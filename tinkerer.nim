#
#
#    Nawabs -- The Anti package manager for Nim
#        (c) Copyright 2016 Andreas Rumpf
#
#    See the file "license.txt", included in this
#    distribution, for details about the copyright.

## This module implements the "tinkering" algorithm. It's still pretty basic
## but it tries to mimic how a programmer would approach this problem.

import json, os, sets
import strutils except toLower
from unicode import toLower, cmpRunesIgnoreCase
import osutils, packages, recipes, callnim, nimscriptsupport

type
  Config* = ref object
    refreshed*, cloneUsingHttps*, nodeps*, norecipes*, noquestions*: bool
    nimExe*: string
    workspace*, deps*: string
    foreignDeps*: seq[string]

proc newConfig*(): Config =
  Config(nimExe: "nim", foreignDeps: @[])

proc refresh*(c: Config) =
  withDir c.workspace / recipesDirName:
    let roots = "config" / "roots.nims"
    runScript(roots, c.workspace)

proc getPackages*(c: Config): seq[Package] =
  result = @[]
  var namesAdded = initSet[string]()
  var jsonFiles = 0
  for kind, path in walkDir(c.workspace / recipesDirName / "packages"):
    if kind == pcFile and path.endsWith(".json"):
      inc jsonFiles
      let packages = json.parseFile(path)
      for p in packages:
        let pkg = p.fromJson()
        if pkg.name notin namesAdded:
          result.add(pkg)
          namesAdded.incl(pkg.name)
  if jsonFiles == 0 and not c.refreshed:
    c.refreshed = true
    refresh(c)
    result = getPackages(c)

proc installDep(c: Config; p: Package): string =
  if c.nodeps:
    error "Not allowed to clone dependency because of --nodeps: " & p.url
  if c.deps.len > 0:
    createDir c.deps
    withDir c.deps:
      cloneUrl(p.url, p.name, c.cloneUsingHttps)
    return c.deps / p.name
  if c.noquestions:
    withDir c.workspace:
      cloneUrl(p.url, p.name, c.cloneUsingHttps)
    return c.workspace / p.name

  echo "package ", p.name, " seems to be a dependency, but is not part of the",
    " workspace. Please enter where to clone it ",
    "(workspace / <subdir_> / abort); [default is the workspace]: "
  while true:
    let inp = stdin.readLine()
    case inp
    of "abort": return ""
    of recipesDirName:
      echo "Error: cannot use " & recipesDirName & " as subdir"
    of "workspace", "w", "ws", "_", "":
      withDir c.workspace:
        cloneUrl(p.url, p.name, c.cloneUsingHttps)
      return c.workspace / p.name
    of ".":
      cloneUrl(p.url, p.name, c.cloneUsingHttps)
      return getCurrentDir() / p.name
    else:
      if not inp.endsWith"_":
        echo "Error: the subdirectory should end in an underscore"
      else:
        createDir inp
        withDir inp:
          cloneUrl(p.url, p.name, c.cloneUsingHttps)
        return inp / p.name

proc findProj(path: string; p: string): string =
  # ensure that 'foo_/bar' takes precedence over 'sub/dir_/bar':
  var subdirs: seq[string]
  for k, dir in os.walkDir(path, relative=true):
    if k == pcDir and dir != recipesDirName:
      if dir.endsWith("_"):
        if subdirs.isNil: subdirs = @[]
        subdirs.add dir
      if cmpRunesIgnoreCase(p, dir) == 0:
        return path / dir
  for s in subdirs:
    result = findProj(path / s, p)
    if result.len > 0: return result

proc findPkg(pkgList: seq[Package]; package: string): Package =
  if package.isUrl:
    result = assumePackage(extractFilename(package), package)
  else:
    for pkg in pkgList:
      if cmpRunesIgnoreCase(package, pkg.name) == 0:
        return pkg

proc cloneRec*(c: Config; pkgList: seq[Package]; package: string; rec=0): string =
  ## returns the proj if the package is already in the workspace.
  if rec >= 10:
    error "unbounded recursion during cloning"

  let p = findPkg(pkgList, package)
  if p.isNil:
    error "Cannot resolve dependency: " & package
  else:
    let proj = findProj(c.workspace, p.name)
    if proj.len == 0:
      var dep: string
      if rec == 0:
        cloneUrl(p.url, p.name, c.cloneUsingHttps)
        dep = p.name
      else:
        dep = installDep(c, p)
      # now try to extract deps and recurse:
      let info = readPackageInfo(dep, c.workspace)
      for fd in info.foreignDeps: c.foreignDeps.add fd
      for r in info.requires:
        discard cloneRec(c, pkgList, r, rec+1)
    else:
      result = proj

proc selectCandidate(conf: Config; c: PkgCandidates): Package =
  for i in low(c)..high(c):
    if c[i].len == 1: return c[i][0]
    if c[i].len != 0:
      echo "These all match: "
      for x in c[i]: echo x.url
      if conf.noquestions:
        error "Ambiguous package request"
      else:
        echo "Which one to use? [1..", c[i].len, "|abort] "
        while true:
          let inp = stdin.readLine()
          if inp == "abort": return nil
          try:
            let choice = parseInt(inp)
            if choice < 1 or choice > c[i].len:
              raise newException(ValueError, "out of range")
            return c[i][choice-1]
          except ValueError, OverflowError:
            echo "Please type in 'abort' or a number in the range 1..", c[i].len

proc tinker(c: Config; pkgList: seq[Package]; pkg, cmd: string; args: seq[string]) =
  var path: seq[string] = @[]
  var todo: Action
  let proj = findProj(c.workspace, pkg)
  if proj.len == 0:
    error "cannot find package: " & pkg
  withDir proj:
    while true:
      todo = callCompiler(c.nimExe, cmd, args, path)
      case todo.k
      of Success:
        echo "Build Successful."
        if not c.norecipes:
          writeRecipe(c.workspace, pkg,
                      toNimCommand(c.nimExe, cmd, args, path), path)
        quit 0
      of Failure:
        error "Hard failure. Don't know how to proceed.\n" & todo.file
      of FileMissing:
        let terms = todo.file.changeFileExt("").split({'\\','/'})
        let p = selectCandidate(c, determineCandidates(pkgList, terms))
        if p == nil:
          error "No package found that could be missing for: " & todo.file
        else:
          if path.contains(p.name):
            error "Package already in --path and yet compilation failed: " & p.name
          var dep = findProj(c.workspace, p.name)
          if dep.len == 0:
            dep = installDep(c, p)
            if dep.len == 0: error "Aborted."
          path.add dep

proc tinkerCmd*(c: Config; pkgList: seq[Package]; pkg: string;
                args: seq[string]) =
  tinker(c, pkgList, pkg, args[0], args[1..^1])

proc tinkerPkg*(c: Config; pkgList: seq[Package]; pkg: string) =
  var proj = findProj(c.workspace, pkg)
  if proj.len == 0:
    discard cloneRec(c, pkgList, pkg)
    proj = getCurrentDir() / pkg
  let nimfile = findProjectNimFile(proj)
  if nimfile.len == 0:
    error "Cannot determine tinker command. Try 'nawabs tinker " & pkg & " c example'"

  let info = readPackageInfo(proj, c.workspace)
  let cmd = if info.backend.len > 0: info.backend else: "c"
  tinker(c, pkgList, pkg, cmd, @[nimfile])

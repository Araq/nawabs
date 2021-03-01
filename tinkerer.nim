#
#    Nawabs -- The Anti package manager for Nim
#        (c) Copyright 2017 Andreas Rumpf
#
#    See the file "license.txt", included in this
#    distribution, for details about the copyright.

## This module implements the traditional build command.

import json, os, sets
import strutils except toLower
from unicode import toLower, cmpRunesIgnoreCase
from osproc import quoteShell, execCmdEx
import osutils, packages, recipes, nimscriptsupport

import
  compiler / [options]

type
  DepsSetting* = enum
    normalDeps, noDeps, onlyDeps, askDeps
  Config* = ref object
    refreshed*, cloneUsingHttps*, norecipes*, noquestions*: bool
    depsSetting*: DepsSetting
    nimExe*: string
    workspace*, deps*: string
    foreignDeps*: seq[string]
    nimconfig: ConfigRef

proc newConfig*(): Config =
  Config(nimExe: "nim", foreignDeps: @[], nimconfig: newConfigRef())

proc refresh*(c: Config) =
  withDir c.workspace / recipesDirName:
    let roots = configDir / "roots.nims"
    runScript(roots, c.workspace)

proc getPackages*(c: Config): seq[Package] =
  result = @[]
  var namesAdded = initHashSet[string]()
  var jsonFiles = 0
  for kind, path in walkDir(c.workspace / recipesDirName / "packages"):
    if kind == pcFile and path.endsWith(".json"):
      inc jsonFiles
      let packages = json.parseFile(path)
      for p in packages:
        let pkg = p.fromJson()
        if pkg != nil and pkg.name notin namesAdded:
          result.add(pkg)
          namesAdded.incl(pkg.name)
  if jsonFiles == 0 and not c.refreshed:
    c.refreshed = true
    refresh(c)
    result = getPackages(c)

proc installDep(c: Config; p: Package): Project =
  if c.depsSetting == noDeps:
    error "Not allowed to clone dependency because of --nodeps: " & p.url
  if c.deps.len > 0:
    createDir c.deps
    withDir c.deps:
      cloneUrl(p.url, p.name, c.cloneUsingHttps)
    return Project(name: p.name, subdir: c.deps)
  if c.noquestions:
    withDir c.workspace:
      cloneUrl(p.url, p.name, c.cloneUsingHttps)
    return Project(name: p.name, subdir: c.workspace)

  echo "package ", p.name, " seems to be a dependency, but is not part of the",
    " workspace. Please enter where to clone it ",
    "(workspace / <subdir_> / abort); [default is the workspace]: "
  while true:
    let inp = stdin.readLine()
    case inp
    of "abort": return Project(name: "", subdir: "")
    of recipesDirName:
      echo "Error: cannot use " & recipesDirName & " as subdir"
    of "workspace", "w", "ws", "_", "":
      withDir c.workspace:
        cloneUrl(p.url, p.name, c.cloneUsingHttps)
      return Project(name: p.name, subdir: c.workspace)
    of ".":
      cloneUrl(p.url, p.name, c.cloneUsingHttps)
      return Project(name: p.name, subdir: getCurrentDir())
    else:
      if not inp.endsWith"_":
        echo "Error: the subdirectory should end in an underscore"
      else:
        createDir inp
        withDir inp:
          cloneUrl(p.url, p.name, c.cloneUsingHttps)
        return Project(name: p.name, subdir: inp)

proc findProj*(path: string; p: string): Project =
  # ensure that 'foo_/bar' takes precedence over 'sub/dir_/bar':
  var subdirs: seq[string] = @[]
  for k, dir in os.walkDir(path, relative=true):
    if k == pcDir and dir != recipesDirName:
      if dir.endsWith("_"):
        subdirs.add dir
      if cmpRunesIgnoreCase(p, dir) == 0:
        return Project(name: dir, subdir: path)
  for s in subdirs:
    result = findProj(path / s, p)
    if result.name.len > 0: return result

proc updateProject*(c: Config; path: string) =
  let projname = extractFilename(path)
  template check() =
    if c.depsSetting == askDeps:
      stdout.write "update ", projname, " (y/n)?"
      if stdin.readLine().normalize.startsWith"n": return
    else:
      echo "updating ", projname

  if dirExists(path / ".git"):
    check()
    withDir path:
      let (outp, exitCode) = execCmdEx("git status")
      if "Changes not staged for commit" notin outp and exitCode == 0:
        exec "git pull", 10
  elif dirExists(path / ".hg"):
    check()
    withDir path:
      # XXX check hg status somehow
      exec "hg pull"

proc updateEverything*(c: Config; path: string) =
  for k, dir in os.walkDir(path, relative=true):
    if k == pcDir and dir != recipesDirName:
      if dir.endsWith("_"):
        updateEverything(c, dir)
      else:
        updateProject(c, path / dir)

proc findPkg(pkgList: seq[Package]; package: string): Package =
  if package.isUrl:
    result = assumePackage(extractFilename(package), package)
  else:
    for pkg in pkgList:
      if cmpRunesIgnoreCase(package, pkg.name) == 0:
        return pkg

proc cloneRec*(c: Config; pkgList: seq[Package]; package: string; rec=0): bool =
  ## returns true if the package is already in the workspace.
  if rec >= 10:
    error "unbounded recursion during cloning"

  let p = findPkg(pkgList, package)
  if p.isNil:
    error "Cannot resolve dependency: " & package
  else:
    var proj = findProj(c.workspace, p.name)
    if proj.name.len == 0:
      if rec == 0:
        cloneUrl(p.url, p.name, c.cloneUsingHttps)
        proj = Project(name: p.name, subdir: getCurrentDir())
      else:
        proj = installDep(c, p)
    else:
      result = true
    # watch out, even though the project exists already, some of its
    # dependencies might not!
    # now try to extract deps and recurse:
    let info = readPackageInfo(proj.toPath, c.workspace)
    for fd in info.foreignDeps: c.foreignDeps.add fd
    for r in info.requires:
      discard cloneRec(c, pkgList, r, rec+1)

proc buildCmd*(c: Config; pkgList: seq[Package]; package: string; result: var string;
               deps: var seq[string]; onlyDeps=false; rec=0) =
  ## returns the proj if the package is already in the workspace.
  if rec >= 10:
    error "unbounded recursion during build command creation"

  var pname = package
  var p: Package = nil
  if package.isUrl:
    p = findPkg(pkgList, package)
    if p.isNil:
      error "Cannot resolve dependency: " & package
    pname = p.name
  var proj = findProj(c.workspace, pname)
  if proj.name.len == 0:
    if p == nil: p = findPkg(pkgList, pname)
    if p != nil:
      proj = installDep(c, p)
    else:
      error "Cannot resolve dependency: " & package
  let info = readPackageInfo(proj.toPath, c.workspace)
  if rec == 0:
    result.add ' '
    if info.backend.len == 0: result.add 'c'
    else: result.add info.backend
    result.add " --noNimblePath"
  for fd in info.foreignDeps: c.foreignDeps.add fd
  for r in info.requires:
    buildCmd(c, pkgList, r, result, deps, onlyDeps, rec+1)
  if rec == 0:
    if not onlyDeps:
      let pp = proj.toPath
      let nimfile = findMainNimFile(c.nimconfig, pp)
      if nimfile.len == 0:
        error "Cannot determine main nim file for: " & pp
      result.add " "
      result.add pp / nimfile
  else:
    result.add " --path:"
    result.add quoteShell(proj.toPath)
    deps.add proj.toPath

#
#
#    Nawabs -- The Anti package manager for Nim
#        (c) Copyright 2016 Andreas Rumpf
#
#    See the file "license.txt", included in this
#    distribution, for details about the copyright.

import system except TResult
import strutils except toLower
from unicode import toLower
import os, json, sets, parseopt
import callnim

const
  Help = """
Usage: nawabs COMMAND [opts]

Commands:
  refresh                         Refreshes the package list.
  search       [pkg/tag]          Searches for a specified package. Search is
                                  performed by tag and by name. If no argument
                                  is given, lists all packages.
  clone        pkgname            Clones a package.
  c|cpp|js|..  pkgname            Builds a package with nim.

Options:
  -h, --help                      Print this help message.
  -v, --version                   Print version information.
  --nimExe:nim.exe                Which nim to use for building.
  --cloneUsingHttps               Use the https URL instead of git URLs for
                                  cloning.
"""
  Version = "1.0"

type
  Package* = ref object
    # Required fields in a package.
    name*: string
    url*: string # Download location.
    license*: string
    downloadMethod*: string
    description*: string
    tags*: seq[string] # Even if empty, always a valid non nil seq. \
    # From here on, optional fields set to the empty string if not available.
    version*: string
    dvcsTag*: string
    web*: string # Info url for humans.

proc error(msg: string) = quit "[Error] " & msg

proc exec(cmd: string) =
  if execShellCmd(cmd) != 0:
    error "exernal program failed: " & cmd

proc optionalField(obj: JsonNode, name: string, default = ""): string =
  if hasKey(obj, name):
    if obj[name].kind == JString:
      return obj[name].str
    else:
      error("Corrupted packages.json file. " & name &
            " field is of unexpected type.")
  else:
    return default

proc requiredField(obj: JsonNode, name: string): string =
  result = optionalField(obj, name, nil)
  if result == nil:
    error("Package in packages.json file does not contain a " & name & " field.")

proc fromJson(obj: JSonNode): Package =
  new result
  result.name = obj.requiredField("name")
  result.version = obj.optionalField("version")
  result.url = obj.requiredField("url")
  result.downloadMethod = obj.requiredField("method")
  result.dvcsTag = obj.optionalField("dvcs-tag")
  result.license = obj.requiredField("license")
  result.tags = @[]
  for t in obj["tags"]:
    result.tags.add(t.str)
  result.description = obj.requiredField("description")
  result.web = obj.optionalField("web")

proc echoPackage*(pkg: Package) =
  echo(pkg.name & ":")
  echo("  url:         " & pkg.url & " (" & pkg.downloadMethod & ")")
  echo("  tags:        " & pkg.tags.join(", "))
  echo("  description: " & pkg.description)
  echo("  license:     " & pkg.license)
  if pkg.web.len > 0:
    echo("  website:     " & pkg.web)

var
  refreshed, cloneUsingHttps: bool
  nimExe = "nim"

proc refresh() =
  let roots = getAppDir() / "config" / "roots.nims"
  exec nimExe & " e " & roots

proc getPackages(): seq[Package] =
  result = @[]
  var namesAdded = initSet[string]()
  var jsonFiles = 0
  for kind, path in walkDir(getCurrentDir()):
    if kind == pcFile and path.endsWith(".json"):
      inc jsonFiles
      let packages = parseFile(path)
      for p in packages:
        let pkg = p.fromJson()
        if pkg.name notin namesAdded:
          result.add(pkg)
          namesAdded.incl(pkg.name)
  if jsonFiles == 0 and not refreshed:
    refreshed = true
    refresh()
    result = getPackages()


proc search(terms: seq[string]) =
  let pkgList = getPackages()
  var found = false
  template onFound =
    echoPackage(pkg)
    echo(" ")
    found = true
    break forPackage

  for pkg in pkgList:
    if terms.len > 0:
      block forPackage:
        for term in terms:
          let word = term.toLower
          # Search by name.
          if word in pkg.name.toLower:
            onFound()
          # Search by tag.
          for tag in pkg.tags:
            if word in tag.toLower:
              onFound()
    else:
      echoPackage(pkg)
      echo(" ")

  if not found and terms.len > 0:
    echo("No package found.")

proc cloneUrl(url: string) =
  var modUrl =
    if url.startsWith("git://") and cloneUsingHttps:
      "https://" & url[6 .. ^1]
    else: url

  # github + https + trailing url slash causes a
  # checkout/ls-remote to fail with Repository not found
  if modUrl.contains("github.com") and modUrl.endswith("/"):
    modUrl = modUrl[0 .. ^2]

  if execShellCmd("git ls-remote " & modUrl) == QuitSuccess:
    exec "git clone " & modUrl
  elif execShellCmd("hg identify " & modUrl) == QuitSuccess:
    exec "hg clone " & modUrl
  else:
    error "Unable to identify url: " & modUrl

proc clone(package: string) =
  let pkgList = getPackages()
  let word = package.toLower
  for pkg in pkgList:
    if word == pkg.name.toLower:
      if not dirExists(pkg.name):
        cloneUrl(pkg.url)
      else:
        error "Directory already exists: " & pkg.name
      break

type PkgCandidates = array[3, seq[Package]]

proc determineCandidates(pkgList: seq[Package];
                         terms: seq[string]): PkgCandidates =
  result[0] = @[]
  result[1] = @[]
  result[2] = @[]
  for pkg in pkgList:
    block termLoop:
      for term in terms:
        let word = term.toLower
        if word == pkg.name.toLower:
          result[0].add pkg
          break termLoop
        elif word in pkg.name.toLower:
          result[1].add pkg
          break termLoop
        else:
          for tag in pkg.tags:
            if word in tag.toLower:
              result[2].add pkg
              break termLoop

proc selectCandidate(c: PkgCandidates): Package =
  for i in low(c)..high(c):
    if c[i].len == 1: return c[i][0]
    if c[i].len != 0:
      echo "These all match: "
      for x in c[i]: echo x.url
      error "Ambiguous package request"

proc tinker(nimExe, cmd: string; args: seq[string]) =
  let pkgList = getPackages()
  var path: seq[string] = @[]
  var todo: Action
  while true:
    let lastDir = getCurrentDir()
    let newDir = lastDir / args[0]
    if dirExists(newDir): setCurrentDir(newDir)
    try:
      todo = callCompiler(nimExe, cmd, args, path)
    finally:
      setCurrentDir(lastDir)
    case todo.k
    of Success:
      echo "Build Successful."
      quit 0
    of Failure:
      error "Hard failure. Don't know how to proceed."
    of FileMissing:
      let terms = todo.file.changeFileExt("").split({'\\','/'})
      let c = selectCandidate determineCandidates(pkgList, terms)
      if c == nil:
        error "No package found that could be missing for: " & todo.file
      else:
        if path.contains(c.name):
          error "Package already in --path and yet compilation failed: " & c.name
        if not dirExists(c.name):
          cloneUrl(c.url)
        path.add c.name

proc main() =
  var action = ""
  var args: seq[string] = @[]
  for kind, key, val in getOpt():
    case kind
    of cmdArgument:
      if action.len == 0: action = key
      else: args.add key
    of cmdLongOption, cmdShortOption:
      case key.normalize
      of "version", "v":
        echo Version
      of "help", "h":
        echo Help
      of "nimexe":
        if val.len == 0: error "--nimExe takes a value"
        else: nimExe = val
      of "cloneusinghttps":
        cloneUsingHttps = true
      else:
        error "unkown command line option: " & key
    of cmdEnd: discard "cannot happen"
  case action.normalize
  of "refresh": refresh()
  of "search", "list": search args
  of "clone":
    if args.len == 1:
      clone args[0]
    else:
      error "clone command takes a single package name"
  elif args.len > 0:
    tinker(nimExe, action, args)
  else:
    error "compile command takes a package name"

when isMainModule:
  main()

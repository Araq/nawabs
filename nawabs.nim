#
#    Nawabs -- The Anti package manager for Nim
#        (c) Copyright 2017 Andreas Rumpf
#
#    See the file "license.txt", included in this
#    distribution, for details about the copyright.

import strutils except toLower
from unicode import toLower
import os, json, parseopt
from osproc import quoteShell
import osutils, recipes, callnim, packages, tinkerer, nimscriptsupport

const
  Help = """
Usage: nawabs [options] COMMAND [args]

Commands:
  init                            Initializes the current working directory as
                                  the workspace.
  refresh                         Refreshes the package list.
  search       [pkg/tag]          Searches for a specified package. Search is
                                  performed by tag and by name. If no argument
                                  is given, lists all packages.
  clone         pkg               Clones a package.
    --deps:DIR_                   Use DIR_ as the subdirectory
                                  for cloning missing dependencies. (Use '_' to
                                  denote the workspace, '.' for the current
                                  directory.)
    --nodeps                      Do not clone missing dependencies.
    --noquestions                 Do not ask any questions.

  build pkg [args]                Build the package, save as recipe if
                                  successful. You can pass optional args
                                  like -d:release to the build.
    --deps:DIR_                   Use DIR_ as the subdirectory
                                  for cloning missing dependencies. (Use '_' to
                                  denote the workspace, '.' for the current
                                  directory.)
    --nodeps                      Do not clone missing dependencies.
    --norecipes                   Do not use the recipes mechanism.
    --noquestions                 Do not ask any questions.

  pinned        pkg               Use the recipe to get a reproducible build.

  tinker pkg [args]               Build the package via tinkering. Experimental,
                                  do not complain if it fails.
  path pkg-list                   Show absolute paths to the installed packages
                                  specified.
  deps pkg                        Show required ``--path:xyz`` command line to
                                  build the given package.

  update        pkg               Update a package and all of its dependencies.
    --nodeps                      Do not update its dependencies.
    --depsOnly                    Only update its dependencies.
    --ask                         Ask about every dependency.
  update                          Update every package in the workspace that
                                  doesn't have uncommitted changes.
    --ask                         Ask about every dependency.

  task <taskname> [file.nimble]   Run the task of the nimble file.
  tests [file.nimble]             Run the 'tests' task of the nimble file.
  bench [file.nimble]             Run the 'bench' task of the nimble file.

  make [file.nim] [args]          Run 'nim c -r file.nim' or 'file.exe'.
                                  If file.nim is missing, it
                                  uses 'nakefile.nim'.

  put           key value         Put a key value pair to the scratchpad.
  get           key               Get the value to a key back.
  run           key [args]        Get the value to a key back and run it as
                                  a command.

Options:
  -h, --help                      Print this help message.
  -v, --version                   Print version information.
  --nimExe:nim.exe                Which nim to use for building.
  --cloneUsingHttps               Use the https URL instead of git URLs for
                                  cloning.
  --workspace:DIR                 Use DIR as the current workspace.
"""
  Version = "1.1"

proc execRecipe(c: Config; proj: Project;
                attempt = false): bool {.discardable.} =
  let recipe = toRecipe(c.workspace, proj)
  if not fileExists recipe:
    if not attempt:
      error "no recipe found: " & recipe
  else:
    runScript(recipe, c.workspace)

proc getProject(c: Config; name: string): Project =
  result = findProj(c.workspace, name)
  if result.name.len == 0:
    error "cannot find package " & name

proc build(c: Config; pkgList: seq[Package]; pkg, rest: string) =
  var cmd = c.nimExe
  if rest.len > 0:
    cmd.add ' '
    cmd.add rest
  var deps: seq[string] = @[]
  buildCmd c, getPackages(c), pkg, cmd, deps
  exec cmd
  if not c.norecipes:
    writeRecipe(c.workspace, getProject(c, pkg), cmd, deps)
  writeKeyValPair(c.workspace, "_", cmd)

proc listDeps(c: Config, pkg: string) =
  var cmd = ""
  var deps: seq[string] = @[]
  buildCmd c, @[], pkg, cmd, deps
  var result = ""
  for d in deps:
    result.add " --path:"
    result.add quoteShell(d)
  echo result

proc update(c: Config; pkg: string) =
  let p = getProject(c, pkg)
  var cmd = c.nimExe
  var deps: seq[string] = @[]
  buildCmd(c, getPackages(c), pkg, cmd, deps, onlyDeps=true)
  if c.depsSetting != onlyDeps:
    updateProject(c, p.toPath)
  if c.depsSetting != noDeps:
    for d in deps: updateProject(c, d)

proc echoPath(c: Config, a: string) =
  let p = getProject(c, a)
  echo c.workspace / p.subdir / p.name

proc findNimbleFile(): string =
  for x in walkFiles("*.nimble"):
    if result.isNil: result = x
    else: error "cannot determine which .nimble file to use; ambiguous"
  if result.isNil:
    error "cannot find a .nimble file"

proc runtask(c: Config; taskname, file: string) =
  runScript(file, c.workspace, taskname, allowSetCommand=true)

proc make(c: Config; args: seq[string]) =
  var nimfile = "nakefile.nim"
  var start = 0
  if args.len >= 1 and args[0].contains(".nim"):
    nimfile = args[0]
    start = 1
  let exefile = changeFileExt(nimfile, ExeExt)
  var cmd = if not exefile.fileExists or fileChanged(nimfile, c.workspace / recipesDirName):
              "nim c -r"
            else:
              exefile
  for i in start..<args.len:
    cmd.add ' '
    cmd.add quoteShell(args[i])
  exec cmd

proc main(c: Config) =
  var action = ""
  var args: seq[string] = @[]
  var rest = ""

  template handleRest() =
    if args.len == 1 and action in ["build", "put", "tinker", "run", "make"]:
      rest = cmdLineRest(p)
      break

  var p = initOptParser()
  while true:
    next(p)
    case p.kind
    of cmdArgument:
      if action.len == 0: action = p.key.normalize
      else: args.add p.key
      handleRest()
    of cmdLongOption, cmdShortOption:
      case p.key.normalize
      of "version", "v":
        echo Version
        quit 0
      of "help", "h":
        echo Help
        quit 0
      of "nimexe":
        if p.val.len == 0: error "--nimExe takes a value"
        else: c.nimExe = p.val
      of "nodeps": c.depsSetting = noDeps
      of "depsonly": c.depsSetting = onlyDeps
      of "ask": c.depsSetting = askDeps
      of "deps":
        if p.val == recipesDirName:
          error "cannot use " & recipesDirName & " for --deps"
        elif p.val.len > 1 and p.val.endsWith"_":
          c.deps = p.val
        else:
          error "deps directory must end in an underscore"
      of "norecipes": c.norecipes = true
      of "cloneusinghttps": c.cloneUsingHttps = true
      of "noquestions": c.noquestions = true
      of "workspace":
        if p.val.len == 0: error "--" & p.key & " takes a value"
        else: c.workspace = p.val
      else:
        error "unkown command line option: " & p.key
    of cmdEnd: break
  if c.workspace.len > 0:
    if not dirExists(c.workspace / recipesDirName):
      error c.workspace & "is not a workspace"
  else:
    c.workspace = getCurrentDir()
    if action != "init":
      while c.workspace.len > 0 and not dirExists(c.workspace / recipesDirName):
        c.workspace = c.workspace.parentDir()
      if c.workspace.len == 0:
        error "Could not detect a workspace. " &
              "Use 'nawabs init' to create a new workspace."

  case c.deps
  of "_": c.deps = c.workspace
  of ".": c.deps = getCurrentDir()
  else: discard

  template singlePkg() =
    if args.len != 1:
      error action & " command takes a single package name"

  template noPkg() =
    if args.len != 0:
      error action & " command takes no arguments"

  case action
  of "init":
    noPkg()
    if dirExists(c.workspace / recipesDirName):
      error c.workspace & " is already a workspace"
    recipes.init(c.workspace)
    withDir c.workspace / recipesDirName:
      createDir configDir
      let roots = configDir / "roots.nims"
      copyFile(getAppDir() / roots, roots)
      copyFile(getAppDir() / configDir / nimscriptApi, nimscriptApi)
    refresh(c)
  of "refresh": refresh(c)
  of "search", "list": search getPackages(c), args
  of "clone":
    singlePkg()
    if cloneRec(c, getPackages(c), args[0]):
      error "Already part of workspace: " & args[0]
  of "help", "h":
    echo Help
  of "update":
    if args.len == 0:
      updateEverything(c, c.workspace)
    else:
      singlePkg()
      update(c, args[0])
  of "pinned":
    singlePkg()
    execRecipe c, getProject(c, args[0])
  of "tinker":
    if args.len == 0:
      error action & " command takes one or more arguments"
    if rest.len == 0:
      tinkerPkg(c, getPackages(c), args[0])
    else:
      tinkerCmd(c, getPackages(c), args[0], rest)
  of "build":
    singlePkg()
    build c, getPackages(c), args[0], rest
  of "deps":
    singlePkg()
    listDeps c, args[0]
  of "path":
    for a in args: echoPath(c, a)
  of "get":
    if args.len > 1:
      error action & " command takes one or zero names"
    try:
      echo getValue(c.workspace, if args.len == 1: args[0] else: "_")
    except IOError:
      echo ""
  of "put":
    writeKeyValPair(c.workspace, args[0], rest)
  of "run":
    let k = if args.len >= 1: args[0] else: "_"
    try:
      var v = getValue(c.workspace, k)
      if rest.len > 0: v = v % rest
      exec v
    except IOError:
      error "no variable found: " & k
    except ValueError:
      error "invalid $expansions: " & k & " " & rest
  of "task":
    if args.len == 2:
      runtask(c, args[0], args[1])
    elif args.len == 1:
      runtask(c, args[0], findNimbleFile())
    else:
      error "command 'task' takes 1 or 2 arguments"
  of "tests", "bench":
    if args.len == 1:
      runtask(c, action, args[0])
    elif args.len == 0:
      runtask(c, action, findNimbleFile())
    else:
      error "command '" & action & "' takes 0 or 1 arguments"
  of "make":
    make(c, args)
  else:
    # typing in 'nawabs' with no command currently raises an error so we're
    # free to later do something more convenient here
    if action.len == 0: error "command missing"
    else: error "unknown command: " & action

  if c.foreignDeps.len > 0:
    echo("Hint: This package has some external dependencies.\n",
         "To install them you may be able to run:")
    for fd in c.foreignDeps:
      echo "  ", fd

when isMainModule:
  main(newConfig())

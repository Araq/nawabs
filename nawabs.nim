#
#
#    Nawabs -- The Anti package manager for Nim
#        (c) Copyright 2017 Andreas Rumpf
#
#    See the file "license.txt", included in this
#    distribution, for details about the copyright.

import strutils except toLower
from unicode import toLower
import os, json, parseopt
import osutils, recipes, callnim, packages, tinkerer, nimscriptsupport

# XXX
# - implement the 'build' command (bah)
# - pkg needs to be normalized, could be subdir_/pkg now!
# - test extensively

const
  Help = """
Usage: nawabs COMMAND [opts]

Commands:
  init                            Initializes the current working directory as
                                  the workspace.
  refresh                         Refreshes the package list.
  search       [pkg/tag]          Searches for a specified package. Search is
                                  performed by tag and by name. If no argument
                                  is given, lists all packages.
  clone         pkg               Clones a package.
    --deps:DIR_                   For tinkering use DIR_ as the subdirectory
                                  for cloning missing dependencies. (Use '_' to
                                  denote the workspace, '.' for the current
                                  directory.)
    --nodeps                      Do not clone missing dependencies.
    --noquestions                 Do not ask any questions.

  tinker pkg [cmd]                Tinker to build the package, ignore the recipe.
    --deps:DIR_                   For tinkering use DIR_ as the subdirectory
                                  for cloning missing dependencies. (Use '_' to
                                  denote the workspace, '.' for the current
                                  directory.)
    --nodeps                      Do not clone missing dependencies.
    --norecipes                   Do not use the recipes mechanism.
    --noquestions                 Do not ask any questions.

  update        pkg               Updates a package and all of its dependencies.
  pinned        pkg               Uses the recipe to get a reproducible build.
  pinnedcmd     pkg               Output the last command that built pkg
                                  successfully.
  build         pkg               Builds a package. Uses the recipe
                                  if available, else it 'tinkers'. If pkg is
                                  not part of the workspace, it is 'cloned'.

Options:
  -h, --help                      Print this help message.
  -v, --version                   Print version information.
  --nimExe:nim.exe                Which nim to use for building.
  --cloneUsingHttps               Use the https URL instead of git URLs for
                                  cloning.
  --workspace:DIR                 Use DIR as the current workspace.
"""
  Version = "1.0"

proc outputRecipe(c: Config; package: string) =
  let recipe = toRecipe(c.workspace, package)
  if not fileExists recipe:
    error "no recipe found: " & recipe
  else:
    echo c.nimExe & " e " & recipe

proc execRecipe(c: Config; package, cmd: string;
                attempt = false): bool {.discardable.} =
  let recipe = toRecipe(c.workspace, package)
  if not fileExists recipe:
    if not attempt:
      error "no recipe found: " & recipe
  else:
    exec c.nimExe & " e " & recipe & " " & cmd
    result = true

proc build(c: Config; pkgList: seq[Package]; pkg: string) =
  var proj = cloneRec(c, pkgList, pkg)
  if proj.len == 0:
    # clone cloned it to the current working dir:
    proj = getCurrentDir() / pkg
  if not execRecipe(c, pkg, "", attempt=true):
    tinkerPkg(c, pkgList, pkg)

proc main(c: Config) =
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
        quit 0
      of "help", "h":
        echo Help
        quit 0
      of "nimexe":
        if val.len == 0: error "--nimExe takes a value"
        else: c.nimExe = val
      of "nodeps": c.nodeps = true
      of "deps":
        if val == recipesDirName:
          error "cannot use " & recipesDirName & " for --deps"
        elif val.endsWith"_":
          c.deps = val
        else:
          error "deps directory must end in an underscore"
      of "norecipes": c.norecipes = true
      of "cloneusinghttps": c.cloneUsingHttps = true
      of "noquestions": c.noquestions = true
      of "workspace":
        if val.len == 0: error "--" & key & " takes a value"
        else: c.workspace = val
      else:
        error "unkown command line option: " & key
    of cmdEnd: discard "cannot happen"
  if c.workspace.len > 0:
    if not dirExists(c.workspace / recipesDirName):
      error c.workspace & "is not a workspace"
  else:
    c.workspace = getCurrentDir()
    if action.normalize != "init":
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

  case action.normalize
  of "init":
    noPkg()
    if dirExists(c.workspace / recipesDirName):
      error c.workspace & " is already a workspace"
    recipes.init(c.workspace)
    withDir c.workspace / recipesDirName:
      createDir "config"
      let roots = "config" / "roots.nims"
      copyFile(getAppDir() / roots, roots)
      copyFile(getAppDir() / "config" / nimscriptApi, nimscriptApi)
    refresh(c)
  of "refresh": refresh(c)
  of "search", "list": search getPackages(c), args
  of "clone":
    singlePkg()
    let proj = cloneRec(c, getPackages(c), args[0])
    if proj.len > 0:
      error "Already part of workspace: " & proj
  of "help", "h":
    echo Help
  of "update", "pinned":
    singlePkg()
    execRecipe c, args[0], action.normalize
  of "pinnedcmd":
    singlePkg()
    outputRecipe c, args[0]
  of "tinker":
    if args.len == 0:
      error action & " command takes one or more arguments"
    if args.len == 1:
      tinkerPkg(c, getPackages(c), args[0])
    else:
      tinkerCmd(c, getPackages(c), args[0], args[1..^1])
  of "build":
    singlePkg()
    build c, getPackages(c), args[0]
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

# Copyright (C) Andreas Rumpf. All rights reserved.
# BSD License. Look at license.txt for more info.

## Implements the new configuration system for Nimble. Uses Nim as a
## scripting language.

import
  compiler / [ast, modules, passes, passaux,
  condsyms, sem, semdata,
  llstream, vm, vmdef, commands,
  msgs, magicsys, idents,
  nimconf, modulegraphs, options, scriptconfig]

from compiler/scriptconfig import setupVM
from compiler/astalgo import strTableGet
from recipes import recipesDirName

import parsecfg
import os, strutils, strtabs, tables, times, osproc, streams

type
  PackageInfo* = object
    myPath*: string ## The path of this .nimble file
    isNimScript*: bool ## Determines if this pkg info was read from a nims file
    isMinimal*: bool
    isInstalled*: bool ## Determines if the pkg this info belongs to is installed
    name*: string
    skipDirs*: seq[string]
    skipFiles*: seq[string]
    skipExt*: seq[string]
    installDirs*: seq[string]
    installFiles*: seq[string]
    installExt*: seq[string]
    requires*: seq[string]
    bin*: seq[string]
    binDir*: string
    srcDir*: string
    backend*: string
    foreignDeps*: seq[string]

const
  nimscriptApi* = "nimscriptapi.nim"

proc raiseVariableError(ident, typ: string) {.noinline.} =
  raise newException(ValueError,
    "NimScript's variable '" & ident & "' needs a value of type '" & typ & "'.")

proc isStrLit(n: PNode): bool = n.kind in {nkStrLit..nkTripleStrLit}

proc getGlobal(ident: PSym): string =
  let n = vm.globalCtx.getGlobalValue(ident)
  if n.isStrLit:
    result = if n.strVal.isNil: "" else: n.strVal
  else:
    raiseVariableError(ident.name.s, "string")

proc getGlobalAsSeq(ident: PSym): seq[string] =
  let n = vm.globalCtx.getGlobalValue(ident)
  result = @[]
  if n.kind == nkBracket:
    for x in n:
      if x.isStrLit:
        result.add x.strVal
      else:
        raiseVariableError(ident.name.s, "seq[string]")
  else:
    raiseVariableError(ident.name.s, "seq[string]")

proc token(s: string; idx: int; lit: var string): int =
  var i = idx
  if i >= s.len: return i
  while s[i] in Whitespace: inc(i)
  lit.setLen 0
  if s[i] in Letters:
    while i < s.len and s[i] in Letters+{'_','.','-','0'..'9'}:
      lit.add s[i]
      inc i
  elif s[i] == '"':
    inc i
    while i < s.len and s[i] != '"':
      lit.add s[i]
      inc i
    inc i
  else:
    lit.add s[i]
    inc i
  result = i

proc parseRequires(s: string): string =
  result = ""
  discard token(s, 0, result)

proc addDep(result: var seq[string]; dep: string) =
  if dep notin ["nim", "nimrod"]: result.add dep

proc extractRequires(ident: PSym, result: var seq[string]) =
  let n = vm.globalCtx.getGlobalValue(ident)
  if n.kind == nkBracket:
    for x in n:
      if x.kind == nkPar and x.len == 2 and x[0].isStrLit and x[1].isStrLit:
        result.addDep(x[0].strVal)
      elif x.isStrLit:
        result.addDep(parseRequires(x.strVal))
      else:
        raiseVariableError("requiresData", "seq[(string, VersionReq)]")
  else:
    raiseVariableError("requiresData", "seq[(string, VersionReq)]")

proc getNimPrefixDir(): string = splitPath(findExe("nim")).head.parentDir

proc execScript(graph: ModuleGraph; cache: IdentCache; scriptName: string, workspace: string): PSym =
  ## Executes the specified script. Returns the script's module symbol.
  ##
  ## No clean up is performed and must be done manually!
  if "nimscriptapi" notin options.implicitImports:
    options.implicitImports.add("nimscriptapi")

  # Ensure the compiler can find its standard library #220.
  options.gPrefixDir = getNimPrefixDir()

  let pkgName = scriptName.splitFile.name

  # Ensure that "nimscriptapi" is in the PATH.
  searchPaths.add workspace / recipesDirName

  initDefines()
  loadConfigs(DefaultConfig)
  passes.gIncludeFile = includeModule
  passes.gImportModule = importModule

  defineSymbol("nimscript")
  defineSymbol("nimconfig")
  defineSymbol("nimble")
  defineSymbol("nawabs")
  registerPass(semPass)
  registerPass(evalPass)

  add(searchPaths, options.libpath)

  result = graph.makeModule(scriptName)

  incl(result.flags, sfMainModule)
  vm.globalCtx = setupVM(result, cache, scriptName, graph.config)

  # Setup builtins defined in nimscriptapi.nim
  template cbApi(name, body) {.dirty.} =
    vm.globalCtx.registerCallback pkgName & "." & astToStr(name),
      proc (a: VmArgs) =
        body

  cbApi getPkgDir:
    setResult(a, scriptName.splitFile.dir)

  graph.compileSystemModule(cache)
  graph.processModule(result, llStreamOpen(scriptName, fmRead), nil, cache)

proc cleanup() =
  # ensure everything can be called again:
  options.gProjectName = ""
  options.command = ""
  resetSystemArtifacts()
  clearPasses()
  msgs.gErrorMax = 1
  msgs.writeLnHook = nil
  vm.globalCtx = nil
  initDefines()

proc readPackageInfoFromNims*(graph: ModuleGraph; cache: IdentCache;
                              scriptName, workspace: string, result: var PackageInfo) =
  discard execScript(graph, cache, scriptName, workspace)

  var apiModule: PSym
  for i in 0..<graph.modules.len:
    if graph.modules[i] != nil and
        graph.modules[i].name.s == "nimscriptapi":
      apiModule = graph.modules[i]
      break
  doAssert apiModule != nil

  # Extract all the necessary fields populated by the nimscript file.
  proc getSym(apiModule: PSym, ident: string): PSym =
    result = apiModule.tab.strTableGet(getIdent(ident))
    if result.isNil:
      raise newException(ValueError, "Ident not found: " & ident)

  template trivialField(field) =
    result.field = getGlobal(getSym(apiModule, astToStr field))

  template trivialFieldSeq(field) =
    result.field.add getGlobalAsSeq(getSym(apiModule, astToStr field))

  # keep reasonable default:
  let name = getGlobal(apiModule.tab.strTableGet(getIdent"packageName"))
  if name.len > 0: result.name = name

  trivialField srcdir
  trivialField bindir
  trivialFieldSeq skipDirs
  trivialFieldSeq skipFiles
  trivialFieldSeq skipExt
  trivialFieldSeq installDirs
  trivialFieldSeq installFiles
  trivialFieldSeq installExt
  trivialFieldSeq foreignDeps

  extractRequires(getSym(apiModule, "requiresData"), result.requires)

  let binSeq = getGlobalAsSeq(getSym(apiModule, "bin"))
  for i in binSeq:
    result.bin.add(i.addFileExt(ExeExt))

  let backend = getGlobal(getSym(apiModule, "backend"))
  if backend.len == 0:
    result.backend = "c"
  elif cmpIgnoreStyle(backend, "javascript") == 0:
    result.backend = "js"
  else:
    result.backend = backend.toLowerAscii
  cleanup()

proc multiSplit(s: string): seq[string] =
  ## Returns ``s`` split by newline and comma characters.
  ##
  ## Before returning, all individual entries are stripped of whitespace and
  ## also empty entries are purged from the list. If after all the cleanups are
  ## done no entries are found in the list, the proc returns a sequence with
  ## the original string as the only entry.
  const seps = {',', '\L', '\C'}
  proc isTrailingWhitespace(s: string; i: int): bool =
    var i = i
    while s[i] in Whitespace-seps:
      inc i
    result = s[i] in seps
  result = @[]
  var buf = newStringOfCap(40)
  var i = 0
  while i < s.len:
    while s[i] in seps+Whitespace: inc i
    setLen buf, 0
    while i < s.len and s[i] notin seps:
      if not isTrailingWhitespace(s, i):
        buf.add s[i]
      inc i
    if buf.len > 0:
      result.add buf
  # Huh, nothing to return? Return given input.
  if len(result) < 1: result.add s

proc readPackageInfoFromNimble(path: string; result: var PackageInfo) =
  template error() =
    result.isNimScript = true
    break

  var fs = newFileStream(path, fmRead)
  if fs != nil:
    var p: CfgParser
    open(p, fs, path)
    defer: close(p)
    var currentSection = ""
    while true:
      var ev = next(p)
      case ev.kind
      of cfgEof:
        break
      of cfgSectionStart:
        currentSection = ev.section
      of cfgKeyValuePair:
        case currentSection.normalize
        of "package":
          case ev.key.normalize
          of "name": result.name = ev.value
          of "version", "author", "description", "license": discard
          of "srcdir": result.srcDir = ev.value
          of "bindir": result.binDir = ev.value
          of "skipdirs":
            result.skipDirs.add(ev.value.multiSplit)
          of "skipfiles":
            result.skipFiles.add(ev.value.multiSplit)
          of "skipext":
            result.skipExt.add(ev.value.multiSplit)
          of "installdirs":
            result.installDirs.add(ev.value.multiSplit)
          of "installfiles":
            result.installFiles.add(ev.value.multiSplit)
          of "installext":
            result.installExt.add(ev.value.multiSplit)
          of "bin":
            for i in ev.value.multiSplit:
              result.bin.add(i.addFileExt(ExeExt))
          of "backend":
            result.backend = ev.value.toLowerAscii()
            case result.backend.normalize
            of "javascript": result.backend = "js"
            else: discard
          else:
            error()
        of "deps", "dependencies":
          case ev.key.normalize
          of "requires":
            for v in ev.value.multiSplit:
              result.requires.addDep(parseRequires(v))
          else:
            error()
        else: error()
      of cfgOption, cfgError:
        error()
  else:
    result.isNimScript = true

proc readPackageInfo*(proj, workspace: string): PackageInfo =
  let nf = proj / extractFilename(proj) & ".nimble"

  result.skipDirs = @[]
  result.skipFiles = @[]
  result.skipExt = @[]
  result.installDirs = @[]
  result.installFiles = @[]
  result.installExt = @[]
  result.bin = @[]
  result.backend = ""
  result.requires = @[]
  result.foreignDeps = @[]

  readPackageInfoFromNimble(nf, result)
  if result.isNimScript:
    readPackageInfoFromNims(newModuleGraph(), newIdentCache(), nf, workspace, result)

proc runScript*(file, workspace: string) =
  discard execScript(newModuleGraph(), newIdentCache(), file, workspace)

proc findMainNimFile*(dir: string): string =
  splitFile(options.findProjectNimFile(dir)).name

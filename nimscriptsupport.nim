#
#    Nawabs -- The Anti package manager for Nim
#        (c) Copyright 2017 Andreas Rumpf
#
#    See the file "license.txt", included in this
#    distribution, for details about the copyright.

import
  compiler / [ast, modules, passes,
  condsyms, sem,
  llstream, vm, vmdef,
  idents,
  nimconf, modulegraphs, options, scriptconfig, main,
  pathutils]

from compiler/scriptconfig import setupVM
from recipes import recipesDirName

import parsecfg
import os, strutils, tables, streams

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

proc getGlobal(g: ModuleGraph; ident: PSym): string =
  let n = vm.getGlobalValue(PCtx g.vm, ident)
  if n.isStrLit:
    result = n.strVal
  else:
    raiseVariableError(ident.name.s, "string")

proc getGlobalAsSeq(g: ModuleGraph; ident: PSym): seq[string] =
  let n = vm.getGlobalValue(PCtx g.vm, ident)
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
    while i < s.len and s[i] notin Whitespace and s[i] != '#':
      lit.add s[i]
      inc i
  elif s[i] == '"':
    inc i
    while i < s.len and s[i] != '"' and s[i] != '#':
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

proc extractRequires(g: ModuleGraph; ident: PSym, result: var seq[string]) =
  let n = vm.getGlobalValue(PCtx g.vm, ident)
  if n.kind == nkBracket:
    for x in n:
      if x.kind in {nkPar, nkTupleConstr} and x.len == 2 and x[0].isStrLit and x[1].isStrLit:
        result.addDep(x[0].strVal)
      elif x.isStrLit:
        result.addDep(parseRequires(x.strVal))
      else:
        raiseVariableError("requiresData", "seq[(string, VersionReq)]")
  else:
    raiseVariableError("requiresData", "seq[(string, VersionReq)]")

proc getNimPrefixDir(): string =
  result = splitPath(findExe("nim")).head.parentDir
  if not dirExists(result / "lib"): result = ""

const nawabsDefines = ["nimscript", "nimconfig", "nimble", "nawabs"]

proc execScript(graph: ModuleGraph;
                scriptName, workspace, task: string): PSym =
  ## Executes the specified script. Returns the script's module symbol.
  ##
  ## No clean up is performed and must be done manually!
  let config = graph.config
  if "nimscriptapi" notin config.implicitImports:
    config.implicitImports.add("nimscriptapi")

  # Ensure the compiler can find its standard library #220.
  config.prefixDir = AbsoluteDir getNimPrefixDir()
  config.command = task

  let pkgName = scriptName.splitFile.name

  # Ensure that "nimscriptapi" is in the PATH.
  config.searchPaths.add AbsoluteDir(workspace / recipesDirName)

  initDefines(config.symbols)
  loadConfigs(DefaultConfig, graph.cache, graph.config, graph.idgen)

  for d in nawabsDefines:
    defineSymbol(config.symbols, d)
  registerPass(graph, semPass)
  registerPass(graph, evalPass)

  config.searchPaths.add(config.libpath)

  result = graph.makeModule(scriptName)
  result.flags.incl(sfMainModule)
  var idgen = idGeneratorFromModule(result)
  graph.vm = setupVM(result, graph.cache, scriptName, graph, idgen)

  # Setup builtins defined in nimscriptapi.nim
  template cbApi(name, body) {.dirty.} =
    PCtx(graph.vm).registerCallback pkgName & "." & astToStr(name),
      proc (a: VmArgs) =
        body

  cbApi getPkgDir:
    setResult(a, scriptName.splitFile.dir)

  graph.compileSystemModule()
  graph.processModule(result, idgen, llStreamOpen(AbsoluteFile scriptName, fmRead))

proc cleanup(graph: ModuleGraph) =
  # ensure everything can be called again:
  let config = graph.config
  config.projectName = ""
  config.command = ""
  resetSystemArtifacts(graph)
  clearPasses(graph)
  config.errorMax = 1
  config.writeLnHook = nil
  graph.vm = nil
  initDefines(config.symbols)

proc readPackageInfoFromNims*(graph: ModuleGraph;
                              scriptName, workspace: string, result: var PackageInfo) =
  discard execScript(graph, scriptName, workspace, "nawabs")

  var apiModule: PSym
  for i in 0..<graph.ifaces.len:
    if graph.ifaces[i].module != nil and
        graph.ifaces[i].module.name.s == "nimscriptapi":
      apiModule = graph.ifaces[i].module
      break
  doAssert apiModule != nil

  # Extract all the necessary fields populated by the nimscript file.
  proc getSym(g: ModuleGraph; apiModule: PSym, ident: string): PSym =
    result = someSym(g, apiModule, getIdent(graph.cache, ident))
    if result.isNil:
      raise newException(ValueError, "Ident not found: " & ident)

  proc getSym(g: ModuleGraph; apiModule: PSym, ident: PIdent): PSym =
    result = someSym(g, apiModule, ident)
    if result.isNil:
      raise newException(ValueError, "Ident not found: " & ident.s)

  template trivialField(field) =
    result.field = getGlobal(graph, getSym(graph, apiModule, astToStr field))

  template trivialFieldSeq(field) =
    result.field.add getGlobalAsSeq(graph, getSym(graph, apiModule, astToStr field))

  # keep reasonable default:
  let name = getGlobal(graph, getSym(graph, apiModule, getIdent(graph.cache, "packageName")))
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

  extractRequires(graph, getSym(graph, apiModule, "requiresData"), result.requires)

  let binSeq = getGlobalAsSeq(graph, getSym(graph, apiModule, "bin"))
  for i in binSeq:
    result.bin.add(i.addFileExt(ExeExt))

  let backend = getGlobal(graph, getSym(graph, apiModule, "backend"))
  if backend.len == 0:
    result.backend = "c"
  elif cmpIgnoreStyle(backend, "javascript") == 0:
    result.backend = "js"
  else:
    result.backend = backend.toLowerAscii
  cleanup(graph)

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
    readPackageInfoFromNims(newModuleGraph(newIdentCache(), newConfigRef()), nf, workspace, result)

proc runScript*(file, workspace: string; task="nawabs"; allowSetCommand=false) =
  let cache = newIdentCache()
  let config = newConfigRef()
  var g = newModuleGraph(cache, config)
  discard execScript(g, file, workspace, task)
  if allowSetCommand and config.command != task:
    resetSystemArtifacts(g)
    clearPasses(g)
    for d in nawabsDefines:
      undefSymbol(config.symbols, d)
    mainCommand(newModuleGraph(cache, config))

proc findMainNimFile*(conf: ConfigRef; dir: string): string =
  splitFile(options.findProjectNimFile(conf, dir)).name

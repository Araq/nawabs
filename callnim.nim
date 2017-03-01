#
#
#    Nawabs -- The Anti package manager for Nim
#        (c) Copyright 2016 Andreas Rumpf
#
#    See the file "license.txt", included in this
#    distribution, for details about the copyright.

## This module calls Nim and decides what to do next.

import strutils, os, osproc, streams, pegs
import osutils

let
  pegLineError =
    peg"{[^(]*} '(' {\d+} ', ' {\d+} ') ' ('Error') ':' \s* {.*}"
  pegLineTemplate =
    peg"{[^(]*} '(' {\d+} ', ' {\d+} ') ' 'template/generic instantiation from here'.*"
  pegOtherError = peg"'Error:' \s* {.*}"
  pegSuccess = peg"'Hint: operation successful'.*"
  pegOfInterest = pegLineError / pegOtherError

proc extract(x, prefix, suffix: string): string =
  let s = x.find(prefix)
  if s >= 0:
    let e = x.find(suffix, s+prefix.len)
    if e >= 1: return x.substr(s+prefix.len, e-1)
  return ""

type
  ActionKind* = enum
    Failure,       ## hard failure: unknown problem
    Success,       ## success
    FileMissing
  Action* = object
    k*: ActionKind
    file*: string

proc toNimCommand*(nimExe, cmd: string, args, path: seq[string]): string =
  result = nimExe & " " & cmd & " --noNimblePath"
  for p in path:
    result.add(" -p:")
    result.add(p.quoteShell)
  for i in 0..<args.len:
    result.add(" ")
    result.add args[i]

proc callCompiler*(nimExe, cmd: string, args, path: seq[string]): Action =
  let tmp = toNimCommand(nimExe, cmd, args, path)

  let c = parseCmdLine(tmp)
  var p = startProcess(command=c[0], args=c[1.. ^1],
                       options={poStdErrToStdOut, poUsePath})
  let outp = p.outputStream
  var suc = ""
  var err = ""
  var tmpl = ""
  var x = newStringOfCap(120)
  result.file = ""
  while outp.readLine(x.TaintedString) or running(p):
    result.file.add(x & "\n")
    if x =~ pegOfInterest:
      # `err` should contain the last error/warning message
      err = x
    elif x =~ pegLineTemplate and err == "":
      # `tmpl` contains the last template expansion before the error
      tmpl = x
    elif x =~ pegSuccess:
      suc = x
  close(p)
  result.k = Failure
  var
    msg = ""
    file = ""
    line = 0
    column = 0
    tfile = ""
    tline = 0
    tcolumn = 0
  if tmpl =~ pegLineTemplate:
    tfile = matches[0]
    tline = parseInt(matches[1])
    tcolumn = parseInt(matches[2])
  if err =~ pegLineError:
    file = matches[0]
    line = parseInt(matches[1])
    column = parseInt(matches[2])
    msg = matches[3]
    result.file = msg.extract("cannot open '", "'")
    if result.file.len != 0:
      result.k = FileMissing
  elif err =~ pegOtherError:
    msg = matches[0]
    result.file = msg.extract("cannot open '", "'")
    if result.file.len != 0:
      result.k = FileMissing
  elif suc =~ pegSuccess:
    result.k = Success

discard """
  nimble dump
Reading from config file at C:\Users\Anwender\AppData\Roaming\nimble\nimble.ini
name: "nimx"
version: "0.1"
author: "Yuriy Glukhov"
desc: "GUI framework"
license: "BSD"
skipDirs: "test/android/com.mycompany.MyGame"
skipFiles: ""
skipExt: ""
installDirs: ""
installFiles: ""
installExt: ""
requires: "sdl2 any version, opengl any version, jnim any version, nake any version, closure_compiler any version, jester any version, https://github.com/yglukhov/ttf any version, https://github.com/yglukhov/async_http_request any version"
bin: ""
binDir: ""
srcDir: ""
backend: "c"
"""

type
  NimbleInfo* = object
    backend*: string
    srcDir*: string
    requires*: seq[string]

proc token(s: string; idx: int; lit: var string): int =
  var i = idx
  if i >= s.len: return i
  while s[i] in Whitespace: inc(i)
  lit.setLen 0
  if s[i] in Letters:
    while i < s.len and s[i] notin Whitespace:
      lit.add s[i]
      inc i
    if s[i-1] in {':', ','}:
      # commas are important, colons are not:
      if s[i-1] == ',': dec i
      lit.setLen lit.len-1
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

proc extractNimbleDeps*(nimbleExe, pkg: string): NimbleInfo =
  result.backend = ""
  result.srcDir = ""
  result.requires = @[]
  var tok = ""
  withDir pkg:
    let (dump, _) = execCmdEx(nimbleExe & " dump")
    var i = 0
    while i < dump.len:
      i = token(dump, i, tok)
      case tok
      of "backend":
        i = token(dump, i, tok)
        result.backend = tok
      of "srcDir":
        i = token(dump, i, tok)
        result.srcDir = tok
      of "requires":
        i = token(dump, i, tok)
        result.requires = @[]
        var j = 0
        var r = ""
        var usenext = true
        while j < tok.len:
          j = token(tok, j, r)
          if usenext:
            result.requires.add r
            usenext = false
          if r == ",": usenext = true
      else: discard

proc findProjectNimFile*(pkg: string): string =
  const extensions = [".nims", ".cfg", ".nimcfg", ".nimble"]
  var candidates: seq[string] = @[]
  for k, f in os.walkDir(pkg, relative=true):
    if k == pcFile and f != "config.nims" and f != "nim.cfg":
      let (_, name, ext) = splitFile(f)
      if ext in extensions:
        let x = changeFileExt(pkg / name, ".nim")
        if fileExists(x):
          candidates.add name
  if candidates.len == 1: return candidates[0]
  for c in candidates:
    # nim-foo foo  or  foo  nfoo
    if (pkg in c) or (c in pkg): return c
  return ""

when isMainModule:
  let xx = extractNimbleDeps("nimble.exe", "../../.nimble/pkgs/nimx-0.1")
  for x in xx.requires:
    echo extractFilename x
  withDir "../../.nimble/pkgs":
    echo findProjectNimFile("nimx-0.1")
    echo findProjectNimFile("nake-1.8")


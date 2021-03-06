#
#    Nawabs -- The Anti package manager for Nim
#        (c) Copyright 2017 Andreas Rumpf
#
#    See the file "license.txt", included in this
#    distribution, for details about the copyright.

## This module calls Nim and decides what to do next.

import strutils, os, osproc, streams, pegs

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

proc toNimCommand*(nimExe, args: string, path: seq[string]): string =
  result = nimExe & " --noNimblePath"
  for p in path:
    result.add(" -p:")
    result.add(p.quoteShell)
  result.add ' '
  result.add args

proc callCompiler*(nimExe, args: string, path: seq[string]): Action =
  let tmp = toNimCommand(nimExe, args, path)

  let c = parseCmdLine(tmp)
  var p = startProcess(command=c[0], args=c[1.. ^1],
                       options={poStdErrToStdOut, poUsePath})
  let outp = p.outputStream
  var suc = ""
  var err = ""
  var tmpl = ""
  var x = newStringOfCap(120)
  result.file = ""
  while outp.readLine(x) or running(p):
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
    let e = msg.extract("cannot open '", "'")
    if e.len != 0:
      result.k = FileMissing
      result.file = e
  elif err =~ pegOtherError:
    msg = matches[0]
    let e = msg.extract("cannot open '", "'")
    if e.len != 0:
      result.k = FileMissing
      result.file = e
  elif suc =~ pegSuccess:
    result.k = Success

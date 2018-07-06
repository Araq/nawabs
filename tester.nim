#
#    Nawabs -- The Anti package manager for Nim
#        (c) Copyright 2017 Andreas Rumpf
#
#    See the file "license.txt", included in this
#    distribution, for details about the copyright.

## Tests.
import strutils, os, osutils

template withWs(ws, body) =
  removeDir(ws)
  createDir(ws)
  withDir ws:
    body
  removeDir(ws)

proc naw(s: string) =
  # we go up one directory here as the 'withWs' environment goes down
  # into a testing workspace.
  when defined(windows):
    let n = getCurrentDir() /../ "nawabs.exe"
    exec quoteShell(n) & " " & s
  else:
    exec "../nawabs " & s

proc test1 =
  withWs "testws":
    naw "init"
    naw "build --noquestions c2nim"
    naw "update"
    naw "pinned c2nim"
    naw "refresh"

proc test2 =
  withWs "testws2":
    naw "init"
    naw "clone --noquestions --deps:nimxdeps_ nimx"
    naw "update nimx"

when not defined(onlyTest2):
  test1()
when not defined(onlyTest1):
  test2()

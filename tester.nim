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
  createDir(ws / "config")
  copyExe("nawabs".exe, ws / "nawabs".exe)
  copyFile("config/roots.nims", ws / "config/roots.nims")
  withDir ws:
    body
  removeDir(ws)

proc naw(s: string) = exec "nawabs " & s

proc main =
  withWs "testws":
    naw "init"
    naw "build --noquestions c2nim"
    naw "update"
    naw "pinned c2nim"
    naw "refresh"
  withWs "testws2":
    naw "init"
    naw "clone --noquestions --deps:nimxdeps_ nimx"
    naw "update nimx"

main()

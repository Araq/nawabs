#
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

proc main =
  withWs "testws":
    exec "nawabs init"
    exec "nawabs build --noquestions c2nim"
  withWs "testws2":
    exec "nawabs init"
    exec "nawabs clone --noquestions --deps:nimxdeps_ nimx"

main()

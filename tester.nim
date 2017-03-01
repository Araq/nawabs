#
#
#    Nawabs -- The Anti package manager for Nim
#        (c) Copyright 2017 Andreas Rumpf
#
#    See the file "license.txt", included in this
#    distribution, for details about the copyright.

## Tests.
import strutils, os, osutils

proc main =
  createDir("testws")
  withDir "testws":
    exec "nawabs init"
    exec "nawabs build c2nim"
  removeDir("testws")

main()

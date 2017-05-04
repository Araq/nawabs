#
#    Nawabs -- The Anti package manager for Nim
#        (c) Copyright 2017 Andreas Rumpf
#
#    See the file "license.txt", included in this
#    distribution, for details about the copyright.

import os, osproc, parseopt, strutils
import osutils

proc main =
  var p = initOptParser()
  var action, file, rest = ""
  while true:
    next(p)
    case p.kind
    of cmdArgument:
      if action.len == 0: action = p.key.normalize
      elif file.len == 0: file = p.key
      else:
        rest = cmdLineRest(p)
        break
    of cmdLongOption, cmdShortOption:
      discard "just ignore options for now"
    of cmdEnd: break
  case action
  of "":
    quit "[FakeNimble] version 1.0"
  of "path":
    exec "nawabs path " & quoteShell(file) & " " & rest
  of "c", "cpp", "js", "objc":
    exec "nim " & action & " " & quoteShell(file)
  else:
    quit "[FakeNimble] don't know how to emulate " & action

main()

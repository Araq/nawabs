#
#
#    Nawabs -- The Anti package manager for Nim
#        (c) Copyright 2016 Andreas Rumpf
#
#    See the file "license.txt", included in this
#    distribution, for details about the copyright.

## OS utilities like 'exec' and 'withDir'.

import os, strutils

proc error*(msg: string) = quit "[Error] " & msg

proc exec*(cmd: string) =
  if execShellCmd(cmd) != 0:
    error "exernal program failed: " & cmd

template withDir*(dir, body) =
  let oldDir = getCurrentDir()
  try:
    setCurrentDir(dir)
    body
  finally:
    setCurrentDir(oldDir)

proc isUrl*(x: string): bool =
  x.startsWith("git://") or x.startsWith("https://") or x.startsWith("http://")

proc cloneUrl*(url: string; cloneUsingHttps: bool) =
  var modUrl =
    if url.startsWith("git://") and cloneUsingHttps:
      "https://" & url[6 .. ^1]
    else: url

  # github + https + trailing url slash causes a
  # checkout/ls-remote to fail with Repository not found
  if modUrl.contains("github.com") and modUrl.endswith("/"):
    modUrl = modUrl[0 .. ^2]

  if execShellCmd("git ls-remote " & modUrl) == QuitSuccess:
    exec "git clone " & modUrl
  elif execShellCmd("hg identify " & modUrl) == QuitSuccess:
    exec "hg clone " & modUrl
  else:
    error "Unable to identify url: " & modUrl

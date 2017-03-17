#
#    Nawabs -- The Anti package manager for Nim
#        (c) Copyright 2017 Andreas Rumpf
#
#    See the file "license.txt", included in this
#    distribution, for details about the copyright.

## OS utilities like 'exec' and 'withDir'.

import os, strutils, osproc

proc error*(msg: string) =
  when defined(debug):
    writeStackTrace()
  quit "[Error] " & msg

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

proc cloneUrl*(url, dest: string; cloneUsingHttps: bool) =
  var modUrl =
    if url.startsWith("git://") and cloneUsingHttps:
      "https://" & url[6 .. ^1]
    else: url

  # github + https + trailing url slash causes a
  # checkout/ls-remote to fail with Repository not found
  if modUrl.contains("github.com") and modUrl.endswith("/"):
    modUrl = modUrl[0 .. ^2]

  let (_, exitCode) = execCmdEx("git ls-remote --quiet --tags " & modUrl)
  if exitCode == QuitSuccess:
    exec "git clone " & modUrl & " " & dest
  else:
    let (_, exitCode) = execCmdEx("hg identify " & modUrl)
    if exitCode == QuitSuccess:
      exec "hg clone " & modUrl & " " & dest
    else:
      error "Unable to identify url: " & modUrl

proc exe*(f: string): string =
  result = addFileExt(f, ExeExt)
  when defined(windows):
    result = result.replace('/','\\')

proc tryExec*(cmd: string): bool =
  echo(cmd)
  result = execShellCmd(cmd) == 0

proc safeRemove*(filename: string) =
  if existsFile(filename): removeFile(filename)

proc copyExe*(source, dest: string) =
  safeRemove(dest)
  copyFile(dest=dest, source=source)
  inclFilePermissions(dest, {fpUserExec})

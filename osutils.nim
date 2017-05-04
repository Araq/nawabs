#
#    Nawabs -- The Anti package manager for Nim
#        (c) Copyright 2017 Andreas Rumpf
#
#    See the file "license.txt", included in this
#    distribution, for details about the copyright.

## OS utilities like 'exec' and 'withDir'.

import os, strutils, osproc, securehash

proc error*(msg: string) =
  when defined(debug):
    writeStackTrace()
  quit "[Error] " & msg

proc exec*(cmd: string; attempts=0) =
  for i in 0..attempts:
    if execShellCmd(cmd) == 0: return
    if i < attempts: os.sleep(4000)
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
  var isgithub = false
  if modUrl.contains("github.com") and modUrl.endswith("/"):
    modUrl = modUrl[0 .. ^2]
    isgithub = true

  let (_, exitCode) = execCmdEx("git ls-remote --quiet --tags " & modUrl)
  var xcode = exitCode
  if isgithub and exitCode != QuitSuccess:
    # retry multiple times to avoid annoying github timeouts:
    for i in 0..10:
      os.sleep(4000)
      xcode = execCmdEx("git ls-remote --quiet --tags " & modUrl)[1]
      if xcode == QuitSuccess: break

  if xcode == QuitSuccess:
    # retry multiple times to avoid annoying github timeouts:
    let cmd = "git clone " & modUrl & " " & dest
    for i in 0..10:
      if execShellCmd(cmd) == 0: return
      os.sleep(4000)
    error "exernal program failed: " & cmd
  elif not isgithub:
    let (_, exitCode) = execCmdEx("hg identify " & modUrl)
    if exitCode == QuitSuccess:
      exec "hg clone " & modUrl & " " & dest
    else:
      error "Unable to identify url: " & modUrl
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

proc fileChanged*(file, hashdir: string): bool =
  try:
    var currentHash = secureHashFile(file)
    var f: File
    let hashFile = hashdir / $secureHash(expandFilename(file)) & ".sha1"
    if open(f, hashFile, fmRead):
      let oldHash = parseSecureHash(f.readLine())
      close(f)
      result = oldHash != currentHash
    else:
      result = true
    if result:
      if open(f, hashFile, fmWrite):
        f.writeLine($currentHash)
        close(f)
  except IOError, OSError:
    result = true

template rule*(d, body: untyped) =
  const deps {.inject.} = d
  var change = false
  for x in deps:
    if fileChanged(x):
      change = true
      # we must not break here so that every file gets a fresh timestamp
      # anyway
  if change:
    body

# Utilities for recipe files.

from os import `/`

template withDir*(dir, body) =
  let oldDir = getCurrentDir()
  try:
    setCurrentDir(dir)
    body
  finally:
    setCurrentDir(oldDir)

template gitDep*(name, url, commit) =
  if not dirExists(name / ".git"): exec "git clone " & url
  withDir name:
    exec "git checkout " & commit

template hgDep*(name, url, commit) =
  if not dirExists(name / ".hg"): exec "hg clone " & url
  withDir name:
    exec "hg update -c " & commit

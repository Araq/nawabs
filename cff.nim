

import os, strutils, parseutils
from osproc import quoteShell

type
  PrefixMatch* {.pure.} = enum
    None,   ## no prefix detected
    Abbrev  ## prefix is an abbreviation of the symbol
    Substr, ## prefix is a substring of the symbol
    Prefix, ## prefix does match the symbol
    Exact,  ## exact match

proc prefixMatch*(p, s: string): PrefixMatch =
  template eq(a, b): bool = a.toLowerAscii == b.toLowerAscii
  if p.len > s.len: return PrefixMatch.None
  var i = 0
  let L = s.len
  # check for prefix/contains:
  while i < L:
    if s[i] == '_': inc i
    if eq(s[i], p[0]):
      var ii = i+1
      var jj = 1
      while ii < L and jj < p.len:
        if p[jj] == '_': inc jj
        if s[ii] == '_': inc ii
        if not eq(s[ii], p[jj]): break
        inc ii
        inc jj
      if jj >= p.len:
        if i == 0:
          if ii >= s.len: return PrefixMatch.Exact
          return PrefixMatch.Prefix
        else: return PrefixMatch.Substr
    inc i
  # check for abbrev:
  if eq(s[0], p[0]):
    i = 1
    var j = 1
    while i < s.len:
      if s[i] == '_' and i < s.len-1:
        if j < p.len and eq(p[j], s[i+1]): inc j
        else: return PrefixMatch.None
      if s[i] in {'A'..'Z'} and s[i-1] notin {'A'..'Z'}:
        if j < p.len and eq(p[j], s[i]): inc j
        else: return PrefixMatch.None
      inc i
    if j >= p.len:
      return PrefixMatch.Abbrev
    else:
      return PrefixMatch.None
  return PrefixMatch.None

when defined(testing):
  import macros

  macro check(val, body: untyped): untyped =
    result = newStmtList()
    expectKind body, nnkStmtList
    for b in body:
      expectKind b, nnkPar
      expectLen b, 2
      let p = b[0]
      let s = b[1]
      result.add quote do:
        echo prefixMatch(`p`, `s`) == `val`

  check PrefixMatch.Exact:
    ("abc", "abc")
    ("abc", "a_b_c")

  check PrefixMatch.Prefix:
    ("a", "abc")
    ("xyz", "X_yzzzZe")

  check PrefixMatch.Substr:
    ("b", "abc")
    ("abc", "fooabcabc")
    ("abC", "foo_AB_c")

  check PrefixMatch.Abbrev:
    ("abc", "AxxxBxxxCxxx")
    ("xyz", "X_yabcZe")

  check PrefixMatch.None:
    ("foobar", "afkslfjd_as")
    ("xyz", "X_yuuZuuZe")
    ("ru", "remotes")


type
  Cand = object
    m: PrefixMatch
    d: int
    p: string
  Keyw = object
    name, subdir: string
    parts: seq[string]

proc search(path: string; k: var Keyw; results: var seq[Cand]; partsLen: int; depth=0) =
  for pc, f in os.walkDir(path, relative=true):
    let match = prefixMatch(k.name, f)
    if match != PrefixMatch.None and partsLen == 0:
      results.add(Cand(m: match, d: depth, p: path / f))
    case pc
    of pcFile, pcLinkToFile:
      discard
    of pcDir, pcLinkToDir:
      let idx = find(k.parts, f)
      if idx >= 0:
        k.parts[idx] = "" # disable for recursion
        search(path / f, k, results, partsLen-1, depth+1)
        k.parts[idx] = f
      else:
        search(path / f, k, results, partsLen, depth+1)

proc pickBest*[T](x: openArray[T]; cmp: proc(a, b: T): int): int =
  ## add to algorithm stdlib?
  result = 0
  for i in 1..high(x):
    if cmp(x[i], x[result]) < 0:
      result = i

let curdir = getCurrentDir()

proc splitKeyw(s: string): Keyw =
  result = Keyw(name: s, subdir: "", parts: @[])
  var a = s.split({'/', '\\'})
  var start = 0
  while start < a.len:
    if not a[start].startsWith"..": break
    var x: int = 0
    discard a[start].parseInt(x, 2)
    if x > 0:
      for i in 1..x:
        if result.subdir.len > 0: result.subdir.add DirSep
        result.subdir.add ".."
    else:
      if result.subdir.len > 0: result.subdir.add DirSep
      result.subdir.add a[start]
    inc start
  if start == 0: result.subdir = curdir
  for i in start..a.len-2:
    result.parts.add a[i]
  result.name = a[^1]

proc complete(s: string): string =
  if not s.endsWith("_"): return quoteShell(s)
  var cands: seq[Cand] = @[]
  var k = splitKeyw(s.substr(0, s.len-2))
  search(k.subdir, k, cands, k.parts.len)
  if cands.len == 0:
    quit "cannot expand: " & s
  let best = pickBest(cands, proc (a, b: Cand): int =
    result = ord(b.m) - ord(a.m)
    if result != 0: return result
    result = a.d - b.d
    if result != 0: return result
    result = a.p.len - b.p.len
    if result != 0: return result
  )

  result = cands[best].p
  if result.startsWith(curdir & DirSep):
    result = result.substr(curdir.len+1)
  return quoteShell(result)

proc main =
  let cnt = os.paramCount()
  if cnt == 0:
    quit "Usage: cff [--confirm] <command to complete>"
  var i = 1
  var confirm = false
  if paramStr(1) == "--confirm":
    confirm = true
    inc i
  var cmd = ""
  while i <= cnt:
    cmd.add ' '
    cmd.add complete(paramStr(i))
    inc i
  if confirm:
    echo "[cff] exec: ", cmd, " (y/n?)"
    confirm = stdin.readline() == "y"
  else:
    confirm = true
  if confirm:
    let exitCode = execShellCmd(cmd)
    echo "[cff] exitcode: ", exitCode

when not defined(testing):
  main()

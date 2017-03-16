#
#
#    Nawabs -- The Anti package manager for Nim
#        (c) Copyright 2016 Andreas Rumpf
#
#    See the file "license.txt", included in this
#    distribution, for details about the copyright.

## Package management for nawabs. Note that interally *package* is used for
## the JSON description (aka what is known to exist in the internet) and
## *project* is used to refer to some directory within the workspace.

import strutils except toLower
from unicode import toLower

import os, json, osutils

type
  Package* = ref object
    # Required fields in a package.
    name*: string
    url*: string # Download location.
    license*: string
    downloadMethod*: string
    description*: string
    tags*: seq[string] # Even if empty, always a valid non nil seq. \
    # From here on, optional fields set to the empty string if not available.
    version*: string
    dvcsTag*: string
    web*: string # Info url for humans.
  Project* = object
    name*: string
    subdir*: string # always relative to the workspace

proc toPath*(p: Project): string = p.subdir / p.name

proc assumePackage*(name, url: string): Package =
  new result
  result.name = name
  result.url = url

proc optionalField(obj: JsonNode, name: string, default = ""): string =
  if hasKey(obj, name):
    if obj[name].kind == JString:
      return obj[name].str
    else:
      error("Corrupted packages.json file. " & name &
            " field is of unexpected type.")
  else:
    return default

proc requiredField(obj: JsonNode, name: string): string =
  result = optionalField(obj, name, nil)
  if result == nil:
    error("Package in packages.json file does not contain a " & name & " field.")

proc fromJson*(obj: JSonNode): Package =
  new result
  result.name = obj.requiredField("name")
  result.version = obj.optionalField("version")
  result.url = obj.requiredField("url")
  result.downloadMethod = obj.requiredField("method")
  result.dvcsTag = obj.optionalField("dvcs-tag")
  result.license = obj.requiredField("license")
  result.tags = @[]
  for t in obj["tags"]:
    result.tags.add(t.str)
  result.description = obj.requiredField("description")
  result.web = obj.optionalField("web")

proc echoPackage*(pkg: Package) =
  echo(pkg.name & ":")
  echo("  url:         " & pkg.url & " (" & pkg.downloadMethod & ")")
  echo("  tags:        " & pkg.tags.join(", "))
  echo("  description: " & pkg.description)
  echo("  license:     " & pkg.license)
  if pkg.web.len > 0:
    echo("  website:     " & pkg.web)

proc search*(pkgList: seq[Package]; terms: seq[string]) =
  var found = false
  template onFound =
    echoPackage(pkg)
    echo(" ")
    found = true
    break forPackage

  for pkg in pkgList:
    if terms.len > 0:
      block forPackage:
        for term in terms:
          let word = term.toLower
          # Search by name.
          if word in pkg.name.toLower:
            onFound()
          # Search by tag.
          for tag in pkg.tags:
            if word in tag.toLower:
              onFound()
    else:
      echoPackage(pkg)
      echo(" ")

  if not found and terms.len > 0:
    echo("No package found.")

type PkgCandidates* = array[3, seq[Package]]

proc determineCandidates*(pkgList: seq[Package];
                         terms: seq[string]): PkgCandidates =
  result[0] = @[]
  result[1] = @[]
  result[2] = @[]
  for pkg in pkgList:
    block termLoop:
      for term in terms:
        let word = term.toLower
        if word == pkg.name.toLower:
          result[0].add pkg
          break termLoop
        elif word in pkg.name.toLower:
          result[1].add pkg
          break termLoop
        else:
          for tag in pkg.tags:
            if word in tag.toLower:
              result[2].add pkg
              break termLoop

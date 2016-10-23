

proc download(url, dest: string) =
  exec "curl " & url & " --output " & dest

#for now disabled:
#download("https://github.com/nim-lang/packages/raw/master/packages.json", "packages.json")
download("http://irclogs.nim-lang.org/packages.json", "packages.json")
#download("http://nim-lang.org/nimble/packages.json", "packages.json")



proc download(url, dest: string) =
  exec "curl " & url & " --output " & dest

exec("git clone https://github.com/nim-lang/packages packages")

#for now disabled:
#download("https://github.com/nim-lang/packages/raw/master/packages.json", "packages.json")
#download("https://irclogs.nim-lang.org/packages.json", "packages.json")
#download("http://nim-lang.org/nimble/packages.json", "packages.json")

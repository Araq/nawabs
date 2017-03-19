
include "../recipe_utils"

if dirExists("packages"):
  withDir("packages"):
    exec("git pull")
else:
  exec("git clone https://github.com/nim-lang/packages packages")

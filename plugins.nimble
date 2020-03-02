# Package

version       = "0.1.0"
author        = "genotrance"
description   = "Plugin system for Nim"
license       = "MIT"
srcDir        = "src"

# Dependencies

requires "nim >= 0.20.2"

import strformat

let
  flags = "--threads:on -o:html/ --project --index:on"

task docs, "Doc generation":
  exec &"nim doc {flags} src/plugins.nim"
  exec &"nim doc {flags} src/plugins/api.nim"
  exec &"nim buildIndex -o:html/theindex.html html/"

task docsPublish, "Doc generation and publish":
  docsTask()
  exec "ghp-import --no-jekyll -fp html"

task test, "Test all":
  let
    expected = """Plugin 'libplg1' dependency 'libplg2' not loaded
Plugin 'libplg2' loaded (plg2test)
Plugin1 loaded
plg2test: testparam
Plugin1: testreturn
Plugin 'libplg1' loaded ()
Plugin2 ready
Plugin1 ready
Plugin 'libplg2' unloaded
Plugin1 unloading
Plugin 'libplg1' unloaded"""

  exec "nim c tests/tmain"
  let (outp, errC) = gorgeEx("./tests/tmain quit")

  doAssert outp == expected and errC == 0, &"""

Expected:
{expected}

Output:
{outp}

Error: {errC}
"""

  docsTask()
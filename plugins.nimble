# Package

version       = "0.1.0"
author        = "genotrance"
description   = "Plugin system for Nim"
license       = "MIT"
srcDir        = "src"

# Dependencies

requires "nim >= 0.20.2"

import os, strformat, strutils

let
  flags = "--threads:on -o:html/ --project --index:on"
  expected = """Plugin 'libplg1' dependency 'libplg2' not loaded
Plugin 'libplg2' loaded (plg2test)
Plugin1 loaded
plg2test: testparam
Plugin1: testreturn
Plugin 'libplg1' loaded ()
Plugin1 ready
Plugin2 ready
Plugin 'libplg1' unloaded
Plugin 'libplg2' unloaded"""

task docs, "Doc generation":
  exec &"nim doc {flags} src/plugins.nim"
  exec &"nim doc {flags} src/plugins/api.nim"
  exec &"nim buildIndex -o:html/theindex.html html/"

task docsPublish, "Doc generation and publish":
  docsTask()
  exec "ghp-import --no-jekyll -fp html"

task clean, "Clean up":
  rmFile("tests/tmain" & ExeExt)
  let
    dlext = DynlibFormat.splitFile().ext
  for file in listFiles("tests/test1"):
    if file.splitFile().ext == dlext:
      rmFile(file)
  rmDir("html")

task test, "Test all":
  cleanTask()
  for mode in ["", "-d:binary"]:
    exec &"nim c {mode} tests/tmain"
    let (outp, errC) = gorgeEx("./tests/tmain quit")
    doAssert outp.strip() == expected and errC == 0, &"""

Expected:
{expected}

Output:
{outp}

Error: {errC}
"""

  docsTask()
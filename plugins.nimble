# Package

version       = "0.1.2"
author        = "genotrance"
description   = "Plugin system for Nim"
license       = "MIT"
srcDir        = "src"

# Dependencies

requires "nim >= 1.0.6"

import os, strformat, strutils

let
  flags = "--threads:on -o:html/ --project --index:on"
  expected = """Plugin 'plg1' dependency 'plg2' not loaded
Plugin 'plg2' loaded (plg1unload, plg2test)
Plugin1 loaded
plg2test: test1param
Plugin1: test2return
Plugin 'plg1' loaded (plg1test)
Plugin1 ready
Plugin2 ready
plg1test: test2param
Plugin2: test1return
notify: testmain
plist: plg1 plg2
Plugin 'plg1' unloaded
Plugin1 loaded
plg2test: test1param
Plugin1: test2return
Plugin 'plg1' loaded (plg1test)
plg2test: testmain
Main: test2return
Plugin 'plg1' unloaded
plg1unload: plg1
Plugin 'plg2' unloaded"""

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
  for build in ["", "-d:release"]:
    cleanTask()
    for mode in ["", "-d:binary"]:
      exec &"nim c {build} {mode} tests/tmain"
      exec "ls -l tests"
      let (outp, errC) = gorgeEx("./tests/tmain quit")
      exec "ls -l tests/test1"
      doAssert outp.strip() == expected and errC == 0, &"""

Expected:
{expected}

Output:
{outp}

Error: {errC}
"""

  docsTask()
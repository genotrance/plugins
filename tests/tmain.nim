import os

import plugins

const
  base = currentSourcePath.parentDir()

proc start*(cmds: seq[string] = @["quit"]) =
  for path in ["test1"]:
    var
      manager = initPlugins(@[base / path], cmds)

    while manager.run != stopped:
      manager.syncPlugins()

    manager.stopPlugins()

when isMainModule:
  start()
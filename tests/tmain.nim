import os

import plugins

const
  base = currentSourcePath.parentDir()

proc start*(cmds: seq[string] = @["quit"]) =
  for path in ["test1"]:
    var
      ctx = initPlugins(@[base / path], cmds)

    while ctx.run != stopped:
      ctx.syncPlugins()

    ctx.stopPlugins()

when isMainModule:
  start()
import os, strutils

import plugins

const
  base = currentSourcePath.parentDir()

proc start*(cmds: seq[string] = @[]) =
  for path in ["test1"]:
    var
      manager = initPlugins(@[base / path], cmds)

    while manager.run != stopped:
      syncPlugins(manager)

      if manager.ready:
        notify(manager, "notify: testmain")
        echo "plist: " & plist(manager).join(" ")
        punload(manager, newCmdData("plg1"))
        pload(manager, newCmdData("plg1"))
        while getPlugin(manager, "plg1").isNil:
          syncPlugins(manager)
        var
          cmd = newCmdData("testmain")
        call(manager, "plg2test", cmd)
        echo "Main: " & cmd.returned[0]
        callPlugin(manager, "plg2", "plg1unload", newCmdData(""))
        break

    stopPlugins(manager)

when isMainModule:
  start()
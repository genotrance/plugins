import plugins/api

proc plg2test(plugin: Plugin, cmd: CmdData) {.pluginCallback.} =
  echo "plg2test: " & cmd.params[0]
  cmd.returned.add "test2return"

proc plg1unload(plugin: Plugin, cmd: CmdData) {.pluginCallback.} =
  punload(plugin.manager, newCmdData("plg1"))
  notify(plugin.manager, "plg1unload: plg1")

pluginLoad()

pluginReady:
  echo "Plugin2 ready"
  var
    cmd2 = newCmdData("test2param")
  callPlugin(plugin.manager, "plg1", "plg1test", cmd2)
  echo "Plugin2: " & cmd2.returned[0]

import plugins/api

proc plg1test(plugin: Plugin, cmd: CmdData) {.pluginCallback.} =
  echo "plg1test: " & cmd.params[0]
  cmd.returned.add "test1return"

pluginLoad:
  echo "Plugin1 loaded"
  var
    cmd = newCmdData("plg2test test1param")
  callCommand(plugin.manager, cmd)
  echo "Plugin1: " & cmd.returned[0]

pluginReady:
  echo "Plugin1 ready"

pluginDepends(@["plg2"])
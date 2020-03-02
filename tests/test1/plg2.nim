import plugins/api

proc plg2test(plg: Plugin, cmd: CmdData) {.pluginCallback.} =
  echo "plg2test: " & cmd.params[0]
  cmd.returned.add "testreturn"

pluginLoad()

pluginReady:
  echo "Plugin2 ready"
import plugins/api

pluginLoad:
  echo "Plugin1 loaded"
  var
    cmd = newCmdData("plg2test testparam")
  plg.ctx.handleCommand(plg.ctx, cmd)
  echo "Plugin1: " & cmd.returned[0]

pluginReady:
  echo "Plugin1 ready"

pluginDepends(@["plg2"])
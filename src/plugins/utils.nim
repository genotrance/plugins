import os, strformat, strutils

include "."/globals

template tryCatch(body: untyped) {.dirty.} =
  var
    ret {.inject.} = true
  try:
    body
  except:
    ret = false
    when not defined(release):
      raise getCurrentException()

proc newShared*[T](): ptr T =
  ## Allocate memory of type T in shared memory
  result = cast[ptr T](allocShared0(sizeof(T)))

proc freeShared*[T](s: var ptr T) =
  ## Free shared memory of type T
  s.deallocShared()
  s = nil

proc getManagerData*[T](plugin: Plugin): T =
  ## Use this proc to store any type T in the plugin manager. Data will persist
  ## across plugin unload/reload and can be used to store information that
  ## requires such persistence.
  ##
  ## Only first call allocates memory. Subsequent calls returns the object already
  ## allocated before.
  ##
  ## Ensure `freeManagerData()` is called to free this memory.
  ##
  ## .. code-block:: nim
  ##
  ##   import plugins/api
  ##
  ##   type
  ##     PlgData = object
  ##       intField: int
  ##
  ##   pluginLoad:
  ##     var pData = getManagerData[PlgData](plugin)
  ##     pData.intField = 5
  ##
  ##   pluginTick:
  ##     var pData = getManagerData[PlgData](plugin)
  ##     pData.intField += 1
  if not plugin.manager.pluginData.hasKey(plugin.name):
    var
      data = new(T)
    GC_ref(data)
    plugin.manager.pluginData[plugin.name] = cast[pointer](data)

  result = cast[T](plugin.manager.pluginData[plugin.name])

proc freeManagerData*[T](plugin: Plugin) =
  ## Use this proc to free memory allocated in the plugin manager with `getManagerData()`
  ##
  ## .. code-block:: nim
  ##
  ##   import plugins/api
  ##
  ##   type
  ##     PlgData = object
  ##       intField: int
  ##
  ##   proc reloadAll(plugin: Plugin, cmd: CmdData) {.pluginCallback.} =
  ##     freeManagerData[PlgData](plugin)
  ##     var plgData = getManagerData[PlugData](plugin)
  if plugin.manager.pluginData.hasKey(plugin.name):
    var
      data = cast[T](plugin.manager.pluginData[plugin.name])
    GC_unref(data)

    plugin.manager.pluginData.del(plugin.name)

proc getPluginData*[T](plugin: Plugin): T =
  ## Use this proc to store any type T within the plugin. Data will be accessible
  ## across plugin callbacks but will be invalid after plugin unload.
  ##
  ## Only first call allocates memory. Subsequent calls returns the object already
  ## allocated before.
  ##
  ## Ensure `freePluginData()` is called to free this memory before plugin unload.
  ##
  ## .. code-block:: nim
  ##
  ##   import plugins/api
  ##
  ##   type
  ##     PlgData = object
  ##       intField: int
  ##
  ##   pluginLoad:
  ##     var pData = getPluginData[PlgData](plugin)
  ##     pData.intField = 5
  ##
  ##   pluginTick:
  ##     var pData = getManagerData[PlgData](plugin)
  ##     pData.intField += 1
  if plugin.pluginData.isNil:
    var
      data = new(T)
    GC_ref(data)
    plugin.pluginData = cast[pointer](data)

  result = cast[T](plugin.pluginData)

proc freePluginData*[T](plugin: Plugin) =
  ## Use this proc to free memory allocated within the plugin with `getPluginData()`
  ##
  ## .. code-block:: nim
  ##
  ##   import plugins/api
  ##
  ##   type
  ##     PlgData = object
  ##       intField: int
  ##
  ##   pluginUnload:
  ##     freePluginData[PlgData](plugin)
  if not plugin.pluginData.isNil:
    var
      data = cast[T](plugin.pluginData)
    GC_unref(data)

    plugin.pluginData = nil

proc splitCmd*(command: string): tuple[name, val: string] =
  ## Split "xxx yyy zzz" into "xxx" and "yyy zzz"
  let
    spl = command.strip().split(" ", maxsplit=1)
    name = spl[0]
    val = if spl.len == 2: spl[1].strip() else: ""

  return (name, val)

proc newCmdData*(command: string): CmdData =
  ## Create new CmdData with `command` split using `os.parseCmdLine()`
  ## and stored in CmdData.params for processing by receiving callback
  result = new(CmdData)
  result.params = command.parseCmdLine()

proc getVersion*(): string =
  ## Get the Git version hash - repo state at compile time
  const
    execResult = gorgeEx("git rev-parse HEAD")
  when execResult[0].len > 0 and execResult[1] == 0:
    result = execResult[0].strip()
  else:
    result ="couldn't determine git hash"

proc getVersionBanner*(): string =
  ## Get the version banner which includes Git hash if any and compiler
  ## version used to build main application
  let
    version = getVersion()
  result = &"Plugin {version}\ncompiled on {CompileDate} {CompileTime} with Nim v{NimVersion}"

proc quit*(manager: PluginManager) =
  ## Stop the plugin manager
  manager.run = stopped

when not declared(API) or defined(nimdoc):
  # Callbacks that are compiled into main application

  import sequtils

  proc notify*(manager: PluginManager, msg: string) =
    ## Invoke `pluginNotify()` across all plugins with `msg` as argument
    var
      cmd = new(CmdData)
    cmd.params.add msg
    cast[proc(manager: PluginManager, cmd: CmdData) {.nimcall.}](
      manager.callbacks["notifyPlugins"])(manager, cmd)

  proc plist*(manager: PluginManager): seq[string] =
    ## Return a list of all loaded plugins
    for pl in manager.plugins.keys():
      result.add pl.extractFilename

  proc pload*(manager: PluginManager, cmd: CmdData) =
    ## Reload all plugins if `CmdData.params` is empty, else (re)load
    ## the plugin(s) specified
    if cmd.params.len > 0:
      for i in 0 .. cmd.params.len-1:
        gMainToMon.send("load")
        gMainToMon.send(cmd.params[i])
    else:
      gMainToMon.send("loadall")

  proc punload*(manager: PluginManager, cmd: CmdData) =
    ## Unload all plugins if `CmdData.params` is empty, else unload
    ## the plugin(s) specified
    let
      unloadPlugin = cast[proc(manager: PluginManager, name: string, force = true) {.nimcall.}](
        manager.callbacks["unloadPlugin"])

    if cmd.params.len > 0:
      for i in 0 .. cmd.params.len-1:
        if manager.plugins.hasKey(cmd.params[i]):
          unloadPlugin(manager, cmd.params[i])
        else:
          notify(manager, &"Plugin '{cmd.params[i]}' not found")
    else:
      let
        pkeys = toSeq(manager.plugins.keys())
      for pl in pkeys:
        unloadPlugin(manager, pl)

  proc presume*(manager: PluginManager) =
    ## Resume plugin monitor - monitor plugin files and recompile
    ## and reload if changed
    gMainToMon.send("executing")
    notify(manager, &"Plugin monitor resumed")

  proc ppause*(manager: PluginManager) =
    ## Pause the plugin monitor - plugin files are not monitored
    ## for changes
    ##
    ## This helps during development of plugins if source files
    ## need to be edited for an extended period of time and saving
    ## incomplete/broken code to disk should not lead to recompile
    ## and reload.
    gMainToMon.send("paused")
    notify(manager, &"Plugin monitor paused")

  proc pstop*(manager: PluginManager) =
    ## Stop the plugin monitor thread - loaded plugins will stay
    ## loaded but the monitor thread will exit and no longer monitor
    ## plugins for changes
    gMainToMon.send("stopped")
    notify(manager, &"Plugin monitor exited")

  proc getPlugin*(manager: PluginManager, name: string): Plugin =
    ## Get plugin by name - if no such plugin, `result.isNil` will be true
    if manager.plugins.hasKey(name):
      result = manager.plugins[name]

  proc getCallback*(manager: PluginManager, pname, callback: string): proc(plugin: Plugin, cmd: CmdData) =
    ## Get custom callback by plugin name and callback name
    ##
    ## .. code-block:: nim
    ##
    ##   import plugins
    ##
    ##   var
    ##     cmd = newCmdData("callbackparam")
    ##     plugin = getPlugin("plugin1")
    ##     callback = getCallback(manager, "plugin1", "callbackname")
    ##   if not callback.isNil:
    ##     callback(plugin, cmd)
    let
      plugin = getPlugin(manager, pname)
    if not plugin.isNil:
      if callback in plugin.cindex:
        result = plugin.callbacks[callback]

  proc call*(manager: PluginManager, callback: string, cmd: CmdData) =
    ## Invoke custom callback across all plugins by callback name
    ##
    ## `CmdData.params` should only include the parameters to pass to the callback
    ##
    ## .. code-block:: nim
    ##
    ##   import plugins
    ##
    ##   var
    ##     cmd = newCmdData("callbackparam")
    ##   call(manager, "callbackname", cmd)
    if callback.len != 0:
      let
        pkeys = toSeq(manager.plugins.keys())
      for pl in pkeys:
        var
          plugin = manager.plugins[pl]
        if callback in plugin.cindex:
          tryCatch:
            plugin.callbacks[callback](plugin, cmd)
          if not ret:
            notify(manager, getCurrentExceptionMsg() & &"Plugin '{plugin.name}' crashed in '{callback}()'")
          elif cmd.failed:
            notify(manager, &"Plugin '{plugin.name}' failed in '{callback}()'")
          else:
            cmd.failed = false
          break

  proc callPlugin*(manager: PluginManager, pname, callback: string, cmd: CmdData) =
    ## Invoke custom callbacks by plugin name and callback name
    ##
    ## `CmdData.params` should only include the parameters to pass to the callback
    ##
    ## .. code-block:: nim
    ##
    ##   import plugins
    ##
    ##   var
    ##     cmd = newCmdData("callbackparam")
    ##   callPlugin(manager, "plugin1", "callbackname", cmd)
    let
      cbplugin = manager.getPlugin(pname)
    if not cbplugin.isNil:
      if cbplugin.callbacks.hasKey(callback):
        cbplugin.callbacks[callback](cbplugin, cmd)

  proc callCommand*(manager: PluginManager, cmd: CmdData) =
    ## Invoke custom callbacks in a command line format
    ##
    ## `CmdData.params` should include the callback name and will be
    ## searched across all loaded plugins.
    ##
    ## .. code-block:: nim
    ##
    ##   import plugins
    ##
    ##   var
    ##     cmd = newCmdData("callbackname callbackparam")
    ##   callCommand(manager, cmd)
    if cmd.params.len != 0:
      let
        cmdName = cmd.params[0]
      case cmdName:
        of "quit", "exit":
          quit(manager)
        of "notify":
          if cmd.params.len > 1:
            notify(manager, cmd.params[1 .. ^1].join(" "))
          else:
            cmd.failed = true
        of "getVersion":
          cmd.returned.add getVersion()
        of "getVersionBanner":
          cmd.returned.add getVersionBanner()
        of "plist":
          cmd.returned.add plist(manager)
        of "preload", "pload":
          cmd.params.delete(0)
          pload(manager, cmd)
        of "punload":
          cmd.params.delete(0)
          punload(manager, cmd)
        of "presume":
          presume(manager)
        of "ppause":
          ppause(manager)
        of "pstop":
          pstop(manager)
        else:
          cmd.params.delete(0)
          call(manager, cmdName, cmd)
    else:
      cmd.failed = true

  proc getCommandResult*(manager: PluginManager, command: string): seq[string] =
    ## Shortcut for running a callback defined in another plugin and getting
    ## all string values returned
    ##
    ## `CmdData.params` should include the callback name and will be
    ## searched across all loaded plugins.
    ##
    ## .. code-block:: nim
    ##
    ##   import plugins/api
    ##
    ##   proc somecallback(plugin: Plugin, cmd: CmdData) {.pluginCallback.} =
    ##     var
    ##       ret = getCommandResult(plugin, "othercallback param1 param2")
    ##
    ##   # Assume this callback is in another plugin
    ##   proc othercallback(plugin: Plugin, cmd: CmdData) {.pluginCallback.} =
    ##     for param in cmd.params:
    ##       cmd.returned.add param & "return"
    var
      cmd = newCmdData(command)
    callCommand(manager, cmd)
    if not cmd.failed:
      return cmd.returned

  proc getCommandIntResult*(manager: PluginManager, command: string, default = 0): seq[int] =
    ## Shortcut for running a callback defined in another plugin and getting
    ## all integer values returned
    ##
    ## If no value is returned, return the `default` value specified.
    ##
    ## `CmdData.params` should include the callback name and will be
    ## searched across all loaded plugins.
    ##
    ## .. code-block:: nim
    ##
    ##   import plugins/api
    ##
    ##   proc somecallback(plugin: Plugin, cmd: CmdData) {.pluginCallback.} =
    ##     var
    ##       ret = getCommandResult(plugin, "othercallback 1 2")
    ##
    ##   # Assume this callback is in another plugin
    ##   proc othercallback(plugin: Plugin, cmd: CmdData) {.pluginCallback.} =
    ##     for param in cmd.params:
    ##       try:
    ##         cmd.returned.add $(parseInt(param) * 2)
    ##       except:
    ##         cmd.returned.add ""
    let
      strs = manager.getCommandResult(command)

    for str in strs:
      try:
        result.add parseInt(str)
      except:
        result.add default
else:
  # Access callbacks compiled into main application

  macro addCallback(name, params: untyped, ret: static[string] = ""): untyped =
    let
      sName = name.strVal()
      sParams = params.strVal()
    var
      sRet = ret
      sParamNames: seq[string]
    if sRet.len != 0:
      sRet = ": " & sRet
    for param in sParams.split(","):
      sParamNames.add param.strip().split(":")[0].strip().split("=")[0].strip()
    result = parseStmt("""
      proc $1*($2)$3 =
        cast[proc($2)$3 {.nimcall.}](
          manager.callbacks["$1"])($4)""" %
      [sName, sParams, sRet, sParamNames.join(",")])

    echo result.repr

  addCallback("notify", "manager: PluginManager, msg: string")
  addCallback("plist", "manager: PluginManager", "seq[string]")
  addCallback("pload", "manager: PluginManager, cmd: CmdData")
  addCallback("punload", "manager: PluginManager, cmd: CmdData")
  addCallback("presume", "manager: PluginManager")
  addCallback("ppause", "manager: PluginManager")
  addCallback("pstop", "manager: PluginManager")

  addCallback("getPlugin", "manager: PluginManager, name: string", "Plugin")
  addCallback("getCallback", "manager: PluginManager, pname, callback: string", "proc(plugin: Plugin, cmd: CmdData) {.nimcall.}")
  addCallback("call", "manager: PluginManager, callback: string, cmd: CmdData")
  addCallback("callPlugin", "manager: PluginManager, name, callback: string, cmd: CmdData")
  addCallback("callCommand", "manager: PluginManager, cmd: CmdData")
  addCallback("getCommandResult", "manager: PluginManager, command: string", "seq[string]")
  addCallback("getCommandIntResult", "manager: PluginManager, command: string, default = 0", "seq[int]")

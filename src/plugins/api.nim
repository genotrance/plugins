## This module provides typical functionality required by shared
## library plugins that get loaded by the main plugin system.
##
## Every plugin requires a `pluginLoad()` definition that gets
## called when the plugin is loaded.
##
## .. code-block:: nim
##
##   import plugins/api
##
##   pluginLoad:
##     echo "Loaded plugin"
##
## If there is no action to be taken on load, an empty `pluginLoad()`
## is sufficient.
##
## Optional definitions are:
## - `pluginUnload()` which gets called before the plugin is unloaded
## - `pluginTick()` which gets called every time `syncPlugins()` runs
## - `pluginNotify()` which gets called when `PluginManager.notify()`
##    is called
## - `pluginReady()` which gets called when all plugins are loaded and
##    system is ready
## - `pluginDepends()` which should be used when a plugin depends on
##    other plugins being loaded
##
## Plugins can choose to use any combination of these optional
## definitions depending on the use case.
##
## In addition, plugins can define custom callbacks by using the
## `{.pluginCallback.}` pragma.
##
## Custom callbacks can be invoked with `PluginManager.handleCommand()`.
## The callback name and params should be populated correctly in the
## `CmdData.params` and return values if any should be populated by
## the callback in `CmdData.returned`. Both these are `string` types
## so a `pointer` type `CmdData.pparams` and `CmdData.preturned` are
## available for other types of data. In addition, callbacks should
## set `CmdData.failed` to `true` if the callback has failed to notify
## the caller.
##
## The `newCmdData()`, `getCbResult()` and `getCbIntResult()` procs
## are available to simplify invoking callbacks and getting return values.
##
## Callbacks should ensure they check input params and returned values
## for validity.
##
## The `getManagerData()` and `getPluginData()` procs enable storage of global
## and plugin local data so that it is accessible from any plugin.
##
## The following global callbacks are available:
## - `notify xxx` - invoke `PluginManager.notify()` with param `xxx`
## - `version` - get version information of plugin
## - `quit | exit` - stop and unload the plugin system
##
## For plugins, the following callbacks are available:
## - `plist` - list all loaded plugins
## - `pload | preload [xxx]` - (re)load specific or all plugins
## - `punload [xxx]` - unload specific or all plugins
## - `ppause` - pause the plugin monitor - changes will not reload plugins
## - `presume` - resume plugin monitor
## - `pstop` - stop and unload all plugins
import macros, sets, strutils, tables

include "."/utils

# Find callbacks
var
  ctcallbacks {.compiletime.}: HashSet[string]

macro tryCatch(body: untyped): untyped =
  if body[^1].kind == nnkStmtList:
    var
      tryStmt = nnkTryStmt.newTree(
        body[^1],
        nnkExceptBranch.newTree(
          nnkStmtList.newTree(
            nnkCommand.newTree(
              newIdentNode("echo"),
              nnkCall.newTree(
                newIdentNode("getStackTrace")
              )
            )
          )
        )
      )
    body[^1] = tryStmt

macro pluginCallback*(body): untyped =
  ## Use this pragma to define callback procs in plugins
  ##
  ## .. code-block:: nim
  ##
  ##   import plugins/api
  ##
  ##   proc name(plugin: Plugin, cmd: CmdData) {.pluginCallback.} =
  ##     discard
  if body.kind == nnkProcDef:
    ctcallbacks.incl $body[0]

    body.addPragma(ident("exportc"))
    body.addPragma(ident("dynlib"))

    tryCatch:
      body

  result = body

const
  callbacks = ctcallbacks

template pluginLoad*(body: untyped) {.dirty.} =
  ## Use this template to specify the code to run when plugin is loaded
  ##
  ## Note that all custom callbacks defined with `{.pluginCallback.}` should
  ## precede the `pluginLoad()` call.
  ##
  ## .. code-block:: nim
  ##
  ##   import plugins/api
  ##
  ##   pluginLoad:
  ##     echo "Loaded plugin"
  proc onLoad*(plugin: Plugin, cmd: CmdData) {.exportc, dynlib.} =
    bind callbacks
    plugin.cindex = callbacks

    try:
      body
    except:
      echo getStackTrace()

template pluginLoad*() {.dirty.} =
  ## Use this template if there is no code to be run on plugin load. `pluginLoad()`
  ## is required or the plugin or does not get loaded
  ##
  ## Note that all custom callbacks defined with `{.pluginCallback.}` should
  ## precede the `pluginLoad()` call.
  ##
  ## .. code-block:: nim
  ##
  ##   import plugins/api
  ##
  ##   pluginLoad()
  pluginLoad:
    discard

template pluginUnload*(body: untyped) {.dirty.} =
  ## Use this template to specify the code to run before plugin is loaded
  ##
  ## .. code-block:: nim
  ##
  ##   import plugins/api
  ##
  ##   pluginUnload:
  ##     echo "Unloaded plugin"
  proc onUnload*(plugin: Plugin, cmd: CmdData) {.exportc, dynlib.} =
    try:
      body
    except:
      echo getStackTrace()

template pluginTick*(body: untyped) {.dirty.} =
  ## Use this template to specify the code to run on every tick - when
  ## `syncPlugins()` is called in main loop
  ##
  ## .. code-block:: nim
  ##
  ##   import plugins/api
  ##
  ##   pluginTick:
  ##     echo "Tick plugin"
  proc onTick*(plugin: Plugin, cmd: CmdData) {.exportc, dynlib.} =
    try:
      body
    except:
      echo getStackTrace()

template pluginNotify*(body: untyped) {.dirty.} =
  ## Use this template to specify the code to run when a notify event is called
  ##
  ## .. code-block:: nim
  ##
  ##   import plugins/api
  ##
  ##   pluginNotify:
  ##     echo "Notify plugin: " & $cmd.params
  proc onNotify*(plugin: Plugin, cmd: CmdData) {.exportc, dynlib.} =
    try:
      body
    except:
      echo getStackTrace()

template pluginReady*(body: untyped) {.dirty.} =
  ## Use this template to specify the code to run when all plugins are loaded
  ## and system is ready
  ##
  ## .. code-block:: nim
  ##
  ##   import plugins/api
  ##
  ##   pluginReady:
  ##     echo "All plugins ready"
  proc onReady*(plugin: Plugin, cmd: CmdData) {.exportc, dynlib.} =
    try:
      body
    except:
      echo getStackTrace()

template pluginDepends*(deps) =
  ## Use this template to specify which plugins this plugin depends on.
  ## System will ensure that those plugins get loaded before this one
  ##
  ## .. code-block:: nim
  ##
  ##   import plugins/api
  ##
  ##   pluginDepends(@["plg1", "plg2"])
  proc onDepends*(plugin: Plugin, cmd: CmdData) {.exportc, dynlib.} =
    plugin.depends.add deps

proc getManagerData*[T](plugin: Plugin): T =
  ## Use this proc to store any type T in the global context. Data will persist
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
  ## Use this proc to free memory allocated in the global context with `getManagerData()`
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

proc getCbResult*(plugin: Plugin, command: string): string =
  ## Shortcut for running a callback defined in another plugin and getting the first
  ## string value returned
  ##
  ## .. code-block:: nim
  ##
  ##   import plugins/api
  ##
  ##   proc somecallback(plugin: Plugin, cmd: CmdData) {.pluginCallback.} =
  ##     var
  ##       ret = getCbResult(plugin, "othercallback param1 param2")
  ##
  ##   # Assume this callback is in another plugin
  ##   proc othercallback(plugin: Plugin, cmd: CmdData) {.pluginCallback.} =
  ##     if cmd.params.len != 0:
  ##       var
  ##
  ##   if config.settings.hasKey(name):
  ##     cmd.returned = @[config.settings[name]]
  var
    cmd = newCmdData(command)
  plugin.manager.handleCommand(plugin.manager, cmd)
  if not cmd.failed:
    if cmd.returned.len != 0 and cmd.returned[0].len != 0:
      return cmd.returned[0]

proc getCbIntResult*(plugin: Plugin, command: string, default = 0): int =
  ## Shortcut for running a callback defined in another plugin and getting the first
  ## integer value returned
  ##
  ## If no value is returned, return the `default` value specified.
  let
    str = plugin.getCbResult(command)

  try:
    result = parseInt(str)
  except:
    result = default

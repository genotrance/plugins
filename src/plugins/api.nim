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
##   is called
## - `pluginReady()` which gets called when all plugins are loaded and
##   system is ready
## - `pluginDepends()` which should be used when a plugin depends on
##   other plugins being loaded
##
## Plugins can choose to use any combination of these optional
## definitions depending on the use case.
##
## In addition, plugins can define custom callbacks by using the
## `{.pluginCallback.}` pragma.
##
## Custom callbacks can be invoked with the `callCommand()` proc.
## The callback name and params should be populated correctly in the
## `CmdData.params`. This approach is useful if the callback needs
## to be invoked as a string like if it were provided by user input.
##
## In addition, the `call()` and `callPlugin()` procs are also available
## to invoke custom callbacks directly without having to pass the callback
## name in `CmdData`. Lastly, the `getPlugin()` and `getCallback()` procs
## allow invoking callbacks like regular code.
##
## Return values if any can be populated by the callback in `CmdData.returned`
## which, along with `CmdData.params`, are `string` types so a `pointer`
## type `CmdData.pparams` and `CmdData.preturned` are also available for
## other types of data. In addition, callbacks should set `CmdData.failed`
## to `true` if the callback has failed in order to notify the caller.
##
## The `newCmdData()`, `getCommandResult()` and `getCommandIntResult()` procs
## are available to simplify invoking callbacks and getting return values.
##
## Callbacks should ensure they check input params and returned values
## for validity.
##
## The `getManagerData()` and `getPluginData()` procs enable storage of global
## and plugin local data so that it is accessible from any plugin.
##
## The following additional procs are available:
## - `notify(xxx)` - invoke `pluginNotify()` across all plugins with param `xxx`
## - `getVersion()` - get git version hash of main application
## - `getVersionBanner()` - get git and Nim compiler version of main application
## - `quit()` - stop and unload the plugin system
##
## The following plugin system specific procs are available:
## - `plist()` - list all loaded plugins
## - `pload([xxx])` - (re)load specific or all plugins
## - `punload([xxx])` - unload specific or all plugins
## - `ppause()` - pause the plugin monitor - will not reload plugins on changes
## - `presume()` - resume plugin monitor
## - `pstop()` - stop and unload all plugins
##
## All these procs are also available from the main application.

import macros, sets, strutils, tables

const API {.used.} = 1

include "."/utils

# Find callbacks
var
  ctcallbacks {.compiletime.}: HashSet[string]

macro tryCatchMacro(body: untyped): untyped =
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
            ),
            nnkCommand.newTree(
              newIdentNode("echo"),
              nnkCall.newTree(
                newIdentNode("getCurrentExceptionMsg")
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

    tryCatchMacro:
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
      echo getCurrentExceptionMsg()

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
      echo getCurrentExceptionMsg()

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
      echo getCurrentExceptionMsg()

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
      echo getCurrentExceptionMsg()

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
      echo getCurrentExceptionMsg()

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

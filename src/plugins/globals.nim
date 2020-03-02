import dynlib, locks, sets, tables

type
  CmdData* = ref object
    ## Object to send params and receive returned values to callbacks
    params*: seq[string]        ## Sequence of string params including callback
                                ## name to send callback
    pparams*: seq[pointer]      ## Sequence of pointer params to send objects to
                                ## the callback

    failed*: bool               ## Whether callback succeeded or failed
    returned*: seq[string]      ## Sequence of strings returned by callback
    preturned*: seq[pointer]    ## Sequence of pointers returned by callback

  Plugin* = ref object
    ## Plugin state information is stored in this object - each plugin has an
    ## instance of this
    ctx*: Ctx                   ## Access global context from plugin
    name*: string               ## Name of the plugin
    path: string
    handle: LibHandle

    depends*: seq[string]       ## Plugins this plugin depends on
    dependents: HashSet[string] ## Plugins that depend on this plugin

    pluginData*: pointer        ## Pointer to store any type T within plugin to make
                                ## data accessible across all callbacks within plugin
                                ## Used by `getPlgData()` and `freePlgData()`

    # Standard callbacks
    onDepends: proc(plg: Plugin, cmd: CmdData)
    onLoad: proc(plg: Plugin, cmd: CmdData)
    onUnload: proc(plg: Plugin, cmd: CmdData)
    onTick: proc(plg: Plugin, cmd: CmdData)
    onNotify: proc(plg: Plugin, cmd: CmdData)
    onReady: proc(plg: Plugin, cmd: CmdData)

    cindex: HashSet[string]
    callbacks: Table[string, proc(plg: Plugin, cmd: CmdData)]

  Run* = enum
    ## States of the plugin system - can be changed using the `ppause`, `presume`
    ## and `pstop` global callbacks
    executing, stopped, paused

  PluginMonitor = object
    lock: Lock
    run: Run
    paths: seq[string]
    load: OrderedSet[string]
    processed: HashSet[string]
    ready: bool

  Ctx* = ref object
    ## Global context of all loaded plugins and callbacks
    run*: Run                   ## State of system
    ready*: bool                ## True when all plugins are loaded
    cli*: seq[string]           ## Commands to run when system is ready

    notify*: proc(ctx: Ctx, msg: string)                      ## Callback to invoke `pluginNotify()` across
                                                              ## all plugins
    handleCommand*: proc(ctx: Ctx, cmd: CmdData) {.nimcall.}  ## Invoke callback by name across all loaded
                                                              ## plugins

    tick*: int
    pmonitor*: ptr PluginMonitor
    plugins*: OrderedTable[string, Plugin]
    pluginData*: Table[string, pointer]

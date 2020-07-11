import dynlib, sets, tables

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
    manager*: PluginManager     ## Access plugin manager from plugin
    name*: string               ## Name of the plugin
    path: string
    handle: LibHandle

    depends: seq[string]        ## Plugins this plugin depends on
    dependents: HashSet[string] ## Plugins that depend on this plugin

    pluginData: pointer         ## Pointer to store any type T within plugin to make
                                ## data accessible across all callbacks within plugin
                                ## Used by `getPluginData()` and `freePluginData()`

    # Standard callbacks
    onDepends: proc(plugin: Plugin, cmd: CmdData)
    onLoad: proc(plugin: Plugin, cmd: CmdData)
    onUnload: proc(plugin: Plugin, cmd: CmdData)
    onTick: proc(plugin: Plugin, cmd: CmdData)
    onNotify: proc(plugin: Plugin, cmd: CmdData)
    onReady: proc(plugin: Plugin, cmd: CmdData)

    cindex: HashSet[string]
    callbacks: Table[string, proc(plugin: Plugin, cmd: CmdData)]

  Run* = enum
    ## States of the plugin system - can be changed using the `ppause`, `presume`
    ## and `pstop` global callbacks
    executing, stopped, paused

  PluginManager* = ref object
    ## Manager of all loaded plugins and callbacks
    run*: Run                   ## State of system
    ready*: bool                ## True when all plugins are loaded
    cli*: seq[string]           ## Commands to run when system is ready

    tick: int
    plugins: OrderedTable[string, Plugin]
    pluginData: Table[string, pointer]

    callbacks: Table[string, pointer]

var
  gMainToMon*: Channel[string]
  gMonToMain*: Channel[string]

gMainToMon.open()
gMonToMain.open()
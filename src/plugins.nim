## This module provides a plugin system that can be used in applications
## that require the ability to distribute functionality across external
## shared libraries. It provides the following functionality:
##
## - Build plugin source file into shared library
## - Monitor source files for changes and rebuild (hot code reloading)
## - Load/unload/reload shared library
## - Provide standard and custom callback framework
## - Allow shipping in binary-only mode (no source or hot code reloading)
##   if required
##
## The library requires `--threads:on` since the monitoring function runs
## in a separate thread. It also needs `--gc:boehm` to ensure that memory
## is handled correctly across multiple threads and plugins. This is true
## both for the main application as well as the individual plugins. To
## build in binary mode, the `-d:binary` flag should be used.
##
## The boehm garbage collector or `libgc` can be installed using the
## package manager on most Linux distros and on OSX. For Windows, prebuilt
## 32-bit and 64-bit binaries are available
## [here](https://bintray.com/beta/#/genotrance/binaries/boehmgc?tab=files).
##
## This module should be imported in the main application. Plugins should
## import the `plugins/api` module which provides typical functionality
## required by the shared library plugins.
##
## The main procs of interest are:
## - `initPlugins()` which initializes the system and loads all plugins
## - `syncPlugins()` which should be called in the main application loop
##   and performs all load/unload/reload functionality plus execution of
##   any callbacks invoked
## - `stopPlugins()` which stops the system and unloads cleanly
##
## Many of the procs and callbacks accessible from plugins can also be
## called from the main application if required. Refer to the documentation
## for the `plugins/api` module for more details.

import algorithm, dynlib, macros, os, sequtils, sets, strformat, strutils, tables

when not defined(binary):
  import osproc, times

include plugins/utils

var
  gThread: Thread[seq[string]]

when not defined(binary):
  proc dllName(sourcePath: string): string =
    let
      (dir, name, _) = sourcePath.splitFile()

    result = dir / (DynlibFormat % name)

  proc sourceChanged(sourcePath, dllPath: string): bool =
    let
      dllTime = dllPath.getLastModificationTime()

    if sourcePath.getLastModificationTime() > dllTime:
      result = true
    else:
      let
        depDir = sourcePath.parentDir() / sourcePath.splitFile().name

      if depDir.dirExists():
        for dep in toSeq(walkFiles(depDir/"*.nim")):
          if dep.getLastModificationTime() > dllTime:
            result = true
            break

proc monitorPlugins(paths: seq[string]) {.thread.} =
  var
    run = executing
    ready = false
    processed: HashSet[string]
    delay = 200

  while true:
    defer:
      # Broken on posix
      sleep(delay)

    let
      ext =
        when defined(binary):
          DynlibFormat.splitFile().ext
        else:
          ".nim"

    var
      xPaths: seq[string]
    for path in paths:
      xPaths.add toSeq(walkFiles(path/"*" & ext))
    xPaths.sort()

    let
      fromMain = gMainToMon.tryRecv()
    if fromMain.dataAvailable:
      case fromMain.msg
      of "load":
        processed.excl gMainToMon.recv()
      of "loadall":
        processed.clear()
      of "executing":
        run = executing
      of "paused":
        run = paused
      of "stopped":
        break

    if run == paused:
      continue

    if not ready and processed.len == xPaths.len:
      ready = true
      gMonToMain.send("ready")
      delay = 2000

    # BROKEN
    let
      allowF = "allow.ini"
      blockF = "block.ini"
      allowed =
        if allowF.fileExists():
          allowF.readFile().splitLines()
        else:
          @[]
      blocked =
        if blockF.fileExists():
          blockF.readFile().splitLines()
        else:
          @[]

    when defined(binary):
      for dllPath in xPaths:
        var
          name = dllPath.splitFile().name
        if name.startsWith("lib"):
          name = name[3 .. ^1]

        if (allowed.len != 0 and name notin allowed) or
            (blocked.len != 0 and name in blocked):
          if name notin processed:
            processed.incl name
          continue

        if name notin processed:
          processed.incl name
          gMonToMain.send("load")
          gMonToMain.send(dllPath)
    else:
      for sourcePath in xPaths:
        let
          dllPath = dllName(sourcePath)
          dllPathNew = dllPath & ".new"
          name = sourcePath.splitFile().name

        if (allowed.len != 0 and name notin allowed) or
            (blocked.len != 0 and name in blocked):
          if name notin processed:
            processed.incl name
          continue

        if not dllPath.fileExists() or sourcePath.sourceChanged(dllPath):
          var
            relbuild =
              when defined(release):
                "-d:release"
              else:
                "--debugger:native --debuginfo"
            output = ""
            exitCode = 0

          if not dllPathNew.fileExists() or
            sourcePath.getLastModificationTime() > dllPathNew.getLastModificationTime():
            (output, exitCode) = execCmdEx(&"nim c --app:lib -o:{dllPath}.new {relbuild} {sourcePath}")
          if exitCode != 0:
            gMonToMain.send("message")
            gMonToMain.send(&"{output}\nPlugin compilation failed for {sourcePath}")
          else:
            if name notin processed:
              processed.incl name
            gMonToMain.send("load")
            gMonToMain.send(&"{dllPath}.new")
        else:
          if name notin processed:
            processed.incl name
            gMonToMain.send("load")
            gMonToMain.send(dllPath)

proc unloadPlugin(manager: PluginManager, name: string, force = true) =
  if manager.plugins.hasKey(name):
    if not force and manager.plugins[name].dependents.len != 0:
      return

    for dep in manager.plugins[name].dependents:
      notify(manager, &"Plugin '{dep}' depends on '{name}' and might crash")

    if not manager.plugins[name].onUnload.isNil:
      var
        cmd = new(CmdData)
      tryCatch:
        manager.plugins[name].onUnload(manager.plugins[name], cmd)
      if not ret:
        notify(manager, getCurrentExceptionMsg() & &"Plugin '{name}' crashed in 'pluginUnload()'")
      if cmd.failed:
        notify(manager, &"Plugin '{name}' failed in 'pluginUnload()'")

    manager.plugins[name].handle.unloadLib()
    for dep in manager.plugins[name].depends:
      if manager.plugins.hasKey(dep):
        manager.plugins[dep].dependents.excl name
    manager.plugins[name] = nil
    manager.plugins.del(name)

    notify(manager, &"Plugin '{name}' unloaded")

proc notifyPlugins(manager: PluginManager, cmd: CmdData) =
  let
    pkeys = toSeq(manager.plugins.keys())
  for pl in pkeys:
    var
      plugin = manager.plugins[pl]
    cmd.failed = false
    if not plugin.onNotify.isNil:
      tryCatch:
        plugin.onNotify(plugin, cmd)
      if not ret:
        plugin.onNotify = nil
        notify(manager, getCurrentExceptionMsg() & &"Plugin '{plugin.name}' crashed in 'pluginNotify()'")
        manager.unloadPlugin(plugin.name)
      if cmd.failed:
        notify(manager, &"Plugin '{plugin.name}' failed in 'pluginNotify()'")

  echo cmd.params[0]

proc readyPlugins(manager: PluginManager, cmd: CmdData) =
  let
    pkeys = toSeq(manager.plugins.keys())
  for pl in pkeys:
    var
      plugin = manager.plugins[pl]
    cmd.failed = false
    if not plugin.onReady.isNil:
      tryCatch:
        plugin.onReady(plugin, cmd)
      if not ret:
        plugin.onReady = nil
        notify(manager, getCurrentExceptionMsg() & &"Plugin '{plugin.name}' crashed in 'pluginReady()'")
        manager.unloadPlugin(plugin.name)
      if cmd.failed:
        notify(manager, &"Plugin '{plugin.name}' failed in 'pluginReady()'")

proc toCallback(callback: pointer): proc(plugin: Plugin, cmd: CmdData) =
  if not callback.isNil:
    result = proc(plugin: Plugin, cmd: CmdData) =
      cast[proc(plugin: Plugin, cmd: CmdData) {.cdecl.}](callback)(plugin, cmd)

macro addGlobalCallback(name: untyped): untyped =
  let
    nodeName = name.strVal()
    node = newIdentNode(nodeName)

  result = quote do:
    result.callbacks[`nodeName`] = cast[pointer](`node`)

proc initPlugins*(paths: seq[string], cmds: seq[string] = @[]): PluginManager =
  ## Loads all plugins in specified `paths`
  ##
  ## `cmds` is a list of commands to execute after all plugins
  ## are successfully loaded and system is ready
  ##
  ## Returns plugin manager that tracks all loaded plugins and
  ## associated data
  result = new(PluginManager)

  result.cli = cmds

  # Global callbacks
  addGlobalCallback(notifyPlugins)
  addGlobalCallback(unloadPlugin)

  addGlobalCallback(notify)
  addGlobalCallback(plist)
  addGlobalCallback(pload)
  addGlobalCallback(punload)
  addGlobalCallback(presume)
  addGlobalCallback(ppause)
  addGlobalCallback(pstop)

  addGlobalCallback(getPlugin)
  addGlobalCallback(getCallback)

  addGlobalCallback(call)
  addGlobalCallback(callPlugin)
  addGlobalCallback(callCommand)
  addGlobalCallback(getCommandResult)
  addGlobalCallback(getCommandIntResult)

  createThread(gThread, monitorPlugins, paths)

proc initPlugin(plugin: Plugin) =
  if plugin.onLoad.isNil:
    var
      once = false
      cmd: CmdData

    if plugin.onDepends.isNil:
      once = true
      plugin.onDepends = plugin.handle.symAddr("onDepends").toCallback()

      if not plugin.onDepends.isNil:
        cmd = new(CmdData)
        tryCatch:
          plugin.onDepends(plugin, cmd)
        if not ret:
          notify(plugin.manager, getCurrentExceptionMsg() & &"Plugin '{plugin.name}' crashed in 'pluginDepends()'")
          plugin.manager.unloadPlugin(plugin.name)
          return
        if cmd.failed:
          notify(plugin.manager, &"Plugin '{plugin.name}' failed in 'pluginDepends()'")
          plugin.manager.unloadPlugin(plugin.name)
          return

    for dep in plugin.depends:
      if not plugin.manager.plugins.hasKey(dep):
        if once:
          notify(plugin.manager, &"Plugin '{plugin.name}' dependency '{dep}' not loaded")
        return

    plugin.onLoad = plugin.handle.symAddr("onLoad").toCallback()
    if plugin.onLoad.isNil:
      notify(plugin.manager, &"Plugin '{plugin.name}' missing 'pluginLoad()'")
      plugin.manager.unloadPlugin(plugin.name)
    else:
      cmd = new(CmdData)
      tryCatch:
        plugin.onLoad(plugin, cmd)
      if not ret:
        notify(plugin.manager, getCurrentExceptionMsg() & &"Plugin '{plugin.name}' crashed in 'pluginLoad()'")
        plugin.manager.unloadPlugin(plugin.name)
        return
      if cmd.failed:
        notify(plugin.manager, &"Plugin '{plugin.name}' failed in 'pluginLoad()'")
        plugin.manager.unloadPlugin(plugin.name)
        return

      plugin.onUnload = plugin.handle.symAddr("onUnload").toCallback()
      plugin.onTick = plugin.handle.symAddr("onTick").toCallback()
      plugin.onNotify = plugin.handle.symAddr("onNotify").toCallback()
      plugin.onReady = plugin.handle.symAddr("onReady").toCallback()

      for cb in plugin.cindex:
        plugin.callbacks[cb] = plugin.handle.symAddr(cb).toCallback()
        if plugin.callbacks[cb].isNil:
          notify(plugin.manager, &"Plugin '{plugin.name}' callback '{cb}' failed to load")
          plugin.callbacks.del cb

      for dep in plugin.depends:
        if plugin.manager.plugins.hasKey(dep):
          plugin.manager.plugins[dep].dependents.incl plugin.name

      notify(plugin.manager, &"Plugin '{plugin.name}' loaded (" & toSeq(plugin.callbacks.keys()).join(", ") & ")")

proc loadPlugin(manager: PluginManager, dllPath: string) =
  var
    plugin = new(Plugin)

  plugin.manager = manager
  plugin.path =
    if dllPath.splitFile().ext == ".new":
      dllPath[0 .. ^5]
    else:
      dllPath

  plugin.name = plugin.path.splitFile().name
  if plugin.name.startsWith("lib"):
    plugin.name = plugin.name[3 .. ^1]
  manager.unloadPlugin(plugin.name)

  if dllPath.splitFile().ext == ".new":
    var
      count = 10
    while count != 0 and tryRemoveFile(plugin.path) == false:
      sleep(250)
      count -= 1

    if fileExists(plugin.path):
      notify(manager, &"Plugin '{plugin.name}' failed to unload")
      return

    tryCatch:
      moveFile(dllPath, plugin.path)
    if not ret:
      notify(manager, &"Plugin '{plugin.name}' dll copy failed")
      return

  plugin.handle = plugin.path.loadLib()
  plugin.dependents.init()

  if plugin.handle.isNil:
    notify(manager, &"Plugin '{plugin.name}' failed to load")
    return
  else:
    manager.plugins[plugin.name] = plugin

    plugin.initPlugin()

proc stopPlugins*(manager: PluginManager) =
  ## Stops all plugins in the specified manager and frees all
  ## associated data
  gMainToMon.send("stopped")

  while manager.plugins.len != 0:
    let
      pkeys = toSeq(manager.plugins.keys())
    for pl in pkeys:
      manager.unloadPlugin(pl, force = false)

  gThread.joinThread()

proc handleCli(manager: PluginManager) =
  if manager.cli.len != 0:
    for command in manager.cli:
      var
        cmd = newCmdData(command)
      callCommand(manager, cmd)
    manager.cli = @[]

proc handleReady(manager: PluginManager) =
  var
    cmd = new(CmdData)
  manager.readyPlugins(cmd)
  manager.handleCli()

proc reloadPlugins(manager: PluginManager) =
  var
    fromMon = gMonToMain.tryRecv()
  if fromMon.dataAvailable:
    case fromMon.msg
    of "load":
      manager.loadPlugin(gMonToMain.recv())
    of "message":
      notify(manager, gMonToMain.recv())
    of "ready":
      manager.ready = true
      manager.handleReady()

  for i in manager.plugins.keys():
    if manager.plugins[i].onLoad.isNil:
      manager.plugins[i].initPlugin()

proc tickPlugins(manager: PluginManager) =
  let
    pkeys = toSeq(manager.plugins.keys())
  for pl in pkeys:
    var
      plugin = manager.plugins[pl]
      cmd = new(CmdData)
    if not plugin.onTick.isNil:
      tryCatch:
        plugin.onTick(plugin, cmd)
      if not ret:
        notify(manager, getCurrentExceptionMsg() & &"Plugin '{plugin.name}' crashed in 'pluginTick()'")
        manager.unloadPlugin(plugin.name)
      if cmd.failed:
        notify(manager, &"Plugin '{plugin.name}' failed in 'pluginTick()'")

proc syncPlugins*(manager: PluginManager) =
  ## Give plugin system time to process all events
  ##
  ## This should be called in the main application loop
  manager.tick += 1
  if not manager.ready or manager.tick == 25:
    manager.tick = 0
    manager.reloadPlugins()

  manager.tickPlugins()

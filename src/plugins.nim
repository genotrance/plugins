## This module provides a plugin system that can be used in applications
## that require the ability to distribute functionality across external
## shared libraries. It provides the following functionality:
##
## - Build plugin source file into shared library
## - Monitor source files for changes and rebuild (hot code reloading)
## - Load/unload/reload shared library
## - Provide standard and custom callback framework
## - Allow shipping in binary-only mode (no hot code reloading) if required
##
## The library requires `--threads:on` since the monitoring function runs
## in a separate thread. It also needs `--gc:boehm` to ensure that memory
## is handled correctly across multiple threads and plugins. To build in
## binary mode, the `-d:binary` flag should be used.
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

import algorithm, dynlib, locks, os, sequtils, sets, strformat, strutils, tables

when not defined(binary):
  import osproc, times

include plugins/utils

var
  gThread: Thread[ptr PluginMonitor]

template tryCatch(body: untyped) {.dirty.} =
  var
    ret {.inject.} = true
  try:
    body
  except:
    ret = false
    when not defined(release):
      raise getCurrentException()

when not defined(binary):
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

proc monitorPlugins(pmonitor: ptr PluginMonitor) {.thread.} =
  var
    paths: seq[string]
    delay = 200

  withLock pmonitor[].lock:
    paths = pmonitor[].paths

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

    withLock pmonitor[].lock:
      case pmonitor[].run
      of paused:
        continue
      of stopped:
        break
      else:
        discard

      if not pmonitor[].ready and pmonitor[].processed.len == xPaths.len:
        pmonitor[].ready = true
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
        let
          name = dllPath.splitFile().name

        withLock pmonitor[].lock:
          if (allowed.len != 0 and name notin allowed) or
              (blocked.len != 0 and name in blocked):
            if name notin pmonitor[].processed:
              pmonitor[].processed.incl name
            continue

          if name notin pmonitor[].processed:
            pmonitor[].processed.incl name
            pmonitor[].load.incl &"{dllPath}"
    else:
      for sourcePath in xPaths:
        let
          dllPath = dllName(sourcePath)
          dllPathNew = dllPath & ".new"
          name = sourcePath.splitFile().name

        if (allowed.len != 0 and name notin allowed) or
            (blocked.len != 0 and name in blocked):
          withLock pmonitor[].lock:
            if name notin pmonitor[].processed:
              pmonitor[].processed.incl name
          continue

        if not dllPath.fileExists() or sourcePath.sourceChanged(dllPath):
          var
            relbuild =
              when defined(release):
                "--opt:speed"
              else:
                "--debugger:native --debuginfo"
            output = ""
            exitCode = 0

          if not dllPathNew.fileExists() or
            sourcePath.getLastModificationTime() > dllPathNew.getLastModificationTime():
            (output, exitCode) = execCmdEx(&"nim c --app:lib -o:{dllPath}.new {relbuild} {sourcePath}")
          if exitCode != 0:
            pmonitor[].load.incl &"{output}\nPlugin compilation failed for {sourcePath}"
          else:
            withLock pmonitor[].lock:
              if name notin pmonitor[].processed:
                pmonitor[].processed.incl name
              pmonitor[].load.incl &"{dllPath}.new"
        else:
          withLock pmonitor[].lock:
            if name notin pmonitor[].processed:
              pmonitor[].processed.incl name
              pmonitor[].load.incl &"{dllPath}"

proc unloadPlugin(ctx: Ctx, name: string, force = true) =
  if ctx.plugins.hasKey(name):
    if not force and ctx.plugins[name].dependents.len != 0:
      return

    for dep in ctx.plugins[name].dependents:
      ctx.notify(ctx, &"Plugin '{dep}' depends on '{name}' and might crash")

    if not ctx.plugins[name].onUnload.isNil:
      var
        cmd = new(CmdData)
      tryCatch:
        ctx.plugins[name].onUnload(ctx.plugins[name], cmd)
      if not ret:
        ctx.notify(ctx, getCurrentExceptionMsg() & &"Plugin '{name}' crashed in 'pluginUnload()'")
      if cmd.failed:
        ctx.notify(ctx, &"Plugin '{name}' failed in 'pluginUnload()'")

    ctx.plugins[name].handle.unloadLib()
    for dep in ctx.plugins[name].depends:
      if ctx.plugins.hasKey(dep):
        ctx.plugins[dep].dependents.excl name
    ctx.plugins[name] = nil
    ctx.plugins.del(name)

    ctx.notify(ctx, &"Plugin '{name}' unloaded")

proc notifyPlugins(ctx: Ctx, cmd: CmdData) =
  let
    pkeys = toSeq(ctx.plugins.keys())
  for pl in pkeys:
    var
      plg = ctx.plugins[pl]
    cmd.failed = false
    if not plg.onNotify.isNil:
      tryCatch:
        plg.onNotify(plg, cmd)
      if not ret:
        plg.onNotify = nil
        ctx.notify(ctx, getCurrentExceptionMsg() & &"Plugin '{plg.name}' crashed in 'pluginNotify()'")
        ctx.unloadPlugin(plg.name)
      if cmd.failed:
        ctx.notify(ctx, &"Plugin '{plg.name}' failed in 'pluginNotify()'")

  echo cmd.params[0]

proc readyPlugins(ctx: Ctx, cmd: CmdData) =
  let
    pkeys = toSeq(ctx.plugins.keys())
  for pl in pkeys:
    var
      plg = ctx.plugins[pl]
    cmd.failed = false
    if not plg.onReady.isNil:
      tryCatch:
        plg.onReady(plg, cmd)
      if not ret:
        plg.onReady = nil
        ctx.notify(ctx, getCurrentExceptionMsg() & &"Plugin '{plg.name}' crashed in 'pluginReady()'")
        ctx.unloadPlugin(plg.name)
      if cmd.failed:
        ctx.notify(ctx, &"Plugin '{plg.name}' failed in 'pluginReady()'")

proc getVersion(): string =
  const
    execResult = gorgeEx("git rev-parse HEAD")
  when execResult[0].len > 0 and execResult[1] == 0:
    result = execResult[0].strip()
  else:
    result ="couldn't determine git hash"

proc handlePluginCommand(ctx: Ctx, cmd: CmdData) =
  if cmd.params.len == 0:
    cmd.failed = true
    return

  case cmd.params[0]:
    of "plist":
      var
        nf = ""
      for pl in ctx.plugins.keys():
        nf &= pl.extractFilename & " "
      ctx.notify(ctx, nf)
    of "preload", "pload":
      if cmd.params.len > 1:
        withLock ctx.pmonitor[].lock:
          for i in 1 .. cmd.params.len-1:
            ctx.pmonitor[].processed.excl cmd.params[i]
      else:
        ctx.pmonitor[].processed.clear()
    of "punload":
      if cmd.params.len > 1:
        for i in 1 .. cmd.params.len-1:
          if ctx.plugins.hasKey(cmd.params[i]):
            ctx.unloadPlugin(cmd.params[i])
          else:
            ctx.notify(ctx, &"Plugin '{cmd.params[i]}' not found")
      else:
        let
          pkeys = toSeq(ctx.plugins.keys())
        for pl in pkeys:
          ctx.unloadPlugin(pl)
    of "presume":
      withLock ctx.pmonitor[].lock:
        ctx.pmonitor[].run = executing
      ctx.notify(ctx, &"Plugin monitor resumed")
    of "ppause":
      withLock ctx.pmonitor[].lock:
        ctx.pmonitor[].run = paused
      ctx.notify(ctx, &"Plugin monitor paused")
    of "pstop":
      withLock ctx.pmonitor[].lock:
        ctx.pmonitor[].run = stopped
      ctx.notify(ctx, &"Plugin monitor exited")
    else:
      cmd.failed = true
      let
        pkeys = toSeq(ctx.plugins.keys())
      for pl in pkeys:
        var
          plg = ctx.plugins[pl]
          ccmd = new(CmdData)
        ccmd.params = cmd.params[1 .. ^1]
        if cmd.params[0] in plg.cindex:
          tryCatch:
            plg.callbacks[cmd.params[0]](plg, ccmd)
          if not ret:
            ctx.notify(ctx, getCurrentExceptionMsg() & &"Plugin '{plg.name}' crashed in '{cmd.params[0]}()'")
          elif ccmd.failed:
            ctx.notify(ctx, &"Plugin '{plg.name}' failed in '{cmd.params[0]}()'")
          else:
            cmd.returned &= ccmd.returned
            cmd.failed = false
          break

proc handleCommand(ctx: Ctx, cmd: CmdData) =
  if cmd.params.len != 0:
    case cmd.params[0]:
      of "quit", "exit":
        ctx.run = stopped
      of "notify":
        if cmd.params.len > 1:
          ctx.notify(ctx, cmd.params[1 .. ^1].join(" "))
        else:
          cmd.failed = true
      of "version":
        ctx.notify(ctx,
          &"Plugin {getVersion()}\ncompiled on {CompileDate} {CompileTime} with Nim v{NimVersion}")
      else:
        ctx.handlePluginCommand(cmd)
  else:
    cmd.failed = true

proc toCallback(callback: pointer): proc(plg: Plugin, cmd: CmdData) =
  if not callback.isNil:
    result = proc(plg: Plugin, cmd: CmdData) =
      cast[proc(plg: Plugin, cmd: CmdData) {.cdecl.}](callback)(plg, cmd)

proc initPlugins*(paths: seq[string], cmds: seq[string] = @[]): Ctx =
  ## Loads all plugins in specified `paths`
  ##
  ## `cmds` is a list of commands to execute after all plugins
  ## are successfully loaded and system is ready
  ##
  ## Returns plugin context that tracks all loaded plugins and
  ## associated data
  result = new(Ctx)

  result.cli = cmds
  result.handleCommand = handleCommand

  result.pmonitor = newShared[PluginMonitor]()
  result.pmonitor[].lock.initLock()
  result.pmonitor[].run = executing
  result.pmonitor[].paths = paths

  result.notify = proc(ctx: Ctx, msg: string) =
    var
      cmd = new(CmdData)
    cmd.params.add msg
    ctx.notifyPlugins(cmd)

  createThread(gThread, monitorPlugins, result.pmonitor)

proc initPlugin(plg: Plugin) =
  if plg.onLoad.isNil:
    var
      once = false
      cmd: CmdData

    if plg.onDepends.isNil:
      once = true
      plg.onDepends = plg.handle.symAddr("onDepends").toCallback()

      if not plg.onDepends.isNil:
        cmd = new(CmdData)
        tryCatch:
          plg.onDepends(plg, cmd)
        if not ret:
          plg.ctx.notify(plg.ctx, getCurrentExceptionMsg() & &"Plugin '{plg.name}' crashed in 'pluginDepends()'")
          plg.ctx.unloadPlugin(plg.name)
          return
        if cmd.failed:
          plg.ctx.notify(plg.ctx, &"Plugin '{plg.name}' failed in 'pluginDepends()'")
          plg.ctx.unloadPlugin(plg.name)
          return

    for dep in plg.depends:
      if not plg.ctx.plugins.hasKey(dep):
        if once:
          plg.ctx.notify(plg.ctx, &"Plugin '{plg.name}' dependency '{dep}' not loaded")
        return

    plg.onLoad = plg.handle.symAddr("onLoad").toCallback()
    if plg.onLoad.isNil:
      plg.ctx.notify(plg.ctx, &"Plugin '{plg.name}' missing 'pluginLoad()'")
      plg.ctx.unloadPlugin(plg.name)
    else:
      cmd = new(CmdData)
      tryCatch:
        plg.onLoad(plg, cmd)
      if not ret:
        plg.ctx.notify(plg.ctx, getCurrentExceptionMsg() & &"Plugin '{plg.name}' crashed in 'pluginLoad()'")
        plg.ctx.unloadPlugin(plg.name)
        return
      if cmd.failed:
        plg.ctx.notify(plg.ctx, &"Plugin '{plg.name}' failed in 'pluginLoad()'")
        plg.ctx.unloadPlugin(plg.name)
        return

      plg.onUnload = plg.handle.symAddr("onUnload").toCallback()
      plg.onTick = plg.handle.symAddr("onTick").toCallback()
      plg.onNotify = plg.handle.symAddr("onNotify").toCallback()
      plg.onReady = plg.handle.symAddr("onReady").toCallback()

      for cb in plg.cindex:
        plg.callbacks[cb] = plg.handle.symAddr(cb).toCallback()
        if plg.callbacks[cb].isNil:
          plg.ctx.notify(plg.ctx, &"Plugin '{plg.name}' callback '{cb}' failed to load")
          plg.callbacks.del cb

      for dep in plg.depends:
        if plg.ctx.plugins.hasKey(dep):
          plg.ctx.plugins[dep].dependents.incl plg.name

      plg.ctx.notify(plg.ctx, &"Plugin '{plg.name}' loaded (" & toSeq(plg.callbacks.keys()).join(", ") & ")")

proc loadPlugin(ctx: Ctx, dllPath: string) =
  var
    plg = new(Plugin)

  plg.ctx = ctx
  plg.path =
    if dllPath.splitFile().ext == ".new":
      dllPath[0 .. ^5]
    else:
      dllPath

  plg.name = plg.path.splitFile().name
  if plg.name.startsWith("lib"):
    plg.name = plg.name[3 .. ^1]
  ctx.unloadPlugin(plg.name)

  if dllPath.splitFile().ext == ".new":
    var
      count = 10
    while count != 0 and tryRemoveFile(plg.path) == false:
      sleep(250)
      count -= 1

    if fileExists(plg.path):
      ctx.notify(ctx, &"Plugin '{plg.name}' failed to unload")
      return

    tryCatch:
      moveFile(dllPath, plg.path)
    if not ret:
      ctx.notify(ctx, &"Plugin '{plg.name}' dll copy failed")
      return

  plg.handle = plg.path.loadLib()
  plg.dependents.init()

  if plg.handle.isNil:
    ctx.notify(ctx, &"Plugin '{plg.name}' failed to load")
    return
  else:
    ctx.plugins[plg.name] = plg

    plg.initPlugin()

proc stopPlugins*(ctx: Ctx) =
  ## Stops all plugins in the specified context and frees all
  ## associated data
  withLock ctx.pmonitor[].lock:
    ctx.pmonitor[].run = stopped

  while ctx.plugins.len != 0:
    let
      pkeys = toSeq(ctx.plugins.keys())
    for pl in pkeys:
      ctx.unloadPlugin(pl, force = false)

  gThread.joinThread()

  ctx.pmonitor[].load.clear()
  ctx.pmonitor[].processed.clear()

  freeShared(ctx.pmonitor)

proc reloadPlugins(ctx: Ctx) =
  var
    load: HashSet[string]

  withLock ctx.pmonitor[].lock:
    load = ctx.pmonitor[].load

    ctx.pmonitor[].load.clear()

  for i in load:
    if i.fileExists():
      ctx.loadPlugin(i)
    else:
      ctx.notify(ctx, i)

  for i in ctx.plugins.keys():
    if ctx.plugins[i].onLoad.isNil:
      ctx.plugins[i].initPlugin()

proc tickPlugins(ctx: Ctx) =
  let
    pkeys = toSeq(ctx.plugins.keys())
  for pl in pkeys:
    var
      plg = ctx.plugins[pl]
      cmd = new(CmdData)
    if not plg.onTick.isNil:
      tryCatch:
        plg.onTick(plg, cmd)
      if not ret:
        ctx.notify(ctx, getCurrentExceptionMsg() & &"Plugin '{plg.name}' crashed in 'pluginTick()'")
        ctx.unloadPlugin(plg.name)
      if cmd.failed:
        ctx.notify(ctx, &"Plugin '{plg.name}' failed in 'pluginTick()'")

proc handleCli(ctx: Ctx) =
  if ctx.cli.len != 0:
    for command in ctx.cli:
      var
        cmd = newCmdData(command)
      ctx.handleCommand(ctx, cmd)
    ctx.cli = @[]

proc handleReady(ctx: Ctx) =
  if not ctx.ready:
    withLock ctx.pmonitor[].lock:
      if ctx.pmonitor[].ready:
        ctx.ready = true
        var
          cmd = new(CmdData)
        ctx.readyPlugins(cmd)
        ctx.handleCli()

proc syncPlugins*(ctx: Ctx) =
  ## Give plugin system time to process all events
  ##
  ## This should be called in the main application loop
  ctx.tick += 1
  if not ctx.ready or ctx.tick == 25:
    ctx.tick = 0
    ctx.reloadPlugins()
    ctx.handleReady()

  ctx.tickPlugins()

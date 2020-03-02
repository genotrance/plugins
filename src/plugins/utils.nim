import os, strutils

include "."/globals

proc newShared*[T](): ptr T =
  ## Allocate memory of type T in shared memory
  result = cast[ptr T](allocShared0(sizeof(T)))

proc freeShared*[T](s: var ptr T) =
  ## Free shared memory of type T
  s.deallocShared()
  s = nil

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

proc dllName(sourcePath: string): string =
  let
    (dir, name, _) = sourcePath.splitFile()

  result = dir / (DynlibFormat % name)

proc depName(name: string): string {.used.} =
  result = dllName(name).splitFile().name
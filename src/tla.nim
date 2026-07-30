## TLA-on-NIF model checker — CLI entry point.

import std / [os, strutils, syncio, tables]
import tlanif, loader, explore, eval

const Help = """
tla — NIF-syntax TLA safety model checker

Usage:
  tla <spec.nif>
  tla --max-states:N <spec.nif>

Specs use Symbol/SymbolDef names and TLA operator tags. See examples/.
"""

proc main() =
  var maxStates = 100_000
  var symmetry = false
  var file = ""
  for i in 1 .. paramCount():
    let a = paramStr(i)
    if a.startsWith("--max-states:"):
      maxStates = parseInt(a["--max-states:".len .. ^1])
    elif a == "--sym":
      symmetry = true
    elif a in ["-h", "--help"]:
      echo Help
      quit(0)
    elif a.startsWith("-"):
      stderr.writeLine "unknown option: " & a
      quit(1)
    else:
      file = a

  if file.len == 0:
    stderr.writeLine Help
    quit(1)
  if not fileExists(file):
    stderr.writeLine "file not found: " & file
    quit(1)

  try:
    let m = loadModuleFile(file)
    let r = explore(m, maxStates, symmetry)
    let total = m.memoHits + m.memoMisses
    if total > 0:
      stderr.writeLine "memo: " & $m.memoHits & " hits / " & $total &
        " (" & $(m.memoHits * 100 div total) & "% hit, " &
        $m.memo.len & " entries)"
    if r.ok:
      echo r.message
      quit(0)
    else:
      stderr.writeLine formatCounterexample(m, r)
      quit(2)
  except EvalError as e:
    stderr.writeLine "error: " & e.msg
    quit(1)

when isMainModule:
  main()

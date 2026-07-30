## TLA-on-NIF model checker — CLI entry point.

import std / [os, strutils, syncio, tables, cpuinfo]
import tlanif_model, loader, explore, pexplore, eval

const Help = """
tlanif — NIF-syntax TLA safety model checker

Usage:
  tlanif <spec.nif>
  tlanif --max-states:N <spec.nif>
  tlanif --jobs:N <spec.nif>       # parallel BFS with N workers (0 = auto)

See examples/.
"""

proc main() =
  var maxStates = 100_000
  var symmetry = false
  var jobs = 1
  var file = ""
  for i in 1 .. paramCount():
    let a = paramStr(i)
    if a.startsWith("--max-states:"):
      maxStates = parseInt(a["--max-states:".len .. ^1])
    elif a.startsWith("--jobs:"):
      jobs = parseInt(a["--jobs:".len .. ^1])
      if jobs <= 0: jobs = countProcessors()
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
    let r =
      if jobs > 1:
        pexplore.pexplore(file, maxStates, symmetry, jobs)
      else:
        explore(m, maxStates, symmetry)
    if jobs <= 1:
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

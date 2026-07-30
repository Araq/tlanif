# tlanif
Small TLA+ implementation based on NIF.

Parses a NIF dialect of untyped TLA-style specs (Symbol/SymbolDef names,
operator tags) and checks safety invariants by BFS over finite models.

Build:
  nim c src/tla/tla.nim

Run:
  bin/tla src/tla/examples/mutex.nif
  bin/tla src/tla/examples/mutex_bug.nif

Modules:
  tlanif   — tags + load helpers
  value    — finite values (bool/int/model/set/seq/fun/record)
  eval     — expression + action interpreter
  loader   — module wiring (constants/variables/models/defs/spec/check)
  explore  — BFS explorer + counterexamples
  tla      — CLI

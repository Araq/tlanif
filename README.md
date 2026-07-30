# tlanif
Small TLA+ implementation based on NIF.

Parses a NIF dialect of untyped TLA-style specs (Symbol/SymbolDef names,
operator tags) and checks safety invariants by BFS over finite models.

Build:
  nim c src/tla/tlanif.nim

Run:
  bin/tlanif examples/mutex.nif
  bin/tlanif examples/mutex_bug.nif

Quick overview over the codebase:

| Module        | description        |
|---------------|--------------------|
|  tlanif_model | tags + load helpers |
|  value        | finite values (bool/int/model/set/seq/fun/record) |
|  eval         | expression + action interpreter |
|  loader       | module wiring (constants/variables/models/defs/spec/check) |
|  explore      | BFS explorer + counterexamples |
|  tlanif       | CLI |

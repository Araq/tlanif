## BFS state-space explorer with safety invariant checking.

import std / [tables, strutils, deques, syncio, algorithm]
import nifcore, value, eval

type
  CheckResult* = object
    ok*: bool
    statesExplored*: int
    counterexample*: seq[State]
    message*: string

proc permsOf(xs: seq[SymId]): seq[seq[SymId]] =
  ## All orderings of `xs`.
  if xs.len <= 1: return @[xs]
  result = @[]
  for i in 0 ..< xs.len:
    var rest = xs
    rest.delete(i)
    for p in permsOf(rest):
      result.add @[xs[i]] & p

proc buildPerms*(groups: seq[seq[SymId]]): seq[Table[SymId, SymId]] =
  ## Product of per-sort object permutations, each as a SymId→SymId rewrite.
  result = @[initTable[SymId, SymId]()]
  for g in groups:
    let orderings = permsOf(g)
    var nextPerms: seq[Table[SymId, SymId]] = @[]
    for base in result:
      for ord in orderings:
        var tbl = base
        for i in 0 ..< g.len:
          tbl[g[i]] = ord[i]
        nextPerms.add tbl
    result = nextPerms

proc canonicalState*(m: Module; st: State; perms: seq[Table[SymId, SymId]]): State =
  ## The lexicographically smallest state in `st`'s symmetry orbit — its
  ## canonical representative. Object symbols are interchangeable, so all orbit
  ## members satisfy the (symmetric) invariant iff the representative does.
  result = st
  for perm in perms:
    var ns = State(vals: initTable[SymId, Value]())
    for k, val in st.vals:
      ns.vals[k] = permuteValue(m.vs, val, perm)
    if cmpState(ns, result) < 0:
      result = ns

proc explore*(m: Module; maxStates = 100_000; symmetry = false): CheckResult =
  result = CheckResult(ok: true, statesExplored: 0, counterexample: @[], message: "")
  var visited = initTable[State, int]()
  var parent: seq[int] = @[]
  var order: seq[State] = @[]

  let perms = buildPerms(m.modelGroups)
  let useSym = symmetry and perms.len > 1
  if useSym:
    stderr.writeLine "symmetry reduction: " & $perms.len & " permutations"
  template canon(s: State): State =
    (if useSym: canonicalState(m, s, perms) else: s)

  var q = initDeque[State]()
  let inits = initialStates(m)
  if inits.len == 0:
    result.ok = false
    result.message = "Init enabled no states"
    return

  for st0 in inits:
    let st = canon(st0)
    if st in visited: continue
    visited[st] = order.len
    parent.add -1
    order.add st
    q.addLast st

  while q.len > 0:
    let st = q.popFirst()
    inc result.statesExplored
    if result.statesExplored mod 50_000 == 0:
      stderr.writeLine "  ... " & $result.statesExplored & " explored, " &
        $order.len & " seen, |queue|=" & $q.len
    if result.statesExplored > maxStates:
      result.ok = false
      result.message = "state limit exceeded (" & $maxStates & ")"
      return

    if not checkInvariant(m, st, m.checkBody):
      result.ok = false
      result.message = "invariant violated"
      # reconstruct path
      var idx = visited[st]
      var path: seq[State] = @[]
      while idx >= 0:
        path.add order[idx]
        idx = parent[idx]
      # reverse
      for i in countdown(path.high, 0):
        result.counterexample.add path[i]
      return

    for nxt0 in successors(m, st):
      let nxt = canon(nxt0)
      if nxt in visited: continue
      visited[nxt] = order.len
      parent.add visited[st]
      order.add nxt
      q.addLast nxt

  result.message = "ok — explored " & $result.statesExplored & " states"

proc formatCounterexample*(m: Module; r: CheckResult): string =
  if r.ok: return r.message
  result = r.message & "\ncounterexample (" & $r.counterexample.len & " states):\n"
  for i, st in r.counterexample:
    result.add "  "
    result.add $i
    result.add ": "
    toString(st, result)
    result.add '\n'

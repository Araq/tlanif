## Parallel level-synchronous BFS explorer.
##
## Workers are fully isolated: each loads its own `Module` from the spec
## file (SymIds and TagIds are deterministic for a given file, so encodings
## agree across workers) and keeps its own memo. States cross threads only
## as canonical byte strings (`encodeValue`), never as `Value` cursors —
## a `Value` is a Cursor into a refcounted TokenBuf whose refcounts are not
## atomic. Under ARC, `string`/`seq` have value semantics (copy = fresh
## payload, no shared refcounts), so the barrier-disciplined handoff below
## is race-free by construction.
##
## The BFS runs level by level: the frontier is split into contiguous
## chunks, one per worker; each worker invariant-checks and expands its
## chunk; the main thread merges successors into the visited set. Level
## synchrony preserves BFS order, so counterexamples are still
## shortest-path and `parent` reconstruction is unchanged.

import std / [tables, locks, syncio, strutils]
import nifcore, value, eval, loader, explore

type
  Item = object
    invOk: bool
    succs: seq[string]     ## canonical encodings of successor states

  Chunk = object
    states: seq[string]    ## input: encoded frontier slice
    items: seq[Item]       ## output, parallel to `states`
    err: string            ## nonempty on worker failure

  WorkerPool = object
    lock: Lock
    workCond, doneCond: Cond
    generation: int
    pending: int
    quitting: bool
    symmetry: bool
    path: string
    chunks: seq[Chunk]

  WorkerArg = tuple[pool: ptr WorkerPool, idx: int]

proc encodeState*(m: Module; st: State): string =
  result = ""
  for v in m.variables:
    encodeValue(st.vals[v], result)

proc decodeState*(m: Module; s: string): State =
  result = State(vals: initTable[SymId, Value]())
  var pos = 0
  for v in m.variables:
    result.vals[v] = decodeValue(m.vs, s, pos)

proc expandChunk(m: Module; perms: seq[Table[SymId, SymId]]; useSym: bool;
                 chunk: ptr Chunk) =
  chunk.items.setLen chunk.states.len
  for j in 0 ..< chunk.states.len:
    let st = decodeState(m, chunk.states[j])
    var it = Item(invOk: checkInvariant(m, st, m.checkBody), succs: @[])
    if it.invOk:
      for nxt in successors(m, st):
        let cn = if useSym: canonicalState(m, nxt, perms) else: nxt
        it.succs.add encodeState(m, cn)
    chunk.items[j] = it

proc workerLoop(arg: WorkerArg) {.thread.} =
  ## The `cast(gcsafe)` below asserts what the module doc explains: workers
  ## touch no shared GC'd state. The only globals on the call path are
  ## nifcore's `fallbackPool`/`fallbackTags`, which tlanif never sets (all
  ## buffers carry per-module pools), so they are read-only nil here.
  let p = arg.pool
  var m: Module = nil
  var perms: seq[Table[SymId, SymId]] = @[]
  var useSym = false
  var myGen = 0
  while true:
    acquire p.lock
    while p.generation == myGen and not p.quitting:
      wait(p.workCond, p.lock)
    if p.quitting:
      release p.lock
      break
    myGen = p.generation
    release p.lock
    {.cast(gcsafe).}:
      if m == nil and p.chunks[arg.idx].err.len == 0:
        try:
          m = loadModuleFile(p.path)
          if p.symmetry:
            perms = buildPerms(m.modelGroups)
          useSym = p.symmetry and perms.len > 1
        except CatchableError as e:
          p.chunks[arg.idx].err = "worker load failed: " & e.msg
      if m != nil:
        try:
          expandChunk(m, perms, useSym, addr p.chunks[arg.idx])
        except CatchableError as e:
          p.chunks[arg.idx].err = e.msg
    acquire p.lock
    dec p.pending
    if p.pending == 0:
      signal p.doneCond
    release p.lock

proc runLevel(p: ptr WorkerPool) =
  acquire p.lock
  p.pending = p.chunks.len
  inc p.generation
  broadcast p.workCond
  while p.pending > 0:
    wait(p.doneCond, p.lock)
  release p.lock

proc pexplore*(path: string; maxStates = 100_000; symmetry = false;
               jobs = 2): CheckResult =
  result = CheckResult(ok: true, statesExplored: 0, counterexample: @[],
                       message: "")
  let m0 = loadModuleFile(path)
  let perms0 = if symmetry: buildPerms(m0.modelGroups)
               else: @[]
  let useSym = symmetry and perms0.len > 1
  if useSym:
    stderr.writeLine "symmetry reduction: " & $perms0.len & " permutations"

  var visited = initTable[string, int32]()
  var order: seq[string] = @[]
  var parent: seq[int32] = @[]
  var frontier: seq[int32] = @[]

  let inits = initialStates(m0)
  if inits.len == 0:
    result.ok = false
    result.message = "Init enabled no states"
    return
  for st0 in inits:
    let st = if useSym: canonicalState(m0, st0, perms0) else: st0
    let enc = encodeState(m0, st)
    if enc in visited: continue
    visited[enc] = int32(order.len)
    parent.add -1'i32
    frontier.add int32(order.len)
    order.add enc

  var pool = WorkerPool(generation: 0, pending: 0, quitting: false,
                        symmetry: symmetry, path: path)
  initLock pool.lock
  initCond pool.workCond
  initCond pool.doneCond
  pool.chunks.setLen jobs
  var threads = newSeq[Thread[WorkerArg]](jobs)
  for i in 0 ..< jobs:
    createThread(threads[i], workerLoop, (addr pool, i))
  defer:
    acquire pool.lock
    pool.quitting = true
    broadcast pool.workCond
    release pool.lock
    joinThreads threads
    deinitCond pool.doneCond
    deinitCond pool.workCond
    deinitLock pool.lock

  template fail(msg: string) =
    result.ok = false
    result.message = msg
    return

  var lastProgress = 0
  while frontier.len > 0:
    let n = frontier.len
    var starts = newSeq[int](jobs + 1)
    for w in 0 .. jobs:
      starts[w] = w * n div jobs
    for w in 0 ..< jobs:
      pool.chunks[w].states.setLen 0
      pool.chunks[w].items.setLen 0
      pool.chunks[w].err.setLen 0
      for k in starts[w] ..< starts[w + 1]:
        pool.chunks[w].states.add order[frontier[k]]

    runLevel(addr pool)

    var nextFrontier: seq[int32] = @[]
    for w in 0 ..< jobs:
      if pool.chunks[w].err.len > 0:
        fail pool.chunks[w].err
      for j in 0 ..< pool.chunks[w].items.len:
        let fi = frontier[starts[w] + j]
        inc result.statesExplored
        if not pool.chunks[w].items[j].invOk:
          result.ok = false
          result.message = "invariant violated"
          var pathIdxs: seq[int] = @[]
          var idx = int(fi)
          while idx >= 0:
            pathIdxs.add idx
            idx = int(parent[idx])
          for i in countdown(pathIdxs.high, 0):
            result.counterexample.add decodeState(m0, order[pathIdxs[i]])
          return
        for enc in pool.chunks[w].items[j].succs:
          if enc notin visited:
            visited[enc] = int32(order.len)
            parent.add fi
            nextFrontier.add int32(order.len)
            order.add enc

    if result.statesExplored - lastProgress >= 50_000:
      lastProgress = result.statesExplored
      stderr.writeLine "  ... " & $result.statesExplored & " explored, " &
        $order.len & " seen, |frontier|=" & $nextFrontier.len
    if result.statesExplored > maxStates:
      fail "state limit exceeded (" & $maxStates & ")"
    frontier = move nextFrontier

  result.message = "ok — explored " & $result.statesExplored & " states"

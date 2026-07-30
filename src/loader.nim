## Load a TLA-NIF module: constants, variables, models, defs, spec, check.

import std / [tables, sets]
import tlanif_model, value, eval

proc skipExtends(c: var Cursor) =
  expectTag(c, TExtends)
  c.skip

proc loadDefs(m: Module; c: var Cursor) =
  ## (def :Name.0. body...)
  expectTag(c, TDef)
  c.into:
    let s = takeSymId(c)
    m.defs[s] = DefEntry(body: c)
    # remember Init/Next by name suffix convention optional; wired via spec
    c.skip

proc loadConstants(m: Module; c: var Cursor) =
  expectTag(c, TConstants)
  c.into:
    while c.hasMore:
      m.constants.add takeSymId(c)

proc loadVariables(m: Module; c: var Cursor) =
  expectTag(c, TVariables)
  c.into:
    while c.hasMore:
      m.variables.add takeSymId(c)

proc loadModels(m: Module; c: var Cursor) =
  ## (models ConstSym :v1.0. :v2.0. ...)
  expectTag(c, TModels)
  c.into:
    let constSym = takeSymId(c)
    var elems: seq[Value] = @[]
    var group: seq[SymId] = @[]
    while c.hasMore:
      let s = takeSymId(c)
      let mv = buildValue(m.vs):
        t.addModel s
      m.env[s] = mv
      elems.add mv
      group.add s
    m.env[constSym] = sortedUniqueSet(m.vs, elems)
    m.modelGroups.add group

proc loadAssign(m: Module; c: var Cursor) =
  ## (assign ConstSym Expr)
  expectTag(c, TAssign)
  c.into:
    let s = takeSymId(c)
    var f = Frame(
      env: m.env,
      primed: initTable[SymId, Value](),
      atStack: @[])
    m.env[s] = evalExpr(m, c, f)

proc loadSpec(m: Module; c: var Cursor) =
  ## (spec (always-stutter InitSym NextSym (tuple v1 v2 ...)))
  expectTag(c, TSpec)
  c.into:
    expectTag(c, TAlwaysStutter)
    c.into:
      let initSym = takeSymId(c)
      let nextSym = takeSymId(c)
      if initSym notin m.defs: raiseEval("spec Init not defined: " & m.pool.poolSym(initSym))
      if nextSym notin m.defs: raiseEval("spec Next not defined: " & m.pool.poolSym(nextSym))
      m.initBody = m.defs[initSym].body
      m.nextBody = m.defs[nextSym].body
      m.hasSpec = true
      if c.hasMore and c.isTag(TTuple):
        c.into:
          while c.hasMore:
            m.stutterVars.add takeSymId(c)
      elif c.hasMore:
        c.skip

proc loadCheck(m: Module; c: var Cursor) =
  ## (check InvSym) or (check expr)
  expectTag(c, TCheck)
  c.into:
    if c.kind == Symbol:
      let s = c.symId
      c.inc
      if s in m.defs:
        m.checkBody = m.defs[s].body
        m.hasCheck = true
      else:
        raiseEval("check symbol not defined: " & m.pool.poolSym(s))
    else:
      m.checkBody = c
      m.hasCheck = true
      c.skip

proc loadModule*(buf: sink TokenBuf): Module =
  let p = buf.pool
  result = Module(
    buf: buf,
    pool: p,
    vs: initValues(p),
    constants: @[],
    variables: @[],
    defs: initTable[SymId, DefEntry](),
    env: initTable[SymId, Value](),
    constSet: initHashSet[SymId](),
    defInfo: initTable[SymId, DefInfo](),
    memo: initTable[Value, Value](),
    memoHits: 0,
    memoMisses: 0,
    stutterVars: @[],
    hasSpec: false,
    hasCheck: false
  )
  var c = result.buf.beginRead()
  if not c.isTag(TStmts):
    raiseEval("module root must be (stmts ...)")
  c.into:
    while c.hasMore:
      if c.kind != TagLit:
        raiseEval("unexpected top-level atom")
      let tag = tlaTag(c.cursorTagId)
      case tag
      of TExtends: skipExtends(c)
      of TConstants: loadConstants(result, c)
      of TVariables: loadVariables(result, c)
      of TModels: loadModels(result, c)
      of TAssign: loadAssign(result, c)
      of TDef: loadDefs(result, c)
      of TSpec: loadSpec(result, c)
      of TCheck: loadCheck(result, c)
      else:
        raiseEval("unsupported top-level tag: " & $tag)

  # Everything grounded in `env` at load time (models + assigns) is constant
  # for the whole run, so it can be dropped from memo keys.
  for k in result.env.keys:
    result.constSet.incl k

  if result.variables.len == 0:
    raiseEval("no variables declared")
  if not result.hasSpec:
    raiseEval("missing (spec ...)")
  if not result.hasCheck:
    raiseEval("missing (check ...)")

proc loadModuleFile*(path: string): Module =
  loadModule(loadTlaFile(path))

proc loadModuleBuffer*(input: string; thisModule = "tla"): Module =
  loadModule(loadTlaBuffer(input, thisModule))

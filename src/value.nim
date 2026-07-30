## Finite TLA values — NIF-backed, same shape as `std/json`.
##
## A value is **not** a heap `ref` ADT; it is a flat `nifcore.TokenBuf`
## navigated with a `Value` (thin `Cursor` wrapper). Encoding:
##
##   null    → (null)
##   true    → (true)
##   false   → (false)
##   42      → IntLit 42
##   model   → Symbol  (SymId in the shared literals Pool)
##   {a,b}   → (set a b)          # elements sorted unique
##   <<a,b>> → (seq a b)
##   fun     → (fun (mapsto k v) ...)
##   record  → (record (kv :field v) ...)

import std / [hashes, tables, strutils, algorithm, assertions]
import nifcore

type
  ValueTag* = enum
    ## Tag-side kinds. BiTable ids start at 1; `tagId` / `valueTag` shim +/- 1.
    VTNull   = (0, "null")
    VTTrue   = (1, "true")
    VTFalse  = (2, "false")
    VTSet    = (3, "set")
    VTSeq    = (4, "seq")
    VTFun    = (5, "fun")
    VTMapsto = (6, "mapsto")
    VTRecord = (7, "record")
    VTKv     = (8, "kv")

  ValueKind* = enum
    ## High-level kind (tags + atoms), like `JsonNodeKind`.
    vkNull, vkBool, vkInt, vkModel, vkSet, vkSeq, vkFun, vkRecord

  Values* = object
    ## Factory: shared literals Pool (must match the spec module for SymIds)
    ## and a dedicated ValueTag pool.
    pool*: Pool
    tags*: TagPool

  ValueTree* = object
    ## Owns one value's token buffer. Move-only.
    buf*: TokenBuf

  Value* = object
    ## Handle to one value: a refcounted `Cursor` into a `ValueTree`.
    c*: Cursor

proc `=copy`(dest: var ValueTree; src: ValueTree) {.error.}

template tagId*(k: ValueTag): TagId = TagId(uint32(k) + 1'u32)
template valueTag*(t: TagId): ValueTag = cast[ValueTag](uint32(t) - 1'u32)

proc initValues*(pool: Pool): Values =
  Values(pool: pool, tags: createTags[ValueTag]())

proc createValueTree*(vs: Values): ValueTree =
  ValueTree(buf: createTokenBuf(16, vs.pool, vs.tags))

# ── Construction (nifcore `buildTree` style) ──────────────────────────────

proc seal(t: var ValueTree): Value =
  ## Root cursor; TokenBuf may be destroyed afterward — Cursor RC keeps data.
  Value(c: t.buf.beginRead())

template buildValue*(vs: Values; body: untyped): Value =
  ## Mint a fresh `ValueTree` as injected `t`, run `body` (emit into `t`),
  ## then seal to a `Value`. Mirrors `TokenBuf.buildTree`: the buffer is the
  ## construction site, not a `seq` of finished nodes.
  var t {.inject.} = createValueTree(vs)
  body
  seal(t)

template buildTree*(t: var ValueTree; tag: ValueTag; body: untyped) =
  t.buf.buildTree tag.tagId:
    body

proc addNull*(t: var ValueTree) {.inline.} =
  t.buildTree VTNull:
    discard

proc addBool*(t: var ValueTree; x: bool) {.inline.} =
  t.buildTree (if x: VTTrue else: VTFalse):
    discard

proc addInt*(t: var ValueTree; x: int64) {.inline.} =
  t.buf.addIntLit x

proc addModel*(t: var ValueTree; s: SymId) {.inline.} =
  t.buf.addSymUse s

proc addValue*(t: var ValueTree; v: Value) {.inline.} =
  t.buf.addSubtree v.c

proc addMapsto*(t: var ValueTree; k, v: Value) {.inline.} =
  t.buildTree VTMapsto:
    t.addValue k
    t.addValue v

proc addKv*(t: var ValueTree; field: SymId; v: Value) {.inline.} =
  t.buildTree VTKv:
    t.addModel field
    t.addValue v

proc cmpValue*(a, b: Value): int

proc rawKind(v: Value): NifKind {.inline.} = nifcore.kind(v.c)
proc cursorTagId(v: Value): TagId {.inline.} = nifcore.cursorTagId(v.c)
proc intVal(v: Value): int64 {.inline.} = intVal(v.c)
proc symId(v: Value): SymId {.inline.} = symId(v.c)
proc symName(v: Value): string {.inline.} = symName(v.c)
proc skip(v: var Value) {.inline.} = skip v.c
proc inc(v: var Value) {.inline.} = inc v.c
template hasMore(v: Value): bool = hasMore(v.c)
template into(v: var Value; body: untyped) = into(v.c, body)

proc kind*(v: Value): ValueKind =
  case rawKind(v)
  of IntLit, UIntLit: vkInt
  of Symbol, SymbolDef: vkModel
  of TagLit:
    case valueTag(v.cursorTagId)
    of VTNull: vkNull
    of VTTrue, VTFalse: vkBool
    of VTSet: vkSet
    of VTSeq: vkSeq
    of VTFun: vkFun
    of VTRecord: vkRecord
    of VTMapsto, VTKv: vkNull
  else: vkNull

proc getBool*(v: Value; default = false): bool =
  if rawKind(v) == TagLit:
    case valueTag(v.cursorTagId)
    of VTTrue: return true
    of VTFalse: return false
    else: discard
  default

proc getInt*(v: Value; default: int64 = 0): int64 =
  case rawKind(v)
  of IntLit: intVal(v)
  of UIntLit: int64(uintVal(v.c))
  else: default

proc getModel*(v: Value): SymId =
  assert kind(v) == vkModel
  symId(v)

proc len*(v: Value): int =
  result = 0
  case kind(v)
  of vkSet, vkSeq, vkFun, vkRecord:
    var c = v
    c.into:
      while c.hasMore:
        inc result
        c.skip
  else: discard

iterator items*(v: Value): Value =
  {.cast(noSideEffect).}:
    assert kind(v) in {vkSet, vkSeq}
    var c = v
    c.into:
      while c.hasMore:
        yield c
        c.skip

iterator pairs*(v: Value): (Value, Value) =
  ## Function pairs `(mapsto k v)`.
  ## After `into` the cursor is already past the `mapsto` node — do not `skip` again.
  {.cast(noSideEffect).}:
    assert kind(v) == vkFun
    var c = v
    c.into:
      while c.hasMore:
        assert rawKind(c) == TagLit and valueTag(c.cursorTagId) == VTMapsto
        var k, val: Value
        c.into:
          k = c
          c.skip
          val = c
          c.skip
        yield (k, val)

iterator fields*(v: Value): (SymId, Value) =
  ## Record fields `(kv :sym v)`.
  ## After `into` the cursor is already past the `kv` node — do not `skip` again.
  {.cast(noSideEffect).}:
    assert kind(v) == vkRecord
    var c = v
    c.into:
      while c.hasMore:
        assert rawKind(c) == TagLit and valueTag(c.cursorTagId) == VTKv
        var sid: SymId
        var val: Value
        c.into:
          case rawKind(c)
          of Symbol, SymbolDef:
            sid = symId(c)
            c.inc
          else:
            raiseAssert "record kv needs Symbol"
          val = c
          c.skip
        yield (sid, val)

# ── Structural eq / cmp / hash ───────────────────────────────────────────

proc `==`*(a, b: Value): bool =
  if rawKind(a) != rawKind(b): return false
  let ka = kind(a)
  if ka != kind(b): return false
  case ka
  of vkNull: true
  of vkBool: getBool(a) == getBool(b)
  of vkInt: getInt(a) == getInt(b)
  of vkModel: getModel(a) == getModel(b)
  of vkSet, vkSeq:
    if len(a) != len(b): return false
    var ca = a
    var cb = b
    ca.into:
      cb.into:
        while ca.hasMore:
          if ca != cb: return false
          ca.skip
          cb.skip
    true
  of vkFun:
    if len(a) != len(b): return false
    var ca = a
    var cb = b
    ca.into:
      cb.into:
        while ca.hasMore:
          var ka2, va, kb2, vb: Value
          ca.into:
            ka2 = ca; ca.skip; va = ca; ca.skip
          cb.into:
            kb2 = cb; cb.skip; vb = cb; cb.skip
          if ka2 != kb2 or va != vb: return false
    true
  of vkRecord:
    if len(a) != len(b): return false
    var ca = a
    var cb = b
    ca.into:
      cb.into:
        while ca.hasMore:
          var sa, sb: SymId
          var va, vb: Value
          ca.into:
            sa = symId(ca); ca.inc; va = ca; ca.skip
          cb.into:
            sb = symId(cb); cb.inc; vb = cb; cb.skip
          if sa != sb or va != vb: return false
    true

proc cmpValue*(a, b: Value): int =
  result = cmp(ord(kind(a)), ord(kind(b)))
  if result != 0: return
  case kind(a)
  of vkNull: discard
  of vkBool: result = cmp(ord(getBool(a)), ord(getBool(b)))
  of vkInt: result = cmp(getInt(a), getInt(b))
  of vkModel: result = cmp(getModel(a).uint32, getModel(b).uint32)
  of vkSet, vkSeq:
    result = cmp(len(a), len(b))
    if result != 0: return
    var ca = a
    var cb = b
    ca.into:
      cb.into:
        while ca.hasMore:
          result = cmpValue(ca, cb)
          if result != 0: return
          ca.skip
          cb.skip
  of vkFun:
    result = cmp(len(a), len(b))
    if result != 0: return
    var ca = a
    var cb = b
    ca.into:
      cb.into:
        while ca.hasMore:
          var ka2, va, kb2, vb: Value
          ca.into:
            ka2 = ca; ca.skip; va = ca; ca.skip
          cb.into:
            kb2 = cb; cb.skip; vb = cb; cb.skip
          result = cmpValue(ka2, kb2)
          if result != 0: return
          result = cmpValue(va, vb)
          if result != 0: return
  of vkRecord:
    result = cmp(len(a), len(b))
    if result != 0: return
    var ca = a
    var cb = b
    ca.into:
      cb.into:
        while ca.hasMore:
          var sa, sb: SymId
          var va, vb: Value
          ca.into:
            sa = symId(ca); ca.inc; va = ca; ca.skip
          cb.into:
            sb = symId(cb); cb.inc; vb = cb; cb.skip
          result = cmp(sa.uint32, sb.uint32)
          if result != 0: return
          result = cmpValue(va, vb)
          if result != 0: return

proc hash*(v: Value): Hash =
  result = hash(ord(kind(v)))
  case kind(v)
  of vkNull: discard
  of vkBool: result = result !& hash(getBool(v))
  of vkInt: result = result !& hash(getInt(v))
  of vkModel: result = result !& hash(getModel(v))
  of vkSet, vkSeq:
    for e in items(v):
      result = result !& hash(e)
  of vkFun:
    for (k, x) in pairs(v):
      result = result !& hash(k) !& hash(x)
  of vkRecord:
    for (k, x) in fields(v):
      result = result !& hash(k) !& hash(x)
  result = !$result

# ── Set / fun helpers ────────────────────────────────────────────────────

proc contains*(s: Value; x: Value): bool =
  assert kind(s) == vkSet
  for e in items(s):
    if e == x: return true
  false

proc card*(s: Value): int64 =
  assert kind(s) == vkSet
  len(s)

proc subset*(a, b: Value): bool =
  assert kind(a) == vkSet and kind(b) == vkSet
  for e in items(a):
    if e notin b: return false
  true

proc collectItems*(s: Value): seq[Value] =
  result = @[]
  for e in items(s):
    result.add e

proc sortedUniqueSet*(vs: Values; elems: var seq[Value]): Value =
  elems.sort(cmpValue)
  buildValue(vs):
    t.buildTree VTSet:
      var i = 0
      while i < elems.len:
        if i == 0 or elems[i] != elems[i - 1]:
          t.addValue elems[i]
        inc i

proc union*(vs: Values; a, b: Value): Value =
  assert kind(a) == vkSet and kind(b) == vkSet
  var xs = collectItems(a)
  for e in items(b): xs.add e
  sortedUniqueSet(vs, xs)

proc intersect*(vs: Values; a, b: Value): Value =
  assert kind(a) == vkSet and kind(b) == vkSet
  var xs: seq[Value] = @[]
  for e in items(a):
    if e in b: xs.add e
  sortedUniqueSet(vs, xs)

proc setminus*(vs: Values; a, b: Value): Value =
  assert kind(a) == vkSet and kind(b) == vkSet
  var xs: seq[Value] = @[]
  for e in items(a):
    if e notin b: xs.add e
  sortedUniqueSet(vs, xs)

proc applyFun*(f, arg: Value): Value =
  ## Function application `f[arg]`. In TLA+ a sequence is a function with
  ## domain `1..Len(f)`, so `apply` on a `vkSeq` is 1-based indexing.
  if kind(f) == vkSeq:
    assert kind(arg) == vkInt, "sequence index must be an integer"
    let i = getInt(arg)
    var pos = 1'i64
    for e in items(f):
      if pos == i: return e
      inc pos
    raiseAssert "sequence index out of range"
  assert kind(f) == vkFun
  for (k, v) in pairs(f):
    if k == arg: return v
  raiseAssert "function application: key not in domain"

proc exceptFun*(vs: Values; f: Value; updates: openArray[(Value, Value)]): Value =
  assert kind(f) == vkFun
  var ps: seq[(Value, Value)] = @[]
  for (k, v) in pairs(f):
    ps.add (k, v)
  for (k, v) in updates:
    var found = false
    for i in 0 ..< ps.len:
      if ps[i][0] == k:
        ps[i][1] = v
        found = true
        break
    if not found:
      ps.add (k, v)
  ps.sort(proc (a, b: (Value, Value)): int = cmpValue(a[0], b[0]))
  buildValue(vs):
    t.buildTree VTFun:
      for (k, v) in ps:
        t.addMapsto k, v

proc domainOf*(vs: Values; f: Value): Value =
  assert kind(f) == vkFun
  var xs: seq[Value] = @[]
  for (k, _) in pairs(f):
    xs.add k
  sortedUniqueSet(vs, xs)

proc permuteValue*(vs: Values; v: Value; perm: Table[SymId, SymId]): Value =
  ## Rewrite `v` by mapping every model symbol through `perm` (identity for
  ## symbols not in the table). Function keys and set elements are re-sorted so
  ## the canonical structural encoding is preserved.
  case kind(v)
  of vkNull, vkBool, vkInt:
    result = v
  of vkModel:
    let s = getModel(v)
    let s2 = perm.getOrDefault(s, s)
    result = buildValue(vs):
      t.addModel s2
  of vkSet:
    var xs: seq[Value] = @[]
    for e in items(v): xs.add permuteValue(vs, e, perm)
    result = sortedUniqueSet(vs, xs)
  of vkSeq:
    var xs: seq[Value] = @[]
    for e in items(v): xs.add permuteValue(vs, e, perm)
    result = buildValue(vs):
      t.buildTree VTSeq:
        for e in xs: t.addValue e
  of vkFun:
    var ps: seq[(Value, Value)] = @[]
    for (k, val) in pairs(v):
      ps.add (permuteValue(vs, k, perm), permuteValue(vs, val, perm))
    ps.sort(proc (a, b: (Value, Value)): int = cmpValue(a[0], b[0]))
    result = buildValue(vs):
      t.buildTree VTFun:
        for (k, val) in ps: t.addMapsto k, val
  of vkRecord:
    var fs: seq[(SymId, Value)] = @[]
    for (k, val) in fields(v):
      fs.add (k, permuteValue(vs, val, perm))   # field names are not objects
    fs.sort(proc (a, b: (SymId, Value)): int = cmp(a[0].uint32, b[0].uint32))
    result = buildValue(vs):
      t.buildTree VTRecord:
        for (k, val) in fs: t.addKv k, val

# ── Canonical binary encoding ────────────────────────────────────────────
#
# Serializes a value to bytes for cross-thread transfer and hashing. The
# encoding is canonical: sets, function pairs and record fields are kept
# sorted by construction everywhere, and SymIds are deterministic for a
# given spec file, so structurally equal values (even from different
# workers' pools) encode to identical bytes.

proc addU32(dest: var string; x: uint32) {.inline.} =
  dest.add char(x and 0xff)
  dest.add char((x shr 8) and 0xff)
  dest.add char((x shr 16) and 0xff)
  dest.add char((x shr 24) and 0xff)

proc readU32(src: string; pos: var int): uint32 {.inline.} =
  result = uint32(src[pos]) or (uint32(src[pos+1]) shl 8) or
           (uint32(src[pos+2]) shl 16) or (uint32(src[pos+3]) shl 24)
  inc pos, 4

proc encodeValue*(v: Value; dest: var string) =
  case kind(v)
  of vkNull:
    dest.add '\0'
  of vkBool:
    dest.add (if getBool(v): '\2' else: '\1')
  of vkInt:
    dest.add '\3'
    let x = cast[uint64](getInt(v))
    for i in 0 ..< 8:
      dest.add char((x shr (8 * i)) and 0xff)
  of vkModel:
    dest.add '\4'
    dest.addU32 uint32(getModel(v))
  of vkSet, vkSeq:
    dest.add (if kind(v) == vkSet: '\5' else: '\6')
    dest.addU32 uint32(len(v))
    for e in items(v):
      encodeValue(e, dest)
  of vkFun:
    dest.add '\7'
    dest.addU32 uint32(len(v))
    for (k, x) in pairs(v):
      encodeValue(k, dest)
      encodeValue(x, dest)
  of vkRecord:
    dest.add '\x08'
    dest.addU32 uint32(len(v))
    for (s, x) in fields(v):
      dest.addU32 uint32(s)
      encodeValue(x, dest)

proc skipEncodedValue*(src: string; pos: var int) =
  ## Advance `pos` past one encoded value without materializing it.
  let tag = src[pos]
  inc pos
  case tag
  of '\0', '\1', '\2':
    discard
  of '\3':
    inc pos, 8
  of '\4':
    inc pos, 4
  of '\5', '\6':
    let n = int(readU32(src, pos))
    for i in 0 ..< n:
      skipEncodedValue(src, pos)
  of '\7':
    let n = int(readU32(src, pos))
    for i in 0 ..< n:
      skipEncodedValue(src, pos)
      skipEncodedValue(src, pos)
  of '\x08':
    let n = int(readU32(src, pos))
    for i in 0 ..< n:
      inc pos, 4
      skipEncodedValue(src, pos)
  else:
    raiseAssert "corrupt value encoding, tag byte " & $ord(tag)

proc decodeValue*(vs: Values; src: string; pos: var int): Value =
  let tag = src[pos]
  inc pos
  case tag
  of '\0':
    result = buildValue(vs):
      t.addNull
  of '\1', '\2':
    result = buildValue(vs):
      t.addBool tag == '\2'
  of '\3':
    var x = 0'u64
    for i in 0 ..< 8:
      x = x or (uint64(src[pos + i]) shl (8 * i))
    inc pos, 8
    result = buildValue(vs):
      t.addInt cast[int64](x)
  of '\4':
    let s = SymId(readU32(src, pos))
    result = buildValue(vs):
      t.addModel s
  of '\5', '\6':
    let n = int(readU32(src, pos))
    var xs = newSeq[Value](n)
    for i in 0 ..< n:
      xs[i] = decodeValue(vs, src, pos)
    result = buildValue(vs):
      t.buildTree (if tag == '\5': VTSet else: VTSeq):
        for e in xs: t.addValue e
  of '\7':
    let n = int(readU32(src, pos))
    var ps = newSeq[(Value, Value)](n)
    for i in 0 ..< n:
      ps[i][0] = decodeValue(vs, src, pos)
      ps[i][1] = decodeValue(vs, src, pos)
    result = buildValue(vs):
      t.buildTree VTFun:
        for (k, x) in ps: t.addMapsto k, x
  of '\x08':
    let n = int(readU32(src, pos))
    var fs = newSeq[(SymId, Value)](n)
    for i in 0 ..< n:
      fs[i][0] = SymId(readU32(src, pos))
      fs[i][1] = decodeValue(vs, src, pos)
    result = buildValue(vs):
      t.buildTree VTRecord:
        for (s, x) in fs: t.addKv s, x
  else:
    raiseAssert "corrupt value encoding, tag byte " & $ord(tag)

proc toString*(v: Value; dest: var string) =
  ## Append a readable form of `v` to `dest`. Prefer this over `$` when
  ## building larger output to avoid intermediate string allocations.
  case kind(v)
  of vkNull:
    dest.add "null"
  of vkBool:
    dest.add $getBool(v)
  of vkInt:
    dest.add $getInt(v)
  of vkModel:
    dest.add symName(v)
  of vkSet:
    dest.add '{'
    var i = 0
    for e in items(v):
      if i > 0: dest.add ", "
      toString(e, dest)
      inc i
    dest.add '}'
  of vkSeq:
    dest.add "<<"
    var i = 0
    for e in items(v):
      if i > 0: dest.add ", "
      toString(e, dest)
      inc i
    dest.add ">>"
  of vkFun:
    dest.add '['
    var i = 0
    for (k, x) in pairs(v):
      if i > 0: dest.add ", "
      toString(k, dest)
      dest.add " |-> "
      toString(x, dest)
      inc i
    dest.add ']'
  of vkRecord:
    dest.add '['
    var i = 0
    let pool = v.c.pool
    for (k, x) in fields(v):
      if i > 0: dest.add ", "
      if pool != nil: dest.add pool.poolSym(k)
      else: dest.add $k.uint32
      dest.add " |-> "
      toString(x, dest)
      inc i
    dest.add ']'

proc `$`*(v: Value): string =
  result = ""
  toString(v, result)

# ── State ────────────────────────────────────────────────────────────────

type
  State* = object
    vals*: Table[SymId, Value]

proc `==`*(a, b: State): bool =
  if a.vals.len != b.vals.len: return false
  for k, v in a.vals:
    if k notin b.vals: return false
    if b.vals[k] != v: return false
  true

proc hash*(s: State): Hash =
  result = Hash(0)
  var keys: seq[SymId] = @[]
  for k in s.vals.keys: keys.add k
  keys.sort(proc (a, b: SymId): int = cmp(a.uint32, b.uint32))
  for k in keys:
    result = result !& hash(k) !& hash(s.vals[k])
  result = !$result

proc cmpState*(a, b: State): int =
  ## Total order over states (same variable keys assumed), by variable SymId
  ## then value. Used to pick the canonical representative of a symmetry class.
  var keys: seq[SymId] = @[]
  for k in a.vals.keys: keys.add k
  keys.sort(proc (x, y: SymId): int = cmp(x.uint32, y.uint32))
  for k in keys:
    if k notin b.vals: return 1
    result = cmpValue(a.vals[k], b.vals[k])
    if result != 0: return
  result = 0

proc toString*(s: State; dest: var string) =
  dest.add '['
  var keys: seq[SymId] = @[]
  for k in s.vals.keys: keys.add k
  keys.sort(proc (a, b: SymId): int = cmp(a.uint32, b.uint32))
  for i, k in keys:
    if i > 0: dest.add ", "
    let pool = s.vals[k].c.pool
    if pool != nil: dest.add pool.poolSym(k)
    else: dest.add $k.uint32
    dest.add '='
    toString(s.vals[k], dest)
  dest.add ']'

proc `$`*(s: State): string =
  result = ""
  toString(s, result)

proc copyState*(s: State): State =
  result = State(vals: initTable[SymId, Value]())
  for k, v in s.vals:
    result.vals[k] = v

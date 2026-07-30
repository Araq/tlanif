## TLA-on-NIF dialect tags and load helpers.
##
## Entity names are always `Symbol` / `SymbolDef` (never `Ident`).
## Operators and structure are tags.

import std / assertions
import nifcore, nifcoreparse

export nifcore, nifcoreparse

type
  TlaTag* = enum
    TStmts         = (0, "stmts")
    TExtends       = (1, "extends")
    TConstants     = (2, "constants")
    TVariables     = (3, "variables")
    TModels        = (4, "models")
    TAssign        = (5, "assign")
    TDef           = (6, "def")
    TSpec          = (7, "spec")
    TCheck         = (8, "check")
    TAlwaysStutter = (9, "always-stutter")
    TTuple         = (10, "tuple")
    TAnd           = (11, "and")
    TOr            = (12, "or")
    TNot           = (13, "not")
    TEq            = (14, "eq")
    TNeq           = (15, "neq")
    TIn            = (16, "in")
    TNotin         = (17, "notin")
    TSubset        = (18, "subset")
    TUnion         = (19, "union")
    TIntersect     = (20, "intersect")
    TSetminus      = (21, "setminus")
    TCard          = (22, "card")
    TExists        = (23, "exists")
    TForall        = (24, "forall")
    TLet           = (25, "let")
    TBind          = (26, "bind")
    TIf            = (27, "if")
    TCase          = (28, "case")
    TExcept        = (29, "except")
    TMapsto        = (30, "mapsto")
    TPrime         = (31, "prime")
    TUnchanged     = (32, "unchanged")
    TFun           = (33, "fun")
    TFunof         = (34, "funof")
    TRecord        = (35, "record")
    TKv            = (36, "kv")
    TSeq           = (37, "seq")
    TAppend        = (38, "append")
    TConcat        = (39, "concat")
    TLen           = (40, "len")
    TChoose        = (41, "choose")
    TSet           = (42, "set")
    TSetcomp       = (43, "setcomp")
    TRange         = (44, "range")
    TTrue          = (45, "true")
    TFalse         = (46, "false")
    TNull          = (47, "null")
    TBool          = (48, "bool")
    TAt            = (49, "at")          ## EXCEPT `@` — current function value
    TDomain        = (50, "domain")
    TApply         = (51, "apply")       ## f[x]
    TGt            = (52, "gt")
    TGe            = (53, "ge")
    TLt            = (54, "lt")
    TLe            = (55, "le")
    TPlus          = (56, "plus")
    TMinus         = (57, "minus")
    TImplies       = (58, "implies")
    TField         = (59, "field")     ## (field record Sym) — record field access
    TEmptySet      = (60, "emptyset")  ## shorthand for (set)
    TEmptySeq      = (61, "emptyseq")  ## shorthand for (seq)

template tagId*(k: TlaTag): TagId = TagId(uint32(k) + 1'u32)
template tlaTag*(t: TagId): TlaTag = cast[TlaTag](uint32(t) - 1'u32)

proc createTlaTags*(): TagPool = createTags[TlaTag]()

proc expectTag*(c: Cursor; k: TlaTag) =
  assert c.kind == TagLit, "expected tag, got " & $c.kind
  assert c.cursorTagId == k.tagId,
    "expected tag " & $k & ", got " & c.tags.tagName(c.cursorTagId)

proc isTag*(c: Cursor; k: TlaTag): bool {.inline.} =
  c.kind == TagLit and c.cursorTagId == k.tagId

proc takeSymId*(c: var Cursor): SymId =
  ## Read a `Symbol` or `SymbolDef` and advance. Rejects `Ident`.
  case c.kind
  of Symbol, SymbolDef:
    result = c.symId
    c.inc
  of Ident:
    raiseAssert "TLA-NIF: Ident is not a valid entity name (use Symbol/SymbolDef): " &
                c.strVal
  else:
    raiseAssert "TLA-NIF: expected Symbol/SymbolDef, got " & $c.kind

proc peekSymId*(c: Cursor): SymId =
  case c.kind
  of Symbol, SymbolDef: c.symId
  of Ident:
    raiseAssert "TLA-NIF: Ident is not a valid entity name: " & c.strVal
  else:
    raiseAssert "TLA-NIF: expected Symbol/SymbolDef, got " & $c.kind

proc loadTlaFile*(filename: string): TokenBuf =
  result = parseFromFile(filename, sharedTags = createTlaTags())

proc loadTlaBuffer*(input: string; thisModule = "tla"): TokenBuf =
  result = parseFromBuffer(input, thisModule, sharedTags = createTlaTags())

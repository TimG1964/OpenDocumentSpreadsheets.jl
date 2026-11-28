# References as ODF stores them, and the operations that rewrite them (phase 5: D-050, D-053, D-054).
#
# Two grammars hold references (F-044):
#   - formulas: bracketed references, `of:=SUM([.A3:.A8];[$Other.B2])`, also in named expressions,
#     validation conditions and conditional-format conditions
#   - range lists: unbracketed areas separated by spaces, `$Data.$A$5:.$A$8 Data.A1:Data.F12`, in named
#     ranges, base and target addresses, print ranges, shape anchors and chart series
# A reference is one end, or two ends joined by ':'. Each end is parsed without loss: its sheet (quoted
# or not, with its `$`), its column and row (with their `$`; either may be missing in whole rows and
# columns), or `#REF!`. Ends that an operation doesn't change are written back as they were, so text
# without changes comes back as the same string.
#
# The operations follow LibreOffice (experiments 021 and 022; F-043 to F-047):
#   LineShift    rows or columns inserted or deleted on a sheet
#   SheetRename  a sheet renamed
#   SheetDelete  a sheet deleted
#   SheetCopy    the text of a sheet's copy (references to the source move to the copy)

"""
    RefEnd

One end of a stored reference: `\$'My sheet'.\$A\$1`, `.B2`, `Data.A:`… Fields:
- `text`: the end as written
- `sheet`: the sheet's name (unquoted), or `nothing` when none is written (`.A1`: the sheet the text
  belongs to); `sheet_abs`: written with `\$`; `sheet_text`: the sheet part as written
- `dot`: the address follows a `.`
- `col`, `row`: 1-based, or 0 when the end has none (a whole row or column); `col_abs`, `row_abs`
- `err`: the end is `#REF!` (or names the sheet `#REF!`)
"""
struct RefEnd
    text::String
    sheet::Union{Nothing,String}
    sheet_abs::Bool
    sheet_text::String
    dot::Bool
    col::Int
    col_abs::Bool
    row::Int
    row_abs::Bool
    err::Bool
end

_coord(e::RefEnd, axis::Int) = axis == 1 ? e.row : e.col
_isabs(e::RefEnd, axis::Int) = axis == 1 ? e.row_abs : e.col_abs
_axis_max(axis::Int) = axis == 1 ? SheetCore.MAX_ROWS : SheetCore.MAX_COLS

# The index of the '.' between the sheet and the address (the last one outside quotes), or 0.
function _sheet_dot(s::AbstractString)
    inq = false
    dot = 0
    for i in eachindex(s)
        c = s[i]
        if c == '\''
            inq = !inq                 # '' inside a quoted name toggles twice
        elseif c == '.' && !inq
            dot = i
        end
    end
    return dot
end

"""
    parse_ref_end(s) -> Union{RefEnd,Nothing}

One end of a reference as stored. `nothing` if it isn't one this parser knows (it is then left
alone by every operation).
"""
function parse_ref_end(s::AbstractString)
    s = String(s)
    isempty(s) && return nothing
    s == "#REF!" && return RefEnd(s, nothing, false, "", false, 0, false, 0, false, true)
    j = _sheet_dot(s)
    sheet = nothing
    sabs = false
    stext = ""
    addr = s
    if j > 0
        stext = String(SubString(s, 1, prevind(s, j)))
        addr = String(SubString(s, nextind(s, j)))
        if !isempty(stext)
            sp = stext
            if startswith(sp, '$')
                sabs = true
                sp = String(SubString(sp, 2))
            end
            if startswith(sp, '\'')
                (ncodeunits(sp) >= 2 && endswith(sp, '\'')) || return nothing
                sheet = SheetCore.unquoteit(sp)
            else
                isempty(sp) && return nothing
                sheet = sp
            end
        end
    end
    err = sheet == "#REF!"
    if addr == "#REF!"
        return RefEnd(s, sheet, sabs, stext, j > 0, 0, false, 0, false, true)
    end
    # [$]LETTERS[$]DIGITS, [$]LETTERS, or [$]DIGITS
    i = 1
    n = ncodeunits(addr)
    cabs = i <= n && codeunit(addr, i) == UInt8('$')
    k = cabs ? i + 1 : i
    k0 = k
    col = 0
    while k <= n && UInt8('A') <= codeunit(addr, k) <= UInt8('Z')
        col = col * 26 + Int(codeunit(addr, k) - UInt8('A') + 1)
        col > SheetCore.MAX_COLS && return nothing
        k += 1
    end
    if k == k0
        col = 0
        cabs && (k = i)              # a lone '$' belongs to the row
        cabs = false
    end
    rabs = k <= n && codeunit(addr, k) == UInt8('$')
    rabs && (k += 1)
    r0 = k
    row = 0
    while k <= n && UInt8('0') <= codeunit(addr, k) <= UInt8('9')
        row = row * 10 + Int(codeunit(addr, k) - UInt8('0'))
        row > 10_000_000 && return nothing
        k += 1
    end
    k == r0 && (row = 0; rabs && return nothing)
    k <= n && return nothing                     # anything else after the address
    (col == 0 && row == 0) && return nothing
    col > SheetCore.MAX_COLS && return nothing
    return RefEnd(s, sheet, sabs, stext, j > 0, col, cabs, row, rabs, err)
end

# The end with a new sheet, columns or rows; its text rebuilt. `quote` writes a new sheet name.
function _with(e::RefEnd; sheet = e.sheet, sheet_text = e.sheet_text, col = e.col, row = e.row)
    io = IOBuffer()
    print(io, sheet_text)
    (e.dot || !isempty(sheet_text)) && print(io, '.')
    col > 0 && (e.col_abs && print(io, '$'); print(io, SheetCore.encode_column_number(col)))
    row > 0 && (e.row_abs && print(io, '$'); print(io, row))
    return RefEnd(String(take!(io)), sheet, e.sheet_abs, sheet_text, e.dot || !isempty(sheet_text),
                  col, e.col_abs, row, e.row_abs, e.err)
end

_sheet_text(e::RefEnd, name::AbstractString) = (e.sheet_abs ? "\$" : "") * SheetCore.quoteit(name)
_with_sheet(e::RefEnd, name::AbstractString) = _with(e; sheet = String(name), sheet_text = _sheet_text(e, name))

# Sheet names match without regard to case, as LibreOffice's do: the one rule of model/workbook.jl (F-093).
_same_sheet(a::AbstractString, b::AbstractString) = _same_sheetname(a, b)
_same_sheet(::Nothing, ::AbstractString) = false
_sheet_index(order::Vector{String}, name::AbstractString) = findfirst(s -> _same_sheet(s, name), order)

"""
    parse_ref(inner) -> Union{Vector{RefEnd},Nothing}

A reference (one or two ends joined by `:`), without brackets. `nothing` for a reference to another
document (`'file:///…'#\$Sheet1.A1`) or one this parser doesn't know: every operation leaves those
alone.
"""
function parse_ref(inner::AbstractString)
    isempty(inner) && return nothing
    if startswith(inner, '\'')               # an external reference: 'url'#…
        k = nextind(inner, 1)
        while k <= lastindex(inner)
            if inner[k] == '\''
                k2 = nextind(inner, k)
                k2 <= lastindex(inner) && inner[k2] == '\'' && (k = nextind(inner, k2); continue)
                k2 <= lastindex(inner) && inner[k2] == '#' && return nothing
                break
            end
            k = nextind(inner, k)
        end
    end
    parts = SheetCore._split_unquoted(inner, (':',))
    length(parts) > 2 && return nothing
    ends = RefEnd[]
    for p in parts
        e = parse_ref_end(p)
        e === nothing && return nothing
        push!(ends, e)
    end
    return ends
end

render_ref(ends::Vector{RefEnd}) = join((e.text for e in ends), ':')

# --- the operations ------------------------------------------------------------------------------

# `RefOp`, their type, is declared with the file's struct (model/workbook.jl).

"""
    LineShift(sheet, axis, at, n, order)

Rows (`axis == 1`) or columns (`axis == 2`) of `sheet`: `n > 0` lines inserted before line `at`;
`n < 0`: lines `at … at-n-1` deleted. `order` is the sheets' order (for 3-D references).
"""
struct LineShift <: RefOp
    sheet::String
    axis::Int
    at::Int
    n::Int
    order::Vector{String}
end

"""
    SheetRename(old, new)
"""
struct SheetRename <: RefOp
    old::String
    new::String
end

"""
    SheetDelete(name, order)

`order`: the sheets' order before the deletion.
"""
struct SheetDelete <: RefOp
    name::String
    order::Vector{String}
end

"""
    SheetCopy(src, dst, all, order)

Applied to the text of `dst`, a copy of `src`; `order` is the sheets' order after the copy. As
LibreOffice keeps them: a reference written with a relative sheet keeps its distance in the
sheet order, so one to `src` moves to `dst`, and one to the sheet before `src` goes to the sheet
before `dst` (`#REF!` past the ends). With `all` (the copy's local names), references to `src` with
an absolute sheet move to `dst` too.
"""
struct SheetCopy <: RefOp
    src::String
    dst::String
    all::Bool
    order::Vector{String}
end

"""
    RefContext(sheet; row = 0, col = 0, names = false, marked = true, expand = false)

Where the text being rewritten lives:
- `sheet`: the sheet that unqualified references (`[.A1]`) mean
- `row`, `col`: the formula's cell, or 0 (the end-of-sheet quirk of F-043 moves relative parts with it)
- `names`: the text is a name's: its relative coordinates are offsets from the base, and are not
  shifted
- `marked`: a reference that loses its sheet or cells becomes `#REF!`. When false (chart series,
  shapes' end cells, names' bases), a reference whose lines are all deleted is left as
  it was, and a deleted sheet is replaced by the sheet before it
- `expand`: lines inserted just after the range grow it (conditional formats' targets)
"""
struct RefContext
    sheet::String
    row::Int
    col::Int
    names::Bool
    marked::Bool
    expand::Bool
end
RefContext(sheet::AbstractString; row::Integer = 0, col::Integer = 0, names::Bool = false,
           marked::Bool = true, expand::Bool = false) =
    RefContext(String(sheet), row, col, names, marked, expand)

const _REFERR = :ref       # the result of an operation that leaves #REF!

# The sheets of a reference's two ends (unqualified ones mean the context's sheet; a second end
# without a sheet is on the first's).
function _ref_sheets(ends::Vector{RefEnd}, ctx::RefContext)
    s1 = something(ends[1].sheet, ctx.sheet)
    s2 = length(ends) == 2 ? something(ends[2].sheet, s1) : s1
    return s1, s2
end

# `nothing`: unchanged; `_REFERR`: #REF!; else the new ends.
function _apply(op::LineShift, ends::Vector{RefEnd}, ctx::RefContext)
    r = _shift(op, ends, ctx)
    return r === _REFERR && !ctx.marked ? nothing : r      # unmarked references keep their address
end

function _shift(op::LineShift, ends::Vector{RefEnd}, ctx::RefContext)
    any(e -> e.err, ends) && return nothing
    s1, s2 = _ref_sheets(ends, ctx)
    ax = op.axis
    if !_same_sheet(s1, s2)                          # 3-D: only a delete across it matters (F-043)
        op.n > 0 && return nothing
        i1 = _sheet_index(op.order, s1); i2 = _sheet_index(op.order, s2); io = _sheet_index(op.order, op.sheet)
        (i1 === nothing || i2 === nothing || io === nothing) && return nothing
        min(i1, i2) <= io <= max(i1, i2) || return nothing
        v1 = _coord(ends[1], ax); v2 = _coord(ends[end], ax)
        (v1 == 0 || v2 == 0) && return nothing
        d1 = op.at; d2 = op.at - op.n - 1
        return min(v1, v2) <= d2 && max(v1, v2) >= d1 ? _REFERR : nothing
    end
    _same_sheet(s1, op.sheet) || return nothing
    MAX = _axis_max(ax)
    if length(ends) == 1
        e = ends[1]
        v = _coord(e, ax)
        v == 0 && return nothing
        ctx.names && !_isabs(e, ax) && return nothing
        if op.n > 0
            ctx.expand && op.at == v + 1 && return [e, _set(e, ax, min(v + op.n, MAX))]
            v >= op.at || return nothing
            v + op.n > MAX && return _REFERR
            return [_set(e, ax, v + op.n)]
        end
        cnt = -op.n; d1 = op.at; d2 = op.at + cnt - 1
        v < d1 && return nothing
        v <= d2 && return _REFERR
        return [_set(e, ax, v - cnt)]
    end
    e1, e2 = ends
    a = _coord(e1, ax); b = _coord(e2, ax)
    (a == 0 || b == 0) && return nothing               # a whole column for a row edit, or the reverse
    fix1 = ctx.names && !_isabs(e1, ax)                # names' relative parts are offsets
    fix2 = ctx.names && !_isabs(e2, ax)
    fix1 && fix2 && return nothing
    swapped = a > b
    lo, hi = minmax(a, b)
    if op.n > 0
        if lo >= op.at
            nlo = lo + op.n
            nlo > MAX && return _REFERR
            nhi = min(hi + op.n, MAX)
        elseif hi >= op.at || (ctx.expand && op.at == hi + 1)
            nlo = lo; nhi = min(hi + op.n, MAX)
        else
            return nothing
        end
    else
        cnt = -op.n; d1 = op.at; d2 = op.at + cnt - 1
        if hi == MAX && d1 > lo
            # F-043's quirk: LibreOffice leaves this reference un-updated, so its relative parts move
            # only as the formula's cell moves, and its absolute parts stay
            cell = ax == 1 ? ctx.row : ctx.col
            m = (cell > d2 && _same_sheet(ctx.sheet, op.sheet)) ? -cnt : 0
            m == 0 && return nothing
            ea, eb = swapped ? (e2, e1) : (e1, e2)
            nlo = _isabs(ea, ax) ? lo : lo + m
            nhi = _isabs(eb, ax) ? hi : hi + m
        else
            nlo = lo < d1 ? lo : (lo > d2 ? lo - cnt : d1)
            nhi = hi == MAX ? MAX : (hi < d1 ? hi : (hi > d2 ? hi - cnt : d1 - 1))
            nlo > nhi && return _REFERR
        end
    end
    na, nb = swapped ? (nhi, nlo) : (nlo, nhi)
    fix1 && (na = a)
    fix2 && (nb = b)
    (na == a && nb == b) && return nothing
    return [na == a ? e1 : _set(e1, ax, na), nb == b ? e2 : _set(e2, ax, nb)]
end

_set(e::RefEnd, axis::Int, v::Int) = axis == 1 ? _with(e; row = v) : _with(e; col = v)

# A formula moved `d` rows as if copied, as LibreOffice's sort moves the formulas it sorts (F-072): its
# relative rows move with it, its absolute ones stay; a row moved off the sheet is #REF!. Not logged
# with the structural operations: nothing else changes.
struct RowMove <: RefOp
    d::Int
end

function _apply(op::RowMove, ends::Vector{RefEnd}, ctx::RefContext)
    any(e -> e.err, ends) && return nothing
    changed = false
    new = RefEnd[]
    for e in ends
        if e.row == 0 || e.row_abs
            push!(new, e)
        else
            v = e.row + op.d
            1 <= v <= SheetCore.MAX_ROWS || return ctx.marked ? _REFERR : nothing
            push!(new, _set(e, 1, v)); changed = true
        end
    end
    return changed ? new : nothing
end

function _apply(op::SheetRename, ends::Vector{RefEnd}, ctx::RefContext)
    changed = false
    new = map(ends) do e
        if e.sheet !== nothing && _same_sheet(e.sheet, op.old) && e.sheet != op.new
            changed = true
            return _with_sheet(e, op.new)
        end
        return e
    end
    return changed ? new : nothing
end

function _apply(op::SheetCopy, ends::Vector{RefEnd}, ctx::RefContext)
    before = filter(s -> !_same_sheet(s, op.dst), op.order)        # the order the text was written in
    isrc = _sheet_index(before, op.src)
    idst = _sheet_index(op.order, op.dst)
    (isrc === nothing || idst === nothing) && return nothing
    new = RefEnd[]
    for e in ends
        if e.sheet === nothing
            push!(new, e)
        elseif e.sheet_abs
            push!(new, op.all && _same_sheet(e.sheet, op.src) ? _with_sheet(e, op.dst) : e)
        else
            i = _sheet_index(before, e.sheet)
            i === nothing && (push!(new, e); continue)
            j = idst + (i - isrc)
            1 <= j <= length(op.order) || return _REFERR
            push!(new, _same_sheet(e.sheet, op.order[j]) ? e : _with_sheet(e, op.order[j]))
        end
    end
    return all(((x, y),) -> x === y, zip(new, ends)) ? nothing : new
end

function _apply(op::SheetDelete, ends::Vector{RefEnd}, ctx::RefContext)
    any(e -> e.err, ends) && return nothing
    s1, s2 = _ref_sheets(ends, ctx)
    d1 = _same_sheet(s1, op.name); d2 = _same_sheet(s2, op.name)
    (d1 || d2) || return nothing
    if !ctx.marked
        # F-047: the sheet before the deleted one, or the new first sheet
        i = _sheet_index(op.order, op.name)
        i === nothing && return nothing
        length(op.order) < 2 && return _REFERR
        target = i > 1 ? op.order[i - 1] : op.order[2]
        new = [e.sheet !== nothing && _same_sheet(e.sheet, op.name) ? _with_sheet(e, target) : e for e in ends]
        return all(((x, y),) -> x === y, zip(new, ends)) ? nothing : new
    end
    _same_sheet(s1, s2) && return _REFERR
    # 3-D: the deleted end moves one sheet inward (F-047)
    i1 = _sheet_index(op.order, s1); i2 = _sheet_index(op.order, s2)
    (i1 === nothing || i2 === nothing) && return _REFERR
    step = i1 < i2 ? 1 : -1
    e1, e2 = ends[1], ends[end]
    if d1
        e1 = _with_sheet(e1, op.order[i1 + step])
        e2.sheet === nothing && (e2 = _with_sheet(e2, s2))
    else
        e2 = _with_sheet(e2, op.order[i2 - step])
    end
    return [e1, e2]
end

# --- the two grammars ------------------------------------------------------------------------------

"""
    rewrite_formula(text, op, ctx) -> String

A formula (or any formula-grammar text: a named expression, a validation or conditional-format
condition) with its bracketed references rewritten by `op`. The text is returned unchanged (the same
string) when no reference changes. A reference that becomes invalid is written `[#REF!]`.
"""
function rewrite_formula(text::AbstractString, op::RefOp, ctx::RefContext)
    s = String(text)
    occursin('[', s) || return s
    out = nothing
    pos = 1                     # the next byte of s to copy
    off = 0                     # the bytes before the current token (the tokens cover s exactly)
    for t in tokenize_formula(s)
        a = off + 1
        off += ncodeunits(t.text)
        t.kind === FT_REF || continue
        ends = parse_ref(_ref_inner(t.text))
        ends === nothing && continue
        r = _apply(op, ends, ctx)
        r === nothing && continue
        out === nothing && (out = IOBuffer(sizehint = ncodeunits(s) + 16))
        print(out, SubString(s, pos, prevind(s, a)))
        print(out, '[', r === _REFERR ? "#REF!" : render_ref(r), ']')
        pos = off + 1
    end
    out === nothing && return s
    pos <= ncodeunits(s) && print(out, SubString(s, pos))
    return String(take!(out))
end

# A bracketed reference's text without its brackets.
_ref_inner(t::AbstractString) = SubString(t, nextind(t, firstindex(t)), prevind(t, lastindex(t)))

# The areas of a range list: (first, last) byte indices of each, split at spaces outside quotes.
function _areas(s::String)
    areas = Tuple{Int,Int}[]
    inq = false
    a = 0
    for i in eachindex(s)
        c = s[i]
        if c == '\''
            inq = !inq
            a == 0 && (a = i)
        elseif c == ' ' && !inq
            a > 0 && push!(areas, (a, prevind(s, i)))
            a = 0
        elseif a == 0
            a = i
        end
    end
    a > 0 && push!(areas, (a, lastindex(s)))
    return areas
end

"""
    rewrite_rangelist(text, op, ctx) -> String

A range list (`\$Data.\$A\$5:.\$A\$8`, `Data.A1:Data.F12 Data.H1`) with its areas rewritten by `op`.
An area that becomes invalid is written `#REF!`. Unchanged text is returned as the same string.
"""
function rewrite_rangelist(text::AbstractString, op::RefOp, ctx::RefContext)
    s = String(text)
    out = nothing
    pos = 1
    for (a, b) in _areas(s)
        ends = parse_ref(SubString(s, a, b))
        ends === nothing && continue
        r = _apply(op, ends, ctx)
        r === nothing && continue
        out === nothing && (out = IOBuffer(sizehint = ncodeunits(s) + 16))
        print(out, SubString(s, pos, prevind(s, a)), r === _REFERR ? "#REF!" : render_ref(r))
        pos = nextind(s, b)
    end
    out === nothing && return s
    pos <= ncodeunits(s) && print(out, SubString(s, pos))
    return String(take!(out))
end

"""
    rewrite_address(text, op, ctx) -> Union{String,Nothing}

A single cell address (a base or end cell, `\$Data.\$J\$1`) rewritten by `op`; `nothing` when it is
deleted.
"""
function rewrite_address(text::AbstractString, op::RefOp, ctx::RefContext)
    r = rewrite_rangelist(text, op, ctx)
    return r == "#REF!" && text != "#REF!" ? nothing : r
end

# --- conditional formats ---------------------------------------------------------------------------

"""
    rebase_condition(cond, base, target, op, sheet) -> Union{Tuple{String,String},Nothing}

A conditional format's condition (`formula-is([.A5]>[.A6])`), whose relative references are taken
from `base` (`Data.A1`), on the cells of `target` (a range list, `Data.B5:Data.B8`), after `op`
(applied to the target too). As LibreOffice does:
- the new base is the new target's top-left cell
- each relative reference keeps its meaning for every cell of the target: it is written as seen
  from the old top-left cell, shifted by `op`, and then read from the new base

Returns `(condition, base)`, or `nothing` when `op` changes nothing the condition means (the text is
then kept as it is) or the target is gone.
"""
function rebase_condition(cond::AbstractString, base::AbstractString, target::AbstractString, op::RefOp,
                          sheet::AbstractString)
    b = parse_ref(base)
    (b === nothing || length(b) != 1) && return nothing
    b = b[1]
    areas = _areas(String(target))
    isempty(areas) && return nothing
    tl = parse_ref(SubString(target, areas[1]...))
    tl === nothing && return nothing
    tl = tl[1]
    # a whole row's top-left cell is in column A, a whole column's in row 1 (their 0 threw, or gave `B0`)
    tlc, tlr = max(tl.col, 1), max(tl.row, 1)
    tsheet = something(tl.sheet, b.sheet, sheet)
    ctx = RefContext(tsheet)
    newtarget = rewrite_rangelist(target, op, RefContext(tsheet; expand = true))
    nareas = _areas(newtarget)
    (isempty(nareas) || SubString(newtarget, nareas[1]...) == "#REF!") && return nothing
    ntl = parse_ref(SubString(newtarget, nareas[1]...))
    ntl === nothing && return nothing
    ntl = ntl[1]
    changed = newtarget != target
    s = String(cond)
    pieces = Tuple{Int,Int,String}[]         # (first byte, last byte, new reference)
    off = 0
    for tok in tokenize_formula(s)
        a = off + 1
        off += ncodeunits(tok.text)
        tok.kind === FT_REF || continue
        ends = parse_ref(_ref_inner(tok.text))
        ends === nothing && continue
        # as seen from the old top-left cell
        seen = map(ends) do e
            e.err && return e
            c = e.col > 0 && !e.col_abs ? tlc + (e.col - b.col) : e.col
            r = e.row > 0 && !e.row_abs ? tlr + (e.row - b.row) : e.row
            (e.col > 0 && c < 1) || (e.row > 0 && r < 1) ? e : _with(e; col = c, row = r)
        end
        r = _apply(op, seen, ctx)
        r === nothing || (changed = true)
        push!(pieces, (a, off, r === nothing ? render_ref(seen) : r === _REFERR ? "#REF!" : render_ref(r)))
    end
    changed || return nothing
    out = IOBuffer()
    pos = 1
    for (a, z, new) in pieces
        print(out, SubString(s, pos, prevind(s, a)), '[', new, ']')
        pos = z + 1
    end
    pos <= ncodeunits(s) && print(out, SubString(s, pos))
    newbase = (ntl.sheet === nothing ? "" : SheetCore.quoteit(ntl.sheet) * ".") *
              SheetCore.encode_column_number(max(ntl.col, 1)) * string(max(ntl.row, 1))
    return String(take!(out)), newbase
end

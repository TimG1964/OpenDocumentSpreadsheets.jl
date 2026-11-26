# Sorting (phase 6 step 9; D-079): `setAutoFilter(...; sort)`, XLSX.jl's keyword, as LibreOffice's
# Data ▸ Sort sorts the rows below the header (experiment 037, F-072), and stored as LibreOffice
# stores it in the sheet's anonymous database range (`table:sort`, F-064).
#
# Adapted from XLSX.jl dev (src/filtersort.jl `_parse_sort`, `_sort_rows!`, `_check_sortable`), MIT
# License, Copyright (c) 2018-2026 Felipe Noronha Tavares and other contributors. Changes: LibreOffice's
# order (numbers and logicals, then text in its collator's order, then errors; descending reverses them;
# empty cells last), its refusals (merged cells unless formats stay, and here array formulas), and what
# its sort moves: each cell's value, formula (as if copied), formats and validation (`includeFormats`),
# note, links and pictures, and its row's hidden state; not row heights, and nothing that refers to
# the cells. LibreOffice's own options are keywords (D-076): `caseSensitive`, `naturalSort`,
# `includeFormats`.

struct _SortKey
    field::Int                      # the column in the range, from 0
    desc::Bool
end

function _sort_keys(ws::Worksheet, r1::Int, c1::Int, c2::Int, sort)
    keys = sort isa AbstractVector ? sort : [sort]
    isempty(keys) && throw(ODSError("`sort` needs at least one column."))
    out = _SortKey[]
    for k in keys
        col, order = k isa Pair ? (first(k), last(k)) : (k, :ascending)
        order in (:ascending, :descending) ||
            throw(ODSError("A sort order is :ascending or :descending. Found `$(repr(order))`."))
        push!(out, _SortKey(_af_column(ws, r1, c1, c2, col), order === :descending))
    end
    return out
end

# A key's cells: as a filter sees them (`_AFCell`), and their text's collation key.
const _SortText = Union{Nothing,Vector{_CollElem},_NatKey}

# Cell a against cell b (with their text keys): LibreOffice's order (F-064, F-072). Numbers (logicals
# among them), then text, then errors, which are all equal; descending reverses that; empty cells
# are last either way.
function _sort_cmp(a::_AFCell, ka::_SortText, b::_AFCell, kb::_SortText, desc::Bool, cs::Bool)
    a.kind == 0x00 && return b.kind == 0x00 ? 0 : 1
    b.kind == 0x00 && return -1
    r = if a.kind != b.kind
        a.kind < b.kind ? -1 : 1
    elseif a.kind == 0x01
        a.num == b.num ? 0 : a.num < b.num ? -1 : 1
    elseif a.kind == 0x02
        ka isa _NatKey ? _lo_nat_cmp(ka, kb::_NatKey, cs) : _lo_key_cmp(ka::Vector{_CollElem}, kb::Vector{_CollElem}, cs)
    else
        0
    end
    return desc ? -r : r
end

# LibreOffice's quicksort (ScTable::QuickSort): the first element as the pivot, `cmp` with ties broken
# by the original order. Its order where `cmp` is not transitive (natural sort, F-072).
function _lo_quicksort!(a::Vector{Int}, lo::Int, hi::Int, cmp)
    if hi - lo == 1
        cmp(a[lo], a[hi]) > 0 && ((a[lo], a[hi]) = (a[hi], a[lo]))
        return a
    end
    ni = lo; nj = hi
    while true
        while ni <= hi && cmp(a[ni], a[lo]) < 0
            ni += 1
        end
        while nj >= lo && cmp(a[lo], a[nj]) < 0
            nj -= 1
        end
        if ni <= nj
            ni != nj && ((a[ni], a[nj]) = (a[nj], a[ni]))
            ni += 1; nj -= 1
        end
        ni < nj || break
    end
    if nj - lo < hi - ni
        lo < nj && _lo_quicksort!(a, lo, nj, cmp)
        ni < hi && _lo_quicksort!(a, ni, hi, cmp)
    else
        ni < hi && _lo_quicksort!(a, ni, hi, cmp)
        lo < nj && _lo_quicksort!(a, lo, nj, cmp)
    end
    return a
end

#
# Refusals
#

# The array formulas of a sheet's original cells: (row, col, rows, cols), current numbers. A table
# without any is not walked.
function _matrix_cells(ws::Worksheet)
    out = NTuple{4,Int}[]
    ws.entry === nothing && return out
    node = ws.entry.node
    src = parent(XML.sourcetext(node))
    sp = XML.sourcespan(node)
    occursin("number-matrix-", SubString(src, first(sp), last(sp))) || return out
    row = Ref(0)
    walk(n::XML.LazyNode) = begin
        c = XML.Cursor(n)
        XML.next!(c)
        XML.for_each_child!(c) do ch
            XML.nodetype(ch) === XML.Element || return
            t = XML.tag(ch)
            if t == "table:table-row"
                nrows = min(_repeat_attr(ch, "table:number-rows-repeated"), SheetCore.MAX_ROWS - row[])
                r0 = row[] + 1
                row[] += nrows
                rc = XML.Cursor(XML.LazyNode(ch)); XML.next!(rc)
                col = 0
                XML.for_each_child!(rc) do cc
                    XML.nodetype(cc) === XML.Element || return
                    if XML.tag(cc) in ("table:table-cell", "table:covered-table-cell")
                        csp = XML.sourcespan(XML.LazyNode(cc))
                        text = SubString(src, first(csp), last(csp))
                        k = max(1, _attr_int(text, "table:number-columns-repeated", 1))
                        e = _start_tag_end(text)
                        tag = SubString(text, 1, e)
                        if occursin("number-matrix-", tag)
                            nc = _attr_int(tag, "table:number-matrix-columns-spanned", 1)
                            nr = _attr_int(tag, "table:number-matrix-rows-spanned", 1)
                            r = _current_line(ws.rowmap, r0); cl = _current_line(ws.colmap, col + 1)
                            (r == 0 || cl == 0) || push!(out, (r, cl, nr, nc))
                        end
                        col += k
                    end
                    XML.skip_element!(cc)
                end
            elseif t in _ROW_CONTAINERS
                walk(XML.LazyNode(ch))
            end
            XML.skip_element!(ch)
        end
    end
    walk(node)
    return out
end

_overlaps(a1, b1, a2, b2) = a1 <= b2 && a2 <= b1

# What LibreOffice refuses to sort (F-072): merged cells, unless the formats stay; and what this
# package can't move: array formulas (LibreOffice moves one over a single cell).
function _sort_check(ws::Worksheet, a::Int, c1::Int, b::Int, c2::Int, formats::Bool)
    area = string(_db_cell(a, c1), ':', _db_cell(b, c2))
    if formats
        for mg in something(getMergedCells(ws), CellRange[])
            (_overlaps(row_number(mg.start), row_number(mg.stop), a, b) && _overlaps(column_number(mg.start), column_number(mg.stop), c1, c2)) &&
                throw(ODSError("Cannot sort `$area`: it has merged cells (`$mg`). LibreOffice sorts merged cells only " *
                               "without their formats: give `includeFormats=false`."))
        end
    end
    for (r, c, nr, nc) in _matrix_cells(ws)
        (_overlaps(r, r + nr - 1, a, b) && _overlaps(c, c + nc - 1, c1, c2)) &&
            throw(ODSError("Cannot sort `$area`: cell $(_db_cell(r, c)) holds an array formula, which a sort can't move."))
    end
    return
end

#
# Moving the cells
#

# Rows a:b of a run-length row list as single rows (one pass), so that setting their cells splits nothing.
function _rows_singles!(rows::Vector{RowData}, a::Int, b::Int)
    i = _first_row_index(rows, a)
    while i <= length(rows) && rows[i].row <= b && rows[i].count == 1
        i += 1
    end
    (i <= length(rows) && rows[i].row <= b) || return rows
    out = RowData[]
    sizehint!(out, length(rows) + (b - a + 1))
    for rd in rows
        lo = Int(rd.row); hi = _lastrow(rd)
        if rd.count == 1 || hi < a || lo > b
            push!(out, rd)
            continue
        end
        lo < a && push!(out, RowData(lo, a - lo, copy(rd.runs)))
        for r in max(lo, a):min(hi, b)
            push!(out, RowData(r, 1, copy(rd.runs)))
        end
        hi > b && push!(out, RowData(b + 1, hi - b, copy(rd.runs)))
    end
    empty!(rows); append!(rows, out)
    return rows
end

const _END_CELL_RX = r"table:end-cell-address=\"([^\"]*)\""

# A shape's XML (current numbers) with its end cell moved `d` rows, as its anchor moves (F-072).
function _shift_end_cell(x::String, d::Int, sheet::String)
    m = match(_END_CELL_RX, x)
    m === nothing && return x
    v = XML.unescape(String(m.captures[1]))
    nv = rewrite_address(v, RowMove(d), RefContext(sheet; marked = false))
    (nv === nothing || nv == v) && return x
    return replace(x, _END_CELL_RX => "table:end-cell-address=\"" * _escape_attr(nv) * "\""; count = 1)
end

_sort_cleared(ws::Worksheet, r::Int, c::Int) = (sc = ws.sortclear; sc !== nothing && (r, c) in sc)

# The cells a sort filled from others, moved with inserted or deleted lines; those of deleted cells go.
function _shift_sortclear!(ws::Worksheet, axis::Int, at::Int, n::Int)
    ws.sortclear === nothing && return
    max = axis == 1 ? SheetCore.MAX_ROWS : SheetCore.MAX_COLS
    new = Set{Tuple{Int,Int}}()
    for (r, c) in ws.sortclear
        x = _line_after(axis == 1 ? r : c, at, n)
        0 < x <= max && push!(new, axis == 1 ? (x, c) : (r, x))
    end
    ws.sortclear = new
    return
end

# A cell's data moved from row `from` to row `to` (formats moving with it, or the destination's
# `style`, covered state and spans kept): a formula as if copied, without its value; text with the
# file's URL fields of its original (`link`: its paragraphs and first link) as the cell's own.
function _moved_data(ws::Worksheet, d::CellData, from::Int, to::Int, c::Int, link, keep::Union{Nothing,Tuple{Int32,UInt8,Int32,Int32}})
    style, cov, cs, rs = keep === nothing ? (d.style, d.flags & F_COVERED, d.colspan, d.rowspan) : keep
    flags = (d.flags & ~F_COVERED) | cov
    if d.formula !== nothing
        f = from == to ? d.formula : rewrite_formula(d.formula, RowMove(to - from), RefContext(ws.name; row = to, col = c))
        return CellData(CK_EMPTY, cov, style, UInt64(0), nothing, f, cs, rs)
    end
    if link !== nothing
        st = get_odsfile(ws).styles
        push!(st.rich, link[1])
        push!(st.richinfo, link[2])
        return CellData(CK_STRING, cov | F_RICH, style, UInt64(length(st.rich)), d.text, nothing, cs, rs)
    end
    return CellData(d.kind, flags, style, d.bits, d.text, d.formula, cs, rs)
end

"""
    _sort_rows!(ws, r1, c1, r2, c2, keys, cs, nat, formats) -> Dict

Puts rows r1+1:r2 of columns c1:c2 in the order of `keys`, as LibreOffice's sort does. Ties
keep their order. Returns the formulas moved with a value, as a filter sees them, by their new cell:
they are saved without one (LibreOffice computes them), and a filter applied with the sort takes
the value they had.
"""
function _sort_rows!(ws::Worksheet, r1::Int, c1::Int, r2::Int, c2::Int, keys::Vector{_SortKey}, cs::Bool, nat::Bool, formats::Bool)
    rows = r1+1:r2
    n = length(rows)
    over = Dict{Tuple{Int,Int},_AFCell}()
    n < 2 && return over
    _sort_check(ws, r1 + 1, c1, r2, c2, formats)
    s = _cached_store(ws)
    f = sheet_formats(ws)
    cache = _CodeCache()
    cells = Dict{Int,Vector{_AFCell}}()
    texts = Dict{Int,Vector{_SortText}}()
    for k in keys
        haskey(cells, k.field) && continue
        v = _af_cells(ws, s, rows, c1 + k.field, cache)
        cells[k.field] = v
        texts[k.field] = _SortText[x.kind == 0x02 ? (nat ? _lo_nat_key(x.text) : _lo_coll_key(x.text)) : nothing for x in v]
    end
    cmpij(i, j) = begin
        for k in keys
            a = cells[k.field]; t = texts[k.field]
            r = _sort_cmp(a[i], t[i], a[j], t[j], k.desc, cs)
            r == 0 || return r
        end
        0
    end
    perm = if nat && n <= 5000
        # natural comparisons need not be transitive ("a 1" < "a%" < "a01" < "a 1"): LibreOffice's own
        # sort, with its test for sorted rows, gives its order. Its pivot makes nearly sorted rows
        # quadratic, so longer ranges are sorted stably (the same order wherever comparisons are transitive)
        p = collect(1:n)
        all(i -> cmpij(i, i + 1) <= 0, 1:n-1) || _lo_quicksort!(p, 1, n, (x, y) -> (r = cmpij(x, y); r != 0 ? r : cmp(x, y)))
        p
    else
        sortperm(collect(1:n); lt = (i, j) -> cmpij(i, j) < 0, alg = MergeSort)   # stable: equal rows keep their order
    end
    moved = [perm[i] != i for i in 1:n]           # a moved row's source moved too (a permutation)
    any(moved) || return over
    inv = similar(perm)
    for i in 1:n
        inv[perm[i]] = i
    end
    xf = get_odsfile(ws)
    file = ws.entry !== nothing
    m = c2 - c1 + 1

    # what each cell holds now
    vals = Matrix{Union{Nothing,CellData}}(nothing, n, m)
    fmts = Matrix{Union{Nothing,CellData}}(nothing, n, m)
    for i in 1:n, j in 1:m
        moved[i] || continue
        vals[i, j] = cell_data(s, rows[i], c1 + j - 1)
        fmts[i, j] = _fmt_cell(f, rows[i], c1 + j - 1)
        d = vals[i, j]
        if d !== nothing && d.formula !== nothing && d.kind !== CK_EMPTY
            over[(rows[inv[i]], c1 + j - 1)] = only(_af_cells(ws, s, rows[i]:rows[i], c1 + j - 1, cache))
        end
    end
    inb(r, c) = r1 < r <= r2 && c1 <= c <= c2
    notes = Dict{Tuple{Int,Int},NoteData}(k => nd for (k, nd) in _all_notes(ws) if inb(k...))
    links = Dict{Tuple{Int,Int},Tuple{String,Tuple{String,String}}}()
    if file
        for i in 1:n, j in 1:m
            moved[i] || continue
            d = vals[i, j]
            (d === nothing || d.kind !== CK_STRING) && continue
            run = _file_link_at(ws, rows[i], c1 + j - 1)
            run !== nothing && _fields_kept(d, run) && !isempty(run.paras) &&
                (links[(rows[i], c1 + j - 1)] = (run.paras, first(run.links)))
        end
    end
    valnames = nothing
    if formats && (ws.valrects !== nothing || (file && !isempty(_file_vals(ws))))
        valnames = Matrix{Union{Nothing,String}}(nothing, n, m)
        for i in 1:n, j in 1:m
            moved[i] && (valnames[i, j] = _val_at(ws, rows[i], c1 + j - 1))
        end
    end
    # the shapes of each moved cell, in current numbers: (XML => operations it has) or a picture added
    shapes = Dict{Tuple{Int,Int},Vector{Union{Pair{String,Int},ImageData}}}()
    nops = isnewfile(xf) ? 0 : length(xf.ops)
    if file
        for ff in _file_frames(ws)
            ff.row == 0 && continue
            r = _current_line(ws.rowmap, ff.row); c = _current_line(ws.colmap, ff.col)
            (r == 0 || c == 0 || !inb(r, c) || !moved[r - r1] || _sort_cleared(ws, r, c)) && continue
            fe = ws.frames === nothing ? nothing : get(ws.frames, (r, c), nothing)
            fe !== nothing && ff.k > 0 && ff.k in fe.removed && continue
            push!(get!(Vector{Union{Pair{String,Int},ImageData}}, shapes, (r, c)), _moved_now(ws, ff.xml => ws.opstart) => nops)
        end
    end
    if ws.frames !== nothing
        for ((r, c), fe) in ws.frames
            (inb(r, c) && moved[r - r1]) || continue
            v = get!(Vector{Union{Pair{String,Int},ImageData}}, shapes, (r, c))
            foreach(mv -> push!(v, _moved_now(ws, mv) => nops), fe.moved)
            append!(v, fe.added)
        end
    end
    vis = [(x = _fmt_at(f.rows, r); x === nothing ? _VISIBLE : x.visibility) for r in rows]

    # the cells move
    _rows_singles!(s.rows, first(rows), last(rows))
    _rows_singles!(f.cells, first(rows), last(rows))
    for i in 1:n
        moved[i] || continue
        r = rows[i]; o = rows[perm[i]]
        for j in 1:m
            c = c1 + j - 1
            d = vals[perm[i], j]
            if formats
                nd = d === nothing ? nothing : _moved_data(ws, d, o, r, c, get(links, (o, c), nothing), nothing)
                fm = fmts[perm[i], j]
            else
                own = vals[i, j]; ownf = fmts[i, j]
                style = own !== nothing ? own.style : (ownf !== nothing && ownf.style >= 0) ? ownf.style : _inherited_style(f, r, c)
                base = own !== nothing ? own : ownf
                cov = base === nothing ? (0x00, Int32(1), Int32(1)) : (base.flags & F_COVERED, base.colspan, base.rowspan)
                nd = d === nothing ? nothing : _moved_data(ws, d, o, r, c, get(links, (o, c), nothing), (style, cov...))
                fm = if nd !== nothing
                    nothing
                elseif ownf !== nothing
                    ownf
                elseif style != _inherited_style(f, r, c) || cov[1] != 0 || cov[2] > 1 || cov[3] > 1
                    CellData(CK_EMPTY, cov[1], style, UInt64(0), nothing, nothing, cov[2], cov[3])
                else
                    nothing
                end
            end
            store_set!(s, r, c, nd)
            _rows_set!(f.cells, r, c, fm)
        end
    end
    s.stale = true
    if file
        push!(f.rects, (rows, c1:c2))
        sc = ws.sortclear === nothing ? (ws.sortclear = Set{Tuple{Int,Int}}()) : ws.sortclear
        for i in 1:n, c in c1:c2
            moved[i] && push!(sc, (rows[i], c))
        end
    end

    # notes, validations and shapes go with their cells; hidden rows with their rows
    for i in 1:n
        moved[i] || continue
        r = rows[i]; o = rows[perm[i]]
        for c in c1:c2
            new = get(notes, (o, c), nothing); old = get(notes, (r, c), nothing)
            new === old || _set_note!(ws, r, c, new)
        end
    end
    if valnames !== nothing
        for j in 1:m
            c = c1 + j - 1
            i = 1
            while i <= n
                if !moved[i] || valnames[perm[i], j] == valnames[i, j]
                    i += 1; continue
                end
                name = valnames[perm[i], j]
                k = i
                while k < n && moved[k+1] && valnames[perm[k+1], j] == name && valnames[perm[k+1], j] != valnames[k+1, j]
                    k += 1
                end
                _set_val_blocks!(ws, _Area[(rows[i]:rows[k], c:c)], name)
                i = k + 1
            end
        end
    end
    for i in 1:n
        moved[i] || continue
        r = rows[i]
        for c in c1:c2
            ws.frames === nothing || delete!(ws.frames, (r, c))
        end
    end
    for ((o, c), v) in shapes
        r = rows[inv[o - r1]]
        fe = _frame_edit!(ws, r, c)
        for x in v
            if x isa ImageData
                x.torow = clamp(x.torow + (r - o), 1, SheetCore.MAX_ROWS)
                push!(fe.added, x)
            else
                push!(fe.moved, _shift_end_cell(x.first, r - o, ws.name) => x.second)
            end
        end
        _touch_cell!(ws, r, c)
    end
    for i in 1:n
        moved[i] || continue
        v = vis[perm[i]]
        v == vis[i] || set_row_formats!(ws, rows[i]:rows[i]; visibility = v)
    end
    return over
end

#
# The stored form (F-064, F-072)
#

function _sort_xml(keys::Vector{_SortKey}, cs::Bool, nat::Bool, formats::Bool)
    io = IOBuffer()
    print(io, "<table:sort")
    formats || print(io, " table:bind-styles-to-content=\"false\"")
    cs && print(io, " table:case-sensitive=\"true\"")
    nat && print(io, " table:embedded-number-behavior=\"double\"")
    print(io, ">")
    for k in keys
        print(io, "<table:sort-by table:field-number=\"", k.field, "\"")
        k.desc && print(io, " table:order=\"descending\"")
        print(io, " table:data-type=\"automatic\"/>")
    end
    print(io, "</table:sort>")
    return String(take!(io))
end

const _DB_SORT_RX = r"<table:sort(?=[\s/>])(?:[^>]*?/>|.*?</table:sort>)"s

# A database range's element with its `table:sort` replaced by `sx` (after its filter, before its
# subtotal rules).
function _db_with_sort(x::String, sx::String)
    isempty(x) && (x = "<table:database-range/>")
    a = findfirst(_DB_SORT_RX, x)
    a === nothing || return string(SubString(x, 1, prevind(x, first(a))), sx, SubString(x, nextind(x, last(a))))
    e = _start_tag_end(x)
    if x[prevind(x, e)] == '/'
        return string(SubString(x, 1, prevind(x, prevind(x, e))), ">", sx, "</table:database-range>")
    end
    b = findnext(r"<table:subtotal-rules(?=[\s/>])", x, e)
    b === nothing && (b = findlast("</table:database-range>", x))
    return string(SubString(x, 1, prevind(x, first(b))), sx, SubString(x, first(b)))
end

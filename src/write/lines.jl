# Inserting and deleting rows and columns (phase 5 step 3: D-050, D-051, D-052, D-054).
#
# The model is updated at once:
#   - the edited sheet's cells (store), formatted empty cells, row and column formats and merges
#     move; inserted lines take LibreOffice's formats (D-051)
#   - every formula in every sheet, and every defined name, is rewritten (src/formula/refs.jl)
#   - the edit records (`dirty`, `rects`, `rows_touched`) move with the lines
# and the operation is logged (`xf.ops`), with an `IndexMap` per sheet read from the file, so that a
# patched save can find where each original line went and rewrite the references in the text it
# copies (D-023, D-049).

#
# Run lists
#

# A row list with `n` rows inserted before row `at` (runs split there), clipped to the sheet.
function _rows_inserted(rows::Vector{RowData}, at::Int, n::Int)
    out = RowData[]
    for rd in rows
        a = Int(rd.row); b = _lastrow(rd)
        if a >= at
            push!(out, RowData(a + n, rd.count, rd.runs))
        elseif b >= at
            push!(out, RowData(a, at - a, rd.runs))
            push!(out, RowData(at + n, b - at + 1, copy(rd.runs)))
        else
            push!(out, rd)
        end
    end
    return _rows_clipped(out)
end

function _rows_clipped(rows::Vector{RowData})
    M = SheetCore.MAX_ROWS
    while !isempty(rows) && rows[end].row > M
        pop!(rows)
    end
    if !isempty(rows) && _lastrow(rows[end]) > M
        rd = rows[end]
        rows[end] = RowData(rd.row, M - rd.row + 1, rd.runs)
    end
    return rows
end

# A row list without rows d1:d2.
function _rows_deleted(rows::Vector{RowData}, d1::Int, d2::Int)
    cnt = d2 - d1 + 1
    out = RowData[]
    for rd in rows
        a = Int(rd.row); b = _lastrow(rd)
        if b < d1
            push!(out, rd)
        elseif a > d2
            push!(out, RowData(a - cnt, rd.count, rd.runs))
        else
            a < d1 && push!(out, RowData(a, d1 - a, rd.runs))
            b > d2 && push!(out, RowData(d1, b - d2, copy(rd.runs)))
        end
    end
    return out
end

# The same for the cells of a row.
function _runs_inserted(runs::Vector{CellRun}, at::Int, n::Int)
    M = SheetCore.MAX_COLS
    out = CellRun[]
    for r in runs
        a = Int(r.col); b = _lastcol(r)
        if a >= at
            a + n <= M && push!(out, CellRun(a + n, min(Int(r.count), M - a - n + 1), r.data))
        elseif b >= at
            push!(out, CellRun(a, at - a, r.data))
            at + n <= M && push!(out, CellRun(at + n, min(b - at + 1, M - at - n + 1), r.data))
        else
            push!(out, r)
        end
    end
    return out
end

function _runs_deleted(runs::Vector{CellRun}, d1::Int, d2::Int)
    cnt = d2 - d1 + 1
    out = CellRun[]
    for r in runs
        a = Int(r.col); b = _lastcol(r)
        if b < d1
            push!(out, r)
        elseif a > d2
            push!(out, CellRun(a - cnt, r.count, r.data))
        else
            a < d1 && push!(out, CellRun(a, d1 - a, r.data))
            b > d2 && push!(out, CellRun(d1, b - d2, r.data))
        end
    end
    return out
end

# Every row of a row list with its cells shifted (rows that lose all their cells go).
function _map_runs!(f::Function, rows::Vector{RowData})
    out = RowData[]
    for rd in rows
        runs = f(rd.runs)
        isempty(runs) || push!(out, RowData(rd.row, rd.count, runs))
    end
    empty!(rows); append!(rows, out)
    return rows
end

# Splits the runs of a row so that one starts at column `c`.
function _split_runs!(runs::Vector{CellRun}, c::Int)
    for i in eachindex(runs)
        r = runs[i]
        if r.col < c <= _lastcol(r)
            splice!(runs, i:i, [CellRun(r.col, c - r.col, r.data), CellRun(c, _lastcol(r) - c + 1, r.data)])
            break
        end
    end
    return runs
end

# Column and row format runs (contiguous from line 1): `n` lines inserted before `at`, which take
# the format `new` (a run of length n at `at`, or nothing to repeat a blank one).
function _formats_inserted(v::Vector{T}, at::Int, n::Int, new::T, max::Int) where {T<:Union{ColFormat,RowFormat}}
    isempty(v) && return v
    stop = _stop(v[end])
    at > stop + 1 && return v                     # past the formats: nothing to move
    out = T[]
    for r in v
        a = _start(r); b = _stop(r)
        if a >= at
            push!(out, _respan(r, a + n, Int(r.count)))
        elseif b >= at
            push!(out, _respan(r, a, at - a))
            push!(out, _respan(r, at + n, b - at + 1))
        else
            push!(out, r)
        end
    end
    i = findfirst(r -> _start(r) > at, out)
    insert!(out, i === nothing ? length(out) + 1 : i, new)
    merged = T[]
    for r in out
        _start(r) > max && break
        r = _stop(r) > max ? _respan(r, _start(r), max - _start(r) + 1) : r
        _push_format!(merged, r)
    end
    empty!(v); append!(v, merged)
    return v
end

function _formats_deleted(v::Vector{T}, d1::Int, d2::Int) where {T<:Union{ColFormat,RowFormat}}
    cnt = d2 - d1 + 1
    out = T[]
    for r in v
        a = _start(r); b = _stop(r)
        if b < d1
            _push_format!(out, r)
        elseif a > d2
            _push_format!(out, _respan(r, a - cnt, Int(r.count)))
        else
            a < d1 && _push_format!(out, _respan(r, a, d1 - a))
            b > d2 && _push_format!(out, _respan(r, d1, b - d2))
        end
    end
    empty!(v); append!(v, out)
    return v
end

# A line number after the operation (0: deleted).
function _line_after(x::Int, at::Int, n::Int)
    n > 0 && return x >= at ? x + n : x
    d2 = at - n - 1
    return x < at ? x : x <= d2 ? 0 : x + n
end

# A range of lines after the operation (empty when wholly deleted). An insert inside a range, or at
# its last line, grows it (F-043).
function _range_after(r::UnitRange{Int}, at::Int, n::Int, max::Int)
    lo, hi = first(r), last(r)
    if n > 0
        lo >= at && return (lo + n):min(hi + n, max)
        hi >= at && return lo:min(hi + n, max)
        return r
    end
    d1 = at; d2 = at - n - 1
    nlo = lo < d1 ? lo : lo > d2 ? lo + n : d1
    nhi = hi < d1 ? hi : hi > d2 ? hi + n : d1 - 1
    return nlo:nhi
end

#
# The model
#

# The rows (axis 1) or columns (2) of a cell range, and the range with them replaced.
_lines(r::CellRange, axis::Int) = axis == 1 ? (row_number(r.start):row_number(r.stop)) :
                                              (column_number(r.start):column_number(r.stop))
_with_lines(r::CellRange, axis::Int, l::UnitRange{Int}) =
    axis == 1 ? CellRange(CellRef(first(l), column_number(r.start)), CellRef(last(l), column_number(r.stop))) :
                CellRange(CellRef(row_number(r.start), first(l)), CellRef(row_number(r.stop), last(l)))

# The data of cell (row, col): stored, else formatted, else nothing; and which list holds it.
function _any_cell(s::SheetStore, f::SheetFormats, row::Int, col::Int)
    d = cell_data(s, row, col)
    d === nothing || return d, :store
    d = _fmt_cell(f, row, col)
    return d, d === nothing ? :none : :formats
end

# (`_with_merge` is merge.jl's.) Sets a cell's covered flag and spans, in the list that holds it (a formatted empty cell is made
# for an empty one that must be covered; one left with nothing to say goes).
function _set_merge_state!(s::SheetStore, f::SheetFormats, row::Int, col::Int, covered::Bool, cs::Int, rs::Int)
    d, where = _any_cell(s, f, row, col)
    flags = covered ? F_COVERED : 0x00
    if where === :store
        dd = _with_merge(d, (d.flags & ~F_COVERED) | flags, cs, rs)
        dd == d || _rows_set!(s.rows, row, col, dd)
    elseif where === :formats
        dd = _with_merge(d, (d.flags & ~F_COVERED) | flags, cs, rs)
        if dd.style < 0 && !covered && cs == 1 && rs == 1
            _rows_set!(f.cells, row, col, nothing)
        elseif dd != d
            _rows_set!(f.cells, row, col, dd)
        end
    elseif covered || cs > 1 || rs > 1
        _rows_set!(f.cells, row, col, CellData(CK_EMPTY, flags, Int32(-1), UInt64(0), nothing, nothing, Int32(cs), Int32(rs)))
    end
    return
end

# The merges after the operation (on line numbers already moved): a merge moves, grows and shrinks
# as a range; one whose anchor line is deleted, or that is left as one cell, goes and its cells are
# uncovered (experiment 021).
function _shift_merges!(s::SheetStore, f::SheetFormats, axis::Int, at::Int, n::Int)
    max = axis == 1 ? SheetCore.MAX_ROWS : SheetCore.MAX_COLS
    kept = CellRange[]
    changed = CellRange[]
    gone = CellRange[]
    for m in s.merges
        l = _lines(m, axis)
        nl = _range_after(l, at, n, max)
        if n < 0 && at <= first(l) <= at - n - 1           # its anchor line is deleted
            isempty(nl) || push!(gone, _with_lines(m, axis, nl))
            continue
        end
        isempty(nl) && continue
        nm = _with_lines(m, axis, nl)
        if row_number(nm.start) == row_number(nm.stop) && column_number(nm.start) == column_number(nm.stop)
            push!(gone, nm)
        else
            push!(kept, nm)
            length(nl) == length(l) || push!(changed, nm)    # moved merges keep their cells' state
        end
    end
    for g in gone, r in row_number(g.start):row_number(g.stop), c in column_number(g.start):column_number(g.stop)
        _set_merge_state!(s, f, r, c, false, 1, 1)
    end
    for m in changed
        r1, c1 = row_number(m.start), column_number(m.start)
        r2, c2 = row_number(m.stop), column_number(m.stop)
        for r in r1:r2, c in c1:c2
            r == r1 && c == c1 ? _set_merge_state!(s, f, r, c, false, c2 - c1 + 1, r2 - r1 + 1) :
                                 _set_merge_state!(s, f, r, c, true, 1, 1)
        end
    end
    sort!(kept; by = m -> (row_number(m.start), column_number(m.start)))
    empty!(s.merges); append!(s.merges, kept)
    return vcat(changed, gone)           # the areas whose cells changed state: written from the model
end

# Cells in the formats layer: adds the runs `add` (on rows that hold none of those columns) to `cells`.
function _merge_cell_rows!(cells::Vector{RowData}, add::Vector{RowData})
    isempty(add) && return cells
    bps = Int[]
    M = SheetCore.MAX_ROWS
    _row_bounds!(bps, cells, 1, M)
    _row_bounds!(bps, add, 1, M)
    pts = _segment_points(bps, 1, maximum(bps) - 1)
    out = RowData[]
    for k in 1:length(pts)-1
        a = pts[k]; b = pts[k + 1] - 1
        x = _runs_of(cells, a); y = _runs_of(add, a)
        (isempty(x) && isempty(y)) && continue
        runs = sort!(vcat(x, y); by = r -> r.col)
        if !isempty(out) && _lastrow(out[end]) + 1 == a && out[end].runs == runs
            out[end] = RowData(out[end].row, out[end].count + b - a + 1, out[end].runs)
        else
            push!(out, RowData(a, b - a + 1, runs))
        end
    end
    empty!(cells); append!(cells, out)
    return cells
end

# The style a new cell copies from a neighbour's data, or -1 for none.
_copied_style(d::CellData) = d.style > 0 ? d.style : Int32(-1)

# Inserted lines' formats (D-051, F-045): rows copy the row above's cell styles; columns copy the
# left column's cell styles and default cell style. Not hidden; nothing at line 1.
function _format_new_lines!(s::SheetStore, f::SheetFormats, axis::Int, at::Int, n::Int)
    at == 1 && return
    src = at - 1
    if axis == 1
        runs = CellRun[]
        for r in vcat(_runs_of(s.rows, src), _runs_of(f.cells, src))
            st = _copied_style(r.data)
            st < 0 && continue
            push!(runs, CellRun(r.col, r.count, CellData(CK_EMPTY, 0x00, st, UInt64(0), nothing, nothing, Int32(1), Int32(1))))
        end
        isempty(runs) && return
        sort!(runs; by = r -> r.col)
        _merge_cell_rows!(f.cells, [RowData(at, min(n, SheetCore.MAX_ROWS - at + 1), runs)])
    else
        add = RowData[]
        for list in (s.rows, f.cells), rd in list
            r = _run_at(rd.runs, src)
            r === nothing && continue
            st = _copied_style(r.data)
            st < 0 && continue
            push!(add, RowData(rd.row, rd.count, [CellRun(at, min(n, SheetCore.MAX_COLS - at + 1),
                CellData(CK_EMPTY, 0x00, st, UInt64(0), nothing, nothing, Int32(1), Int32(1)))]))
        end
        sort!(add; by = rd -> rd.row)
        # rows of the store and of the formats may overlap: keep the first source for each row
        dedup = RowData[]
        for rd in add
            if !isempty(dedup) && _lastrow(dedup[end]) >= rd.row
                b = _lastrow(rd)
                b > _lastrow(dedup[end]) && push!(dedup, RowData(_lastrow(dedup[end]) + 1, b - _lastrow(dedup[end]), rd.runs))
            else
                push!(dedup, rd)
            end
        end
        _merge_cell_rows!(f.cells, dedup)
    end
    return
end

# The edit records of a sheet read from the file, moved with the lines.
function _shift_edits!(ws::Worksheet, f::SheetFormats, axis::Int, at::Int, n::Int)
    max = axis == 1 ? SheetCore.MAX_ROWS : SheetCore.MAX_COLS
    if axis == 1
        new = Dict{Int,Vector{Int}}()
        for (r, cs) in ws.dirty
            r2 = _line_after(r, at, n)
            0 < r2 <= max && (new[r2] = cs)
        end
        ws.dirty = new
        f.rows_touched = filter!(!isempty, [_range_after(r, at, n, max) for r in f.rows_touched])
    else
        for (r, cs) in ws.dirty
            ws.dirty[r] = filter!(c -> 0 < c <= max, [_line_after(c, at, n) for c in cs])
        end
        filter!(p -> !isempty(p.second), ws.dirty)
        f.cols_touched = true
    end
    rects = Tuple{UnitRange{Int},UnitRange{Int}}[]
    for (rr, cc) in f.rects
        if axis == 1
            nr = _range_after(rr, at, n, max)
            isempty(nr) || push!(rects, (nr, cc))
        else
            nc = _range_after(cc, at, n, max)
            isempty(nc) || push!(rects, (rr, nc))
        end
    end
    f.rects = rects
    return
end

# Every formula of every sheet, and every defined name, rewritten by `op` (src/formula/refs.jl).
# Formulas are rewritten before the cells move: a formula's cell is where it was when the
# operation happened (the end-of-sheet rule of F-043 needs it).
function _rewrite_model_refs!(xf::ODSFile, op::RefOp)
    for ws in _sheets(xf)
        # a print area set by OpenDocumentSpreadsheets (phase 5 step 10): the file's are replayed with the text
        pa = ws.print
        if pa !== nothing && pa.area_changed && pa.area !== nothing
            pa.area = rewrite_rangelist(pa.area, op, RefContext(ws.name))
        end
        s = _cached_store(ws)
        for i in eachindex(s.rows)
            rd = s.rows[i]
            changed = false
            runs = rd.runs
            for j in eachindex(runs)
                d = runs[j].data
                d.formula === nothing && continue
                nf = rewrite_formula(d.formula, op, RefContext(ws.name; row = Int(rd.row), col = Int(runs[j].col)))
                nf === d.formula && continue
                changed || (runs = copy(runs); changed = true)
                runs[j] = CellRun(runs[j].col, runs[j].count,
                                  CellData(d.kind, d.flags, d.style, d.bits, d.text, nf, d.colspan, d.rowspan))
            end
            changed && (s.rows[i] = RowData(rd.row, rd.count, runs))
        end
        ln = ws.localnames
        ln === nothing || (ws.localnames = [_rewrite_name(dn, op) for dn in ln])
    end
    xf.names = [_rewrite_name(dn, op) for dn in xf.names]
    _rewrite_rule_refs!(xf, op)                        # validations added (phase 6 step 6)
    _rewrite_db_refs!(xf, op)                          # tables added or changed (phase 6 step 7)
    _rewrite_cf_refs!(xf, op)                          # conditional formats read or set (phase 7)
    _rewrite_spark_refs!(xf, op)                       # sparklines read or set (phase 8 step 8)
    _rewrite_chart_refs!(xf, op)                       # charts added or edited (phase 8)
    return
end

function _rewrite_name(dn::NameDef, op::RefOp)
    sheet = dn.base === nothing ? something(dn.scope, "") : something(_base_sheet(dn.base), something(dn.scope, ""))
    ctx = RefContext(sheet; names = true)
    rng = dn.range === nothing ? nothing : rewrite_rangelist(dn.range, op, ctx)
    expr = dn.expression === nothing ? nothing : rewrite_formula(dn.expression, op, ctx)
    base = dn.base === nothing ? nothing : _rewrite_base(dn.base, op)
    (rng === dn.range && expr === dn.expression && base === dn.base) && return dn
    return NameDef(dn.name, dn.scope, rng, expr, base, dn.span)
end

function _base_sheet(base::AbstractString)
    r = parse_ref(base)
    return r === nothing ? nothing : r[1].sheet
end

# A name's base: rows and columns don't move it (F-044); sheet operations do, unmarked (F-047).
_rewrite_base(base::AbstractString, op::LineShift) = base
_rewrite_base(base::AbstractString, op::RefOp) = rewrite_rangelist(base, op, RefContext(""; marked = false))

# Whether a cell's formatting counts for D-052: a style other than Default, covered, or spanning.
# LibreOffice writes explicit Default cells across whole rows, which don't block an insert.
_formatted_cell(d::CellData) = d.style > 0 || d.flags & F_COVERED != 0 || d.colspan > 1 || d.rowspan > 1

# The first cell that an insert would push off the sheet, or nothing (D-052, F-046). A value or
# formula pushed off blocks it; formatting only when it would be lost entirely: a run of equal cells
# that starts before the pushed-off lines is only cut short (row 5 formatted across all columns
# doesn't block a column insert; a fill on XFD5 alone does).
function _pushed_off(s::SheetStore, f::SheetFormats, axis::Int, at::Int, n::Int)
    if axis == 1
        lim = SheetCore.MAX_ROWS - n
        for (list, isvals) in ((s.rows, true), (f.cells, false))
            i = length(list)
            while i >= 1 && _lastrow(list[i]) > lim
                rd = list[i]
                if _lastrow(rd) >= at && (isvals || rd.row > lim)
                    for r in rd.runs
                        (isvals ? has_content(r.data) : _formatted_cell(r.data)) &&
                            return CellRef(max(Int(rd.row), lim + 1, at), Int(r.col))
                    end
                end
                i -= 1
            end
        end
    else
        lim = SheetCore.MAX_COLS - n
        for (list, isvals) in ((s.rows, true), (f.cells, false)), rd in list
            for r in Iterators.reverse(rd.runs)
                _lastcol(r) > lim || break
                _lastcol(r) >= at || continue
                (isvals ? has_content(r.data) : (r.col > lim && _formatted_cell(r.data))) &&
                    return CellRef(Int(rd.row), max(Int(r.col), lim + 1, at))
            end
        end
    end
    return nothing
end

"""
    shift_lines!(ws, axis, at, n)

Insert (`n > 0`: before line `at`) or delete (`n < 0`: lines `at … at-n-1`) rows (`axis == 1`) or
columns (`axis == 2`) of `ws`, in the model, and log the operation for saving.
"""
function shift_lines!(ws::Worksheet, axis::Int, at::Int, n::Int)
    xf = get_odsfile(ws)
    sheets = _sheets(xf)
    foreach(_cached_store, sheets)
    foreach(_local_names, sheets)
    _wb_names(xf)
    s = _cached_store(ws)
    f = sheet_formats(ws)
    maxl = axis == 1 ? SheetCore.MAX_ROWS : SheetCore.MAX_COLS
    word = axis == 1 ? "row" : "column"
    if n > 0
        p = _pushed_off(s, f, axis, at, n)
        p === nothing ||
            throw(ODSError("Can't insert $n $(word)$(n == 1 ? "" : "s") into `$(ws.name)`: cell $(p) would be pushed off the sheet (LibreOffice refuses this too)."))
    end
    d1 = at; d2 = at - n - 1
    # shapes in deleted cells that reach beyond them stay, in the cell now at their place (F-060)
    rescued = n < 0 ? _rescued_frames(ws, axis, d1, d2) : nothing
    # validations: inserted cells take those of the line before them (F-068)
    vcopy = n > 0 && at > 1 ? _line_vals(ws, axis, at - 1) : nothing
    # formulas are rewritten where their cells are now: split the runs at the edges first
    if n < 0
        if axis == 1
            _split_rows!(s.rows, d1); _split_rows!(s.rows, d2 + 1)
        else
            for rd in s.rows
                _split_runs!(rd.runs, d1); _split_runs!(rd.runs, d2 + 1)
            end
        end
    end
    op = LineShift(ws.name, axis, at, n, [w.name for w in sheets])
    _rewrite_model_refs!(xf, op)
    # the cells move
    if axis == 1
        s.rows = n > 0 ? _rows_inserted(s.rows, at, n) : _rows_deleted(s.rows, d1, d2)
        f.cells = n > 0 ? _rows_inserted(f.cells, at, n) : _rows_deleted(f.cells, d1, d2)
    else
        _map_runs!(r -> n > 0 ? _runs_inserted(r, at, n) : _runs_deleted(r, d1, d2), s.rows)
        _map_runs!(r -> n > 0 ? _runs_inserted(r, at, n) : _runs_deleted(r, d1, d2), f.cells)
    end
    # row and column formats
    if axis == 1
        if n > 0
            above = at > 1 ? _fmt_at(f.rows, at - 1) : nothing
            new = above === nothing ? _blank(RowFormat, at, n) :
                  RowFormat(at, n, above.style, above.default, _VISIBLE, above.ncells)
            _formats_inserted(f.rows, at, n, new, maxl)
        else
            _formats_deleted(f.rows, d1, d2)
        end
    else
        if n > 0
            left = at > 1 ? _fmt_at(f.cols, at - 1) : nothing
            pushed = _fmt_at(f.cols, at)
            new = ColFormat(at, n, pushed === nothing ? "" : pushed.style, left === nothing ? Int32(-1) : left.default, _VISIBLE)
            _formats_inserted(f.cols, at, n, new, maxl)
            # rows whose cells reach the new columns cover them too
            f.rows = [r.ncells >= at ? RowFormat(r.row, r.count, r.style, r.default, r.visibility, min(Int(r.ncells) + n, maxl)) : r
                      for r in f.rows]
        else
            _formats_deleted(f.cols, d1, d2)
            f.rows = [r.ncells >= d1 ? RowFormat(r.row, r.count, r.style, r.default, r.visibility, max(d1 - 1, Int(r.ncells) - (d2 - d1 + 1))) : r
                      for r in f.rows]
        end
        s.cols = [ColRun(c.col, c.count, c.default, c.visibility == _VISIBLE) for c in f.cols]
    end
    n > 0 && _format_new_lines!(s, f, axis, at, n)
    _shift_sheet_groups!(f, axis, at, n, maxl)        # groups (phase 5 step 7, F-052)
    _shift_titles!(f, axis, at, n, maxl)              # print titles (step 10)
    _shift_notes!(ws, axis, at, n)                    # notes set or removed (phase 6 step 4)
    _shift_sortclear!(ws, axis, at, n)                # cells a sort filled (phase 6 step 9)
    merged = _shift_merges!(s, f, axis, at, n)
    s.stale = true
    # what the patched save needs
    if ws.entry !== nothing
        _shift_edits!(ws, f, axis, at, n)
        for mg in merged
            push!(f.rects, (row_number(mg.start):row_number(mg.stop), column_number(mg.start):column_number(mg.stop)))
        end
        m = axis == 1 ? (ws.rowmap === nothing ? (ws.rowmap = IndexMap(maxl)) : ws.rowmap) :
                        (ws.colmap === nothing ? (ws.colmap = IndexMap(maxl)) : ws.colmap)
        n > 0 ? insert_lines!(m, at, n) : delete_lines!(m, d1, d2)
    end
    _shift_frames!(ws, axis, at, n, rescued)          # pictures (phase 6 step 5): after the edits moved
    _shift_valrects!(ws, axis, at, n, vcopy)          # validations (phase 6 step 6): likewise
    isnewfile(xf) || push!(xf.ops, op)
    return ws
end

#
# The public functions
#

function _check_line(axis::Int, x::Integer, what)
    max = axis == 1 ? SheetCore.MAX_ROWS : SheetCore.MAX_COLS
    1 <= x <= max || throw(ODSError("$what $x is outside the sheet (1 to $max)."))
end

# A single row ("5") or column ("C", "c") given as text.
function _one_line(axis::Int, s::AbstractString)
    t = strip(String(s))
    if axis == 1
        v = tryparse(Int, t)
        v === nothing && throw(ODSError("`$s` is not a row number."))
        return v
    end
    occursin(r"^\$?[A-Za-z]{1,3}$", t) || throw(ODSError("`$s` is not a column (`\"C\"`)."))
    return SheetCore.decode_column_number(uppercase(replace(t, "\$" => "")))
end

# The lines a string names: "3", "3:5", "3:5,9" or "3:5~9" for rows; "B", "B:C", "B:C,F" for
# columns; cells and ranges ("A3:B5") give their rows or columns; a defined name its range's.
function _lines_of(ws::Worksheet, axis::Int, s::AbstractString)
    out = UnitRange{Int}[]
    for part in SheetCore._split_unquoted(strip(String(s)), (',', '~'))
        p = replace(strip(part), "\$" => "")
        if axis == 1 && (m = match(r"^(\d+)(?::(\d+))?$", p)) !== nothing
            a = parse(Int, m.captures[1]); b = m.captures[2] === nothing ? a : parse(Int, m.captures[2])
            push!(out, min(a, b):max(a, b))
        elseif axis == 2 && (m = match(r"^([A-Za-z]{1,3})(?::([A-Za-z]{1,3}))?$", p)) !== nothing
            a = SheetCore.decode_column_number(uppercase(m.captures[1]))
            b = m.captures[2] === nothing ? a : SheetCore.decode_column_number(uppercase(m.captures[2]))
            push!(out, min(a, b):max(a, b))
        elseif SheetCore.is_valid_cellname(p)
            c = CellRef(p)
            push!(out, axis == 1 ? (row_number(c):row_number(c)) : (column_number(c):column_number(c)))
        elseif SheetCore.is_valid_cellrange(p)
            push!(out, _lines(CellRange(p), axis))
        else
            dn = something(_find_name(_local_names(ws), p), _find_name(_wb_names(get_odsfile(ws)), p), Some(nothing))
            dn === nothing && throw(ODSError("`$part` names no $(axis == 1 ? "rows" : "columns") of `$(ws.name)`."))
            v = get_defined_name_value(dn)
            for r in (v isa NonContiguousRange ? v.rng : [v])
                rng = r isa SheetCellRef ? CellRange(r.cellref, r.cellref) :
                      r isa SheetCellRange ? r.rng :
                      r isa CellRef ? CellRange(r, r) :
                      r isa CellRange ? r :
                      throw(ODSError("The name `$part` is not a range of cells."))
                push!(out, _lines(rng, axis))
            end
        end
    end
    return out
end

_lines_of(ws::Worksheet, axis::Int, x::Integer) = [Int(x):Int(x)]
_lines_of(ws::Worksheet, axis::Int, x::CellRef) = [_lines(CellRange(x, x), axis)]
_lines_of(ws::Worksheet, axis::Int, x::CellRange) = [_lines(x, axis)]
_lines_of(ws::Worksheet, axis::Int, x::AbstractUnitRange{<:Integer}) = [Int(first(x)):Int(last(x))]
_lines_of(ws::Worksheet, axis::Int, x::AbstractVector{<:Integer}) = [Int(i):Int(i) for i in x]

# Deletes the lines of `spans`, the last first (so that earlier numbers stay valid).
function _delete_lines!(ws::Worksheet, axis::Int, spans::Vector{UnitRange{Int}}, what)
    _require_writable(ws, "delete $what")
    isempty(spans) && return nothing
    for r in spans
        isempty(r) && throw(ODSError("An empty range of $what."))
        _check_line(axis, first(r), what == "rows" ? "Row" : "Column")
        _check_line(axis, last(r), what == "rows" ? "Row" : "Column")
    end
    merged = _merge_ranges(spans)
    for r in reverse(merged)
        shift_lines!(ws, axis, first(r), -length(r))
    end
    return nothing
end

function _insert_lines!(ws::Worksheet, axis::Int, at::Integer, count::Integer, what)
    _require_writable(ws, "insert $what")
    count >= 1 || throw(ODSError("`count` must be at least 1, not $count."))
    _check_line(axis, at, what == "rows" ? "Row" : "Column")
    shift_lines!(ws, axis, Int(at), Int(count))
    return nothing
end

# "Sheet1.5" / "Sheet1!C:D" → (worksheet, the part after the sheet)
function _sheet_and_lines(xf::ODSFile, ref::AbstractString)
    s = String(ref)
    i = something(findlast(c -> c == '!', s), Some(nothing))
    if i === nothing
        parts = SheetCore._split_unquoted(s, ('.',))
        length(parts) >= 2 || throw(ODSError("`$ref` names no sheet (`\"Sheet1.5\"` or `\"Sheet1!5\"`)."))
        sheet = join(parts[1:end-1], "."); rest = parts[end]
    else
        sheet = s[1:prevind(s, i)]; rest = s[nextind(s, i):end]
    end
    sheet = SheetCore.unquoteit(replace(strip(sheet), r"^\$" => ""))
    hassheet(xf, sheet) || throw(ODSError("$(xf.source) has no sheet named `$sheet`."))
    return getsheet(xf, sheet), rest
end

"""
    insertRows(sheet, at; count = 1)
    insertRows(xf, "Sheet1.5"; count = 1)

Insert `count` empty rows before row `at` (an integer, or a string such as `"5"`). The rows from
`at` down move down, and everything that refers to them follows, as in LibreOffice: formulas on
every sheet, defined names, merged cells, conditional formats, validations, database ranges, print
ranges, charts and anchored shapes. A range that the new rows fall inside, or whose last row is at
`at`, grows.

The new rows take the cell formats of the row above, and its height when that height was set, and
are not hidden. Inserting at row 1 gives unformatted rows. An insert that would push a cell
with content or formatting off the sheet is an error, as it is in LibreOffice.

```julia
insertRows(sh, 2)                        # a new, empty row 2: =SUM(A1:B2,1) in C1 becomes =SUM(A1:B3,1)
insertRows(xf, "Sheet1.5"; count = 3)    # three rows before row 5
```
"""
function insertRows(ws::Worksheet, at::Union{Integer,AbstractString}; count::Integer = 1)
    _insert_lines!(ws, 1, at isa Integer ? at : _one_line(1, at), count, "rows")
end
insertRows(xf::ODSFile, ref::AbstractString; count::Integer = 1) =
    ((ws, rest) = _sheet_and_lines(xf, ref); insertRows(ws, rest; count))

"""
    insertColumns(sheet, at; count = 1)
    insertColumns(xf, "Sheet1.C"; count = 1)

Insert `count` empty columns before column `at` (an integer, or a column such as `"C"`). As
[`insertRows`](@ref), along the other axis. The new columns take the cell formats and default cell
style of the column to their left, and the width of the column they push to the right.
"""
function insertColumns(ws::Worksheet, at::Union{Integer,AbstractString}; count::Integer = 1)
    _insert_lines!(ws, 2, at isa Integer ? at : _one_line(2, at), count, "columns")
end
insertColumns(xf::ODSFile, ref::AbstractString; count::Integer = 1) =
    ((ws, rest) = _sheet_and_lines(xf, ref); insertColumns(ws, rest; count))

"""
    deleteRows(sheet, rows)
    deleteRows(xf, "Sheet1.3:5")

Delete rows: an integer, a range, a vector of row numbers, or a string (`"3"`, `"3:5"`,
`"3:5,9"` or `"3:5~9"`; a cell or range gives its rows, a defined name its range's rows). The rows
below move up, and everything that refers to them follows, as in LibreOffice: a reference
to a deleted cell becomes `#REF!`, and a range that loses some of its rows shrinks. Merges whose
first row is deleted are undone; validations, conditional formats and annotations on deleted cells
go with them.

As in LibreOffice, a picture or shape lying wholly in the deleted cells goes with them, and one
reaching beyond them stays where it is, anchored in the cell now at its place. Not yet
as LibreOffice does it: a validation that no cell uses any more stays in the file, unused
(LibreOffice drops it).
"""
deleteRows(ws::Worksheet, rows) = _delete_lines!(ws, 1, _lines_of(ws, 1, rows), "rows")
deleteRows(xf::ODSFile, ref::AbstractString) = ((ws, rest) = _sheet_and_lines(xf, ref); deleteRows(ws, rest))

"""
    deleteColumns(sheet, cols)
    deleteColumns(xf, "Sheet1.B:C")

Delete columns: an integer, a range, a vector of column numbers, or a string (`"B"`, `"B:C"`,
`"B:C,F"`; a cell or range gives its columns, a defined name its range's columns). As
[`deleteRows`](@ref), along the other axis.
"""
deleteColumns(ws::Worksheet, cols) = _delete_lines!(ws, 2, _lines_of(ws, 2, cols), "columns")
deleteColumns(xf::ODSFile, ref::AbstractString) = ((ws, rest) = _sheet_and_lines(xf, ref); deleteColumns(ws, rest))

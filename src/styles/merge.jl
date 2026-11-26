# Merged cells (phase 4): `mergeCells`, `removeMergedCells`, `getMergedCells`,
# `isMergedCell`, `getMergedBaseCell`.
#
# The API follows XLSX.jl 0.13.4 (src/cellformats/mergedcells.jl), MIT License, Copyright
# (c) 2018-2026 Felipe Noronha Tavares and other contributors. In ODF a merge is its anchor
# cell's `table:number-columns-spanned`/`-rows-spanned` and a `table:covered-table-cell` for
# every other cell (F-014). The store keeps the list of merges (`SheetStore.merges`, read
# with the cells); the spans live on the anchor's cell data, and the covered state on the
# cells' data or, for empty cells, in the sheet's formats (D-038).

# Sets the data of each cell of a block that the store holds no value for, through
# `g(old::Union{Nothing,CellData}) -> Union{Nothing,CellData}` (formatted empty cells).
function _map_empty_cells!(g::Function, ws::Worksheet, rows::UnitRange{Int}, cols::UnitRange{Int})
    s = _cached_store(ws)
    f = sheet_formats(ws)
    for r in rows
        vals = _runs_of(s.rows, r)
        for c in cols
            _run_at(vals, c) === nothing || continue
            old = _fmt_cell(f, r, c)
            new = g(old)
            new === old || _rows_set!(f.cells, r, c, new)
        end
    end
end

_with_merge(d::CellData, flags::UInt8, cs::Integer, rs::Integer) =
    CellData(d.kind, flags, d.style, d.bits, d.text, d.formula, Int32(cs), Int32(rs))

# Sets a cell's spans and covered state, whether it holds a value or not.
function _set_merge_state!(ws::Worksheet, r::Int, c::Int, covered::Bool, cs::Int, rs::Int)
    s = _cached_store(ws)
    flags(d) = covered ? (d.flags | F_COVERED) : (d.flags & ~F_COVERED)
    d = cell_data(s, r, c)
    if d !== nothing
        store_set!(s, r, c, _with_merge(d, flags(d), cs, rs))
    else
        _map_empty_cells!(ws, r:r, c:c) do old
            base = old === nothing ? CellData(CK_EMPTY, 0x00, Int32(-1), UInt64(0), nothing, nothing, Int32(1), Int32(1)) : old
            new = _with_merge(base, flags(base), cs, rs)
            # an empty cell with no style, covering nothing and not covered, is no format at all
            (new.style < 0 && !covered && cs == 1 && rs == 1) ? nothing : new
        end
    end
end

# The blocks of a merge or unmerge target: column and row ranges are taken to the used area,
# as XLSX.jl takes them.
function _merge_blocks(x, ref)
    out = Tuple{Worksheet,UnitRange{Int},UnitRange{Int}}[]
    for (ws, blocks) in format_targets(x, ref...)
        for b in blocks
            if b.kind === :cells
                push!(out, (ws, b.rows, b.cols))
            else
                dim = get_dimension(ws)
                rows = b.kind === :rows ? b.rows : row_number(dim.start):row_number(dim.stop)
                cols = b.kind === :cols ? b.cols : column_number(dim.start):column_number(dim.stop)
                push!(out, (ws, rows, cols))
            end
        end
    end
    return out
end

_merge_range(rows, cols) = CellRange(CellRef(first(rows), first(cols)), CellRef(last(rows), last(cols)))
_cols_of(r::CellRange) = column_number(r.start):column_number(r.stop)
_overlaps(a::CellRange, b::CellRange) =
    !isempty(intersect(_rows_of(a), _rows_of(b))) && !isempty(intersect(_cols_of(a), _cols_of(b)))

"""
    mergeCells(sheet, ref) -> 0
    mergeCells(sheet, row, col) / mergeCells(xf, "Sheet1.A1:C2")

Merge the cells of a range. The merged cell shows the value of the range's first (top-left)
cell; the other cells are emptied, and become covered cells
(`table:covered-table-cell`). Their formatting is kept. A list of ranges merges each range;
whole columns or rows are taken to the used area. A range may not be a single cell, nor overlap
a merged range, but it may reach past the used area.
"""
function mergeCells(x::Union{Worksheet,ODSFile}, ref...)
    for (ws, rows, cols) in _merge_blocks(x, ref)
        _require_writable(ws, "merge cells")
        rng = _merge_range(rows, cols)
        length(rows) == 1 && length(cols) == 1 && throw(ODSError("Cannot merge a single cell: `$rng`."))
        s = _cached_store(ws)
        for m in s.merges
            _overlaps(rng, m) && throw(ODSError("Merged range `$rng` cannot overlap the merged range `$m`."))
        end
        r1, c1 = first(rows), first(cols)
        for r in rows, c in cols                          # the other cells are emptied (XLSX.jl)
            (r, c) == (r1, c1) && continue
            old = cell_data(s, r, c)
            if old !== nothing
                store_set!(s, r, c, nothing)
                _after_cell_edit!(ws, r, c, old, nothing)
                _mark_dirty!(ws, r, c)
            end
        end
        _set_merge_state!(ws, r1, c1, false, length(cols), length(rows))
        f = sheet_formats(ws)
        _map_empty_cells!(ws, rows, cols) do old
            old !== nothing && old.colspan > 1 && return old             # the anchor
            base = old === nothing ? CellData(CK_EMPTY, 0x00, Int32(-1), UInt64(0), nothing, nothing, Int32(1), Int32(1)) : old
            return _with_merge(base, base.flags | F_COVERED, 1, 1)
        end
        _anchor_fix!(ws, r1, c1, rows, cols)
        push!(s.merges, rng)
        sort!(s.merges; by = m -> (row_number(m.start), column_number(m.start)))
        ws.entry === nothing || push!(f.rects, (rows, cols))
    end
    return 0
end

# A one-row merge's anchor is set before the covered cells are; make sure the anchor itself
# is not marked covered (a merge of one column has no colspan > 1 to recognise it by).
function _anchor_fix!(ws::Worksheet, r1::Int, c1::Int, rows, cols)
    _set_merge_state!(ws, r1, c1, false, length(cols), length(rows))
end

"""
    removeMergedCells(sheet, ref) -> 0
    removeMergedCells(sheet) / removeMergedCells(sheet, :)

Unmerge the merged range that encloses `ref` (so naming any one of its cells is enough), or
every merged range of the sheet. Values are not changed. A range no merge encloses is left
alone.
"""
function removeMergedCells(ws::Worksheet)
    _require_writable(ws, "remove merged cells")
    for m in copy(_cached_store(ws).merges)
        _unmerge!(ws, m)
    end
    return 0
end
removeMergedCells(ws::Worksheet, ::Colon) = removeMergedCells(ws)
function removeMergedCells(x::Union{Worksheet,ODSFile}, ref...)
    for (ws, rows, cols) in _merge_blocks(x, ref)
        _require_writable(ws, "remove merged cells")
        for m in copy(_cached_store(ws).merges)
            issubset(rows, _rows_of(m)) && issubset(cols, _cols_of(m)) && _unmerge!(ws, m)
        end
    end
    return 0
end

function _unmerge!(ws::Worksheet, m::CellRange)
    rows, cols = _rows_of(m), _cols_of(m)
    s = _cached_store(ws)
    f = sheet_formats(ws)
    for r in rows, c in cols
        _set_merge_state!(ws, r, c, false, 1, 1)
    end
    filter!(!=(m), s.merges)
    ws.entry === nothing || push!(f.rects, (rows, cols))
    return
end

"""
    getMergedCells(sheet) -> Union{Vector{CellRange}, Nothing}

The merged ranges of a sheet, in reading order, or `nothing` if it has none. Works on
read-only files.
"""
function getMergedCells(ws::Worksheet)
    m = _store_for(ws).merges
    return isempty(m) ? nothing : sort(unique(m); by = x -> (row_number(x.start), column_number(x.start)))
end

const _MergeList = Union{Vector{CellRange},Nothing,Missing}

"""
    isMergedCell(sheet, ref; mergedCells=missing) -> Bool

Whether a cell is part of a merged range. `mergedCells` (from [`getMergedCells`](@ref))
spares finding the merges again.
"""
function isMergedCell(x::Union{Worksheet,ODSFile}, ref...; mergedCells::_MergeList = missing)
    ws, r, c = format_cell(x, ref...)
    mc = mergedCells === missing ? getMergedCells(ws) : mergedCells
    mc === nothing && return false
    return any(m -> r in _rows_of(m) && c in _cols_of(m), mc)
end

"""
    getMergedBaseCell(sheet, ref; mergedCells=missing) -> Union{Nothing, NamedTuple}

The base (top-left) cell of the merged range holding `ref`, and its value:
`(baseCell = CellRef, baseValue = value)`, or `nothing` if the cell is not merged.
"""
function getMergedBaseCell(x::Union{Worksheet,ODSFile}, ref...; mergedCells::_MergeList = missing)
    ws, r, c = format_cell(x, ref...)
    mc = mergedCells === missing ? getMergedCells(ws) : mergedCells
    mc === nothing && return nothing
    for m in mc
        (r in _rows_of(m) && c in _cols_of(m)) && return (; baseCell = m.start, baseValue = ws[m.start])
    end
    return nothing
end

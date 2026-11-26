# The formats of a sheet (phase 4): what the value store leaves out.
#
# The store (`SheetStore`, model/sheetreader.jl) holds the cells with a value or formula.
# Formatting also needs:
#   - the cells without a value that have a style of their own, or are covered or span a
#     merge (stored as `CK_EMPTY` runs, apart from the store, so that the dimension, rows,
#     tables and `getdata` never see them)
#   - the columns: their column style (width), default cell style and visibility
#   - the rows: their row style (height), default cell style and visibility
# A `SheetFormats` is read the first time formatting needs it, by a pass over the sheet
# that reads only styles, so plain reads and writes never pay for it (phase 3's speed).

"""
    ColFormat(col, count, style, default, visibility)

`count` columns from `col` (`table:table-column`): the name of their column style (`""` for
none), their default cell style id (-1 for none) and their `table:visibility`.
"""
struct ColFormat
    col::Int32
    count::Int32
    style::String
    default::Int32
    visibility::String
end

"""
    RowFormat(row, count, style, default, visibility, ncells)

`count` rows from `row` (`table:table-row`): their row style name (`""` for none), default
cell style id (-1 for none; LibreOffice misreads these and never writes them, F-035, so
OpenDocumentSpreadsheets only reads them), `table:visibility`, and the number of columns their cells cover.
A column's default cell style reaches only those columns.
"""
struct RowFormat
    row::Int32
    count::Int32
    style::String
    default::Int32
    visibility::String
    ncells::Int32
end

const _VISIBLE = "visible"

_start(r::ColFormat) = Int(r.col)
_start(r::RowFormat) = Int(r.row)
_stop(r::Union{ColFormat,RowFormat}) = _start(r) + Int(r.count) - 1
_respan(r::ColFormat, a::Integer, n::Integer) = ColFormat(a, n, r.style, r.default, r.visibility)
_respan(r::RowFormat, a::Integer, n::Integer) = RowFormat(a, n, r.style, r.default, r.visibility, r.ncells)
_blank(::Type{ColFormat}, a::Integer, n::Integer) = ColFormat(a, n, "", -1, _VISIBLE)
_blank(::Type{RowFormat}, a::Integer, n::Integer) = RowFormat(a, n, "", -1, _VISIBLE, 0)
_same_format(a::ColFormat, b::ColFormat) = a.style == b.style && a.default == b.default && a.visibility == b.visibility
_same_format(a::RowFormat, b::RowFormat) = a.style == b.style && a.default == b.default && a.visibility == b.visibility && a.ncells == b.ncells
_isblank(r::ColFormat) = isempty(r.style) && r.default < 0 && r.visibility == _VISIBLE
_isblank(r::RowFormat) = isempty(r.style) && r.default < 0 && r.visibility == _VISIBLE && r.ncells == 0

"""
    LineGroup(first, last, depth, display)

A group of rows or columns: the lines `first:last`, its nesting depth (1 for a group no other
holds; LibreOffice allows 7), and whether it is expanded (`table:display`, false when collapsed).
Groups of a sheet nest: two either don't meet, or one holds the other.
"""
struct LineGroup
    first::Int
    last::Int
    depth::Int
    display::Bool
end

"""
    SheetFormats

The formats of a sheet that the value store leaves out:

- `cells`: the cells without a value or formula that have a style of their own (`style >= 0`),
  or are covered or span a merge (`CK_EMPTY` data; `style == -1` when they have no style)
- `cols`, `rows`: the column and row runs, from column / row 1, as the sheet defines them
- what changed since the sheet was read, for saving by patching: whether the columns
  changed (`cols_touched`), the rows whose attributes changed (`rows_touched`), and the
  blocks of cells restyled (`rects`, rows × columns)
"""
mutable struct SheetFormats
    cells::Vector{RowData}
    cols::Vector{ColFormat}
    rows::Vector{RowFormat}
    cols_touched::Bool
    rows_touched::Vector{UnitRange{Int}}
    rects::Vector{Tuple{UnitRange{Int},UnitRange{Int}}}
    # phase 5 step 7: the row and column groups (`table:table-row-group`, `-column-group`), and
    # whether they changed (then a save writes the sheet's containers again, D-060)
    rowgroups::Vector{LineGroup}
    colgroups::Vector{LineGroup}
    groups_touched::Bool
    # phase 5 step 10: the print titles (`table:table-header-rows`, `-columns`), or nothing
    title_rows::Union{Nothing,UnitRange{Int}}
    title_cols::Union{Nothing,UnitRange{Int}}
end
SheetFormats() = SheetFormats(RowData[], ColFormat[], RowFormat[], false, UnitRange{Int}[],
                              Tuple{UnitRange{Int},UnitRange{Int}}[], LineGroup[], LineGroup[], false, nothing, nothing)

# Whether formats changed since the sheet was read.
_formats_touched(f::SheetFormats) = f.cols_touched || !isempty(f.rows_touched) || !isempty(f.rects) || f.groups_touched

#
# Run lists
#

# The index of the first run ending at or after `x` (length + 1 if none).
function _fmt_index(v::Vector{T}, x::Integer) where {T<:Union{ColFormat,RowFormat}}
    lo, hi = 1, length(v)
    while lo <= hi
        mid = (lo + hi) >>> 1
        if _stop(@inbounds v[mid]) < x
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    return lo
end

# The run holding `x`, or `nothing`.
function _fmt_at(v::Vector{T}, x::Integer) where {T<:Union{ColFormat,RowFormat}}
    i = _fmt_index(v, x)
    return i <= length(v) && _start(v[i]) <= x ? v[i] : nothing
end

# Appends a run, merged into the last one when they are alike.
function _push_format!(v::Vector{T}, r::T) where {T<:Union{ColFormat,RowFormat}}
    if !isempty(v) && _stop(v[end]) + 1 == _start(r) && _same_format(v[end], r)
        v[end] = _respan(v[end], _start(v[end]), Int(v[end].count) + Int(r.count))
    else
        push!(v, r)
    end
    return v
end

"""
    set_formats!(f, v::Vector{<:Union{ColFormat,RowFormat}}, a, b)

Replace the runs over `a:b` by `f(run)` (each run cut to `a:b` first), extending the list with
blank runs where it ends before `b`. Alike neighbours are merged.
"""
function set_formats!(f::Function, v::Vector{T}, a::Int, b::Int) where {T<:Union{ColFormat,RowFormat}}
    stop = isempty(v) ? 0 : _stop(v[end])
    stop < b && push!(v, _blank(T, stop + 1, b - stop))
    i = _fmt_index(v, a)
    out = T[]
    j = i
    while j <= length(v) && _start(v[j]) <= b
        r = v[j]
        _start(r) < a && push!(out, _respan(r, _start(r), a - _start(r)))
        lo = max(_start(r), a); hi = min(_stop(r), b)
        push!(out, f(_respan(r, lo, hi - lo + 1)))
        _stop(r) > b && push!(out, _respan(r, b + 1, _stop(r) - b))
        j += 1
    end
    # merge with the neighbours
    merged = T[]
    i > 1 && push!(merged, v[i - 1])
    foreach(r -> _push_format!(merged, r), out)
    j <= length(v) && _push_format!(merged, v[j])
    lo = i > 1 ? i - 1 : i
    hi = j <= length(v) ? j : j - 1
    splice!(v, lo:hi, merged)
    return v
end

# `runs` without the columns that `vals` hold (both in column order).
function _runs_minus(runs::Vector{CellRun}, vals::Vector{CellRun})
    out = CellRun[]
    j = 1
    for r in runs
        a = Int(r.col); b = _lastcol(r)
        while j <= length(vals) && _lastcol(vals[j]) < a
            j += 1
        end
        k = j
        while a <= b
            if k <= length(vals) && vals[k].col <= b
                v = vals[k]
                v.col > a && push!(out, CellRun(a, Int(v.col) - a, r.data))
                a = max(a, _lastcol(v) + 1)
                k += 1
            else
                push!(out, CellRun(a, b - a + 1, r.data))
                break
            end
        end
    end
    return out
end

#
# Reading: a pass over the sheet that reads only the formats
#

"""
    read_formats(node, styles, store) -> SheetFormats

The formats of a sheet read from the file. The formatted cells are those with a style of
their own (or covered, or spanning) that `store` holds no value for: so a cell whose value
was removed by an edit keeps its style.
"""
function read_formats(node::XML.LazyNode{String}, styles::StyleIndex, store::SheetStore)
    f = SheetFormats()
    c = XML.Cursor(node)
    XML.next!(c)                 # on table:table (depth 1)
    nextrow = 1
    runs = CellRun[]
    open = Tuple{Int,Int,Bool,Bool}[]     # groups being read: (depth in the XML, first line, rows?, display)
    endgroups!(d) = while !isempty(open) && abs(open[end][1]) >= d
        xd, a, isrow, disp = pop!(open)
        last = isrow ? nextrow - 1 : (isempty(f.cols) ? 0 : _stop(f.cols[end]))
        if xd < 0                # the print titles (the depth is kept negative)
            last >= a && (isrow ? (f.title_rows = a:last) : (f.title_cols = a:last))
        else
            depth = count(g -> g[3] == isrow && g[1] > 0, open) + 1
            last >= a && push!(isrow ? f.rowgroups : f.colgroups, LineGroup(a, last, depth, disp))
        end
    end
    while XML.next!(c) !== nothing && XML.depth(c) > 1
        XML.nodetype(c) === XML.Element || continue
        endgroups!(XML.depth(c))
        t = XML.tag(c)
        if t == "table:table-row-group" || t == "table:table-column-group"
            isrow = t == "table:table-row-group"
            disp = true
            for (k, v) in XML.eachattribute!(c)
                k == "table:display" && (disp = v != "false")
            end
            push!(open, (XML.depth(c), isrow ? nextrow : (isempty(f.cols) ? 1 : _stop(f.cols[end]) + 1), isrow, disp))
            continue
        end
        if t == "table:table-header-rows" || t == "table:table-header-columns"
            isrow = t == "table:table-header-rows"
            push!(open, (-XML.depth(c), isrow ? nextrow : (isempty(f.cols) ? 1 : _stop(f.cols[end]) + 1), isrow, true))
            continue
        end
        if t == "table:table-row"
            nextrow = _read_row_formats!(f, c, styles, store, nextrow, runs)
        elseif t == "table:table-column"
            _read_col_format!(f, c, styles)
        elseif t in _ROW_CONTAINERS || t in _COL_CONTAINERS
            continue             # descend
        else
            XML.skip_element!(c)
        end
    end
    endgroups!(0)
    sort!(f.rowgroups; by = g -> (g.first, g.depth)); sort!(f.colgroups; by = g -> (g.first, g.depth))
    return f
end

# (repeat, style name, default cell style id, visibility) of a table:table-column or -row.
function _line_attrs(c, styles::StyleIndex, repeatkey::AbstractString)
    n = 1; style = ""; default = Int32(-1); vis = _VISIBLE
    for (k, v) in XML.eachattribute!(c)
        if k == repeatkey
            n = max(1, something(tryparse(Int, v), 1))
        elseif k == "table:style-name"
            style = String(v)
        elseif k == "table:default-cell-style-name"
            default = style_id(styles, v)
        elseif k == "table:visibility"
            vis = v == _VISIBLE ? _VISIBLE : String(v)
        end
    end
    return n, style, default, vis
end

function _read_col_format!(f::SheetFormats, c, styles::StyleIndex)
    n, style, default, vis = _line_attrs(c, styles, "table:number-columns-repeated")
    first = isempty(f.cols) ? 1 : _stop(f.cols[end]) + 1
    n = clamp(n, 0, SheetCore.MAX_COLS - first + 1)
    n > 0 && _push_format!(f.cols, ColFormat(first, n, style, default, vis))
    XML.skip_element!(c)
    return
end

function _read_row_formats!(f::SheetFormats, c, styles::StyleIndex, store::SheetStore, rowno::Int, runs::Vector{CellRun})
    n, style, default, vis = _line_attrs(c, styles, "table:number-rows-repeated")
    n = min(n, SheetCore.MAX_ROWS - rowno + 1)
    n <= 0 && (XML.skip_element!(c); return rowno)
    empty!(runs)
    col = 1
    XML.for_each_child!(c) do ch
        XML.nodetype(ch) === XML.Element || return
        t = XML.tag(ch)
        covered = t == "table:covered-table-cell"
        if covered || t == "table:table-cell"
            k = 1; s = Int32(-1); cs = 1; rs = 1
            for (key, v) in XML.eachattribute!(ch)
                if key == "table:number-columns-repeated"
                    k = max(1, something(tryparse(Int, v), 1))
                elseif key == "table:style-name"
                    s = style_id(styles, v)
                elseif key == "table:number-columns-spanned"
                    cs = max(1, something(tryparse(Int, v), 1))
                elseif key == "table:number-rows-spanned"
                    rs = max(1, something(tryparse(Int, v), 1))
                end
            end
            k = min(k, SheetCore.MAX_COLS - col + 1)
            if k > 0 && (s >= 0 || covered || cs > 1 || rs > 1)
                push!(runs, CellRun(col, k, CellData(CK_EMPTY, covered ? F_COVERED : 0x00, s, UInt64(0), nothing, nothing, cs, rs)))
            end
            col += max(k, 0)
        end
        XML.skip_element!(ch)
    end
    _push_format!(f.rows, RowFormat(rowno, n, style, default, vis, col - 1))
    isempty(runs) || _add_format_rows!(f.cells, rowno, n, runs, store)
    return rowno + n
end

# Adds the formatted cells `runs` of rows r0 … r0+n-1, without the cells the store holds.
function _add_format_rows!(cells::Vector{RowData}, r0::Int, n::Int, runs::Vector{CellRun}, store::SheetStore)
    r1 = r0 + n - 1
    a = r0
    i = _first_row_index(store, r0)
    while a <= r1
        if i <= length(store.rows) && store.rows[i].row <= r1
            sr = store.rows[i]
            if sr.row > a
                push!(cells, RowData(a, Int(sr.row) - a, copy(runs)))
                a = Int(sr.row)
            end
            b = min(_lastrow(sr), r1)
            rest = _runs_minus(runs, sr.runs)
            isempty(rest) || push!(cells, RowData(a, b - a + 1, rest))
            a = b + 1
            i += 1
        else
            push!(cells, RowData(a, r1 - a + 1, copy(runs)))
            break
        end
    end
    return cells
end

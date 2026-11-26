# A sheet's formats (styles/formats.jl), read on first use, and the edits formatting makes
# to them: restyling blocks of cells (empty ones too, D-033), and setting the attributes of
# columns and rows. The public setters (font, fill, widths, …) are built on these.

"""
    sheet_formats(ws::Worksheet) -> SheetFormats

The formats of a sheet, read the first time they are needed (empty for a new sheet).
"""
function sheet_formats(ws::Worksheet)
    f = ws.formats
    f === nothing || return f
    return lock(ws.lock) do
        if ws.formats === nothing
            ws.formats = if ws.entry === nothing
                SheetFormats()
            else
                styles = get_odsfile(ws).styles
                store = is_cache_enabled(ws) ? _cached_store(ws) : read_store(ws.entry.node, styles)
                read_formats(ws.entry.node, styles, store)
            end
        end
        ws.formats
    end
end

# Whether the sheet changed since it was read: its cells or its formats.
_has_edits(ws::Worksheet) = !isempty(ws.dirty) || (ws.formats !== nothing && _formats_touched(ws.formats)) ||
    ws.rowmap !== nothing || ws.colmap !== nothing

# The formatted cell (row, col) without a value, or `nothing`.
function _fmt_cell(f::SheetFormats, row::Integer, col::Integer)
    rd = _row_at(f.cells, row)
    rd === nothing && return nothing
    run = _run_at(rd.runs, col)
    return run === nothing ? nothing : run.data
end

# The style a cell shows when it has none of its own: its row's default, else its column's
# (only within the cells its row writes, F-035), else Default (F-009).
_inherited_style(f::SheetFormats, row::Integer, col::Integer) = _inherited_style(f, _fmt_at(f.rows, row), col)
function _inherited_style(f::SheetFormats, r::Union{Nothing,RowFormat}, col::Integer)
    r === nothing && return Int32(0)
    r.default >= 0 && return r.default
    col <= r.ncells || return Int32(0)
    c = _fmt_at(f.cols, col)
    c !== nothing && c.default >= 0 && return c.default
    return Int32(0)
end

"""
    effective_style(ws, row, col) -> Int32

The style id cell (row, col) shows: a stored cell's style, else the cell's own style, else
its row's or column's default, else 0 (Default).
"""
function effective_style(ws::Worksheet, row::Integer, col::Integer)
    d = cell_data(_store_for(ws, row:row), row, col)
    d === nothing || return d.style
    f = sheet_formats(ws)
    e = _fmt_cell(f, row, col)
    e !== nothing && e.style >= 0 && return e.style
    return _inherited_style(f, row, col)
end

# For a value or formula written where the store holds nothing: the cell's effective style,
# and from its formats whether it is covered and its spans. The formats of a sheet read
# from a file are read for it, so a formatted empty cell keeps its style (D-038).
function _empty_cell_base(ws::Worksheet, row::Int, col::Int)
    f = ws.entry === nothing ? ws.formats : sheet_formats(ws)
    f === nothing && return (Int32(0), 0x00, Int32(1), Int32(1))
    e = _fmt_cell(f, row, col)
    style = e !== nothing && e.style >= 0 ? e.style : _inherited_style(f, row, col)
    e === nothing && return (style, 0x00, Int32(1), Int32(1))
    return (style, e.flags & F_COVERED, e.colspan, e.rowspan)
end

# Keeps the formats in step with a cell edit (old → d): a cell given a value leaves the
# formatted empty cells; a cell whose value is removed keeps its style as one (as
# LibreOffice keeps a deleted cell's formatting).
function _after_cell_edit!(ws::Worksheet, row::Int, col::Int, old::Union{Nothing,CellData}, d::Union{Nothing,CellData})
    f = ws.formats
    f === nothing && return
    if d !== nothing
        _fmt_cell(f, row, col) === nothing || _rows_set!(f.cells, row, col, nothing)
    elseif old !== nothing
        covered = old.flags & F_COVERED
        if old.style != _inherited_style(f, row, col) || covered != 0 || old.colspan > 1 || old.rowspan > 1
            _rows_set!(f.cells, row, col, CellData(CK_EMPTY, covered, old.style, UInt64(0), nothing, nothing, old.colspan, old.rowspan))
        end
    end
    return
end

_with_style(d::CellData, s::Int32) = CellData(d.kind, d.flags, s, d.bits, d.text, d.formula, d.colspan, d.rowspan)

# Splits the run of rows holding `r`, so that a run starts at `r`.
function _split_rows!(rows::Vector{RowData}, r::Int)
    i = _first_row_index(rows, r)
    if i <= length(rows) && rows[i].row < r
        rd = rows[i]
        splice!(rows, i:i, [RowData(rd.row, r - rd.row, rd.runs), RowData(r, _lastrow(rd) - r + 1, copy(rd.runs))])
    end
    return rows
end

# The runs of the row list at row `r` (empty if none).
const _NO_RUNS = CellRun[]
_runs_of(rows::Vector{RowData}, r::Integer) = (rd = _row_at(rows, r); rd === nothing ? _NO_RUNS : rd.runs)

# Appends a run, merged into the last one when it continues it with the same data.
function _push_run!(out::Vector{CellRun}, r::CellRun)
    if !isempty(out) && _lastcol(out[end]) + 1 == r.col && out[end].data === r.data
        out[end] = CellRun(out[end].col, out[end].count + r.count, r.data)
    else
        push!(out, r)
    end
    return out
end

# `runs` with the style of the cells in c1:c2 mapped by `m`.
function _restyle_runs!(runs::Vector{CellRun}, c1::Int, c2::Int, m)
    # in place when no run straddles c1 or c2 (the usual case): no new vector
    straddles = false
    for r in runs
        a = Int(r.col); b = _lastcol(r)
        (a < c1 <= b || a <= c2 < b) && (straddles = true; break)
    end
    if !straddles
        @inbounds for i in eachindex(runs)
            r = runs[i]
            (r.col < c1 || r.col > c2) && continue
            s = m(r.data.style)
            s == r.data.style || (runs[i] = CellRun(r.col, r.count, _with_style(r.data, s)))
        end
        return runs
    end
    out = CellRun[]
    for r in runs
        a = Int(r.col); b = _lastcol(r)
        if b < c1 || a > c2
            push!(out, r)
        else
            a < c1 && push!(out, CellRun(a, c1 - a, r.data))
            lo = max(a, c1); hi = min(b, c2)
            push!(out, CellRun(lo, hi - lo + 1, _with_style(r.data, m(r.data.style))))
            b > c2 && push!(out, CellRun(c2 + 1, b - c2, r.data))
        end
    end
    empty!(runs)
    append!(runs, out)
    return runs
end

# Whether the runs (in column order) hold every column of c1:c2.
function _covers(runs::Vector{CellRun}, c1::Int, c2::Int)
    next = c1
    for r in runs
        _lastcol(r) < next && continue
        r.col > next && return false
        next = _lastcol(r) + 1
        next > c2 && return true
    end
    return false
end

# Adds to `bps` the starts and ends (+1) of the runs in a:b.
function _row_bounds!(bps::Vector{Int}, rows::Vector{RowData}, a::Int, b::Int)
    i = _first_row_index(rows, a)
    while i <= length(rows) && rows[i].row <= b
        push!(bps, Int(rows[i].row), _lastrow(rows[i]) + 1)
        i += 1
    end
    return bps
end
function _row_bounds!(bps::Vector{Int}, v::Vector{T}, a::Int, b::Int) where {T<:Union{ColFormat,RowFormat}}
    i = _fmt_index(v, a)
    while i <= length(v) && _start(v[i]) <= b
        push!(bps, _start(v[i]), _stop(v[i]) + 1)
        i += 1
    end
    return bps
end
function _col_bounds!(bps::Vector{Int}, runs::Vector{CellRun}, a::Int, b::Int)
    for r in runs
        (r.col > b || _lastcol(r) < a) && continue
        push!(bps, Int(r.col), _lastcol(r) + 1)
    end
    return bps
end

# The breakpoints in a:b (a and b+1 included), sorted and unique.
_segment_points(bps::Vector{Int}, a::Int, b::Int) = unique!(sort!(filter!(x -> a <= x <= b + 1, push!(bps, a, b + 1))))

# The formatted empty cells of one row after restyling c1:c2: `ex` (its formatted cells),
# with every cell of c1:c2 that holds no value (`vals`) given the style `m(effective style)`.
function _restyled_empty_runs(ex::Vector{CellRun}, vals::Vector{CellRun}, c1::Int, c2::Int, f::SheetFormats,
                              rf::Union{Nothing,RowFormat}, m)
    # a row whose values fill c1:c2 and that has no formatted empty cells: nothing to do
    isempty(ex) && _covers(vals, c1, c2) && return _NO_RUNS
    out = CellRun[]
    for r in ex                                   # before c1
        r.col < c1 && _push_run!(out, CellRun(r.col, min(_lastcol(r), c1 - 1) - r.col + 1, r.data))
    end
    bps = Int[]
    _col_bounds!(bps, ex, c1, c2)
    _col_bounds!(bps, vals, c1, c2)
    _row_bounds!(bps, f.cols, c1, c2)
    rf === nothing || push!(bps, Int(rf.ncells) + 1)
    pts = _segment_points(bps, c1, c2)
    for k in 1:length(pts)-1
        x = pts[k]; y = pts[k + 1] - 1
        _run_at(vals, x) === nothing || continue
        e = _run_at(ex, x)
        own = e === nothing ? Int32(-1) : e.data.style
        eff = own >= 0 ? own : _inherited_style(f, rf, x)
        new = m(eff)
        d = e === nothing ? CellData(CK_EMPTY, 0x00, new, UInt64(0), nothing, nothing, Int32(1), Int32(1)) : _with_style(e.data, new)
        _push_run!(out, CellRun(x, y - x + 1, d))
    end
    for r in ex                                   # after c2
        _lastcol(r) > c2 && _push_run!(out, CellRun(max(Int(r.col), c2 + 1), _lastcol(r) - max(Int(r.col), c2 + 1) + 1, r.data))
    end
    return out
end

function _check_block(rows::UnitRange{Int}, cols::UnitRange{Int})
    (1 <= first(rows) && last(rows) <= SheetCore.MAX_ROWS && 1 <= first(cols) && last(cols) <= SheetCore.MAX_COLS) ||
        throw(ODSError("Rows $rows, columns $cols are outside the sheet (at most $(SheetCore.MAX_ROWS) rows and $(SheetCore.MAX_COLS) columns)."))
end

"""
    restyle_cells!(m, ws, rows, cols) -> ws

Give every cell of the block `rows × cols` the style `m(id)`, where `id` is the style it
shows now: cells with a value or formula, and empty ones, which become formatted
empty cells. `m` is called once per distinct style.
"""
function restyle_cells!(m::Function, ws::Worksheet, rows::UnitRange{Int}, cols::UnitRange{Int})
    (isempty(rows) || isempty(cols)) && return ws
    _check_block(rows, cols)
    memo = Dict{Int32,Int32}()
    ms = s -> get!(() -> Int32(m(s)), memo, s)
    s = _cached_store(ws)
    f = sheet_formats(ws)
    r1, r2 = first(rows), last(rows)
    c1, c2 = first(cols), last(cols)
    # the cells with values
    _split_rows!(s.rows, r1); _split_rows!(s.rows, r2 + 1)
    i = _first_row_index(s.rows, r1)
    while i <= length(s.rows) && s.rows[i].row <= r2
        _restyle_runs!(s.rows[i].runs, c1, c2, ms)
        i += 1
    end
    # the empty ones, row segment by row segment
    _split_rows!(f.cells, r1); _split_rows!(f.cells, r2 + 1)
    bps = Int[]
    _row_bounds!(bps, s.rows, r1, r2)
    _row_bounds!(bps, f.cells, r1, r2)
    _row_bounds!(bps, f.rows, r1, r2)
    pts = _segment_points(bps, r1, r2)
    new = RowData[]
    for k in 1:length(pts)-1
        a = pts[k]; b = pts[k + 1] - 1
        runs = _restyled_empty_runs(_runs_of(f.cells, a), _runs_of(s.rows, a), c1, c2, f, _fmt_at(f.rows, a), ms)
        isempty(runs) && continue
        if !isempty(new) && _lastrow(new[end]) + 1 == a && new[end].runs == runs
            new[end] = RowData(new[end].row, new[end].count + b - a + 1, new[end].runs)
        else
            push!(new, RowData(a, b - a + 1, runs))
        end
    end
    lo = _first_row_index(f.cells, r1)
    hi = lo
    while hi <= length(f.cells) && f.cells[hi].row <= r2
        hi += 1
    end
    splice!(f.cells, lo:hi-1, new)
    ws.entry === nothing || push!(f.rects, (rows, cols))
    return ws
end

"""
    restyle_columns!(m, ws, cols) -> ws

Format whole columns, as LibreOffice does: their default cell style becomes
`m(the default they had, or Default)`, the cells of every row with a value or a style of
their own are restyled, and every row's cells are made to reach the last column, so that
the column default reaches the empty ones.
"""
function restyle_columns!(m::Function, ws::Worksheet, cols::UnitRange{Int})
    isempty(cols) && return ws
    _check_block(1:1, cols)
    memo = Dict{Int32,Int32}()
    ms = s -> s < 0 ? s : get!(() -> Int32(m(s)), memo, s)
    s = _cached_store(ws)
    f = sheet_formats(ws)
    c1, c2 = first(cols), last(cols)
    for rd in s.rows
        _restyle_runs!(rd.runs, c1, c2, ms)
    end
    for rd in f.cells
        _restyle_runs!(rd.runs, c1, c2, ms)
    end
    set_formats!(f.cols, c1, c2) do r
        ColFormat(r.col, r.count, r.style, ms(r.default >= 0 ? r.default : Int32(0)), r.visibility)
    end
    set_row_formats!(ws, 1:SheetCore.MAX_ROWS; cover = c2)
    if ws.entry !== nothing
        f.cols_touched = true
        push!(f.rects, (1:SheetCore.MAX_ROWS, cols))
    end
    return ws
end

_or(x, y) = x === nothing ? y : x

"""
    set_column_formats!(ws, cols; style=nothing, default=nothing, visibility=nothing)

Set the column style name (`""`: none), default cell style id (-1: none) or visibility of
the columns `cols`; `nothing` leaves an attribute as it is.
"""
function set_column_formats!(ws::Worksheet, cols::UnitRange{Int}; style::Union{Nothing,AbstractString} = nothing,
                             default::Union{Nothing,Integer} = nothing, visibility::Union{Nothing,AbstractString} = nothing)
    isempty(cols) && return ws
    _check_block(1:1, cols)
    f = sheet_formats(ws)
    set_formats!(f.cols, first(cols), last(cols)) do r
        ColFormat(r.col, r.count, String(_or(style, r.style)), Int32(_or(default, r.default)), String(_or(visibility, r.visibility)))
    end
    ws.entry === nothing || (f.cols_touched = true)
    return ws
end

"""
    set_row_formats!(ws, rows; style=nothing, visibility=nothing, cover=0)

Set the row style name (`""`: none) or visibility of the rows `rows` (`nothing` leaves an
attribute as it is), and make their cells cover at least `cover` columns, so that the
default cell styles of those columns reach them. Rows get no default cell style:
LibreOffice misreads those.
"""
function set_row_formats!(ws::Worksheet, rows::UnitRange{Int}; style::Union{Nothing,AbstractString} = nothing,
                          visibility::Union{Nothing,AbstractString} = nothing, cover::Integer = 0)
    isempty(rows) && return ws
    _check_block(rows, 1:max(1, cover))
    f = sheet_formats(ws)
    set_formats!(f.rows, first(rows), last(rows)) do r
        RowFormat(r.row, r.count, String(_or(style, r.style)), r.default, String(_or(visibility, r.visibility)),
                  max(r.ncells, Int32(cover)))
    end
    ws.entry === nothing || push!(f.rows_touched, rows)
    return ws
end

# Column widths, row heights and autofit (phase 4): `setColumnWidth`, `getColumnWidth`,
# `setRowHeight`, `getRowHeight`, `autofitColumns`.
#
# The API follows XLSX.jl 0.13.4 (src/cellformats/widthheight.jl and autofit.jl), MIT
# License, Copyright (c) 2018-2026 Felipe Noronha Tavares and other contributors. In ODF a
# column's width is its column style's `style:column-width` (a length), a row's height its
# row style's `style:row-height`. Widths are in XLSX.jl's character units unless `unit` says
# otherwise, converted as LibreOffice converts the widths of XLSX.jl's files (D-034, F-033).

# A character, in cm: LibreOffice's width for one unit of an xlsx width when the default
# font is 12 pt, as in XLSX.jl's template (experiment 014).
const CHAR_WIDTH_CM = 0.2152
const EXCEL_COLUMN_WIDTH_PADDING = 0.7109375     # XLSX.jl adds it to a width it stores
const EXCEL_ROW_HEIGHT_PADDING = 0.2109375       # and this to a height

const _CM_PER = Dict(:cm => 1.0, :mm => 0.1, :in => 2.54, :pt => 2.54 / 72)

function _width_cm(width::Real, unit::Symbol)
    width < 0 && throw(ODSError("Invalid width: $width. Must be >= 0."))
    unit === :chars && return CHAR_WIDTH_CM * (width + EXCEL_COLUMN_WIDTH_PADDING)
    haskey(_CM_PER, unit) || throw(ODSError("Invalid unit `$unit`: give :chars, :cm, :mm, :in or :pt."))
    return width * _CM_PER[unit]
end

_cm_from(w_cm::Float64, unit::Symbol) = unit === :chars ? round(w_cm / CHAR_WIDTH_CM; digits = 8) :
    (haskey(_CM_PER, unit) ? round(w_cm / _CM_PER[unit]; digits = 8) : throw(ODSError("Invalid unit `$unit`: give :chars, :cm, :mm, :in or :pt.")))

function _length_text(cm::Float64)
    x = round(cm; digits = 8)
    s = isinteger(x) ? string(Int(x)) : rstrip(rstrip(@sprintf("%.8f", x), '0'), '.')
    return s * "cm"
end
function _length_cm(s::Union{Nothing,AbstractString})
    s === nothing && return nothing
    p = _length_pt(s)
    return p === nothing ? nothing : p * 2.54 / 72
end

# The columns (rows) a target names: the columns of its cells, ranges and whole columns; for
# whole rows, the used area's columns (as XLSX.jl).
function _target_lines(x, ref, cols::Bool)
    out = Pair{Worksheet,Vector{UnitRange{Int}}}[]
    for (ws, blocks) in format_targets(x, ref...)
        dim = get_dimension(ws)
        rs = UnitRange{Int}[]
        for b in blocks
            if cols
                push!(rs, b.kind === :rows ? (column_number(dim.start):column_number(dim.stop)) : b.cols)
            else
                push!(rs, b.kind === :cols ? (row_number(dim.start):row_number(dim.stop)) : b.rows)
            end
        end
        push!(out, ws => _merge_ranges(rs))
    end
    return out
end

# Sets the given properties on the column (family 1) or row (2) styles of lines a:b,
# deriving one new style per style the lines had.
function _set_line_props!(ws::Worksheet, family::Int, a::Int, b::Int, changes::Pair...)
    st = get_odsfile(ws).styles
    f = sheet_formats(ws)
    memo = Dict{String,String}()
    restyle(name) = get!(memo, name) do
        add_line_style!(st, family, setprops(line_props(st, family, name), changes...))
    end
    if family == 1
        set_formats!(r -> ColFormat(r.col, r.count, restyle(r.style), r.default, r.visibility), f.cols, a, b)
        ws.entry === nothing || (f.cols_touched = true)
    else
        set_formats!(r -> RowFormat(r.row, r.count, restyle(r.style), r.default, r.visibility, r.ncells), f.rows, a, b)
        ws.entry === nothing || push!(f.rows_touched, a:b)
    end
end

"""
    setColumnWidth(sheet, ref; width, unit=:chars) -> 0
    setColumnWidth(sheet, row, col; width, unit=:chars)
    setColumnWidth(sheet, col; width) / setColumnWidth(xf, "Sheet1.B:D"; width)

Set the width of the columns `ref` names (a cell, range, column range, defined name, or rows
and columns as integers, ranges, vectors or `:`; only the columns are used).

`width` is in characters by default, stored as LibreOffice stores a width given in characters by
other spreadsheet programs: 0.2152 cm × (width + 0.7109375). With `unit = :cm`, `:mm`, `:in` or `:pt`, `width` is a length. A width may be 0.
"""
function setColumnWidth(x::Union{Worksheet,ODSFile}, ref...; width::Union{Nothing,Real} = nothing, unit::Symbol = :chars)
    width === nothing && return 0
    w = _length_text(_width_cm(width, unit))
    for (ws, ranges) in _target_lines(x, ref, true)
        _require_writable(ws, "set column widths")
        for r in ranges
            _set_line_props!(ws, 1, first(r), last(r), "style:column-width" => w, "style:use-optimal-column-width" => nothing)
        end
    end
    return 0
end
setColumnWidth(ws::Worksheet, col::Union{Integer,AbstractVector{<:Integer}}; kw...) = setColumnWidth(ws, :, col; kw...)

"""
    getColumnWidth(sheet, ref; unit=:chars) -> Union{Nothing, Float64}
    getColumnWidth(sheet, row, col; unit=:chars)

The width of the column of one cell, or `nothing` if its column style gives none. In
characters by default, including the column's padding of 0.7109375 characters, so a width set
as 20 reads back as 20.7109375; with `unit`, as a length. Works on read-only files.
"""
function getColumnWidth(x::Union{Worksheet,ODSFile}, ref...; unit::Symbol = :chars)
    ws, _, c = format_cell(x, ref...)
    r = _fmt_at(sheet_formats(ws).cols, c)
    r === nothing && return nothing
    cm = _length_cm(getprop(line_props(get_odsfile(ws).styles, 1, r.style), "style:column-width"))
    return cm === nothing ? nothing : _cm_from(cm, unit)
end

"""
    setRowHeight(sheet, ref; height) -> 0
    setRowHeight(sheet, row, col; height) / setRowHeight(sheet, row; height)

Set the height, in points, of the rows `ref` names (only the rows are used). LibreOffice
then keeps the height rather than fitting it to the text (`use-optimal-row-height="false"`).
A height may be 0.
"""
function setRowHeight(x::Union{Worksheet,ODSFile}, ref...; height::Union{Nothing,Real} = nothing)
    height === nothing && return 0
    height < 0 && throw(ODSError("Invalid value specified for height: $height. Height must be >= 0."))
    h = replace(_length_text(Float64(height)), "cm" => "pt")     # in points, as given (exact)
    for (ws, ranges) in _target_lines(x, ref, false)
        _require_writable(ws, "set row heights")
        for r in ranges
            _set_line_props!(ws, 2, first(r), last(r), "style:row-height" => h, "style:use-optimal-row-height" => "false")
        end
    end
    return 0
end
setRowHeight(ws::Worksheet, row::Union{Integer,AbstractVector{<:Integer}}; kw...) = setRowHeight(ws, row, :; kw...)

"""
    getRowHeight(sheet, ref) -> Union{Nothing, Float64}
    getRowHeight(sheet, row, col)

The height of the row of one cell, in points, including the row's padding of 0.2109375 points,
so a height set as 30 reads back as 30.2109375.
`nothing` if its row style gives no height, -1 if the sheet has no such row. Works on
read-only files.
"""
function getRowHeight(x::Union{Worksheet,ODSFile}, ref...)
    ws, r, _ = format_cell(x, ref...)
    rf = _fmt_at(sheet_formats(ws).rows, r)
    rf === nothing && return -1
    cm = _length_cm(getprop(line_props(get_odsfile(ws).styles, 2, rf.style), "style:row-height"))
    return cm === nothing ? nothing : round(cm * 72 / 2.54 + EXCEL_ROW_HEIGHT_PADDING; digits = 8)
end

#
# Autofit
#

# LibreOffice's fonts measured as their metric twins, whose widths SheetCore has (Q-010).
const _METRIC_TWINS = ("liberation sans" => "Arial", "liberation serif" => "Times New Roman",
                       "liberation mono" => "Courier New", "carlito" => "Calibri", "caladea" => "Cambria")

function _measured_font(name::AbstractString)
    key = lowercase(name)
    for (k, twin) in _METRIC_TWINS
        startswith(key, k) && return twin
    end
    return name
end

# The font (name, size in pt, bold) a style shows.
function _style_font(st::StyleIndex, id::Int32)
    _, _, text = resolved_props(st, id)
    d = _font_dict(text)
    return (d["name"]["val"], parse(Float64, d["sz"]["val"]), haskey(d, "b"))
end

# LibreOffice's optimal width: the text's width plus this, in points (F-034).
const LO_AUTOFIT_PADDING_PT = 7.9

"""
    autofitColumns(sheet, [cols=:]; min_width=0, max_width=255) -> Dict{Int,Float64}

Set the width of columns to fit the text their cells show ([`getText`](@ref OpenDocumentSpreadsheets.getText)),
as LibreOffice's optimal column width does: the widest text, in each cell's font, size and
boldness, plus 7.9 pt. `cols` is `:` (every column with something in it), a column
number, a range or vector of numbers, or letters such as `"B"`, `"B:D"` or `"A,C:E"`.

Widths are in characters, as [`setColumnWidth`](@ref) takes them, kept between `min_width`
and `max_width`. A column whose cells show nothing keeps its width; cells in merged ranges
are left out. Returns the width set for each column, by column number.

The widths are approximate: characters are measured with the widths Excel uses for Calibri,
Aptos, Arial, Times New Roman and Courier New, LibreOffice's Liberation fonts as their metric
twins (Arial, Times New Roman, Courier New), and other fonts as Calibri.
"""
function autofitColumns(ws::Worksheet, cols = :; min_width::Real = 0, max_width::Real = 255)
    _require_writable(ws, "autofit columns")
    0 <= min_width <= max_width <= 255 ||
        throw(ODSError("Widths must have 0 ≤ `min_width` ≤ `max_width` ≤ 255, got $min_width and $max_width."))
    wanted = SheetCore._autofit_columns(cols)
    st = get_odsfile(ws).styles
    s = _cached_store(ws)
    merged = s.merges
    fonts = Dict{Int32,Tuple{String,Float64,Bool}}()
    cache = _CodeCache()
    widest = Dict{Int,Float64}()
    for rd in s.rows, run in rd.runs
        for c in run.col:_lastcol(run)
            (wanted === nothing || c in wanted) || continue
            r = Int(rd.row)
            any(m -> row_number(m.start) <= r + rd.count - 1 && r <= row_number(m.stop) &&
                     column_number(m.start) <= c <= column_number(m.stop), merged) && continue
            text = cell_text(ws, r, c; for_width = true, cache, store = s)
            isempty(text) && continue
            name, size, bold = get!(() -> _style_font(st, run.data.style), fonts, run.data.style)
            pt = SheetCore.text_width_points(text, _measured_font(name), size; bold) + LO_AUTOFIT_PADDING_PT
            widest[c] = max(get(widest, c, 0.0), pt)
        end
    end
    for (c, pt) in widest
        w = round(clamp(pt * 2.54 / 72 / CHAR_WIDTH_CM - EXCEL_COLUMN_WIDTH_PADDING, min_width, max_width); digits = 2)
        widest[c] = w
        setColumnWidth(ws, :, c; width = w)
    end
    return widest
end

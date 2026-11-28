# Sparklines (phase 8 step 8, D-085, D-086): XLSX.jl's `addSparklines`, `getSparklines` and
# `deleteSparklines` on LibreOffice's sparkline groups (F-084). The model and its patching are the main
# module's (`write/sparklines.jl`); this file reads and writes the groups' XML, with the colours of
# charts. The functions are bound at the top level, as XLSX.jl's are.
# The API follows XLSX.jl dev (src/sparklines.jl), MIT License, Copyright (c) 2018-2026 Felipe Noronha
# Tavares and other contributors: names, keywords, defaults, checks and return shapes.

const _SPARK_TYPES = (line = "line", column = "column", winloss = "stacked")
const _SPARK_EMPTY = (gap = "gap", zero = "zero", span = "span")
# the colours: keyword, attribute, and XLSX.jl's (Excel's) default, as LibreOffice's import keeps it
const _SPARK_COLORS = (seriesColor = ("color-series", "#376092"), negativeColor = ("color-negative", "#d00000"),
    axisColor = ("color-axis", "#000000"), markersColor = ("color-markers", "#d00000"), firstColor = ("color-first", "#d00000"),
    lastColor = ("color-last", "#d00000"), highColor = ("color-high", "#d00000"), lowColor = ("color-low", "#d00000"))
# the on/off options, in LibreOffice's order
const _SPARK_FLAGS = (markers = "markers", high = "high", low = "low", first = "first", last = "last", negative = "negative",
    axis = "display-x-axis", showHidden = "display-hidden", rightToLeft = "right-to-left")
const _SPARK_KEYWORDS = (:type, :emptyCells, :lineWeight, :min, :max, :dateRange, keys(_SPARK_FLAGS)..., keys(_SPARK_COLORS)...)

"""
    addSparklines(ws::Worksheet, location, data; type = :line, kw...)

A group of sparklines, small charts each in one cell: `location` is the cell, or the row
or column of cells, to hold them, and `data` the cells they chart, on this sheet or another
(`"Data!B2:M13"`, `"Data.B2:M13"`):
- one cell: one sparkline of a row or column of data;
- a column of cells: one sparkline for each row of `data` (as many rows), or each column;
- a row of cells: one sparkline for each column of `data`, or each row.

A sparkline already in one of the cells is replaced. The group's options: `type`
(`:line`, `:column`, `:winloss`, which LibreOffice calls stacked), `markers`, `high`, `low`, `first`,
`last`, `negative` (`true` by default for `:winloss`), `axis`, `emptyCells` (`:gap`, `:zero`, `:span`),
`showHidden`, `lineWeight` (points, 0.75), `min` and `max` (`:individual`, `:group` or a number),
`rightToLeft`, and the colours `seriesColor`, `negativeColor`, `axisColor`, `markersColor`,
`firstColor`, `lastColor`, `highColor`, `lowColor` (hex, a colour name, a theme colour or a
`SchemeColor`, resolved against the document's theme).

LibreOffice keeps no date range: `dateRange` is an error. A sparkline follows its cell through
inserts and deletes, and its data moves as a chart's; LibreOffice itself leaves both
where they were.
"""
function addSparklines(ws::Worksheet, location, data; kw...)
    xf = get_odsfile(ws)
    _require_writable(xf, "add sparklines")
    for k in keys(kw)
        k in _SPARK_KEYWORDS || throw(ODSError("Unknown keyword `$k`. Must be one of $(join(_SPARK_KEYWORDS, ", "))."))
    end
    haskey(kw, :dateRange) && kw[:dateRange] !== nothing &&
        throw(ODSError("LibreOffice's sparklines keep no date range (F-084, D-086): its dates would be lost."))
    cells = _spark_cells(ws, location)
    sheet, rows, cols = _spark_data(ws, data)
    sparks = _spark_pairs(cells, rows, cols, location, data)
    group = _spark_group(xf, ws.name, sheet, sparks; kw...)
    st = _spark_state(ws)
    _spark_remove!(st, Set(cells), false)
    pushfirst!(st.list, group)                   # a new group first, as XLSX.jl's (and LibreOffice's import's order)
    st.edited = true
    return nothing
end

# The cells of `location`: one cell, or one row or column of them, as (row, col).
function _spark_cells(ws, location)
    s = location isa AbstractString ? replace(String(location), '$' => "") : string(location)
    rng = occursin(':', s) ? CellRange(s) : (c = CellRef(s); CellRange(c, c))
    r1, c1 = row_number(rng.start), column_number(rng.start); r2, c2 = row_number(rng.stop), column_number(rng.stop)
    (r1 == r2 || c1 == c2) || throw(ODSError("Sparklines go in one row or one column of cells, not `$location`."))
    return [(r, c) for r in r1:r2 for c in c1:c2]
end

# The sheet and cells of a data reference (`"B2:M13"`, `"Data!B2:M13"`, `"Data.B2:M13"`).
function _spark_data(ws, data)
    areas = _range_areas(_odf_range(data, ws.name))
    length(areas) == 1 || throw(ODSError("The sparklines' data must be one range of cells, such as `B2:M13`. Found `$data`."))
    sheet, rows, cols = only(areas)
    hassheet(get_odsfile(ws), sheet) || throw(ODSError("The sparklines' data refers to sheet `$sheet`, which isn't in the workbook."))
    return sheet, rows, cols
end

# Each sparkline's cell and data (rows, cols), as XLSX.jl pairs them.
function _spark_pairs(cells, rows, cols, location, data)
    nr, nc, n = length(rows), length(cols), length(cells)
    byrow() = [(r:r, cols) for r in rows]
    bycol() = [(rows, c:c) for c in cols]
    if n == 1
        (nr == 1 || nc == 1) || throw(ODSError("One sparkline charts one row or column of data, not `$data`. Give a cell for each row or column."))
        return [only(cells) => (rows, cols)]
    end
    vertical = first(cells)[2] == last(cells)[2]
    parts = vertical ? (nr == n ? byrow() : nc == n ? bycol() : nothing) : (nc == n ? bycol() : nr == n ? byrow() : nothing)
    parts === nothing && throw(ODSError("The data `$data` has $nr rows and $nc columns, but there are $n cells in `$location`: give one row or column of data for each sparkline."))
    return [c => p for (c, p) in zip(cells, parts)]
end

_spark_addr(sheet, r, c) = SheetCore.quoteit(sheet) * "." * _cellname(r, c)
_spark_range(sheet, rows, cols) = _spark_addr(sheet, first(rows), first(cols)) * ":" * _spark_addr(sheet, last(rows), last(cols))

# A group's element, as LibreOffice writes one (F-084): its options in LibreOffice's order, every colour.
function _spark_group(xf, cellsheet, datasheet, sparks; type::Symbol = :line, emptyCells::Symbol = :gap, lineWeight::Real = 0.75,
                      min::Union{Symbol,Real} = :individual, max::Union{Symbol,Real} = :individual, dateRange = nothing, kw...)
    haskey(_SPARK_TYPES, type) || throw(ODSError("Invalid sparkline `type` `:$type`. Must be one of :line, :column, :winloss."))
    haskey(_SPARK_EMPTY, emptyCells) || throw(ODSError("Invalid `emptyCells` `:$emptyCells`. Must be one of :gap, :zero, :span."))
    (isfinite(lineWeight) && 0 < lineWeight <= 1584) || throw(ODSError("Invalid `lineWeight` $lineWeight. Must be a width in points, more than 0."))
    io = IOBuffer()
    print(io, "<calcext:sparkline-group calcext:id=\"{00000000-0000-0000-0000-000000000000}\" calcext:type=\"", _SPARK_TYPES[type],
          "\" calcext:line-width=\"", _num_text(lineWeight), "pt\" calcext:display-empty-cells-as=\"", _SPARK_EMPTY[emptyCells], "\"")
    for (k, att) in pairs(_SPARK_FLAGS)
        v = get(kw, k, k === :negative && type === :winloss)
        v isa Bool || throw(ODSError("`$k` must be `true` or `false`. Found `$(repr(v))`."))
        v && print(io, " calcext:", att, "=\"true\"")
    end
    manual = String[]
    for (k, v, att) in ((:min, min, "min-axis-type"), (:max, max, "max-axis-type"))
        if v isa Real
            isfinite(v) || throw(ODSError("`$k` must be a finite number, `:individual` or `:group`."))
            print(io, " calcext:", att, "=\"custom\"")
            push!(manual, " calcext:manual-$k=\"" * _num_text(v) * "\"")
        elseif v in (:group, :individual)
            print(io, " calcext:", att, "=\"", v, "\"")
        else
            throw(ODSError("Invalid `$k` `:$v`. Must be `:individual`, `:group` or a number."))
        end
    end
    print(io, join(reverse(manual)))                             # manual-max before manual-min, as LibreOffice
    for (k, (att, default)) in pairs(_SPARK_COLORS)
        c = get(kw, k, nothing)
        col = c === nothing ? default : first(_color_value(xf, c isa AbstractString && length(lstrip(c, '#')) == 8 &&
                                                         all(isxdigit, lstrip(c, '#')) ? lstrip(c, '#')[3:end] : c))
        print(io, " calcext:", att, "=\"", lowercase(col), "\"")
    end
    print(io, "><calcext:sparklines>")
    for ((r, c), (rows, cols)) in sparks
        print(io, "<calcext:sparkline calcext:cell-address=\"", _esc(_spark_addr(cellsheet, r, c)), "\" calcext:data-range=\"",
              _esc(_spark_range(datasheet, rows, cols)), "\"/>")
    end
    print(io, "</calcext:sparklines></calcext:sparkline-group>")
    return String(take!(io))
end

# A sparkline's cell (row, col) on its sheet, or nothing.
function _spark_cell(x::AbstractString)
    v = _tag_attr(x, "calcext:cell-address")
    v === nothing && return nothing
    a = _range_areas(v)
    (isempty(a) || a[1][2] === nothing) && return nothing
    return (first(a[1][2]), first(a[1][3]))
end

# Removes the sparklines in `cells` (or, `whole`, the groups holding any), and groups left empty.
function _spark_remove!(st, cells::Set, whole::Bool)
    removed = false
    keep = String[]
    for g in st.list
        sparks = [m.match for m in eachmatch(r"<calcext:sparkline\s[^>]*/>", g)]
        hit = [_spark_cell(s) in cells for s in sparks]
        if !any(hit)
            push!(keep, g)
        elseif !whole && !all(hit)
            for (s, h) in zip(sparks, hit)
                h && (g = replace(g, s => ""; count = 1))
            end
            push!(keep, g); removed = true
        else
            removed = true
        end
    end
    st.list = keep
    return removed
end

"""
    getSparklines(ws::Worksheet) -> Vector{NamedTuple}

A sheet's sparkline groups: `sparklines`, each sparkline's cell and data
(`"F2" => "Data.A2:E2"`, in this package's notation); `type`, `markers`, `high`, `low`, `first`, `last`,
`negative`, `axis`, `emptyCells`, `showHidden`, `lineWeight`, `min`, `max`, `rightToLeft`, `dateRange`
(always `nothing`: LibreOffice keeps none) and `colors` (`seriesColor` …, each `"FFRRGGBB"`), as they
are now.
"""
function getSparklines(ws::Worksheet)
    out = []
    for g in _spark_state(ws).list
        a(k) = _tag_attr(g, "calcext:" * k)
        flag(k) = a(k) == "true"
        type = something(findfirst(==(something(a("type"), "line")), _SPARK_TYPES), :line)
        empty = something(findfirst(==(something(a("display-empty-cells-as"), "zero")), _SPARK_EMPTY), :zero)
        lim(k) = (t = something(a("$k-axis-type"), "individual");
                  t == "custom" ? something(tryparse(Float64, something(a("manual-$k"), "")), :individual) : t == "group" ? :group : :individual)
        lw = a("line-width")
        colors = map(_SPARK_COLORS) do (att, _)
            c = a(att)
            c === nothing ? nothing : SheetCore.parse_odf_color(c)
        end
        sparks = Pair{String,String}[]
        for m in eachmatch(r"<calcext:sparkline\s[^>]*/>", g)
            cell = _spark_cell(m.match)
            d = _tag_attr(m.match, "calcext:data-range")
            push!(sparks, (cell === nothing ? "" : _cellname(cell...)) => (d === nothing ? "" : _spark_short(d)))
        end
        push!(out, (sparklines = sparks, type = type, map(flag, _SPARK_FLAGS)..., emptyCells = empty,
                    lineWeight = lw === nothing ? 0.75 : something(tryparse(Float64, replace(lw, "pt" => "")), 0.75),
                    min = lim("min"), max = lim("max"), dateRange = nothing, colors = colors))
    end
    return [x for x in out]
end

# An ODF range (`Data.A2:Data.E2`) in this package's notation (`Data.A2:E2`); "" when its cells are gone.
function _spark_short(r::AbstractString)
    occursin("#REF!", r) && return ""
    a = _range_areas(r)
    (isempty(a) || a[1][2] === nothing) && return ""
    sheet, rows, cols = a[1]
    s = SheetCore.quoteit(sheet) * "." * _cellname(first(rows), first(cols))
    return length(rows) == 1 && length(cols) == 1 ? s : s * ":" * _cellname(last(rows), last(cols))
end

"""
    deleteSparklines(ws::Worksheet, ref; group = false) -> Bool

Deletes the sparklines in the cells of `ref` (a cell or a range), or with `group = true` every group
with a sparkline there. `false` if there were none.
"""
function deleteSparklines(ws::Worksheet, ref; group::Bool = false)
    xf = get_odsfile(ws)
    _require_writable(xf, "delete sparklines")
    s = ref isa AbstractString ? replace(String(ref), '$' => "") : string(ref)
    rng = occursin(':', s) ? CellRange(s) : (c = CellRef(s); CellRange(c, c))
    r1, c1 = row_number(rng.start), column_number(rng.start); r2, c2 = row_number(rng.stop), column_number(rng.stop)
    st = _spark_state(ws)
    cells = Set((r, c) for r in r1:r2 for c in c1:c2)
    _spark_remove!(st, cells, group) || return false
    st.edited = true
    return true
end

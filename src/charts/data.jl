# A chart's series, groups, data and title (phase 8 step 3). Values are read from the cells now, since
# LibreOffice draws a chart from its cells (F-079); the object's local table is its cache for other
# programs.

# XLSX.jl's group tags for LibreOffice's classes (F-080); a 3-D chart's are XLSX.jl's 3-D tags.
const _TAGS = Dict("chart:bar" => :barChart, "chart:line" => :lineChart, "chart:area" => :areaChart,
    "chart:circle" => :pieChart, "chart:ring" => :doughnutChart, "chart:scatter" => :scatterChart,
    "chart:bubble" => :bubbleChart, "chart:radar" => :radarChart, "chart:filled-radar" => :radarChart,
    "chart:stock" => :stockChart, "chart:surface" => :surfaceChart, "chart:histogram" => :histogram)
const _TAGS3D = Dict(:barChart => :bar3DChart, :lineChart => :line3DChart, :areaChart => :area3DChart,
    :pieChart => :pie3DChart, :surfaceChart => :surface3DChart)

_plot_area(doc::_ChartDoc) = _first(doc.chart, "chart:plot-area")
_series_nodes(doc::_ChartDoc) = (pa = _plot_area(doc); pa === nothing ? XML.Node[] : _children(pa, "chart:series"))

function _series_tag(doc::_ChartDoc, s)
    cclass = something(_get(doc.chart, "chart:class"), "")
    class = something(_get(s, "chart:class"), cclass)
    cclass == "chart:ring" && class == "chart:circle" && (class = cclass)   # a doughnut's series say circle
    tag = get(_TAGS, class, Symbol(replace(class, r"^.*:" => "")))
    pa = _plot_area(doc)
    st = pa === nothing ? Dict{String,String}() : _style(doc, pa)
    if tag === :pieChart && (_get(doc.chart, "loext:sub-pie") == "true" || _get(doc.chart, "loext:sub-bar") == "true")
        tag = :ofPieChart
    elseif get(st, "chart:three-dimensional", "") == "true"
        tag = get(_TAGS3D, tag, tag)
    end
    return tag
end
_series_axids(s) = _get(s, "chart:attached-axis") == "secondary-y" ? [3, 4] : [1, 2]

# The groups of a document's series: one per type and pair of axes, in the order they first appear.
function _groups(doc::_ChartDoc)
    out = ChartGroup[]
    for s in _series_nodes(doc)
        g = ChartGroup(_series_tag(doc, s), _series_axids(s), nothing)
        g in out || push!(out, g)
    end
    return out
end

"""
    getChartGroups(c::Chart) -> Vector{ChartGroup}

The chart's groups: its series of one type on one pair of axes (LibreOffice's column and line chart has
two). ODF has no group element, so `raw` is `nothing`.
"""
getChartGroups(c::AbstractChart) = _groups(_doc(c))

"""
    getChartTypes(c::Chart) -> Vector{Symbol}

The tags of the chart's groups (`:barChart`, `:lineChart`, `:pieChart`, `:doughnutChart`, `:areaChart`,
`:scatterChart`, `:bubbleChart`, `:radarChart`, and LibreOffice's `:stockChart`, `:ofPieChart` and the
3-D tags such as `:bar3DChart`).
"""
getChartTypes(c::AbstractChart) = [g.kind for g in getChartGroups(c)]

"""
    getChartType(c::Chart) -> Symbol
    getChartType(c::ChartEx) -> Symbol

A chart's one group tag ([`getChartTypes`](@ref)), `:combo` when it has more than one, `:unknown`
when it has none. A [`ChartEx`](@ref) is `:histogram`.
"""
function getChartType(c::Chart)
    t = getChartTypes(c)
    return isempty(t) ? :unknown : length(t) == 1 ? t[1] : :combo
end
getChartType(::ChartEx) = :histogram

#
# References and their values
#

# A range list's areas (`Data.B2:Data.B7`, `'My Data'.A1:.C3 Data.F1`) as (sheet, rows, cols) in the
# package's notation, with the text of each; nothing for an area that isn't one (`#REF!`).
function _range_areas(addr::AbstractString)
    out = Tuple{Union{Nothing,String},UnitRange{Int},UnitRange{Int}}[]
    s = String(addr)
    for (a, b) in _areas(s)
        ends = parse_ref(SubString(s, a, b))
        (ends === nothing || isempty(ends) || any(e -> e.err, ends)) && (push!(out, (nothing, 0:-1, 0:-1)); continue)
        e1 = ends[1]; e2 = ends[end]
        sheet = something(e1.sheet, e2.sheet, nothing)
        r1, r2 = e1.row == 0 ? (1, SheetCore.MAX_ROWS) : minmax(e1.row, e2.row == 0 ? e1.row : e2.row)
        c1, c2 = e1.col == 0 ? (1, SheetCore.MAX_COLS) : minmax(e1.col, e2.col == 0 ? e1.col : e2.col)
        push!(out, (sheet, r1:r2, c1:c2))
    end
    return out
end

function _area_text(sheet, rows::UnitRange{Int}, cols::UnitRange{Int})
    q = sheet === nothing ? "" : SheetCore.quoteit(sheet) * "."
    if rows == 1:SheetCore.MAX_ROWS
        return q * SheetCore.encode_column_number(first(cols)) * ":" * SheetCore.encode_column_number(last(cols))
    elseif cols == 1:SheetCore.MAX_COLS
        return q * string(first(rows)) * ":" * string(last(rows))
    end
    a = _cellname(first(rows), first(cols)); b = _cellname(last(rows), last(cols))
    return q * (a == b ? a : a * ":" * b)
end

# An address as a range ([`ChartRange`](@ref)).
function _chart_range(addr::Union{Nothing,AbstractString})
    addr === nothing && return nothing
    areas = _range_areas(addr)
    (isempty(areas) || any(a -> a[1] === nothing, areas)) && return nothing
    texts = [_area_text(a...) for a in areas]
    length(texts) > 1 && return NonContiguousRange(join(texts, ","))
    sheet, rows, cols = areas[1]
    t = texts[1]
    rows == 1:SheetCore.MAX_ROWS && return SheetColumnRange(t)
    cols == 1:SheetCore.MAX_COLS && return SheetRowRange(t)
    return length(rows) == 1 && length(cols) == 1 ? SheetCellRef(t) : SheetCellRange(t)
end

# The values of an address's cells now (row by row), with the errors by position.
function _chart_ref(xf::ODSFile, addr::Union{Nothing,AbstractString})
    addr === nothing && return nothing
    areas = _range_areas(addr)
    data = Any[]
    errors = Dict{Int,String}()
    fmt = nothing
    ok = !isempty(areas) && all(a -> a[1] !== nothing && hassheet(xf, a[1]), areas)
    if ok
        for (sheet, rows, cols) in areas
            ws = xf[sheet]
            # whole columns and rows: up to the sheet's used cells
            if rows == 1:SheetCore.MAX_ROWS || cols == 1:SheetCore.MAX_COLS
                d = OpenDocumentSpreadsheets.get_dimension(ws)
                d === nothing && continue
                rows = first(rows):min(last(rows), OpenDocumentSpreadsheets.row_number(d.stop))
                cols = first(cols):min(last(cols), OpenDocumentSpreadsheets.column_number(d.stop))
            end
            for r in rows, c in cols
                cell = getcell(ws, r, c)
                if cell isa Cell && cell.datatype === :error
                    push!(data, missing)
                    errors[length(data)] = something(cell.error, "")
                elseif cell isa Cell && cell.value !== nothing
                    v = cell.value
                    push!(data, v isa Real && !(v isa Bool) ? Float64(v) : v)
                    fmt === nothing && v isa Real && (fmt = something(try getFormat(ws, r, c).format["numFmt"]["formatCode"] catch; nothing end, "General"))
                else
                    push!(data, missing)
                end
            end
        end
    end
    kind = all(v -> v === missing || !(v isa AbstractString), data) ? :num : :str
    text = something(_chart_range_text(addr), String(addr))
    return ChartRef(kind, text, fmt, length(data), data, errors)
end
_chart_range_text(addr) = (r = _chart_range(addr); r === nothing ? nothing : string(r))

# A series name given as text: `loext:label-string="&quot;Literal name&quot;"` (F-081).
_literal(s::AbstractString) = length(s) >= 2 && startswith(s, '"') && endswith(s, '"') ? replace(s[2:prevind(s, end)], "\"\"" => "\"") : s

function _categories_addr(doc::_ChartDoc)
    pa = _plot_area(doc)
    pa === nothing && return nothing
    for ax in _children(pa, "chart:axis")
        _get(ax, "chart:dimension") == "x" || continue
        cat = _first(ax, "chart:categories")
        cat === nothing || return _get(cat, "table:cell-range-address")
    end
    return nothing
end

# Each series' addresses: (node, tag, categories, values, sizes, label, literal name). XY and bubble
# series take their x (and y) values from their domains; a series without one shares the series
# before's (LibreOffice writes shared x values on the first series only).
function _series_addrs(doc::_ChartDoc)
    out = []
    cats = _categories_addr(doc)
    lastdom = String[]
    for s in _series_nodes(doc)
        tag = _series_tag(doc, s)
        domains = String[something(_get(d, "table:cell-range-address"), "") for d in _children(s, "chart:domain")]
        if tag in (:scatterChart, :bubbleChart)
            isempty(domains) ? (domains = lastdom) : (lastdom = domains)
        end
        vals = _get(s, "chart:values-cell-range-address")
        cat, v, sz = tag === :bubbleChart ? (get(domains, 2, nothing), get(domains, 1, nothing), vals) :   # (F-083)
                     tag === :scatterChart ? (get(domains, 1, cats), vals, nothing) : (cats, vals, nothing)
        push!(out, (node = s, tag = tag, categories = cat, values = v, sizes = sz,
                    label = _get(s, "chart:label-cell-address"), literal = _get(s, "loext:label-string")))
    end
    return out
end

function _series_name(xf::ODSFile, a)
    name_ref = a.label === nothing ? nothing : _chart_ref(xf, a.label)
    name = a.label !== nothing ? (isempty(name_ref.data) || name_ref.data[1] === missing ? nothing : string(name_ref.data[1])) :
           a.literal !== nothing ? _literal(a.literal) : nothing
    return name, name_ref
end

function _series(xf::ODSFile, doc::_ChartDoc)
    out = ChartSeries[]
    refs = Dict{String,ChartRef}()             # each address read once
    ref(addr) = addr === nothing ? nothing : get!(() -> _chart_ref(xf, addr), refs, addr)
    for (i, a) in enumerate(_series_addrs(doc))
        name, name_ref = _series_name(xf, a)
        push!(out, ChartSeries(i - 1, i - 1, a.tag, name, name_ref, ref(a.categories), ref(a.values), ref(a.sizes), a.node))
    end
    return out
end

"""
    getChartSeries(c::AbstractChart) -> Vector{ChartSeries}

The chart's series in order, each with its name, categories (x values on XY and bubble charts), values
and bubble sizes, read from the cells now.
"""
getChartSeries(c::AbstractChart) = _series(c.package, _doc(c))

"""
    getChartRanges(c::AbstractChart) -> Vector{ChartRanges}
    getChartRanges(x::Union{Worksheet,ODSFile}, name) -> Vector{ChartRanges}
    getChartRanges(x::Union{Worksheet,ODSFile}) -> Vector{Tuple{String,Vector{ChartRanges}}}

The ranges of each series: `idx`, `name`, `categories`, `values` and `bubble_sizes`, each a
[`ChartRange`](@ref). Without a name, every chart's: `(chart name, ranges)`.

LibreOffice keeps a chart's references even when their cells are deleted: they never become
`#REF!`.
"""
getChartRanges(c::AbstractChart) =
    ChartRanges[(idx = i - 1, name = _series_name(c.package, a)[1], categories = _chart_range(a.categories),
                 values = _chart_range(a.values), bubble_sizes = _chart_range(a.sizes))
                for (i, a) in enumerate(_series_addrs(_doc(c)))]
getChartRanges(x::Union{Worksheet,ODSFile}, name::AbstractString) = getChartRanges(getChart(x, name))
getChartRanges(x::Union{Worksheet,ODSFile}) = [(c.name, getChartRanges(c)) for c in getCharts(x)]

#
# The data as a table
#

function _unique_label!(labels::Vector{Symbol}, name::AbstractString)
    base = Symbol(isempty(name) ? "column" : name)
    label = base
    n = 1
    while label in labels
        n += 1
        label = Symbol(base, "_", n)
    end
    push!(labels, label)
    return label
end
_pad(v::AbstractVector, n::Int) = length(v) >= n ? collect(Any, v) : vcat(collect(Any, v), fill(missing, n - length(v)))

"""
    getChartData(c::AbstractChart) -> DataTable
    getChartData(x::Union{Worksheet,ODSFile}, name) -> DataTable

The chart's data as a `DataTable` (for `DataFrame(...)` or any Tables.jl sink), read from its cells now,
as LibreOffice draws it: a `categories` column when every series shares the categories (else a
`<series>_x` column before each series), one column per series (named by the series, else `Series<i>`),
and `<series>_size` after a bubble series. Shorter columns are padded with `missing`.
"""
function getChartData(c::AbstractChart)
    series = getChartSeries(c)
    isempty(series) && return DataTable(Any[], Symbol[])
    catrefs = [s.categories for s in series]
    shared = first(catrefs) !== nothing && all(r -> r !== nothing && r.ref == first(catrefs).ref, catrefs)
    n = 0
    for s in series, r in (s.categories, s.values, s.bubble_sizes)
        r === nothing || (n = max(n, length(r.data)))
    end
    columns = Any[]
    labels = Symbol[]
    if shared
        _unique_label!(labels, "categories"); push!(columns, _pad(first(catrefs).data, n))
    end
    for (i, s) in enumerate(series)
        nm = something(s.name, "Series$i")
        if !shared && s.categories !== nothing
            _unique_label!(labels, nm * "_x"); push!(columns, _pad(s.categories.data, n))
        end
        _unique_label!(labels, nm)
        push!(columns, s.values === nothing ? Any[missing for _ in 1:n] : _pad(s.values.data, n))
        if s.bubble_sizes !== nothing
            _unique_label!(labels, nm * "_size"); push!(columns, _pad(s.bubble_sizes.data, n))
        end
    end
    return DataTable(columns, labels)
end
getChartData(x::Union{Worksheet,ODSFile}, name::AbstractString) = getChartData(getChart(x, name))

"""
    iserror(r::ChartRef) -> Vector{Bool}
    iserror(r::ChartRef, i) -> Bool
    geterror(r::ChartRef) -> Vector{String}
    geterror(r::ChartRef, i) -> String

Whether each value of a chart reference is an error, and its error text (`""` where none). Every error
kind is reported, since the values come from the cells.
"""
iserror(r::ChartRef) = Bool[haskey(r.errors, i) for i in 1:length(r.data)]
iserror(r::ChartRef, i::Integer) = haskey(r.errors, Int(i))
geterror(r::ChartRef) = String[get(r.errors, i, "") for i in 1:length(r.data)]
geterror(r::ChartRef, i::Integer) = get(r.errors, Int(i), "")

#
# The title
#

# The text of an element's paragraphs: spans, spaces (`text:s`), tabs and line breaks; paragraphs
# joined by "\n".
function _text(n)
    io = IOBuffer()
    walk(x) = for c in XML.children(x)
        t = XML.nodetype(c)
        if t === XML.Text
            print(io, XML.unescape(XML.value(c)))
        elseif t === XML.Element
            tg = XML.tag(c)
            if tg == "text:s"
                print(io, " "^parse(Int, something(_get(c, "text:c"), "1")))
            elseif tg == "text:tab"
                print(io, '\t')
            elseif tg == "text:line-break"
                print(io, '\n')
            else
                walk(c)
            end
        end
    end
    paras = _children(n, "text:p")
    for (i, p) in enumerate(paras)
        i > 1 && print(io, '\n')
        walk(p)
    end
    return String(take!(io))
end

"""
    getChartTitle(c::AbstractChart) -> Union{Nothing,String}

The chart's title as text (paragraphs joined by `"\\n"`), or `nothing` when it has none. LibreOffice has
no automatic titles and no titles bound to cells.
"""
function getChartTitle(c::AbstractChart)
    t = get(_children(_doc(c).chart, "chart:title"), 1, nothing)
    return t === nothing ? nothing : _text(t)
end

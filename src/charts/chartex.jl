# `addChartEx` and chart sheets (phase 8 step 7, D-085, D-086). Of XLSX.jl's seven chartex kinds,
# LibreOffice has the histogram (F-080): the others are errors. A chart sheet is LibreOffice's import's
# form of one: an ordinary sheet holding one chart anchored to the page (F-081).

const CX_KINDS = (:waterfall, :funnel, :treemap, :sunburst, :histogram, :pareto, :boxWhisker)

# LibreOffice's import's chart sheet: the frame's size (experiment 039 part B).
const _CHARTSHEET_CM = (25.821, 16.856)

"""
    ChartExDimension, ChartExData, ChartExBinning

A histogram's data and its bins. LibreOffice's histogram has one
dimension, its values (`kind` `:num`, `type` `:val`, `formula` the ODF range, `range` its
[`ChartRange`](@ref)); its binning is a bin width or a bin count (`intervalClosed`, `underflow` and
`overflow` are always `nothing`: LibreOffice has none).
"""
struct ChartExDimension
    kind::Symbol
    type::Symbol
    formula::Union{Nothing,String}
    range::Any
end
struct ChartExData
    id::Int
    dimensions::Vector{ChartExDimension}
end
struct ChartExBinning
    intervalClosed::Union{Nothing,Symbol}
    underflow::Union{Nothing,Float64,Symbol}
    overflow::Union{Nothing,Float64,Symbol}
    binSize::Union{Nothing,Float64,Symbol}
    binCount::Union{Nothing,Int,Symbol}
end
@doc (@doc ChartExDimension) ChartExData
@doc (@doc ChartExDimension) ChartExBinning

function _check_cx_kind(kind::Symbol)
    kind in CX_KINDS || throw(ODSError("Unknown kind `:$kind` for addChartEx: the kinds are " * join(string.(":", CX_KINDS), ", ") * "."))
    kind === :histogram ||
        throw(ODSError("LibreOffice has no $kind chart: addChartEx makes only histograms (`:histogram`)."))
end

# A histogram, as LibreOffice's own (F-080): a bar chart of class `loext:histogram`, its bins chosen by
# LibreOffice (`frequency-type` 0), no gap between its columns, and (added by `addSeries`) one series of
# class `chart:histogram`. `addChart(…, :histogram)` makes it (D-092).
function _make_histogram!(c::Chart)
    xf = c.package
    o = xf.chartobjs[c.name]
    o.text = replace(o.text, r"(<chart:chart\b[^>]*?) chart:class=\"chart:bar\"" => s"\1 chart:class=\"chart:bar\" loext:class=\"loext:histogram\""; count = 1)
    _set_style_attrs!(o, _plot_style(o), ["chart:treat-empty-cells" => "use-zero", "loext:frequency-type" => "0",
                                          "loext:bin-width" => "2", "loext:bin-count" => "10"])
    _axis_set!(c, 2, ["chart:gap-width" => "0"])
    return ChartEx(xf, c.path, c.name, nothing, c.sheet, c.from, c.to)
end

"""
    addSeries(c::ChartEx, values; name = nothing, name_ref = nothing) -> ChartEx

Adds a histogram's series: the cells whose values it counts (`"Data.B2:B201"`, `"B2:B201"` on the chart's
sheet, or a range object), with its name as text (`name`) or from a cell (`name_ref`). A histogram has
one series, and no categories: LibreOffice draws its bins from its values.
"""
function addSeries(c::ChartEx, values; name = nothing, name_ref = nothing, kw...)
    haskey(kw, :categories) && throw(ODSError("A histogram takes no `categories`: LibreOffice draws its bins from its values."))
    isempty(kw) || throw(ODSError("A histogram's series takes `name` or `name_ref`; `$(first(keys(kw)))` is for other charts."))
    name !== nothing && name_ref !== nothing && throw(ODSError("Give the series' `name` or its `name_ref`, not both."))
    o = _editable(c)
    occursin("<chart:series", o.text) && throw(ODSError("A histogram has one series: make another histogram for more data."))
    vals = _odf_range(values, c.sheet)
    label = name_ref === nothing ? nothing : _odf_range(name_ref, c.sheet)
    st = _add_style!(o, """<style:chart-properties chart:link-data-style-to-source="true"/><style:graphic-properties draw:stroke="none" draw:fill-color="$(_PALETTE[1])"/>""" * _TEXT10;
                     datastyle = true)
    io = IOBuffer()
    print(io, "<chart:series chart:style-name=\"$st\" chart:values-cell-range-address=\"", _esc(vals), "\"")
    label === nothing || print(io, " chart:label-cell-address=\"", _esc(label), "\"")
    name === nothing || print(io, " loext:label-string=\"", _esc("\"" * replace(String(name), "\"" => "\"\"") * "\""), "\"")
    print(io, " chart:class=\"chart:histogram\"></chart:series>")
    _insert_before!(o, "<chart:wall", String(take!(io)))
    return c
end

"""
    addChartEx(ws::Worksheet, kind::Symbol, values; anchor, categories = nothing, name = nothing,
               name_ref = nothing, title = nothing) -> ChartEx
    addChartEx(xf::ODSFile, kind::Symbol, values; sheetname = "", …) -> ChartEx

A histogram of `values` (`kind = :histogram`), on a sheet or on a new chart sheet: the same as
[`addChart`](@ref)`(ws, :histogram; anchor, title)` followed by `addSeries(h, values; name, name_ref)`,
the form these docs use. The other kinds, `:waterfall`, `:funnel`, `:treemap`, `:sunburst`, `:pareto`
and `:boxWhisker`, are charts LibreOffice doesn't have, so they are errors. A histogram takes no
`categories`, and LibreOffice draws its bins from its values (set them with `setSeriesBinning`,
under [`setSeriesName`](@ref)).

A chart sheet is LibreOffice's form of one: an ordinary sheet, named `sheetname` (by default
`Chart1`, `Chart2`, …), holding the chart anchored to the page. Its references name their sheet
(`"Data!B2:B7"`), since the chart sheet's cells hold nothing.
"""
function addChartEx(ws::Worksheet, kind::Symbol, values; anchor::Union{AbstractString,CellRange}, categories = nothing,
                    name = nothing, name_ref = nothing, title = nothing)
    _check_cx_kind(kind)
    categories === nothing || throw(ODSError("A histogram takes no `categories`: LibreOffice draws its bins from its values."))
    name !== nothing && name_ref !== nothing && throw(ODSError("Give the series' `name` or its `name_ref`, not both."))
    _odf_range(values, ws.name)                          # a bad reference changes nothing
    name_ref === nothing || _odf_range(name_ref, ws.name)
    return addSeries(addChart(ws, :histogram; anchor, title), values; name, name_ref)
end
function addChartEx(xf::ODSFile, kind::Symbol, values; sheetname::AbstractString = "", categories = nothing,
                    name = nothing, name_ref = nothing, title = nothing)
    _check_cx_kind(kind)
    categories === nothing || throw(ODSError("A histogram takes no `categories`: LibreOffice draws its bins from its values."))
    name !== nothing && name_ref !== nothing && throw(ODSError("Give the series' `name` or its `name_ref`, not both."))
    _require_qualified(values, name_ref)
    _odf_range(values, ""); name_ref === nothing || _odf_range(name_ref, "")   # a bad reference changes nothing
    return addSeries(_chartsheet_chart(xf, :histogram, sheetname; title), values; name, name_ref)
end

"""
    addChart(xf::ODSFile, kind::Symbol; sheetname = "", title = nothing, xtitle = nothing, ytitle = nothing,
             kw...) -> Chart

A chart on a new chart sheet (a [`ChartEx`](@ref) for `:histogram`): LibreOffice's form of one, an ordinary sheet
named `sheetname` (by default `Chart1`, `Chart2`, …) holding the chart anchored to the page, after the
other sheets. Add its series with [`addSeries`](@ref), naming their sheet (`"Data!B2:B7"`). The other
keywords are [`addChart`](@ref)'s, but `data` (whose cells would be the chart sheet's).
"""
addChart(xf::ODSFile, kind::Symbol; sheetname::AbstractString = "", kw...) = _chartsheet_chart(xf, kind, sheetname; kw...)

function _chartsheet_chart(xf::ODSFile, kind::Symbol, sheetname::AbstractString; kw...)
    haskey(kw, :anchor) && throw(ODSError("A chart sheet's chart fills its page: it takes no `anchor`."))
    haskey(kw, :data) && throw(ODSError("A chart sheet holds no cells: add its series with `addSeries`, naming their sheet."))
    _require_writable(xf, "add a chart sheet")
    name = isempty(sheetname) ? _next_chartsheet_name(xf) : String(sheetname)
    hassheet(xf, name) && throw(ODSError("There is already a sheet `$name`."))
    ws = addsheet!(xf, name)
    w, h = _CHARTSHEET_CM
    # made as a cell chart over the page's cells, then moved to the page
    c = addChart(ws, kind; anchor = "A1:A1", kw...)
    fe = ws.frames[(1, 1)]
    img = pop!(fe.added)
    isempty(fe.added) && isempty(fe.removed) && isempty(fe.moved) && isempty(fe.objremoved) && delete!(ws.frames, (1, 1))
    img.width, img.height = w, h
    o = xf.chartobjs[c.name]
    o.text = replace(o.text, r"<chart:chart svg:width=\"[^\"]*\" svg:height=\"[^\"]*\"" => "<chart:chart svg:width=\"$(_fmt_cm(w))\" svg:height=\"$(_fmt_cm(h))\""; count = 1)
    ws.pagecharts === nothing && (ws.pagecharts = ImageData[])
    push!(ws.pagecharts, img)
    er, ec = _page_end_cell(ws, w, h)
    return typeof(c)(xf, c.path, c.name, nothing, ws.name, "A1", _cellname(er, ec))
end

function _next_chartsheet_name(xf)
    k = 1
    while hassheet(xf, "Chart$k")
        k += 1
    end
    return "Chart$k"
end

# A chart sheet's references name their sheet: its own cells hold nothing.
function _require_qualified(refs...)
    for r in refs
        r === nothing && continue
        s = r isa AbstractString ? String(r) : string(r)
        (occursin('!', s) || occursin(r"^'?[^.']+'?\.", s) || occursin("'.", s)) ||
            throw(ODSError("A chart sheet holds no cells: name the sheet of `$s` (\"Data!B2:B7\")."))
    end
end

#
# The histogram's series, data and bins (XLSX.jl's ChartEx functions)
#

function _cx_series(c::ChartEx, i::Integer)
    doc = _doc(c)
    ss = _series_nodes(doc)
    1 <= i <= length(ss) || throw(ODSError("The chart has $(length(ss)) series; there is no series $i."))
    return doc, ss[i]
end
_no_pareto(pareto::Bool) = pareto && throw(ODSError("LibreOffice has no pareto charts: no series has a Pareto line (D-086)."))

"""
    getChartSeriesCount(c::ChartEx) -> Int
    getSeriesLayout(c::ChartEx, i) -> Symbol
    getSeriesName(c::ChartEx, i) / getSeriesNameRange(c::ChartEx, i)
    getChartDataBlocks(c::ChartEx) / getSeriesData(c::ChartEx, i)
    getSeriesHidden(c::ChartEx, i) / getSeriesAxisIds(c::ChartEx, i) / getChartAxisIds(c::ChartEx)
    getLabelPosition(c::ChartEx, i) / getSeriesBinning(c::ChartEx, i)

A histogram's series: its layout is `:clusteredColumn`, its data one dimension of values (data blocks numbered from 0, one per series), its axes
`[0, 1]`; it is never hidden. Its binning is LibreOffice's: a width or a count, or `:auto` for both
when LibreOffice chooses. `pareto = true` is an error: LibreOffice has no pareto charts.
"""
getChartSeriesCount(c::ChartEx) = length(_series_nodes(_doc(c)))
getSeriesLayout(c::ChartEx, i::Integer; pareto::Bool = false) = (_no_pareto(pareto); _cx_series(c, i); :clusteredColumn)
getSeriesName(c::ChartEx, i::Integer; pareto::Bool = false) = (_no_pareto(pareto); getChartSeries(c)[i].name)
getSeriesNameRange(c::ChartEx, i::Integer; pareto::Bool = false) =
    (_no_pareto(pareto); _cx_series(c, i); a = _series_addrs(_doc(c))[i]; a.label === nothing ? nothing : _chart_range(a.label))
function getChartDataBlocks(c::ChartEx)
    return [ChartExData(k - 1, [ChartExDimension(:num, :val, s.values.ref, getChartRanges(c)[k].values)])
            for (k, s) in enumerate(getChartSeries(c))]
end
getSeriesData(c::ChartEx, i::Integer; pareto::Bool = false) = (_no_pareto(pareto); _cx_series(c, i); getChartDataBlocks(c)[i])
getSeriesHidden(c::ChartEx, i::Integer; pareto::Bool = false) = (_no_pareto(pareto); _cx_series(c, i); nothing)
getSeriesAxisIds(c::ChartEx, i::Integer; pareto::Bool = false) = (_no_pareto(pareto); _cx_series(c, i); [0, 1])
getChartAxisIds(c::ChartEx) = [0, 1]
getLabelPosition(c::ChartEx, i::Integer; pareto::Bool = false) =
    (_no_pareto(pareto); (doc, s) = _cx_series(c, i); p = get(_style(doc, s), "chart:label-position", nothing);
     p === nothing ? nothing : get(_LABEL_POS, p, nothing))
function getSeriesBinning(c::ChartEx, i::Integer)
    doc, _ = _cx_series(c, i)
    st = _style(doc, _plot_area(doc))
    ft = get(st, "loext:frequency-type", "0")
    w = _num(get(st, "loext:bin-width", nothing)); n = _maybe(x -> tryparse(Int, x), get(st, "loext:bin-count", nothing))
    return ft == "1" ? ChartExBinning(nothing, nothing, nothing, w, nothing) :
           ft == "2" ? ChartExBinning(nothing, nothing, nothing, nothing, n) :
                       ChartExBinning(nothing, nothing, nothing, :auto, :auto)
end

"""
    setSeriesName(c::ChartEx, i, name) -> ChartEx
    setSeriesBinning(c::ChartEx, i; binSize = nothing, binCount = nothing, intervalClosed = nothing,
                     underflow = nothing, overflow = nothing) -> ChartEx

A histogram's series name (text), and its bins: a width (`binSize`) or a count (`binCount`), or
`:auto` (LibreOffice chooses); `:inherit` is `:auto`. LibreOffice's bins have no closed side, underflow
or overflow bin: those are errors. The other setters for a histogram's handle (`setSeriesSubtotals`,
`setSeriesAggregation`, `setSeriesQuartileMethod`, `setSeriesParentLabelLayout`, `setSeriesLayoutFlag`)
are for chart kinds LibreOffice doesn't have: errors.
"""
function setSeriesName(c::ChartEx, i::Integer, name::AbstractString; pareto::Bool = false)
    _no_pareto(pareto)
    o = _editable(c)
    m = _series_start(o, i)
    _set_tag_attrs!(o, m, ["chart:label-cell-address" => nothing,
                           "loext:label-string" => "\"" * replace(String(name), "\"" => "\"\"") * "\""])
    return c
end
function setSeriesBinning(c::ChartEx, i::Integer; intervalClosed = nothing, underflow = nothing, overflow = nothing,
                          binSize = nothing, binCount = nothing)
    for (k, v) in (("intervalClosed", intervalClosed), ("underflow", underflow), ("overflow", overflow))
        v === nothing || v === :inherit ||
            throw(ODSError("LibreOffice's histogram bins have no `$k` (D-086): only a width or a count."))
    end
    binSize === nothing || binCount === nothing || throw(ODSError("`binSize` and `binCount` are alternatives; set only one."))
    o = _editable(c)
    _series_start(o, i)
    plot = _plot_style(o)
    auto(v) = v === :auto || v === :inherit
    if binSize !== nothing
        if auto(binSize)
            _set_style_attrs!(o, plot, ["loext:frequency-type" => "0"])
        else
            binSize isa Real && binSize > 0 || throw(ODSError("`binSize` is a positive number, or :auto."))
            _set_style_attrs!(o, plot, ["loext:frequency-type" => "1", "loext:bin-width" => _num_text(binSize)])
        end
    elseif binCount !== nothing
        if auto(binCount)
            _set_style_attrs!(o, plot, ["loext:frequency-type" => "0"])
        else
            binCount isa Integer && binCount > 0 || throw(ODSError("`binCount` is a positive integer, or :auto."))
            _set_style_attrs!(o, plot, ["loext:frequency-type" => "2", "loext:bin-count" => string(binCount)])
        end
    end
    return c
end
makeCombo(::ChartEx) = throw(ODSError("A histogram has one series and can't be a combo chart."))

for (f, kind) in ((:setSeriesSubtotals, "waterfall"), (:setSeriesQuartileMethod, "box-and-whisker"),
                  (:setSeriesParentLabelLayout, "treemap"))
    @eval $f(::ChartEx, ::Integer, ::Any) = throw(ODSError(string("LibreOffice has no ", $kind, " chart (D-086).")))
end
setSeriesAggregation(::ChartEx, ::Integer, ::Bool) =
    throw(ODSError("LibreOffice's histogram has no category aggregation (D-086): it bins its values."))
setSeriesLayoutFlag(::ChartEx, ::Integer, flag::Symbol, value) =
    throw(ODSError("LibreOffice's histogram has no layout flag `:$flag` (D-086)."))


"""
    getSeriesSubtotals(c::ChartEx, i) / getSeriesAggregation(c::ChartEx, i) / getSeriesQuartileMethod(c::ChartEx, i)
    getSeriesParentLabelLayout(c::ChartEx, i) / getSeriesLayoutFlag(c::ChartEx, i, flag)

Getters for chart kinds LibreOffice doesn't have (waterfall, box and whisker, treemap): a histogram
has none of these settings, so `nothing`.
"""
getSeriesSubtotals(c::ChartEx, i::Integer) = (_cx_series(c, i); nothing)
getSeriesAggregation(c::ChartEx, i::Integer) = (_cx_series(c, i); nothing)
getSeriesQuartileMethod(c::ChartEx, i::Integer) = (_cx_series(c, i); nothing)
getSeriesParentLabelLayout(c::ChartEx, i::Integer) = (_cx_series(c, i); nothing)
getSeriesLayoutFlag(c::ChartEx, i::Integer, flag::Symbol) = (_cx_series(c, i); nothing)

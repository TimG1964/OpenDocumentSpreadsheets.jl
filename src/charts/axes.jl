# A chart's axes (phase 8 step 4): XLSX.jl's axis getters on LibreOffice's `chart:axis` elements and
# their styles (F-082). Axes are numbered as XLSX.jl's selectors name them: 1 primary x, 2 primary y,
# 3 secondary x, 4 secondary y, 5 z.

const _AXIDS = Dict("primary-x" => 1, "primary-y" => 2, "secondary-x" => 3, "secondary-y" => 4, "primary-z" => 5)

function _axis_id(n)
    nm = _get(n, "chart:name")
    nm !== nothing && haskey(_AXIDS, nm) && return _AXIDS[nm]
    d = _get(n, "chart:dimension")
    return d == "x" ? 1 : d == "y" ? 2 : 5
end

function _axis_node(doc::_ChartDoc, axid::Int)
    pa = _plot_area(doc)
    pa === nothing && return nothing
    for ax in _children(pa, "chart:axis")
        _axis_id(ax) == axid && return ax
    end
    return nothing
end

function _axes(doc::_ChartDoc)
    pa = _plot_area(doc)
    pa === nothing && return ChartAxis[]
    class = something(_get(doc.chart, "chart:class"), "")
    xy = class in ("chart:scatter", "chart:bubble")
    swapped = get(_style(doc, pa), "chart:vertical", "false") == "true"        # a bar chart's: categories on the left
    out = ChartAxis[]
    for ax in _children(pa, "chart:axis")
        id = _axis_id(ax)
        d = _style(doc, ax)
        x = id in (1, 3)
        kind = id == 5 ? :serAx : !x || xy ? :valAx : _get(ax, "chartooo:axis-type") == "date" ? :dateAx : :catAx
        pos = id == 5 ? nothing : x ? (swapped ? (id == 1 ? :l : :r) : (id == 1 ? :b : :t)) : (swapped ? (id == 2 ? :b : :t) : (id == 2 ? :l : :r))
        cross = id == 1 ? 2 : id == 2 ? 1 : id == 3 ? 4 : id == 4 ? 3 : nothing
        push!(out, ChartAxis(kind, id, pos, cross, get(d, "chart:visible", "true") == "false", ax))
    end
    return out
end

const AxisRef = Union{ChartAxis,Symbol,Integer}

"""
    getChartAxes(c::AbstractChart) -> Vector{ChartAxis}
    getChartAxes(c::AbstractChart, role) -> Vector{ChartAxis}

The chart's axes (hidden ones too), or those of a role: `:category`, `:value`, `:date`, `:series`.
"""
getChartAxes(c::AbstractChart) = _axes(_doc(c))
function getChartAxes(c::AbstractChart, role::Symbol)
    k = role === :category ? :catAx : role === :value ? :valAx : role === :date ? :dateAx : role === :series ? :serAx :
        throw(ODSError("Unknown axis role `:$role`: use :category, :value, :date or :series."))
    return [a for a in getChartAxes(c) if a.kind === k]
end

"""
    getChartAxis(c::AbstractChart, which::Symbol) -> ChartAxis
    getChartAxis(c::AbstractChart, axid::Integer) -> ChartAxis

One axis: `:x`, `:y`, `:x2`, `:y2` or `:z` (as drawn: a bar chart's `:x` is its value axis, along the
bottom), a role that names one axis, or its number.
"""
function getChartAxis(c::AbstractChart, which::Symbol)
    axes = getChartAxes(c)
    if which in (:x, :y, :x2, :y2, :z)
        which === :z && return _only_axis(filter(a -> a.axid == 5, axes), which)
        horiz = which in (:x, :x2)
        primary = which in (:x, :y)
        return _only_axis(filter(a -> a.axid != 5 && (a.pos in (:b, :t)) == horiz && (a.axid <= 2) == primary, axes), which)
    end
    return _only_axis(getChartAxes(c, which), which)
end
getChartAxis(c::AbstractChart, axid::Integer) = _only_axis(filter(a -> a.axid == axid, getChartAxes(c)), axid)
getChartAxis(::AbstractChart, a::ChartAxis) = a
function _only_axis(v, which)
    isempty(v) && throw(ODSError("The chart has no axis `$which`."))
    length(v) > 1 && throw(ODSError("The chart has $(length(v)) axes `$which`; name one with :x, :y, :x2, :y2, :z or its number."))
    return v[1]
end

_axis(c::AbstractChart, ax::AxisRef) = (doc = _doc(c); a = getChartAxis(c, ax); (doc, _axis_node(doc, a.axid), a))
_axis_style(c::AbstractChart, ax::AxisRef) = ((doc, n, _) = _axis(c, ax); _style(doc, n))

"""
    getAxisShapeProps(c, ax) / getAxisTextProps(c, ax)

An axis's line, and its labels' text properties.
"""
getAxisShapeProps(c::AbstractChart, ax::AxisRef) = _shape(_axis_style(c, ax))
getAxisTextProps(c::AbstractChart, ax::AxisRef) = ((doc, n, _) = _axis(c, ax); _txpr(doc, n))

_axis_title_node(n) = get(_children(n, "chart:title"), 1, nothing)

"""
    getAxisTitle(c, ax) -> Union{Nothing,String}
    getAxisTitleText(c, ax) -> Union{Nothing,DrawingText}
    getAxisTitleTextProps(c, ax) -> Union{Nothing,DrawingText}
    getAxisTitleRef(c, ax) / getAxisTitleRange(c, ax) -> Nothing

An axis's title: its text, as rich text, and its text properties. LibreOffice's titles can't follow a
cell: the reference is always `nothing`.
"""
getAxisTitle(c::AbstractChart, ax::AxisRef) = ((_, n, _) = _axis(c, ax); _maybe(_text, _axis_title_node(n)))
getAxisTitleText(c::AbstractChart, ax::AxisRef) = ((doc, n, _) = _axis(c, ax); _drawing_text(doc, _axis_title_node(n)))
getAxisTitleTextProps(c::AbstractChart, ax::AxisRef) = ((doc, n, _) = _axis(c, ax); _txpr(doc, _axis_title_node(n)))
getAxisTitleRef(c::AbstractChart, ax::AxisRef) = (getChartAxis(c, ax); nothing)
getAxisTitleRange(c::AbstractChart, ax::AxisRef) = (getChartAxis(c, ax); nothing)

"""
    getAxisGridlines(c, ax; minor = false) -> Union{Nothing,DrawingShapeProps}

An axis's major (or minor) gridlines' line, or `nothing` when it has none.
"""
function getAxisGridlines(c::AbstractChart, ax::AxisRef; minor::Bool = false)
    doc, n, _ = _axis(c, ax)
    for g in _children(n, "chart:grid")
        if something(_get(g, "chart:class"), "major") == (minor ? "minor" : "major")
            return something(_shape(_style(doc, g)), DrawingShapeProps(nothing, nothing, nothing, nothing, nothing))
        end
    end
    return nothing
end

"""
    getAxisPartner(c, ax) -> Union{Nothing,ChartAxis}

The axis an axis crosses.
"""
getAxisPartner(c::AbstractChart, ax::AxisRef) = (a = getChartAxis(c, ax); axes = getChartAxes(c); k = findfirst(b -> b.axid == a.crossax, axes); k === nothing ? nothing : axes[k])

"""
    getAxisNumberFormatCode(c, ax) -> Union{Nothing,String}
    getAxisNumberFormatLinked(c, ax) -> Union{Nothing,Bool}

An axis's number format, as a format code, and whether it follows its source cells'.
"""
function getAxisNumberFormatCode(c::AbstractChart, ax::AxisRef)
    doc, n, _ = _axis(c, ax)
    ds = get(_style(doc, n), "style:data-style-name", nothing)
    ds === nothing && return nothing
    m = match(Regex("<number:[a-z-]+-style style:name=\"" * ds * "\".*?</number:[a-z-]+-style>", "s"), doc.text)
    m === nothing && return nothing
    return first(_style_code(m.match))
end
getAxisNumberFormatLinked(c::AbstractChart, ax::AxisRef) = _bool(get(_axis_style(c, ax), "chart:link-data-style-to-source", nothing))

function _ticks(d::Dict{String,String}, which::String)
    i = get(d, "chart:tick-marks-$which-inner", nothing); o = get(d, "chart:tick-marks-$which-outer", nothing)
    # absent: LibreOffice's defaults, major ticks outside, no minor ticks
    i === nothing && o === nothing && return which == "major" ? :out : :none
    i = i == "true"; o = o == "true"
    return i && o ? :cross : i ? :in : o ? :out : :none
end

"""
    getAxisMajorTickMark(c, ax) / getAxisMinorTickMark(c, ax) -> Union{Nothing,Symbol}

`:cross`, `:in`, `:out` or `:none`.
"""
getAxisMajorTickMark(c::AbstractChart, ax::AxisRef) = _ticks(_axis_style(c, ax), "major")
getAxisMinorTickMark(c::AbstractChart, ax::AxisRef) = _ticks(_axis_style(c, ax), "minor")

"""
    getAxisTickLabelPos(c, ax) -> Union{Nothing,Symbol}

`:nextTo`, `:low` (outside start), `:high` (outside end) or `:none` (no labels).
"""
function getAxisTickLabelPos(c::AbstractChart, ax::AxisRef)
    d = _axis_style(c, ax)
    get(d, "chart:display-label", "true") == "false" && return :none
    p = get(d, "chart:axis-label-position", nothing)
    return p === nothing ? :nextTo : p == "outside-start" ? :low : p == "outside-end" ? :high : :nextTo
end

"""
    getAxisOrientation(c, ax) / getAxisMin(c, ax) / getAxisMax(c, ax) / getAxisLogBase(c, ax)

`:minMax` or `:maxMin` (reversed); the fixed minimum and maximum (`nothing`: automatic); 10 for a
logarithmic axis (LibreOffice's are base 10), else `nothing`.
"""
getAxisOrientation(c::AbstractChart, ax::AxisRef) = get(_axis_style(c, ax), "chart:reverse-direction", "false") == "true" ? :maxMin : :minMax
getAxisMin(c::AbstractChart, ax::AxisRef) = _num(get(_axis_style(c, ax), "chart:minimum", nothing))
getAxisMax(c::AbstractChart, ax::AxisRef) = _num(get(_axis_style(c, ax), "chart:maximum", nothing))
getAxisLogBase(c::AbstractChart, ax::AxisRef) = get(_axis_style(c, ax), "chart:logarithmic", "false") == "true" ? 10.0 : nothing

"""
    getAxisCrosses(c, ax) -> Union{Nothing,Symbol}
    getAxisCrossesAt(c, ax) -> Union{Nothing,Float64}

Where an axis crosses the axis it meets (`chart:axis-position`): `:min` (its start), `:max` (its end),
`:autoZero` (at 0), or at a value.
"""
function getAxisCrosses(c::AbstractChart, ax::AxisRef)
    p = get(_axis_style(c, ax), "chart:axis-position", nothing)
    return p === nothing ? nothing : p == "start" ? :min : p == "end" ? :max : p == "0" ? :autoZero : nothing
end
function getAxisCrossesAt(c::AbstractChart, ax::AxisRef)
    p = get(_axis_style(c, ax), "chart:axis-position", nothing)
    (p === nothing || p in ("start", "end", "0")) && return nothing
    return _num(p)
end

"""
    getAxisMajorUnit(c, ax) / getAxisMinorUnit(c, ax) -> Union{Nothing,Float64}

The interval between major ticks, and between minor ones (LibreOffice stores the number of minor
intervals in a major one).
"""
getAxisMajorUnit(c::AbstractChart, ax::AxisRef) = _num(get(_axis_style(c, ax), "chart:interval-major", nothing))
function getAxisMinorUnit(c::AbstractChart, ax::AxisRef)
    d = _axis_style(c, ax)
    m = _num(get(d, "chart:interval-major", nothing)); k = _num(get(d, "chart:interval-minor-divisor", nothing))
    return m === nothing || k === nothing || k == 0 ? nothing : m / k
end

"""
    getAxisLabelAlign(c, ax) / getAxisLabelOffset(c, ax) / getAxisMultiLevelLabels(c, ax) / getAxisCrossBetween(c, ax)

`nothing`: ODF has no label alignment, offset, multi-level switch or crossing rule for an axis.
"""
getAxisLabelAlign(c::AbstractChart, ax::AxisRef) = (getChartAxis(c, ax); nothing)
getAxisLabelOffset(c::AbstractChart, ax::AxisRef) = (getChartAxis(c, ax); nothing)
getAxisMultiLevelLabels(c::AbstractChart, ax::AxisRef) = (getChartAxis(c, ax); nothing)
getAxisCrossBetween(c::AbstractChart, ax::AxisRef) = (getChartAxis(c, ax); nothing)

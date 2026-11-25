# Reading a chart's formatting (phase 8 step 4): XLSX.jl's getters, filled from the chart's ODF
# styles (F-082). LibreOffice keeps every part's formatting in its own automatic style; its cascade is
# a point's style, then its series'.

#
# Styles to values
#

# A length (`0.3cm`, `2mm`, `1pt`, `0.1in`) in points.
function _pt(v::Union{Nothing,AbstractString})
    v === nothing && return nothing
    m = match(r"^(-?[0-9.]+)(cm|mm|in|pt|pc|px)?$", strip(v))
    m === nothing && return nothing
    x = parse(Float64, m.captures[1])
    u = something(m.captures[2], "pt")
    f = u == "cm" ? 72 / 2.54 : u == "mm" ? 72 / 25.4 : u == "in" ? 72.0 : u == "pc" ? 12.0 : u == "px" ? 0.75 : 1.0
    return round(x * f; digits = 2)
end
_hex(v::AbstractString) = uppercase(lstrip(v, '#'))
_bool(v) = v === nothing ? nothing : v == "true"
_num(v) = v === nothing ? nothing : tryparse(Float64, v)

# A colour attribute, with its theme slot when it follows the document's theme.
function _color(d::Dict{String,String}, attr::String, theme::String; alpha::Float64 = 1.0)
    v = get(d, attr, nothing)
    v === nothing && return nothing
    t = get(d, theme, nothing)
    rgb = _hex(v)
    return t === nothing ? DrawingColor(:srgb, rgb, Pair{Symbol,Int}[], rgb, alpha) :
                           DrawingColor(:scheme, t, Pair{Symbol,Int}[], rgb, alpha)
end

_opacity(d) = (t = get(d, "draw:opacity", nothing); t === nothing ? 1.0 : something(tryparse(Float64, rstrip(t, '%')), 100.0) / 100)

function _fill(d::Dict{String,String})
    f = get(d, "draw:fill", nothing)
    c = _color(d, "draw:fill-color", "@loext:fill-complex-color"; alpha = _opacity(d))
    f === nothing && c === nothing && return nothing
    f == "none" && return DrawingFill(:none)
    f == "gradient" && return DrawingFill(:gradient; preset = get(d, "draw:fill-gradient-name", nothing))
    f == "hatch" && return DrawingFill(:pattern; fgcolor = c, preset = get(d, "draw:fill-hatch-name", nothing))
    f == "bitmap" && return DrawingFill(:blip; preset = get(d, "draw:fill-image-name", nothing))
    return DrawingFill(:solid; fgcolor = c)
end

const _CAPS = Dict("butt" => "flat", "round" => "rnd", "square" => "sq")
function _line(d::Dict{String,String})
    s = get(d, "draw:stroke", nothing)
    c = _color(d, "svg:stroke-color", "@loext:stroke-complex-color")
    w = _pt(get(d, "svg:stroke-width", nothing))
    cap = get(d, "svg:stroke-linecap", nothing); join = get(d, "draw:stroke-linejoin", nothing)
    (s === nothing && c === nothing && w === nothing && cap === nothing && join === nothing) && return nothing
    s == "none" && return DrawingLine(; fill = DrawingFill(:none))
    dash = s == "dash" ? something(get(d, "draw:stroke-dash", nothing), "dash") : s === nothing ? nothing : "solid"
    return DrawingLine(; fill = c === nothing ? nothing : DrawingFill(:solid; fgcolor = c), width = w, dash,
                       cap = cap === nothing ? nothing : get(_CAPS, cap, cap), join = join == "none" ? nothing : join)
end

function _shape(d::Dict{String,String})
    f = _fill(d); l = _line(d)
    return f === nothing && l === nothing ? nothing : DrawingShapeProps(f, l, nothing, nothing, nothing)
end

const _UNDER = Dict("solid" => "sng", "wave" => "wavy", "dotted" => "dotted", "dash" => "dash", "long-dash" => "dashLong",
                    "dot-dash" => "dotDash", "dot-dot-dash" => "dotDotDash")
function _runprops(d::Dict{String,String})
    any(k -> startswith(k, "fo:") || startswith(k, "style:font") || startswith(k, "style:text-") || k == "style:letter-kerning", keys(d)) ||
        return nothing
    under = let st = get(d, "style:text-underline-style", nothing)
        st === nothing ? nothing : st == "none" ? "none" :
        get(d, "style:text-underline-type", "") == "double" ? "dbl" :
        (u = get(_UNDER, st, st); get(d, "style:text-underline-width", "") == "bold" ? u * "Heavy" : u)
    end
    strike = let st = get(d, "style:text-line-through-style", nothing)
        st === nothing ? nothing : st == "none" ? "noStrike" : get(d, "style:text-line-through-type", "") == "double" ? "dblStrike" : "sngStrike"
    end
    caps = get(d, "fo:font-variant", "") == "small-caps" ? "small" : get(d, "fo:text-transform", "") == "uppercase" ? "all" : nothing
    base = let p = get(d, "style:text-position", nothing)
        p === nothing ? nothing : startswith(p, "super") ? 0.33 : startswith(p, "sub") ? -0.33 :
        (x = tryparse(Float64, rstrip(first(split(p)), '%')); x === nothing ? nothing : x / 100)
    end
    w = get(d, "fo:font-weight", nothing); i = get(d, "fo:font-style", nothing)
    lang = get(d, "fo:language", nothing)
    lang !== nothing && haskey(d, "fo:country") && (lang *= "-" * d["fo:country"])
    color = _color(d, "fo:color", "@loext:char-complex-color")
    sz = _pt(get(d, "fo:font-size", nothing))
    sp = get(d, "fo:letter-spacing", nothing)
    return DrawingRunProps(; lang, size = sz, bold = w === nothing ? nothing : w in ("bold", "600", "700", "800", "900"),
        italic = i === nothing ? nothing : i in ("italic", "oblique"), under, strike, caps, baseline = base,
        spacing = sp === nothing || sp == "normal" ? nothing : _pt(sp),
        fill = color === nothing ? nothing : DrawingFill(:solid; fgcolor = color),
        line = get(d, "style:text-outline", "") == "true" ? DrawingLine() : nothing,
        latin = something(get(d, "style:font-name", nothing), get(d, "fo:font-family", nothing), Some(nothing)),
        ea = something(get(d, "style:font-name-asian", nothing), get(d, "style:font-family-asian", nothing), Some(nothing)),
        cs = something(get(d, "style:font-name-complex", nothing), get(d, "style:font-family-complex", nothing), Some(nothing)))
end

_rotation(d) = (r = get(d, "style:rotation-angle", nothing); r === nothing ? nothing : _num(replace(r, "deg" => "")))

# An element's text properties, as XLSX.jl's `txPr`: one empty paragraph with them as its defaults.
function _txpr(doc::_ChartDoc, n)
    n === nothing && return nothing
    d = _style(doc, n)
    rp = _runprops(d)
    rp === nothing && _rotation(d) === nothing && return nothing
    return DrawingText(DrawingBodyProps(; rotation = _rotation(d)), nothing,
                       [DrawingParagraph(DrawingParaProps(; defprops = rp), DrawingRun[], nothing, nothing)], nothing)
end

# An element's paragraphs as a DrawingText: runs with their spans' properties, line breaks as runs.
function _drawing_text(doc::_ChartDoc, n)
    n === nothing && return nothing
    paras = DrawingParagraph[]
    for p in _children(n, "text:p")
        runs = DrawingRun[]
        walk(x, props) = for c in XML.children(x)
            t = XML.nodetype(c)
            if t === XML.Text
                push!(runs, DrawingRun(:run, XML.unescape(XML.value(c)), props, nothing))
            elseif t === XML.Element
                tg = XML.tag(c)
                if tg == "text:line-break"
                    push!(runs, DrawingRun(:br, "\n", props, nothing))
                elseif tg == "text:s"
                    push!(runs, DrawingRun(:run, " "^something(tryparse(Int, something(_get(c, "text:c"), "1")), 1), props, nothing))
                elseif tg == "text:tab"
                    push!(runs, DrawingRun(:run, "\t", props, nothing))
                elseif tg == "text:span"
                    sn = _get(c, "text:style-name")
                    walk(c, sn === nothing ? props : _runprops(get(doc.styles, sn, Dict{String,String}())))
                else
                    walk(c, props)
                end
            end
        end
        walk(p, nothing)
        push!(paras, DrawingParagraph(nothing, runs, nothing, nothing))
    end
    d = _style(doc, n)
    return DrawingText(DrawingBodyProps(; rotation = _rotation(d)), nothing, paras, nothing)
end

#
# Parts of the chart
#

_title_node(doc) = get(_children(doc.chart, "chart:title"), 1, nothing)
_legend_node(doc) = get(_children(doc.chart, "chart:legend"), 1, nothing)
_wall_node(doc) = (pa = _plot_area(doc); pa === nothing ? nothing : get(_children(pa, "chart:wall"), 1, nothing))
_maybe(f, x) = x === nothing ? nothing : f(x)

"""
    getChartTitleText(c) -> Union{Nothing,DrawingText}

The chart's title as rich text: its paragraphs and runs, each run with its span's properties.
"""
getChartTitleText(c::AbstractChart) = (doc = _doc(c); _drawing_text(doc, _title_node(doc)))

"""
    getChartTitleShapeProps(c) -> Union{Nothing,DrawingShapeProps}
    getChartTitleTextProps(c) -> Union{Nothing,DrawingText}

The title's fill and border, and its text properties.
"""
getChartTitleShapeProps(c::AbstractChart) = (doc = _doc(c); _maybe(n -> _shape(_style(doc, n)), _title_node(doc)))
getChartTitleTextProps(c::AbstractChart) = (doc = _doc(c); _txpr(doc, _title_node(doc)))

"""
    getChartTitleRef(c) -> Nothing
    getChartTitleRange(c) -> Nothing
    getAutoTitleDeleted(c) -> Nothing

Always `nothing`: LibreOffice's titles can't follow a cell, and it has no automatic titles (F-081).
"""
getChartTitleRef(::AbstractChart) = nothing
getChartTitleRange(::AbstractChart) = nothing
getAutoTitleDeleted(::AbstractChart) = nothing

"""
    getChartLegend(c) -> Union{Nothing,XML.Node}

The `chart:legend` element, or `nothing` when the chart has no legend.
"""
getChartLegend(c::AbstractChart) = _legend_node(_doc(c))

const _LEGEND_POS = Dict("bottom" => :b, "top" => :t, "start" => :l, "end" => :r, "top-end" => :tr,
                         "top-start" => :tl, "bottom-start" => :bl, "bottom-end" => :br)

"""
    getLegendPos(c) -> Union{Nothing,Symbol}

`:b`, `:t`, `:l`, `:r` or `:tr`, and the other corners `:tl`, `:bl`, `:br`; `nothing` without a legend.
LibreOffice keeps a corner as a custom position (`style:legend-expansion="custom"` with `svg:x` and
`svg:y`, as its import writes `:tr`, F-081): the corner is the quarter of the chart the legend is in.
"""
getLegendPos(c::AbstractChart) = _maybe(_legend_node(_doc(c))) do n
    if _get(n, "style:legend-expansion") == "custom"
        x = _cm_value(_get(n, "svg:x")); y = _cm_value(_get(n, "svg:y"))
        if x !== nothing && y !== nothing
            w, h = _chart_size(c)
            return y < h / 2 ? (x < w / 2 ? :tl : :tr) : (x < w / 2 ? :bl : :br)
        end
    end
    return get(_LEGEND_POS, something(_get(n, "chart:legend-position"), "end"), :r)
end
_cm_value(s) = s === nothing ? nothing : (m = match(r"^(-?[\d.]+)cm$", s); m === nothing ? nothing : parse(Float64, m.captures[1]))

# A chart's size in cm: its object's page (`chart:chart`'s svg:width and svg:height, on which its
# custom positions are), else its frame's.
function _chart_size(c::AbstractChart)
    f = _frame(c)
    ch = match(r"<chart:chart\b[^>]*>", _object_text(f))
    if ch !== nothing
        w = _cm_value(_attr(ch.match, "svg:width")); h = _cm_value(_attr(ch.match, "svg:height"))
        w !== nothing && h !== nothing && return (w, h)
    end
    if isempty(f.xml) && f.ws.frames !== nothing
        for fe in values(f.ws.frames), img in fe.added
            img.object == c.name && return (img.width, img.height)
        end
    end
    return (something(_attr_cm(f.xml, "svg:width"), 16.0), something(_attr_cm(f.xml, "svg:height"), 9.0))
end

"""
    getLegendOverlay(c) -> Union{Nothing,Bool}

Whether the legend may overlap the plot area (LibreOffice's `loext:overlay`, F-082).
"""
getLegendOverlay(c::AbstractChart) = _maybe(n -> _get(n, "loext:overlay") == "true", _legend_node(_doc(c)))

"""
    getLegendShapeProps(c) -> Union{Nothing,DrawingShapeProps}
    getLegendTextProps(c) -> Union{Nothing,DrawingText}
"""
getLegendShapeProps(c::AbstractChart) = (doc = _doc(c); _maybe(n -> _shape(_style(doc, n)), _legend_node(doc)))
getLegendTextProps(c::AbstractChart) = (doc = _doc(c); _txpr(doc, _legend_node(doc)))

"""
    getLegendEntryDeleted(c, i) -> Union{Nothing,Bool}

Whether series `i`'s legend entry is hidden (LibreOffice's `loext:hide-legend`).
"""
getLegendEntryDeleted(c::Chart, i::Integer) = (doc = _doc(c); _bool(_get(_series_node(doc, i), "loext:hide-legend")))

"""
    getPlotAreaShapeProps(c) -> Union{Nothing,DrawingShapeProps}
    getChartSpaceShapeProps(c) -> Union{Nothing,DrawingShapeProps}
    getChartSpaceTextProps(c) -> Union{Nothing,DrawingText}

The plot area's fill and border (LibreOffice's wall), and the chart's background and text defaults.
"""
getPlotAreaShapeProps(c::Chart) = (doc = _doc(c); _maybe(n -> _shape(_style(doc, n)), _wall_node(doc)))
getChartSpaceShapeProps(c::Chart) = (doc = _doc(c); _shape(_style(doc, doc.chart)))
getChartSpaceTextProps(c::Chart) = (doc = _doc(c); _txpr(doc, doc.chart))

#
# Series, points, markers and labels
#

function _series_node(doc::_ChartDoc, i::Integer)
    s = _series_nodes(doc)
    1 <= i <= length(s) || throw(ODSError("The chart has $(length(s)) series; there is no series $i."))
    return s[i]
end

"""
    getSeriesShapeProps(c, i) -> Union{Nothing,DrawingShapeProps}
    getSeriesLabelTextProps(c, i) -> Union{Nothing,DrawingText}

Series `i`'s fill and line, and its data labels' text properties.
"""
getSeriesShapeProps(c::Chart, i::Integer) = (doc = _doc(c); _shape(_style(doc, _series_node(doc, i))))
getSeriesLabelTextProps(c::Chart, i::Integer) = (doc = _doc(c); _txpr(doc, _series_node(doc, i)))

const _SYMBOLS = Dict("square" => :square, "diamond" => :diamond, "circle" => :circle, "x" => :x, "plus" => :plus,
    "asterisk" => :star, "arrow-up" => :triangle, "horizontal-bar" => :dash, "arrow-right" => :dot,
    "arrow-down" => :arrowDown, "arrow-left" => :arrowLeft, "bow-tie" => :bowTie, "hourglass" => :hourglass,
    "star" => :loStar, "vertical-bar" => :vBar)

function _marker(doc::_ChartDoc, n, si::Int, pi::Union{Nothing,Int})
    d = _style(doc, n)
    t = get(d, "chart:symbol-type", nothing)
    t === nothing && return nothing
    sym = t == "none" ? :none : t == "automatic" ? :auto : t == "named-symbol" ? get(_SYMBOLS, get(d, "chart:symbol-name", ""), :auto) : :picture
    w = _pt(get(d, "chart:symbol-width", nothing))
    return ChartMarker(si, pi, sym, w === nothing ? nothing : round(Int, w), _shape(d), nothing)
end

"""
    getSeriesMarker(c, i) -> Union{Nothing,ChartMarker}

Series `i`'s symbol, or `nothing` when its style sets none (LibreOffice's default for the chart type).
"""
getSeriesMarker(c::Chart, i::Integer) = (doc = _doc(c); _marker(doc, _series_node(doc, i), i - 1, nothing))

"""
    getSeriesGroup(c, i) -> ChartGroup
    getGroupAxes(c, g) -> Vector{ChartAxis}
    getSeriesAxes(c, i) -> Vector{ChartAxis}

The group series `i` is in, and the axes of a group or a series (none for a pie or doughnut).
"""
getSeriesGroup(c::Chart, i::Integer) = (doc = _doc(c); s = _series_node(doc, i); ChartGroup(_series_tag(doc, s), _series_axids(s), nothing))
function getGroupAxes(c::Chart, g::ChartGroup)
    g.kind in (:pieChart, :pie3DChart, :doughnutChart, :ofPieChart) && return ChartAxis[]
    axes = _axes(_doc(c))
    return [a for a in axes if a.axid in g.axids || (a.axid == 1 && 3 in g.axids && !any(b -> b.axid == 3, axes)) || a.axid == 5]
end
getSeriesAxes(c::Chart, i::Integer) = getGroupAxes(c, getSeriesGroup(c, i))

# A series' points with their own styles: (index from 0, the element), `chart:repeated` expanded.
function _points(doc::_ChartDoc, s)
    out = Tuple{Int,Any}[]
    k = 0
    for p in _children(s, "chart:data-point")
        n = something(tryparse(Int, something(_get(p, "chart:repeated"), "1")), 1)
        if _get(p, "chart:style-name") !== nothing
            for j in 0:n-1
                push!(out, (k + j, p))
            end
        end
        k += n
    end
    return out
end

"""
    getSeriesDataPoints(c, i) -> Vector{ChartDataPoint}
    getSeriesDataPoint(c, i, point) -> Union{Nothing,ChartDataPoint}

The points of series `i` that have their own style (`point` counts from 1; `idx` from 0).
"""
getSeriesDataPoints(c::Chart, i::Integer) = (doc = _doc(c); [ChartDataPoint(i - 1, k, nothing, nothing, p) for (k, p) in _points(doc, _series_node(doc, i))])
function getSeriesDataPoint(c::Chart, i::Integer, point::Integer)
    doc = _doc(c)
    for (k, p) in _points(doc, _series_node(doc, i))
        k == point - 1 && return ChartDataPoint(i - 1, k, nothing, nothing, p)
    end
    return nothing
end

"""
    getDataPointShapeProps(c, d::ChartDataPoint) -> Union{Nothing,DrawingShapeProps}
    getDataPointMarker(c, d::ChartDataPoint) -> Union{Nothing,ChartMarker}
"""
getDataPointShapeProps(c::Chart, d::ChartDataPoint) = (doc = _doc(c); _shape(_style(doc, d.raw)))
getDataPointMarker(c::Chart, d::ChartDataPoint) = (doc = _doc(c); _marker(doc, d.raw, d.series_idx, d.idx))

const _LABEL_POS = Dict("avoid-overlap" => :bestFit, "center" => :ctr, "top" => :t, "bottom" => :b, "left" => :l,
    "right" => :r, "inside" => :inEnd, "outside" => :outEnd, "near-origin" => :inBase)

"""
    getSeriesDataLabels(c, i) -> Vector{ChartDataLabel}
    getSeriesDataLabel(c, i, point) -> Union{Nothing,ChartDataLabel}

The points of series `i` whose labels differ from the series': those with custom text (a
`chart:data-label`), and those whose style turns every label part off (`delete`).
"""
function getSeriesDataLabels(c::Chart, i::Integer)
    doc = _doc(c)
    out = ChartDataLabel[]
    for (k, p) in _points(doc, _series_node(doc, i))
        d = _style(doc, p)
        custom = !isempty(_children(p, "chart:data-label"))
        off = get(d, "chart:data-label-number", "") == "none" && get(d, "chart:data-label-text", "") == "false" &&
              get(d, "loext:data-label-series", get(d, "chart:data-label-series", "false")) == "false" && get(d, "chart:data-label-symbol", "false") == "false"
        (custom || off) && push!(out, ChartDataLabel(i - 1, k, off && !custom, p))
    end
    return out
end
getSeriesDataLabel(c::Chart, i::Integer, point::Integer) =
    (ls = getSeriesDataLabels(c, i); k = findfirst(l -> l.idx == point - 1, ls); k === nothing ? nothing : ls[k])

"""
    getDataLabelTextProps(c, d) / getDataLabelShapeProps(c, d) / getDataLabelText(c, d)
    getDataLabelPosition(c, d) / getDataLabelOffset(c, d)

A point's label: its text properties, fill and border, custom text (custom label fields), placement
(`:bestFit`, `:ctr`, `:t`, `:b`, `:l`, `:r`, `:inEnd`, `:outEnd`, `:inBase`) and offset (`nothing`: ODF
has no offsets).
"""
getDataLabelTextProps(c::Chart, d::ChartDataLabel) = (doc = _doc(c); _txpr(doc, d.raw))
getDataLabelShapeProps(c::Chart, d::ChartDataLabel) =
    (doc = _doc(c); l = get(_children(d.raw, "chart:data-label"), 1, nothing); _maybe(n -> _shape(_style(doc, n)), l))
getDataLabelText(c::Chart, d::ChartDataLabel) =
    (doc = _doc(c); l = get(_children(d.raw, "chart:data-label"), 1, nothing); _drawing_text(doc, l))
getDataLabelPosition(c::Chart, d::ChartDataLabel) =
    (doc = _doc(c); p = get(_style(doc, d.raw), "chart:label-position", nothing); p === nothing ? nothing : get(_LABEL_POS, p, nothing))
getDataLabelOffset(::Chart, ::ChartDataLabel) = nothing

"""
    getLabelFlag(c, i, flag) -> Union{Nothing,Bool}

Whether series `i`'s labels show `flag`: `:value`, `:percent`, `:categoryName`, `:seriesName` or
`:legendKey`; `nothing` when its style doesn't say. LibreOffice has no bubble-size labels:
`:bubbleSize` is always `nothing`.
"""
function getLabelFlag(c::Chart, i::Integer, flag::Symbol)
    doc = _doc(c)
    d = _style(doc, _series_node(doc, i))
    if flag in (:value, :percent)
        n = get(d, "chart:data-label-number", nothing)
        n === nothing && return nothing
        return flag === :value ? n in ("value", "value-and-percentage") : n in ("percentage", "value-and-percentage")
    end
    k = flag === :categoryName ? "chart:data-label-text" : flag === :seriesName ? "loext:data-label-series" :
        flag === :legendKey ? "chart:data-label-symbol" : flag === :bubbleSize ? nothing :
        throw(ODSError("Unknown label flag `:$flag`: use :value, :percent, :categoryName, :seriesName, :legendKey or :bubbleSize."))
    k == "loext:data-label-series" && !haskey(d, k) && (k = "chart:data-label-series")      # ODF 1.4's name (LibreOffice 26)
    return k === nothing ? nothing : _bool(get(d, k, nothing))
end

#
# The cascade
#

function _cascade(f, doc::_ChartDoc, c::Chart, i::Integer, point, kind::Symbol)
    s = _series_node(doc, i)
    chain = FormatSite[]
    if point !== nothing
        for (k, p) in _points(doc, s)
            k == point - 1 || continue
            push!(chain, FormatSite(:point, kind, nothing, _style(doc, p)))
        end
    end
    push!(chain, FormatSite(:series, kind, nothing, _style(doc, s)))
    for site in chain
        v = f(site.props)
        v === nothing || return (v, site, chain)
    end
    return (nothing, nothing, chain)
end

"""
    getSeriesFill(c, i; point = nothing) -> Effective{DrawingFill}
    getSeriesLine(c, i; point = nothing) -> Effective{DrawingLine}
    getMarkerFill(c, i, point) -> Effective{DrawingFill}

The fill or line series `i` (or one of its points) is drawn with, found through LibreOffice's cascade:
the point's style, then the series'. LibreOffice draws a symbol in its series' colours, so a marker's
fill is the series' fill.
"""
function getSeriesFill(c::Chart, i::Integer; point = nothing)
    v, site, chain = _cascade(_fill, _doc(c), c, i, point, :shape)
    return Effective{DrawingFill}(v, site, chain)
end
function getSeriesLine(c::Chart, i::Integer; point = nothing)
    v, site, chain = _cascade(_line, _doc(c), c, i, point, :shape)
    return Effective{DrawingLine}(v, site, chain)
end
getMarkerFill(c::Chart, i::Integer, point::Integer) = getSeriesFill(c, i; point)

"""
    getLabelTextProp(c, i, field) -> Effective

One text property of series `i`'s labels (a field of [`DrawingRunProps`](@ref): `:size`, `:bold`,
`:italic`, `:fill`…), from the series' style, else the chart's.
"""
function getLabelTextProp(c::Chart, i::Integer, field::Symbol)
    field in fieldnames(DrawingRunProps) || throw(ODSError("`$field` is not a text property; use one of $(join(fieldnames(DrawingRunProps)[1:end-1], ", "))."))
    doc = _doc(c)
    chain = [FormatSite(:series, :text, nothing, _style(doc, _series_node(doc, i))), FormatSite(:chartspace, :text, nothing, _style(doc, doc.chart))]
    for site in chain
        rp = _runprops(site.props)
        rp === nothing && continue
        v = getfield(rp, field)
        v === nothing || return Effective{typeof(v)}(v, site, chain)
    end
    return Effective{Any}(nothing, nothing, chain)
end

#
# Trendlines and error bars
#

const _REG = Dict("linear" => :linear, "logarithmic" => :log, "exponential" => :exp, "power" => :power,
                  "polynomial" => :poly, "moving-average" => :movingAvg)

"""
    getSeriesTrendlines(c, i) -> Vector{ChartTrendline}
    getTrendlineShapeProps(c, t) / getTrendlineLabelText(c, t) / getTrendlineLabelTextProps(c, t) / getTrendlineLabelShapeProps(c, t)

Series `i`'s trendlines (`chart:regression-curve`, F-082), their line, and their equation's text and
formatting.
"""
function getSeriesTrendlines(c::Chart, i::Integer)
    doc = _doc(c)
    out = ChartTrendline[]
    for (k, r) in enumerate(_children(_series_node(doc, i), "chart:regression-curve"))
        d = _style(doc, r)
        eq = get(_children(r, "chart:equation"), 1, nothing)
        force = get(d, "chart:regression-force-intercept", "false") == "true"
        push!(out, ChartTrendline(i - 1, k, get(_REG, get(d, "chart:regression-type", "linear"), :linear),
            get(d, "chart:regression-name", nothing), _maybe(x -> tryparse(Int, x), get(d, "chart:regression-max-degree", nothing)),
            _maybe(x -> tryparse(Int, x), get(d, "chart:regression-period", nothing)),
            _num(get(d, "loext:regression-extrapolate-forward", get(d, "chart:regression-extrapolate-forward", nothing))),
            _num(get(d, "loext:regression-extrapolate-backward", get(d, "chart:regression-extrapolate-backward", nothing))),
            force ? _num(get(d, "chart:regression-intercept-value", nothing)) : nothing,
            eq === nothing ? nothing : _get(eq, "chart:display-r-square") == "true",
            eq === nothing ? nothing : _get(eq, "chart:display-equation") == "true", r))
    end
    return out
end
getTrendlineShapeProps(c::Chart, t::ChartTrendline) = (doc = _doc(c); _shape(_style(doc, t.raw)))
_equation(t::ChartTrendline) = get(_children(t.raw, "chart:equation"), 1, nothing)
getTrendlineLabelText(c::Chart, t::ChartTrendline) = (doc = _doc(c); _maybe(n -> isempty(_children(n, "text:p")) ? nothing : _drawing_text(doc, n), _equation(t)))
getTrendlineLabelTextProps(c::Chart, t::ChartTrendline) = (doc = _doc(c); _txpr(doc, _equation(t)))
getTrendlineLabelShapeProps(c::Chart, t::ChartTrendline) = (doc = _doc(c); _maybe(n -> _shape(_style(doc, n)), _equation(t)))

const _ERRCAT = Dict("constant" => "fixedVal", "percentage" => "percentage", "standard-deviation" => "stdDev",
                     "standard-error" => "stdErr", "cell-range" => "cust", "variance" => "stdDev")

"""
    getSeriesErrorBars(c, i) -> Vector{ChartErrorBars}
    getErrorBarsShapeProps(c, e) -> Union{Nothing,DrawingShapeProps}
    getErrorBarsCustomRefs(c, e) -> (plus, minus)

Series `i`'s error bars (`chart:error-indicator`, F-082), their line, and the cells of error bars from
cell ranges (as [`ChartRef`](@ref)s).
"""
function getSeriesErrorBars(c::Chart, i::Integer)
    doc = _doc(c)
    out = ChartErrorBars[]
    for (k, e) in enumerate(_children(_series_node(doc, i), "chart:error-indicator"))
        d = _style(doc, e)
        up = get(d, "chart:error-upper-indicator", "true") == "true"; lo = get(d, "chart:error-lower-indicator", "true") == "true"
        cat = get(d, "chart:error-category", "none")
        val = cat == "percentage" ? _num(get(d, "chart:error-percentage", nothing)) :
              cat == "constant" ? _num(get(d, "chart:error-upper-limit", nothing)) :
              cat == "standard-deviation" ? _num(get(d, "loext:std-weight", nothing)) : nothing
        push!(out, ChartErrorBars(i - 1, k, _get(e, "chart:dimension"), up && lo ? "both" : up ? "plus" : "minus",
                                  get(_ERRCAT, cat, cat), val, nothing, e))
    end
    return out
end
getErrorBarsShapeProps(c::Chart, e::ChartErrorBars) = (doc = _doc(c); _shape(_style(doc, e.raw)))
function getErrorBarsCustomRefs(c::Chart, e::ChartErrorBars)
    doc = _doc(c)
    d = _style(doc, e.raw)
    return (plus = _chart_ref(c.package, get(d, "chart:error-upper-range", nothing)),
            minus = _chart_ref(c.package, get(d, "chart:error-lower-range", nothing)))
end

#
# Groups: lines and bars LibreOffice has (or hasn't)
#

"""
    getGroupDropLines(c, g) / getGroupHiLowLines(c, g) / getGroupSeriesLines(c, g) -> Nothing

Always `nothing`: LibreOffice has no drop lines or series lines, and a stock chart's high-low lines are
its series' (F-080).
"""
getGroupDropLines(::Chart, ::ChartGroup) = nothing
getGroupHiLowLines(::Chart, ::ChartGroup) = nothing
getGroupSeriesLines(::Chart, ::ChartGroup) = nothing

"""
    getGroupUpDownBars(c, g) -> Union{Nothing,ChartUpDownBars}
    getUpBarShapeProps(c, b) / getDownBarShapeProps(c, b)

A stock group's candle bodies (LibreOffice's Japanese candlesticks), and the fill and line of rising and
falling ones (`chart:stock-gain-marker`, `chart:stock-loss-marker`).
"""
function getGroupUpDownBars(c::Chart, g::ChartGroup)
    g.kind === :stockChart || return nothing
    doc = _doc(c)
    pa = _plot_area(doc)
    get(_style(doc, pa), "chart:japanese-candle-stick", "false") == "true" || return nothing
    return ChartUpDownBars(g, nothing, nothing)
end
_stock_marker(c::Chart, tag::String) = (doc = _doc(c); pa = _plot_area(doc); n = get(_children(pa, tag), 1, nothing); _maybe(x -> _shape(_style(doc, x)), n))
getUpBarShapeProps(c::Chart, ::ChartUpDownBars) = _stock_marker(c, "chart:stock-gain-marker")
getDownBarShapeProps(c::Chart, ::ChartUpDownBars) = _stock_marker(c, "chart:stock-loss-marker")

# A group's gap width and overlap are kept on its y axis's style (F-082).
_group_axis_style(doc::_ChartDoc, g::ChartGroup) =
    (n = _axis_node(doc, 3 in g.axids ? 4 : 2); n === nothing ? Dict{String,String}() : _style(doc, n))

"""
    getGroupGapWidth(c, g) -> Union{Nothing,Int}
    getGroupOverlap(c, g) -> Union{Nothing,Int}

A bar group's gap width and overlap, in percent.
"""
getGroupGapWidth(c::Chart, g::ChartGroup) = _maybe(x -> tryparse(Int, x), get(_group_axis_style(_doc(c), g), "chart:gap-width", nothing))
getGroupOverlap(c::Chart, g::ChartGroup) = _maybe(x -> tryparse(Int, x), get(_group_axis_style(_doc(c), g), "chart:overlap", nothing))

"""
    getGroupLabelTextProps(c, g) -> Union{Nothing,DrawingText}

LibreOffice has no group level: the text properties of the group's first series' labels.
"""
function getGroupLabelTextProps(c::Chart, g::ChartGroup)
    doc = _doc(c)
    for s in _series_nodes(doc)
        ChartGroup(_series_tag(doc, s), _series_axids(s), nothing) == g && return _txpr(doc, s)
    end
    return nothing
end

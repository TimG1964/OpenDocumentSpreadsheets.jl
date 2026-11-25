# The formatting value types, with XLSX.jl's DrawingML names and fields (D-085), filled from a chart's
# ODF styles: `style:graphic-properties` (fill and stroke), `style:text-properties` and
# `style:chart-properties`. A field ODF has no value for is `nothing`; `raw` is `nothing` (the values
# come from styles, not from one element).

"""
    DrawingColor

A colour as read: `kind` is `:srgb`, or `:scheme` for a colour that follows the document's theme
(LibreOffice's `loext:theme-type`, F-082); `val` is `"RRGGBB"` or the theme slot (`"accent1"`);
`transforms` are a theme colour's (`:lumMod => 60000`…, thousandths of a percent); `rgb` the colour as
drawn, `"RRGGBB"`; `alpha` its opacity, 0 to 1.
"""
struct DrawingColor
    kind::Symbol
    val::String
    transforms::Vector{Pair{Symbol,Int}}
    rgb::String
    alpha::Float64
end

"""
    ColorSpec

What a colour can be given as: a [`DrawingColor`](@ref), or a string (`"FF0000"`, `"red"`, `"accent1"`).
"""
const ColorSpec = Union{DrawingColor,String}

"""
    DrawingFill

A fill: `kind` is `:none`, `:solid`, `:gradient`, `:pattern` (a hatch) or `:blip` (a bitmap);
`fgcolor` a solid fill's colour (a hatch's line colour); `bgcolor` a hatch's background; `preset` a
hatch's, gradient's or bitmap's name.
"""
struct DrawingFill
    kind::Symbol
    fgcolor::Union{Nothing,ColorSpec}
    bgcolor::Union{Nothing,ColorSpec}
    preset::Union{Nothing,String}
    raw::Union{Nothing,XML.Node}
end
DrawingFill(kind::Symbol; fgcolor = nothing, bgcolor = nothing, preset = nothing) = DrawingFill(kind, fgcolor, bgcolor, preset, nothing)

"""
    DrawingLine

A line: `fill` its colour (`kind === :none` for no line), `width` in points, `dash` (`"solid"` or the
name of LibreOffice's dash), `cap` (`"rnd"`, `"sq"`, `"flat"`), `join` (`"round"`, `"bevel"`,
`"miter"`). ODF has no compound lines or miter limits (F-081): `compound` and `miter_limit` are
`nothing`.
"""
struct DrawingLine
    fill::Union{Nothing,DrawingFill}
    width::Union{Nothing,Float64}
    dash::Union{Nothing,String}
    cap::Union{Nothing,String}
    compound::Union{Nothing,String}
    join::Union{Nothing,String}
    miter_limit::Union{Nothing,Float64}
    raw::Union{Nothing,XML.Node}
end
DrawingLine(; fill = nothing, width = nothing, dash = nothing, cap = nothing, compound = nothing, join = nothing,
              miter_limit = nothing) = DrawingLine(fill, width, dash, cap, compound, join, miter_limit, nothing)

"""
    DrawingShapeProps

The fill and line of a part of a chart (a series, a point, the wall, the chart, an axis line, the legend,
gridlines). `nothing` means the style says nothing (LibreOffice's default applies); a `DrawingFill` of
kind `:none` means none.
"""
struct DrawingShapeProps
    fill::Union{Nothing,DrawingFill}
    line::Union{Nothing,DrawingLine}
    effects::Union{Nothing,XML.Node}
    bwmode::Union{Nothing,String}
    raw::Union{Nothing,XML.Node}
end

"""
    DrawingRunProps

Character properties, from `style:text-properties`: `lang` (`"de-DE"`), `size` (points), `bold`,
`italic`, `under` and `strike` (XLSX.jl's names: `"sng"`, `"dbl"`, `"wavy"`…, `"sngStrike"`…), `caps`
(`"small"`, `"all"`), `baseline` (a fraction of the size), `spacing` (points), `fill` (the colour),
`line` (a text outline; LibreOffice's has no colour), and the fonts `latin`, `ea` and `cs`. ODF has no
kerning size: `kern` is `nothing`.
"""
struct DrawingRunProps
    lang::Union{Nothing,String}
    size::Union{Nothing,Float64}
    bold::Union{Nothing,Bool}
    italic::Union{Nothing,Bool}
    under::Union{Nothing,String}
    strike::Union{Nothing,String}
    caps::Union{Nothing,String}
    baseline::Union{Nothing,Float64}
    kern::Union{Nothing,Float64}
    spacing::Union{Nothing,Float64}
    fill::Union{Nothing,DrawingFill}
    line::Union{Nothing,DrawingLine}
    latin::Union{Nothing,String}
    ea::Union{Nothing,String}
    cs::Union{Nothing,String}
    raw::Union{Nothing,XML.Node}
end
DrawingRunProps(; lang = nothing, size = nothing, bold = nothing, italic = nothing, under = nothing, strike = nothing,
                  caps = nothing, baseline = nothing, kern = nothing, spacing = nothing, fill = nothing, line = nothing,
                  latin = nothing, ea = nothing, cs = nothing) =
    DrawingRunProps(lang, size, bold, italic, under, strike, caps, baseline, kern, spacing, fill, line, latin, ea, cs, nothing)

"""
    DrawingParaProps

Paragraph properties. In a chart, `defprops` (the text's character properties) is the one ODF fills.
"""
struct DrawingParaProps
    align::Union{Nothing,String}
    level::Union{Nothing,Int}
    marginleft::Union{Nothing,Float64}
    marginright::Union{Nothing,Float64}
    indent::Union{Nothing,Float64}
    rtl::Union{Nothing,Bool}
    linespacing::Union{Nothing,Tuple{Symbol,Float64}}
    spacebefore::Union{Nothing,Tuple{Symbol,Float64}}
    spaceafter::Union{Nothing,Tuple{Symbol,Float64}}
    defprops::Union{Nothing,DrawingRunProps}
    raw::Union{Nothing,XML.Node}
end
DrawingParaProps(; align = nothing, level = nothing, marginleft = nothing, marginright = nothing, indent = nothing,
                   rtl = nothing, linespacing = nothing, spacebefore = nothing, spaceafter = nothing, defprops = nothing) =
    DrawingParaProps(align, level, marginleft, marginright, indent, rtl, linespacing, spacebefore, spaceafter, defprops, nothing)

"""
    DrawingRun

One run of text (`kind` `:run`), or a line break (`:br`, text `"\\n"`), with its own properties (a
`text:span`'s style).
"""
struct DrawingRun
    kind::Symbol
    text::Union{Nothing,String}
    props::Union{Nothing,DrawingRunProps}
    raw::Union{Nothing,XML.Node}
end
DrawingRun(text::AbstractString; props = nothing, kind::Symbol = :run) = DrawingRun(kind, String(text), props, nothing)

"""
    DrawingParagraph

One paragraph (`text:p`): its runs in order.
"""
struct DrawingParagraph
    props::Union{Nothing,DrawingParaProps}
    runs::Vector{DrawingRun}
    endprops::Union{Nothing,DrawingRunProps}
    raw::Union{Nothing,XML.Node}
end
DrawingParagraph(runs::Union{DrawingRun,AbstractString}...; props = nothing, endprops = nothing) =
    DrawingParagraph(props, DrawingRun[r isa DrawingRun ? r : DrawingRun(r) for r in runs], endprops, nothing)

"""
    DrawingBodyProps

A text's body: `rotation` (degrees, `style:rotation-angle`) is the one ODF fills.
"""
struct DrawingBodyProps
    rotation::Union{Nothing,Float64}
    vertical::Union{Nothing,String}
    wrap::Union{Nothing,String}
    anchor::Union{Nothing,String}
    anchorctr::Union{Nothing,Bool}
    upright::Union{Nothing,Bool}
    spcfirstlastpara::Union{Nothing,Bool}
    vertoverflow::Union{Nothing,String}
    horzoverflow::Union{Nothing,String}
    insetleft::Union{Nothing,Float64}
    insettop::Union{Nothing,Float64}
    insetright::Union{Nothing,Float64}
    insetbottom::Union{Nothing,Float64}
    autofit::Union{Nothing,Symbol}
    fontscale::Union{Nothing,Float64}
    linespacereduction::Union{Nothing,Float64}
    raw::Union{Nothing,XML.Node}
end
DrawingBodyProps(; rotation = nothing) = DrawingBodyProps(rotation, ntuple(_ -> nothing, 16)...)

"""
    DrawingText

A text: its body and paragraphs. A title's text has its runs; a text-properties getter's has one empty
paragraph whose `props.defprops` are the element's character properties.
"""
struct DrawingText
    body::Union{Nothing,DrawingBodyProps}
    liststyle::Union{Nothing,XML.Node}
    paragraphs::Vector{DrawingParagraph}
    raw::Union{Nothing,XML.Node}
end
DrawingText(paras::Union{DrawingParagraph,AbstractString}...; body = nothing, liststyle = nothing) =
    DrawingText(body, liststyle, DrawingParagraph[p isa DrawingParagraph ? p : DrawingParagraph(p) for p in paras], nothing)

"""
    FormatSite

Where a value was found: `level` (`:point`, `:series`, `:chartspace`), `kind` (`:shape`, `:marker`,
`:text`), `container` (`nothing`), `props` (what was read there).
"""
struct FormatSite
    level::Symbol
    kind::Symbol
    container::Union{Nothing,XML.Node}
    props::Any
end

"""
    Effective{T}

A value resolved through LibreOffice's cascade (a point's style, then its series'): `value`, the `site`
it came from, and the `chain` of sites looked at. `value` is `nothing` when no style sets it
(LibreOffice's default applies).
"""
struct Effective{T}
    value::Union{Nothing,T}
    site::Union{Nothing,FormatSite}
    chain::Vector{FormatSite}
    # `T` is always given (a `nothing` value can't tell it)
    Effective{T}(value, site, chain) where {T} = new{T}(value, site, chain)
end

"""
    ChartMarker

A series' (or point's) symbol: `symbol` (`:circle`, `:square`, `:diamond`, `:triangle`, `:x`, `:plus`,
`:star`, `:dash`, `:dot`, `:none`, `:auto`, and LibreOffice's own `:arrowDown`, `:arrowLeft`,
`:bowTie`, `:hourglass`, `:loStar`, `:vBar`), `size` in points, `shape` its fill and line (LibreOffice
draws a symbol in its series' colours).
"""
struct ChartMarker
    series_idx::Int
    point_idx::Union{Nothing,Int}
    symbol::Union{Nothing,Symbol}
    size::Union{Nothing,Int}
    shape::Union{Nothing,DrawingShapeProps}
    raw::Union{Nothing,XML.Node}
end

"""
    ChartAxis

An axis: `kind` (`:catAx`, `:valAx`, `:dateAx`, `:serAx`), `axid` (1 primary x, 2 primary y, 3 secondary
x, 4 secondary y, 5 z), `pos` (`:b`, `:l`, `:t`, `:r`), `crossax` (the axis it crosses), `deleted` (hidden).
"""
struct ChartAxis
    kind::Symbol
    axid::Int
    pos::Union{Nothing,Symbol}
    crossax::Union{Nothing,Int}
    deleted::Bool
    raw::Union{Nothing,XML.Node}
end
Base.:(==)(a::ChartAxis, b::ChartAxis) = a.axid == b.axid && a.kind == b.kind
Base.hash(a::ChartAxis, h::UInt) = hash(a.axid, hash(a.kind, h))

"""
    ChartDataPoint

A point with its own style: `series_idx`, `idx` (from 0).
"""
struct ChartDataPoint
    series_idx::Int
    idx::Int
    invert_if_negative::Union{Nothing,Bool}
    bubble3d::Union{Nothing,Bool}
    raw::Union{Nothing,XML.Node}
end

"""
    ChartDataLabel

A point's own label (custom text, or labels turned off): `series_idx`, `idx` (from 0), `delete`.
"""
struct ChartDataLabel
    series_idx::Int
    idx::Int
    delete::Union{Nothing,Bool}
    raw::Union{Nothing,XML.Node}
end

"""
    ChartTrendline

A series' trendline (`chart:regression-curve`): `kind` (`:linear`, `:log`, `:exp`, `:power`, `:poly`,
`:movingAvg`), `name`, `order` (polynomial degree), `period` (moving average), `forward`/`backward`
(extrapolation), `intercept` (when forced), `disp_rsqr`, `disp_eq`.
"""
struct ChartTrendline
    series_idx::Int
    ordinal::Int
    kind::Symbol
    name::Union{Nothing,String}
    order::Union{Nothing,Int}
    period::Union{Nothing,Int}
    forward::Union{Nothing,Float64}
    backward::Union{Nothing,Float64}
    intercept::Union{Nothing,Float64}
    disp_rsqr::Union{Nothing,Bool}
    disp_eq::Union{Nothing,Bool}
    raw::Union{Nothing,XML.Node}
end

"""
    ChartErrorBars

A series' error bars (`chart:error-indicator`): `direction` (`"x"`, `"y"`), `bar_type` (`"both"`,
`"plus"`, `"minus"`), `value_type` (`"fixedVal"`, `"percentage"`, `"stdDev"`, `"stdErr"`, `"cust"` for
cell ranges), `value`, `no_end_cap`.
"""
struct ChartErrorBars
    series_idx::Int
    ordinal::Int
    direction::Union{Nothing,String}
    bar_type::Union{Nothing,String}
    value_type::Union{Nothing,String}
    value::Union{Nothing,Float64}
    no_end_cap::Union{Nothing,Bool}
    raw::Union{Nothing,XML.Node}
end

"""
    ChartUpDownBars

A stock chart's candle bodies (LibreOffice's Japanese candlesticks): its `group`.
"""
struct ChartUpDownBars
    group::ChartGroup
    gap_width::Union{Nothing,Int}
    raw::Union{Nothing,XML.Node}
end

"""
    hasFill(x) -> Bool
    hasLine(x) -> Bool

Whether a fill (of shape properties, a fill, or an [`Effective`](@ref) fill) is drawn: not `nothing`
and not of kind `:none`; likewise a line.
"""
hasFill(f::DrawingFill) = f.kind !== :none
hasFill(p::DrawingShapeProps) = p.fill !== nothing && hasFill(p.fill)
hasFill(e::Effective{DrawingFill}) = e.value !== nothing && hasFill(e.value)
hasLine(l::DrawingLine) = l.fill === nothing || l.fill.kind !== :none
hasLine(p::DrawingShapeProps) = p.line !== nothing && hasLine(p.line)
hasLine(e::Effective{DrawingLine}) = e.value !== nothing && hasLine(e.value)

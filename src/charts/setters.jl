# Formatting setters (phase 8 step 6, D-085, D-086): XLSX.jl's setters on LibreOffice's chart styles,
# for charts added here and LibreOffice's own (zipped files). Every setter returns the chart; `:inherit`
# removes the setting. What LibreOffice can't store is an error (D-084, D-086).
# Since Phase 3 of the code review (D-102) they work on the chart object's XML.jl tree (charts/tree.jl).

#
# The elements and styles are found and changed in the object's tree (charts/tree.jl, D-102). An
# element is a path; a style is its name.
#

# Series `i`'s element (from 1).
function _series_start(o, i::Integer)
    ps = _tall(o, "chart:series")
    1 <= i <= length(ps) || throw(ODSError("The chart has $(length(ps)) series; there is no series $i."))
    return ps[i]
end

# An element's own automatic style (made, and given to it, when it has none or shares one).
function _own_style!(o, p::_Path)
    s = _tget(o, p, "chart:style-name")
    s !== nothing && _style_uses(o, s) == 1 && return s
    name = _clone_style!(o, s)              # in the automatic styles, so `p` (in the body) still holds
    _tset!(o, p, ["chart:style-name" => name])
    return name
end

# A style's property element (`element`), or nothing.
function _style_prop(o, style::AbstractString, element::AbstractString)
    q = _style_el(o, style)
    q === nothing && return nothing
    k = _tkids(o, q, element)
    return isempty(k) ? nothing : k[1]
end

# Removes attributes from a style's property element.
function _del_style_attrs!(o, style::AbstractString, keys; element = "style:chart-properties")
    e = _style_prop(o, style, element)
    e === nothing && return
    any(k -> _tget(o, e, k) !== nothing, keys) && _tset!(o, e, Pair{String,Union{Nothing,String}}[k => nothing for k in keys])
    return
end

# Sets (or, with `nothing`, removes) attributes of the element at `p`; values are text.
_set_tag_attrs!(o, p::_Path, attrs) = (_tset!(o, p, Pair{String,Union{Nothing,String}}[String(k) => v for (k, v) in attrs]); p)

_pts(x::Real) = _fmt_cm(x * 2.54 / 72)
_fmt_cm(x::Real) = string(round(x; digits = 3)) * "cm"

#
# Colours, fills and lines
#

const SCHEME_TOKENS = (:bg1, :tx1, :bg2, :tx2, :accent1, :accent2, :accent3, :accent4, :accent5, :accent6, :hlink,
                       :folHlink, :lt1, :dk1, :lt2, :dk2)
const COLOR_TRANSFORMS = (:lumMod, :lumOff, :shade, :tint, :satMod, :alpha)
const _SCHEME_ALIASES = Dict(:lt1 => :bg1, :dk1 => :tx1, :lt2 => :bg2, :dk2 => :tx2)

"""
    SchemeColor(token; lumMod = nothing, lumOff = nothing, satMod = nothing, shade = nothing, tint = nothing,
                alpha = nothing)
    SchemeColor(token, transforms)

A theme colour: a token (`:bg1`, `:tx1`, `:bg2`, `:tx2`, `:accent1` … `:accent6`, `:hlink`,
`:folHlink`, or the aliases `:lt1`, `:dk1`, `:lt2`, `:dk2`) and transforms in percent, applied in order.
It resolves to the document's theme (LibreOffice's, for a new document) and is written as LibreOffice's
theme reference, so LibreOffice follows a change of theme. LibreOffice keeps `lumMod`, `lumOff`,
`tint` and `shade`; `alpha` is a fill's transparency; `satMod` is an error.
"""
struct SchemeColor
    token::Symbol
    transforms::Vector{Pair{Symbol,Float64}}
    function SchemeColor(token::Symbol, transforms::Vector{Pair{Symbol,Float64}})
        token in SCHEME_TOKENS || throw(ODSError("`$token` is not a theme colour token: use " * join(SCHEME_TOKENS, ", ") * "."))
        for (k, v) in transforms
            k in COLOR_TRANSFORMS || throw(ODSError("`$k` is not a colour transform: use " * join(COLOR_TRANSFORMS, ", ") * "."))
            isfinite(v) || throw(ODSError("A colour transform is a number of percent, not `$v`."))
            # an opacity past 100 was written as a negative transparency
            k === :alpha && !(0 <= v <= 100) && throw(ODSError("`alpha` is an opacity, 0 to 100 percent, not $v."))
        end
        return new(token, transforms)
    end
end
function SchemeColor(token::Symbol; lumMod = nothing, lumOff = nothing, satMod = nothing, shade = nothing, tint = nothing,
                     alpha = nothing)
    t = Pair{Symbol,Float64}[]
    for (k, v) in ((:lumMod, lumMod), (:lumOff, lumOff), (:satMod, satMod), (:shade, shade), (:tint, tint), (:alpha, alpha))
        v === nothing || push!(t, k => Float64(v))
    end
    return SchemeColor(token, t)
end
_canonical_token(t::Symbol) = get(_SCHEME_ALIASES, t, t)
Base.:(==)(a::SchemeColor, b::SchemeColor) = _canonical_token(a.token) == _canonical_token(b.token) && a.transforms == b.transforms
Base.hash(a::SchemeColor, h::UInt) = hash(a.transforms, hash(_canonical_token(a.token), hash(:SchemeColor, h)))

const SchemeColorLike = Union{AbstractString,Symbol,SchemeColor}

# A colour value: (#rrggbb, opacity in percent or nothing). A theme colour is resolved against the
# document's theme, its transforms applied as LibreOffice's import applies them: LibreOffice keeps no
# theme reference in a chart, its own save writes the colour (experiment 039 B2).
function _color_value(xf, c; alpha::Bool = false)
    if c isa SchemeColor
        op = nothing
        for (k, v) in c.transforms
            k === :alpha || continue
            alpha || throw(ODSError("LibreOffice's chart text has no transparency: `alpha` is for fills and lines (D-086)."))
            op = round(Int, v)
        end
        return (_apply_transforms(_theme_colors(xf)[_THEME_TOKENS[getfield(c, :token)]], c.transforms), op)
    end
    c isa Colors.Colorant && return ("#" * lowercase(Colors.hex(c, :RRGGBB)), nothing)
    return (first(_color_spec(xf, c)), nothing)
end

# DrawingML's luminance and shade transforms on an RGB colour, as LibreOffice's import applies them.
function _apply_transforms(hex::AbstractString, ts)
    rgb = [parse(Int, hex[i:i+1]; base = 16) for i in (2, 4, 6)]
    hsl = nothing                                   # consecutive HSL transforms stay in HSL, as LibreOffice's
    for (k, v) in ts
        if k in (:lumMod, :lumOff, :satMod)         # on HSL's luminance and saturation
            h, s, l = hsl === nothing ? _hsl(rgb) : hsl
            k === :lumMod && (l *= v / 100)
            k === :lumOff && (l += v / 100)
            k === :satMod && (s *= v / 100)
            hsl = (h, clamp(s, 0, 1), clamp(l, 0, 1))
            continue
        end
        hsl === nothing || (rgb = _from_hsl(hsl...); hsl = nothing)
        if k in (:tint, :shade)                     # on linear RGB, as LibreOffice's import (experiment 039 B2)
            f = clamp(v / 100, 0, 1)
            rgb = map(rgb) do x
                c = _gamma(div(x * 100000, 255), 2.3)
                c = k === :tint ? trunc(Int, 100000 - (100000 - c) * f) : trunc(Int, c * f)
                div(_gamma(c, 1 / 2.3) * 255, 100000)
            end
        end
    end
    hsl === nothing || (rgb = _from_hsl(hsl...))
    return "#" * join(string(clamp(x, 0, 255); base = 16, pad = 2) for x in rgb)
end
_gamma(c::Integer, g) = trunc(Int, (c / 100000)^g * 100000 + 0.5)
function _hsl(rgb)
    r, g, b = rgb ./ 255
    mx, mn = max(r, g, b), min(r, g, b); l = (mx + mn) / 2; d = mx - mn
    s = d == 0 ? 0.0 : d / (1 - abs(2l - 1))
    h = d == 0 ? 0.0 : mx == r ? 60 * mod((g - b) / d, 6) : mx == g ? 60 * ((b - r) / d + 2) : 60 * ((r - g) / d + 4)
    return h, s, l
end
function _from_hsl(h, s, l)
    c = (1 - abs(2l - 1)) * s; x = c * (1 - abs(mod(h / 60, 2) - 1)); m = l - c / 2
    rr, gg, bb = h < 60 ? (c, x, 0) : h < 120 ? (x, c, 0) : h < 180 ? (0, c, x) : h < 240 ? (0, x, c) : h < 300 ? (x, 0, c) : (c, 0, x)
    return [round(Int, (v + m) * 255) for v in (rr, gg, bb)]
end

# Writes a fill on a style: a colour, `:none`, or `:inherit` (removed).
function _style_fill!(o, xf, st, color; transparency = nothing, gradient = nothing, gradientStyle::Symbol = :linear,
                     gradientAngle::Integer = 0, hatch = nothing, hatchAngle::Integer = 0)
    _del_style_attrs!(o, st, ["draw:fill", "draw:fill-color", "draw:opacity", "draw:fill-gradient-name", "draw:fill-hatch-name"];
                      element = "style:graphic-properties")
    _del_complex!(o, st, "fill")
    color === :inherit && return
    if color === :none
        _set_style_attrs!(o, st, ["draw:fill" => "none"]; element = "style:graphic-properties")
        return
    end
    col, a = _color_value(xf, color; alpha = true)
    attrs = ["draw:fill" => "solid", "draw:fill-color" => col]
    if gradient !== nothing                     # LibreOffice's gradient, from the colour to `gradient` (D-076)
        gradientStyle in _GRADIENT_STYLES || throw(ODSError("`gradientStyle` is " * Base.join(string.(":", _GRADIENT_STYLES), ", ") * "."))
        col2, _ = _color_value(xf, gradient)
        attrs = ["draw:fill" => "gradient", "draw:fill-color" => col,
                 "draw:fill-gradient-name" => _gradient_def!(o, col, col2, gradientStyle, mod(gradientAngle, 360))]
    elseif hatch !== nothing                    # LibreOffice's hatch, lines of the colour (D-076)
        hatch in _HATCH_STYLES || throw(ODSError("`hatch` is " * Base.join(string.(":", _HATCH_STYLES), ", ") * "."))
        attrs = ["draw:fill" => "hatch", "draw:fill-color" => col, "draw:fill-hatch-name" => _hatch_def!(o, col, hatch, mod(hatchAngle, 180))]
    end
    t = transparency === nothing ? (a === nothing ? nothing : 100 - a) : transparency
    t === nothing || t == 0 || push!(attrs, "draw:opacity" => "$(100 - t)%")
    _set_style_attrs!(o, st, attrs; element = "style:graphic-properties")
end

# Removes a theme reference an imported style holds (LibreOffice would draw it over the colour set).
function _del_complex!(o, st, kind)
    q = _style_el(o, st)
    q === nothing && return
    for p in reverse(_tall(o, "loext:" * kind * "-complex-color"; within = q))   # the last first: paths before it hold
        _tdelete!(o, p)
    end
end

# XLSX.jl's dash names (and Excel's aliases) as LibreOffice's import writes them (F-081): dots and gaps in
# percent of the line width.
const _DASH_ALIASES = Dict(:roundDot => :sysDot, :squareDot => :sysDash, :longDash => :lgDash, :longDashDot => :lgDashDot,
                           :longDashDotDot => :lgDashDotDot)
const _DASHES = Dict(:dot => (1, "1%", 0, "", "399%"), :dash => (1, "301%", 0, "", "399%"), :lgDash => (1, "701%", 0, "", "399%"),
    :dashDot => (1, "301%", 1, "1%", "399%"), :lgDashDot => (1, "701%", 1, "1%", "399%"), :lgDashDotDot => (1, "701%", 2, "1%", "399%"),
    :sysDash => (1, "201%", 0, "", "199%"), :sysDot => (1, "1%", 0, "", "199%"), :sysDashDot => (1, "201%", 1, "1%", "199%"),
    :sysDashDotDot => (1, "201%", 2, "1%", "199%"))

# The object's styles.xml text (made empty, with the dash), holding a dash definition named `name`.
function _ensure_dash!(o, d::Symbol)
    name = "odsfDash" * uppercasefirst(string(d))         # no "_": LibreOffice would rename it
    d1, l1, d2, l2, dist = _DASHES[d]
    return _put_def!(o, name, "<draw:stroke-dash draw:name=\"$name\" draw:display-name=\"$name\" draw:style=\"round\" draw:dots1=\"$d1\" draw:dots1-length=\"$l1\"" *
                              (d2 > 0 ? " draw:dots2=\"$d2\" draw:dots2-length=\"$l2\"" : "") * " draw:distance=\"$dist\"/>")
end

# A definition (a dash, gradient or hatch) in the object's styles.xml, made when it has none; returns its name.
function _put_def!(o, name::AbstractString, def::AbstractString)
    occursin("draw:name=\"$name\"", o.styles) && return name
    if isempty(o.styles)
        o.styles = """<?xml version="1.0" encoding="UTF-8"?><office:document-styles xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0" xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" xmlns:svg="urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0" xmlns:loext="urn:org:documentfoundation:names:experimental:office:xmlns:loext:1.0" office:version="1.4"><office:styles>$def</office:styles></office:document-styles>"""
    elseif occursin("</office:styles>", o.styles)
        o.styles = replace(o.styles, "</office:styles>" => def * "</office:styles>"; count = 1)
    elseif occursin("<office:styles/>", o.styles)
        o.styles = replace(o.styles, "<office:styles/>" => "<office:styles>" * def * "</office:styles>"; count = 1)
    else
        o.styles = replace(o.styles, r"(<office:document-styles\b[^>]*>)" => SubstitutionString("\1<office:styles>" * replace(def, "\\" => "\\\\") * "</office:styles>"); count = 1)
    end
    return name
end

const _GRADIENT_STYLES = (:linear, :axial, :radial, :ellipsoid, :square, :rectangular)
const _HATCH_STYLES = (:single, :double, :triple)

# A gradient (from `col` to `col2`) or hatch (lines of `col`) as LibreOffice writes them (experiment 039
# part A): named after their colours and settings, so alike fills share one definition.
function _gradient_def!(o, col, col2, style::Symbol, angle::Integer)
    name = "odsfGradient" * uppercasefirst(string(style)) * lstrip(col, '#') * lstrip(col2, '#') * string(angle)
    return _put_def!(o, name, "<draw:gradient draw:name=\"$name\" draw:display-name=\"$name\" draw:style=\"$style\" draw:start-color=\"$col\" " *
        "draw:end-color=\"$col2\" draw:start-intensity=\"100%\" draw:end-intensity=\"100%\" draw:angle=\"$(angle)deg\" draw:border=\"0%\">" *
        "<loext:gradient-stop svg:offset=\"0\" loext:color-type=\"rgb\" loext:color-value=\"$col\"/>" *
        "<loext:gradient-stop svg:offset=\"1\" loext:color-type=\"rgb\" loext:color-value=\"$col2\"/></draw:gradient>")
end
function _hatch_def!(o, col, style::Symbol, angle::Integer)
    name = "odsfHatch" * uppercasefirst(string(style)) * lstrip(col, '#') * string(angle)
    return _put_def!(o, name, "<draw:hatch draw:name=\"$name\" draw:display-name=\"$name\" draw:style=\"$style\" draw:color=\"$col\" " *
        "draw:distance=\"0.102cm\" draw:rotation=\"$(10angle)\"/>")
end

function _style_line!(o, xf, st; color = nothing, width = nothing, dash = nothing, cap = nothing, compound = nothing,
                      join = nothing, miterLimit = nothing, linked::Bool = false)
    compound === nothing || compound === :inherit ||
        throw(ODSError("LibreOffice's chart lines are single: compound lines can't be stored (D-086)."))
    join === nothing || join === :inherit || throw(ODSError("LibreOffice's chart lines have no join setting (D-086)."))
    miterLimit === nothing || miterLimit === :inherit || throw(ODSError("LibreOffice's chart lines have no miter limit (D-086)."))
    G = "style:graphic-properties"
    if color !== nothing
        _del_style_attrs!(o, st, ["svg:stroke-color", "svg:stroke-opacity"]; element = G); _del_complex!(o, st, "stroke")
        _own_stroke(o, st) == "none" && _del_style_attrs!(o, st, ["draw:stroke"]; element = G)
        if color === :none
            _set_style_attrs!(o, st, ["draw:stroke" => "none"]; element = G)
        elseif color !== :inherit
            col, a = _color_value(xf, color; alpha = true)
            _set_style_attrs!(o, st, ["svg:stroke-color" => col]; element = G)
            a === nothing || _set_style_attrs!(o, st, ["svg:stroke-opacity" => "$a%"]; element = G)
            _own_stroke(o, st) in ("none", nothing) && _set_style_attrs!(o, st, ["draw:stroke" => "solid"]; element = G)
            # a line series' one colour: its symbols' too (LibreOffice's series colour, experiment 039 B)
            linked && (_del_complex!(o, st, "fill"); _set_style_attrs!(o, st, ["draw:fill-color" => col]; element = G))
        end
    end
    if width !== nothing
        _del_style_attrs!(o, st, ["svg:stroke-width"]; element = G)
        if width !== :inherit
            width isa Real && 0 <= width <= 1584 || throw(ODSError("A line's width is 0 to 1584 points."))
            _set_style_attrs!(o, st, ["svg:stroke-width" => _pts(width)]; element = G)
        end
    end
    if dash !== nothing
        _del_style_attrs!(o, st, ["draw:stroke-dash"]; element = G)
        d = Symbol(dash)
        if d === :inherit || d === :solid
            _own_stroke(o, st) == "dash" && _set_style_attrs!(o, st, ["draw:stroke" => "solid"]; element = G)
        else
            d = get(_DASH_ALIASES, d, d)
            haskey(_DASHES, d) || throw(ODSError("Unknown dash `$dash`: use :solid, $(Base.join(string.(":", sort!(collect(Base.keys(_DASHES)))), ", "))."))
            _set_style_attrs!(o, st, ["draw:stroke" => "dash", "draw:stroke-dash" => _ensure_dash!(o, d)]; element = G)
        end
    end
    if cap !== nothing
        _del_style_attrs!(o, st, ["svg:stroke-linecap"]; element = G)
        if cap !== :inherit
            k = Symbol(cap); k = get(_CAP_ALIASES, k, k)
            haskey(_CAPS_ODF, k) || throw(ODSError("Unknown cap `$cap`: use :rnd, :sq or :flat."))
            _set_style_attrs!(o, st, ["svg:stroke-linecap" => _CAPS_ODF[k]]; element = G)
        end
    end
end

_series_style!(o, i) = _own_style!(o, _series_start(o, i))
# A style's own attribute (of its property element), or nothing.
function _style_attr(o, st, key; element = "style:graphic-properties")
    e = _style_prop(o, st, element)
    return e === nothing ? nothing : _tget(o, e, key)
end
_own_stroke(o, st) = _style_attr(o, st, "draw:stroke")

"""
    setSeriesFill(c::AbstractChart, i, color; transparency = nothing, gradient = nothing, gradientStyle = :linear,
gradientAngle = 0, hatch = nothing, hatchAngle = 0) -> Chart

Series `i`'s fill: a colour (hex, a colour name, a theme colour such as `:accent1` or a
[`SchemeColor`](@ref)), `:none`, or `:inherit` (LibreOffice's default). Also:
`transparency`, 0 to 100 percent; a gradient from `color` to `gradient` (another colour), of
`gradientStyle` (`:linear`, `:axial`, `:radial`, `:ellipsoid`, `:square`, `:rectangular`) at
`gradientAngle` degrees; or a `hatch` (`:single`, `:double`, `:triple`) of lines of `color` at `hatchAngle`
degrees. A line, XY or radar series has one colour, its line's and its symbols' (LibreOffice's): its fill
is its line colour, and `:none`, transparency, gradients and hatches are errors.
"""
function setSeriesFill(c::AbstractChart, i::Integer, color::Union{SchemeColorLike,Colors.Colorant}; transparency::Union{Nothing,Integer} = nothing,
gradient = nothing, gradientStyle::Symbol = :linear, gradientAngle::Integer = 0, hatch = nothing,
hatchAngle::Integer = 0)
    transparency === nothing || 0 <= transparency <= 100 || throw(ODSError("`transparency` is 0 to 100 percent."))
    o = _editable(c)
    if _line_like(o, i)
        # a line, XY or radar series has one colour, its line's and its symbols' (LibreOffice's series colour)
        color in (:none, :inherit) && throw(ODSError("LibreOffice draws a line series' symbols in its line colour: it has no fill of its own to remove (D-086)."))
        (transparency === nothing && gradient === nothing && hatch === nothing) ||
throw(ODSError("LibreOffice's line series have one colour: no fill transparency, gradient or hatch (D-086)."))
        _style_line!(o, c.package, _series_style!(o, i); color, linked = true)
    else
        _style_fill!(o, c.package, _series_style!(o, i), color; transparency, gradient, gradientStyle, gradientAngle, hatch, hatchAngle)
    end
    return c
end

# Whether series `i` is a line, XY or radar series: one colour for its line and symbols (LibreOffice's).
function _line_like(o, i)
    return something(_tget(o, _series_start(o, i), "chart:class"), _chart_class(o)) in ("chart:line", "chart:scatter", "chart:radar")
end

"""
    setSeriesLine(c::AbstractChart, i; color, width, dash, cap, compound, join, miterLimit) -> Chart
    setSeriesLine(c::AbstractChart, i, :none | :inherit) -> Chart
    setSeriesLineColor / setSeriesLineWidth / setSeriesLineDash / setSeriesLineCap(c, i, value) -> Chart
    setSeriesLineCompound / setSeriesLineJoin / setSeriesLineMiterLimit(c, i, value) -> error

Series `i`'s line: a colour, a width in points, a dash (`:solid`, `:dot`, `:dash`, `:lgDash` (long),
`:dashDot`, `:lgDashDot`, `:lgDashDotDot`, `:sysDash`, `:sysDot`, `:sysDashDot`, `:sysDashDotDot`;
the `sys` ones are denser), a cap (`:rnd` round, `:sq` square, `:flat`). LibreOffice's chart lines have no
compound lines, joins or miter limits: those are errors.
"""
function setSeriesLine(c::AbstractChart, i::Integer; color = nothing, width = nothing, dash = nothing, cap = nothing,
                       compound = nothing, join = nothing, miterLimit = nothing)
    o = _editable(c)
    _style_line!(o, c.package, _series_style!(o, i); color, width, dash, cap, compound, join, miterLimit, linked = _line_like(o, i))
    return c
end
setSeriesLine(c::AbstractChart, i::Integer, v::Symbol) =
    v === :none ? setSeriesLine(c, i; color = :none) : v === :inherit ? setSeriesLine(c, i; color = :inherit, width = :inherit, dash = :inherit, cap = :inherit) :
    throw(ODSError("Use :none or :inherit, or the keywords."))
setSeriesLineColor(c::AbstractChart, i::Integer, v) = setSeriesLine(c, i; color = v)
setSeriesLineWidth(c::AbstractChart, i::Integer, v) = setSeriesLine(c, i; width = v)
setSeriesLineDash(c::AbstractChart, i::Integer, v) = setSeriesLine(c, i; dash = v)
setSeriesLineCap(c::AbstractChart, i::Integer, v) = setSeriesLine(c, i; cap = v)
setSeriesLineCompound(c::AbstractChart, i::Integer, v) = setSeriesLine(c, i; compound = v)
setSeriesLineJoin(c::AbstractChart, i::Integer, v) = setSeriesLine(c, i; join = v)
setSeriesLineMiterLimit(c::AbstractChart, i::Integer, v) = setSeriesLine(c, i; miterLimit = v)

#
# Markers
#

# A point's own element and style (point from 1): the run of `chart:data-point` holding it is split
# (`chart:repeated`). LibreOffice writes a series' points after its trendlines and error bars.
function _point_style!(o, i::Integer, point::Integer)
    point >= 1 || throw(ODSError("Points are numbered from 1."))
    sp = _series_start(o, i)
    series = _tnode(o, sp)
    # each point (attributes but `chart:repeated`, children), and the series' other children
    pts = Tuple{Vector{Pair{String,String}},Vector{Any}}[]
    others = Any[]
    for c in XML.children(series)
        if _isel(c) && XML.tag(c) == "chart:data-point"
            rep = something(tryparse(Int, something(_tattr(c, "chart:repeated"), "1")), 1)
            attrs = filter(p -> p.first != "chart:repeated", _tpairs(c))
            kids = collect(XML.children(c))
            for r in 1:max(rep, 1)                   # each its own nodes (they are changed in place)
                push!(pts, (copy(attrs), r == 1 ? kids : Any[_tcopy(x) for x in kids]))
            end
        else
            push!(others, c)
        end
    end
    n = _series_length(o, i)
    while length(pts) < max(point, n)
        push!(pts, (Pair{String,String}[], Any[]))
    end
    attrs = pts[point][1]                            # changed in place below
    k = findfirst(p -> p.first == "chart:style-name", attrs)
    sname = k === nothing ? nothing : attrs[k].second
    if sname === nothing || _style_uses(o, sname) > 1 || count(p -> any(==("chart:style-name" => sname), p[1]), pts) > 1
        sname = _clone_style!(o, sname)               # in the automatic styles: the series' path holds
        k === nothing ? push!(attrs, "chart:style-name" => sname) : (attrs[k] = "chart:style-name" => sname)
    end
    # written back, runs of alike points (without children) merged
    newpts = Any[]
    k = 1
    while k <= length(pts)
        j = k
        while j < length(pts) && pts[j+1] == pts[k] && isempty(pts[k][2])
            j += 1
        end
        a = j > k ? [pts[k][1]; "chart:repeated" => string(j - k + 1)] : pts[k][1]
        push!(newpts, XML.Element("chart:data-point", pts[k][2]...; (Symbol(x) => y for (x, y) in a)...))
        k = j + 1
    end
    # LibreOffice writes a series' points after its trendlines and error bars, and its own label last
    l = findfirst(c -> _isel(c) && XML.tag(c) == "chart:data-label", others)
    kids = l === nothing ? vcat(others, newpts) : vcat(others[1:l-1], newpts, others[l:end])
    _treplace!(o, sp, _telement(series, _tpairs(series), kids))
    return sname
end

# How many values series `i` has (its values range's cells), for the points written out.
function _series_length(o, i)
    v = _tget(o, _series_start(o, i), "chart:values-cell-range-address")
    v === nothing && return 0
    return sum((length(r) * length(c) for (_, r, c) in _range_areas(v) if r !== nothing); init = 0)
end

# A new automatic style: a copy of `old` (its data style too), or empty.
function _clone_style!(o, old::Union{Nothing,AbstractString})
    name = _next_style_name(o)
    q = old === nothing ? nothing : _style_el(o, old)
    st = if q === nothing
        XML.Element("style:style"; Symbol("style:name") => name, Symbol("style:family") => "chart")
    else
        n = _tnode(o, q)
        a = [(k == "style:name" ? k => name : k => v) for (k, v) in _tpairs(n)]
        _telement(n, a, [_tcopy(c) for c in XML.children(n)])
    end
    _tappend!(o, _auto_styles(o), st)
    return name
end


function _set_marker!(o, st, symbol, size)
    if symbol !== nothing
        _del_style_attrs!(o, st, ["chart:symbol-type", "chart:symbol-name"])
        if symbol === :none
            _set_style_attrs!(o, st, ["chart:symbol-type" => "none"])
        elseif symbol === :auto
            _set_style_attrs!(o, st, ["chart:symbol-type" => "automatic"])
        elseif symbol !== :inherit
            haskey(_MARKERS, symbol) || throw(ODSError("Unknown marker `:$symbol`: use $(join(string.(":", sort!(collect(keys(_MARKERS)))), ", ")), :none or :auto."))
            attrs = ["chart:symbol-type" => "named-symbol", "chart:symbol-name" => _MARKERS[symbol]]
            _style_attr(o, st, "chart:symbol-width"; element = "style:chart-properties") !== nothing ||
                append!(attrs, ["chart:symbol-width" => "0.25cm", "chart:symbol-height" => "0.25cm"])
            _set_style_attrs!(o, st, attrs)
        end
    end
    if size !== nothing
        _del_style_attrs!(o, st, ["chart:symbol-width", "chart:symbol-height"])
        if size !== :inherit
            size isa Real && 2 <= size <= 72 || throw(ODSError("A marker's size is 2 to 72 points."))
            v = _pts(round(Int, size))
            _set_style_attrs!(o, st, ["chart:symbol-width" => v, "chart:symbol-height" => v])
        end
    end
end

function _check_marker_series(o, i)
    _line_like(o, i) || throw(ODSError("Markers are for line, XY and radar series."))
end

"""
    setMarker(c::AbstractChart, i; point = nothing, symbol = nothing, size = nothing, fill = nothing, lineColor = nothing,
              lineWidth = nothing) -> Chart
    setMarkerSymbol(c, i, symbol; point = nothing) / setMarkerSize(c, i, size; point = nothing) -> Chart
    setMarkerFill / setMarkerLineColor / setMarkerLineWidth(c, i, value; point = nothing) -> error

A line, XY or radar series' (or point's, from 1) symbol and size (2 to 72 points). Symbols are
`:circle`, `:square`, `:diamond`, `:triangle`, `:x`, `:plus`, `:star`, `:dash`, `:dot`,
`:none`, `:auto`, `:arrowDown`, `:arrowLeft`, `:bowTie`, `:hourglass`, `:loStar` and `:vBar`. LibreOffice draws a symbol in its series' colours: a fill or border of its own is an error.
"""
function setMarker(c::AbstractChart, i::Integer; point = nothing, symbol = nothing, size = nothing, fill = nothing,
                   lineColor = nothing, lineWidth = nothing)
    (fill === nothing && lineColor === nothing && lineWidth === nothing) ||
        throw(ODSError("LibreOffice draws a marker in its series' colours: it has no fill or border of its own (D-086). Set the series' with `setSeriesFill`."))
    o = _editable(c)
    _check_marker_series(o, i)
    st = point === nothing ? _series_style!(o, i) : _point_style!(o, i, point)
    _set_marker!(o, st, symbol, size)
    return c
end
setMarkerSymbol(c::AbstractChart, i::Integer, v::Symbol; point = nothing) = setMarker(c, i; point, symbol = v)
setMarkerSize(c::AbstractChart, i::Integer, v; point = nothing) = setMarker(c, i; point, size = v)
setMarkerFill(c::AbstractChart, i::Integer, v; point = nothing) = setMarker(c, i; point, fill = v)
setMarkerLineColor(c::AbstractChart, i::Integer, v; point = nothing) = setMarker(c, i; point, lineColor = v)
setMarkerLineWidth(c::AbstractChart, i::Integer, v; point = nothing) = setMarker(c, i; point, lineWidth = v)

#
# Text properties (the field table every text setter shares)
#

const _UNDER_ODF = Dict(:sng => ("solid", "single", "auto"), :dbl => ("solid", "double", "auto"), :heavy => ("solid", "single", "bold"),
    :dotted => ("dotted", "single", "auto"), :dottedHeavy => ("dotted", "single", "bold"), :dash => ("dash", "single", "auto"),
    :dashHeavy => ("dash", "single", "bold"), :dashLong => ("long-dash", "single", "auto"), :dashLongHeavy => ("long-dash", "single", "bold"),
    :dotDash => ("dot-dash", "single", "auto"), :dotDashHeavy => ("dot-dash", "single", "bold"), :dotDotDash => ("dot-dot-dash", "single", "auto"),
    :dotDotDashHeavy => ("dot-dot-dash", "single", "bold"), :wavy => ("wave", "single", "auto"), :wavyHeavy => ("wave", "single", "bold"),
    :wavyDbl => ("wave", "double", "auto"), :single => ("solid", "single", "auto"), :double => ("solid", "double", "auto"))
const _TEXT_FIELDS = (:size, :bold, :italic, :under, :underline, :strike, :strikethrough, :caps, :baseline, :kern, :spacing,
                      :fill, :color, :line, :latin, :font, :ea, :cs, :lang)

# The attributes of one text field (or the attributes to remove, for `:inherit`).
function _text_attrs(xf, field::Symbol, v)
    field in _TEXT_FIELDS || throw(ODSError("Unknown text property `:$field`: use $(join(string.(":", _TEXT_FIELDS), ", "))."))
    field === :underline && (field = :under); field === :strikethrough && (field = :strike)
    field === :color && (field = :fill); field === :font && (field = :latin)
    field === :caps && throw(ODSError("LibreOffice's chart text has no capitals setting (D-086)."))
    field === :kern && throw(ODSError("LibreOffice's chart text has no kerning size (D-086)."))
    field === :line && throw(ODSError("LibreOffice's chart text outline has no colour or width (D-086)."))
    ks = field === :size ? _font_keys("fo:font-size") : field === :bold ? _font_keys("fo:font-weight") :
           field === :italic ? _font_keys("fo:font-style") :
           field === :under ? ["style:text-underline-style", "style:text-underline-type", "style:text-underline-width", "style:text-underline-color"] :
           field === :strike ? ["style:text-line-through-style", "style:text-line-through-type"] :
           field === :baseline ? ["style:text-position"] : field === :spacing ? ["fo:letter-spacing"] :
           field === :fill ? ["fo:color"] : field === :latin ? ["fo:font-family", "style:font-name"] :
           field === :ea ? ["style:font-family-asian", "style:font-name-asian"] :
           field === :cs ? ["style:font-family-complex", "style:font-name-complex"] : ["fo:language", "fo:country"]
    v === :inherit && return ks, Pair{String,String}[]
    attrs = if field === :size
        v isa Real && v > 0 || throw(ODSError("`:size` is a size in points."))
        p = string(v) * "pt"; [ks[1] => p, ks[2] => p, ks[3] => p]
    elseif field in (:bold, :italic)
        v isa Bool || throw(ODSError("`:$field` is true or false."))
        w = field === :bold ? (v ? "bold" : "normal") : (v ? "italic" : "normal"); [k => w for k in ks]
    elseif field === :under
        u = v === true ? :sng : v === false ? :none : Symbol(v)
        u === :none ? [ks[1] => "none"] : haskey(_UNDER_ODF, u) ?
            (t = _UNDER_ODF[u]; [ks[1] => t[1], ks[2] => t[2], ks[3] => t[3], ks[4] => "font-color"]) :
            throw(ODSError("Unknown underline `$v`: use $(join(string.(":", sort!(collect(Base.keys(_UNDER_ODF)))), ", ")), :none or a Bool."))
    elseif field === :strike
        s = v === true ? :sngStrike : v === false ? :noStrike : Symbol(v)
        s in (:noStrike, :none) ? [ks[1] => "none"] : s in (:sngStrike, :single) ? [ks[1] => "solid", ks[2] => "single"] :
        s in (:dblStrike, :double) ? [ks[1] => "solid", ks[2] => "double"] : throw(ODSError("Unknown strike-through `$v`."))
    elseif field === :baseline
        v isa Real || throw(ODSError("`:baseline` is a fraction of the font size."))
        [ks[1] => "$(round(Int, 100v))% 58%"]
    elseif field === :spacing
        v isa Real || throw(ODSError("`:spacing` is in points.")); [ks[1] => _pts(v)]
    elseif field === :fill
        col, _ = _color_value(xf, v)
        return ks, [ks[1] => col]
    elseif field in (:latin, :ea, :cs)
        f = String(v)
        f in ("+mn-lt", "+mj-lt", "+mn-ea", "+mj-ea", "+mn-cs", "+mj-cs") && (f = "Liberation Sans")   # LibreOffice's default font
        [ks[1] => f]
    else
        l = split(String(v), '-'); length(l) == 2 || throw(ODSError("`:lang` is a language tag such as \"de-DE\"."))
        [ks[1] => l[1], ks[2] => l[2]]
    end
    return ks, attrs
end

function _style_text!(o, xf, st, field::Symbol, v)
    ks, attrs = _text_attrs(xf, field, v)
    T = "style:text-properties"
    _del_style_attrs!(o, st, ks; element = T)
    isempty(attrs) || _set_style_attrs!(o, st, attrs; element = T)
    if field in (:fill, :color)
        _del_complex!(o, st, "char")
    end
end

# The chart's element, and its title (a child of the chart, before the plot area), or nothing.
_chart_el(o) = (p = _tfirst(o, "chart:chart"); p === nothing && throw(ODSError("The object holds no chart.")); p)
_chart_title(o) = (t = _tkids(o, _chart_el(o), "chart:title"); isempty(t) ? nothing : t[1])
_title_tag(o) = (t = _chart_title(o); t === nothing && throw(ODSError("The chart has no title: set one with `setChartTitleText`.")); t)
_legend_tag(o) = (p = _tfirst(o, "chart:legend"); p === nothing && throw(ODSError("The chart has no legend: set one with `setLegendPos`.")); p)
# An axis' title (its first child), or nothing.
_axis_title(o, p::_Path) = (k = _tkids(o, p); !isempty(k) && _ttag(o, k[1]) == "chart:title" ? k[1] : nothing)

"""
    setChartTitleTextProp(c, field, value) / setAxisTitleTextProp(c, ax, field, value) / setLegendTextProp(c, field, value)
    setAxisTextProp(c, ax, field, value) / setLabelTextProp(c, i, field, value) / setLabelTextProp(c, i, point, field, value)
    setGroupLabelTextProp(c, g, field, value) / setChartSpaceTextProp(c, field, value) -> Chart

One text property of a part of the chart. Fields: `:size` (points), `:bold`, `:italic`, `:under`
(`:underline`), `:strike` (`:strikethrough`), `:baseline` (a fraction of the size), `:spacing`
(points), `:fill` (`:color`), `:latin` (`:font`), `:ea`, `:cs`, `:lang`; `:inherit` removes one.
LibreOffice's chart text has no capitals setting, kerning size or coloured outline: `:caps`, `:kern`
and `:line` are errors. The chart space's text (`setChartSpaceTextProp`) is set on its series'
labels.
"""
setChartTitleTextProp(c::AbstractChart, field::Symbol, v) = (o = _editable(c); _style_text!(o, c.package, _own_style!(o, _title_tag(o)), field, v); c)
setLegendTextProp(c::AbstractChart, field::Symbol, v) = (o = _editable(c); _style_text!(o, c.package, _own_style!(o, _legend_tag(o)), field, v); c)
function setAxisTitleTextProp(c::AbstractChart, ax, field::Symbol, v)
    o = _editable(c)
    t = _axis_title(o, _axis_tag(o, c, ax))
    t === nothing && throw(ODSError("The axis has no title: set one with `setAxisTitleText`."))
    _style_text!(o, c.package, _own_style!(o, t), field, v)
    return c
end
setAxisTextProp(c::AbstractChart, ax, field::Symbol, v) = (o = _editable(c); _style_text!(o, c.package, _own_style!(o, _axis_tag(o, c, ax)), field, v); c)
setLabelTextProp(c::AbstractChart, i::Integer, field::Symbol, v) = (o = _editable(c); _style_text!(o, c.package, _series_style!(o, i), field, v); c)
setLabelTextProp(c::AbstractChart, i::Integer, point::Integer, field::Symbol, v) =
    (o = _editable(c); _style_text!(o, c.package, _point_style!(o, i, point), field, v); c)
function setGroupLabelTextProp(c::AbstractChart, g::ChartGroup, field::Symbol, v)
    doc = _doc(c)
    for (i, s) in enumerate(_series_nodes(doc))
        ChartGroup(_series_tag(doc, s), _series_axids(s), nothing) == g && setLabelTextProp(c, i, field, v)
    end
    return c
end
setChartSpaceTextProp(c::AbstractChart, field::Symbol, v) = (foreach(i -> setLabelTextProp(c, i, field, v), 1:length(_series_nodes(_doc(c)))); c)

# An axis' element: one of the plot area's `chart:axis` children, by its id.
function _axis_tag(o, c, ax)
    a = getChartAxis(c, ax)
    pa = _tfirst(o, "chart:plot-area")
    k = pa === nothing ? nothing : findfirst(p -> _axis_id(_tnode(o, p)) == a.axid, _tkids(o, pa, "chart:axis"))
    k === nothing && throw(ODSError("The chart has no axis `$ax`."))
    return _tkids(o, pa, "chart:axis")[k]
end
_axis_style!(o, c, ax) = _own_style!(o, _axis_tag(o, c, ax))

#
# Titles, legend and plot area
#

"""
    setChartTitleText(c, text) -> Chart
    setAxisTitleText(c, ax, text) -> Chart

The chart's (or an axis') title: a string (a line break starts a paragraph) or a `DrawingText`.
LibreOffice's titles can't follow a cell: a `CellRef` is an error.
"""
function setChartTitleText(c::AbstractChart, text)
    o = _editable(c)
    paras = _tfrag(_title_xml(text, o, c.package))       # its text styles go in the automatic styles
    t = _chart_title(o)
    if t !== nothing
        _treplace!(o, t, _title_element(_tget(o, t, "chart:style-name"), paras))   # its position goes: placed anew
    else
        st = _add_style!(o, """<style:chart-properties chart:auto-position="true"/>""" * _text_pt(13))
        _tinsert!(o, _chart_el(o), 1, _title_element(st, paras))
    end
    return c
end
function setAxisTitleText(c::AbstractChart, ax, text)
    o = _editable(c)
    paras = _tfrag(_title_xml(text, o, c.package))
    p = _axis_tag(o, c, ax)
    t = _axis_title(o, p)
    if t !== nothing
        _treplace!(o, t, _title_element(_tget(o, t, "chart:style-name"), paras))
    else
        rot = getChartAxis(c, ax).pos in (:l, :r) ? " style:rotation-angle=\"90\"" : ""
        st = _add_style!(o, """<style:chart-properties chart:auto-position="true"$rot/>""" * _text_pt(11))
        _tinsert!(o, p, 1, _title_element(st, paras))
    end
    return c
end
_title_element(st, paras) = XML.Element("chart:title", paras...; (st === nothing ? () : (Symbol("chart:style-name") => st,))...)
# A rich title's paragraphs (D-088): a span per run with attributes, its text style (`style:family="text"`)
# in the object's automatic styles, as LibreOffice's import writes one (F-087); the font as
# `fo:font-family`, and colours as their RGB (LibreOffice keeps no theme link in a chart, F-085).
function _rich_title_paras(o, rts::RichTextString)
    io = IOBuffer()
    print(io, "<text:p>")
    for run in rts.runs
        props = _chart_run_props(run)
        name = isempty(props) ? "" : _chart_text_style!(o, props)
        for (k, part) in enumerate(split(replace(run.text, "\r\n" => "\n"), '\n'))
            k > 1 && print(io, "</text:p><text:p>")
            isempty(part) && continue
            isempty(name) ? print(io, _esct(part)) : print(io, "<text:span text:style-name=\"", name, "\">", _esct(part), "</text:span>")
        end
    end
    print(io, "</text:p>")
    return replace(String(take!(io)), "<text:p></text:p>" => "<text:p/>")
end

function _chart_run_props(run::RichTextRun)
    a = run.atts
    a === nothing && return ""
    p = Pair{String,String}[]
    get(a, :bold, false) in (true, 1) && append!(p, [k => "bold" for k in _font_keys("fo:font-weight")])
    get(a, :italic, false) in (true, 1) && append!(p, [k => "italic" for k in _font_keys("fo:font-style")])
    get(a, :under, false) in (true, 1) && append!(p, ["style:text-underline-style" => "solid", "style:text-underline-width" => "auto",
                                                       "style:text-underline-color" => "font-color"])
    get(a, :strike, false) in (true, 1) && append!(p, ["style:text-line-through-style" => "solid", "style:text-line-through-type" => "single"])
    v = get(a, :vertAlign, nothing)
    v == "superscript" && push!(p, "style:text-position" => "super 58%")
    v == "subscript" && push!(p, "style:text-position" => "sub 58%")
    c = get(a, :color, nothing)
    c === nothing || push!(p, "fo:color" => SheetCore.odf_color(c))
    s = get(a, :size, nothing)
    if s !== nothing
        # a Rational was written as `21//2pt`
        s isa Real && isfinite(s) && s > 0 || throw(ODSError("A text size is a positive number of points, not `$s`."))
        sz = _num_text(s) * "pt"
        append!(p, [k => sz for k in _font_keys("fo:font-size")])
    end
    n = get(a, :name, nothing)
    n === nothing || push!(p, "fo:font-family" => (occursin(' ', n) ? "'$n'" : String(n)))
    return join(" $k=\"$(_esc(v))\"" for (k, v) in p)
end

# The object's text style with `props`, made (`T1`, `T2`, …) when it has none.
function _chart_text_style!(o, props::AbstractString)
    want = _tpairs(_tfrag1("<x$props/>"))                 # `props`: ` k="v"` pairs, as written
    a = _auto_styles(o)
    for q in _tkids(o, a, "style:style")
        _tget(o, q, "style:family") == "text" || continue
        k = _tkids(o, q)
        length(k) == 1 && _ttag(o, k[1]) == "style:text-properties" && _tpairs(_tnode(o, k[1])) == want &&
            return _tget(o, q, "style:name")
    end
    names = Set{String}(); _teach(c -> (n = _tattr(c, "style:name"); n === nothing || push!(names, n)), o)
    k = 1
    while "T$k" in names
        k += 1
    end
    _tappend!(o, a, _tfrag1("<style:style style:name=\"T$k\" style:family=\"text\"><style:text-properties$props/></style:style>"))
    return "T$k"
end

function _title_xml(text, o, xf)
    text isa RichTextString && return _rich_title_paras(o, text)
    text isa AbstractString && return _title_paras(text)
    text isa DrawingText || throw(ODSError("LibreOffice's titles can't follow a cell (F-081, D-086): give the text."))
    io = IOBuffer()
    for p in text.paragraphs
        print(io, "<text:p>")
        for r in p.runs
            if r.kind === :br
                print(io, "<text:line-break/>")
                continue
            end
            props = r.props === nothing ? "" : _drawing_run_props(xf, r.props)
            t = _esct(something(r.text, ""))
            isempty(props) ? print(io, t) : print(io, "<text:span text:style-name=\"", _chart_text_style!(o, props), "\">", t, "</text:span>")
        end
        print(io, "</text:p>")
    end
    return String(take!(io))
end

# A DrawingML run's properties as a text style's (the text property setters' fields): every set field
# is kept, and LibreOffice's refusals (caps, kerning, an outline) are errors (D-086).
function _drawing_run_props(xf, rp::DrawingRunProps)
    out = Pair{String,String}[]
    for (field, v) in ((:size, rp.size), (:bold, rp.bold), (:italic, rp.italic), (:under, rp.under === nothing ? nothing : Symbol(rp.under)),
                       (:strike, rp.strike === nothing ? nothing : Symbol(rp.strike)), (:caps, rp.caps), (:baseline, rp.baseline),
                       (:kern, rp.kern), (:spacing, rp.spacing), (:line, rp.line), (:latin, rp.latin), (:ea, rp.ea), (:cs, rp.cs), (:lang, rp.lang),
                       (:fill, rp.fill === nothing || rp.fill.fgcolor === nothing ? nothing : "#" * rp.fill.fgcolor.rgb))
        v === nothing && continue
        _, attrs = _text_attrs(xf, field, v)
        append!(out, attrs)
    end
    return join(" $k=\"$(_esc(v))\"" for (k, v) in out)
end

const _LEGEND_ODF = Dict(:b => "bottom", :bottom => "bottom", :t => "top", :top => "top", :l => "start", :left => "start",
    :r => "end", :right => "end")
# The corners: LibreOffice has no corner positions (it reads `top-end` as `end`), so a corner is a
# custom position, as its import writes `:tr` (F-081): beside the side, in the corner, sized to the
# entries (LibreOffice sizes it again as it draws).
const _LEGEND_CORNERS = Dict(:tr => (:r, :t), :topRight => (:r, :t), :tl => (:l, :t), :topLeft => (:l, :t),
    :bl => (:l, :b), :bottomLeft => (:l, :b), :br => (:r, :b), :bottomRight => (:r, :b))

"""
    setLegendPos(c, pos; overlay = nothing, expansion = nothing) -> Chart
    setLegendOverlay(c, overlay) -> Chart
    setLegendEntryDeleted(c, positions, deleted) -> Chart

The legend's place: `:b` (bottom), `:t`, `:l`, `:r`, and the corners `:tr`, `:tl`, `:bl`, `:br`; a
corner is a custom position in that corner of the chart.
`:inherit` removes the position, which LibreOffice reads as `:r`. Whether the legend may overlap the
plot area, and the series whose entries are hidden. The first two make a legend if the chart has none.
`expansion` shapes the legend: `:wide`, `:high` or `:balanced` (not for a corner).
"""
function setLegendPos(c::AbstractChart, pos::Symbol; overlay = nothing, expansion = nothing)
    corner = get(_LEGEND_CORNERS, pos, nothing)
    pos === :inherit || haskey(_LEGEND_ODF, pos) || corner !== nothing ||
        throw(ODSError("Unknown legend position `:$pos`: use :b, :t, :l, :r, :tr, :tl, :bl, :br or :inherit."))
    exp = expansion === nothing ? nothing : expansion in (:wide, :high, :balanced) ? string(expansion) :
          throw(ODSError("`expansion` is :wide, :high or :balanced."))
    corner !== nothing && exp !== nothing && throw(ODSError("A legend in a corner is a custom position: it takes no `expansion`."))
    o = _editable(c)
    attrs = Pair{String,Union{Nothing,String}}["svg:x" => nothing, "svg:y" => nothing, "svg:width" => nothing,
        "svg:height" => nothing, "style:legend-expansion-aspect-ratio" => nothing]
    if corner === nothing
        push!(attrs, "chart:legend-position" => pos === :inherit ? nothing : _LEGEND_ODF[pos])
        _style_attr_legend(o) == "custom" && push!(attrs, "style:legend-expansion" => nothing)
        exp === nothing || push!(attrs, "style:legend-expansion" => exp)
    else
        W, H = _chart_size(c)
        names = [something(s.name, "") for s in getChartSeries(c)]
        w = round(0.5 + 0.16 * maximum(length, names; init = 1); digits = 3)
        h = round(0.486 * max(length(names), 1); digits = 3)
        x = corner[1] === :r ? max(W - w, 0.0) : 0.0
        y = corner[2] === :b ? max(H - h, 0.0) : 0.0
        append!(attrs, ["chart:legend-position" => corner[1] === :r ? "end" : "start", "svg:x" => _fmt_cm(x), "svg:y" => _fmt_cm(y),
                        "style:legend-expansion" => "custom", "svg:width" => _fmt_cm(w), "svg:height" => _fmt_cm(h),
                        "style:legend-expansion-aspect-ratio" => string(w / h)])
    end
    overlay === nothing || push!(attrs, "loext:overlay" => overlay === :inherit ? nothing : string(Bool(overlay)))
    _set_tag_attrs!(o, _legend_or_new!(o), attrs)
    # a custom position holds only where LibreOffice doesn't place the legend itself
    _set_style_attrs!(o, _own_style!(o, _legend_or_new!(o)), ["chart:auto-position" => string(corner === nothing)])
    return c
end
_style_attr_legend(o) = (p = _tfirst(o, "chart:legend"); p === nothing ? nothing : _tget(o, p, "style:legend-expansion"))
setLegendOverlay(c::AbstractChart, overlay::Union{Bool,Symbol}) =
    (o = _editable(c); _set_tag_attrs!(o, _legend_or_new!(o), ["loext:overlay" => overlay === :inherit ? nothing : string(Bool(overlay))]); c)
# The legend's start tag, a legend made (on the right, as LibreOffice's) when there is none.
function _legend_or_new!(o)
    p = _tfirst(o, "chart:legend")
    p === nothing || return p
    st = _add_style!(o, """<style:chart-properties chart:auto-position="true"/>""" * _TEXT10)
    _insert_before!(o, "<chart:plot-area", "<chart:legend chart:legend-position=\"end\" svg:x=\"0cm\" svg:y=\"0cm\" chart:style-name=\"$st\"/>")
    return _tfirst(o, "chart:legend")
end
function setLegendEntryDeleted(c::AbstractChart, positions, deleted::Union{Bool,Symbol})
    # any other Symbol showed the entries
    deleted isa Symbol && deleted !== :inherit && throw(ODSError("`deleted` is true, false or :inherit, not `:$deleted`."))
    o = _editable(c)
    _legend_tag(o)
    for i in positions
        _set_tag_attrs!(o, _series_start(o, i), ["loext:hide-legend" => deleted === true ? "true" : nothing])
    end
    return c
end

"""
    setPlotAreaLine(c; color, width, dash, cap) -> Chart
    setPlotAreaLine(c, :none | :inherit) -> Chart

The plot area's border: LibreOffice's wall.
"""
function setPlotAreaLine(c::AbstractChart; kw...)
    o = _editable(c)
    m = _tfirst(o, "chart:wall")
    m === nothing && throw(ODSError("The chart has no wall (a pie or doughnut)."))
    _style_line!(o, c.package, _own_style!(o, m); kw...)
    return c
end
setPlotAreaLine(c::AbstractChart, v::Symbol) = v === :none ? setPlotAreaLine(c; color = :none) :
    v === :inherit ? setPlotAreaLine(c; color = :inherit, width = :inherit, dash = :inherit) : throw(ODSError("Use :none or :inherit."))

#
# Data labels
#

"""
    setLabelFlag(c, i, flag, on) -> Chart

Whether series `i`'s labels show `flag`: `:value`, `:percent`, `:categoryName`, `:seriesName`,
`:legendKey`. LibreOffice has no bubble-size labels: `:bubbleSize` is an error.
"""
function setLabelFlag(c::AbstractChart, i::Integer, flag::Symbol, on::Bool)
    flag === :bubbleSize && throw(ODSError("LibreOffice's labels can't show bubble sizes (D-086)."))
    flag in (:value, :percent, :categoryName, :seriesName, :legendKey) ||
        throw(ODSError("Unknown label flag `:$flag`: use :value, :percent, :categoryName, :seriesName or :legendKey."))
    o = _editable(c)
    st = _series_style!(o, i)
    cur(k) = _style_attr(o, st, k; element = "style:chart-properties")
    num = something(cur("chart:data-label-number"), "none")
    v = num in ("value", "value-and-percentage"); p = num in ("percentage", "value-and-percentage")
    flag === :value && (v = on); flag === :percent && (p = on)
    attrs = ["chart:data-label-number" => v && p ? "value-and-percentage" : v ? "value" : p ? "percentage" : "none"]
    cur("chart:data-label-text") === nothing && push!(attrs, "chart:data-label-text" => "false")
    cur("chart:data-label-symbol") === nothing && push!(attrs, "chart:data-label-symbol" => "false")
    cur("loext:data-label-series") === nothing && push!(attrs, "loext:data-label-series" => "false")
    flag === :categoryName && push!(attrs, "chart:data-label-text" => string(on))
    flag === :legendKey && push!(attrs, "chart:data-label-symbol" => string(on))
    flag === :seriesName && push!(attrs, "loext:data-label-series" => string(on))
    _set_style_attrs!(o, st, unique(p -> p.first, reverse(attrs)))
    return c
end

"""
    setLabelText(c, i, point, text) -> Chart
    setLabelDeleted(c, i, point, deleted) -> Chart

A point's label: custom text (LibreOffice's custom label fields), or none.
"""
function setLabelText(c::AbstractChart, i::Integer, point::Integer, text::AbstractString)
    o = _editable(c)
    _point_style!(o, i, point)                       # the point has an element of its own
    lbl = _tfrag1("<chart:data-label><text:p><text:span>" * _esct(text) * "</text:span></text:p></chart:data-label>")
    p = _nth_point(o, i, point)
    _tdelete_kids!(o, p, c -> XML.tag(c) == "chart:data-label")
    _tinsert!(o, p, 1, lbl)                          # first, as before
    return c
end
function setLabelDeleted(c::AbstractChart, i::Integer, point::Integer, deleted::Bool)
    o = _editable(c)
    st = _point_style!(o, i, point)
    deleted ? _set_style_attrs!(o, st, ["chart:data-label-number" => "none", "chart:data-label-text" => "false",
                                        "chart:data-label-symbol" => "false", "loext:data-label-series" => "false"]) :
              _del_style_attrs!(o, st, ["chart:data-label-number", "chart:data-label-text", "chart:data-label-symbol", "loext:data-label-series"])
    return c
end
# The element of a series' point (from 1): a `chart:data-point` child of the series, repeats counted.
function _nth_point(o, i, point)
    k = 0
    for p in _tkids(o, _series_start(o, i), "chart:data-point")
        rep = something(tryparse(Int, something(_tget(o, p, "chart:repeated"), "1")), 1)
        k + rep >= point && return p
        k += rep
    end
    throw(ODSError("Series $i has no point $point."))
end

#
# Axes
#

function _axis_set!(c, ax, attrs; element = "style:chart-properties")
    o = _editable(c)
    st = _axis_style!(o, c, ax)
    rm = [k for (k, v) in attrs if v === nothing]
    isempty(rm) || _del_style_attrs!(o, st, rm; element)
    set = Pair{String,String}[k => v for (k, v) in attrs if v !== nothing]
    isempty(set) || _set_style_attrs!(o, st, set; element)
    return c
end
# A number as attribute text: a whole number as Int64 digits while it is exact (an `Int` threw
# past 2^31 on a 32-bit build, and past 2^63 anywhere), else as a Float64.
_num_text(v::Real) = isinteger(v) && abs(v) < 2.0^53 ? string(Int64(v)) : string(Float64(v))
function _axis_value(v, what)
    v === :inherit && return nothing
    v isa Real && isfinite(v) || throw(ODSError("$what is a number, or :inherit."))
    return _num_text(v)
end

"""
    setAxisScaling(c, ax; orientation, min, max) / setAxisMin / setAxisMax / setAxisOrientation -> Chart
    setAxisCrosses(c, ax, rule) / setAxisCrossesAt(c, ax, value) -> Chart
    setAxisMajorUnit / setAxisMinorUnit(c, ax, value) -> Chart
    setAxisTickLabelPos(c, ax, pos) / setAxisMajorTickMark / setAxisMinorTickMark(c, ax, mark) -> Chart
    setAxisGridlines(c, ax; major, minor) / setAxisLine(c, ax; …) / setAxisNumberFormatCode(c, ax, code)
    setAxisNumberFormatLinked(c, ax, linked) -> Chart

An axis' scale and look, in LibreOffice's form. LibreOffice stores a minor unit as the number of
minor intervals in a major one: it needs a major unit it divides.
"""
function setAxisScaling(c::AbstractChart, ax; orientation = nothing, min = nothing, max = nothing)
    attrs = Pair{String,Union{Nothing,String}}[]
    min === nothing || push!(attrs, "chart:minimum" => _axis_value(min, "`min`"))
    max === nothing || push!(attrs, "chart:maximum" => _axis_value(max, "`max`"))
    if orientation !== nothing
        orientation in (:minMax, :maxMin, :inherit) || throw(ODSError("`orientation` is :minMax or :maxMin."))
        push!(attrs, "chart:reverse-direction" => orientation === :maxMin ? "true" : orientation === :minMax ? "false" : nothing)
    end
    # against the bounds the axis will have: one this call removes (`:inherit`) is none
    lo = min isa Real ? min : min === :inherit ? nothing : getAxisMin(c, ax)
    hi = max isa Real ? max : max === :inherit ? nothing : getAxisMax(c, ax)
    lo !== nothing && hi !== nothing && lo >= hi && throw(ODSError("An axis' minimum must be less than its maximum."))
    return _axis_set!(c, ax, attrs)
end
setAxisMin(c::AbstractChart, ax, v) = setAxisScaling(c, ax; min = v)
setAxisMax(c::AbstractChart, ax, v) = setAxisScaling(c, ax; max = v)
setAxisOrientation(c::AbstractChart, ax, v::Symbol) = setAxisScaling(c, ax; orientation = v)
function setAxisCrosses(c::AbstractChart, ax, rule::Symbol)
    rule in (:autoZero, :min, :max, :inherit) || throw(ODSError("`rule` is :autoZero, :min, :max or :inherit."))
    return _axis_set!(c, ax, ["chart:axis-position" => rule === :min ? "start" : rule === :max ? "end" : rule === :autoZero ? "0" : nothing])
end
setAxisCrossesAt(c::AbstractChart, ax, v) = _axis_set!(c, ax, ["chart:axis-position" => _axis_value(v, "The crossing")])
setAxisMajorUnit(c::AbstractChart, ax, v) = (_check_value_axis(c, ax); v === :inherit ? _axis_set!(c, ax, ["chart:interval-major" => nothing, "chart:interval-minor-divisor" => nothing]) :
    (v isa Real && v > 0 || throw(ODSError("A unit is a positive number."))) && _axis_set!(c, ax, ["chart:interval-major" => _num_text(v)]))
function setAxisMinorUnit(c::AbstractChart, ax, v)
    _check_value_axis(c, ax)
    v === :inherit && return _axis_set!(c, ax, ["chart:interval-minor-divisor" => nothing])
    v isa Real && v > 0 || throw(ODSError("A unit is a positive number."))
    major = getAxisMajorUnit(c, ax)
    major === nothing && throw(ODSError("LibreOffice stores a minor unit as a division of the major unit: set the major unit first (D-086)."))
    k = major / v
    isapprox(k, round(k); atol = 1e-9) && k >= 1 ||
        throw(ODSError("LibreOffice stores a minor unit as a division of the major unit: $v doesn't divide $major (D-086)."))
    return _axis_set!(c, ax, ["chart:interval-minor-divisor" => string(round(Int, k))])
end
_check_value_axis(c, ax) = getChartAxis(c, ax).kind in (:valAx, :dateAx) || throw(ODSError("Units are for value and date axes."))
function setAxisTickLabelPos(c::AbstractChart, ax, pos::Symbol)
    pos in (:high, :low, :nextTo, :none, :inherit) || throw(ODSError("`pos` is :high, :low, :nextTo, :none or :inherit."))
    return _axis_set!(c, ax, ["chart:display-label" => pos === :none ? "false" : "true",
        "chart:axis-label-position" => pos === :high ? "outside-end" : pos === :low ? "outside-start" : nothing])
end
function _tick_attrs(m::Symbol, which)
    m = m === :inside ? :in : m === :outside ? :out : m
    m in (:cross, :in, :out, :none, :inherit) || throw(ODSError("A tick mark is :cross, :in, :out, :none or :inherit."))
    m === :inherit && return ["chart:tick-marks-$which-inner" => nothing, "chart:tick-marks-$which-outer" => nothing]
    return ["chart:tick-marks-$which-inner" => string(m in (:cross, :in)), "chart:tick-marks-$which-outer" => string(m in (:cross, :out))]
end
setAxisMajorTickMark(c::AbstractChart, ax, m::Symbol) = _axis_set!(c, ax, _tick_attrs(m, "major"))
setAxisMinorTickMark(c::AbstractChart, ax, m::Symbol) = _axis_set!(c, ax, _tick_attrs(m, "minor"))
function setAxisGridlines(c::AbstractChart, ax; major = nothing, minor = nothing)
    o = _editable(c)
    for (on, class, col) in ((major, "major", "#b3b3b3"), (minor, "minor", "#dddddd"))
        on === nothing && continue
        on isa Bool || throw(ODSError("`$class` is true or false."))
        p = _axis_tag(o, c, ax)
        g = findfirst(q -> _tget(o, q, "chart:class") == class, _tkids(o, p, "chart:grid"))
        if on && g === nothing
            st = _add_style!(o, "<style:graphic-properties svg:stroke-color=\"$col\"/>")   # the axis' path holds
            _tappend!(o, p, XML.Element("chart:grid"; Symbol("chart:style-name") => st, Symbol("chart:class") => class))
        elseif !on && g !== nothing
            _tdelete!(o, _tkids(o, p, "chart:grid")[g])
        end
    end
    return c
end
setAxisLine(c::AbstractChart, ax; kw...) = (o = _editable(c); _style_line!(o, c.package, _axis_style!(o, c, ax); kw...); c)
setAxisLine(c::AbstractChart, ax, v::Symbol) = v === :none ? setAxisLine(c, ax; color = :none) :
    v === :inherit ? setAxisLine(c, ax; color = :inherit, width = :inherit, dash = :inherit) : throw(ODSError("Use :none or :inherit."))
function setAxisNumberFormatCode(c::AbstractChart, ax, code)
    o = _editable(c)
    st = _axis_style!(o, c, ax)
    if code === :inherit
        _set_style_attrs!(o, st, ["chart:link-data-style-to-source" => "true"])
        return c
    end
    r = numfmt_to_odf(String(code))
    name = "N0"
    if r !== nothing
        maps, main = r
        isempty(maps) || throw(ODSError("A chart axis takes a format of one section."))
        body = _ds_body(main)
        a = _auto_styles(o)
        named(n) = (q = findfirst(q -> _tget(o, q, "style:name") == n, _tkids(o, a)); q === nothing ? nothing : _tkids(o, a)[q])
        # the object's data style with this body, if it has one: each call added another
        k = 100
        while (q = named("N$k")) !== nothing
            _tnode(o, q) == _tfrag1(replace(body, "\$NAME" => "N$k")) && break
            k += 1
        end
        name = "N$k"
        if named(name) === nothing                   # before the styles, as LibreOffice writes them
            i = findfirst(c -> _isel(c) && XML.tag(c) == "style:style", collect(XML.children(_tnode(o, a))))
            _tinsert!(o, a, something(i, typemax(Int)), _tfrag1(replace(body, "\$NAME" => name)))
        end
    end
    q = _style_el(o, st)
    old = _tget(o, q, "style:data-style-name")
    _tset!(o, q, ["style:data-style-name" => name])
    old === nothing || old == name || _drop_own_data_style!(o, old)
    _set_style_attrs!(o, st, ["chart:link-data-style-to-source" => "false"])
    return c
end

# Removes data style `name` from the chart object if it is one this package made (`N100` on) and
# no style uses it any more: a replaced axis format was kept.
function _drop_own_data_style!(o, name::AbstractString)
    k = match(r"^N(\d+)$", name)
    (k === nothing || parse(Int, k.captures[1]) < 100) && return
    used = false; _teach(c -> _tattr(c, "style:data-style-name") == name && (used = true), o); used && return
    _tdelete_kids!(o, _auto_styles(o), c -> startswith(XML.tag(c), "number:") && _tattr(c, "style:name") == name)
    return
end
setAxisNumberFormatLinked(c::AbstractChart, ax, linked::Bool) = _axis_set!(c, ax, ["chart:link-data-style-to-source" => string(linked)])

"""
    setGroupGapWidth(c, g, pct) / setGroupOverlap(c, g, pct) -> Chart

A bar group's gap width (0 to 500 percent) and overlap (−100 to 100), on its y axis' style.
"""
function setGroupGapWidth(c::AbstractChart, g::ChartGroup, pct)
    pct === :inherit || (pct isa Integer && 0 <= pct <= 500) || throw(ODSError("A gap width is 0 to 500 percent."))
    return _axis_set!(c, 3 in g.axids ? 4 : 2, ["chart:gap-width" => pct === :inherit ? nothing : string(pct)])
end
function setGroupOverlap(c::AbstractChart, g::ChartGroup, pct)
    pct === :inherit || (pct isa Integer && -100 <= pct <= 100) || throw(ODSError("An overlap is −100 to 100 percent."))
    return _axis_set!(c, 3 in g.axids ? 4 : 2, ["chart:overlap" => pct === :inherit ? nothing : string(pct)])
end

#
# LibreOffice's own (D-076, D-086): trendlines, error bars, label arrangement, explosion
#


"""
    addTrendline(c, i, kind = :linear; order, period, name, forward, backward, intercept,
                 displayEquation = false, displayRSquared = false) -> Chart
    deleteTrendlines(c, i) -> Chart

A trendline on series `i`, LibreOffice's Insert ▸ Trend Line: `kind` `:linear`, `:log`,
`:exp`, `:power`, `:poly` (with `order`, 2 to 6) or `:movingAvg` (with `period`); its `name`;
extrapolation `forward` and `backward`; a forced `intercept`; the equation and R² shown.
"""
function addTrendline(c::AbstractChart, i::Integer, kind::Symbol = :linear; order = nothing, period = nothing, name = nothing,
                      forward = nothing, backward = nothing, intercept = nothing, displayEquation::Bool = false,
                      displayRSquared::Bool = false)
    haskey(_TREND_ODF, kind) || throw(ODSError("Unknown trendline `:$kind`: use :linear, :log, :exp, :power, :poly or :movingAvg."))
    kind === :poly && !(order isa Integer && 2 <= order <= 6) && throw(ODSError("A polynomial trendline needs an `order` of 2 to 6."))
    kind === :movingAvg && !(period isa Integer && period >= 2) && throw(ODSError("A moving average needs a `period` of 2 or more."))
    o = _editable(c)
    p = ["chart:regression-type" => _TREND_ODF[kind]]
    order === nothing || push!(p, "chart:regression-max-degree" => string(order))
    period === nothing || push!(p, "chart:regression-period" => string(period))
    name === nothing || push!(p, "chart:regression-name" => String(name))
    forward === nothing || push!(p, "loext:regression-extrapolate-forward" => _num_text(forward))
    backward === nothing || push!(p, "loext:regression-extrapolate-backward" => _num_text(backward))
    intercept === nothing || append!(p, ["chart:regression-force-intercept" => "true", "chart:regression-intercept-value" => _num_text(intercept)])
    st = _add_style!(o, "<style:chart-properties" * join(" $k=\"$(_esc(v))\"" for (k, v) in p) * "/>")
    eq = displayEquation || displayRSquared ? "<chart:equation chart:display-equation=\"$displayEquation\" chart:display-r-square=\"$displayRSquared\"/>" : ""
    _insert_in_series!(o, i, "<chart:regression-curve chart:style-name=\"$st\"" * (isempty(eq) ? "/>" : ">" * eq * "</chart:regression-curve>");
                       before = ("<chart:error-indicator", "<chart:data-point", "<chart:data-label"))
    return c
end
deleteTrendlines(c::AbstractChart, i::Integer) = (o = _editable(c); _remove_in_series!(o, i, c -> XML.tag(c) == "chart:regression-curve"); c)

const _ERR_ODF = Dict(:fixed => "constant", :percent => "percentage", :stdDev => "standard-deviation", :stdErr => "standard-error",
                      :range => "cell-range")

"""
    setErrorBars(c, i; type, value, plus, minus, bars = :both, direction = :y) -> Chart
    deleteErrorBars(c, i) -> Chart

Error bars on series `i`, LibreOffice's Insert ▸ Y Error Bars: `type` `:fixed`,
`:percent` or `:stdDev` (with `value`), `:stdErr`, or `:range` (with the cells `plus` and `minus`);
`bars` `:both`, `:plus` or `:minus`; `direction` `:y` or `:x` (XY charts).
"""
function setErrorBars(c::AbstractChart, i::Integer; type::Symbol, value = nothing, plus = nothing, minus = nothing,
                      bars::Symbol = :both, direction::Symbol = :y)
    haskey(_ERR_ODF, type) || throw(ODSError("Unknown error bar type `:$type`: use :fixed, :percent, :stdDev, :stdErr or :range."))
    bars in (:both, :plus, :minus) || throw(ODSError("`bars` is :both, :plus or :minus."))
    direction in (:x, :y) || throw(ODSError("`direction` is :x or :y."))
    type in (:fixed, :percent, :stdDev) && !(value isa Real) && throw(ODSError("Error bars of type `:$type` need a `value`."))
    type === :range && plus === nothing && minus === nothing && throw(ODSError("Error bars from cells need `plus` or `minus`."))
    o = _editable(c)
    _delete_error_bars!(o, i, direction)          # this direction's only: the other's were lost
    p = ["chart:error-category" => _ERR_ODF[type], "chart:error-upper-indicator" => string(bars !== :minus),
         "chart:error-lower-indicator" => string(bars !== :plus)]
    type === :fixed && append!(p, ["chart:error-upper-limit" => _num_text(value), "chart:error-lower-limit" => _num_text(value)])
    type === :percent && push!(p, "chart:error-percentage" => _num_text(value))
    push!(p, "loext:std-weight" => type === :stdDev ? _num_text(value) : "1")
    plus === nothing || push!(p, "chart:error-upper-range" => _odf_range(plus, c.sheet))
    minus === nothing || push!(p, "chart:error-lower-range" => _odf_range(minus, c.sheet))
    st = _add_style!(o, "<style:chart-properties" * join(" $k=\"$(_esc(v))\"" for (k, v) in p) * "/>" *
                        "<style:graphic-properties draw:stroke=\"solid\" svg:stroke-width=\"0cm\" svg:stroke-color=\"#000000\"/>")
    _insert_in_series!(o, i, "<chart:error-indicator chart:style-name=\"$st\" chart:dimension=\"$direction\"/>";
                       before = ("<chart:data-point", "<chart:data-label"))
    return c
end
deleteErrorBars(c::AbstractChart, i::Integer) = (_delete_error_bars!(_editable(c), i, nothing); c)

# Removes series `i`'s error bars in `direction` (`:x` or `:y`; `nothing`: both). An indicator
# without `chart:dimension` is a y one, as ODF's default.
function _delete_error_bars!(o, i::Integer, direction::Union{Nothing,Symbol})
    _remove_in_series!(o, i, c -> XML.tag(c) == "chart:error-indicator" &&
        (direction === nothing || something(_tattr(c, "chart:dimension"), "y") == string(direction)))
end

# Inserts a child of series `i` before the first of its children with a tag of `before` (ODF's
# order: tags written `"<chart:data-point"`), else last.
function _insert_in_series!(o, i, xml; before = ())
    p = _series_start(o, i)
    tags = [lstrip(b, '<') for b in before]
    k = findfirst(c -> _isel(c) && XML.tag(c) in tags, collect(XML.children(_tnode(o, p))))
    _tinsert!(o, p, something(k, typemax(Int)), _tfrag(xml)...)
end
# Removes series `i`'s children for which `pred(element)` holds.
_remove_in_series!(o, i, pred::Function) = (_tdelete_kids!(o, _series_start(o, i), pred); nothing)

"""
    setAxisLabelArrangement(c, ax; stagger = nothing, overlap = nothing, breakText = nothing) -> Chart

LibreOffice's label options of an axis: `stagger` (`:odd`, `:even`, `:none`), whether labels may
`overlap`, and whether they may break into lines.
"""
function setAxisLabelArrangement(c::AbstractChart, ax; stagger = nothing, overlap = nothing, breakText = nothing)
    attrs = Pair{String,Union{Nothing,String}}[]
    stagger === nothing || push!(attrs, "chart:label-arrangement" => stagger === :odd ? "stagger-odd" : stagger === :even ? "stagger-even" :
                                 stagger === :none ? "side-by-side" : throw(ODSError("`stagger` is :odd, :even or :none.")))
    overlap === nothing || push!(attrs, "chart:text-overlap" => string(Bool(overlap)))
    breakText === nothing || push!(attrs, "text:line-break" => string(Bool(breakText)))
    return _axis_set!(c, ax, attrs)
end

"""
    setSeriesExplosion(c, i, pct; point = nothing) -> Chart

How far a pie or doughnut series (or one point) is pulled out, in percent of the radius (LibreOffice's
`chart:pie-offset`).
"""
function setSeriesExplosion(c::AbstractChart, i::Integer, pct::Integer; point = nothing)
    0 <= pct <= 100 || throw(ODSError("An explosion is 0 to 100 percent."))
    o = _editable(c)
    _chart_class(o) in ("chart:circle", "chart:ring") || throw(ODSError("Explosion is for pie and doughnut charts."))
    st = point === nothing ? _series_style!(o, i) : _point_style!(o, i, point)
    _set_style_attrs!(o, st, ["chart:pie-offset" => string(pct)])
    return c
end

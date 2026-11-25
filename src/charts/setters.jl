# Formatting setters (phase 8 step 6, D-085, D-086): XLSX.jl's setters on LibreOffice's chart styles,
# for charts added here and LibreOffice's own (zipped files). Every setter returns the chart; `:inherit`
# removes the setting. What LibreOffice can't store is an error (D-084, D-086).

#
# Style editing
#

# A match of a regex in the object's text: where it starts, and its text.
struct _Hit
    at::Int
    match::String
end
_find(rx::Regex, text::AbstractString, start::Integer = 1) =
    (r = findnext(rx, text, start); r === nothing ? nothing : _Hit(first(r), text[r]))
# Every match, in order.
function _find_all(rx::Regex, text::AbstractString)
    out = _Hit[]
    i = 1
    while (h = _find(rx, text, i)) !== nothing
        push!(out, h)
        i = h.at + max(ncodeunits(h.match), 1)
    end
    return out
end

# The start tag of the k-th element matching `rx`, or nothing.
function _nth_tag(text::String, rx::Regex, k::Int)
    hs = _find_all(rx, text)
    return 1 <= k <= length(hs) ? hs[k] : nothing
end

_series_start(o, i::Integer) = (m = _nth_tag(o.text, r"<chart:series\b[^>]*>", Int(i));
    m === nothing && throw(ODSError("The chart has $(count("<chart:series ", o.text)) series; there is no series $i.")); m)

# An element's own automatic style (made, and given to it, when it has none or shares one): the
# element is the match `m` of its start tag.
function _own_style!(o, m::_Hit)
    tag = m.match
    s = match(r"chart:style-name=\"([^\"]*)\"", tag)
    if s !== nothing && count("chart:style-name=\"$(s.captures[1])\"", o.text) == 1
        return s.captures[1]
    end
    name = _next_style_name(o.text)
    newtag = s === nothing ? (endswith(tag, "/>") ? tag[1:end-2] * " chart:style-name=\"$name\"/>" : tag[1:end-1] * " chart:style-name=\"$name\">") :
                             replace(tag, s.match => "chart:style-name=\"$name\"")
    o.text = o.text[1:prevind(o.text, m.at)] * newtag * o.text[m.at+ncodeunits(tag):end]
    # the new style: a copy of the shared one (its data style too), or empty
    old = s === nothing ? nothing : _style_block(o, s.captures[1])
    st = old === nothing ? "<style:style style:name=\"$name\" style:family=\"chart\"></style:style>" :
         replace(old.match, r"^<style:style style:name=\"[^\"]*\"" => "<style:style style:name=\"$name\""; count = 1)
    i = findfirst("</office:automatic-styles>", o.text)
    i === nothing && throw(ODSError("The chart's object has no automatic styles."))
    o.text = o.text[1:prevind(o.text, first(i))] * st * o.text[first(i):end]
    return name
end
_rx_escape(s::AbstractString) = replace(s, r"([\\^$.|?*+()\[\]{}])" => s"\\\1")
_style_block(o, name::AbstractString) =
    match(Regex("<style:style style:name=\"" * _rx_escape(name) * "\"[^>]*?(/>|>.*?</style:style>)", "s"), o.text)

# Removes attributes from a style's property element.
function _del_style_attrs!(o, style::AbstractString, keys; element = "style:chart-properties")
    m = match(Regex("<style:style style:name=\"" * style * "\"[^>]*>.*?</style:style>", "s"), o.text)
    m === nothing && return
    st = m.match
    e = match(Regex("<" * element * "\\b[^>]*?/?>"), st)
    e === nothing && return
    tag = e.match
    for k in keys
        tag = replace(tag, Regex(" " * k * "=\"[^\"]*\"") => "")
    end
    o.text = replace(o.text, st => replace(st, e.match => tag; count = 1); count = 1)
end

# Sets (or, with `nothing`, removes) attributes of the element whose start tag is matched by `m`.
function _set_tag_attrs!(o, m::_Hit, attrs)
    tag = m.match
    for (k, v) in attrs
        tag = replace(tag, Regex(" " * k * "=\"[^\"]*\"") => "")
        v === nothing && continue
        close = endswith(tag, "/>") ? "/>" : ">"
        tag = tag[1:end-ncodeunits(close)] * " $k=\"$(_esc(v))\"" * close
    end
    o.text = o.text[1:prevind(o.text, m.at)] * tag * o.text[m.at+ncodeunits(m.match):end]
    return tag
end

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

A theme colour, as XLSX.jl's: a token (`:bg1`, `:tx1`, `:bg2`, `:tx2`, `:accent1` … `:accent6`, `:hlink`,
`:folHlink`, or the aliases `:lt1`, `:dk1`, `:lt2`, `:dk2`) and transforms in percent, applied in order.
It resolves to the document's theme (LibreOffice's, for a new document) and is written as LibreOffice's
theme reference, so LibreOffice follows a change of theme (F-082). LibreOffice keeps `lumMod`, `lumOff`,
`tint` and `shade`; `alpha` is a fill's transparency; `satMod` is an error (D-086).
"""
struct SchemeColor
    token::Symbol
    transforms::Vector{Pair{Symbol,Float64}}
    function SchemeColor(token::Symbol, transforms::Vector{Pair{Symbol,Float64}})
        token in SCHEME_TOKENS || throw(ODSError("`$token` is not a theme colour token: use " * join(SCHEME_TOKENS, ", ") * "."))
        for (k, _) in transforms
            k in COLOR_TRANSFORMS || throw(ODSError("`$k` is not a colour transform: use " * join(COLOR_TRANSFORMS, ", ") * "."))
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
    m = _style_block(o, st)
    m === nothing && return
    o.text = replace(o.text, m.match => replace(m.match, Regex("<loext:" * kind * "-complex-color\\b[^>]*?(/>|>.*?</loext:" * kind * "-complex-color>)", "s") => ""); count = 1)
end

# XLSX.jl's dash names (and Excel's aliases) as LibreOffice's import writes them (F-081): dots and gaps in
# percent of the line width.
const _DASH_ALIASES = Dict(:roundDot => :sysDot, :squareDot => :sysDash, :longDash => :lgDash, :longDashDot => :lgDashDot,
                           :longDashDotDot => :lgDashDotDot)
const _DASHES = Dict(:dot => (1, "1%", 0, "", "399%"), :dash => (1, "301%", 0, "", "399%"), :lgDash => (1, "701%", 0, "", "399%"),
    :dashDot => (1, "301%", 1, "1%", "399%"), :lgDashDot => (1, "701%", 1, "1%", "399%"), :lgDashDotDot => (1, "701%", 2, "1%", "399%"),
    :sysDash => (1, "201%", 0, "", "199%"), :sysDot => (1, "1%", 0, "", "199%"), :sysDashDot => (1, "201%", 1, "1%", "199%"),
    :sysDashDotDot => (1, "201%", 2, "1%", "199%"))
const _CAPS_ODF = Dict(:rnd => "round", :round => "round", :sq => "square", :square => "square", :flat => "butt")

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
            k = Symbol(cap)
            haskey(_CAPS_ODF, k) || throw(ODSError("Unknown cap `$cap`: use :rnd, :sq or :flat."))
            _set_style_attrs!(o, st, ["svg:stroke-linecap" => _CAPS_ODF[k]]; element = G)
        end
    end
end

_series_style!(o, i) = _own_style!(o, _series_start(o, i))
# A style's own attribute (of its property element), or nothing.
function _style_attr(o, st, key; element = "style:graphic-properties")
    m = _style_block(o, st)
    m === nothing && return nothing
    e = match(Regex("<" * element * "\\b[^>]*>"), m.match)
    e === nothing && return nothing
    a = match(Regex("\\s" * key * "=\"([^\"]*)\""), e.match)
    return a === nothing ? nothing : String(a.captures[1])
end
_own_stroke(o, st) = _style_attr(o, st, "draw:stroke")

"""
    setSeriesFill(c::Chart, i, color; transparency = nothing, gradient = nothing, gradientStyle = :linear,
gradientAngle = 0, hatch = nothing, hatchAngle = 0) -> Chart

Series `i`'s fill: a colour (hex, a colour name, a theme colour such as `:accent1` or a
[`SchemeColor`](@ref)), `:none`, or `:inherit` (LibreOffice's default). LibreOffice's own option
(D-076): `transparency`, 0 to 100 percent; a gradient from `color` to `gradient` (another colour), of
`gradientStyle` (`:linear`, `:axial`, `:radial`, `:ellipsoid`, `:square`, `:rectangular`) at
`gradientAngle` degrees; or a `hatch` (`:single`, `:double`, `:triple`) of lines of `color` at `hatchAngle`
degrees. A line, XY or radar series has one colour, its line's and its symbols' (LibreOffice's): its fill
is its line colour, and `:none`, transparency, gradients and hatches are errors (D-086).
"""
function setSeriesFill(c::Chart, i::Integer, color::Union{SchemeColorLike,Colors.Colorant}; transparency::Union{Nothing,Integer} = nothing,
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
    class = _chart_class(o)
    m = match(r"chart:class=\"([^\"]*)\"", _series_start(o, i).match)
    return (m === nothing ? class : m.captures[1]) in ("chart:line", "chart:scatter", "chart:radar")
end

"""
    setSeriesLine(c::Chart, i; color, width, dash, cap, compound, join, miterLimit) -> Chart
    setSeriesLine(c::Chart, i, :none | :inherit) -> Chart
    setSeriesLineColor / setSeriesLineWidth / setSeriesLineDash / setSeriesLineCap(c, i, value) -> Chart
    setSeriesLineCompound / setSeriesLineJoin / setSeriesLineMiterLimit(c, i, value) -> error

Series `i`'s line: a colour, a width in points, a dash (XLSX.jl's names and Excel's aliases, written as
LibreOffice's import writes them), a cap (`:rnd`, `:sq`, `:flat`). LibreOffice's chart lines have no
compound lines, joins or miter limits (D-086): those are errors.
"""
function setSeriesLine(c::Chart, i::Integer; color = nothing, width = nothing, dash = nothing, cap = nothing,
                       compound = nothing, join = nothing, miterLimit = nothing)
    o = _editable(c)
    _style_line!(o, c.package, _series_style!(o, i); color, width, dash, cap, compound, join, miterLimit, linked = _line_like(o, i))
    return c
end
setSeriesLine(c::Chart, i::Integer, v::Symbol) =
    v === :none ? setSeriesLine(c, i; color = :none) : v === :inherit ? setSeriesLine(c, i; color = :inherit, width = :inherit, dash = :inherit, cap = :inherit) :
    throw(ODSError("Use :none or :inherit, or the keywords."))
setSeriesLineColor(c::Chart, i::Integer, v) = setSeriesLine(c, i; color = v)
setSeriesLineWidth(c::Chart, i::Integer, v) = setSeriesLine(c, i; width = v)
setSeriesLineDash(c::Chart, i::Integer, v) = setSeriesLine(c, i; dash = v)
setSeriesLineCap(c::Chart, i::Integer, v) = setSeriesLine(c, i; cap = v)
setSeriesLineCompound(c::Chart, i::Integer, v) = setSeriesLine(c, i; compound = v)
setSeriesLineJoin(c::Chart, i::Integer, v) = setSeriesLine(c, i; join = v)
setSeriesLineMiterLimit(c::Chart, i::Integer, v) = setSeriesLine(c, i; miterLimit = v)

#
# Markers
#

# A point's own element and style (point from 1): the run of `chart:data-point` holding it is split
# (`chart:repeated`). LibreOffice writes a series' points after its trendlines and error bars.
function _point_style!(o, i::Integer, point::Integer)
    point >= 1 || throw(ODSError("Points are numbered from 1."))
    st = _series_start(o, i)
    if endswith(st.match, "/>")                                   # a series with no children
        o.text = o.text[1:prevind(o.text, st.at)] * st.match[1:end-2] * "></chart:series>" * o.text[st.at+ncodeunits(st.match):end]
        st = _series_start(o, i)
    end
    a = st.at + ncodeunits(st.match)
    b = first(findnext("</chart:series>", o.text, a)) - 1
    inner = o.text[a:b]
    pts = Tuple{String,String}[]                                  # (attributes but repeated, children) per point
    rest = IOBuffer()
    pos = 1
    for h in _find_all(r"<chart:data-point\b([^>]*?)(/>|>(.*?)</chart:data-point>)"s, inner)
        print(rest, inner[pos:prevind(inner, h.at)])
        m = match(r"^<chart:data-point\b([^>]*?)(/>|>(.*?)</chart:data-point>)$"s, h.match)
        r = match(r"chart:repeated=\"(\d+)\"", m.captures[1])
        rep = r === nothing ? 1 : parse(Int, r.captures[1])
        attrs = replace(m.captures[1], r"\s*chart:repeated=\"\d+\"" => "")
        for _ in 1:rep
            push!(pts, (attrs, something(m.captures[3], "")))
        end
        pos = h.at + ncodeunits(h.match)
    end
    others = String(take!(rest)) * inner[pos:end]
    n = _series_length(o, i)
    while length(pts) < max(point, n)
        push!(pts, ("", ""))
    end
    attrs, pin = pts[point]
    s = match(r"chart:style-name=\"([^\"]*)\"", attrs)
    sname = s === nothing ? nothing : String(s.captures[1])
    if sname === nothing || count("chart:style-name=\"$sname\"", o.text) > 1 || count(p -> occursin("\"$sname\"", p[1]), pts) > 1
        sname = _clone_style!(o, sname)
        attrs = s === nothing ? attrs * " chart:style-name=\"$sname\"" : replace(attrs, s.match => "chart:style-name=\"$sname\"")
        pts[point] = (attrs, pin)
        st = _series_start(o, i)                                  # the styles moved the series
        a = st.at + ncodeunits(st.match)
        b = first(findnext("</chart:series>", o.text, a)) - 1
    end
    io = IOBuffer()                                               # written back, runs of alike points merged
    k = 1
    while k <= length(pts)
        j = k
        while j < length(pts) && pts[j+1] == pts[k] && isempty(pts[k][2])
            j += 1
        end
        print(io, "<chart:data-point", pts[k][1], j > k ? " chart:repeated=\"$(j - k + 1)\"" : "",
              isempty(pts[k][2]) ? "/>" : ">" * pts[k][2] * "</chart:data-point>")
        k = j + 1
    end
    lbl = _find(r"<chart:data-label\b.*$"s, others)              # a series' own label comes last
    head = lbl === nothing ? others : others[1:prevind(others, lbl.at)]
    o.text = o.text[1:a-1] * head * String(take!(io)) * (lbl === nothing ? "" : lbl.match) * o.text[b+1:end]
    return sname
end

# How many values series `i` has (its values range's cells), for the points written out.
function _series_length(o, i)
    v = match(r"chart:values-cell-range-address=\"([^\"]*)\"", _series_start(o, i).match)
    v === nothing && return 0
    return sum((length(r) * length(c) for (_, r, c) in _range_areas(XML.unescape(String(v.captures[1]))) if r !== nothing); init = 0)
end

# A new automatic style: a copy of `old` (its data style too), or empty.
function _clone_style!(o, old::Union{Nothing,AbstractString})
    name = _next_style_name(o.text)
    m = old === nothing ? nothing : _style_block(o, old)
    st = m === nothing ? "<style:style style:name=\"$name\" style:family=\"chart\"></style:style>" :
         replace(m.match, r"^<style:style style:name=\"[^\"]*\"" => "<style:style style:name=\"$name\""; count = 1)
    i = findfirst("</office:automatic-styles>", o.text)
    i === nothing && throw(ODSError("The chart's object has no automatic styles."))
    o.text = o.text[1:prevind(o.text, first(i))] * st * o.text[first(i):end]
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
            occursin("chart:symbol-width", something(match(Regex("<style:style style:name=\"" * st * "\".*?</style:style>", "s"), o.text)).match) ||
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
    setMarker(c::Chart, i; point = nothing, symbol = nothing, size = nothing, fill = nothing, lineColor = nothing,
              lineWidth = nothing) -> Chart
    setMarkerSymbol(c, i, symbol; point = nothing) / setMarkerSize(c, i, size; point = nothing) -> Chart
    setMarkerFill / setMarkerLineColor / setMarkerLineWidth(c, i, value; point = nothing) -> error

A line, XY or radar series' (or point's, from 1) symbol and size (2 to 72 points). Symbols are
XLSX.jl's (`:circle`, `:square`, `:diamond`, `:triangle`, `:x`, `:plus`, `:star`, `:dash`, `:dot`,
`:none`, `:auto`) and LibreOffice's own (`:arrowDown`, `:arrowLeft`, `:bowTie`, `:hourglass`, `:loStar`,
`:vBar`). LibreOffice draws a symbol in its series' colours: a fill or border of its own is an error
(D-086).
"""
function setMarker(c::Chart, i::Integer; point = nothing, symbol = nothing, size = nothing, fill = nothing,
                   lineColor = nothing, lineWidth = nothing)
    (fill === nothing && lineColor === nothing && lineWidth === nothing) ||
        throw(ODSError("LibreOffice draws a marker in its series' colours: it has no fill or border of its own (D-086). Set the series' with `setSeriesFill`."))
    o = _editable(c)
    _check_marker_series(o, i)
    st = point === nothing ? _series_style!(o, i) : _point_style!(o, i, point)
    _set_marker!(o, st, symbol, size)
    return c
end
setMarkerSymbol(c::Chart, i::Integer, v::Symbol; point = nothing) = setMarker(c, i; point, symbol = v)
setMarkerSize(c::Chart, i::Integer, v; point = nothing) = setMarker(c, i; point, size = v)
setMarkerFill(c::Chart, i::Integer, v; point = nothing) = setMarker(c, i; point, fill = v)
setMarkerLineColor(c::Chart, i::Integer, v; point = nothing) = setMarker(c, i; point, lineColor = v)
setMarkerLineWidth(c::Chart, i::Integer, v; point = nothing) = setMarker(c, i; point, lineWidth = v)

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
    ks = field === :size ? ["fo:font-size", "style:font-size-asian", "style:font-size-complex"] :
           field === :bold ? ["fo:font-weight", "style:font-weight-asian", "style:font-weight-complex"] :
           field === :italic ? ["fo:font-style", "style:font-style-asian", "style:font-style-complex"] :
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

function _title_tag(o)
    m = _find(r"<chart:title\b[^>]*>", o.text)          # the chart's title comes before the plot area
    (m === nothing || m.at > something(findfirst("<chart:plot-area", o.text), 1:typemax(Int))[1]) &&
        throw(ODSError("The chart has no title: set one with `setChartTitleText`."))
    return m
end
_legend_tag(o) = (m = _find(r"<chart:legend\b[^>]*>", o.text); m === nothing && throw(ODSError("The chart has no legend: set one with `setLegendPos`.")); m)

"""
    setChartTitleTextProp(c, field, value) / setAxisTitleTextProp(c, ax, field, value) / setLegendTextProp(c, field, value)
    setAxisTextProp(c, ax, field, value) / setLabelTextProp(c, i, field, value) / setLabelTextProp(c, i, point, field, value)
    setGroupLabelTextProp(c, g, field, value) / setChartSpaceTextProp(c, field, value) -> Chart

One text property of a part of the chart. Fields: `:size` (points), `:bold`, `:italic`, `:under`
(`:underline`), `:strike` (`:strikethrough`), `:baseline` (a fraction of the size), `:spacing`
(points), `:fill` (`:color`), `:latin` (`:font`), `:ea`, `:cs`, `:lang`; `:inherit` removes one.
LibreOffice's chart text has no capitals setting, kerning size or coloured outline: `:caps`, `:kern`
and `:line` are errors (D-086). The chart space's text is its series labels', as LibreOffice's import
places it (F-081).
"""
setChartTitleTextProp(c::Chart, field::Symbol, v) = (o = _editable(c); _style_text!(o, c.package, _own_style!(o, _title_tag(o)), field, v); c)
setLegendTextProp(c::Chart, field::Symbol, v) = (o = _editable(c); _style_text!(o, c.package, _own_style!(o, _legend_tag(o)), field, v); c)
function setAxisTitleTextProp(c::Chart, ax, field::Symbol, v)
    o = _editable(c)
    m = _axis_tag(o, c, ax)
    t = endswith(m.match, "/>") ? nothing : _find(r"^<chart:title\b[^>]*>", o.text[m.at+ncodeunits(m.match):end])
    t === nothing && throw(ODSError("The axis has no title: set one with `setAxisTitleText`."))
    _style_text!(o, c.package, _own_style!(o, _Hit(m.at + ncodeunits(m.match), t.match)), field, v)
    return c
end
setAxisTextProp(c::Chart, ax, field::Symbol, v) = (o = _editable(c); _style_text!(o, c.package, _own_style!(o, _axis_tag(o, c, ax)), field, v); c)
setLabelTextProp(c::Chart, i::Integer, field::Symbol, v) = (o = _editable(c); _style_text!(o, c.package, _series_style!(o, i), field, v); c)
setLabelTextProp(c::Chart, i::Integer, point::Integer, field::Symbol, v) =
    (o = _editable(c); _style_text!(o, c.package, _point_style!(o, i, point), field, v); c)
function setGroupLabelTextProp(c::Chart, g::ChartGroup, field::Symbol, v)
    doc = _doc(c)
    for (i, s) in enumerate(_series_nodes(doc))
        ChartGroup(_series_tag(doc, s), _series_axids(s), nothing) == g && setLabelTextProp(c, i, field, v)
    end
    return c
end
setChartSpaceTextProp(c::Chart, field::Symbol, v) = (foreach(i -> setLabelTextProp(c, i, field, v), 1:length(_series_nodes(_doc(c)))); c)

# An axis' start tag: the axes are the plot area's `chart:axis` children, in order.
function _axis_tag(o, c, ax)
    a = getChartAxis(c, ax)
    k = findfirst(n -> _axis_id(n) == a.axid, _children(_plot_area(_chart_doc(o.text)), "chart:axis"))
    m = k === nothing ? nothing : _nth_tag(o.text, r"<chart:axis\b[^>]*>", k)
    m === nothing && throw(ODSError("The chart has no axis `$ax`."))
    return m
end
_axis_style!(o, c, ax) = _own_style!(o, _axis_tag(o, c, ax))

#
# Titles, legend and plot area
#

"""
    setChartTitleText(c, text) -> Chart
    setAxisTitleText(c, ax, text) -> Chart

The chart's (or an axis') title: a string (a line break starts a paragraph) or a `DrawingText`.
LibreOffice's titles can't follow a cell: a `CellRef` is an error (D-086).
"""
function setChartTitleText(c::Chart, text)
    o = _editable(c)
    paras = _title_xml(text, o, c.package)
    m = _find(r"<chart:title\b[^>]*>.*?</chart:title>"s, o.text)
    pa = first(something(findfirst("<chart:plot-area", o.text), 1:typemax(Int)))
    if m !== nothing && m.at < pa
        st = something(match(r"chart:style-name=\"[^\"]*\"", m.match), (match = "",)).match
        o.text = replace(o.text, m.match => "<chart:title $st>" * paras * "</chart:title>"; count = 1)
    else
        st = _add_style!(o, """<style:chart-properties chart:auto-position="true"/>""" * _text_pt(13))
        h = _find(r"<chart:chart\b[^>]*>", o.text)
        o.text = o.text[1:h.at+ncodeunits(h.match)-1] * "<chart:title chart:style-name=\"$st\">" * paras * "</chart:title>" * o.text[h.at+ncodeunits(h.match):end]
    end
    return c
end
function setAxisTitleText(c::Chart, ax, text)
    o = _editable(c)
    paras = _title_xml(text, o, c.package)
    m = _axis_tag(o, c, ax)
    a = getChartAxis(c, ax)
    after = o.text[m.at+ncodeunits(m.match):end]
    tm = match(r"^<chart:title\b[^>]*>.*?</chart:title>"s, after)
    if tm !== nothing
        st = something(match(r"chart:style-name=\"[^\"]*\"", tm.match), (match = "",)).match
        new = "<chart:title $st>" * paras * "</chart:title>"
        o.text = o.text[1:m.at+ncodeunits(m.match)-1] * new * after[ncodeunits(tm.match)+1:end]
    else
        rot = a.pos in (:l, :r) ? " style:rotation-angle=\"90\"" : ""
        st = _add_style!(o, """<style:chart-properties chart:auto-position="true"$rot/>""" * _text_pt(11))
        m = _axis_tag(o, c, ax)
        tag = endswith(m.match, "/>") ? m.match[1:end-2] * ">" : m.match
        o.text = o.text[1:m.at-1] * tag * "<chart:title chart:style-name=\"$st\">" * paras * "</chart:title>" *
                 (endswith(m.match, "/>") ? "</chart:axis>" : "") * o.text[m.at+ncodeunits(m.match):end]
    end
    return c
end
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
    get(a, :bold, false) in (true, 1) && append!(p, ["fo:font-weight" => "bold", "style:font-weight-asian" => "bold", "style:font-weight-complex" => "bold"])
    get(a, :italic, false) in (true, 1) && append!(p, ["fo:font-style" => "italic", "style:font-style-asian" => "italic", "style:font-style-complex" => "italic"])
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
        sz = string(isinteger(s) ? Int(s) : s) * "pt"
        append!(p, ["fo:font-size" => sz, "style:font-size-asian" => sz, "style:font-size-complex" => sz])
    end
    n = get(a, :name, nothing)
    n === nothing || push!(p, "fo:font-family" => (occursin(' ', n) ? "'$n'" : String(n)))
    return join(" $k=\"$(_esc(v))\"" for (k, v) in p)
end

# The object's text style with `props`, made (`T1`, `T2`, …) when it has none.
function _chart_text_style!(o, props::AbstractString)
    for m in eachmatch(r"<style:style style:name=\"([^\"]*)\" style:family=\"text\"><style:text-properties([^>]*?)/></style:style>", o.text)
        m.captures[2] == props && return String(m.captures[1])
    end
    k = 1
    while occursin("style:name=\"T$k\"", o.text)
        k += 1
    end
    _insert_before!(o, "</office:automatic-styles>", "<style:style style:name=\"T$k\" style:family=\"text\"><style:text-properties$props/></style:style>")
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

The legend's place: `:b`, `:t`, `:l`, `:r`, `:tr`, and the other corners `:tl`, `:bl`, `:br` (D-076); a
corner is a custom position in that corner of the chart, as LibreOffice's import writes `:tr` (F-081).
`:inherit` removes the position, which LibreOffice reads as `:r`. Whether the legend may overlap the
plot area, and the series whose entries are hidden. The first two make a legend if the chart has none.
LibreOffice's own (D-076): `expansion`, `:wide`, `:high` or `:balanced` (not for a corner).
"""
function setLegendPos(c::Chart, pos::Symbol; overlay = nothing, expansion = nothing)
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
_style_attr_legend(o) = (m = _find(r"<chart:legend\b[^>]*>", o.text);
    m === nothing ? nothing : (a = match(r"style:legend-expansion=\"([^\"]*)\"", m.match); a === nothing ? nothing : a.captures[1]))
setLegendOverlay(c::Chart, overlay::Union{Bool,Symbol}) =
    (o = _editable(c); _set_tag_attrs!(o, _legend_or_new!(o), ["loext:overlay" => overlay === :inherit ? nothing : string(Bool(overlay))]); c)
# The legend's start tag, a legend made (on the right, as LibreOffice's) when there is none.
function _legend_or_new!(o)
    m = _find(r"<chart:legend\b[^>]*>", o.text)
    m === nothing || return m
    st = _add_style!(o, """<style:chart-properties chart:auto-position="true"/>""" * _TEXT10)
    _insert_before!(o, "<chart:plot-area", "<chart:legend chart:legend-position=\"end\" svg:x=\"0cm\" svg:y=\"0cm\" chart:style-name=\"$st\"/>")
    return _find(r"<chart:legend\b[^>]*>", o.text)
end
function setLegendEntryDeleted(c::Chart, positions, deleted::Union{Bool,Symbol})
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

The plot area's border: LibreOffice's wall (F-081).
"""
function setPlotAreaLine(c::Chart; kw...)
    o = _editable(c)
    m = _find(r"<chart:wall\b[^>]*>", o.text)
    m === nothing && throw(ODSError("The chart has no wall (a pie or doughnut)."))
    _style_line!(o, c.package, _own_style!(o, m); kw...)
    return c
end
setPlotAreaLine(c::Chart, v::Symbol) = v === :none ? setPlotAreaLine(c; color = :none) :
    v === :inherit ? setPlotAreaLine(c; color = :inherit, width = :inherit, dash = :inherit) : throw(ODSError("Use :none or :inherit."))

#
# Data labels
#

"""
    setLabelFlag(c, i, flag, on) -> Chart

Whether series `i`'s labels show `flag`: `:value`, `:percent`, `:categoryName`, `:seriesName`,
`:legendKey`. LibreOffice has no bubble-size labels: `:bubbleSize` is an error (D-086).
"""
function setLabelFlag(c::Chart, i::Integer, flag::Symbol, on::Bool)
    flag === :bubbleSize && throw(ODSError("LibreOffice's labels can't show bubble sizes (D-086)."))
    flag in (:value, :percent, :categoryName, :seriesName, :legendKey) ||
        throw(ODSError("Unknown label flag `:$flag`: use :value, :percent, :categoryName, :seriesName or :legendKey."))
    o = _editable(c)
    st = _series_style!(o, i)
    cur = match(Regex("<style:style style:name=\"" * st * "\".*?</style:style>", "s"), o.text).match
    num = something(match(r"chart:data-label-number=\"([^\"]*)\"", cur), (captures = ["none"],)).captures[1]
    v = num in ("value", "value-and-percentage"); p = num in ("percentage", "value-and-percentage")
    flag === :value && (v = on); flag === :percent && (p = on)
    attrs = ["chart:data-label-number" => v && p ? "value-and-percentage" : v ? "value" : p ? "percentage" : "none"]
    occursin("chart:data-label-text", cur) || push!(attrs, "chart:data-label-text" => "false")
    occursin("chart:data-label-symbol", cur) || push!(attrs, "chart:data-label-symbol" => "false")
    occursin("loext:data-label-series", cur) || push!(attrs, "loext:data-label-series" => "false")
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
function setLabelText(c::Chart, i::Integer, point::Integer, text::AbstractString)
    o = _editable(c)
    _point_style!(o, i, point)
    lbl = "<chart:data-label><text:p><text:span>" * _esct(text) * "</text:span></text:p></chart:data-label>"
    m = _nth_point(o, i, point)
    full = endswith(m.match, "/>") ? m.match[1:end-2] * ">" * lbl * "</chart:data-point>" :
           (e = findnext("</chart:data-point>", o.text, m.at); inner = o.text[m.at+ncodeunits(m.match):first(e)-1];
            o.text = o.text[1:m.at+ncodeunits(m.match)-1] * replace(inner, r"<chart:data-label\b.*?</chart:data-label>"s => "") * o.text[first(e):end];
            nothing)
    if full === nothing
        m = _nth_point(o, i, point)
        o.text = o.text[1:m.at+ncodeunits(m.match)-1] * lbl * o.text[m.at+ncodeunits(m.match):end]
    else
        o.text = o.text[1:m.at-1] * full * o.text[m.at+ncodeunits(m.match):end]
    end
    return c
end
function setLabelDeleted(c::Chart, i::Integer, point::Integer, deleted::Bool)
    o = _editable(c)
    st = _point_style!(o, i, point)
    deleted ? _set_style_attrs!(o, st, ["chart:data-label-number" => "none", "chart:data-label-text" => "false",
                                        "chart:data-label-symbol" => "false", "loext:data-label-series" => "false"]) :
              _del_style_attrs!(o, st, ["chart:data-label-number", "chart:data-label-text", "chart:data-label-symbol", "loext:data-label-series"])
    return c
end
# The start tag of a series' point (from 1), once points have their own elements.
function _nth_point(o, i, point)
    st = _series_start(o, i)
    close = findnext("</chart:series>", o.text, st.at)
    k = 0
    for m in _find_all(r"<chart:data-point\b[^>]*>", o.text[1:first(close)])
        m.at < st.at && continue
        r = match(r"chart:repeated=\"(\d+)\"", m.match)
        rep = r === nothing ? 1 : parse(Int, r.captures[1])
        k + rep >= point && return m
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
_num_text(v::Real) = isinteger(v) ? string(Int(v)) : string(Float64(v))
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

An axis' scale and look, in LibreOffice's form (F-082). LibreOffice stores a minor unit as the number of
minor intervals in a major one (F-081): it needs a major unit it divides (D-086).
"""
function setAxisScaling(c::Chart, ax; orientation = nothing, min = nothing, max = nothing)
    attrs = Pair{String,Union{Nothing,String}}[]
    min === nothing || push!(attrs, "chart:minimum" => _axis_value(min, "`min`"))
    max === nothing || push!(attrs, "chart:maximum" => _axis_value(max, "`max`"))
    if orientation !== nothing
        orientation in (:minMax, :maxMin, :inherit) || throw(ODSError("`orientation` is :minMax or :maxMin."))
        push!(attrs, "chart:reverse-direction" => orientation === :maxMin ? "true" : orientation === :minMax ? "false" : nothing)
    end
    lo = min isa Real ? min : getAxisMin(c, ax); hi = max isa Real ? max : getAxisMax(c, ax)
    lo !== nothing && hi !== nothing && lo >= hi && throw(ODSError("An axis' minimum must be less than its maximum."))
    return _axis_set!(c, ax, attrs)
end
setAxisMin(c::Chart, ax, v) = setAxisScaling(c, ax; min = v)
setAxisMax(c::Chart, ax, v) = setAxisScaling(c, ax; max = v)
setAxisOrientation(c::Chart, ax, v::Symbol) = setAxisScaling(c, ax; orientation = v)
function setAxisCrosses(c::Chart, ax, rule::Symbol)
    rule in (:autoZero, :min, :max, :inherit) || throw(ODSError("`rule` is :autoZero, :min, :max or :inherit."))
    return _axis_set!(c, ax, ["chart:axis-position" => rule === :min ? "start" : rule === :max ? "end" : rule === :autoZero ? "0" : nothing])
end
setAxisCrossesAt(c::Chart, ax, v) = _axis_set!(c, ax, ["chart:axis-position" => _axis_value(v, "The crossing")])
setAxisMajorUnit(c::Chart, ax, v) = (_check_value_axis(c, ax); v === :inherit ? _axis_set!(c, ax, ["chart:interval-major" => nothing, "chart:interval-minor-divisor" => nothing]) :
    (v isa Real && v > 0 || throw(ODSError("A unit is a positive number."))) && _axis_set!(c, ax, ["chart:interval-major" => _num_text(v)]))
function setAxisMinorUnit(c::Chart, ax, v)
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
function setAxisTickLabelPos(c::Chart, ax, pos::Symbol)
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
setAxisMajorTickMark(c::Chart, ax, m::Symbol) = _axis_set!(c, ax, _tick_attrs(m, "major"))
setAxisMinorTickMark(c::Chart, ax, m::Symbol) = _axis_set!(c, ax, _tick_attrs(m, "minor"))
function setAxisGridlines(c::Chart, ax; major = nothing, minor = nothing)
    o = _editable(c)
    for (on, class, col) in ((major, "major", "#b3b3b3"), (minor, "minor", "#dddddd"))
        on === nothing && continue
        on isa Bool || throw(ODSError("`$class` is true or false."))
        m = _axis_tag(o, c, ax)
        rest = o.text[m.at+ncodeunits(m.match):end]
        e = endswith(m.match, "/>") ? 0 : first(something(findfirst("</chart:axis>", rest), 0:0))
        g = e == 0 ? nothing : _find(Regex("<chart:grid\\b[^>]*chart:class=\"" * class * "\"[^>]*/>"), rest[1:e-1])
        if on && g === nothing
            st = _add_style!(o, "<style:graphic-properties svg:stroke-color=\"$col\"/>")
            m = _axis_tag(o, c, ax)
            grid = "<chart:grid chart:style-name=\"$st\" chart:class=\"$class\"/>"
            if endswith(m.match, "/>")
                o.text = o.text[1:m.at-1] * m.match[1:end-2] * ">" * grid * "</chart:axis>" * o.text[m.at+ncodeunits(m.match):end]
            else
                rest = o.text[m.at+ncodeunits(m.match):end]
                e = first(findfirst("</chart:axis>", rest))
                o.text = o.text[1:m.at+ncodeunits(m.match)-1] * rest[1:e-1] * grid * rest[e:end]
            end
        elseif !on && g !== nothing
            s = m.at + ncodeunits(m.match) + g.at - 1
            o.text = o.text[1:s-1] * o.text[s+ncodeunits(g.match):end]
        end
    end
    return c
end
setAxisLine(c::Chart, ax; kw...) = (o = _editable(c); _style_line!(o, c.package, _axis_style!(o, c, ax); kw...); c)
setAxisLine(c::Chart, ax, v::Symbol) = v === :none ? setAxisLine(c, ax; color = :none) :
    v === :inherit ? setAxisLine(c, ax; color = :inherit, width = :inherit, dash = :inherit) : throw(ODSError("Use :none or :inherit."))
function setAxisNumberFormatCode(c::Chart, ax, code)
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
        k = 100
        while occursin("style:name=\"N$k\"", o.text)
            k += 1
        end
        name = "N$k"
        _insert_before!(o, "<style:style", replace(_ds_body(main), "\$NAME" => name))
    end
    m = match(Regex("<style:style style:name=\"" * st * "\"[^>]*>"), o.text)
    tag = occursin("style:data-style-name=", m.match) ? replace(m.match, r"style:data-style-name=\"[^\"]*\"" => "style:data-style-name=\"$name\"") :
          m.match[1:end-1] * " style:data-style-name=\"$name\">"
    o.text = replace(o.text, m.match => tag; count = 1)
    _set_style_attrs!(o, st, ["chart:link-data-style-to-source" => "false"])
    return c
end
setAxisNumberFormatLinked(c::Chart, ax, linked::Bool) = _axis_set!(c, ax, ["chart:link-data-style-to-source" => string(linked)])

"""
    setGroupGapWidth(c, g, pct) / setGroupOverlap(c, g, pct) -> Chart

A bar group's gap width (0 to 500 percent) and overlap (−100 to 100), on its y axis' style (F-082).
"""
function setGroupGapWidth(c::Chart, g::ChartGroup, pct)
    pct === :inherit || (pct isa Integer && 0 <= pct <= 500) || throw(ODSError("A gap width is 0 to 500 percent."))
    return _axis_set!(c, 3 in g.axids ? 4 : 2, ["chart:gap-width" => pct === :inherit ? nothing : string(pct)])
end
function setGroupOverlap(c::Chart, g::ChartGroup, pct)
    pct === :inherit || (pct isa Integer && -100 <= pct <= 100) || throw(ODSError("An overlap is −100 to 100 percent."))
    return _axis_set!(c, 3 in g.axids ? 4 : 2, ["chart:overlap" => pct === :inherit ? nothing : string(pct)])
end

#
# LibreOffice's own (D-076, D-086): trendlines, error bars, label arrangement, explosion
#

const _TREND_ODF = Dict(:linear => "linear", :log => "logarithmic", :exp => "exponential", :power => "power",
                        :poly => "polynomial", :movingAvg => "moving-average")

"""
    addTrendline(c, i, kind = :linear; order, period, name, forward, backward, intercept,
                 displayEquation = false, displayRSquared = false) -> Chart
    deleteTrendlines(c, i) -> Chart

A trendline on series `i` (XLSX.jl reads them; LibreOffice stores them, D-076): `kind` `:linear`, `:log`,
`:exp`, `:power`, `:poly` (with `order`, 2 to 6) or `:movingAvg` (with `period`); its `name`;
extrapolation `forward` and `backward`; a forced `intercept`; the equation and R² shown.
"""
function addTrendline(c::Chart, i::Integer, kind::Symbol = :linear; order = nothing, period = nothing, name = nothing,
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
deleteTrendlines(c::Chart, i::Integer) = (o = _editable(c); _remove_in_series!(o, i, r"<chart:regression-curve\b.*?</chart:regression-curve>|<chart:regression-curve\b[^>]*/>"s); c)

const _ERR_ODF = Dict(:fixed => "constant", :percent => "percentage", :stdDev => "standard-deviation", :stdErr => "standard-error",
                      :range => "cell-range")

"""
    setErrorBars(c, i; type, value, plus, minus, bars = :both, direction = :y) -> Chart
    deleteErrorBars(c, i) -> Chart

Error bars on series `i` (XLSX.jl reads them; LibreOffice stores them, D-076): `type` `:fixed`,
`:percent` or `:stdDev` (with `value`), `:stdErr`, or `:range` (with the cells `plus` and `minus`);
`bars` `:both`, `:plus` or `:minus`; `direction` `:y` or `:x` (XY charts).
"""
function setErrorBars(c::Chart, i::Integer; type::Symbol, value = nothing, plus = nothing, minus = nothing,
                      bars::Symbol = :both, direction::Symbol = :y)
    haskey(_ERR_ODF, type) || throw(ODSError("Unknown error bar type `:$type`: use :fixed, :percent, :stdDev, :stdErr or :range."))
    bars in (:both, :plus, :minus) || throw(ODSError("`bars` is :both, :plus or :minus."))
    direction in (:x, :y) || throw(ODSError("`direction` is :x or :y."))
    type in (:fixed, :percent, :stdDev) && !(value isa Real) && throw(ODSError("Error bars of type `:$type` need a `value`."))
    type === :range && plus === nothing && minus === nothing && throw(ODSError("Error bars from cells need `plus` or `minus`."))
    o = _editable(c)
    deleteErrorBars(c, i)
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
deleteErrorBars(c::Chart, i::Integer) = (o = _editable(c); _remove_in_series!(o, i, r"<chart:error-indicator\b[^>]*/>"); c)

# Inserts a child of series `i` before the first of the children `before` (ODF's order), else last.
function _insert_in_series!(o, i, xml; before = ())
    st = _series_start(o, i)
    if endswith(st.match, "/>")
        o.text = o.text[1:st.at-1] * st.match[1:end-2] * ">" * xml * "</chart:series>" * o.text[st.at+ncodeunits(st.match):end]
    else
        a = st.at + ncodeunits(st.match)
        e = first(findnext("</chart:series>", o.text, a))
        for b in before
            r = findnext(b, o.text, a)
            r !== nothing && first(r) < e && (e = first(r))
        end
        o.text = o.text[1:e-1] * xml * o.text[e:end]
    end
end
function _remove_in_series!(o, i, rx)
    st = _series_start(o, i)
    endswith(st.match, "/>") && return
    e = findnext("</chart:series>", o.text, st.at)
    a = st.at + ncodeunits(st.match)
    o.text = o.text[1:a-1] * replace(o.text[a:first(e)-1], rx => "") * o.text[first(e):end]
end

"""
    setAxisLabelArrangement(c, ax; stagger = nothing, overlap = nothing, breakText = nothing) -> Chart

LibreOffice's label options of an axis (D-076): `stagger` (`:odd`, `:even`, `:none`), whether labels may
`overlap`, and whether they may break into lines.
"""
function setAxisLabelArrangement(c::Chart, ax; stagger = nothing, overlap = nothing, breakText = nothing)
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
`chart:pie-offset`, D-076).
"""
function setSeriesExplosion(c::Chart, i::Integer, pct::Integer; point = nothing)
    0 <= pct <= 100 || throw(ODSError("An explosion is 0 to 100 percent."))
    o = _editable(c)
    _chart_class(o) in ("chart:circle", "chart:ring") || throw(ODSError("Explosion is for pie and doughnut charts."))
    st = point === nothing ? _series_style!(o, i) : _point_style!(o, i, point)
    _set_style_attrs!(o, st, ["chart:pie-offset" => string(pct)])
    return c
end

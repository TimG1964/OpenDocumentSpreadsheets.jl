# Font, fill, border and alignment (phase 4): XLSX.jl's setters and getters, on ODF cell
# styles.
#
# The API follows XLSX.jl 0.13.4 (src/cellformats/font.jl, fill.jl, border.jl,
# alignment.jl, uniformstyle.jl; the keyword specs in src/types.jl; validation lists in
# src/cellformat-helpers.jl), MIT License, Copyright (c) 2018-2026 Felipe Noronha Tavares
# and other contributors. The implementation is OpenDocumentSpreadsheets's own: each setter is a transform
# of a cell style (`CellStyle` → `CellStyle`), applied once per distinct style in the target
# (`apply_format!`); ODF's form of each keyword is LibreOffice's (F-032, D-036). Getters
# return XLSX.jl's shapes (D-032), from the properties the cell's style resolves to.

#
# Resolved properties: the style's own over its parents' over the document's defaults
#

# The chain of a style: itself, then its parents (named styles), nearest first.
function _style_chain(st::StyleIndex, cs::CellStyle)
    sh = stylesheet(st)
    chain = CellStyle[cs]
    p = cs.parent
    while !isempty(p) && length(chain) < 32
        id = p == "Default" ? Int32(0) : get(st.ids, p, nothing)
        id === nothing && break
        pcs = sh.cells[id + 1]
        push!(chain, pcs)
        p = pcs.parent
    end
    return chain
end

"""
    resolved_props(st, cs::CellStyle; defaults=true) -> (cell, para, text)

The cell, paragraph and text properties a style shows, as `Dict`s of attribute values as
written: its own, over its parents', over (with `defaults`) the document's default cell
style.
"""
function resolved_props(st::StyleIndex, cs::CellStyle; defaults::Bool = true)
    chain = _style_chain(st, cs)
    defaults && push!(chain, stylesheet(st).default_cell)
    cell = Dict{String,String}(); para = Dict{String,String}(); text = Dict{String,String}()
    for s in Iterators.reverse(chain)
        merge!(cell, Dict(s.cell.attrs)); merge!(para, Dict(s.para.attrs)); merge!(text, Dict(s.text.attrs))
    end
    return cell, para, text
end
# by style id: cached, as a style id's properties never change (the Dicts are shared: callers
# must not change them)
resolved_props(st::StyleIndex, id::Integer; defaults::Bool = true) =
    get!(() -> resolved_props(st, cell_style(st, id); defaults), stylesheet(st).resolved, (Int32(id), defaults))

# The style a transform starts from for style id `id`: an automatic style itself; a named
# one (or Default) as the parent of a new automatic style.
function _base_style(st::StyleIndex, id::Integer)
    sh = stylesheet(st)
    return sh.automatic[id + 1] ? sh.cells[id + 1] : CellStyle(style_name(st, id))
end

# A memoised map from a style id to the id of that style transformed by `t`.
function _style_map(t::Function, st::StyleIndex)
    memo = Dict{Int32,Int32}()
    return id -> get!(memo, Int32(id)) do
        base = _base_style(st, id)
        new = t(base)
        new == base ? Int32(id) : add_cell_style!(st, new)
    end
end

"""
    writable_targets(x, ref) -> FormatTargets

`format_targets(x, ref...)`, with every sheet checked as writable. Setters call it before they
build their transform, which may add a font face or a data style to the file: a bad reference
or a read-only file then changes nothing.
"""
function writable_targets(x, ref)
    targets = format_targets(x, ref...)
    for (ws, _) in targets
        _require_writable(ws, "format cells")
    end
    return targets
end

"""
    apply_format!(t, targets) -> Union{String, Int}

Give every cell of `targets` (`format_targets`) the style it shows transformed by `t`
(`CellStyle` → `CellStyle`). Returns the new style's name for a single cell, else -1.
"""
function apply_format!(t::Function, targets::FormatTargets)
    for (ws, blocks) in targets
        _require_writable(ws, "format cells")
        _apply_map!(_style_map(t, get_odsfile(ws).styles), ws, blocks)
    end
    return _result(targets)
end

function _apply_map!(m::Function, ws::Worksheet, blocks::Vector{FormatBlock})
    for b in blocks
        if b.kind === :cells
            restyle_cells!(m, ws, b.rows, b.cols)
        elseif b.kind === :rows
            restyle_cells!(m, ws, b.rows, 1:SheetCore.MAX_COLS)
        else
            restyle_columns!(m, ws, b.cols)
        end
    end
end

function _result(targets::FormatTargets)
    one = _single_cell(targets)
    one === nothing && return -1
    ws, r, c = one
    return style_name(get_odsfile(ws).styles, effective_style(ws, r, c))
end

# Numbers as LibreOffice writes them in lengths: no trailing zeros.
function _fmt_num(x::Real)
    isinteger(x) && return string(Int(x))
    s = string(round(Float64(x); digits = 4))
    return occursin('.', s) ? rstrip(rstrip(s, '0'), '.') : s
end

# A length in points (`"0.74pt"`, `"0.026cm"`, `"1mm"`, `"0.01in"`), or `nothing`.
function _length_pt(s::AbstractString)
    m = match(r"^\s*(-?[0-9.]+)\s*(pt|cm|mm|in|px)?\s*$", s)
    m === nothing && return nothing
    x = tryparse(Float64, m.captures[1])
    x === nothing && return nothing
    u = something(m.captures[2], "pt")
    return u == "pt" ? x : u == "cm" ? x * 72 / 2.54 : u == "mm" ? x * 72 / 25.4 : u == "in" ? x * 72 : x * 0.75
end

_check_choice(what, v, valid) = v === nothing || v in valid ||
    throw(ODSError("Invalid $what: $v. Must be one of: $(join(valid, ", "))."))

const _Changes = Vector{Pair{String,Union{Nothing,String}}}

# The keyword specs, as XLSX.jl's: unknown keywords are refused, naming the setter.
function _check_keywords(caller::Symbol, kw)
    isempty(kw) && return
    k = first(keys(kw))
    throw(ODSError("`$caller` has no keyword `$k`."))
end

#
# Font
#

const _FONT_TWINS = Dict("fo:font-weight" => ("style:font-weight-asian", "style:font-weight-complex"),
                         "fo:font-style" => ("style:font-style-asian", "style:font-style-complex"),
                         "fo:font-size" => ("style:font-size-asian", "style:font-size-complex"),
                         "style:font-name" => ("style:font-name-asian", "style:font-name-complex"))
const _UNDER_KEYS = ("style:text-underline-style", "style:text-underline-width", "style:text-underline-color", "style:text-underline-type")
const _STRIKE_KEYS = ("style:text-line-through-style", "style:text-line-through-type")

# A font property's key and its Asian and complex-script twins' (cells and charts write all three).
_font_keys(k::AbstractString) = String[k, get(_FONT_TWINS, k, ())...]

# Sets a font property and, as LibreOffice does, its Asian and complex-script twins.
function _font_prop!(ch::_Changes, k::String, v::Union{Nothing,String})
    push!(ch, k => v)
    for t in get(_FONT_TWINS, k, ())
        push!(ch, t => v)
    end
end

function _font_transform(st::StyleIndex, caller::Symbol; bold::Union{Nothing,Bool} = nothing, italic::Union{Nothing,Bool} = nothing,
                         under::Union{Nothing,AbstractString} = nothing, strike::Union{Nothing,Bool} = nothing,
                         size::Union{Nothing,Real} = nothing, color = nothing, name::Union{Nothing,AbstractString} = nothing,
                         vertAlign::Union{Nothing,AbstractString} = nothing, kw...)
    _check_keywords(caller, kw)
    _check_choice("value for under", under, ("none", "single", "double"))
    size === nothing || 1 <= size <= 409 || throw(ODSError("Invalid size value: $size. Must be between 1 and 409."))
    _check_choice("vertAlign", vertAlign, ("superscript", "subscript", "baseline"))
    vertAlign in ("superscript", "subscript") &&
        throw(ODSError("`vertAlign=\"$vertAlign\"` can't be set: an ODF cell style has no superscript or subscript (D-036)."))
    ch = _Changes()
    bold === nothing || _font_prop!(ch, "fo:font-weight", bold ? "bold" : "normal")
    italic === nothing || _font_prop!(ch, "fo:font-style", italic ? "italic" : "normal")
    if under == "none"
        push!(ch, _UNDER_KEYS[1] => "none", _UNDER_KEYS[2] => nothing, _UNDER_KEYS[3] => nothing, _UNDER_KEYS[4] => nothing)
    elseif under !== nothing
        push!(ch, _UNDER_KEYS[1] => "solid", _UNDER_KEYS[2] => "auto", _UNDER_KEYS[3] => "font-color",
              _UNDER_KEYS[4] => (under == "double" ? "double" : nothing))
    end
    strike === nothing || push!(ch, _STRIKE_KEYS[1] => (strike ? "solid" : "none"), _STRIKE_KEYS[2] => (strike ? "single" : nothing))
    size === nothing || _font_prop!(ch, "fo:font-size", _fmt_num(size) * "pt")
    color === nothing || push!(ch, "fo:color" => SheetCore.odf_color(color))
    if name !== nothing
        _check_xml_text(name)
        _font_prop!(ch, "style:font-name", _escape_attr(add_font_face!(st, name)))
    end
    vertAlign == "baseline" && push!(ch, "style:text-position" => nothing)
    isempty(ch) && return identity
    return cs -> with_text(cs, setprops(cs.text, ch...))
end

"""
    CellFont(fontId, font, applyFont)

A cell's font, as [`getFont`](@ref) returns it. `fontId` is the name
of the cell's style (ODF has no font table).
"""
struct CellFont
    fontId::String
    font::Dict{String,Union{Nothing,Dict{String,String}}}
    applyFont::String
end

const _FONT_MAPPED = Set(["fo:font-weight", "fo:font-style", "fo:font-size", "style:font-name", "fo:font-family", "fo:color",
                          _UNDER_KEYS..., _STRIKE_KEYS..., (t for v in values(_FONT_TWINS) for t in v)...])

# LibreOffice's defaults when the document's default style says nothing (F-033).
const _LO_FONT = "Liberation Sans"
const _LO_SIZE = "10"

# (`own`: the properties the cell's styles set themselves; only those are reported under
# "odf:" keys, not the document's defaults, which hold languages and the like)
function _font_dict(text::Dict{String,String}, own::Dict{String,String} = Dict{String,String}())
    d = Dict{String,Union{Nothing,Dict{String,String}}}()
    w = get(text, "fo:font-weight", "normal")
    (w == "bold" || (tryparse(Int, w) !== nothing && parse(Int, w) >= 600)) && (d["b"] = nothing)
    get(text, "fo:font-style", "normal") in ("italic", "oblique") && (d["i"] = nothing)
    u = get(text, "style:text-underline-style", "none")
    if u != "none"
        d["u"] = get(text, "style:text-underline-type", "single") == "double" ? Dict("val" => "double") : nothing
    end
    get(text, "style:text-line-through-style", "none") != "none" && (d["strike"] = nothing)
    sz = get(text, "fo:font-size", nothing)
    p = sz === nothing ? nothing : _length_pt(sz)
    d["sz"] = Dict("val" => p === nothing ? _LO_SIZE : _fmt_num(p))
    nm = get(text, "style:font-name", nothing)
    if nm === nothing
        fam = get(text, "fo:font-family", nothing)
        nm = fam === nothing ? _LO_FONT : strip(fam, ['\'', '"'])
    end
    d["name"] = Dict("val" => XML.unescape(nm))
    c = get(text, "fo:color", nothing)
    if c !== nothing
        rgb = SheetCore.parse_odf_color(c)
        rgb === nothing || (d["color"] = Dict("rgb" => rgb))
    end
    for (k, v) in own
        k in _FONT_MAPPED || (d["odf:" * k] = Dict("val" => v))
    end
    return d
end

_applied(d::Dict{String,String}, keys) = any(k -> haskey(d, k), keys) ? "1" : "0"

function _get_font(ws::Worksheet, r::Int, c::Int)
    st = get_odsfile(ws).styles
    id = effective_style(ws, r, c)
    _, _, text = resolved_props(st, id)
    _, _, own = resolved_props(st, id; defaults = false)
    return CellFont(style_name(st, id), _font_dict(text, own), _applied(own, keys(own)))
end

#
# Fill
#

const VALID_FILL_PATTERNS = (
    "none", "solid", "mediumGray", "darkGray", "lightGray",
    "darkHorizontal", "darkVertical", "darkDown", "darkUp", "darkGrid", "darkTrellis",
    "lightHorizontal", "lightVertical", "lightDown", "lightUp", "lightGrid", "lightTrellis",
    "gray125", "gray0625")

# The weight (of 255) LibreOffice gives the foreground colour of a pattern it blends into
# one colour (experiment 013).
const _PATTERN_WEIGHT = Dict(
    "mediumGray" => 127, "darkHorizontal" => 127, "darkVertical" => 127, "darkDown" => 127, "darkUp" => 127, "darkGrid" => 127,
    "darkGray" => 191, "darkTrellis" => 191,
    "lightGray" => 63, "lightHorizontal" => 63, "lightVertical" => 63, "lightDown" => 63, "lightUp" => 63,
    "lightGrid" => 111, "lightTrellis" => 95, "gray125" => 31, "gray0625" => 15)

function _blend(fg::AbstractString, bg::AbstractString, a::Int)
    ch(s, i) = parse(Int, s[i:i+1]; base = 16)
    io = IOBuffer()
    print(io, '#')
    for i in (2, 4, 6)
        print(io, string(round(Int, (ch(fg, i) * a + ch(bg, i) * (255 - a)) / 255); base = 16, pad = 2))
    end
    return String(take!(io))
end

function _fill_transform(st::StyleIndex, caller::Symbol; pattern::Union{Nothing,AbstractString} = nothing,
                         fgColor = nothing, bgColor = nothing, kw...)
    _check_keywords(caller, kw)
    _check_choice("pattern", pattern, VALID_FILL_PATTERNS)
    fg = fgColor === nothing ? nothing : SheetCore.odf_color(fgColor)
    bg = bgColor === nothing ? nothing : SheetCore.odf_color(bgColor)
    return function (cs::CellStyle)
        cell, _, _ = resolved_props(st, cs)
        cur = get(cell, "fo:background-color", "transparent")
        cur = SheetCore.parse_odf_color(cur) === nothing ? nothing : cur
        new = if pattern == "none"
            "transparent"
        elseif pattern === nothing
            fg === nothing || cur === nothing ? nothing : fg          # a new colour for the fill there is
        elseif pattern == "solid"
            something(fg, cur, "#000000")
        else                                                           # blended, as LibreOffice does (D-036)
            _blend(something(fg, cur, "#000000"), something(bg, "#ffffff"), _PATTERN_WEIGHT[pattern])
        end
        new === nothing && return cs
        return with_cell(cs, setprops(cs.cell, "fo:background-color" => new))
    end
end

"""
    CellFill(fillId, fill, applyFill)

A cell's fill, as [`getFill`](@ref) returns it. `fillId` is the name
of the cell's style.
"""
struct CellFill
    fillId::String
    fill::Dict{String,Union{Nothing,Dict{String,String}}}
    applyFill::String
end

function _get_fill(ws::Worksheet, r::Int, c::Int)
    st = get_odsfile(ws).styles
    id = effective_style(ws, r, c)
    cell, _, _ = resolved_props(st, id; defaults = false)   # what the cell's styles set (D-032)
    own, _, _ = resolved_props(st, id; defaults = false)
    rgb = SheetCore.parse_odf_color(get(cell, "fo:background-color", "transparent"))
    pf = rgb === nothing ? Dict("patternType" => "none") : Dict("patternType" => "solid", "fgrgb" => rgb)
    return CellFill(style_name(st, id), Dict{String,Union{Nothing,Dict{String,String}}}("patternFill" => pf),
                    _applied(own, ("fo:background-color",)))
end

#
# Border
#

const VALID_BORDER_STYLES = (
    "none", "thin", "medium", "dashed", "dotted", "thick", "double", "hair",
    "mediumDashed", "dashDot", "mediumDashDot", "dashDotDot", "mediumDashDotDot", "slantDashDot")
const VALID_DIAGONAL_DIRECTIONS = ("up", "down", "both")

# XLSX.jl's border styles as LibreOffice's xlsx import writes them (F-032).
const _BORDER_ODF = Dict(
    "thin" => ("0.74pt", "solid"), "medium" => ("1.76pt", "solid"), "thick" => ("2.49pt", "solid"),
    "hair" => ("0.06pt", "solid"), "dotted" => ("0.74pt", "dotted"), "dashed" => ("0.74pt", "fine-dashed"),
    "mediumDashed" => ("1.76pt", "dashed"), "dashDot" => ("0.74pt", "dash-dot"), "mediumDashDot" => ("1.76pt", "dash-dot"),
    "dashDotDot" => ("0.74pt", "dash-dot-dot"), "mediumDashDotDot" => ("1.76pt", "dash-dot-dot"),
    "slantDashDot" => ("1.76pt", "fine-dashed"), "double" => ("1.76pt", "double-thin"))
const _DOUBLE_WIDTHS = "0.018cm 0.026cm 0.018cm"
const _SIDES = ("left", "right", "top", "bottom")

# An ODF border value (`"0.74pt solid #000000"`) as (XLSX.jl style, "FFRRGGBB"), or `nothing`.
function _parse_border(v::AbstractString)
    parts = split(strip(v))
    (isempty(parts) || parts[1] == "none" || "none" in parts || "hidden" in parts) && return nothing
    w = 0.74; style = "solid"; rgb = "FF000000"
    for p in parts
        x = _length_pt(p)
        if x !== nothing
            w = x
        elseif startswith(p, '#')
            rgb = something(SheetCore.parse_odf_color(p), rgb)
        elseif p in ("thin", "medium", "thick")
            w = p == "thin" ? 0.75 : p == "medium" ? 1.75 : 2.5
        else
            style = p
        end
    end
    thin = w <= 1.25
    s = if style in ("double", "double-thin")
        "double"
    elseif style == "dotted"
        "dotted"
    elseif style == "fine-dashed"
        thin ? "dashed" : "slantDashDot"
    elseif style == "dashed"
        thin ? "dashed" : "mediumDashed"
    elseif style == "dash-dot"
        thin ? "dashDot" : "mediumDashDot"
    elseif style == "dash-dot-dot"
        thin ? "dashDotDot" : "mediumDashDotDot"
    else
        w <= 0.3 ? "hair" : thin ? "thin" : w <= 2.1 ? "medium" : "thick"
    end
    return (s, rgb)
end

_border_value(style::AbstractString, color::AbstractString) =
    style == "none" ? "none" : (w_s = _BORDER_ODF[style]; "$(w_s[1]) $(w_s[2]) $color")

# The value of each side (and the diagonals) a style shows.
function _border_sides(cell::Dict{String,String})
    all4 = get(cell, "fo:border", nothing)
    sides = Dict{String,Union{Nothing,String}}(s => get(cell, "fo:border-$s", all4) for s in _SIDES)
    sides["up"] = get(cell, "style:diagonal-bl-tr", nothing)
    sides["down"] = get(cell, "style:diagonal-tl-br", nothing)
    return sides
end

# The new value of a side from a keyword (`["style" => …, "color" => …]`) and the old value.
function _merge_side(kw, old::Union{Nothing,String})
    d = Dict{String,Any}(String(k) => v for (k, v) in kw)
    for k in keys(d)
        k in ("style", "color", "direction") || throw(ODSError("A border takes `style`, `color` and, for `diagonal`, `direction`; not `$k`."))
    end
    o = old === nothing ? nothing : _parse_border(old)
    style = get(d, "style", o === nothing ? nothing : o[1])
    style === nothing && return old
    _check_choice("border style", style, VALID_BORDER_STYLES)
    color = haskey(d, "color") ? SheetCore.odf_color(d["color"]) : o === nothing ? "#000000" : "#" * lowercase(o[2][3:8])
    return _border_value(style, color)
end

const _BorderKw = Union{Nothing,AbstractVector{<:Pair}}

function _border_transform(st::StyleIndex, caller::Symbol; outside::_BorderKw = nothing, allsides::_BorderKw = nothing,
                           left::_BorderKw = nothing, right::_BorderKw = nothing, top::_BorderKw = nothing,
                           bottom::_BorderKw = nothing, diagonal::_BorderKw = nothing, kw...)
    _check_keywords(caller, kw)
    outside === nothing ||
        throw(ODSError("Keyword `outside` sets the border around a range: use it alone, with `setBorder` on a range."))
    if allsides !== nothing
        all(isnothing, (left, right, top, bottom)) ||
            throw(ODSError("Keyword `allsides` is incompatible with `left`, `right`, `top`, or `bottom`."))
        left = right = top = bottom = allsides
    end
    if diagonal !== nothing
        dir = get(Dict{String,Any}(String(k) => v for (k, v) in diagonal), "direction", nothing)
        _check_choice("diagonal direction", dir, VALID_DIAGONAL_DIRECTIONS)
    end
    given = Dict("left" => left, "right" => right, "top" => top, "bottom" => bottom)
    all(isnothing, values(given)) && diagonal === nothing && return identity
    return function (cs::CellStyle)
        cell, _, _ = resolved_props(st, cs)
        old = _border_sides(cell)
        new = Dict{String,Union{Nothing,String}}(s => (given[s] === nothing ? old[s] : _merge_side(given[s], old[s])) for s in _SIDES)
        ch = _Changes()
        if any(s -> given[s] !== nothing, _SIDES)
            vals = [new[s] for s in _SIDES]
            if all(v -> v !== nothing && v == vals[1], vals)       # one value for all sides: fo:border, as LibreOffice writes
                push!(ch, "fo:border" => vals[1])
                foreach(s -> push!(ch, "fo:border-$s" => nothing), _SIDES)
                push!(ch, "style:border-line-width" => (occursin("double", vals[1]) ? _DOUBLE_WIDTHS : nothing))
                foreach(s -> push!(ch, "style:border-line-width-$s" => nothing), _SIDES)
            else
                push!(ch, "fo:border" => nothing, "style:border-line-width" => nothing)
                for s in _SIDES
                    push!(ch, "fo:border-$s" => new[s])
                    push!(ch, "style:border-line-width-$s" => (new[s] !== nothing && occursin("double", new[s]) ? _DOUBLE_WIDTHS : nothing))
                end
            end
        end
        if diagonal !== nothing
            d = Dict{String,Any}(String(k) => v for (k, v) in diagonal)
            olddir = old["up"] !== nothing && old["down"] !== nothing ? "both" : old["up"] !== nothing ? "up" :
                     old["down"] !== nothing ? "down" : "both"
            dir = get(d, "direction", olddir)
            v = _merge_side(filter(p -> first(p) != "direction", d), something(old["up"], old["down"], Some(nothing)))
            for (key, on) in (("style:diagonal-bl-tr", dir in ("up", "both")), ("style:diagonal-tl-br", dir in ("down", "both")))
                push!(ch, key => (on ? v : (haskey(cell, key) ? "none" : nothing)))
                push!(ch, key * "-widths" => (on && v !== nothing && occursin("double", v) ? _DOUBLE_WIDTHS : nothing))
            end
        end
        return with_cell(cs, setprops(cs.cell, ch...))
    end
end

"""
    CellBorder(borderId, border, applyBorder)

A cell's borders, as [`getBorder`](@ref) returns them. `borderId` is
the name of the cell's style.
"""
struct CellBorder
    borderId::String
    border::Dict{String,Union{Nothing,Dict{String,String}}}
    applyBorder::String
end

const _BORDER_KEYS = ("fo:border", "fo:border-left", "fo:border-right", "fo:border-top", "fo:border-bottom",
                      "style:diagonal-bl-tr", "style:diagonal-tl-br")

function _get_border(ws::Worksheet, r::Int, c::Int)
    st = get_odsfile(ws).styles
    id = effective_style(ws, r, c)
    cell, _, _ = resolved_props(st, id; defaults = false)
    own, _, _ = resolved_props(st, id; defaults = false)
    sides = _border_sides(cell)
    d = Dict{String,Union{Nothing,Dict{String,String}}}()
    for s in _SIDES
        b = sides[s] === nothing ? nothing : _parse_border(sides[s])
        d[s] = b === nothing ? nothing : Dict("style" => b[1], "rgb" => b[2])
    end
    up = sides["up"] === nothing ? nothing : _parse_border(sides["up"])
    down = sides["down"] === nothing ? nothing : _parse_border(sides["down"])
    diag = something(up, down, Some(nothing))
    d["diagonal"] = diag === nothing ? nothing :
        Dict("style" => diag[1], "rgb" => diag[2], "direction" => up !== nothing && down !== nothing ? "both" : up !== nothing ? "up" : "down")
    return CellBorder(style_name(st, id), d, _applied(own, _BORDER_KEYS))
end

#
# Alignment
#

const VALID_HORIZONTAL_ALIGNMENTS = ("left", "center", "right", "fill", "justify", "centerContinuous", "distributed")
const VALID_VERTICAL_ALIGNMENTS = ("top", "center", "bottom", "justify", "distributed")
const _INDENT_CM = 0.286          # per level (F-032)

function _alignment_transform(st::StyleIndex, caller::Symbol; horizontal::Union{Nothing,AbstractString} = nothing,
                              vertical::Union{Nothing,AbstractString} = nothing, wrapText::Union{Nothing,Bool} = nothing,
                              shrink::Union{Nothing,Bool} = nothing, indent::Union{Nothing,Integer} = nothing,
                              rotation::Union{Nothing,Integer} = nothing, kw...)
    _check_keywords(caller, kw)
    _check_choice("horizontal alignment", horizontal, VALID_HORIZONTAL_ALIGNMENTS)
    _check_choice("vertical alignment", vertical, VALID_VERTICAL_ALIGNMENTS)
    indent === nothing || indent >= 0 || throw(ODSError("Invalid indent value: $indent. Must be a positive integer."))
    rotation === nothing || rotation in -90:90 ||
        throw(ODSError("Invalid rotation value: $rotation. Must be an integer between -90 and 90."))
    cell = _Changes(); para = _Changes()
    if horizontal !== nothing
        push!(cell, "style:text-align-source" => "fix", "style:repeat-content" => (horizontal == "fill" ? "true" : nothing))
        a = horizontal in ("left", "fill") ? "start" : horizontal == "right" ? "end" :
            horizontal in ("justify", "distributed") ? "justify" : "center"
        push!(para, "fo:text-align" => a)
    end
    vertical === nothing || push!(cell, "style:vertical-align" => (vertical == "center" ? "middle" :
                                                                   vertical == "distributed" ? "justify" : vertical))
    wrapText === nothing || push!(cell, "fo:wrap-option" => (wrapText ? "wrap" : "no-wrap"))
    shrink === nothing || push!(cell, "style:shrink-to-fit" => string(shrink))
    indent === nothing || push!(para, "fo:margin-left" => _fmt_num(indent * _INDENT_CM) * "cm")
    rotation === nothing || push!(cell, "style:rotation-angle" => string(mod(rotation, 360)))
    isempty(cell) && isempty(para) && return identity
    return cs -> with_para(with_cell(cs, setprops(cs.cell, cell...)), setprops(cs.para, para...))
end

"""
    CellAlignment(alignment, applyAlignment)

A cell's alignment, as [`getAlignment`](@ref) returns it:
`alignment["alignment"]` holds the attributes (`horizontal`, `vertical`, `wrapText`,
`shrinkToFit`, `indent`, `textRotation`) that the cell's style sets.
"""
struct CellAlignment
    alignment::Dict{String,Union{Nothing,Dict{String,String}}}
    applyAlignment::String
end

const _ALIGN_CELL_KEYS = ("style:text-align-source", "style:vertical-align", "fo:wrap-option", "style:shrink-to-fit",
                          "style:rotation-angle", "style:repeat-content")
const _ALIGN_PARA_KEYS = ("fo:text-align", "fo:margin-left")

function _get_alignment(ws::Worksheet, r::Int, c::Int)
    st = get_odsfile(ws).styles
    id = effective_style(ws, r, c)
    cell, para, _ = resolved_props(st, id; defaults = false)
    owncell, ownpara, _ = resolved_props(st, id; defaults = false)
    a = Dict{String,String}()
    h = get(para, "fo:text-align", nothing)
    if h !== nothing
        a["horizontal"] = get(cell, "style:repeat-content", "false") == "true" ? "fill" :
            h in ("start", "left") ? "left" : h in ("end", "right") ? "right" : h
    end
    v = get(cell, "style:vertical-align", nothing)
    v === nothing || v == "automatic" || (a["vertical"] = v == "middle" ? "center" : v)
    w = get(cell, "fo:wrap-option", nothing)
    w === nothing || (a["wrapText"] = w == "wrap" ? "1" : "0")
    s = get(cell, "style:shrink-to-fit", nothing)
    s === nothing || (a["shrinkToFit"] = s == "true" ? "1" : "0")
    m = get(para, "fo:margin-left", nothing)
    if m !== nothing
        p = _length_pt(m)
        p === nothing || (a["indent"] = string(round(Int, p * 2.54 / 72 / _INDENT_CM)))
    end
    rot = get(cell, "style:rotation-angle", nothing)
    if rot !== nothing
        x = tryparse(Float64, replace(rot, "deg" => ""))
        x === nothing || (deg = round(Int, x); a["textRotation"] = string(deg > 180 ? deg - 360 : deg))
    end
    applied = any(k -> haskey(owncell, k), _ALIGN_CELL_KEYS) || any(k -> haskey(ownpara, k), _ALIGN_PARA_KEYS)
    return CellAlignment(Dict{String,Union{Nothing,Dict{String,String}}}("alignment" => a), applied ? "1" : "0")
end

#
# The public setters and getters
#

const _SETTERS = (
    (:setFont, :_font_transform, "font"),
    (:setFill, :_fill_transform, "fill"),
    (:setBorder, :_border_transform, "borders"),
    (:setAlignment, :_alignment_transform, "alignment"),
)

_styles_of(x::Worksheet) = get_odsfile(x).styles
_styles_of(x::ODSFile) = x.styles

for (F, T, _) in _SETTERS
    if F === :setBorder
        @eval function $F(x::Union{Worksheet,ODSFile}, ref...; outside::_BorderKw = nothing, kw...)
            outside === nothing || return _set_outside_border(x, ref, outside, kw)
            t = writable_targets(x, ref)
            return apply_format!($T(_styles_of(x), $(QuoteNode(F)); kw...), t)
        end
    else
        @eval function $F(x::Union{Worksheet,ODSFile}, ref...; kw...)
            t = writable_targets(x, ref)
            return apply_format!($T(_styles_of(x), $(QuoteNode(F)); kw...), t)
        end
    end
end

"""
    setFont(sheet, ref; bold, italic, under, strike, size, color, name) -> String or -1
    setFont(sheet, row, col; …)
    setFont(xf, "Sheet1.A1:B2"; …)

Set font attributes of a cell, a range, whole columns (`"A:C"`, `(sheet, :, 2:4)`), whole
rows (`"3:5"`, `(sheet, 2, :)`), a list of ranges (`"A1:B2,D4"`) or a defined name; rows and
columns can also be integers, ranges, vectors or `:`. Only the attributes given change.

- `bold`, `italic`, `strike`: `true` or `false`
- `under`: `"single"`, `"double"` or `"none"`
- `size`: in points, 1 to 409
- `color`: a hex colour (`"FF0000"`, `"#FF0000"`, `"FFFF0000"`), a Colors.jl name or a `Colorant`
- `name`: a font name (declared as a font face in the file)
- `vertAlign`: only `"baseline"`; ODF cells have no superscript or subscript

As in LibreOffice, empty cells are formatted too, and whole columns and rows are formatted
as such, not only up to the used area. Returns the name of the cell's new style for a
single cell, else -1.

```julia
setFont(sh, "A1:B1"; bold = true, color = "1F4E79")
setFont(sh, "A:A"; name = "Liberation Serif", size = 12)   # all of column A
```
"""
setFont

"""
    setFill(sheet, ref; pattern, fgColor, bgColor) -> String or -1

Set the background of cells, LibreOffice's Format ▸ Cells ▸ Background (address forms as
[`setFont`](@ref)). For a plain colour give `pattern = "solid"` and the colour as `fgColor`:
`setFill(sheet, "A1:C1"; pattern = "solid", fgColor = "DDEEFF")`; without `pattern`, nothing is
filled. `pattern = "none"` removes the background.

The names come from patterned fills, where `fgColor` is the pattern's colour and `bgColor` the
colour behind it. OpenDocument cells have no patterns: another `pattern` blends `fgColor` into
`bgColor` (white by default) into one colour.

```julia
setFill(sh, "A1:B1"; pattern = "solid", fgColor = "DDEEFF")   # a light blue background
setFill(sh, "A1"; pattern = "none")                            # no background
```
"""
setFill

"""
    setBorder(sheet, ref; left, right, top, bottom, diagonal, allsides, outside) -> String or -1

Set cell borders (address forms as [`setFont`](@ref)). Each side is a vector of pairs:
`["style" => "thin", "color" => "red"]`; `diagonal` also takes `"direction" => "up"`,
`"down"` or `"both"`. `allsides` sets the four sides. `outside` sets the border around a
range as a whole, alone. Styles are `"thin"`, `"medium"`, `"thick"`, `"dashed"`, `"dotted"`, `"double"` and the others,
written as LibreOffice writes them.

```julia
setBorder(sh, "A1:B4"; allsides = ["style" => "thin", "color" => "black"])   # every cell's four sides
setBorder(sh, "A1:B4"; outside = ["style" => "medium", "color" => "1F4E79"]) # round the whole range
setBorder(sh, "A1"; bottom = ["style" => "double"])
```
"""
setBorder

"""
    setAlignment(sheet, ref; horizontal, vertical, wrapText, shrink, indent, rotation) -> String or -1

Set cell alignment (address forms as [`setFont`](@ref)): `horizontal` (`"left"`, `"center"`,
`"right"`, `"fill"`, `"justify"`, `"centerContinuous"`, `"distributed"`), `vertical`
(`"top"`, `"center"`, `"bottom"`, `"justify"`, `"distributed"`), `wrapText`, `shrink`,
`indent` (levels of 0.286 cm) and `rotation` (−90 to 90 degrees).

```julia
setAlignment(sh, "A1:B1"; horizontal = "center", wrapText = true)
setAlignment(sh, "C1"; rotation = 45)
```
"""
setAlignment

# `outside`: the four edges of a range, each restyled with its side only.
function _set_outside_border(x, ref, outside, kw)
    isempty(kw) || throw(ODSError("Keyword `outside` is incompatible with any other keywords."))
    st = _styles_of(x)
    targets = writable_targets(x, ref)
    for (ws, blocks) in targets
        length(blocks) == 1 && length(targets) == 1 ||
            throw(ODSError("An outside border needs one rectangular range, not a list of ranges or vectors."))
        b = blocks[1]
        b.kind === :cells && length(b.rows) == 1 && length(b.cols) == 1 &&
            throw(ODSError("Keyword `outside` sets the border around a range, so it can't be used for a single cell."))
        dim = get_dimension(ws)
        rows = b.kind === :cols ? (row_number(dim.start):row_number(dim.stop)) : b.rows
        cols = b.kind === :rows ? (column_number(dim.start):column_number(dim.stop)) : b.cols
        r1, r2, c1, c2 = first(rows), last(rows), first(cols), last(cols)
        side(; kw...) = _style_map(_border_transform(st, :setBorder; kw...), st)
        if b.kind === :cols
            restyle_columns!(side(left = outside), ws, c1:c1)
            restyle_columns!(side(right = outside), ws, c2:c2)
        else
            restyle_cells!(side(left = outside), ws, rows, c1:c1)
            restyle_cells!(side(right = outside), ws, rows, c2:c2)
        end
        if b.kind === :rows
            _apply_map!(side(top = outside), ws, [_rowblock(r1:r1)])
            _apply_map!(side(bottom = outside), ws, [_rowblock(r2:r2)])
        else
            restyle_cells!(side(top = outside), ws, r1:r1, cols)
            restyle_cells!(side(bottom = outside), ws, r2:r2, cols)
        end
    end
    return -1
end

for (F, G, what) in ((:getFont, :_get_font, "font"), (:getFill, :_get_fill, "fill"), (:getBorder, :_get_border, "borders"),
                     (:getAlignment, :_get_alignment, "alignment"))
    @eval function $F(x::Union{Worksheet,ODSFile}, ref...)
        ws, r, c = format_cell(x, ref...)
        return $G(ws, r, c)
    end
end

"""
    getFont(sheet, ref) -> CellFont
    getFont(sheet, row, col) / getFont(xf, "Sheet1.A1")

The font of one cell: `font` holds `"b"`, `"i"`, `"strike"`
(`=> nothing` when set), `"u"` (`nothing` for single, `Dict("val" => "double")`), `"sz"`,
`"name"` and `"color"` (`Dict("rgb" => "FFRRGGBB")`), and other ODF text properties under
`"odf:…"` keys. The values are those the cell's style resolves to, through its parent styles
and the document's defaults; an unformatted cell, even an empty one, reports the default
font. Works on read-only files.
"""
getFont

"""
    getFill(sheet, ref) -> CellFill

The background of one cell: `fill["patternFill"]` is `Dict("patternType" => "solid",
"fgrgb" => "FFRRGGBB")`, or `Dict("patternType" => "none")`.
"""
getFill

"""
    getBorder(sheet, ref) -> CellBorder

The borders of one cell: `border["left"]` (and `right`, `top`, `bottom`) is
`Dict("style" => …, "rgb" => "FFRRGGBB")` or `nothing`; `border["diagonal"]` also has
`"direction"`.
"""
getBorder

"""
    getAlignment(sheet, ref) -> CellAlignment

The alignment of one cell: `alignment["alignment"]` holds the attributes the cell's style
sets.
"""
getAlignment

"""
    getDefaultFont(sheet) -> CellFont

The font of an unformatted cell.
"""
function getDefaultFont(ws::Worksheet)
    st = get_odsfile(ws).styles
    _, _, text = resolved_props(st, 0)
    return CellFont("Default", _font_dict(text), "0")
end

#
# Uniform setters: format the first cell, then copy that part of its style to the rest
#

# The keys each family copies: (cell keys, paragraph keys, whole text properties?).
const _BORDER_COPY = (_BORDER_KEYS..., "style:border-line-width", "style:border-line-width-left", "style:border-line-width-right",
                      "style:border-line-width-top", "style:border-line-width-bottom", "style:diagonal-bl-tr-widths",
                      "style:diagonal-tl-br-widths")

function _copy_transform(st::StyleIndex, from::CellStyle, family::Symbol)
    cell, para, text = resolved_props(st, from; defaults = false)
    if family === :font
        p = PropSet(sort!(collect(text); by = first), from.text.inner)
        return cs -> with_text(cs, p)
    end
    keys_cell, keys_para = family === :fill ? (("fo:background-color",), ()) :
                           family === :border ? (_BORDER_COPY, ()) : (_ALIGN_CELL_KEYS, _ALIGN_PARA_KEYS)
    ccell = Pair{String,Union{Nothing,String}}[k => get(cell, k, nothing) for k in keys_cell]
    family === :fill && ccell[1].second === nothing && (ccell[1] = "fo:background-color" => "transparent")
    cpara = Pair{String,Union{Nothing,String}}[k => get(para, k, nothing) for k in keys_para]
    return cs -> with_para(with_cell(cs, setprops(cs.cell, ccell...)), setprops(cs.para, cpara...))
end

for (F, T, fam) in ((:setUniformFont, :_font_transform, :font), (:setUniformFill, :_fill_transform, :fill),
                    (:setUniformBorder, :_border_transform, :border), (:setUniformAlignment, :_alignment_transform, :alignment))
    @eval function $F(x::Union{Worksheet,ODSFile}, ref...; kw...)
        st = _styles_of(x)
        targets = writable_targets(x, ref)
        t = $T(st, $(QuoteNode(F)); kw...)
        ws, r, c = _first_cell(targets)
        first_id = _style_map(t, st)(effective_style(ws, r, c))
        apply_format!(_copy_transform(st, cell_style(st, first_id), $(QuoteNode(fam))), targets)
        return style_name(st, effective_style(ws, r, c))
    end
end

"""
    setUniformFont(sheet, ref; kw...) -> String

Format the first (top-left) cell of `ref` with [`setFont`](@ref)'s keywords, then give every
cell of `ref` that cell's font. Returns the first cell's style name. `setUniformFill`,
`setUniformBorder` and `setUniformAlignment` do the same for fills, borders and alignment.
"""
setUniformFont

"""
    setUniformFill(sheet, ref; kw...) -> String

See [`setUniformFont`](@ref).
"""
setUniformFill

"""
    setUniformBorder(sheet, ref; kw...) -> String

See [`setUniformFont`](@ref). `outside` can't be used.
"""
setUniformBorder

"""
    setUniformAlignment(sheet, ref; kw...) -> String

See [`setUniformFont`](@ref).
"""
setUniformAlignment

"""
    setUniformStyle(sheet, ref) -> String

Give every cell of `ref` the style of its first (top-left) cell. Returns that style's name.
"""
function setUniformStyle(x::Union{Worksheet,ODSFile}, ref...)
    targets = writable_targets(x, ref)
    ws, r, c = _first_cell(targets)
    id = effective_style(ws, r, c)
    for (w, blocks) in targets
        _apply_map!(_ -> id, w, blocks)
    end
    return style_name(_styles_of(x), id)
end

# How the cell format types show (issue #1's audit): their style and the attributes set, not the Dict.
# One line: `CellFont("Default": name = Liberation Sans, sz = 10)`; `text/plain`, one attribute a line.
# A `nothing` attribute is a flag that is on in a font (`"b" => nothing`, bold) and an unset side in a border.
function _attr_items(d::Dict{String,Union{Nothing,Dict{String,String}}}, flags::Bool)
    items = String[]
    for k in sort!(collect(keys(d)))
        v = d[k]
        if v === nothing
            flags && push!(items, k)
        elseif length(v) == 1 && haskey(v, "val")
            push!(items, "$k = $(v["val"])")
        elseif isempty(v)
            continue
        else
            push!(items, k == _only_key(d) ? join(("$a = $(v[a])" for a in sort!(collect(keys(v)))), ", ") :
                         "$k(" * join(("$a = $(v[a])" for a in sort!(collect(keys(v)))), ", ") * ")")
        end
    end
    return items
end
# A Dict whose one key only names the group (`"alignment"`, `"numFmt"`, `"patternFill"`): its attributes
# show without it.
_only_key(d) = length(d) == 1 ? first(keys(d)) : nothing

_format_parts(f::CellFont) = (f.fontId, f.font)
_format_parts(f::CellFill) = (f.fillId, f.fill)
_format_parts(f::CellBorder) = (f.borderId, f.border)
_format_parts(f::CellAlignment) = (nothing, f.alignment)

function _show_cell_format(io::IO, x, multiline::Bool)
    id, d = _format_parts(x)
    items = _attr_items(d, x isa CellFont)
    print(io, nameof(typeof(x)), "(", id === nothing ? "" : repr(id) * (multiline ? ")" : ": "))
    if multiline
        id === nothing && print(io, ")")
        isempty(items) ? print(io, "\n  (nothing set)") : foreach(s -> print(io, "\n  ", s), items)
    else
        print(io, isempty(items) ? "nothing set" : join(items, ", "), ")")
    end
end
Base.show(io::IO, x::Union{CellFont,CellFill,CellBorder,CellAlignment}) = _show_cell_format(io, x, false)
Base.show(io::IO, ::MIME"text/plain", x::Union{CellFont,CellFill,CellBorder,CellAlignment}) = _show_cell_format(io, x, true)

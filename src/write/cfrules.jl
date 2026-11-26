# Conditional formats (phase 7, D-081): XLSX.jl's `setConditionalFormat` and `setColoredDataBars`, as
# LibreOffice's rules (F-073), written as LibreOffice's import writes XLSX.jl's (F-074), except where
# the import loses something LibreOffice can store (D-081):
#   - highlight rules are `calcext:condition`s (or `calcext:date-is`) applying a named cell style, one
#     per rule (`ConditionalStyle_N`, as the import names them), or any named style (`style`, D-076)
#   - colour scales, data bars and icon sets with XLSX.jl's presets, types and values
#   - a rule on the range of an existing format joins it as its last entry (its priority is its order)
# The API follows XLSX.jl dev (src/conditionalformats/setconditionalformat.jl, rules.jl, databar.jl,
# colorscale.jl, iconset.jl, presets.jl; src/conditional-format-helpers.jl), MIT License, Copyright
# (c) 2018-2026 Felipe Noronha Tavares and other contributors: the types, keywords, presets (dxStyles,
# data bars, colour scales, icon sets, the 52 icons) and checks, and their messages.

#
# XLSX.jl's presets (presets.jl), as LibreOffice stores them
#

# dxStyle => (font colour, background, border colour): the import's styles (F-074).
const _CF_DX = Dict(
    "redfilltext" => (font = ["color" => "FF9C0006"], fill = ["pattern" => "solid", "bgColor" => "FFFFC7CE"]),
    "yellowfilltext" => (font = ["color" => "FF9C5700"], fill = ["pattern" => "solid", "bgColor" => "FFFFEB9C"]),
    "greenfilltext" => (font = ["color" => "FF006100"], fill = ["pattern" => "solid", "bgColor" => "FFC6EFCE"]),
    "redfill" => (fill = ["pattern" => "solid", "bgColor" => "FFFFC7CE"],),
    "redtext" => (font = ["color" => "FF9C0006"],),
    "redborder" => (border = ["color" => "FF9C0006", "style" => "thin"],))

# Data bars: fill colour and gradient (the grad presets' borders can't be stored, and the import drops
# them too, F-074).
const _CF_DATABARS = Dict(
    "bluegrad" => ("638EC6", true), "greengrad" => ("63C384", true), "redgrad" => ("FF555A", true),
    "orangegrad" => ("FFB628", true), "lightbluegrad" => ("008AEF", true), "purplegrad" => ("D6007B", true),
    "blue" => ("638EC6", false), "green" => ("63C384", false), "red" => ("FF555A", false),
    "orange" => ("FFB628", false), "lightblue" => ("008AEF", false), "purple" => ("D6007B", false))

# Colour scales: (type, value, colour) per point.
const _CF_SCALES = Dict(
    "greenyellowred" => [("min", nothing, "F8696B"), ("percentile", "50", "FFEB84"), ("max", nothing, "63BE7B")],
    "redyellowgreen" => [("min", nothing, "63BE7B"), ("percentile", "50", "FFEB84"), ("max", nothing, "F8696B")],
    "greenwhitered" => [("min", nothing, "F8696B"), ("percentile", "50", "FCFCFF"), ("max", nothing, "63BE7B")],
    "redwhitegreen" => [("min", nothing, "63BE7B"), ("percentile", "50", "FCFCFF"), ("max", nothing, "F8696B")],
    "bluewhitered" => [("min", nothing, "F8696B"), ("percentile", "50", "FCFCFF"), ("max", nothing, "5A8AC6")],
    "redwhiteblue" => [("min", nothing, "5A8AC6"), ("percentile", "50", "FCFCFF"), ("max", nothing, "F8696B")],
    "whitered" => [("min", nothing, "F8696B"), ("max", nothing, "FCFCFF")],
    "redwhite" => [("min", nothing, "FCFCFF"), ("max", nothing, "F8696B")],
    "greenwhite" => [("min", nothing, "FCFCFF"), ("max", nothing, "63BE7B")],
    "whitegreen" => [("min", nothing, "63BE7B"), ("max", nothing, "FCFCFF")],
    "greenyellow" => [("min", nothing, "FFEF9C"), ("max", nothing, "63BE7B")],
    "yellowgreen" => [("min", nothing, "63BE7B"), ("max", nothing, "FFEF9C")])

# Icon sets: XLSX.jl's name => (LibreOffice's, number of icons). LibreOffice's own smiley sets are
# added (D-076).
const _CF_ICONSETS = Dict(
    "3Arrows" => ("3Arrows", 3), "4Arrows" => ("4Arrows", 4), "5Arrows" => ("5Arrows", 5),
    "3ArrowsGray" => ("3ArrowsGray", 3), "4ArrowsGray" => ("4ArrowsGray", 4), "5ArrowsGray" => ("5ArrowsGray", 5),
    "3TrafficLights" => ("3TrafficLights1", 3), "3TrafficLights2" => ("3TrafficLights2", 3),
    "4TrafficLights" => ("4TrafficLights", 4), "3Signs" => ("3Signs", 3), "4RedToBlack" => ("4RedToBlack", 4),
    "3Symbols" => ("3Symbols", 3), "3Symbols2" => ("3Symbols2", 3), "3Flags" => ("3Flags", 3),
    "5Quarters" => ("5Quarters", 5), "4Rating" => ("4Rating", 4), "5Rating" => ("5Rating", 5),
    "3Triangles" => ("3Triangles", 3), "3Stars" => ("3Stars", 3), "5Boxes" => ("5Boxes", 5),
    "3Smilies" => ("3Smilies", 3), "3ColorSmilies" => ("3ColorSmilies", 3))
const _CF_ICON_DEFAULTS = Dict(3 => ["33", "67"], 4 => ["25", "50", "75"], 5 => ["20", "40", "60", "80"])

# timePeriod operators as LibreOffice's periods; this, last and next year are LibreOffice's own (D-076).
const _CF_PERIODS = Dict("yesterday" => "yesterday", "today" => "today", "tomorrow" => "tomorrow", "last7Days" => "last-7-days",
    "lastWeek" => "last-week", "thisWeek" => "this-week", "nextWeek" => "next-week", "lastMonth" => "last-month",
    "thisMonth" => "this-month", "nextMonth" => "next-month", "thisYear" => "this-year", "lastYear" => "last-year",
    "nextYear" => "next-year")
const _CF_PERIOD_NAMES = ("yesterday", "today", "tomorrow", "last7Days", "lastWeek", "thisWeek", "nextWeek", "lastMonth",
                          "thisMonth", "nextMonth", "thisYear", "lastYear", "nextYear")

const CELLIS_OPERATORS = ("greaterThan", "greaterEqual", "lessThan", "lessEqual", "equal", "notEqual", "between", "notBetween")
const _CF_CELLIS = Dict("greaterThan" => ">", "greaterEqual" => ">=", "lessThan" => "<", "lessEqual" => "<=", "equal" => "=",
                        "notEqual" => "!=", "greaterThanOrEqual" => ">=", "lessThanOrEqual" => "<=")
const _CF_TOP10 = Dict("topN" => "top-elements", "bottomN" => "bottom-elements", "topN%" => "top-percent", "bottomN%" => "bottom-percent")
const _CF_AVERAGE = Dict("aboveAverage" => "above-average", "aboveEqAverage" => "above-equal-average",
                         "belowAverage" => "below-average", "belowEqAverage" => "below-equal-average")
const _CF_STDDEV = ("plus1StdDev", "plus2StdDev", "plus3StdDev", "minus1StdDev", "minus2StdDev", "minus3StdDev")
const _CF_TEXT = Dict("containsText" => "contains-text", "notContainsText" => "not-contains-text", "beginsWith" => "begins-with",
                      "endsWith" => "ends-with")

#
# Keywords
#

# A string keyword's value, given as a string, Symbol or (LibreOffice's convenience) a Bool.
function _cf_string(k::Symbol, v)
    (v === nothing || v isa String) && return v
    (v isa AbstractString || v isa Symbol) && return String(v)
    v isa Bool && return string(v)
    v isa Real && return _dv_num(v)
    throw(ODSError("`$k` must be a string, not $(repr(v))."))
end

const CF_FORMAT_KEYWORDS = (:dxStyle, :format, :font, :border, :fill, :style)

# A rule setter's keywords: `own` gives its own with their defaults; the format keywords follow.
function _cf_rule_keywords(allkws, own::NamedTuple)
    # not offered (D-084): LibreOffice has no such option, and applies the first true rule of a range
    haskey(allkws, :stopIfTrue) &&
        throw(ODSError("`stopIfTrue` is not supported: LibreOffice has no such option. It applies a range's rules in the order they were set, and the first that holds."))
    valid = (keys(own)..., CF_FORMAT_KEYWORDS...)
    for k in keys(allkws)
        k in valid || throw(ODSError("Invalid keyword argument: $k. Valid options are: $(join(("`$v`" for v in valid), ", "))."))
    end
    strings = NamedTuple{keys(own)}(map(k -> _cf_string(k, get(allkws, k, own[k])), keys(own)))
    dxStyle = _cf_string(:dxStyle, get(allkws, :dxStyle, nothing))
    style = _cf_string(:style, get(allkws, :style, nothing))
    pairs_(k) = (v = get(allkws, k, nothing); v === nothing || v isa AbstractVector{<:Pair} ? v :
                 throw(ODSError("`$k` is a vector of pairs, such as `$k = [\"color\" => \"red\"]`; got $(repr(v)).")))
    return (; strings..., dxStyle, style, format = pairs_(:format), font = pairs_(:font), border = pairs_(:border),
              fill = pairs_(:fill))
end

#
# Values: XLSX.jl's (numbers or cell references as strings; formulas) as LibreOffice's notation
#

# Excel's `Sheet!A1` inside a formula as LibreOffice's `$Sheet.A1` (D-014), outside string literals.
function _cf_sheet_refs(s::AbstractString)
    out = IOBuffer()
    parts = split(s, '"')
    for (i, p) in enumerate(parts)
        i > 1 && print(out, '"')
        print(out, isodd(i) ? replace(p, r"(?<![\w.$'])('(?:[^']|'')+'|[A-Za-z_][\w]*)!(\$?[A-Za-z]{1,3}\$?\d+(?::\$?[A-Za-z]{1,3}\$?\d+)?)" =>
                                         s"$\1.\2") : p)
    end
    return String(take!(out))
end

# A formula (with or without `=`) as LibreOffice stores it in a rule (OpenFormula, no prefix).
function _cf_formula(v::AbstractString, k::String)
    s = strip(v)
    startswith(s, '=') && (s = strip(s[nextind(s, 1):end]))
    isempty(s) && throw(ODSError("`$k` can't be empty."))
    return String(SubString(ui_to_openformula("=" * _cf_sheet_refs(s)), 5))
end

# A rule's value: a number, or a reference or formula.
_cf_value(xf::ODSFile, v::Union{Real,Dates.TimeType}, k::String) = _dv_expr(xf, v, k)
function _cf_value(xf::ODSFile, v::AbstractString, k::String)
    x = tryparse(Float64, strip(v))
    x === nothing || return _dv_num(x)
    return _cf_formula(v, k)
end
_cf_value(::ODSFile, v, k::String) = throw(ODSError("Invalid `$k`: $(repr(v)). Must be a number, a CellRef or a formula."))

_cf_isref(v::AbstractString) = is_valid_cellname(v) || SheetCore.is_valid_fixed_cellname(v) || SheetCore.is_valid_sheet_cellname(v) ||
                               SheetCore.is_valid_fixed_sheet_cellname(v)

#
# The format a highlight rule applies: a named style
#

# The display names of the file's styles (`ConditionalStyle_N` numbering).
function _cf_next_style(st::StyleIndex)
    sh = stylesheet(st)
    n = 0
    for k in Iterators.flatten((keys(sh.display), keys(st.ids)))
        m = match(r"^ConditionalStyle_(?:5f_)?(\d+)$", k)
        m === nothing || (n = max(n, parse(Int, m.captures[1])))
    end
    return "ConditionalStyle_$(n + 1)"
end

_cf_pairs(v) = Dict{String,Any}(String(first(p)) => last(p) for p in v)
_cf_true(v) = v === true || v == "true"

# XLSX.jl's differential format (font, fill, border, format pairs) as `addCellStyle!`'s keywords,
# translated as LibreOffice's import translates a dxf (F-074).
function _cf_style_keywords(kw)
    out = Dict{Symbol,Any}()
    if kw.font !== nothing
        f = _cf_pairs(kw.font)
        font = Dict{Symbol,Any}()
        for (k, v) in f
            k in ("color", "bold", "italic", "under", "strike", "name", "size") ||
                throw(ODSError("Invalid font attribute: $k. Valid options are: `color`, `bold`, `italic`, `under`, `strike` (and LibreOffice's `name`, `size`)."))
            if k == "color"
                font[:color] = v
            elseif k in ("bold", "italic", "strike")
                _cf_true(v) && (font[Symbol(k)] = true)
            elseif k == "under"
                string(v) in ("none", "single", "double") ||
                    throw(ODSError("Invalid font attribute value: under=$v. Valid options are: `none`, `single`, `double`."))
                string(v) == "none" || (font[:under] = string(v))
            elseif k == "name"
                font[:name] = string(v)
            else
                font[:size] = v isa Real ? v : parse(Float64, string(v))
            end
        end
        isempty(font) || (out[:font] = NamedTuple(font))
    end
    if kw.fill !== nothing
        f = _cf_pairs(kw.fill)
        for k in keys(f)
            k in ("pattern", "bgColor", "fgColor") || throw(ODSError("Invalid fill attribute: $k. Valid options are: `pattern`, `bgColor`, `fgColor`."))
        end
        p = string(get(f, "pattern", "solid"))
        fg = get(f, "fgColor", nothing); bg = get(f, "bgColor", nothing)
        if p in ("none", "solid")
            c = something(bg, fg, Some(nothing))           # a dxf's fill is its bgColor (F-074)
            c === nothing || (out[:fill] = (pattern = "solid", fgColor = c))
        elseif fg !== nothing || bg !== nothing
            out[:fill] = (pattern = p, fgColor = something(fg, "FF000000"), bgColor = something(bg, "FFFFFFFF"))
        end
    end
    if kw.border !== nothing
        b = _cf_pairs(kw.border)
        all(k -> k in ("color", "style"), keys(b)) || throw(ODSError("Invalid border attribute. Valid options are: `color`, `style`."))
        haskey(b, "style") && (out[:border] = (allsides = ["style" => string(b["style"]), "color" => get(b, "color", "FF000000")],))
    end
    if kw.format !== nothing
        f = _cf_pairs(kw.format)
        haskey(f, "format") && (out[:format] = string(f["format"]))
    end
    return out
end

# The display name of the style a highlight rule applies: `style` (D-076), else a new
# `ConditionalStyle_N` with `dxStyle`'s or the custom keywords' properties (`redfilltext` by default).
function _cf_rule_style(xf::ODSFile, kw)
    st = xf.styles
    if kw.style !== nothing
        (kw.dxStyle === nothing && all(isnothing, (kw.format, kw.font, kw.border, kw.fill))) ||
            throw(ODSError("`style` applies a named cell style: give it alone, without `dxStyle`, `format`, `font`, `border` or `fill`."))
        id = _named_style_id(st, kw.style)
        return _display_name(st, id == 0 ? "Default" : style_name(st, id))
    end
    dx = if kw.dxStyle !== nothing
        haskey(_CF_DX, kw.dxStyle) || throw(ODSError("Invalid dxStyle: $(kw.dxStyle). Valid options are: $(join(sort!(collect(keys(_CF_DX))), ", "))."))
        _CF_DX[kw.dxStyle]
    elseif all(isnothing, (kw.format, kw.font, kw.border, kw.fill))
        _CF_DX["redfilltext"]
    else
        (font = kw.font, fill = kw.fill, border = kw.border, format = kw.format)
    end
    full = (font = get(dx, :font, nothing), fill = get(dx, :fill, nothing), border = get(dx, :border, nothing),
            format = get(dx, :format, nothing))
    name = _cf_next_style(st)
    addCellStyle!(xf, name; _cf_style_keywords(full)...)
    return name
end

#
# Targets, and adding a rule
#

# A rule's target on a sheet: its areas, and the target and base addresses.
function _cf_target_of(ws::Worksheet, rng)
    areas = _cf_blocks(ws, rng)
    q = SheetCore.quoteit(ws.name)
    cell(r, c) = q * "." * SheetCore.encode_column_number(c) * string(r)
    target = join((cell(first(r), first(c)) * ":" * cell(last(r), last(c)) for (r, c) in areas), ' ')
    return areas, target, cell(first(areas[1][1]), first(areas[1][2]))
end

# Adds an entry (`entry`, its XML) to the rules of `ws` on `target`: as the last entry of a format on
# the same areas, else as a new format at the end (D-081).
function _cf_add!(ws::Worksheet, areas, target::String, entry::String)
    st = _cf_state(ws)
    k = findfirst(x -> _cf_areas(_cf_target(x)) == areas, st.list)
    if k === nothing
        push!(st.list, "<calcext:conditional-format calcext:target-range-address=\"" * _escape_attr(target) * "\">" *
                       entry * "</calcext:conditional-format>")
    else
        x = st.list[k]
        i = first(findlast("</calcext:conditional-format>", x))
        st.list[k] = x[1:prevind(x, i)] * entry * x[i:end]
    end
    st.edited = true
    return 0
end

_cf_attr(k::String, v::String) = " calcext:" * k * "=\"" * _escape_attr(v) * "\""

function _cf_condition(name::String, value::String, base::String)
    return "<calcext:condition" * _cf_attr("apply-style-name", name) * _cf_attr("value", value) * _cf_attr("base-cell-address", base) * "/>"
end

# The numbers of a range's cells (the cellIs default, the coloured bands): finite numbers only.
function _cf_numbers(ws::Worksheet, areas)
    dim = get_dimension(ws)
    out = Float64[]
    dim === nothing && return out
    for (rr, cc) in areas
        r1 = max(first(rr), row_number(dim.start)); r2 = min(last(rr), row_number(dim.stop))
        c1 = max(first(cc), column_number(dim.start)); c2 = min(last(cc), column_number(dim.stop))
        (r1 > r2 || c1 > c2) && continue
        for v in getdata(ws, CellRange(r1, c1, r2, c2))
            v isa Real && !(v isa Bool) && isfinite(v) && push!(out, Float64(v))
        end
    end
    return out
end

#
# The highlight rules
#

function _cf_cellis!(ws, areas, target, base, allkws)
    kw = _cf_rule_keywords(allkws, (; operator = "greaterThan", value = nothing, value2 = nothing))
    xf = get_odsfile(ws)
    op = kw.operator
    op in CELLIS_OPERATORS || op in ("greaterThanOrEqual", "lessThanOrEqual") ||
        throw(ODSError("Invalid `operator`: $op. Valid options are: $(join(("`$o`" for o in CELLIS_OPERATORS), ", "))"))
    v = kw.value
    if v === nothing
        # the average of the range's numbers, as XLSX.jl sets it
        nums = _cf_numbers(ws, areas)
        isempty(nums) && throw(ODSError("Give a `value`: the range has no numbers to take the average of."))
        a = _dv_num(sum(nums) / length(nums))
    else
        a = _cf_value(xf, v, "value")
    end
    if op in ("between", "notBetween")
        kw.value2 === nothing && throw(ODSError("Operator `$op` needs `value2` as well as `value`."))
        value = (op == "between" ? "between(" : "not-between(") * a * "," * _cf_value(xf, kw.value2, "value2") * ")"
    else
        value = _CF_CELLIS[op] * a
    end
    return _cf_add!(ws, areas, target, _cf_condition(_cf_rule_style(xf, kw), value, base))
end

function _cf_top10!(ws, areas, target, base, allkws)
    kw = _cf_rule_keywords(allkws, (; operator = "topN", value = "10"))
    haskey(_CF_TOP10, kw.operator) || throw(ODSError("Invalid operator: $(kw.operator). Valid options are: `topN`, `topN%`, `bottomN`, `bottomN%`."))
    xf = get_odsfile(ws)
    value = _CF_TOP10[kw.operator] * "(" * _cf_value(xf, kw.value, "value") * ")"
    return _cf_add!(ws, areas, target, _cf_condition(_cf_rule_style(xf, kw), value, base))
end

function _cf_average!(ws, areas, target, base, allkws)
    kw = _cf_rule_keywords(allkws, (; operator = "aboveAverage"))
    kw.operator in _CF_STDDEV &&
        throw(ODSError("`operator=\"$(kw.operator)\"` can't be stored: LibreOffice's above and below average rules have no standard deviations (D-081). Use `:expression` with a formula such as `B2>AVERAGE(\$B\$2:\$B\$20)+STDEV(\$B\$2:\$B\$20)`."))
    haskey(_CF_AVERAGE, kw.operator) ||
        throw(ODSError("Invalid operator: $(kw.operator). Valid options are: `aboveAverage`, `aboveEqAverage`, `belowAverage`, `belowEqAverage` (the standard deviations, `plus1StdDev` …, can't be stored in LibreOffice)."))
    xf = get_odsfile(ws)
    return _cf_add!(ws, areas, target, _cf_condition(_cf_rule_style(xf, kw), _CF_AVERAGE[kw.operator], base))
end

function _cf_text!(ws, areas, target, base, allkws, type::Symbol)
    if type !== :containsText
        haskey(allkws, :operator) && string(allkws[:operator]) != string(type) &&
            throw(ODSError("`operator=$(allkws[:operator])` conflicts with the conditional format type `:$type`. Omit `operator`: the type sets it."))
        allkws[:operator] = string(type)
    end
    kw = _cf_rule_keywords(allkws, (; operator = "containsText", value = nothing))
    kw.value === nothing && throw(ODSError("Invalid `value`: nothing. Must contain text or a CellRef."))
    haskey(_CF_TEXT, kw.operator) ||
        throw(ODSError("Invalid operator: $(kw.operator). Valid options are: `containsText`, `notContainsText`, `beginsWith`, `endsWith`."))
    # a cell reference as such (LibreOffice keeps it, F-075), else the text in quotes, its own quotes
    # not doubled: LibreOffice's form (`contains-text(""q"")` for `"q"`; it rewrites a doubled one so)
    operand = _cf_isref(kw.value) ? _cf_formula(kw.value, "value") : "\"" * kw.value * "\""
    xf = get_odsfile(ws)
    return _cf_add!(ws, areas, target, _cf_condition(_cf_rule_style(xf, kw), _CF_TEXT[kw.operator] * "(" * operand * ")", base))
end

function _cf_period!(ws, areas, target, base, allkws)
    kw = _cf_rule_keywords(allkws, (; operator = "last7Days"))
    haskey(_CF_PERIODS, kw.operator) ||
        throw(ODSError("Invalid operator: $(kw.operator). Valid options are: $(join(("`$p`" for p in _CF_PERIOD_NAMES), ", "))."))
    xf = get_odsfile(ws)
    e = "<calcext:date-is" * _cf_attr("style", _cf_rule_style(xf, kw)) * _cf_attr("date", _CF_PERIODS[kw.operator]) * "/>"
    return _cf_add!(ws, areas, target, e)
end

function _cf_special!(ws, areas, target, base, allkws, type::Symbol)
    kw = _cf_rule_keywords(allkws, NamedTuple())
    xf = get_odsfile(ws)
    cr = "[." * replace(last(split(base, '.')), "\$" => "") * "]"      # the top-left cell, relative
    value = type === :containsBlanks ? "formula-is(LEN(TRIM($cr))=0)" : type === :notContainsBlanks ? "formula-is(LEN(TRIM($cr))>0)" :
            type === :containsErrors ? "is-error" : type === :notContainsErrors ? "is-no-error" :
            type === :uniqueValues ? "unique" : "duplicate"
    return _cf_add!(ws, areas, target, _cf_condition(_cf_rule_style(xf, kw), value, base))
end

function _cf_expression!(ws, areas, target, base, allkws)
    kw = _cf_rule_keywords(allkws, (; formula = nothing))
    kw.formula === nothing && throw(ODSError("A `formula` must be provided as a keyword argument."))
    xf = get_odsfile(ws)
    value = "formula-is(" * _cf_formula(kw.formula, "formula") * ")"
    return _cf_add!(ws, areas, target, _cf_condition(_cf_rule_style(xf, kw), value, base))
end

#
# Thresholds of colour scales, data bars and icon sets (XLSX.jl's cfvo types and values)
#

# A threshold as LibreOffice's (type, value): `t` XLSX.jl's type, `v` its value (a number, a cell
# reference or, with `formula`, a formula). A reference with `num` is a formula to LibreOffice (its
# number entries hold numbers, F-073).
function _cf_threshold(xf::ODSFile, name::String, t::String, v, lo::String, hi::String)
    t == "min" && return ("minimum", "0")
    t == "max" && return ("maximum", "0")
    t == "least" && return ("minimum", "0")
    t == "highest" && return ("maximum", "0")
    t == "automatic" && return (lo, "0")
    v === nothing && throw(ODSError("Give `$(name)_val` for `$(name)_type=\"$t\"`."))
    s = _cf_string(Symbol(name * "_val"), v)
    x = tryparse(Float64, strip(s))
    if t == "formula" || (t == "num" && x === nothing)
        return ("formula", "=" * _cf_formula(s, name * "_val"))
    end
    x === nothing && throw(ODSError("Invalid $(name)_val: `$s`. With $(name)_type `$t`, LibreOffice stores a number (give `formula` for a reference)."))
    return (t == "num" ? "number" : t, _dv_num(x))
end

function _cf_check_type(name, t, types)
    t in types || throw(ODSError("Invalid $(name)_type: $t. Valid options are: $(join(types, ", "))."))
end

_cf_colour(c) = SheetCore.odf_color(c)

#
# Colour scales
#

function _cf_colorscale!(ws, areas, target, base, allkws)
    valid = (:colorscale, :min_type, :min_val, :min_col, :mid_type, :mid_val, :mid_col, :max_type, :max_val, :max_col)
    for k in keys(allkws)
        k in valid || throw(ODSError("Invalid keyword argument: $k. Valid options are: $(join(("`$v`" for v in valid), ", "))."))
    end
    xf = get_odsfile(ws)
    g(k, d = nothing) = get(allkws, k, d)
    points = if haskey(allkws, :colorscale)
        cs = _cf_string(:colorscale, allkws[:colorscale])
        haskey(_CF_SCALES, cs) || throw(ODSError("Invalid colorscale option chosen: $cs. Valid options are: $(join(sort!(collect(keys(_CF_SCALES))), ", "))."))
        [(t, v, c) for (t, v, c) in _CF_SCALES[cs]]
    else
        mn = _cf_string(:min_type, g(:min_type, "min")); mx = _cf_string(:max_type, g(:max_type, "max"))
        md = _cf_string(:mid_type, g(:mid_type))
        _cf_check_type("min", mn, ("min", "percentile", "percent", "num", "formula"))
        md === nothing || _cf_check_type("mid", md, ("percentile", "percent", "num", "formula"))
        _cf_check_type("max", mx, ("max", "percentile", "percent", "num", "formula"))
        p = Any[(mn, g(:min_val), g(:min_col, "FFF8696B"))]
        md === nothing || push!(p, (md, g(:mid_val), g(:mid_col, "FFFCFCFF")))
        push!(p, (mx, g(:max_val), g(:max_col, "FFFFEB84")))
        p
    end
    io = IOBuffer()
    print(io, "<calcext:color-scale>")
    for (i, (t, v, c)) in enumerate(points)
        name = i == 1 ? "min" : i == length(points) ? "max" : "mid"
        lt, lv = _cf_threshold(xf, name, t, v, "minimum", "maximum")
        print(io, "<calcext:color-scale-entry", _cf_attr("value", lv), _cf_attr("type", lt), _cf_attr("color", _cf_colour(c)), "/>")
    end
    print(io, "</calcext:color-scale>")
    return _cf_add!(ws, areas, target, String(take!(io)))
end

#
# Data bars
#

const DATABAR_KEYWORDS = (:databar, :showVal, :gradient, :borders, :sameNegFill, :sameNegBorders, :direction, :axis_pos, :axis_col,
    :min_type, :min_val, :max_type, :max_val, :fill_col, :border_col, :neg_fill_col, :neg_border_col, :minLength, :maxLength)

function _cf_databar!(ws, areas, target, base, allkws)
    for k in keys(allkws)
        k in DATABAR_KEYWORDS || throw(ODSError("Invalid keyword argument: $k. Valid options are: $(join(("`$v`" for v in DATABAR_KEYWORDS), ", "))."))
    end
    xf = get_odsfile(ws)
    s(k, d = nothing) = _cf_string(k, get(allkws, k, d))
    db = s(:databar, "bluegrad")
    haskey(_CF_DATABARS, db) || throw(ODSError("Invalid dataBar option chosen: $db. Valid options are: $(join(sort!(collect(keys(_CF_DATABARS))), ", "))"))
    fill, grad = _CF_DATABARS[db]
    for k in (:showVal, :gradient, :borders, :sameNegFill, :sameNegBorders)
        v = s(k)
        v === nothing || v in ("true", "false") || throw(ODSError("Invalid keyword $k: $v. Valid values are [\"true\", \"false\"]"))
    end
    # what LibreOffice's data bars can't show (D-081)
    s(:borders) == "true" && throw(ODSError("`borders=\"true\"` can't be stored: LibreOffice's data bars have no borders (D-081)."))
    for k in (:border_col, :neg_border_col)
        haskey(allkws, k) && throw(ODSError("`$k` can't be stored: LibreOffice's data bars have no borders (D-081)."))
    end
    s(:sameNegBorders) == "true" && throw(ODSError("`sameNegBorders` can't be stored: LibreOffice's data bars have no borders (D-081)."))
    dir = s(:direction)
    dir === nothing || dir in ("leftToRight", "rightToLeft") || throw(ODSError("Invalid keyword direction: $dir. Valid values are [\"leftToRight\", \"rightToLeft\"]"))
    dir == "rightToLeft" && throw(ODSError("`direction=\"rightToLeft\"` can't be stored: LibreOffice's data bars always run left to right (D-081)."))
    ax = s(:axis_pos)
    ax === nothing || ax in ("middle", "none") || throw(ODSError("Invalid keyword axis_pos: $ax. Valid values are [\"middle\", \"none\"]"))
    mnt = s(:min_type, "automatic"); mxt = s(:max_type, "automatic")
    _cf_check_type("min", mnt, ("least", "percentile", "percent", "num", "formula", "automatic"))
    _cf_check_type("max", mxt, ("highest", "percentile", "percent", "num", "formula", "automatic"))
    lt, lv = _cf_threshold(xf, "min", mnt, get(allkws, :min_val, nothing), "auto-minimum", "auto-maximum")
    ht, hv = _cf_threshold(xf, "max", mxt, get(allkws, :max_val, nothing), "auto-maximum", "auto-maximum")
    minl = get(allkws, :minLength, 10); maxl = get(allkws, :maxLength, 90)
    (minl isa Real && maxl isa Real && 0 <= minl <= maxl <= 100) ||
        throw(ODSError("`minLength` and `maxLength` are percentages of the cell's width, with 0 ≤ minLength ≤ maxLength ≤ 100."))
    io = IOBuffer()
    print(io, "<calcext:data-bar")
    s(:showVal) == "false" && print(io, _cf_attr("show-value", "false"))
    (s(:gradient) === nothing ? !grad : s(:gradient) == "false") && print(io, _cf_attr("gradient", "false"))
    minl == 0 || print(io, _cf_attr("min-length", _dv_num(minl)))
    print(io, _cf_attr("max-length", _dv_num(maxl)))
    s(:sameNegFill) == "true" || print(io, _cf_attr("negative-color", _cf_colour(get(allkws, :neg_fill_col, "FFFF0000"))))
    ax === nothing || print(io, _cf_attr("axis-position", ax))
    print(io, _cf_attr("positive-color", _cf_colour(get(allkws, :fill_col, fill))), _cf_attr("axis-color", _cf_colour(get(allkws, :axis_col, "FF000000"))), ">")
    print(io, "<calcext:formatting-entry", _cf_attr("value", lv), _cf_attr("type", lt), "/>")
    print(io, "<calcext:formatting-entry", _cf_attr("value", hv), _cf_attr("type", ht), "/></calcext:data-bar>")
    return _cf_add!(ws, areas, target, String(take!(io)))
end

#
# Icon sets
#

const ICONSET_KEYWORDS = (:iconset, :reverse, :showVal, :min_type, :min_val, :min_gte, :mid_type, :mid_val, :mid_gte,
    :mid2_type, :mid2_val, :mid2_gte, :max_type, :max_val, :max_gte, :icon_list)    # icon_list: for its error

function _cf_iconset!(ws, areas, target, base, allkws)
    for k in keys(allkws)
        k in ICONSET_KEYWORDS || throw(ODSError("Invalid keyword argument: $k. Valid options are: $(join(("`$v`" for v in ICONSET_KEYWORDS), ", "))."))
    end
    xf = get_odsfile(ws)
    s(k, d = nothing) = _cf_string(k, get(allkws, k, d))
    set = s(:iconset, "3TrafficLights")
    types = ("percentile", "percent", "num", "formula")
    th = [(n, s(Symbol(n, "_type")), get(allkws, Symbol(n, "_val"), nothing), s(Symbol(n, "_gte"))) for n in ("min", "mid", "mid2", "max")]
    for (n, t, _, _) in th
        t === nothing || _cf_check_type(n, t, types)
    end
    # what LibreOffice can't read back is not offered (D-084): custom icon sets, and so a reversed
    # set, which ODF can only write as custom icons (F-077)
    (set == "Custom" || haskey(allkws, :icon_list)) &&
        throw(ODSError("Custom icon sets (`iconset = \"Custom\"`, `icon_list`) are not supported: LibreOffice doesn't read them back from a file."))
    s(:reverse) == "true" &&
        throw(ODSError("`reverse = \"true\"` is not supported: ODF has no reversed icon set, and LibreOffice doesn't read back the custom icons that would stand for one."))
    haskey(_CF_ICONSETS, set) || throw(ODSError("Invalid iconset option chosen: $set. Valid options are: $(join(sort!(collect(keys(_CF_ICONSETS))), ", "))"))
    lotype, nicons = _CF_ICONSETS[set]
    used = nicons == 3 ? [1, 4] : nicons == 4 ? [1, 2, 4] : [1, 2, 3, 4]
    io = IOBuffer()
    print(io, "<calcext:icon-set", _cf_attr("icon-set-type", lotype))
    # values hidden: LibreOffice's reader takes `show-value="true"` on the icon set as "hide" (F-075)
    s(:showVal) == "false" && print(io, _cf_attr("show-value", "true"))
    print(io, ">")
    print(io, "<calcext:formatting-entry", _cf_attr("value", "0"), _cf_attr("type", "percent"), "/>")
    defaults = _CF_ICON_DEFAULTS[nicons]
    for (j, k) in enumerate(used)
        n, t, v, gte = th[k]
        lt, lv = _cf_threshold(xf, n, something(t, "percent"), something(v, defaults[j]), "percent", "percent")
        # XLSX.jl gives an icon set's formula thresholds parentheses, which the import keeps (F-074)
        t == "formula" && (lv = "=(" * lv[2:end] * ")")
        gte === nothing || gte in ("true", "false") || (gte = nothing)          # XLSX.jl ignores other values
        print(io, "<calcext:formatting-entry", _cf_attr("value", lv))
        gte == "false" && print(io, _cf_attr("greater_equal", "false"))
        print(io, _cf_attr("type", lt), "/>")
    end
    print(io, "</calcext:icon-set>")
    return _cf_add!(ws, areas, target, String(take!(io)))
end

#
# The API
#

const _CF_TYPES = (:cellIs, :top10, :aboveAverage, :containsText, :notContainsText, :beginsWith, :endsWith, :timePeriod,
    :containsErrors, :notContainsErrors, :containsBlanks, :notContainsBlanks, :uniqueValues, :duplicateValues, :expression,
    :dataBar, :colorScale, :iconSet)

function _cf_set!(ws::Worksheet, rng, type::Symbol, kw)
    _require_writable(ws, "set a conditional format")
    allkws = Dict{Symbol,Any}(k => v for (k, v) in pairs(kw))
    haskey(allkws, :priority) &&
        throw(ODSError("Invalid keyword argument: `priority`. Conditional format rules are prioritised in the order they are applied."))
    type in _CF_TYPES || throw(ODSError("Invalid conditional format type: $type."))
    areas, target, base = _cf_target_of(ws, rng)
    type === :cellIs && return _cf_cellis!(ws, areas, target, base, allkws)
    type === :top10 && return _cf_top10!(ws, areas, target, base, allkws)
    type === :aboveAverage && return _cf_average!(ws, areas, target, base, allkws)
    type in (:containsText, :notContainsText, :beginsWith, :endsWith) && return _cf_text!(ws, areas, target, base, allkws, type)
    type === :timePeriod && return _cf_period!(ws, areas, target, base, allkws)
    type in (:containsErrors, :notContainsErrors, :containsBlanks, :notContainsBlanks, :uniqueValues, :duplicateValues) &&
        return _cf_special!(ws, areas, target, base, allkws, type)
    type === :expression && return _cf_expression!(ws, areas, target, base, allkws)
    type === :colorScale && return _cf_colorscale!(ws, areas, target, base, allkws)
    type === :dataBar && return _cf_databar!(ws, areas, target, base, allkws)
    return _cf_iconset!(ws, areas, target, base, allkws)
end

"""
    setConditionalFormat(sheet, rng, type; kw...) -> 0
    setConditionalFormat(xf, "Sheet1.A1:B5", type; kw...) -> 0
    setConditionalFormat(sheet, rows, cols, type; kw...) -> 0

Add a conditional format to a range (a cell, a range, whole columns `"B:B"` or rows, several of these
separated by commas, or rows and columns given apart), stored as LibreOffice's conditional
format. `type` and its keywords:

- `:cellIs`: `operator` (`greaterThan` (default), `greaterEqual`, `lessThan`, `lessEqual`, `equal`,
  `notEqual`, `between`, `notBetween`), `value` (default: the mean of the range's numbers), `value2`
- `:top10`: `operator` (`topN` (default), `bottomN`, `topN%`, `bottomN%`), `value` (default `"10"`)
- `:aboveAverage`: `operator` (`aboveAverage` (default), `aboveEqAverage`, `belowAverage`,
  `belowEqAverage`)
- `:containsText`, `:notContainsText`, `:beginsWith`, `:endsWith`: `value`, the text or a cell reference
- `:timePeriod`: `operator` (`yesterday`, `today`, `tomorrow`, `last7Days` (default), `lastWeek`,
  `thisWeek`, `nextWeek`, `lastMonth`, `thisMonth`, `nextMonth`; and LibreOffice's `thisYear`,
  `lastYear`, `nextYear`)
- `:containsErrors`, `:notContainsErrors`, `:containsBlanks`, `:notContainsBlanks`, `:uniqueValues`,
  `:duplicateValues`: no keywords of their own
- `:expression`: `formula`, true for the cells to format (`"B2>\$D\$1"`, relative to the range's
  top-left cell)
- `:dataBar`: `databar` (a preset: `bluegrad` (default), `greengrad`, `redgrad`, `orangegrad`,
  `lightbluegrad`, `purplegrad`, `blue`, `green`, `red`, `orange`, `lightblue`, `purple`), `showVal`,
  `gradient`, `sameNegFill`, `axis_pos` (`"middle"`, `"none"`), `axis_col`, `fill_col`,
  `neg_fill_col`, `min_type`/`max_type` (`automatic` (default), `least`/`highest`, `num`, `percent`,
  `percentile`, `formula`) with `min_val`/`max_val`; and LibreOffice's `minLength`, `maxLength` (the
  shortest and longest bar, in percent of the cell; 10 and 90 by default)
- `:colorScale`: `colorscale` (a preset: `greenyellow` …), or `min_type`, `min_val`, `min_col`,
  `mid_type`, `mid_val`, `mid_col`, `max_type`, `max_val`, `max_col` (types `min`/`max`, `num`,
  `percent`, `percentile`, `formula`)
- `:iconSet`: `iconset` (`3TrafficLights` (default), `3Arrows`, `4Arrows`, `5Arrows`, `3ArrowsGray`,
  `4ArrowsGray`, `5ArrowsGray`, `3TrafficLights2`, `4TrafficLights`, `3Signs`, `4RedToBlack`,
  `3Symbols`, `3Symbols2`, `3Flags`, `5Quarters`, `4Rating`, `5Rating`, `3Triangles`, `3Stars`,
  `5Boxes`; and LibreOffice's `3Smilies`, `3ColorSmilies`), the thresholds `min_*`, `mid_*`,
  `mid2_*`, `max_*` (`_type`, `_val`, `_gte`), `showVal`

The highlight rules (all but data bars, colour scales and icon sets) format matching cells with
`dxStyle` (`redfilltext` (default), `yellowfilltext`, `greenfilltext`, `redfill`, `redtext`,
`redborder`) or with custom `format`, `font`, `border` and `fill`, each a vector of pairs
(`font = ["color" => "red", "bold" => "true"]`; a font may also have LibreOffice's `name`
and `size`). Each rule's format becomes a named cell style,
`ConditionalStyle_N`. `style` applies any named cell style instead
(`style = "Good"`; its built-in styles are added when used).

Values and thresholds are numbers or cell references given as strings, or formulas;
references are relative to the range's top-left cell. Formulas may use `Sheet.A1` or
`Sheet!A1`.

Rules are applied in the order they are set: a rule on the same range as an earlier one is its next
entry, as in LibreOffice, which applies the first true condition of a range. Options that
LibreOffice doesn't support are errors: `stopIfTrue`, the standard deviations of
`:aboveAverage`, data bar borders (`borders`, `border_col`, `neg_border_col`, `sameNegBorders`),
`direction="rightToLeft"`, custom icon sets (`iconset = "Custom"`, `icon_list`) and
`reverse = "true"`. Returns 0. The file must be writable.
"""
function setConditionalFormat end
setConditionalFormat(ws::Worksheet, rng, type::Symbol; kw...) = _cf_set!(ws, rng, type, kw)
setConditionalFormat(ws::Worksheet, rows, cols, type::Symbol; kw...) = _cf_set!(ws, _cf_rowscols(rows, cols), type, kw)
setConditionalFormat(xf::ODSFile, ref::AbstractString, type::Symbol; kw...) = setConditionalFormat(_dv_sheet_ref(xf, ref)..., type; kw...)

# (rows, cols) as a range `_cf_blocks` takes.
struct _RowsCols
    rows::Any
    cols::Any
end
_cf_rowscols(rows, cols) = _RowsCols(rows, cols)
_cf_blocks(ws::Worksheet, rc::_RowsCols) = _cf_blocks_rc(ws, rc.rows, rc.cols)
function _cf_blocks_rc(ws::Worksheet, rows, cols)
    out = _Area[]
    for (w, blocks) in format_targets(ws, rows, cols)
        for b in blocks
            push!(out, b.kind === :cells ? (b.rows, b.cols) : b.kind === :rows ? (b.rows, 1:SheetCore.MAX_COLS) : (1:SheetCore.MAX_ROWS, b.cols))
        end
    end
    isempty(out) && throw(ODSError("The range names no cells."))
    return out
end

"""
    setColoredDataBars(sheet, rng; bands=5, colors=["green", "red"], breaks=nothing, gte=true,
                       showVal, direction, min_type, min_val, max_type, max_val, clear=true) -> Vector{Pair}

Data bars whose colour changes with the value as well as their length: the cells of `rng` are split into bands of value (`bands` equal
intervals between the smallest and largest number, or `breaks`; a value on a break goes in the band
above it, or below with `gte=false`), and each band gets a solid data bar of its colour (`colors`:
one per band, or two to interpolate between), on a shared scale (`min_type`/`max_type` `num` (the
range's minimum and maximum by default) or `formula`). With `clear`, the formats lying within `rng`
are removed first. Returns each band's label and cells (`label => range`); empty bands are left out.
The bands are those of the values when it is called. `direction="rightToLeft"` is an error, as for
data bars.
"""
function setColoredDataBars(ws::Worksheet, rng; bands::Int = 5, colors = ["green", "red"], breaks = nothing,
                            gte::Union{Bool,AbstractVector{Bool}} = true, showVal = nothing, direction = nothing,
                            min_type = nothing, min_val = nothing, max_type = nothing, max_val = nothing, clear::Bool = true)
    _require_writable(ws, "set a conditional format")
    showVal, direction, min_type, min_val, max_type, max_val =
        map((k, v) -> _cf_string(k, v), (:showVal, :direction, :min_type, :min_val, :max_type, :max_val),
            (showVal, direction, min_type, min_val, max_type, max_val))
    areas = _cf_blocks(ws, rng)
    length(areas) == 1 || throw(ODSError("`setColoredDataBars` takes one contiguous range."))
    rr, cc = areas[1]
    # the checks first: a refused call leaves the range's formats
    for (t, name) in ((min_type, "min_type"), (max_type, "max_type"))
        t === nothing || t in ("num", "formula") || throw(ODSError(
            "`$name` must be `num` or `formula` for colored data bars; `$t` is evaluated separately for each band, which makes bar lengths incomparable between bands."))
    end
    direction === nothing || direction in ("leftToRight", "rightToLeft") ||
        throw(ODSError("Invalid keyword direction: $direction. Valid values are [\"leftToRight\", \"rightToLeft\"]"))
    direction == "rightToLeft" && throw(ODSError("`direction=\"rightToLeft\"` can't be stored: LibreOffice's data bars always run left to right (D-081)."))
    showVal === nothing || showVal in ("true", "false") || throw(ODSError("Invalid keyword showVal: $showVal. Valid values are [\"true\", \"false\"]"))
    vals = _cf_numbers(ws, areas)
    isempty(vals) && throw(ODSError("No numeric values in `$rng` to band."))
    lo, hi = minimum(vals), maximum(vals)
    breaks === nothing && bands < 1 && throw(ODSError("`bands` must be at least 1, got $bands."))
    breaks === nothing && bands > 1 && !(hi > lo) && throw(ODSError("All numeric values in `$rng` are equal; cannot form bands."))
    breaks === nothing || issorted(breaks) || throw(ODSError("`breaks` must be sorted ascending."))
    _cf_band_colours(colors, breaks === nothing ? bands : length(breaks) + 1)
    clear && clearConditionalFormats(ws, CellRange(first(rr), first(cc), last(rr), last(cc)))
    extra = Dict{Symbol,Any}()
    showVal === nothing || (extra[:showVal] = showVal)
    direction === nothing || (extra[:direction] = direction)
    bar(cells, col) = _cf_set!(ws, cells, :dataBar, (fill_col = col, gradient = "false", sameNegFill = "true",
        min_type = something(min_type, "num"), min_val = something(min_val, _dv_num(lo)),
        max_type = something(max_type, "num"), max_val = something(max_val, _dv_num(hi)), extra...))
    if breaks === nothing
        bands < 1 && throw(ODSError("`bands` must be at least 1, got $bands."))
        if bands == 1
            bar(CellRange(first(rr), first(cc), last(rr), last(cc)), only(_cf_band_colours(colors, 1)))
            return [1 => CellRange(first(rr), first(cc), last(rr), last(cc))]
        end
        hi > lo || throw(ODSError("All numeric values in `$rng` are equal; cannot form bands."))
        brk = collect(range(lo, hi; length = bands + 1))[2:end-1]
    else
        issorted(breaks) || throw(ODSError("`breaks` must be sorted ascending."))
        bands = length(breaks) + 1
        brk = collect(Float64, breaks)
    end
    cols = _cf_band_colours(colors, bands)
    g = gte isa Bool ? fill(gte, length(brk)) : collect(gte)
    length(g) == length(brk) || throw(ODSError("`gte` must be a Bool or have one entry per break ($(length(brk))), got $(length(g))."))
    # each finite number's band, by cell
    cells = [Tuple{Int,Int}[] for _ in 1:bands]
    dim = get_dimension(ws)
    if dim !== nothing
        r1 = max(first(rr), row_number(dim.start)); r2 = min(last(rr), row_number(dim.stop))
        c1 = max(first(cc), column_number(dim.start)); c2 = min(last(cc), column_number(dim.stop))
        if r1 <= r2 && c1 <= c2
            data = getdata(ws, CellRange(r1, c1, r2, c2))
            for i in axes(data, 1), j in axes(data, 2)
                v = data[i, j]
                (v isa Real && !(v isa Bool) && isfinite(v)) || continue
                n = 0
                for k in eachindex(brk)
                    (g[k] ? v >= brk[k] : v > brk[k]) || break
                    n += 1
                end
                push!(cells[n + 1], (r1 + i - 1, c1 + j - 1))
            end
        end
    end
    out = Pair{Int,NonContiguousRange}[]
    for b in 1:bands
        isempty(cells[b]) && continue
        ar = _merge_areas(_Area[(r:r, c:c) for (r, c) in cells[b]])
        ncr = NonContiguousRange(ws.name, Union{CellRef,CellRange}[CellRange(first(a[1]), first(a[2]), last(a[1]), last(a[2])) for a in ar])
        bar(ncr, cols[b])
        push!(out, b => ncr)
    end
    return out
end

# The bands' colours: one per band, or two interpolated in LCHab (as XLSX.jl does).
function _cf_band_colours(spec, n::Int)
    cols = [SheetCore.get_color(c) for c in (spec isa AbstractVector ? spec : [spec])]
    length(cols) == n && return cols
    if length(cols) == 2
        n == 1 && return [cols[1]]
        return SheetCore.color_ramp(cols[1], cols[2], n)
    end
    throw(ODSError("`colors` must give either $n colors (one per band) or 2 colors to interpolate between, got $(length(cols))."))
end

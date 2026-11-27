# AutoFilters (phase 6 step 8; D-078): XLSX.jl's `setAutoFilter`, `getAutoFilter` and
# `deleteAutoFilter` on LibreOffice's sheet database range, with its criteria stored as LibreOffice
# stores them (`table:filter`, F-063) and applied as LibreOffice's Refresh Range applies them (F-071).
#
# Adapted from XLSX.jl dev (src/autofilter.jl `setAutoFilter`, `getAutoFilter`, `deleteAutoFilter`;
# src/filtersort.jl `_parse_criterion`, `_parse_condition`, `_filter_column_id`, `_criteria_pairs`),
# MIT License, Copyright (c) 2018-2026 Felipe Noronha Tavares and other contributors. Changes: the
# filter is the sheet's anonymous database range (`__Anonymous_Sheet_DB__<n>`, F-062); criteria are
# LibreOffice's conditions, combined in its disjunctive form; rows are hidden as LibreOffice hides
# them (`table:visibility="filter"`, F-051) by LibreOffice's rules for each condition (F-071), not
# Excel's; criteria LibreOffice can't store (above/below average, relative dates) are errors; and
# LibreOffice's own options are keywords (D-076): `caseSensitive`, `noDuplicates`, and regular
# expressions.

const _AF_OPS = Dict("==" => "=", "=" => "=", "!=" => "!=", "<>" => "!=", ">" => ">", ">=" => ">=", "<" => "<", "<=" => "<=")
const _AF_NO_FORM = (:aboveAverage, :belowAverage, :today, :yesterday, :tomorrow, :thisWeek, :lastWeek, :nextWeek,
    :thisMonth, :lastMonth, :nextMonth, :thisQuarter, :lastQuarter, :nextQuarter, :thisYear, :lastYear, :nextYear,
    :yearToDate, (Symbol("Q$i") for i in 1:4)..., (Symbol("M$i") for i in 1:12)...)
const _AF_HELP = "Give a value or a vector of values, a condition such as `\">\" => 5`, two joined by :and or :or, " *
    "`(:top, n)`, `(:bottom, n, :percent)`, or a regular expression such as `r\"^a.*\"`."

# One of LibreOffice's filter conditions (`table:filter-condition`): its column in the range (from 0),
# operator, value, whether the value is a number (`table:data-type="number"`), and a set's items.
struct _AFCond
    field::Int
    op::String
    value::String
    num::Bool
    items::Vector{String}
end
_AFCond(field::Int, op::AbstractString, value::AbstractString; num::Bool = false, items::Vector{String} = String[]) =
    _AFCond(field, String(op), String(value), num, items)

# A column's criterion: its conditions, and whether any of them (rather than all) must hold.
struct _AFCrit
    conds::Vector{_AFCond}
    any::Bool
end

#
# Values as LibreOffice reads them
#

# A number as LibreOffice writes one in a condition.
_af_num(x::Real) = (y = Float64(x); isinteger(y) && abs(y) < 1e15 ? string(Int64(y)) : string(y))

# ASCII digits only: Julia's `\d` matches every script's, which `parse` refuses.
const _LO_NUM_RX = r"^[+-]?(?:(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"
const _LO_DATE_RX = r"^([0-9]{4})-([0-9]{1,2})-([0-9]{1,2})(?:[T ]([0-9]{1,2}):([0-9]{2})(?::([0-9]{2}(?:\.[0-9]+)?))?)?$"

# The number LibreOffice reads a condition's text as, or nothing (F-071): a number, with or without
# thousands separators, an exponent or spaces around it, or in parentheses for a negative one; an ISO
# date, with or without a time. A time alone, percentages, currencies, fractions and dates in other
# forms are text.
function _lo_number(s::AbstractString, null::Dates.Date)
    t = strip(s)
    isempty(t) && return nothing
    if startswith(t, '(') && endswith(t, ')') && ncodeunits(t) > 2
        x = _lo_number(SubString(t, 2, prevind(t, lastindex(t))), null)
        return x === nothing ? nothing : -x
    end
    occursin(_LO_NUM_RX, t) && return parse(Float64, replace(t, "," => ""))
    m = match(_LO_DATE_RX, t)
    m === nothing && return nothing
    d = tryparse(Dates.Date, string(m.captures[1], "-", lpad(m.captures[2], 2, '0'), "-", lpad(m.captures[3], 2, '0')), _AF_D)
    d === nothing && return nothing
    x = Float64(Dates.value(d - null))
    m.captures[4] === nothing && return x
    return x + _lo_time(m.captures[4], m.captures[5], m.captures[6])
end
_lo_time(h, m, s) = (Int(parse(Int64, h)) * 3600 + Int(parse(Int64, m)) * 60 + (s === nothing ? 0.0 : parse(Float64, s))) / 86_400

const _AF_D = Dates.DateFormat("yyyy-mm-dd")
const _AF_DTM = Dates.DateFormat("yyyy-mm-dd HH:MM")
const _AF_DTS = Dates.DateFormat("yyyy-mm-dd HH:MM:SS")
const _AF_DTMS = Dates.DateFormat("yyyy-mm-dd HH:MM:SS.sss")

# A value of a list as a set item.
function _af_item(v)
    ismissing(v) && return ""
    v isa Bool && return v ? "TRUE" : "FALSE"
    v isa Real && return _af_num(v)
    v isa Dates.Date && return Dates.format(v, _AF_D)
    if v isa Dates.DateTime
        Dates.millisecond(v) == 0 || return Dates.format(v, _AF_DTMS)
        return Dates.format(v, Dates.second(v) == 0 ? _AF_DTM : _AF_DTS)
    end
    v isa AbstractString && (_check_xml_text(v); return String(v))
    throw(ODSError("Cannot filter by a `$(typeof(v))`: `$v`. " * _AF_HELP))
end

#
# Criteria
#

function _af_criterion(x, f::Int, xf::ODSFile)
    if x isa Symbol
        x in _AF_NO_FORM && throw(ODSError("LibreOffice has no filter for `:$x`: its files can't store above- or " *
                                           "below-average or relative-date filters (F-063). " * _AF_HELP))
        throw(ODSError("Unknown filter `:$x`. " * _AF_HELP))
    end
    (x isa Regex || x isa Pair) && return _AFCrit([_af_condition(x, f, xf)], false)
    if x isa Tuple && !isempty(x) && first(x) in (:top, :bottom)
        (length(x) == 2 || (length(x) == 3 && x[3] === :percent)) && x[2] isa Integer ||
            throw(ODSError("A top or bottom filter is `(:top, n)` or `(:top, n, :percent)`. Found `$x`."))
        percent = length(x) == 3
        (percent ? 1 <= x[2] <= 100 : x[2] >= 1) ||
            throw(ODSError("A top or bottom filter takes $(percent ? "1 to 100 percent" : "1 or more items"). Found $(x[2])."))
        op = string(first(x), percent ? " percent" : " values")
        return _AFCrit([_AFCond(f, op, string(x[2]); num = true)], false)
    end
    if x isa Tuple && length(x) == 3 && x[2] in (:and, :or)
        return _AFCrit([_af_condition(x[1], f, xf), _af_condition(x[3], f, xf)], x[2] === :or)
    end
    x isa Tuple && throw(ODSError("Unknown filter `$x`. " * _AF_HELP))
    vals = x isa AbstractVector ? x : [x]
    isempty(vals) && throw(ODSError("A list of values to show cannot be empty."))
    items = unique!(String[_af_item(v) for v in vals])
    length(items) == 1 && return _AFCrit([_AFCond(f, "=", only(items))], false)
    return _AFCrit([_AFCond(f, "=", first(items); items)], false)
end

function _af_condition(p, f::Int, xf::ODSFile)
    p isa Regex && return _af_regex(f, "=", p)
    p isa Pair && first(p) isa AbstractString && haskey(_AF_OPS, first(p)) ||
        throw(ODSError("A condition is an operator and a value, such as `\">\" => 5`; the operators are " *
                       "$(join(sort(collect(keys(_AF_OPS))), ", ")). Found `$p`."))
    op = _AF_OPS[first(p)]
    v = last(p)
    v isa Bool && throw(ODSError("Use a list of values, `[true]`, to filter by a logical value."))
    v isa Regex && return _af_regex(f, op, v)
    v isa Real && return _AFCond(f, op, _af_num(v); num = true)
    v isa Dates.Date && return _AFCond(f, op, _af_num(Dates.value(v - xf.null_date)); num = true)
    v isa Dates.DateTime &&
        return _AFCond(f, op, _af_num((Dates.value(v) - Dates.value(Dates.DateTime(xf.null_date))) / 86_400_000); num = true)
    v isa AbstractString && (_check_xml_text(v); return _af_text_condition(f, op, String(v)))
    throw(ODSError("Cannot compare with a `$(typeof(v))`: `$v`."))
end

function _af_regex(f::Int, op::String, r::Regex)
    op in ("=", "!=") || throw(ODSError("A regular expression is matched with `==` or `!=`, not `$op`."))
    return _AFCond(f, op == "=" ? "match" : "!match", r.pattern)
end

# A text condition. With `==` and `!=`, Excel's wildcards (`*`, `?`, and `~` before a character for
# itself) are LibreOffice's text tests where they can be (`"a*"` begins with a), and otherwise a
# regular expression: LibreOffice compares wildcards in `=` as plain text (F-063).
function _af_text_condition(f::Int, op::String, v::String)
    (op in ("=", "!=") && any(c -> c in ('*', '?', '~'), v)) || return _AFCond(f, op, v)
    toks = Tuple{Bool,Char}[]                       # (a wildcard, the character)
    esc = false
    for ch in v
        if !esc && ch == '~'
            esc = true
        else
            push!(toks, (!esc && ch in ('*', '?'), ch))
            esc = false
        end
    end
    esc && push!(toks, (false, '~'))
    lit(ts) = String([c for (_, c) in ts])
    wild = [w for (w, _) in toks]
    !any(wild) && return _AFCond(f, op, lit(toks))
    n = length(toks)
    star(i) = toks[i] == (true, '*')
    inner(a, b) = a <= b && !any(wild[a:b])
    pos = op == "="
    if n >= 2 && star(n) && inner(1, n - 1)
        return _AFCond(f, pos ? "begins-with" : "does-not-begin-with", lit(toks[1:n-1]))
    elseif n >= 2 && star(1) && inner(2, n)
        return _AFCond(f, pos ? "ends-with" : "does-not-end-with", lit(toks[2:n]))
    elseif n >= 3 && star(1) && star(n) && inner(2, n - 1)
        return _AFCond(f, pos ? "contains" : "does-not-contain", lit(toks[2:n-1]))
    end
    io = IOBuffer()
    for (w, c) in toks
        if w
            print(io, c == '*' ? ".*" : ".")
        else
            c in "\\^\$.|?*+()[]{}" && print(io, '\\')
            print(io, c)
        end
    end
    return _AFCond(f, pos ? "match" : "!match", String(take!(io)))
end

# The column of `rng` (from 0) given by its position (1 for the first), its header's text or its letter.
function _af_column(ws::Worksheet, r1::Int, c1::Int, c2::Int, col)
    if col isa Integer
        1 <= col <= c2 - c1 + 1 || throw(ODSError("Column $col is outside the filter's $(c2 - c1 + 1) columns."))
        return Int(col) - 1
    end
    col isa AbstractString || throw(ODSError("A filter column is given by its position, its header or its letter. Found `$col`."))
    for c in c1:c2
        cell_text(ws, r1, c) == col && return c - c1
    end
    if occursin(r"^[A-Za-z]{1,3}$", col)
        c = SheetCore.decode_column_number(uppercase(col))
        c1 <= c <= c2 && return c - c1
    end
    throw(ODSError("No column `$col` in the filter's range: it is neither a header nor a column letter in it."))
end

_af_pairs(f::Pair) = [f]
_af_pairs(f::AbstractDict) = collect(f)
_af_pairs(f::AbstractVector) = (all(p -> p isa Pair, f) ||
    throw(ODSError("Give filters as pairs of a column and its criterion, such as `\"Colour\" => [\"Red\"]`.")); f)
_af_pairs(_) = throw(ODSError("Give filters as pairs of a column and its criterion, such as `\"Colour\" => [\"Red\"]`."))

#
# The stored form
#

function _af_cond_xml(io::IO, k::_AFCond, cs::Bool)
    print(io, "<table:filter-condition ")
    k.num && print(io, "table:data-type=\"number\" ")
    print(io, "table:value=\"", _escape_attr(k.value), "\" table:operator=\"", _escape_attr(k.op),
          "\" table:field-number=\"", k.field, "\"")
    cs && print(io, " table:case-sensitive=\"true\"")
    if isempty(k.items)
        print(io, "/>")
    else
        print(io, ">")
        for i in k.items
            print(io, "<table:filter-set-item table:value=\"", _escape_attr(i), "\"/>")
        end
        print(io, "</table:filter-condition>")
    end
end

# The `table:filter` of the criteria: the columns' criteria all hold, as LibreOffice stores it, in
# disjunctive form (`filter-or` of `filter-and`s), since it reads conditions nested otherwise wrongly
# (F-071). nothing when there is nothing to store.
function _af_filter_xml(crits::Vector{_AFCrit}, cs::Bool, nodup::Bool)
    terms = [_AFCond[]]
    for c in crits
        if c.any
            terms = [vcat(t, [k]) for t in terms for k in c.conds]
        else
            foreach(t -> append!(t, c.conds), terms)
        end
    end
    isempty(first(terms)) && return nothing
    io = IOBuffer()
    print(io, "<table:filter", nodup ? " table:display-duplicates=\"false\"" : "", ">")
    if length(terms) == 1
        print(io, "<table:filter-and>")
        foreach(k -> _af_cond_xml(io, k, cs), only(terms))
        print(io, "</table:filter-and>")
    else
        print(io, "<table:filter-or>")
        for t in terms
            if length(t) == 1
                _af_cond_xml(io, only(t), cs)
            else
                print(io, "<table:filter-and>")
                foreach(k -> _af_cond_xml(io, k, cs), t)
                print(io, "</table:filter-and>")
            end
        end
        print(io, "</table:filter-or>")
    end
    print(io, "</table:filter>")
    return String(take!(io))
end

const _AF_FILTER_RX = r"<table:filter(?=[\s/>])(?:[^>]*?/>|.*?</table:filter>)"s
const _AF_AFTER_FILTER_RX = r"<table:(?:sort|subtotal-rules)(?=[\s/>])"

# A database range's element with its `table:filter` replaced by `f` (nothing: removed).
function _af_with_filter(x::String, f::Union{Nothing,String})
    isempty(x) && (x = "<table:database-range/>")
    m = match(_AF_FILTER_RX, x)
    if m !== nothing
        a = findfirst(_AF_FILTER_RX, x)
        y = string(SubString(x, 1, prevind(x, first(a))), something(f, ""), SubString(x, nextind(x, last(a))))
        e = _start_tag_end(y)
        rest = SubString(y, nextind(y, e))
        isempty(strip(replace(rest, "</table:database-range>" => ""))) &&       # no children left
            return string(SubString(y, 1, prevind(y, e)), "/>")
        return y
    end
    f === nothing && return x
    e = _start_tag_end(x)
    if x[prevind(x, e)] == '/'                       # <table:database-range …/>
        return string(SubString(x, 1, prevind(x, prevind(x, e))), ">", f, "</table:database-range>")
    end
    b = findnext(_AF_AFTER_FILTER_RX, x, e)
    b === nothing && (b = findlast("</table:database-range>", x))
    return string(SubString(x, 1, prevind(x, first(b))), f, SubString(x, first(b)))
end

#
# Applying the criteria as LibreOffice's Refresh Range does (F-071)
#

# A cell as a filter sees it: blank (0), a number (1, booleans 1 and 0), text (2) or an error (3);
# its number; and the text it shows. A formula without a value is the text "", as LibreOffice saves
# one giving "".
struct _AFCell
    kind::UInt8
    num::Float64
    text::String
end

# `over`: cells seen otherwise (formulas a sort just moved, with the values they had, F-072).
function _af_cells(ws::Worksheet, store::SheetStore, rows::UnitRange{Int}, c::Int, cache::_CodeCache,
                   over::Union{Nothing,Dict{Tuple{Int,Int},_AFCell}} = nothing)
    null = get_odsfile(ws).null_date
    out = Vector{_AFCell}(undef, length(rows))
    for (i, r) in enumerate(rows)
        if over !== nothing
            x = get(over, (r, c), nothing)
            x === nothing || (out[i] = x; continue)
        end
        d = cell_data(store, r, c)
        out[i] = if d === nothing
            _AFCell(0x00, 0.0, "")
        elseif d.kind === CK_EMPTY                  # LibreOffice saves a formula giving "" without a value (F-071)
            _AFCell(d.formula === nothing ? 0x00 : 0x02, 0.0, "")
        elseif d.kind === CK_STRING
            _AFCell(0x02, 0.0, something(d.text, ""))
        elseif d.kind === CK_ERROR
            _AFCell(0x03, 0.0, something(d.text, ""))
        else
            v = _engine_value(d, null)
            _AFCell(0x01, v isa Bool ? Float64(v) : Float64(v), cell_text(ws, r, c; cache, store))
        end
    end
    return out
end

_af_approx(a::Float64, b::Float64) = a == b || isapprox(a, b; rtol = 2.0^-48)
function _af_cmp(a::Float64, b::Float64, op::String)
    op == "=" && return _af_approx(a, b)
    op == "!=" && return !_af_approx(a, b)
    op == ">" && return a > b && !_af_approx(a, b)
    op == ">=" && return a >= b || _af_approx(a, b)
    op == "<" && return a < b && !_af_approx(a, b)
    return a <= b || _af_approx(a, b)
end

# (Text is compared as LibreOffice's collator compares it: `_lo_collate`, src/write/collate.jl.)
function _af_order(r::Int, op::String)
    op == ">" && return r > 0
    op == ">=" && return r >= 0
    op == "<" && return r < 0
    return r <= 0
end

_af_eq(a::AbstractString, b::AbstractString, cs::Bool) = cs ? a == b : lowercase(a) == lowercase(b)

# A condition ready to apply: its numbers and regular expression, and a ranking's threshold.
struct _AFPrep
    k::_AFCond
    q::Union{Nothing,Float64}                       # the value as a number, as LibreOffice reads it
    qs::Vector{Union{Nothing,Float64}}              # the items' numbers
    rx::Union{Nothing,Regex}
    th::Union{Nothing,Float64}                      # top or bottom: the threshold (nothing: none)
end

# A ranking's threshold: the n-th of the column's cells as LibreOffice sorts them (errors and text
# before numbers for the top, after them for the bottom; blanks out), whose number counts (0 for text
# and errors); n percent of the cells that aren't blank, at least one.
function _af_threshold(k::_AFCond, cells::Vector{_AFCell})
    nums = sort!([c.num for c in cells if c.kind == 0x01])
    other = count(c -> c.kind == 0x02 || c.kind == 0x03, cells)
    total = length(nums) + other
    total == 0 && return nothing
    v = parse(Float64, k.value)
    n = endswith(k.op, "percent") ? max(1, floor(Int, total * v / 100)) : min(Int(v), total)
    n = min(n, total)
    if startswith(k.op, "top")
        return n <= other ? 0.0 : nums[end-(n-other)+1]
    end
    return n <= length(nums) ? nums[n] : 0.0
end

function _af_prep(k::_AFCond, cells::Vector{_AFCell}, null::Dates.Date, cs::Bool)
    q = k.num ? parse(Float64, k.value) : _lo_number(k.value, null)
    qs = Union{Nothing,Float64}[_lo_number(i, null) for i in k.items]
    rx = nothing
    if k.op in ("match", "!match")
        rx = Regex("^(?:" * k.value * ")\$", cs ? "s" : "is")       # the whole cell, as LibreOffice matches
    end
    th = (startswith(k.op, "top") || startswith(k.op, "bottom")) ? _af_threshold(k, cells) : nothing
    return _AFPrep(k, q, qs, rx, th)
end

# Whether a cell equals text `v` (`q`: as a number), as LibreOffice compares them: a number with the
# number `v` reads as, else with the text it shows; text with text.
_af_text_eq(c::_AFCell, v::String, q, cs::Bool) =
    (c.kind == 0x01 && q !== nothing) ? _af_approx(c.num, q) : _af_eq(c.text, v, cs)

function _af_holds(c::_AFCell, p::_AFPrep, cs::Bool)
    k = p.k
    op = k.op
    op == "empty" && return c.kind == 0x00
    if startswith(op, "top") || startswith(op, "bottom")
        p.th === nothing && return false
        return c.kind == 0x01 && (startswith(op, "top") ? c.num >= p.th || _af_approx(c.num, p.th) :
                                                          c.num <= p.th || _af_approx(c.num, p.th))
    end
    isempty(k.items) || return any(i -> _af_text_eq(c, k.items[i], p.qs[i], cs), eachindex(k.items))
    if k.num
        c.kind == 0x01 || return op == "!="
        return _af_cmp(c.num, p.q, op)
    end
    v = k.value
    op == "=" && return _af_text_eq(c, v, p.q, cs)
    op == "!=" && return !_af_text_eq(c, v, p.q, cs)
    if op in (">", ">=", "<", "<=")
        c.kind == 0x00 && return false
        c.kind == 0x01 && return p.q !== nothing && _af_cmp(c.num, p.q, op)
        return _af_order(_lo_collate(c.text, v, cs), op)
    end
    if op == "match" || op == "!match"
        r = (c.kind == 0x01 && p.q !== nothing) ? _af_approx(c.num, p.q) : occursin(p.rx, c.text)
        return op == "match" ? r : !r
    end
    t, w = cs ? (c.text, v) : (lowercase(c.text), lowercase(v))
    op == "begins-with" && return startswith(t, w)
    op == "does-not-begin-with" && return !startswith(t, w)
    op == "ends-with" && return endswith(t, w)
    op == "does-not-end-with" && return !endswith(t, w)
    op == "contains" && return occursin(w, t)
    op == "does-not-contain" && return !occursin(w, t)
    throw(ODSError("Unknown filter operator `$op`."))
end

# Which data rows of (r1:r2, c1:c2) the criteria show; with `nodup`, a row showing the same texts as
# one above it is hidden, as LibreOffice compares them (case matters, F-071).
function _af_shows(ws::Worksheet, r1::Int, c1::Int, r2::Int, c2::Int, crits::Vector{_AFCrit}, cs::Bool, nodup::Bool,
                   over::Union{Nothing,Dict{Tuple{Int,Int},_AFCell}} = nothing)
    rows = r1+1:r2
    shows = trues(length(rows))
    isempty(rows) && return rows, shows
    store = _store_for(ws, rows)
    cache = _CodeCache()
    null = get_odsfile(ws).null_date
    cols = Dict{Int,Vector{_AFCell}}()
    cellsof(f) = get!(() -> _af_cells(ws, store, rows, c1 + f, cache, over), cols, f)
    for c in crits
        preps = [_af_prep(k, cellsof(k.field), null, cs) for k in c.conds]
        for i in eachindex(rows)
            shows[i] || continue
            h = c.any ? any(p -> _af_holds(cellsof(p.k.field)[i], p, cs), preps) :
                        all(p -> _af_holds(cellsof(p.k.field)[i], p, cs), preps)
            shows[i] = h
        end
    end
    if nodup
        seen = Set{String}()
        texts = [cellsof(f) for f in 0:c2-c1]
        for i in eachindex(rows)
            shows[i] || continue
            key = join((t[i].text for t in texts), '\x01')
            key in seen ? (shows[i] = false) : push!(seen, key)
        end
    end
    return rows, shows
end

_af_row_hidden(f, r::Int) = (x = _fmt_at(f.rows, r); x !== nothing && x.visibility != _VISIBLE)

# Hide the rows not shown, as a filter hides them, and show the others.
function _af_apply_rows!(ws::Worksheet, rows::UnitRange{Int}, shows::BitVector)
    f = sheet_formats(ws)
    i = 1
    n = length(rows)
    while i <= n
        j = i
        while j < n && shows[j+1] == shows[i]; j += 1; end
        if !shows[i]
            set_row_formats!(ws, rows[i]:rows[j]; visibility = "filter")
        else
            for r in rows[i]:rows[j]
                _af_row_hidden(f, r) && set_row_formats!(ws, r:r; visibility = _VISIBLE)
            end
        end
        i = j + 1
    end
    return
end

#
# The sheet's filter
#

# The sheet's anonymous database range, or nothing.
function _af_range(ws::Worksheet)
    for d in _db_now(get_odsfile(ws))
        d.sheet === ws && startswith(d.name, _ANON_DB) && return d
    end
    return nothing
end

function _af_cells_of(ws::Worksheet, rng)
    rng isa SheetCellRange && (do_sheet_names_match(ws, rng); rng = rng.rng)
    blocks = Tuple{UnitRange{Int},UnitRange{Int}}[]
    for (w, bs) in format_targets(ws, rng)
        w === ws || throw(ODSError("The range names another sheet than `$(ws.name)`."))
        for b in bs
            b.kind === :cells || throw(ODSError("An AutoFilter needs a range of cells, such as `A1:D20`. Found `$rng`."))
            push!(blocks, (b.rows, b.cols))
        end
    end
    length(blocks) == 1 || throw(ODSError("An AutoFilter needs a single range of cells, such as `A1:D20`. Found `$rng`."))
    rr, cc = only(blocks)
    return first(rr), first(cc), last(rr), last(cc)
end

"""
    setAutoFilter(sheet, rng; filters=nothing, sort=nothing, caseSensitive=false, noDuplicates=false,
                  naturalSort=false, includeFormats=true)
    setAutoFilter(xf, "Sheet1.A1:D20"; kw...)

Add filter buttons to the first row of `rng`, as LibreOffice's Data ▸ AutoFilter does, stored as
LibreOffice stores a sheet's AutoFilter: the sheet's anonymous database range. `rng`
is a range of cells (`"A1:D20"`), a defined name, or `:` for the sheet's used range. Its first row
is the header row.

A sheet has one AutoFilter, so this replaces any the sheet has. It may not overlap a table (see
[`addtable!`](@ref)). Setting the filter again on the same range keeps its criteria and sort, unless
new ones are given. With both, the rows are sorted first and then filtered, as LibreOffice does.

# Filtering

`filters` gives criteria for some of the columns, as pairs of a column and a criterion. A column is
given by its header text, its column letter or its position in the range (`1` for the first). Rows
a criterion doesn't show are hidden (as LibreOffice hides them, `table:visibility="filter"`) and
the others shown, so the file opens filtered, as LibreOffice would have saved it. A row is shown if
it meets the criteria of every filtered column. A criterion is one of:

- a value, or a vector of values, to show: text (in any case), numbers, dates, `true`/`false`, and
  `missing` for empty cells.
- a condition, `op => value`, where `op` is `"=="`, `"!="`, `">"`, `">="`, `"<"` or `"<="` and `value`
  a number, a date or text. With `"=="` and `"!="`, text may use wildcards: `*` for any
  characters, `?` for any one, and `~` before one of them for itself. `"!=" => ""` shows the cells
  that aren't empty.
- two conditions joined by `:and` or `:or`: `(">=" => 10, :and, "<" => 20)`.
- `(:top, n)` or `(:bottom, n)` for the `n` largest or smallest numbers, or `(:top, n, :percent)` and
  `(:bottom, n, :percent)` for a percentage of the cells.
- a regular expression, `r"^a.*z\$"` or `"!=" => r"…"` (it must match the whole cell's text).

Criteria are applied as LibreOffice's Refresh Range applies them:
- Text that LibreOffice reads as a number (`"10"`, `"1,000"`, `"(1)"`, `"2026-11-23 15:00"`) is compared
  with numbers as that number, and with text as text; other text is compared with the text a number
  shows (`"50%"`, `"TRUE"`). A number is compared only with numbers.
- Values in a list are compared as such text, so `[10]` shows the text `"10"` too, and a date shows
  cells of that date at midnight, not later that day.
- A ranking counts every cell that isn't empty, and sorts text and errors above the largest numbers.
- `"!=" => ""` treats a formula giving `""` as empty, while `missing` shows only cells holding
  nothing.

LibreOffice has no above- or below-average or relative-date filters (`:aboveAverage`, `:today`,
`:Q1`, …): they are errors.

Options: `caseSensitive=true` compares text in its case, and
`noDuplicates=true` hides rows that show the same as a row above them (always comparing case), as
LibreOffice's *No duplications*. `noDuplicates` applies to the criteria given, so it needs `filters`,
and LibreOffice applies it only with at least one criterion.

`filters=[]` removes the criteria and shows every row of the range.

# Sorting

`sort` gives a column, `column => :ascending` or `column => :descending`, or a vector of these, the
first sorting first. The rows below the header are put in that order, as LibreOffice's Data ▸ Sort
puts them, and the sort is stored with the range:
- ascending: numbers and dates, with `FALSE` and `TRUE` as 0 and 1; then text, in LibreOffice's
  alphabetical order (ignoring case, and accents but where they alone differ); then errors. Descending
  reverses this. Empty cells are last either way, and rows that compare equal keep their order.
- each row's cells in the range move with their formats, validations, notes, links and pictures, and
  its hidden state goes with it; a formula moves as if copied, so `=B5*2` in row 5 becomes `=B2*2` in
  row 2, and is saved without a value (LibreOffice computes it on loading). Cells outside the
  range's columns, row heights, and formulas and names that refer to the sorted cells stay as they
  are, as in LibreOffice.
- a range with merged cells is refused (LibreOffice sorts it only without formats), and so is one with
  an array formula.

Options: `caseSensitive=true` (shared with the criteria) puts lower case
before upper case where text is otherwise equal; `naturalSort=true` compares the numbers within text
by value (`"a2"` before `"a10"`); `includeFormats=false` leaves the formats and validations where they
are and moves only the values, notes, links and pictures (which allows merged cells).

The file must be writable.

```julia
st = addsheet!(xf, "Stock")
st["A1:B1"] = ["Colour" "Amount"]
for (i, (colour, amount)) in enumerate([("Red", 120), ("Green", 80), ("Blue", 150), ("Red", 60)])
    st[i+1, 1] = colour; st[i+1, 2] = amount
end
setAutoFilter(st, :)          # drop-down buttons on the header, over the used area

# only the red and blue rows over 100 show, largest first
setAutoFilter(st, "A1:B5"; filters = ["Colour" => ["Red", "Blue"], "Amount" => (">" => 100)],
              sort = "Amount" => :descending)
```

See also [`getAutoFilter`](@ref) and [`deleteAutoFilter`](@ref).
"""
function setAutoFilter end
setAutoFilter(xf::ODSFile, ref::AbstractString; kw...) = setAutoFilter(_dv_sheet_ref(xf, ref)...; kw...)
setAutoFilter(ws::Worksheet, ::Colon; kw...) = setAutoFilter(ws, get_dimension(ws); kw...)
function setAutoFilter(ws::Worksheet, rng; filters = nothing, sort = nothing, caseSensitive::Union{Nothing,Bool} = nothing,
                       noDuplicates::Union{Nothing,Bool} = nothing, naturalSort::Union{Nothing,Bool} = nothing,
                       includeFormats::Union{Nothing,Bool} = nothing)
    _require_writable(ws, "set an AutoFilter")
    xf = get_odsfile(ws)
    r1, c1, r2, c2 = _af_cells_of(ws, rng)
    for t in tables(ws)
        a, b = t.ref.start, t.ref.stop
        (row_number(a) <= r2 && r1 <= row_number(b) && column_number(a) <= c2 && c1 <= column_number(b)) &&
            throw(ODSError("AutoFilter range `$(_db_cell(r1, c1)):$(_db_cell(r2, c2))` overlaps table `$(t.name)` (`$(t.ref)`), which has a filter of its own."))
    end
    filters === nothing && sort === nothing && caseSensitive !== nothing &&
        throw(ODSError("`caseSensitive` applies to the criteria and the sort: give it with `filters` or `sort`."))
    filters === nothing && noDuplicates !== nothing &&
        throw(ODSError("`noDuplicates` applies to the criteria: give it with `filters` (`filters=[]` for none)."))
    sort === nothing && (naturalSort !== nothing || includeFormats !== nothing) &&
        throw(ODSError("`naturalSort` and `includeFormats` apply to the sort: give them with `sort`."))
    cs = something(caseSensitive, false)
    nodup = something(noDuplicates, false)
    nodup && isempty(_af_pairs(filters)) &&
        throw(ODSError("LibreOffice applies `noDuplicates` only with criteria (F-071): give `filters` too."))
    crits = _AFCrit[]
    if filters !== nothing
        for (col, crit) in _af_pairs(filters)
            push!(crits, _af_criterion(crit, _af_column(ws, r1, c1, c2, col), xf))
        end
    end
    keys = sort === nothing ? nothing : _sort_keys(ws, r1, c1, c2, sort)
    nat = something(naturalSort, false)
    formats = something(includeFormats, true)
    fx = filters === nothing ? nothing : _af_filter_xml(crits, cs, nodup)
    over = keys === nothing ? nothing : _sort_rows!(ws, r1, c1, r2, c2, keys, cs, nat, formats)   # LibreOffice sorts, then filters
    if filters !== nothing
        rows, shows = _af_shows(ws, r1, c1, r2, c2, crits, cs, nodup, over)
        _af_apply_rows!(ws, rows, shows)
    end
    sx = keys === nothing ? nothing : _sort_xml(keys, cs, nat, formats)

    old = _af_range(ws)
    same = old !== nothing && (old.r1, old.c1, old.r2, old.c2) == (r1, c1, r2, c2)
    if old !== nothing
        m = _db_model!(xf, old)
        m.r1, m.c1, m.r2, m.c2 = r1, c1, r2, c2
        m.buttons = true
        m.header = true
        m.footer = false
        if !same
            m.xml = _af_with_filter(isempty(m.xml) ? "" : _db_strip_children(m.xml), fx)
        elseif filters !== nothing
            m.xml = _af_with_filter(m.xml, fx)
        end
        sx === nothing || (m.xml = _db_with_sort(m.xml, sx))
    else
        name = _af_new_name(xf, ws)
        x = fx === nothing ? "" : _af_with_filter("", fx)
        sx === nothing || (x = _db_with_sort(x, sx))
        push!(xf.dbedits.model, DBRange(name, ws, r1, c1, r2, c2, true, false, true, x, 1.0e9 + length(xf.dbedits.model) + 1))
    end
    return nothing
end

# A database range's element without its children (a new range keeps no filter or sort).
function _db_strip_children(x::String)
    e = _start_tag_end(x)
    x[prevind(x, e)] == '/' && return x
    return string(SubString(x, 1, prevind(x, e)), "/>")
end

# The name of a sheet's new anonymous range: LibreOffice numbers them by the sheet's place (F-062),
# though it reads any number (F-071).
function _af_new_name(xf::ODSFile, ws::Worksheet)
    used = Set(uppercase(d.name) for d in _db_now(xf))
    k = something(findfirst(s -> s === ws, _sheets(xf)), 1) - 1
    while uppercase(_ANON_DB * string(k)) in used; k += 1; end
    return _ANON_DB * string(k)
end

"""
    getAutoFilter(sheet) -> Union{Nothing, CellRange}

The range of the sheet's AutoFilter (see [`setAutoFilter`](@ref)), or `nothing` if it has none:
LibreOffice's anonymous database range of the sheet, when it shows filter buttons. Tables' filters
are not included. Works on read-only files.
"""
function getAutoFilter(ws::Worksheet)::Union{Nothing,CellRange}
    d = _af_range(ws)
    (d === nothing || !d.buttons) && return nothing
    return CellRange(d.r1, d.c1, d.r2, d.c2)
end

"""
    deleteAutoFilter(sheet) -> Bool

Remove the sheet's AutoFilter and its criteria, as turning off LibreOffice's Data ▸ AutoFilter
does: every row below the header is shown, those hidden by hand too, and the sheet keeps
its anonymous database range without filter buttons or criteria. Returns `false` if the sheet had
no AutoFilter.

The file must be writable.
"""
function deleteAutoFilter(ws::Worksheet)::Bool
    _require_writable(ws, "remove an AutoFilter")
    xf = get_odsfile(ws)
    d = _af_range(ws)
    (d === nothing || !d.buttons) && return false
    m = _db_model!(xf, d)
    m.buttons = false
    isempty(m.xml) || (m.xml = _af_with_filter(m.xml, nothing))
    _af_apply_rows!(ws, d.r1+1:d.r2, trues(max(0, d.r2 - d.r1)))
    return true
end

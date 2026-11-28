# Number formats (phase 4): Excel-style format codes ↔ ODF data styles (`number:*-style`).
#
# Codes are parsed by SheetCore's engine (`_parse_numfmt`, adapted from XLSX.jl). Each
# section becomes a data style in the form LibreOffice writes for the same code (F-031,
# experiment 012): the last section is the main style, and the others are separate styles
# it reaches through `style:map` conditions. The reverse turns any data style, LibreOffice's
# or OpenDocumentSpreadsheets's, back into a code, for `getFormat` and for the displayed text (`getText`).

const SC = SheetCore

#
# Code → ODF
#

const _FMT_COLOR_HEX = Dict("black" => "#000000", "blue" => "#0000ff", "cyan" => "#00ffff", "green" => "#00ff00",
                            "magenta" => "#ff00ff", "red" => "#ff0000", "white" => "#ffffff", "yellow" => "#ffff00")

_needs_loext(styles::StyleIndex) = (sh = styles.sheet[1]; sh !== nothing && sh.needs_loext)


# One section as a data style: its element, attributes, children, and whether it uses
# LibreOffice's `loext:` attributes.
struct _OdfSection
    element::String
    attrs::String
    inner::String
    loext::Bool
end

_ds_body(s::_OdfSection, maps::AbstractString = "") =
    "<$(s.element) style:name=\"\$NAME\"$(s.attrs)>$(s.inner)$(maps)</$(s.element)>"

# The placeholders of a number part as LibreOffice's `number:number` attributes.
function _number_attrs(toks, digits::Vector{Int}, ipoint, thousands::Bool, scale::Int)
    intd = [k for k in digits if ipoint === nothing || k < ipoint]
    decd = [k for k in digits if ipoint !== nothing && k > ipoint]
    io = IOBuffer()
    print(io, " number:decimal-places=\"", length(decd), "\" number:min-decimal-places=\"", count(k -> toks[k].text == "0", decd), "\"")
    if any(k -> toks[k].text != "0", decd)
        print(io, " number:decimal-replacement=\"", any(k -> toks[k].text == "?", decd) ? " " : "", "\"")
    end
    nblank = count(k -> toks[k].text == "?", intd)
    print(io, " number:min-integer-digits=\"", count(k -> toks[k].text != "#", intd), "\"")
    loext = nblank > 0
    loext && print(io, " loext:max-blank-integer-digits=\"", nblank, "\"")
    thousands && print(io, " number:grouping=\"true\"")
    scale > 0 && print(io, " number:display-factor=\"", big(1000)^scale, "\"")   # BigInt: 1000^7 passes Int64
    return String(take!(io)), loext
end

# The numeric element of a number section (number, scientific or fraction), from tokens
# `first:last`. Returns (xml, loext).
function _numeric_element(toks, run::UnitRange{Int})
    stop = last(run)
    iexp = findfirst(k -> toks[k].kind == :exp, run)
    if iexp !== nothing
        iexp = run[iexp]
        p = SC._number_parts(toks, iexp - 1)
        digits = [k for k in first(run):iexp-1 if toks[k].kind == :digit]
        intd = [k for k in digits if p.ipoint === nothing || k < p.ipoint]
        decd = [k for k in digits if p.ipoint !== nothing && k > p.ipoint]
        expd = count(k -> toks[k].kind == :digit, iexp+1:stop)
        interval = any(k -> toks[k].text == "#", intd) || length(intd) > 1 ? length(intd) : 1
        return string("<number:scientific-number number:decimal-places=\"", length(decd), "\" number:min-decimal-places=\"",
                      count(k -> toks[k].text == "0", decd), "\" number:min-integer-digits=\"",
                      max(1, count(k -> toks[k].text == "0", intd)), "\" number:min-exponent-digits=\"", expd,
                      "\" number:exponent-interval=\"", interval, "\" number:forced-exponent-sign=\"",
                      toks[iexp].text == "E+", "\"/>"), false
    end
    islash = SC._fraction_slash(toks)
    if islash !== nothing && islash in run
        numstart = islash - 1
        while numstart > first(run) && toks[numstart - 1].kind == :digit
            numstart -= 1
        end
        intd = [k for k in first(run):numstart-1 if toks[k].kind == :digit]
        num = numstart:islash-1
        denend = islash + 1
        while denend < stop && (toks[denend + 1].kind == :digit || (toks[denend + 1].kind == :lit && all(isdigit, toks[denend + 1].text)))
            denend += 1
        end
        den = islash+1:denend
        io = IOBuffer()
        print(io, "<number:fraction")
        isempty(intd) || print(io, " number:min-integer-digits=\"", count(k -> toks[k].text == "0", intd), "\"")
        print(io, " number:min-numerator-digits=\"", length(num), "\" loext:max-numerator-digits=\"", length(num), "\"")
        z = count(k -> toks[k].text == "0", num)
        z > 0 && print(io, " loext:zeros-numerator-digits=\"", z, "\"")
        if toks[first(den)].kind == :lit
            print(io, " number:denominator-value=\"", join(toks[k].text for k in den), "\"")
        else
            print(io, " number:min-denominator-digits=\"", length(den), "\" number:max-denominator-value=\"", big(10)^length(den) - 1, "\"")   # BigInt: 10^19 passes Int64
        end
        print(io, "/>")
        return String(take!(io)), true
    end
    p = SC._number_parts(toks, stop)
    digits = [k for k in run if toks[k].kind == :digit]
    attrs, loext = _number_attrs(toks, digits, p.ipoint, p.thousands, p.scale)
    # text between integer digits (`0-00`): number:embedded-text, at the number of integer
    # digits to its right
    intd = [k for k in digits if p.ipoint === nothing || k < p.ipoint]
    emb = IOBuffer()
    for k in run
        (toks[k].kind === :lit && !isempty(intd) && first(intd) < k < last(intd)) || continue
        print(emb, "<number:embedded-text number:position=\"", count(>(k), intd), "\">", _xtext(toks[k].text), "</number:embedded-text>")
    end
    e = String(take!(emb))
    return isempty(e) ? "<number:number$(attrs)/>" : "<number:number$(attrs)>$(e)</number:number>", loext
end

# A date or time part.
function _date_element(t)::Union{Nothing,String}
    k, s = t.kind, t.text
    n = length(s)
    long(b) = b ? " number:style=\"long\"" : ""
    if k === :date && !isempty(s)
        c = s[1]
        c in ('y', 'e', 'b') && return "<number:year$(long(c == 'y' && n > 2))/>"
        c == 'm' && return n >= 3 ? "<number:month$(long(n == 4)) number:textual=\"true\"/>" : "<number:month$(long(n == 2))/>"
        c == 'd' && return n >= 3 ? "<number:day-of-week$(long(n >= 4))/>" : "<number:day$(long(n == 2))/>"
        c == 'h' && return "<number:hours$(long(n >= 2))/>"
        c == 's' && return "<number:seconds$(long(n >= 2))/>"
        return nothing                                   # g: an era, which ODF writes otherwise
    elseif k === :minute
        return "<number:minutes$(long(n >= 2))/>"
    elseif k === :elapsed
        c = s[1]
        tag = c == 'h' ? "hours" : c == 'm' ? "minutes" : "seconds"
        return "<number:$tag$(long(n >= 2))/>"
    elseif k === :ampm
        return "<number:am-pm/>"
    end
    return nothing
end

function _odf_section(sec, raw::AbstractString)
    toks = sec.tokens
    io = IOBuffer()
    loext = false
    m = match(r"\[(black|blue|cyan|green|magenta|red|white|yellow)\]"i, raw)
    m === nothing || print(io, "<style:text-properties fo:color=\"", _FMT_COLOR_HEX[lowercase(m.captures[1])], "\"/>")
    cur = match(r"\[\$([^\]\-]*)", raw)
    currency = cur === nothing || isempty(cur.captures[1]) ? nothing : String(cur.captures[1])
    lit = IOBuffer()
    flush_text() = (s = String(take!(lit)); isempty(s) || print(io, "<number:text>", _xtext(s), "</number:text>"))
    hastext = sec.hastext && !any(t -> t.kind === :digit, toks)
    general = any(t -> t.kind === :general, toks)
    element = if hastext
        "number:text-style"
    elseif sec.isdate
        any(t -> t.kind === :date && !isempty(t.text) && t.text[1] in ('y', 'm', 'd', 'e', 'b'), toks) ? "number:date-style" : "number:time-style"
    elseif any(t -> t.kind === :percent, toks)
        "number:percentage-style"
    elseif currency !== nothing
        "number:currency-style"
    else
        "number:number-style"
    end
    attrs = sec.isdate && any(t -> t.kind === :elapsed, toks) ? " number:truncate-on-overflow=\"false\"" : ""
    digits = findall(t -> t.kind in (:digit, :exp), toks)
    run = if sec.isdate || hastext || general || isempty(digits)
        1:0
    else
        stop = last(digits)
        islash = SC._fraction_slash(toks)
        if islash !== nothing && islash > first(digits)     # a fixed denominator is part of the fraction
            stop = islash + 1
            while stop < length(toks) && (toks[stop + 1].kind == :digit || (toks[stop + 1].kind == :lit && all(isdigit, toks[stop + 1].text)))
                stop += 1
            end
        end
        while stop < length(toks) && toks[stop + 1].kind === :comma   # scaling commas
            stop += 1
        end
        first(digits):max(stop, last(digits))
    end
    k = 1
    while k <= length(toks)
        t = toks[k]
        if k in run
            if k == first(run)
                flush_text()
                el, lx = _numeric_element(toks, run)
                print(io, el); loext |= lx
            end
            # a percent sign or literal inside the number part (other than a fraction's) stays text
            if t.kind === :percent
                flush_text(); print(lit, "%")
            end
        elseif t.kind === :lit
            if currency !== nothing && t.text == currency
                flush_text(); print(io, "<number:currency-symbol>", _xtext(currency), "</number:currency-symbol>")
                currency = nothing
            else
                print(lit, t.text)
            end
        elseif t.kind === :percent
            print(lit, "%")
        elseif t.kind in (:point, :comma, :digit)
            print(lit, t.text)
        elseif t.kind === :pad
            flush_text(); loext = true
            print(io, "<number:text loext:blank-width-char=\"", _xattr(t.text), "\"> </number:text>")
        elseif t.kind === :fill
            flush_text(); print(io, "<number:fill-character>", _xtext(t.text), "</number:fill-character>")
        elseif t.kind === :text
            flush_text(); print(io, "<number:text-content/>")
        elseif t.kind === :general
            flush_text(); print(io, "<number:number number:min-integer-digits=\"1\"/>")
        elseif t.kind === :fracsec
            # the decimals of the seconds before it
            flush_text()
            s = String(take!(io))
            r = findlast("<number:seconds", s)
            s = r === nothing ? s : s[1:last(r)] * " number:decimal-places=\"$(t.text)\"" * s[last(r)+1:end]
            print(io, s)
        else
            el = _date_element(t)
            el === nothing || (flush_text(); print(io, el))
        end
        k += 1
    end
    flush_text()
    return _OdfSection(element, attrs, String(take!(io)), loext)
end

# (whole numbers as Int64 digits while exact: an `Int` threw past 2^31 on a 32-bit build)
_cond_text((op, x)) = "value()" * op * (isinteger(x) && abs(x) < 2.0^53 ? string(Int64(x)) : string(x))

"""
    numfmt_to_odf(code) -> (sections, main)

The data styles of a format code: the conditional ones, as `(condition, _OdfSection)` in
map order, and the main one. `nothing` for `General` (no data style).
"""
function numfmt_to_odf(code::AbstractString)
    secs = SC._parse_numfmt(code; strict = true)
    secs === nothing && throw(ODSError("`$code` is not a valid number format."))
    raws = something(SC._split_sections(code))
    length(secs) == 1 && all(t -> t.kind === :general, secs[1].tokens) && return nothing
    od = [_odf_section(s, r) for (s, r) in zip(secs, raws)]
    textsec = SC._text_section(secs)
    numeric = textsec === nothing ? collect(1:length(secs)) : collect(1:length(secs)-1)
    maps = Tuple{String,_OdfSection}[]
    isempty(numeric) && return maps, od[end]                   # text only (`@`)
    if any(i -> secs[i].condition !== nothing, numeric)
        rest = [i for i in numeric if secs[i].condition === nothing]
        for i in numeric
            secs[i].condition === nothing || push!(maps, (_cond_text(secs[i].condition), od[i]))
        end
        main = textsec === nothing ? (isempty(rest) ? od[numeric[end]] : od[rest[1]]) : od[end]
        textsec === nothing || foreach(i -> push!(maps, ("value()>=0", od[i])), rest)
        return maps, main
    end
    n = length(numeric)
    conds = n == 1 ? (textsec === nothing ? String[] : ["value()>=0", "value()<0"]) :
            n == 2 ? (textsec === nothing ? ["value()>=0"] : ["value()>=0", "value()<0"]) :
                     (textsec === nothing ? ["value()>0", "value()<0"] : ["value()>0", "value()<0", "value()=0"])
    if textsec === nothing
        for (j, c) in enumerate(conds)
            push!(maps, (c, od[numeric[j]]))
        end
        return maps, od[numeric[end]]
    end
    for (j, c) in enumerate(conds)
        push!(maps, (c, od[numeric[min(j, n)]]))
    end
    return maps, od[end]
end

# What the read path knows of a data style (styleindex.jl), from its XML and that of the
# styles its maps apply.
function _data_info(main::AbstractString, others::Vector{String})
    xml = string("<office:document-styles><office:styles>", join(others), replace(main, "\$NAME" => "odsf-info"),
                 "</office:styles></office:document-styles>")
    raw = Dict{String,_RawDataStyle}()
    _scan_styles!(raw, Dict{String,Tuple{Union{Nothing,String},Union{Nothing,String}}}(), Ref{Union{Nothing,String}}(nothing),
                  Set{String}(), xml)
    return _resolve_data_style(raw, "odsf-info", 0)
end

"""
    add_number_format!(styles, code) -> String

The data style name for format code `code` (`""` for `General`), added to the document
(deduplicated) with the styles its sections need.
"""
function add_number_format!(styles::StyleIndex, code::AbstractString)
    sh = stylesheet(styles)
    cached = get(sh.code_styles, code, nothing)
    cached === nothing || return cached
    r = numfmt_to_odf(code)
    name = if r === nothing
        ""
    else
        maps, main = r
        mapxml = IOBuffer()
        others = String[]
        for (cond, s) in maps
            b = _ds_body(s)
            nm = add_data_style!(styles, b, _data_info(b, String[]))
            push!(others, replace(sh.datastyles[nm], "\$NAME" => nm))
            print(mapxml, "<style:map style:condition=\"", _xattr(cond), "\" style:apply-style-name=\"", _xattr(nm), "\"/>")
        end
        body = _ds_body(main, String(take!(mapxml)))
        (main.loext || any(s -> s[2].loext, maps)) && (sh.needs_loext = true)
        add_data_style!(styles, body, _data_info(body, others))
    end
    sh.code_styles[String(code)] = name
    _numfmt_id(sh, String(code))                 # custom ids in the order formats are added, as XLSX.jl
    return name
end

#
# ODF → code
#

# Characters Excel shows as they are without quotes (in a date or time section, also . and ,).
const _PLAIN_LITERAL = Set("\$-+/():!^&'~{}<>= ")

function _code_literal(s::AbstractString, datelike::Bool)
    isempty(s) && return ""
    all(c -> c in _PLAIN_LITERAL || (datelike && c in ('.', ',')), s) && return s
    length(s) == 1 && return "\\" * s
    return "\"" * replace(s, "\"" => "\\\"") * "\""
end

_attrs_dict(c) = Dict{String,String}(String(k) => String(v) for (k, v) in XML.eachattribute!(c))
# A digit count or position from a file: as Int64 (the same on a 32-bit build), and at most 255,
# so a count of a billion digits builds no gigabyte code
_int_attr(a, k, d) = _file_count(get(a, k, ""), d, 0, 255)

function _number_code(a::Dict{String,String})
    haskey(a, "number:decimal-places") || return "General"     # LibreOffice's Standard number
    nd = _int_attr(a, "number:decimal-places", 0)
    nmin = _int_attr(a, "number:min-decimal-places", nd)
    repl = get(a, "number:decimal-replacement", nothing)
    mi = _int_attr(a, "number:min-integer-digits", 0)
    blank = _int_attr(a, "loext:max-blank-integer-digits", 0)
    int = "?"^min(blank, mi) * "0"^max(mi - blank, 0)
    if get(a, "number:grouping", "false") == "true"            # #,##0 / #,### / 0,000
        int = length(int) <= 3 ? "#," * lpad(int, 3, '#') : int[1:end-3] * "," * int[end-2:end]
    end
    isempty(int) && (int = "#")
    dec = "0"^nmin * (repl == " " ? "?" : "#")^max(nd - nmin, 0)
    f = something(tryparse(Float64, get(a, "number:display-factor", "1")), 1.0)   # not a number: none
    commas = isfinite(f) && f > 1 ? round(Int, log10(f) / 3) : 0
    return int * (isempty(dec) ? "" : "." * dec) * ","^commas
end

function _scientific_code(a::Dict{String,String})
    nd = _int_attr(a, "number:decimal-places", 0)
    nmin = _int_attr(a, "number:min-decimal-places", nd)
    mi = max(_int_attr(a, "number:min-integer-digits", 1), 1)
    iv = _int_attr(a, "number:exponent-interval", 1)
    int = iv > mi ? "#"^(iv - mi) * "0"^mi : "0"^mi
    dec = "0"^nmin * "#"^max(nd - nmin, 0)
    sign = get(a, "number:forced-exponent-sign", "true") == "false" ? "E-" : "E+"
    return int * (isempty(dec) ? "" : "." * dec) * sign * "0"^max(_int_attr(a, "number:min-exponent-digits", 2), 1)
end

function _fraction_code(a::Dict{String,String})
    io = IOBuffer()
    # an integer part: LibreOffice writes min-integer-digits="1" for `0/100` too (which has
    # none, and a zero numerator digit), so that case is read as no integer part
    mi = _int_attr(a, "number:min-integer-digits", 0)
    if haskey(a, "number:min-integer-digits") && !(mi > 0 && haskey(a, "loext:zeros-numerator-digits"))
        print(io, mi == 0 ? "#" : "0"^mi, " ")
    end
    nn = max(_int_attr(a, "number:min-numerator-digits", 1), 1)
    z = _int_attr(a, "loext:zeros-numerator-digits", 0)
    print(io, "?"^(nn - min(z, nn)), "0"^min(z, nn), "/")
    if haskey(a, "number:denominator-value")
        print(io, a["number:denominator-value"])
    else
        print(io, "?"^max(_int_attr(a, "number:min-denominator-digits", 1), 1))
    end
    return String(take!(io))
end

const _HEX_COLOR_NAME = Dict(v => uppercasefirst(k) for (k, v) in _FMT_COLOR_HEX)

# The code of one data style element's content, and its maps (condition, style name).
function _style_code(xml::AbstractString)
    c = XML.Cursor(xml)
    XML.next!(c)
    tag = XML.tag(c)
    top = _attrs_dict(c)
    datelike = tag in ("number:date-style", "number:time-style")
    elapsed = get(top, "number:truncate-on-overflow", "true") == "false"
    io = IOBuffer()
    maps = Tuple{String,String}[]
    first_time = true
    XML.for_each_child!(c) do ch
        XML.nodetype(ch) === XML.Element || return
        t = XML.tag(ch)
        a = _attrs_dict(ch)
        long = get(a, "number:style", "short") == "long"
        # the element's text (consuming its children: no skip_element! after it)
        function txt()
            buf = IOBuffer()
            XML.for_each_child!(ch) do x
                nt = XML.nodetype(x)
                if nt === XML.Text || nt === XML.CData
                    v = XML.value(x)
                    v === nothing || print(buf, v)
                elseif nt === XML.Element
                    XML.skip_element!(x)
                end
            end
            return String(take!(buf))
        end
        if t == "style:text-properties"
            col = get(a, "fo:color", "")
            haskey(_HEX_COLOR_NAME, lowercase(col)) && print(io, "[", _HEX_COLOR_NAME[lowercase(col)], "]")
        elseif t == "style:map"
            push!(maps, (get(a, "style:condition", ""), get(a, "style:apply-style-name", "")))
        elseif t == "number:number"
            code = _number_code(a)
            emb = Tuple{Int,String}[]                           # embedded texts: (position, text)
            XML.for_each_child!(ch) do e
                if XML.nodetype(e) === XML.Element && XML.tag(e) == "number:embedded-text"
                    pos = _int_attr(_attrs_dict(e), "number:position", 0)
                    buf = IOBuffer()
                    XML.for_each_child!(x -> (XML.nodetype(x) === XML.Text ? print(buf, XML.value(x)) :
                                              XML.nodetype(x) === XML.Element && XML.skip_element!(x)), e)
                    push!(emb, (pos, String(take!(buf))))
                elseif XML.nodetype(e) === XML.Element
                    XML.skip_element!(e)
                end
            end
            for (pos, s) in sort(emb; by = first, rev = true)   # into the integer part, counted from its end
                ip = something(findfirst('.', code), lastindex(code) + 1) - 1
                at = ip
                n = 0
                while at >= 1 && n < pos
                    code[at] in ('0', '#', '?') && (n += 1)
                    at -= 1
                end
                code = code[1:at] * _code_literal(s, false) * code[at+1:end]
            end
            print(io, code)
            return                                               # its children were consumed
        elseif t == "number:scientific-number"
            print(io, _scientific_code(a))
        elseif t == "number:fraction"
            print(io, _fraction_code(a))
        elseif t == "number:text"
            s = txt()
            b = get(a, "loext:blank-width-char", nothing)
            if b !== nothing
                print(io, "_", first(b, 1))
            elseif tag == "number:percentage-style" && occursin('%', s)   # the percent sign itself
                print(io, join((_code_literal(p, datelike) for p in split(s, '%')), "%"))
            else
                print(io, _code_literal(s, datelike))
            end
            return                                   # txt() consumed the children
        elseif t == "number:fill-character"
            print(io, "*", first(txt() * " ", 1))
            return
        elseif t == "number:currency-symbol"
            print(io, "[\$", txt(), "]")
            return
        elseif t == "number:text-content"
            print(io, "@")
        elseif t == "number:boolean"
            print(io, "BOOLEAN")
        elseif t == "number:year"
            print(io, long ? "yyyy" : "yy")
        elseif t == "number:month"
            textual = get(a, "number:textual", "false") == "true"
            print(io, textual ? (long ? "mmmm" : "mmm") : (long ? "mm" : "m"))
        elseif t == "number:day"
            print(io, long ? "dd" : "d")
        elseif t == "number:day-of-week"
            print(io, long ? "dddd" : "ddd")
        elseif t in ("number:hours", "number:minutes", "number:seconds")
            s = (t == "number:hours" ? "h" : t == "number:minutes" ? "m" : "s")^(long ? 2 : 1)
            if elapsed && first_time && tag == "number:time-style"
                s = "[" * s * "]"
            end
            first_time = false
            print(io, s)
            nd = _int_attr(a, "number:decimal-places", 0)
            t == "number:seconds" && nd > 0 && print(io, ".", "0"^nd)
        elseif t == "number:am-pm"
            print(io, "AM/PM")
        elseif t == "number:quarter"
            print(io, long ? "QQ" : "Q")
        elseif t == "number:week-of-year"
            print(io, "WW")
        elseif t == "number:era"
            print(io, long ? "GGG" : "G")
        end
        XML.skip_element!(ch)
    end
    return String(take!(io)), maps
end

const _STD_MAPS = (["value()>=0"], ["value()>0", "value()<0"], ["value()>0", "value()<0", "value()=0"])

"""
    data_style_code(sh::StyleSheet, name) -> String

The format code of data style `name` (`"General"` for none or an unknown one).
"""
function data_style_code(sh::StyleSheet, name::AbstractString)
    (isempty(name) || !haskey(sh.datastyles, name)) && return "General"
    main, maps = _style_code(replace(sh.datastyles[name], "\$NAME" => _xattr(name)))
    isempty(maps) && return isempty(main) ? "General" : main
    conds = [replace(c, " " => "") for (c, _) in maps]
    secs = [first(_style_code(get(sh.datastyles, n, "<x/>"))) for (_, n) in maps]
    std = any(s -> conds == s, _STD_MAPS) ||
          (length(conds) == 2 && conds == ["value()>=0", "value()<0"] && secs[1] == secs[2])
    if std
        conds == ["value()>=0", "value()<0"] && (secs = secs[1:1])          # one number section, then text
        return join([secs; main], ';')
    end
    parts = String[]
    for (c, s) in zip(conds, secs)
        m = match(r"^value\(\)(<=|>=|<>|!=|<|>|=)(.+)$", c)
        push!(parts, m === nothing ? s : "[" * replace(m.captures[1], "!=" => "<>") * m.captures[2] * "]" * s)
    end
    return join([parts; main], ';')
end

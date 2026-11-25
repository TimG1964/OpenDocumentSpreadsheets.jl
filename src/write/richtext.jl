# Rich text in cells (D-088, F-087): a `RichTextString` written as LibreOffice keeps one, and read back
# with `getRichTextString`.
#   - writing: the cell is a string with `F_RICH`, its paragraphs in `StyleIndex.rich` (as a URL field's,
#     D-072, with no link). A run with attributes is a `text:span` with a text style (`TR1`, … in the
#     content's automatic styles, one per set of properties) that holds only those attributes, as
#     LibreOffice's own rich text does: the rest are the cell's. A line break starts a new paragraph.
#   - reading: the package's own cells from their paragraphs; a file's from its cell's paragraphs (one
#     walk of the sheet, on first use) and its automatic text styles, while the cell's text is unchanged.

#
# Writing
#

# A run's text properties (LibreOffice's, as `setFont` writes a cell's: with their Asian and complex
# twins), or "" for none.
function _run_props(st::StyleIndex, run::RichTextRun)
    a = run.atts
    a === nothing && return ""
    ch = _Changes()
    get(a, :bold, false) in (true, 1) && _font_prop!(ch, "fo:font-weight", "bold")
    get(a, :italic, false) in (true, 1) && _font_prop!(ch, "fo:font-style", "italic")
    get(a, :under, false) in (true, 1) && push!(ch, _UNDER_KEYS[1] => "solid", _UNDER_KEYS[2] => "auto", _UNDER_KEYS[3] => "font-color")
    get(a, :strike, false) in (true, 1) && push!(ch, _STRIKE_KEYS[1] => "solid", _STRIKE_KEYS[2] => "single")
    v = get(a, :vertAlign, nothing)
    v == "superscript" && push!(ch, "style:text-position" => "super 58%")       # LibreOffice's (F-087)
    v == "subscript" && push!(ch, "style:text-position" => "sub 58%")
    c = get(a, :color, nothing)
    c === nothing || push!(ch, "fo:color" => SheetCore.odf_color(c))
    s = get(a, :size, nothing)
    s === nothing || _font_prop!(ch, "fo:font-size", _fmt_num(s) * "pt")
    n = get(a, :name, nothing)
    if n !== nothing
        _check_xml_text(String(n))
        _font_prop!(ch, "style:font-name", _escape_attr(add_font_face!(st, String(n))))
    end
    io = IOBuffer()
    for (k, val) in ch
        val === nothing && continue
        print(io, ' ', k, "=\"", k == "style:font-name" || startswith(k, "style:font-name-") ? val : sprint(_escape_attr, val), '"')
    end
    return String(take!(io))
end

# The text style holding `props`: its name, one per set of properties.
function _text_style!(st::StyleIndex, props::String)
    i = findfirst(==(props), st.texts)
    i === nothing && (push!(st.texts, props); i = length(st.texts))
    return "TR$i"
end

# The text styles' XML, for the content's automatic styles.
function text_styles_xml(st::StyleIndex)
    isempty(st.texts) && return ""
    io = IOBuffer()
    for (i, p) in enumerate(st.texts)
        print(io, "<style:style style:name=\"TR", i, "\" style:family=\"text\"><style:text-properties", p, "/></style:style>")
    end
    return String(take!(io))
end

# A run's text: escaped, its runs of spaces and tabs as `_write_paragraphs` writes them.
# Its spaces by its place in the paragraph: a padding character on a side that is not the paragraph's
# edge makes a single space there plain, as `_write_paragraphs` writes one inside a paragraph.
function _run_text(io::IO, s::AbstractString; atstart::Bool = true, atend::Bool = true)
    isempty(s) && return
    t = sprint(_write_paragraphs, (atstart ? "" : "x") * s * (atend ? "" : "x"))     # "<text:p>…</text:p>"
    a = ncodeunits("<text:p>") + 1 + (atstart ? 0 : 1)
    b = ncodeunits(t) - ncodeunits("</text:p>") - (atend ? 0 : 1)
    print(io, SubString(t, a, prevind(t, b + 1)))
end

# The paragraphs of a rich string: a paragraph per line, a span per run with attributes.
function _rich_paragraphs(st::StyleIndex, rts::RichTextString)
    paras = [Tuple{String,String}[]]                  # each paragraph's pieces: (text, style name)
    for run in rts.runs
        props = _run_props(st, run)
        name = isempty(props) ? "" : _text_style!(st, props)
        for (k, part) in enumerate(eachsplit(replace(run.text, "\r\n" => "\n", '\r' => '\n'), '\n'))
            k > 1 && push!(paras, Tuple{String,String}[])
            isempty(part) || push!(paras[end], (String(part), name))
        end
    end
    io = IOBuffer()
    for pieces in paras
        if isempty(pieces)
            print(io, "<text:p/>")
            continue
        end
        print(io, "<text:p>")
        for (i, (t, name)) in enumerate(pieces)
            isempty(name) || print(io, "<text:span text:style-name=\"", name, "\">")
            _run_text(io, t; atstart = i == 1, atend = i == length(pieces))
            isempty(name) || print(io, "</text:span>")
        end
        print(io, "</text:p>")
    end
    return String(take!(io))
end

# The attributes `setFont` can give a whole cell (all but super- and subscript).
_cell_font_atts(a) = a === nothing || all(k -> k !== :vertAlign || a[k] == "baseline", keys(a))

# A rich string written to cell (r, c), as XLSX.jl writes one: a single run (or runs without
# attributes) as plain text, the run's attributes the cell's font; more as spans (D-088).
function _set_cell!(ws::Worksheet, row::Int, col::Int, rts::RichTextString)
    runs = rts.runs
    if all(r -> isempty(_norm_atts(r.atts)), runs)
        return _set_cell!(ws, row, col, rts.text)
    elseif length(runs) == 1 && _cell_font_atts(runs[1].atts)
        _set_cell!(ws, row, col, rts.text)
        a = runs[1].atts
        kw = Pair{Symbol,Any}[]
        get(a, :bold, false) in (true, 1) && push!(kw, :bold => true)
        get(a, :italic, false) in (true, 1) && push!(kw, :italic => true)
        get(a, :under, false) in (true, 1) && push!(kw, :under => "single")
        get(a, :strike, false) in (true, 1) && push!(kw, :strike => true)
        haskey(a, :color) && push!(kw, :color => a[:color])
        haskey(a, :size) && push!(kw, :size => a[:size])
        haskey(a, :name) && push!(kw, :name => String(a[:name]))
        isempty(kw) || setFont(ws, CellRef(row, col); kw...)
        return rts
    end
    _set_cell!(ws, row, col, rts.text)
    s = _cached_store(ws)
    d = cell_data(s, row, col)
    st = get_odsfile(ws).styles
    push!(st.rich, _rich_paragraphs(st, rts))
    push!(st.richinfo, ("", d.text))                          # a rich string: no link
    new = CellData(CK_STRING, (d.flags & F_COVERED) | F_RICH, d.style, UInt64(length(st.rich)), d.text, nothing, d.colspan, d.rowspan)
    store_set!(s, row, col, new)
    _after_cell_edit!(ws, row, col, d, new)
    return rts
end

#
# Reading
#

# A text style's properties as a run's attributes (XLSX.jl's), those that are set.
function _text_atts(p::Dict{String,String})
    a = Pair{Symbol,Any}[]
    w = get(p, "fo:font-weight", "normal")
    (w == "bold" || something(tryparse(Int, w), 0) >= 600) && push!(a, :bold => true)
    get(p, "fo:font-style", "normal") in ("italic", "oblique") && push!(a, :italic => true)
    get(p, "style:text-underline-style", "none") != "none" && push!(a, :under => true)
    (get(p, "style:text-line-through-style", "none") != "none" || get(p, "style:text-line-through-type", "none") != "none") &&
        push!(a, :strike => true)
    pos = get(p, "style:text-position", nothing)
    if pos !== nothing
        f = split(pos)
        e = isempty(f) ? "0%" : f[1]
        e == "super" || (endswith(e, "%") && something(tryparse(Float64, e[1:end-1]), 0.0) > 0) ? push!(a, :vertAlign => "superscript") :
        e == "sub" || (endswith(e, "%") && something(tryparse(Float64, e[1:end-1]), 0.0) < 0) ? push!(a, :vertAlign => "subscript") : nothing
    end
    c = get(p, "fo:color", nothing)
    if c !== nothing
        rgb = SheetCore.parse_odf_color(c)
        rgb === nothing || push!(a, :color => "FF" * uppercase(lstrip(rgb, '#'))[max(1, end - 5):end])
    end
    sz = get(p, "fo:font-size", nothing)
    if sz !== nothing
        pt = _length_pt(sz)
        pt === nothing || push!(a, :size => Float64(pt))
    end
    n = get(p, "style:font-name", nothing)
    n === nothing || push!(a, :name => XML.unescape(n))
    return isempty(a) ? nothing : a
end


# The runs of a cell's paragraphs (`text:p` elements' XML), each span's attributes from `styles`. A line
# break between paragraphs starts the next paragraph's first run; runs alike are joined.
function _paragraph_runs(paras::AbstractString, styles)
    doc = parse(XML.Node, "<r xmlns:text=\"urn:oasis:names:tc:opendocument:xmlns:text:1.0\" xmlns:xlink=\"http://www.w3.org/1999/xlink\">" *
                          String(paras) * "</r>")
    root = only(c for c in XML.children(doc) if XML.nodetype(c) === XML.Element)
    runs = Tuple{String,Union{Nothing,Vector{Pair{Symbol,Any}}}}[]
    pending = Ref(0)                                  # line breaks waiting for the next text
    function add!(t, a)
        isempty(t) && return
        pending[] > 0 && (t = repeat("\n", pending[]) * t; pending[] = 0)
        if !isempty(runs) && runs[end][2] == a
            runs[end] = (runs[end][1] * t, a)
        else
            push!(runs, (t, a))
        end
    end
    attrs(c) = something(XML.attributes(c), Dict{String,String}())
    function walk(n, a)
        for c in XML.children(n)
            if XML.nodetype(c) === XML.Text
                add!(XML.value(c), a)
            elseif XML.nodetype(c) === XML.Element
                tg = XML.tag(c)
                if tg == "text:span"
                    nm = get(attrs(c), "text:style-name", nothing)
                    sa = nm === nothing ? nothing : _text_atts(get(styles, nm, Dict{String,String}()))
                    walk(c, sa === nothing ? a : sa)
                elseif tg == "text:s"
                    add!(repeat(" ", something(tryparse(Int, get(attrs(c), "text:c", "1")), 1)), a)
                elseif tg == "text:tab"
                    add!("\t", a)
                elseif tg == "text:line-break"
                    pending[] += 1
                else
                    walk(c, a)                        # a link's text, a field's
                end
            end
        end
    end
    first = true
    for p in XML.children(root)
        XML.nodetype(p) === XML.Element || continue
        first || (pending[] += 1)
        first = false
        walk(p, nothing)
    end
    pending[] > 0 && push!(runs, (repeat("\n", pending[]), nothing))
    return runs
end

_rich_string(runs) = RichTextString([RichTextRun(t, a) for (t, a) in runs])

# The file's automatic text styles (name => properties), read once from its content's head.
function _file_text_styles(xf)
    st = xf.styles
    st.filetexts[1] === nothing || return st.filetexts[1]
    d = Dict{String,Dict{String,String}}()
    src = xf.container === nothing ? "" : xf.container.zip === nothing ? xf.content : read_part_text(xf.container, "content.xml")
    b = findfirst("<office:body", src)
    head = b === nothing ? src : SubString(src, 1, first(b))
    for m in eachmatch(r"<style:style\b[^>]*\bstyle:family=\"text\"[^>]*>.*?</style:style>"s, head)
        nm = match(r"style:name=\"([^\"]*)\"", m.match)
        nm === nothing && continue
        tp = match(r"<style:text-properties\b([^>]*?)/?>", m.match)
        d[XML.unescape(nm.captures[1])] = tp === nothing ? Dict{String,String}() : _props_dict(tp.captures[1])
    end
    st.filetexts[1] = d
    return d
end

_props_dict(p::AbstractString) = Dict{String,String}(String(a.captures[1]) => XML.unescape(String(a.captures[2]))
                                                    for a in eachmatch(r"([\w:-]+)=\"([^\"]*)\"", p))

"""
    getRichTextString(sheet, ref) -> Union{RichTextString, Nothing}
    getRichTextString(sheet, row, col) -> Union{RichTextString, Nothing}
    getRichTextString(xf, "Sheet1!A1") -> Union{RichTextString, Nothing}

A text cell's rich text, as XLSX.jl's: its runs and their attributes, or `nothing` for a cell whose
text has no runs of its own formatting (plain text, a number, an empty cell). It reads the cells
written with a [`RichTextString`](@ref) and LibreOffice's own rich text (its spans' text styles), while
their text is unchanged. A run's attributes are those its span sets: the rest are the cell's.
"""
function getRichTextString(ws::Worksheet, ref::CellRef)
    r, c = row_number(ref), column_number(ref)
    d = cell_data(_cached_store(ws), r, c)
    (d === nothing || d.kind !== CK_STRING || d.formula !== nothing) && return nothing
    xf = get_odsfile(ws)
    st = xf.styles
    if (d.flags & F_RICH) != 0
        own = Dict("TR$i" => _props_dict(p) for (i, p) in enumerate(st.texts))
        runs = _paragraph_runs(st.rich[d.bits], own)
    else
        (d.flags & F_PLAIN) != 0 && return nothing
        run = _file_rich_at(ws, r, c)
        (run === nothing || run[6] != d.text) && return nothing
        runs = _paragraph_runs(run[5], _file_text_styles(xf))
    end
    any(x -> x[2] !== nothing, runs) || return nothing
    return _rich_string(runs)
end
getRichTextString(ws::Worksheet, ref::AbstractString) = getRichTextString(ws, CellRef(ref))
getRichTextString(ws::Worksheet, row::Integer, col::Integer) = getRichTextString(ws, CellRef(row, col))
function getRichTextString(xf::ODSFile, ref::AbstractString)
    s = replace(String(ref), '!' => '.')
    i = findlast('.', s)
    i === nothing && throw(ODSError("Give the sheet and cell: \"Sheet1!A1\" or \"Sheet1.A1\"."))
    sheet = strip(s[1:prevind(s, i)], '\'')
    return getRichTextString(xf[String(sheet)], CellRef(s[nextind(s, i):end]))
end

# The file's cell holding (r, c) now, with spans: (row, nrows, col, ncols, paragraphs, text), or nothing.
function _file_rich_at(ws::Worksheet, r::Int, c::Int)
    (ws.entry === nothing || _sort_cleared(ws, r, c)) && return nothing
    o = _original_line(ws.rowmap, r)
    p = _original_line(ws.colmap, c)
    (o == 0 || p == 0) && return nothing
    for run in _file_rich(ws)
        run[1] <= o < run[1] + run[2] && run[3] <= p < run[3] + run[4] && return run
    end
    return nothing
end

# The sheet's original cells whose text has spans (one walk of its table, on first use).
function _file_rich(ws::Worksheet)
    ws.filerich === nothing || return ws.filerich
    runs = Tuple{Int,Int,Int,Int,String,String}[]
    if ws.entry !== nothing
        node = ws.entry.node
        src = parent(XML.sourcetext(node))
        row = Ref(0)
        walk(n::XML.LazyNode) = begin
            cur = XML.Cursor(n)
            XML.next!(cur)
            XML.for_each_child!(cur) do ch
                XML.nodetype(ch) === XML.Element || return
                t = XML.tag(ch)
                if t == "table:table-row"
                    nrows = min(_repeat_attr(ch, "table:number-rows-repeated"), SheetCore.MAX_ROWS - row[])
                    r0 = row[] + 1
                    row[] += nrows
                    rc = XML.Cursor(XML.LazyNode(ch))
                    XML.next!(rc)
                    col = 0
                    XML.for_each_child!(rc) do cc
                        XML.nodetype(cc) === XML.Element || return
                        if XML.tag(cc) in ("table:table-cell", "table:covered-table-cell")
                            k = _repeat_attr(cc, "table:number-columns-repeated")
                            cl = XML.LazyNode(cc)
                            sp = XML.sourcespan(cl)
                            if occursin("<text:span", SubString(src, first(sp), last(sp)))
                                paras = String(_cell_paras(src, cl))
                                text = join(t for (t, _) in _paragraph_runs(paras, Dict{String,Dict{String,String}}()))
                                push!(runs, (r0, nrows, col + 1, k, paras, text))
                            end
                            col += k
                        end
                        XML.skip_element!(cc)
                    end
                elseif t in _ROW_CONTAINERS
                    walk(XML.LazyNode(ch))
                end
                XML.skip_element!(ch)
            end
        end
        walk(node)
    end
    ws.filerich = runs
    return runs
end

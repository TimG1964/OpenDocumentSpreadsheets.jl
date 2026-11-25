# Hyperlinks (phase 6 step 3, D-072): XLSX.jl's `addHyperlink`, `deleteHyperlink`, `getHyperlink`
# and `getHyperlinks`, on LibreOffice's two kinds of link (F-058):
#   - a URL field in the cell's text: `<text:a xlink:href=… xlink:type="simple">`. A text cell (or an
#     empty one, given its display text) gets one around its whole text, as LibreOffice's import
#     of an xlsx link does. In the model the cell is a string with `F_RICH`, whose `bits` index
#     its paragraphs in `StyleIndex.rich`; writing a new value drops it, as in LibreOffice.
#   - a cell link: the cell's `Hyperlink` property, `<style:hyperlink>` and `<loext:hyperlink>` in
#     its automatic style's `style:table-cell-properties`. A number, a formula, and the cells of
#     a range after its first get one, as the import gives them.
# The API follows XLSX.jl 0.13.4 (src/hyperlinks.jl), MIT License, Copyright (c) 2018-2026 Felipe
# Noronha Tavares and other contributors: its names, keywords and return shape. LibreOffice has
# no tooltips (an error), no link over a range (a link per cell), and keeps a relative URL
# relative to the package (`../report.pdf`).

const _XLINK_NS = "http://www.w3.org/1999/xlink"
const _DRAW_NS = "urn:oasis:names:tc:opendocument:xmlns:drawing:1.0"

const HyperlinkInfo = NamedTuple{(:sheet, :ref, :url, :location, :display, :tooltip),
    Tuple{String,String,Union{Nothing,String},Union{Nothing,String},Union{Nothing,String},Union{Nothing,String}}}

# Whether a patched content.xml must declare `xlink`: links were added, as fields or cell links.
_needs_xlink(st::StyleIndex) = !isempty(st.rich) ||
    (sh = st.sheet[1]; sh !== nothing && any(id -> occursin("xlink:", sh.cells[id + 1].cell.inner), sh.added))

#
# Targets: XLSX.jl's url and location, as LibreOffice's href, and back
#

# A URL with a scheme (`https:`, `mailto:`, `file:`; not a drive letter), or an absolute path.
_absolute_url(u::AbstractString) = occursin(r"^[A-Za-z][A-Za-z0-9+.\-]+:", u) || startswith(u, '/') || startswith(u, '\\') ||
                                   occursin(r"^[A-Za-z]:[\\/]", u)
# A link to a file relative to the document: not absolute, not a place in the workbook.
_relative_url(h::AbstractString) = !startswith(h, '#') && !_absolute_url(h)

# A URL as LibreOffice keeps it once loaded (F-065): the scheme in lower case; for http, https and
# ftp, `/` after a host with no path, and spaces as `%20`.
function _normalize_url(u::String)
    m = match(r"^([A-Za-z][A-Za-z0-9+.\-]+):(.*)$"s, u)
    m === nothing && return u
    scheme = lowercase(m.captures[1])
    rest = String(m.captures[2])
    if scheme in ("http", "https", "ftp") && startswith(rest, "//")
        k = findnext(c -> c == '/' || c == '?' || c == '#', rest, 3)
        if k === nothing
            rest *= "/"
        elseif rest[k] != '/'
            rest = string(SubString(rest, 1, prevind(rest, k)), '/', SubString(rest, k))
        end
        rest = replace(rest, ' ' => "%20")
    end
    return string(scheme, ':', rest)
end

# A place in the workbook: `Sheet!A1` (XLSX.jl's form) as `Sheet.A1`; LibreOffice's own forms
# (`Sheet.A1`, `'My Sheet'.C3`, a range, a defined name) as they are.
function _location_ref(loc::AbstractString)
    i = findlast('!', loc)
    i === nothing && return String(loc)
    return string(SubString(loc, 1, prevind(loc, i)), '.', SubString(loc, nextind(loc, i)))
end

# Whether the hrefs of a workbook's links are in a flat file's form: relative to the document's
# folder (else a zipped package's: relative to the package, `../` for the document's folder; F-065).
_links_flat(xf::ODSFile) = xf.container !== nothing ? xf.container.format === :fods : xf.styles.linkflat[1]

function _link_href(xf::ODSFile, url, location)
    if url !== nothing
        u = _normalize_url(String(url))
        return _relative_url(u) && !_links_flat(xf) ? "../" * u : u
    end
    return "#" * _location_ref(location)
end

# (url, location) of an href, as getHyperlink returns them: a relative file from the document's folder.
function _href_target(href::AbstractString, flat::Bool)
    startswith(href, '#') && return (nothing, String(SubString(href, 2)))
    !flat && startswith(href, "../") && return (String(SubString(href, 4)), nothing)
    return (String(href), nothing)
end

_link_info(ws::Worksheet, r::Int, c::Int, href::AbstractString, display) =
    (t = _href_target(href, _links_flat(get_odsfile(ws)));
     HyperlinkInfo((ws.name, string(SheetCore.encode_column_number(c), r), t[1], t[2], display, nothing)))

# A new document's relative hrefs in a flat file's form or a zipped package's, for the file being
# written (F-065). Its links are all OpenDocumentSpreadsheets's: its URL fields and added styles.
function _set_link_base!(st::StyleIndex, flat::Bool)
    st.linkflat[1] == flat && return
    conv(h) = isempty(h) || !_relative_url(h) ? h : flat ? (startswith(h, "../") ? String(SubString(h, 4)) : h) : "../" * h
    rx = r"xlink:href=\"([^\"]*)\""
    swap(s) = replace(s, rx => m -> (h = XML.unescape(match(rx, m).captures[1]); "xlink:href=\"" * sprint(_escape_attr, conv(h)) * "\""))
    for i in eachindex(st.rich)
        st.rich[i] = swap(st.rich[i])
        h, t = st.richinfo[i]
        st.richinfo[i] = (conv(h), t)
    end
    sh = st.sheet[1]
    if sh !== nothing
        for id in sh.added
            cs = sh.cells[id + 1]
            occursin("xlink:href", cs.cell.inner) || continue
            new = with_cell(cs, PropSet(cs.cell.attrs, swap(cs.cell.inner)))
            delete!(sh.dedup, cs)
            sh.cells[id + 1] = new
            sh.dedup[new] = id
        end
    end
    st.linkflat[1] = flat
    return
end

#
# Cell links: a style property
#

const _HLINK_RX = r"<(?:style|loext):hyperlink\b[^>]*?/>"

# `cs` with the cell link `href`, or without one (`nothing`).
function _with_cell_link(cs::CellStyle, href::Union{Nothing,String})
    inner = replace(cs.cell.inner, _HLINK_RX => "")
    if href !== nothing
        h = sprint(_escape_attr, href)
        inner *= "<style:hyperlink xlink:href=\"$h\" xlink:type=\"simple\"/><loext:hyperlink xlink:href=\"$h\" xlink:type=\"simple\"/>"
    end
    return inner == cs.cell.inner ? cs : with_cell(cs, PropSet(cs.cell.attrs, inner))
end

const _HLINK_HREF_RX = r"<style:hyperlink\b[^>]*?\bxlink:href=\"([^\"]*)\""

# The cell link of style id `id` (its own: LibreOffice keeps cell links in automatic styles), or nothing.
function _style_link(st::StyleIndex, id::Integer)
    id < 0 && return nothing
    m = match(_HLINK_HREF_RX, cell_style(st, id).cell.inner)
    return m === nothing ? nothing : XML.unescape(m.captures[1])
end

function _set_cell_links!(ws::Worksheet, blocks::Vector{FormatBlock}, href::Union{Nothing,String})
    isempty(blocks) && return
    st = get_odsfile(ws).styles
    href === nothing || (stylesheet(st).needs_loext = true)
    _apply_map!(_style_map(cs -> _with_cell_link(cs, href), st), ws, blocks)
    return
end

#
# URL fields: rich string cells
#

# The paragraphs of `text` as one URL field each (href already escaped).
function _link_paragraphs(text::AbstractString, href::AbstractString)
    io = IOBuffer()
    _write_paragraphs(io, text)
    a = "<text:a xlink:href=\"$href\" xlink:type=\"simple\">"
    return replace(String(take!(io)), "<text:p>" => "<text:p>" * a, "</text:p>" => "</text:a></text:p>")
end

# Cell (r, c) as `text` with a URL field to `href` around it.
function _set_link_field!(ws::Worksheet, r::Int, c::Int, text::AbstractString, href::String)
    _set_cell!(ws, r, c, String(text))
    s = _cached_store(ws)
    d = cell_data(s, r, c)
    st = get_odsfile(ws).styles
    push!(st.rich, _link_paragraphs(d.text, sprint(_escape_attr, href)))
    push!(st.richinfo, (href, d.text))
    new = CellData(CK_STRING, (d.flags & F_COVERED) | F_RICH, d.style, UInt64(length(st.rich)), d.text, nothing, d.colspan, d.rowspan)
    store_set!(s, r, c, new)
    _after_cell_edit!(ws, r, c, d, new)
    return
end

# Whether a cell can hold a URL field: empty, or text that is not a formula's.
_field_cell(d::Union{Nothing,CellData}) = d === nothing || (d.kind === CK_EMPTY && d.formula === nothing) ||
                                           (d.kind === CK_STRING && d.formula === nothing)

#
# The URL fields the file holds (read on first use, D-069)
#

# The URL fields of an original cell's paragraphs, and its text (as the reader reads it).
function _cell_fields(cell::XML.LazyNode)
    links = Tuple{String,String}[]
    buf = IOBuffer()
    n = 0
    c = XML.Cursor(cell)
    XML.next!(c)
    XML.for_each_child!(c) do ch
        XML.nodetype(ch) === XML.Element || return
        t = XML.tag(ch)
        if t == "text:p" || t == "text:h"
            n > 0 && write(buf, '\n')
            n += 1
            _para_fields!(buf, links, ch)
        else
            XML.skip_element!(ch)
        end
    end
    text = replace(String(take!(buf)), "\r\n" => "\n", '\r' => '\n')
    return links, text
end

# `_para_text!` (the reader's), noting each `text:a` with its text.
function _para_fields!(buf::IOBuffer, links::Vector{Tuple{String,String}}, c)
    XML.for_each_child!(c) do ch
        nt = XML.nodetype(ch)
        if nt === XML.Text || nt === XML.CData
            v = XML.value(ch)
            v === nothing || write(buf, v)
        elseif nt === XML.Element
            t = XML.tag(ch)
            if t == "text:a"
                href = ""
                for (k, v) in XML.eachattribute!(ch)
                    k == "xlink:href" && (href = String(v))
                end
                lb = IOBuffer()
                _para_text!(lb, ch)
                s = String(take!(lb))
                write(buf, s)
                push!(links, (href, s))
            elseif t == "text:s"
                n = 1
                for (k, v) in XML.eachattribute!(ch)
                    k == "text:c" && (n = something(tryparse(Int, v), 1))
                end
                for _ in 1:n
                    write(buf, ' ')
                end
                XML.skip_element!(ch)
            elseif t == "text:tab"
                write(buf, '\t'); XML.skip_element!(ch)
            elseif t == "text:line-break"
                write(buf, '\n'); XML.skip_element!(ch)
            elseif t == "office:annotation" || t == "text:note" || startswith(t, "draw:")
                XML.skip_element!(ch)
            else
                _para_fields!(buf, links, ch)
            end
        end
    end
    return
end

function _repeat_attr(ch, key::String)
    n = 1
    for (k, v) in XML.eachattribute!(ch)
        k == key && (n = max(1, something(tryparse(Int, v), 1)))
    end
    return n
end

# The sheet's original cells with URL fields, as runs (one walk of its table, on first use).
function _file_links(ws::Worksheet)
    ws.links === nothing || return ws.links
    runs = FileLinkRun[]
    if ws.entry !== nothing
        node = ws.entry.node
        src = parent(XML.sourcetext(node))
        row = Ref(0)
        walk(n::XML.LazyNode) = begin
            c = XML.Cursor(n)
            XML.next!(c)
            XML.for_each_child!(c) do ch
                XML.nodetype(ch) === XML.Element || return
                t = XML.tag(ch)
                if t == "table:table-row"
                    nrows = min(_repeat_attr(ch, "table:number-rows-repeated"), SheetCore.MAX_ROWS - row[])
                    r0 = row[] + 1
                    row[] += nrows
                    ln = XML.LazyNode(ch)
                    rc = XML.Cursor(ln)
                    XML.next!(rc)
                    col = 0
                    XML.for_each_child!(rc) do cc
                        XML.nodetype(cc) === XML.Element || return
                        if XML.tag(cc) in ("table:table-cell", "table:covered-table-cell")
                            k = _repeat_attr(cc, "table:number-columns-repeated")
                            cl = XML.LazyNode(cc)
                            sp = XML.sourcespan(cl)
                            if occursin("text:a", SubString(src, first(sp), last(sp)))
                                links, text = _cell_fields(cl)
                                isempty(links) || push!(runs, FileLinkRun(r0, nrows, col + 1, k, links, text, _cell_paras(src, cl)))
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
    ws.links = runs
    return runs
end

# The original line of current line `cur` (`0`: inserted since), through an IndexMap or none.
function _original_line(m::Union{Nothing,IndexMap}, cur::Int)
    m === nothing && return cur
    for (so, len, c) in m.segs
        c <= cur <= c + len - 1 && return so + (cur - c)
    end
    return 0
end
_current_line(m::Union{Nothing,IndexMap}, o::Int) = m === nothing ? o : current_line(m, o)

# An original cell's paragraphs, first to last, as written.
function _cell_paras(src::String, cell::XML.LazyNode)
    a = 0; b = 0
    c = XML.Cursor(cell)
    XML.next!(c)
    XML.for_each_child!(c) do ch
        XML.nodetype(ch) === XML.Element || return
        if XML.tag(ch) in ("text:p", "text:h")
            sp = XML.sourcespan(XML.LazyNode(ch))
            a == 0 && (a = first(sp))
            b = last(sp)
        end
        XML.skip_element!(ch)
    end
    return a == 0 ? "" : String(SubString(src, a, b))
end

# The run of original fields at current cell (r, c), or nothing (a cell a sort filled from another
# has none of its original's, F-072).
function _file_link_at(ws::Worksheet, r::Int, c::Int)
    (ws.entry === nothing || _sort_cleared(ws, r, c)) && return nothing
    o = _original_line(ws.rowmap, r)
    p = _original_line(ws.colmap, c)
    (o == 0 || p == 0) && return nothing
    for run in _file_links(ws)
        run.row <= o < run.row + run.nrows && run.col <= p < run.col + run.ncols && return run
    end
    return nothing
end

# Whether the file's fields of a cell are still its own: they are kept on save while the cell's
# text is the same (D-071) and they were not removed (`F_PLAIN`).
_fields_kept(d::Union{Nothing,CellData}, run::FileLinkRun) =
    d !== nothing && d.kind === CK_STRING && d.formula === nothing && (d.flags & (F_RICH | F_PLAIN)) == 0 && d.text == run.text

#
# The links of one cell
#

function _cell_links(ws::Worksheet, r::Int, c::Int)
    out = HyperlinkInfo[]
    st = get_odsfile(ws).styles
    d = cell_data(_cached_store(ws), r, c)
    if d !== nothing && (d.flags & F_RICH) != 0
        href, text = st.richinfo[d.bits]
        isempty(href) || push!(out, _link_info(ws, r, c, href, text))        # rich text: no link (D-088)
    else
        run = _file_link_at(ws, r, c)
        if run !== nothing && _fields_kept(d, run)
            for (href, text) in run.links
                push!(out, _link_info(ws, r, c, href, text))
            end
        end
    end
    h = _style_link(st, effective_style(ws, r, c))
    h === nothing || push!(out, _link_info(ws, r, c, h, nothing))
    return out
end

#
# The cells a reference names
#

function _link_block(ref::AbstractString)
    is_valid_cellname(ref) && (x = CellRef(ref); return row_number(x):row_number(x), column_number(x):column_number(x))
    if is_valid_cellrange(ref)
        g = CellRange(ref)
        return row_number(g.start):row_number(g.stop), column_number(g.start):column_number(g.stop)
    end
    throw(ODSError("Invalid cell or range reference: `$ref`."))
end
_link_block(ref::CellRef) = row_number(ref):row_number(ref), column_number(ref):column_number(ref)
_link_block(g::CellRange) = row_number(g.start):row_number(g.stop), column_number(g.start):column_number(g.stop)

#
# The API
#

"""
    addHyperlink(sheet, ref; url=nothing, location=nothing, display=nothing) -> NamedTuple
    addHyperlink(sheet, row, col; kw...) -> NamedTuple

Make a cell, or each cell of a range (`"A1:C3"`), a hyperlink, as LibreOffice's import of
XLSX.jl's links does (F-058, D-072). Give exactly one of:

- `url`: an address outside the workbook (`"https://julialang.org"`,
  `"mailto:team@example.com"`), or a file relative to the document's folder (`"report.pdf"`)
- `location`: a place in the workbook: a cell or range (`"Sheet2.A1"` or XLSX.jl's
  `"Sheet2!A1"`, `"'My Sheet'.C3"`), a sheet, or a defined name

LibreOffice has two kinds of link. An empty cell, or a text cell, gets a URL field around its
text: an empty cell takes `display` (or `url`, or `location`) as its text, and a text cell keeps
its text. A number, a formula, and every cell of a range after the first get a cell link: their
value is unchanged, and a click on the cell follows it. A cell's previous links are replaced.
Writing a new value into a cell drops its URL field, as in LibreOffice; its cell link stays.

A URL is kept as LibreOffice keeps it once loaded (F-065): its scheme in lower case, and for
`http`, `https` and `ftp` a `/` after a host with no path and spaces as `%20`
(`"https://julialang.org"` becomes `"https://julialang.org/"`). A relative file is written as
the file's format needs it: `../report.pdf` in a zipped `.ods`, whose links are relative to the
package, and `report.pdf` in a flat `.fods`.

LibreOffice has no tooltips: `tooltip` is an error.

Returns the link of the first cell, as [`getHyperlink`](@ref) reads it. The file must be
writable.
"""
function addHyperlink(ws::Worksheet, ref::Union{AbstractString,CellRef,CellRange};
                      url::Union{Nothing,AbstractString} = nothing, location::Union{Nothing,AbstractString} = nothing,
                      display::Union{Nothing,AbstractString} = nothing, tooltip::Union{Nothing,AbstractString} = nothing)
    _require_writable(ws, "add a hyperlink")
    (url === nothing) == (location === nothing) &&
        throw(ODSError("Give exactly one of `url` (an address outside the workbook) or `location` (a place in it)."))
    target = something(url, location)
    isempty(target) && throw(ODSError("A hyperlink's `$(url === nothing ? "location" : "url")` cannot be empty."))
    tooltip === nothing ||
        throw(ODSError("LibreOffice has no hyperlink tooltips (F-058): leave out `tooltip`."))
    rows, cols = _link_block(ref)
    _delete_links!(ws, rows, cols)
    href = _link_href(get_odsfile(ws), url, location)
    r1, c1 = first(rows), first(cols)
    blocks = FormatBlock[]
    if _field_cell(cell_data(_cached_store(ws), r1, c1))
        d = cell_data(_cached_store(ws), r1, c1)
        text = d === nothing || d.kind === CK_EMPTY ? something(display, target) : d.text
        _set_link_field!(ws, r1, c1, text, href)
        length(cols) > 1 && push!(blocks, _cellblock(r1:r1, c1+1:last(cols)))
        length(rows) > 1 && push!(blocks, _cellblock(r1+1:last(rows), cols))
    else
        push!(blocks, _cellblock(rows, cols))
    end
    _set_cell_links!(ws, blocks, href)
    return first(_cell_links(ws, r1, c1))
end
addHyperlink(ws::Worksheet, row::Integer, col::Integer; kw...) = addHyperlink(ws, CellRef(row, col); kw...)

# Removes every link of the cells rows × cols; whether there was one.
function _delete_links!(ws::Worksheet, rows::UnitRange{Int}, cols::UnitRange{Int})
    s = _cached_store(ws)
    st = get_odsfile(ws).styles
    found = false
    styled = FormatBlock[]
    for r in rows, c in cols
        d = cell_data(s, r, c)
        if d !== nothing && (d.flags & F_RICH) != 0
            new = CellData(CK_STRING, d.flags & ~F_RICH, d.style, UInt64(0), d.text, nothing, d.colspan, d.rowspan)
            store_set!(s, r, c, new); _after_cell_edit!(ws, r, c, d, new); _mark_dirty!(ws, r, c)
            found = true
        else
            run = _file_link_at(ws, r, c)
            if run !== nothing && _fields_kept(d, run)
                new = CellData(d.kind, d.flags | F_PLAIN, d.style, d.bits, d.text, d.formula, d.colspan, d.rowspan)
                store_set!(s, r, c, new); _after_cell_edit!(ws, r, c, d, new); _mark_dirty!(ws, r, c)
                found = true
            end
        end
        if _style_link(st, effective_style(ws, r, c)) !== nothing
            push!(styled, _cellblock(r:r, c:c))
            found = true
        end
    end
    _set_cell_links!(ws, styled, nothing)
    return found
end

"""
    deleteHyperlink(sheet, ref) -> Bool
    deleteHyperlink(sheet, row, col) -> Bool

Remove the links of a cell, or of every cell of a range: its URL fields (the text stays) and
its cell link. Returns whether there was one. The file must be writable.
"""
function deleteHyperlink(ws::Worksheet, ref::Union{AbstractString,CellRef,CellRange})
    _require_writable(ws, "delete a hyperlink")
    rows, cols = _link_block(ref)
    return _delete_links!(ws, rows, cols)
end
deleteHyperlink(ws::Worksheet, row::Integer, col::Integer) = deleteHyperlink(ws, CellRef(row, col))

"""
    getHyperlink(sheet, ref) -> Union{Nothing, NamedTuple}
    getHyperlink(sheet, row, col) -> Union{Nothing, NamedTuple}

The hyperlink of a cell, as `(sheet, ref, url, location, display, tooltip)`, or `nothing`:
its first URL field, else its cell link (F-058). `url` is set for a link outside the workbook
(a file relative to the document's folder as such), `location` for a place in it, in
LibreOffice's notation (`Sheet2.A1`). `display` is a URL field's text (`nothing` for a cell
link), and `tooltip` is always `nothing`: LibreOffice has none.
"""
function getHyperlink(ws::Worksheet, ref::Union{AbstractString,CellRef})
    rows, cols = _link_block(ref)
    (length(rows) == 1 && length(cols) == 1) ||
        throw(ODSError("`getHyperlink` reads one cell, not a range: `$ref`. Use `getHyperlinks` for every link."))
    v = _cell_links(ws, first(rows), first(cols))
    return isempty(v) ? nothing : first(v)
end
getHyperlink(ws::Worksheet, row::Integer, col::Integer) = getHyperlink(ws, CellRef(row, col))

"""
    getHyperlinks(sheet) -> Vector{NamedTuple}
    getHyperlinks(xf::ODSFile) -> Vector{NamedTuple}

Every hyperlink of a sheet, or of every sheet, by row and then column: each URL field of a
cell, then its cell link, as [`getHyperlink`](@ref) gives them.
"""
function getHyperlinks(ws::Worksheet)
    st = get_odsfile(ws).styles
    linkstyle = Dict{Int32,Bool}()
    haslink(id) = get!(() -> _style_link(st, id) !== nothing, linkstyle, id)
    cells = Set{Tuple{Int,Int}}()
    function scan(rows::Vector{RowData}, fields::Bool)
        for rd in rows, run in rd.runs
            d = run.data
            (haslink(d.style) || (fields && (d.flags & F_RICH) != 0)) || continue
            for r in rd.row:rd.row+rd.count-1, c in run.col:run.col+run.count-1
                push!(cells, (Int(r), Int(c)))
            end
        end
    end
    scan(_cached_store(ws).rows, true)
    if !(isnewsheet(ws) && ws.formats === nothing)
        f = sheet_formats(ws)
        scan(f.cells, false)
        # cells whose column or row default has a link (LibreOffice moves a column's common style
        # there): the cells each row element has (`ncells`), but not the sheet's tail of rows
        for rf in f.rows
            last = Int(rf.row) + Int(rf.count) - 1
            last >= SheetCore.MAX_ROWS && continue
            for cf in f.cols
                (cf.default >= 0 && haslink(cf.default)) || continue
                for r in Int(rf.row):last, c in Int(cf.col):min(Int(cf.col) + Int(cf.count) - 1, Int(rf.ncells))
                    push!(cells, (r, c))
                end
            end
            if rf.default >= 0 && haslink(rf.default)
                for r in Int(rf.row):last, c in 1:Int(rf.ncells)
                    push!(cells, (r, c))
                end
            end
        end
    end
    for run in _file_links(ws)
        for o in run.row:run.row+run.nrows-1
            r = _current_line(ws.rowmap, o)
            r == 0 && continue
            for p in run.col:run.col+run.ncols-1
                c = _current_line(ws.colmap, p)
                c == 0 || push!(cells, (r, c))
            end
        end
    end
    out = HyperlinkInfo[]
    for (r, c) in sort!(collect(cells))
        append!(out, _cell_links(ws, r, c))
    end
    return out
end
getHyperlinks(xf::ODSFile) = reduce(vcat, (getHyperlinks(ws) for ws in _sheets(xf)); init = HyperlinkInfo[])

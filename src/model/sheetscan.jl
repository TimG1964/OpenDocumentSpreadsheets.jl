#=
The byte scanner (D-047): a sheet's rows read straight from the bytes of its
`table:table` element, for the `SheetReader` (the cache, uncached reads, `eachrow`).

Read with an `XML.Cursor`, most of a sheet's time goes on XML.jl's general tokenizer: a
token per tag, attribute and text, each ready for anything XML allows. The scanner reads
the few shapes a sheet's rows are made of, a byte at a time, into the same `RowData`, with
the same decoders (`_cell_value`, `_with_text`, `_store_cell!`, `_push_column!`). The
idea, and its split between a narrow fast path and XML.jl for the rest, follow XLSX.jl's
unreleased `src/valuescan.jl` (XLSX-Cursor), MIT License, Copyright (c) 2018-2026 Felipe
Noronha Tavares and other contributors; the code is written for ODF's markup.

It is a second parser, kept narrow so that it never decides what unusual XML means:
  - XML.jl still finds the sheet (`index_body`). The scanner starts at the sheet's first
    child, located through `XML.sourcetext` of that child (`parent`/`parentindices`
    give the document and the offset), so it never scans the sheet twice. The text is
    the one XML.jl holds, already rewritten by any DOCTYPE.
  - Elements are told apart by their qualified names, as the cursor walk compares them.
    Text between elements, comments and processing instructions are skipped, as the
    cursor walk skips them. End tags aren't matched against start tags, as XML.jl's lazy
    reader doesn't match them.
  - Attribute values are taken as written, or through `XML.unescape` when they hold a
    reference, which is what XML.jl reports for them (F-042). A wanted cell attribute
    with a tab or line end (which XML.jl normalizes) sends the cell to XML.jl.
  - The fast path takes a cell whose paragraphs (`text:p`, `text:h`) hold only text,
    unescaped as above. Any other paragraph content (`text:s`, spans, links, comments,
    CDATA) sends the cell to XML.jl: its text is parsed on its own and read by the
    cursor walk's own code (`_read_cell!`). Other elements in a cell (annotations,
    frames) are skipped, as the cursor walk skips them.
  - Anything the scanner can't step over (a tag cut off by the end of the text, a
    missing quote or `=`, a `<!` that isn't a comment or CDATA, an odd row or column
    attribute) throws `_ScanFallback`. The reader then goes on with the cursor walk from
    the row where the scan stopped (`_scan_to_cursor!`), so nothing is read twice and
    whatever the cursor walk does with such XML, errors included, still happens.

Keeping the two in step: test/model/test_sheetscan.jl compares the scanner with the
cursor walk on every test file and on sheets written in each shape above. Set
`_SCAN[] = false` to read with the cursor only; or delete this file, its include, the
`scan` branch of `next_row!` and the scanner fields of `SheetReader`.
=#

# Rows are read with the byte scanner; `false` reads them with the XML.jl cursor walk.
const _SCAN = Ref(true)

# Thrown by the scanner for markup it can't step over (see above).
struct _ScanFallback <: Exception end

# Cells the scanner has handed to XML.jl, for the tests.
const _SCAN_CELL_FALLBACKS = Threads.Atomic{Int}(0)

@inline _sbyte(s::String, i::Int) = 1 <= i <= ncodeunits(s) ? (@inbounds codeunit(s, i)) : 0x00
@inline _is_space(b::UInt8) = b == 0x20 || b == 0x0a || b == 0x09 || b == 0x0d

# The index of the next byte `b` from `i`, or 0.
@inline function _sfind(s::String, b::UInt8, i::Int)
    i < 1 && (i = 1)
    i > ncodeunits(s) && return 0
    return something(findnext(==(b), codeunits(s), i), 0)    # memchr
end

# The index after the next run of spaces from `i`.
@inline function _sskip_spaces(s::String, i::Int)
    while _is_space(_sbyte(s, i))
        i += 1
    end
    return i
end

# Whether `range` of `s` holds `lit`.
@inline function _seq(s::String, range::UnitRange{Int}, lit::String)
    length(range) == ncodeunits(lit) || return false
    k = 1
    @inbounds for i in range
        codeunit(s, i) == codeunit(lit, k) || return false
        k += 1
    end
    return true
end

# Whether `s` has `lit` at `i`.
@inline function _sat(s::String, i::Int, lit::String)
    i + ncodeunits(lit) - 1 <= ncodeunits(s) || return false
    return _seq(s, i:i+ncodeunits(lit)-1, lit)
end

# The index after the next `lit` from `i` (a terminator: `-->`, `?>`, `]]>`).
function _safter(s::String, lit::String, i::Int)
    b = codeunit(lit, 1)
    while true
        i = _sfind(s, b, i)
        i == 0 && throw(_ScanFallback())
        _sat(s, i, lit) && return i + ncodeunits(lit)
        i += 1
    end
end

# At a `<` that starts a comment, a processing instruction or CDATA: the index after it.
# Anything else beginning `<!` (a DOCTYPE) throws.
function _sskip_special(s::String, i::Int)
    b = _sbyte(s, i + 1)
    if b == UInt8('?')
        return _safter(s, "?>", i + 2)
    elseif _sat(s, i, "<!--")
        return _safter(s, "-->", i + 4)
    elseif _sat(s, i, "<![CDATA[")
        return _safter(s, "]]>", i + 9)
    end
    throw(_ScanFallback())
end

# Reads the start tag at `i` (`s[i]` is `<`, not followed by `/`, `!` or `?`), recording
# its attributes' name and value ranges in `attrs`. Returns (name, stop, empty): the
# name's range, the index of its `>`, and whether it ends `/>`.
function _stag!(attrs::Vector{NTuple{2,UnitRange{Int}}}, s::String, i::Int)
    n = ncodeunits(s)
    j = i + 1
    while j <= n
        b = @inbounds codeunit(s, j)
        (_is_space(b) || b == UInt8('>') || b == UInt8('/')) && break
        j += 1
    end
    j == i + 1 && throw(_ScanFallback())
    name = i+1:j-1
    empty!(attrs)
    while true
        j = _sskip_spaces(s, j)
        j > n && throw(_ScanFallback())
        b = @inbounds codeunit(s, j)
        if b == UInt8('>')
            return name, j, false
        elseif b == UInt8('/')
            _sbyte(s, j + 1) == UInt8('>') || throw(_ScanFallback())
            return name, j + 1, true
        end
        k = j
        while k <= n
            b = @inbounds codeunit(s, k)
            (b == UInt8('=') || _is_space(b) || b == UInt8('>') || b == UInt8('/')) && break
            k += 1
        end
        aname = j:k-1
        k = _sskip_spaces(s, k)
        _sbyte(s, k) == UInt8('=') || throw(_ScanFallback())
        k = _sskip_spaces(s, k + 1)
        q = _sbyte(s, k)
        (q == UInt8('"') || q == UInt8('\'')) || throw(_ScanFallback())
        e = _sfind(s, q, k + 1)
        e == 0 && throw(_ScanFallback())
        push!(attrs, (aname, k+1:e-1))
        j = e + 1
    end
end

# The end of the start tag at `i`, stepping over quoted values: (index of `>`, empty).
function _stag_end(s::String, i::Int)
    n = ncodeunits(s)
    j = i + 1
    while j <= n
        b = @inbounds codeunit(s, j)
        if b == UInt8('"') || b == UInt8('\'')
            j = _sfind(s, b, j + 1)
            j == 0 && throw(_ScanFallback())
        elseif b == UInt8('>')
            return j, _sbyte(s, j - 1) == UInt8('/')
        elseif b == UInt8('<')
            throw(_ScanFallback())
        end
        j += 1
    end
    throw(_ScanFallback())
end

# After the start tag of an element (at `j`): the index after its end tag.
function _sskip_content(s::String, j::Int)
    depth = 1
    while true
        j = _sfind(s, UInt8('<'), j)
        j == 0 && throw(_ScanFallback())
        b = _sbyte(s, j + 1)
        if b == UInt8('/')
            e = _sfind(s, UInt8('>'), j)
            e == 0 && throw(_ScanFallback())
            j = e + 1
            depth -= 1
            depth == 0 && return j
        elseif b == UInt8('!') || b == UInt8('?')
            j = _sskip_special(s, j)
        else
            stop, empty = _stag_end(s, j)
            empty || (depth += 1)
            j = stop + 1
        end
    end
end

# The element starting at `i`: the index after it.
function _sskip_element(s::String, i::Int)
    stop, empty = _stag_end(s, i)
    return empty ? stop + 1 : _sskip_content(s, stop + 1)
end

# Returned by `_sattr` for a value XML.jl would normalize: a sentinel compared with `===`,
# not `nothing`, so that the result is never boxed.
const _NEEDS_XML = SubString(String(UInt8[0x00]), 1, 1)

# An attribute value as XML.jl reports it (F-042), or `_NEEDS_XML` when XML.jl would
# normalize its white space (a tab or line end).
@inline function _sattr(s::String, range::UnitRange{Int})
    isempty(range) && return SubString(s, first(range), last(range))
    # one pass without an early exit; the rare values it flags are looked at again
    special = false
    @inbounds for i in range
        b = codeunit(s, i)
        special |= (b == UInt8('&')) | (b == 0x09) | (b == 0x0a) | (b == 0x0d)
    end
    v = SubString(s, first(range), prevind(s, last(range) + 1))
    special || return v
    @inbounds for i in range
        b = codeunit(s, i)
        (b == 0x09 || b == 0x0a || b == 0x0d) && return _NEEDS_XML
    end
    return SubString(XML.unescape(v))
end

# A row or column attribute: one XML.jl would normalize throws.
function _sattr_or_throw_value(s::String, range::UnitRange{Int})
    v = _sattr(s, range)
    v === _NEEDS_XML && throw(_ScanFallback())
    return v
end

# A cell attribute's value; one XML.jl would normalize returns `_FALLBACK_ATTRS` from the
# enclosing function.
macro _cell_attr(s, av)
    quote
        v = _sattr($(esc(s)), $(esc(av)))
        v === _NEEDS_XML && return _FALLBACK_ATTRS
        v
    end
end

#
# The reader's scan mode
#

# Starts scanning at the sheet's first child; a sheet without children is done at once.
# Called by the `SheetReader` constructor, its cursor on the `table:table`.
function _scan_start!(r::SheetReader)
    c = XML.Cursor(r.node)
    XML.next!(c)                          # table:table
    if XML.next!(c) === nothing || XML.depth(c) <= 1
        r.done = true                     # as the cursor walk finds it
        return
    end
    t = XML.sourcetext(XML.LazyNode(c))   # the first child only
    r.src = parent(t)
    r.pos = first(parentindices(t)[1])
    r.depth = 0
    r.scan = true
    return
end

# Leaves scan mode after a `_ScanFallback`: the cursor walk reads on from row `mark`, the
# first row the failed call had not finished. Its columns are read again, and the merges
# of that call are dropped (the cursor walk records them again).
function _scan_to_cursor!(r::SheetReader, mark::Int, nmerges::Int)
    r.scan = false
    r.c = XML.Cursor(r.node)
    XML.next!(r.c)                        # on table:table, as the constructor leaves it
    empty!(r.cols)
    resize!(r.merges, nmerges)
    r.nextrow = 1
    r.skip_before = max(r.skip_before, mark)
    r.done = false
    return
end

const _SROW = "table:table-row"
const _SCOL = "table:table-column"
const _SCELL = "table:table-cell"
const _SCOVERED = "table:covered-table-cell"

@inline _sname_in(s::String, name::UnitRange{Int}, lits) = any(l -> _seq(s, name, l), lits)

# The next row with content, as `next_row!` gives it.
function _scan_next_row!(r::SheetReader)
    s = r.src
    while true
        j = _sfind(s, UInt8('<'), r.pos)
        j == 0 && throw(_ScanFallback())          # no end to the sheet
        b = _sbyte(s, j + 1)
        if b == UInt8('/')
            e = _sfind(s, UInt8('>'), j)
            e == 0 && throw(_ScanFallback())
            r.pos = e + 1
            if r.depth == 0                       # </table:table>
                r.done = true
                return nothing
            end
            r.depth -= 1                          # the end of a row or column container
            continue
        elseif b == UInt8('!') || b == UInt8('?')
            r.pos = _sskip_special(s, j)
            continue
        end
        name, stop, empty = _stag!(r.attrs, s, j)
        if _seq(s, name, _SROW)
            row = _scan_row!(r, s, stop, empty)
            row === nothing || return row
            r.done && return nothing
        elseif _seq(s, name, _SCOL)
            _scan_column!(r, s)
            r.pos = empty ? stop + 1 : _sskip_content(s, stop + 1)
        elseif _sname_in(s, name, _ROW_CONTAINERS) || _sname_in(s, name, _COL_CONTAINERS)
            empty || (r.depth += 1)               # descend
            r.pos = stop + 1
        else
            r.pos = empty ? stop + 1 : _sskip_content(s, stop + 1)
        end
    end
end

function _scan_column!(r::SheetReader, s::String)
    count = 1; ds = Int32(-1); visible = true
    for (an, av) in r.attrs
        if _seq(s, an, "table:number-columns-repeated")
            count = _file_count(_sattr_or_throw_value(s, av), 1, 1, SheetCore.MAX_COLS)     # 0 or less: one (F-092)
        elseif _seq(s, an, "table:default-cell-style-name")
            ds = style_id(r.styles, _sattr_or_throw_value(s, av))
        elseif _seq(s, an, "table:visibility")
            visible = _sattr_or_throw_value(s, av) == "visible"
        end
    end
    _push_column!(r, count, ds, visible)
    return
end

# The row whose start tag ends at `stop`; sets `r.pos` after it.
function _scan_row!(r::SheetReader, s::String, stop::Int, empty::Bool)
    count = 1; rowdefault = Int32(-1)
    for (an, av) in r.attrs
        if _seq(s, an, "table:number-rows-repeated")
            count = _file_count(_sattr_or_throw_value(s, av), 1, 1, SheetCore.MAX_ROWS)
        elseif _seq(s, an, "table:default-cell-style-name")
            rowdefault = style_id(r.styles, _sattr_or_throw_value(s, av))
        end
    end
    rowno, count, read = _row_span!(r, count)
    r.done && return nothing
    if !read || empty
        r.pos = empty ? stop + 1 : _sskip_content(s, stop + 1)
        return nothing
    end
    runs = r.runs
    empty!(runs)
    col = 1
    j = stop + 1
    while true
        j = _sfind(s, UInt8('<'), j)
        j == 0 && throw(_ScanFallback())
        b = _sbyte(s, j + 1)
        if b == UInt8('/')                        # </table:table-row>
            e = _sfind(s, UInt8('>'), j)
            e == 0 && throw(_ScanFallback())
            j = e + 1
            break
        elseif b == UInt8('!') || b == UInt8('?')
            j = _sskip_special(s, j)
            continue
        end
        name, cstop, cempty = _stag!(r.attrs, s, j)
        if _seq(s, name, _SCELL)
            col, j = _scan_cell!(r, s, j, cstop, cempty, rowno, col, rowdefault, false)
        elseif _seq(s, name, _SCOVERED)
            col, j = _scan_cell!(r, s, j, cstop, cempty, rowno, col, rowdefault, true)
        else
            j = cempty ? cstop + 1 : _sskip_content(s, cstop + 1)
        end
    end
    r.pos = j
    isempty(runs) && return nothing
    return RowData(rowno, count, copy(runs))
end

# The cell whose start tag is at `start` and ends at `stop`: (the column after it, the
# index after it).
function _scan_cell!(r::SheetReader, s::String, start::Int, stop::Int, empty::Bool,
                     rowno::Int, col::Int, rowdefault::Int32, covered::Bool)
    a = _scan_cell_attrs(r, s)
    a.count < 0 && return _scan_cell_fallback(r, s, start, rowno, col, rowdefault, covered)
    count = min(a.count, SheetCore.MAX_COLS - col + 1)
    count <= 0 && return col, (empty ? stop + 1 : _sskip_content(s, stop + 1))
    kind, flags, bits, text, needs_text = _cell_value(a, covered)
    if needs_text
        if empty
            t = nothing; j = stop + 1
        else
            t, j = _scan_cell_text!(r, s, stop + 1)
            j == 0 && return _scan_cell_fallback(r, s, start, rowno, col, rowdefault, covered)
        end
        kind, text = _with_text(kind, text, t)
    else
        j = empty ? stop + 1 : _sskip_content(s, stop + 1)
    end
    return _store_cell!(r, a, rowno, col, count, rowdefault, kind, flags, bits, text), j
end

# The cell's attributes, as `_cursor_cell_attrs` reads them; `_FALLBACK_ATTRS` when one of
# them needs XML.jl's white-space normalization (a sentinel, not `nothing`, so that the
# result is never boxed).
const _FALLBACK_ATTRS = CellAttrs(-1, Int32(-1), _NO_ATTR, _NO_ATTR, _NO_ATTR, _NO_ATTR, _NO_ATTR, _NO_ATTR,
                                  nothing, nothing, nothing, 1, 1)

function _scan_cell_attrs(r::SheetReader, s::String)
    count = 1
    style = Int32(-1)
    vtype = _NO_ATTR; cvtype = _NO_ATTR
    value = _NO_ATTR; datev = _NO_ATTR; timev = _NO_ATTR; boolv = _NO_ATTR
    strv = nothing; currency = nothing
    formula = nothing
    colspan = 1; rowspan = 1
    for (an, av) in r.attrs
        if _seq(s, an, "office:value-type")
            vtype = @_cell_attr(s, av)
        elseif _seq(s, an, "calcext:value-type")
            cvtype = @_cell_attr(s, av)
        elseif _seq(s, an, "office:value")
            value = @_cell_attr(s, av)
        elseif _seq(s, an, "table:style-name")
            style = style_id(r.styles, @_cell_attr(s, av))
        elseif _seq(s, an, "table:number-columns-repeated")
            count = _file_count(@_cell_attr(s, av), 1, 1, SheetCore.MAX_COLS)
        elseif _seq(s, an, "table:formula")
            formula = String(@_cell_attr(s, av))
        elseif _seq(s, an, "office:date-value")
            datev = @_cell_attr(s, av)
        elseif _seq(s, an, "office:time-value")
            timev = @_cell_attr(s, av)
        elseif _seq(s, an, "office:boolean-value")
            boolv = @_cell_attr(s, av)
        elseif _seq(s, an, "office:string-value")
            strv = String(@_cell_attr(s, av))
        elseif _seq(s, an, "office:currency")
            currency = String(@_cell_attr(s, av))
        elseif _seq(s, an, "table:number-columns-spanned")
            colspan = _file_count(@_cell_attr(s, av), 1, 1, SheetCore.MAX_COLS + 1)
        elseif _seq(s, an, "table:number-rows-spanned")
            rowspan = _file_count(@_cell_attr(s, av), 1, 1, SheetCore.MAX_ROWS + 1)
        end
    end
    return CellAttrs(count, style, vtype, cvtype, value, datev, timev, boolv, strv, currency, formula, colspan, rowspan)
end

# The text of the cell's paragraphs, as `_cell_text!` reads it, from `j` (after the cell's
# start tag): (text or `nothing`, the index after the cell), or (nothing, 0) when a
# paragraph holds more than text.
function _scan_cell_text!(r::SheetReader, s::String, j::Int)
    buf = r.text
    truncate(buf, 0)
    nparas = 0
    while true
        j = _sfind(s, UInt8('<'), j)
        j == 0 && throw(_ScanFallback())
        b = _sbyte(s, j + 1)
        if b == UInt8('/')                        # </table:table-cell>
            e = _sfind(s, UInt8('>'), j)
            e == 0 && throw(_ScanFallback())
            return _paragraphs_text(buf, nparas), e + 1
        elseif b == UInt8('!') || b == UInt8('?')
            j = _sskip_special(s, j)
            continue
        end
        name, stop, empty = _stag!(r.attrs, s, j)
        if _seq(s, name, "text:p") || _seq(s, name, "text:h")
            nparas > 0 && write(buf, '\n')
            nparas += 1
            if empty
                j = stop + 1
                continue
            end
            k = _sfind(s, UInt8('<'), stop + 1)
            k == 0 && throw(_ScanFallback())
            _sbyte(s, k + 1) == UInt8('/') || return nothing, 0   # markup inside: XML.jl
            if k > stop + 1
                amp = false
                @inbounds for i in stop+1:k-1
                    amp |= codeunit(s, i) == UInt8('&')
                end
                t = SubString(s, stop + 1, prevind(s, k))
                amp ? write(buf, XML.unescape(t)) : write(buf, t)
            end
            e = _sfind(s, UInt8('>'), k)
            e == 0 && throw(_ScanFallback())
            j = e + 1
        else
            j = empty ? stop + 1 : _sskip_content(s, stop + 1)   # annotations, frames, ...
        end
    end
end

# The cell at `start`, read by XML.jl: its text is parsed on its own and read by the cursor
# walk's `_read_cell!`. Returns (the column after it, the index after it).
function _scan_cell_fallback(r::SheetReader, s::String, start::Int, rowno::Int,
                             col::Int, rowdefault::Int32, covered::Bool)
    e = _sskip_element(s, start)
    Threads.atomic_add!(_SCAN_CELL_FALLBACKS, 1)
    c = XML.Cursor(String(SubString(s, start, prevind(s, e))))
    XML.next!(c)
    return _read_cell!(r, c, rowno, col, rowdefault, covered), e
end

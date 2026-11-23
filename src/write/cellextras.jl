# What an edited cell keeps of the original (D-071).
#
# A patched save writes an edited cell from the model, which holds the cell's value, formula
# and style only. What else the original cell held is kept, as LibreOffice keeps it when a
# cell's value changes (F-058, F-059, F-060):
#   - its validation (`table:content-validation-name`), on every column of the cell
#   - its annotation, and the other children before its text (`_LEAD_CHILDREN`)
#   - the shapes anchored in it, and the other children after its text
#   - its paragraphs as written (links, spans, fields), while the model's text is the original's;
#     a new text drops them, as LibreOffice drops a cell's URL fields with its old text
# The cell's attribute order is LibreOffice's: `table:style-name`, the validation, then the
# rest; its children's order: the annotation, the paragraphs, the shapes (experiment 031 part C).

# Children that LibreOffice writes before a cell's paragraphs.
const _LEAD_CHILDREN = ("office:annotation", "table:cell-range-source", "table:detective")

# Whether `s`, after index `i`, starts with the tag name `name` (followed by the end of the name).
function _tag_at(s::AbstractString, i::Int, name::String)
    j = i
    for b in codeunits(name)
        (j > ncodeunits(s) || codeunit(s, j) != b) && return false
        j += 1
    end
    j > ncodeunits(s) && return false
    c = codeunit(s, j)
    return c == UInt8('>') || c == UInt8('/') || c == UInt8(' ') || c == UInt8('\t') || c == UInt8('\n') || c == UInt8('\r')
end

# Tags a paragraph may hold that the model's text writes back the same (spaces, tabs, line ends).
_plain_para_tag(s::AbstractString, i::Int) =
    _tag_at(s, i, "text:s") || _tag_at(s, i, "text:tab") || _tag_at(s, i, "text:line-break")

# The next index of the ASCII character `c` in `s` from `i`, or `nothing`. For a SubString of a
# String the parent is searched (memchr), as far as the next hit.
function _next_ascii(c::Char, s::SubString{String}, i::Int)
    off = first(parentindices(s)[1]) - 1
    j = findnext(c, parent(s), off + i)
    return j === nothing || j > off + ncodeunits(s) ? nothing : j - off
end
_next_ascii(c::Char, s::AbstractString, i::Int) = findnext(c, s, i)

# Whether `s` holds `table:content-validation-name` before index `e` (as `validation-name`, found
# by its `v`s).
function _has_validation(s::AbstractString, e::Int = ncodeunits(s))
    i = 1
    while (j = _next_ascii('v', s, i)) !== nothing && j < e
        j + 14 <= ncodeunits(s) && _bytes_at(s, j, "validation-name") && return true
        i = j + 1
    end
    return false
end

function _bytes_at(s::AbstractString, i::Int, name::String)
    for (k, b) in enumerate(codeunits(name))
        codeunit(s, i + k - 1) == b || return false
    end
    return true
end

# Whether the elements in `s` from index `i` on are only paragraphs (`text:p`, `text:h`) of plain
# text, and end tags of the cell. The quick test that leaves most cells on the plain path.
function _only_plain_text(s::AbstractString, i::Int)
    while (j = _next_ascii('<', s, i)) !== nothing
        k = j + 1
        if k <= ncodeunits(s) && codeunit(s, k) == UInt8('/')
            k += 1
            (_tag_at(s, k, "text:p") || _tag_at(s, k, "text:h") || _tag_at(s, k, "table:table-cell") ||
             _tag_at(s, k, "table:covered-table-cell")) || return false
        else
            (_tag_at(s, k, "text:p") || _tag_at(s, k, "text:h") || _plain_para_tag(s, k)) || return false
        end
        i = k
    end
    return true
end

# Whether an original cell may hold something besides its value (the quick test, on every cell
# a patched save rewrites; ~40 ns). The start tag ends at the first `>`: LibreOffice and this
# package write `>` in attribute values as `&gt;` (a raw `>` before the validation's name, from
# another producer, would lose the validation as before D-071).
function _maybe_extras(celltext::AbstractString)
    e = _next_ascii('>', celltext, 1)
    e === nothing && return false
    _has_validation(celltext, e) && return true
    codeunit(celltext, e - 1) == UInt8('/') && return false              # <table:table-cell …/>
    return !_only_plain_text(celltext, e + 1)
end

struct _CellExtras
    validation::String                       # ` table:content-validation-name="…"` as written, or ""
    lead::Vector{SubString{String}}          # children before the paragraphs
    tail::Vector{SubString{String}}          # children after them
    paras::Union{Nothing,SubString{String}}  # the paragraphs, first to last, when they hold markup
    text::Union{Nothing,String}              # the paragraphs' text (as the reader reads it)
    single::Bool                             # the original is one cell (not repeated)
end

_has_children(ex::_CellExtras) = !isempty(ex.lead) || !isempty(ex.tail) || ex.paras !== nothing

# The extras of the original cell `cell` (its text `celltext`, in `src`), or `nothing` if it has
# none. Call it only when `_maybe_extras(celltext)`.
function _cell_extras(src::String, cell::XML.LazyNode, celltext::SubString{String})
    val = ""
    for (k, v) in _raw_attrs(celltext)
        k == "table:content-validation-name" && (val = string(' ', k, '=', v))
    end
    single = _attr_int(celltext, "table:number-columns-repeated", 1) <= 1
    lead = SubString{String}[]
    tail = SubString{String}[]
    pfirst = 0; plast = 0
    markup = false
    buf = IOBuffer()
    nparas = 0
    c = XML.Cursor(cell)
    XML.next!(c)
    XML.for_each_child!(c) do ch
        XML.nodetype(ch) === XML.Element || return
        sp = XML.sourcespan(XML.LazyNode(ch))
        s = SubString(src, first(sp), last(sp))
        t = XML.tag(ch)
        if t == "text:p" || t == "text:h"
            pfirst == 0 && (pfirst = first(sp))
            plast = last(sp)
            e = _start_tag_end(s)
            markup |= codeunit(s, prevind(s, e)) != UInt8('/') && !_only_plain_text(s, nextind(s, e))
            nparas > 0 && write(buf, '\n')
            nparas += 1
            _para_text!(buf, ch)
        else
            push!(t in _LEAD_CHILDREN ? lead : tail, s)
            XML.skip_element!(ch)
        end
    end
    paras = nothing
    text = nothing
    if markup && single
        inside(x) = pfirst <= first(_span(x)) <= plast
        # paragraphs interleaved with other children are not kept as one piece
        if !any(inside, lead) && !any(inside, tail)
            paras = SubString(src, pfirst, plast)
            text = _paragraphs_text(buf, nparas)
        end
    end
    isempty(val) && isempty(lead) && isempty(tail) && paras === nothing && return nothing
    return _CellExtras(val, lead, tail, paras, text, single)
end

const _CELL_START_RX = r"<table:(?:covered-)?table-cell(?: table:style-name=\"[^\"]*\")?"

# Cells written from the model (`frag`), each given the validation attribute `val`.
_with_validation(frag::String, val::String) = replace(frag, _CELL_START_RX => m -> m * val)

# One cell written from the model (`frag`), with the original's children: the leading ones, the
# model's paragraphs (or the original's, when the text is the same: `keep`), the trailing ones.
# Original text goes through `_emit` (references replayed, phase 5) as the cell's at `row`, `col`.
function _emit_with_children(st, frag::String, ex::_CellExtras, keep::Bool; row::Int, col::Int)
    out = st.out
    e = _start_tag_end(frag)
    selfclosing = codeunit(frag, prevind(frag, e)) == UInt8('/')
    covered = startswith(frag, "<table:covered-table-cell")
    endtag = covered ? "</table:covered-table-cell>" : "</table:table-cell>"
    if selfclosing
        print(out, SubString(frag, 1, prevind(frag, prevind(frag, e))), '>')
    else
        print(out, SubString(frag, 1, e))
    end
    for s in ex.lead
        _emit(st, s; row, col, orig = _span(s))
    end
    if keep
        _emit(st, ex.paras; row, col, orig = _span(ex.paras))
    elseif !selfclosing
        print(out, SubString(frag, nextind(frag, e), ncodeunits(frag) - ncodeunits(endtag)))
    end
    for s in ex.tail
        _emit(st, s; row, col, orig = _span(s))
    end
    print(out, endtag)
    return
end

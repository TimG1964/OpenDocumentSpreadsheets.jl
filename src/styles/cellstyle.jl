# The full properties of cell styles (phase 4).
#
# The read path needs only each cell style's data style (`StyleIndex`, model/styleindex.jl).
# Formatting needs everything else too: a `CellStyle` is the canonical, hashable form of a
# `style:style` of family `table-cell`. Its three property elements keep their attributes
# sorted by name, with values as written in the XML (escaped); their child elements, and the
# style's other children (`style:map`, …), are kept verbatim, so that a style derived from
# another loses nothing OpenDocumentSpreadsheets does not model.
#
# A `StyleSheet` holds the `CellStyle` of every style id, and is built from the document's
# XML the first time formatting needs it (stylesheet.jl), so plain reads and writes never
# pay for it (phase 3's speed).

"""
    PropSet(attrs, inner)

One property element of a style (`style:table-cell-properties`, `style:paragraph-properties`
or `style:text-properties`): its attributes, sorted by name, with values as written in the
XML; and its child elements, verbatim.
"""
struct PropSet
    attrs::Vector{Pair{String,String}}
    inner::String
end
PropSet() = PropSet(Pair{String,String}[], "")

Base.:(==)(a::PropSet, b::PropSet) = a.attrs == b.attrs && a.inner == b.inner
Base.hash(p::PropSet, h::UInt) = hash(p.inner, hash(p.attrs, hash(:PropSet, h)))
Base.isempty(p::PropSet) = isempty(p.attrs) && isempty(p.inner)

"""
    getprop(p::PropSet, name) -> Union{String, Nothing}

The value of attribute `name` as written in the XML, or `nothing`.
"""
function getprop(p::PropSet, name::AbstractString)
    for (k, v) in p.attrs
        k == name && return v
    end
    return nothing
end

"""
    setprops(p::PropSet, changes...) -> PropSet

`p` with each `name => value` of `changes` set (`value` as it is to be written in the XML,
already escaped), or removed when `value === nothing`.
"""
function setprops(p::PropSet, changes::Pair{<:AbstractString}...)
    d = Dict{String,String}(p.attrs)
    for (k, v) in changes
        v === nothing ? delete!(d, String(k)) : (d[String(k)] = String(v))
    end
    return PropSet(sort!(collect(d); by = first), p.inner)
end

"""
    CellStyle

A cell style's parent and data style names (`""` for none), its other attributes (sorted,
as written), its cell, paragraph and text properties, and its other children, verbatim.
Two `CellStyle`s are equal when they would be written the same, whatever their names.
"""
struct CellStyle
    parent::String
    datastyle::String
    attrs::Vector{Pair{String,String}}
    cell::PropSet
    para::PropSet
    text::PropSet
    extra::String
end
CellStyle(parent::AbstractString = "Default", datastyle::AbstractString = "") =
    CellStyle(String(parent), String(datastyle), Pair{String,String}[], PropSet(), PropSet(), PropSet(), "")

Base.:(==)(a::CellStyle, b::CellStyle) =
    a.parent == b.parent && a.datastyle == b.datastyle && a.attrs == b.attrs && a.cell == b.cell &&
    a.para == b.para && a.text == b.text && a.extra == b.extra
Base.hash(s::CellStyle, h::UInt) =
    hash(s.extra, hash(s.text, hash(s.para, hash(s.cell, hash(s.attrs, hash(s.datastyle, hash(s.parent, hash(:CellStyle, h))))))))

# Whether a style says nothing but its parent and data style (as OpenDocumentSpreadsheets's typed styles and
# LibreOffice's data-format-only styles do).
is_plain(s::CellStyle) = isempty(s.attrs) && isempty(s.cell) && isempty(s.para) && isempty(s.text) && isempty(s.extra)

with_datastyle(s::CellStyle, ds::AbstractString) = CellStyle(s.parent, String(ds), s.attrs, s.cell, s.para, s.text, s.extra)
with_cell(s::CellStyle, p::PropSet) = CellStyle(s.parent, s.datastyle, s.attrs, p, s.para, s.text, s.extra)
with_para(s::CellStyle, p::PropSet) = CellStyle(s.parent, s.datastyle, s.attrs, s.cell, p, s.text, s.extra)
with_text(s::CellStyle, p::PropSet) = CellStyle(s.parent, s.datastyle, s.attrs, s.cell, s.para, p, s.extra)

#
# Parsing
#

# An attribute value as written, from its quoted form: a single-quoted value's `"` becomes
# `&quot;`, so that every value can be written between double quotes.
function _attr_value(quoted::AbstractString)
    v = String(SubString(quoted, 2, prevind(quoted, lastindex(quoted))))
    return quoted[1] == '\'' ? replace(v, '"' => "&quot;") : v
end

# The attributes of the start tag at the beginning of `text`, as written.
_start_attrs(text::AbstractString) = [String(k) => _attr_value(v) for (k, v) in _raw_attrs(text)]

# The text between the start tag and the end tag of an element's source (`""` if self-closing).
function _inner_xml(text::AbstractString)
    e = _start_tag_end(text)
    text[prevind(text, e)] == '/' && return ""
    stop = findlast("</", text)
    stop === nothing && return ""
    return String(SubString(text, nextind(text, e), prevind(text, first(stop))))
end

const _PROP_TAGS = ("style:table-cell-properties", "style:paragraph-properties", "style:text-properties")
const _STYLE_OWN_ATTRS = ("style:name", "style:family", "style:parent-style-name", "style:data-style-name")

"""
    parse_cell_style(text) -> CellStyle

The `CellStyle` of a `style:style` element, given its source text.
"""
function parse_cell_style(text::AbstractString)
    parent = ""; ds = ""
    attrs = Pair{String,String}[]
    for (k, v) in _start_attrs(text)
        if k == "style:parent-style-name"
            parent = XML.unescape(v)                 # names are kept unescaped (and written escaped)
        elseif k == "style:data-style-name"
            ds = XML.unescape(v)
        elseif !(k in _STYLE_OWN_ATTRS)
            push!(attrs, k => v)
        end
    end
    sort!(attrs; by = first)
    props = [PropSet(), PropSet(), PropSet()]
    extra = IOBuffer()
    inner = _inner_xml(text)
    if !isempty(strip(inner))
        c = XML.Cursor(string("<x>", inner, "</x>"))
        XML.next!(c)
        XML.for_each_child!(c) do ch
            XML.nodetype(ch) === XML.Element || return
            ctext = XML.sourcetext(XML.LazyNode(ch))
            k = findfirst(==(XML.tag(ch)), _PROP_TAGS)
            if k === nothing
                print(extra, ctext)
            else
                props[k] = PropSet(sort!(_start_attrs(ctext); by = first), _inner_xml(ctext))
            end
            XML.skip_element!(ch)
        end
    end
    return CellStyle(parent, ds, attrs, props[1], props[2], props[3], String(take!(extra)))
end

#
# Writing
#

function _write_props(io::IO, tag::AbstractString, p::PropSet)
    isempty(p) && return
    print(io, '<', tag)
    for (k, v) in p.attrs
        print(io, ' ', k, "=\"", v, '"')
    end
    if isempty(p.inner)
        print(io, "/>")
    else
        print(io, '>', p.inner, "</", tag, '>')
    end
end

"""
    write_cell_style(io, name, s::CellStyle)

`s` as a `style:style` element named `name` (child elements in the schema's order: cell,
paragraph and text properties, then the rest).
"""
function write_cell_style(io::IO, name::AbstractString, s::CellStyle)
    print(io, "<style:style style:name=\""); _escape_attr(io, name); print(io, "\" style:family=\"table-cell\"")
    isempty(s.parent) || (print(io, " style:parent-style-name=\""); _escape_attr(io, s.parent); print(io, '"'))
    isempty(s.datastyle) || (print(io, " style:data-style-name=\""); _escape_attr(io, s.datastyle); print(io, '"'))
    for (k, v) in s.attrs
        print(io, ' ', k, "=\"", v, '"')
    end
    if is_plain(s)
        print(io, "/>")
        return
    end
    print(io, '>')
    _write_props(io, "style:table-cell-properties", s.cell)
    _write_props(io, "style:paragraph-properties", s.para)
    _write_props(io, "style:text-properties", s.text)
    print(io, s.extra, "</style:style>")
end

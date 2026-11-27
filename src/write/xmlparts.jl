# Small parts of a document (settings, page styles, header and footer regions) read as XML.jl trees
# rather than matched as text, so any quoting, attribute order, white space or entity is read as
# LibreOffice reads it, and a name may hold any character (Phase 2 of the code review, D-101). Their edits
# are splices of the original text at the elements' spans: everything else stays byte for byte.

"""
    _XElement

An element of an XML fragment, as `_xelements` lists it: its tag, its attributes (unescaped),
its depth (1 for the fragment's own elements), its span in the fragment, and the span of its
content (`nothing` for an empty element written `<…/>`).
"""
struct _XElement
    tag::String
    attrs::Dict{String,String}
    depth::Int
    span::UnitRange{Int}
    inner::Union{Nothing,UnitRange{Int}}
end

_xattr(e::_XElement, k::AbstractString) = get(e.attrs, k, nothing)

# Every element of the XML fragment `s` (any number of siblings and text), at any depth and in
# document order. Spans are byte ranges of `s`.
function _xelements(s::AbstractString)
    pre = "<_x>"
    w = string(pre, s, "</_x>")
    doc = parse(XML.LazyNode, w)
    root = first(c for c in XML.children(doc) if XML.nodetype(c) === XML.Element)
    out = _XElement[]
    shift = ncodeunits(pre)
    function walk(n, depth)
        for c in XML.children(n)
            XML.nodetype(c) === XML.Element || continue
            sp = XML.sourcespan(c)
            text = XML.sourcetext(c)
            e = _start_tag_end(text)
            a = first(sp) - shift
            # the content ends at the character before the end tag's `<` (by character: it may be
            # multi-byte, and a range must end on a character's first byte)
            inner = endswith(text, "/>") && e == ncodeunits(text) ? nothing :
                    (a + e):(prevind(w, first(sp) + first(findlast("</", text)) - 1) - shift)
            at = XML.attributes(c)
            attrs = at === nothing ? Dict{String,String}() : Dict{String,String}(String(k) => String(v) for (k, v) in at)
            push!(out, _XElement(String(XML.tag(c)), attrs, depth, a:(last(sp) - shift), inner))
            walk(c, depth + 1)
        end
    end
    walk(root, 1)
    return out
end

# The elements of `s` with `tag` whose attribute `k` is `v` (`k === nothing`: any), at `depth`
# (`nothing`: any), within `span` (`nothing`: anywhere).
function _xfind(s::AbstractString, tag::AbstractString, k = nothing, v = nothing; depth = nothing, within = nothing,
                elements = _xelements(s))
    return [e for e in elements if e.tag == tag && (k === nothing || _xattr(e, k) == v) &&
                                   (depth === nothing || e.depth == depth) &&
                                   (within === nothing || (first(e.span) >= first(within) && last(e.span) <= last(within)))]
end
_xfirst(s::AbstractString, tag::AbstractString, k = nothing, v = nothing; kw...) =
    (r = _xfind(s, tag, k, v; kw...); isempty(r) ? nothing : r[1])

# Where an element's end tag starts (for content added last), or nothing for an empty element.
_xend(e::_XElement) = e.inner === nothing ? nothing : last(e.inner) + 1

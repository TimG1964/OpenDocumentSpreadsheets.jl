# Namespace prefixes (D-067). OpenDocumentSpreadsheets matches elements and attributes by their written names
# (`table:table-cell`), in XML.jl, which doesn't resolve prefixes (F-042), and in its byte
# scanners. LibreOffice resolves names by URI (experiment 029, F-057): a file may bind
# ODF's namespaces to other prefixes, declare them on inner elements, or use a default
# namespace. Such a part is rewritten once, as it is read, into the usual prefixes. A part
# whose every declaration binds a usual prefix to its usual URI, as in every file of the
# test corpus, is used as it is: the check costs one vectorised search for `xmlns` over the
# text (about 0.6% of reading a file).

# The usual prefix of each namespace: LibreOffice's (the declarations of its own files), with
# `manifest`, `msoxl` and the other ODF namespaces it writes in some parts.
const _USUAL_NS = [
    "office" => "urn:oasis:names:tc:opendocument:xmlns:office:1.0",
    "ooo" => "http://openoffice.org/2004/office",
    "fo" => "urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0",
    "xlink" => "http://www.w3.org/1999/xlink",
    "config" => "urn:oasis:names:tc:opendocument:xmlns:config:1.0",
    "dc" => "http://purl.org/dc/elements/1.1/",
    "meta" => "urn:oasis:names:tc:opendocument:xmlns:meta:1.0",
    "style" => "urn:oasis:names:tc:opendocument:xmlns:style:1.0",
    "text" => "urn:oasis:names:tc:opendocument:xmlns:text:1.0",
    "rpt" => "http://openoffice.org/2005/report",
    "draw" => "urn:oasis:names:tc:opendocument:xmlns:drawing:1.0",
    "dr3d" => "urn:oasis:names:tc:opendocument:xmlns:dr3d:1.0",
    "svg" => "urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0",
    "chart" => "urn:oasis:names:tc:opendocument:xmlns:chart:1.0",
    "table" => "urn:oasis:names:tc:opendocument:xmlns:table:1.0",
    "number" => "urn:oasis:names:tc:opendocument:xmlns:datastyle:1.0",
    "ooow" => "http://openoffice.org/2004/writer",
    "oooc" => "http://openoffice.org/2004/calc",
    "field" => "urn:openoffice:names:experimental:ooo-ms-interop:xmlns:field:1.0",
    "of" => "urn:oasis:names:tc:opendocument:xmlns:of:1.2",
    "xforms" => "http://www.w3.org/2002/xforms",
    "tableooo" => "http://openoffice.org/2009/table",
    "calcext" => "urn:org:documentfoundation:names:experimental:calc:xmlns:calcext:1.0",
    "drawooo" => "http://openoffice.org/2010/draw",
    "chartooo" => "http://openoffice.org/2010/chart",
    "officeooo" => "http://openoffice.org/2009/office",
    "loext" => "urn:org:documentfoundation:names:experimental:office:xmlns:loext:1.0",
    "math" => "http://www.w3.org/1998/Math/MathML",
    "form" => "urn:oasis:names:tc:opendocument:xmlns:form:1.0",
    "script" => "urn:oasis:names:tc:opendocument:xmlns:script:1.0",
    "dom" => "http://www.w3.org/2001/xml-events",
    "formx" => "urn:openoffice:names:experimental:ooxml-odf-interop:xmlns:form:1.0",
    "xsd" => "http://www.w3.org/2001/XMLSchema",
    "xsi" => "http://www.w3.org/2001/XMLSchema-instance",
    "xhtml" => "http://www.w3.org/1999/xhtml",
    "grddl" => "http://www.w3.org/2003/g/data-view#",
    "css3t" => "http://www.w3.org/TR/css3-text/",
    "presentation" => "urn:oasis:names:tc:opendocument:xmlns:presentation:1.0",
    "smil" => "urn:oasis:names:tc:opendocument:xmlns:smil-compatible:1.0",
    "anim" => "urn:oasis:names:tc:opendocument:xmlns:animation:1.0",
    "db" => "urn:oasis:names:tc:opendocument:xmlns:database:1.0",
    "manifest" => "urn:oasis:names:tc:opendocument:xmlns:manifest:1.0",
    "msoxl" => "http://schemas.microsoft.com/office/excel/formula",
]
const _PREFIX_OF_URI = Dict(u => p for (p, u) in _USUAL_NS)
const _URI_OF_PREFIX = Dict(p => u for (p, u) in _USUAL_NS)

# The declarations of usual namespaces, ` xmlns:p="uri"` for each prefix: every namespace the
# package declares is written from the table above (code review Phase 4).
_xmlns(prefixes) = join(" xmlns:$p=\"$(_URI_OF_PREFIX[p])\"" for p in prefixes)
# The namespaces every content or styles part written or patched declares; a new part adds
# `meta`, `dc` and `xlink` (`_NS_DECL`).
const _BASE_NS = ("office", "style", "text", "table", "number", "fo", "of")
const _NS_DECL = _xmlns((_BASE_NS..., "meta", "dc", "xlink"))
const _XML_NS = "http://www.w3.org/XML/1998/namespace"

# Attributes whose value starts with a namespace prefix that LibreOffice resolves as a name
# (`table:formula="of:=1+1"`: the formula's syntax), under their usual names.
const _QNAME_VALUED = ("table:formula", "table:condition")

# The index of the next `xmlns` at or after `i`, or `nothing`. The pair `xm` is rare in ODF
# (only in `xmlns` and `xml`), so 64-byte blocks are tested for it branch-free: 512 MiB in
# about 10 ms, against 160 ms for `findnext` of the five bytes (D-067's benchmark).
function _next_xmlns(s::AbstractVector{UInt8}, i::Int)
    n = length(s)
    while true
        p = 0
        @inbounds while i + 64 <= n
            hit = false
            @simd for k in i:i+63
                hit |= (s[k] == 0x78) & (s[k+1] == 0x6d)
            end
            if hit
                for k in i:i+63
                    (s[k] == 0x78 && s[k+1] == 0x6d) && (p = k; break)
                end
                break
            end
            i += 64
        end
        if p == 0
            @inbounds for k in i:n-1
                (s[k] == 0x78 && s[k+1] == 0x6d) && (p = k; break)
            end
            p == 0 && return nothing
        end
        @inbounds p + 4 <= n && s[p+2] == 0x6c && s[p+3] == 0x6e && s[p+4] == 0x73 && return p
        i = p + 1
    end
end

@inline _ns_space(b::UInt8) = b == 0x20 || b == 0x09 || b == 0x0a || b == 0x0d
@inline _ns_namebyte(b::UInt8) = !(_ns_space(b) || b == UInt8('=') || b == UInt8('>') || b == UInt8('/') ||
                                   b == UInt8('"') || b == UInt8('\'') || b == UInt8('<'))

# The declaration whose `xmlns` starts at `p`: (prefix, uri) ("" for a default namespace),
# or `nothing` if `p` doesn't start one (`xmlns` inside a URI or text). Raw values: none of
# the usual URIs holds a character that needs escaping.
function _ns_decl_at(s::AbstractVector{UInt8}, p::Int)
    n = length(s)
    (p > 1 && _ns_space(s[p-1])) || return nothing
    j = p + 5
    j <= n || return nothing
    prefix = ""
    if s[j] == UInt8(':')
        k = j + 1
        while k <= n && _ns_namebyte(s[k]); k += 1; end
        k == j + 1 && return nothing
        prefix = String(s[j+1:k-1])
        j = k
    end
    while j <= n && _ns_space(s[j]); j += 1; end
    (j <= n && s[j] == UInt8('=')) || return nothing
    j += 1
    while j <= n && _ns_space(s[j]); j += 1; end
    (j <= n && (s[j] == UInt8('"') || s[j] == UInt8('\''))) || return nothing
    e = findnext(==(s[j]), s, j + 1)
    e === nothing && return nothing
    return prefix, String(s[j+1:e-1])
end

"""
    _ns_usual(xml) -> Bool

Whether every namespace declaration in `xml` binds a usual prefix to its usual URI, and a
known URI to its usual prefix, with no default namespace: the names in the text can then be
matched as written. Text that merely looks like a declaration (`xmlns:x="…"` in a cell)
only sends the part down the slower path, which reads it correctly.
"""
function _ns_usual(xml::AbstractString)
    s = codeunits(xml)
    i = 1
    while true
        p = _next_xmlns(s, i)
        p === nothing && return true
        i = p + 5
        d = _ns_decl_at(s, p)
        d === nothing && continue
        prefix, uri = d
        isempty(prefix) && return false
        get(_PREFIX_OF_URI, uri, prefix) == prefix || return false
        get(_URI_OF_PREFIX, prefix, uri) == uri || return false
    end
end

"""
    _ns_canonical(xml::String) -> String

`xml` itself when its prefixes are the usual ones ([`_ns_usual`](@ref)); otherwise the same
document with every name in a known namespace written with its usual prefix.
"""
_ns_canonical(xml::String) = _ns_usual(xml) ? xml : _ns_rewrite(xml)

# One start tag's attributes: (name, value start, value end, quote) as byte indices.
const _NsAttr = Tuple{String,Int,Int,UInt8}

# Parses the start tag at `p` (`s[p] == '<'`): its name, attributes, whether it closes
# itself, and the index of its `>`.
function _ns_start_tag(s::AbstractVector{UInt8}, p::Int, attrs::Vector{_NsAttr})
    n = length(s)
    empty!(attrs)
    j = p + 1
    while j <= n && _ns_namebyte(s[j]); j += 1; end
    name = String(s[p+1:j-1])
    while true
        while j <= n && _ns_space(s[j]); j += 1; end
        j > n && throw(ArgumentError("malformed XML: a start tag <$name never ends"))
        b = s[j]
        b == UInt8('>') && return name, attrs, false, j
        if b == UInt8('/')
            (j < n && s[j+1] == UInt8('>')) || throw(ArgumentError("malformed XML in the start tag <$name"))
            return name, attrs, true, j + 1
        end
        k = j
        while k <= n && _ns_namebyte(s[k]); k += 1; end
        k == j && throw(ArgumentError("malformed XML in the start tag <$name"))
        aname = String(s[j:k-1])
        while k <= n && _ns_space(s[k]); k += 1; end
        (k <= n && s[k] == UInt8('=')) || throw(ArgumentError("malformed XML: attribute $aname of <$name has no value"))
        k += 1
        while k <= n && _ns_space(s[k]); k += 1; end
        (k <= n && (s[k] == UInt8('"') || s[k] == UInt8('\''))) ||
            throw(ArgumentError("malformed XML: attribute $aname of <$name has no quoted value"))
        q = s[k]
        e = findnext(==(q), s, k + 1)
        e === nothing && throw(ArgumentError("malformed XML: attribute $aname of <$name never ends"))
        push!(attrs, (aname, k + 1, e - 1, q))
        j = e + 1
    end
end

_ns_isdecl(a::String) = a == "xmlns" || startswith(a, "xmlns:")
_ns_declprefix(a::String) = a == "xmlns" ? "" : a[7:end]

# Every declaration in the text: the known URIs declared (in the usual order, for the root),
# and every prefix declared, so that a new one doesn't clash.
function _ns_survey(s::AbstractVector{UInt8})
    known = Set{String}(); prefixes = Set{String}()
    i = 1
    while (p = _next_xmlns(s, i)) !== nothing
        i = p + 5
        d = _ns_decl_at(s, p)
        d === nothing && continue
        push!(prefixes, d[1])
        haskey(_PREFIX_OF_URI, d[2]) && push!(known, d[2])
    end
    return [u for (_, u) in _USUAL_NS if u in known], prefixes
end

mutable struct _NsRewriter
    s::Vector{UInt8}
    scopes::Vector{Dict{String,String}}   # prefix => URI ("" the default namespace), per open element
    names::Vector{String}                 # the written names of the open elements
    aliases::Dict{String,String}          # an unknown URI declared with a usual prefix => a new prefix
    taken::Set{String}
end

# A new prefix for an unknown namespace whose own prefix is a usual one (it would otherwise
# be read as ODF's).
function _ns_alias!(w::_NsRewriter, uri::String)
    get!(w.aliases, uri) do
        k = 1
        while "ns$k" in w.taken || haskey(_URI_OF_PREFIX, "ns$k"); k += 1; end
        push!(w.taken, "ns$k")
        "ns$k"
    end
end

# The written form of a prefix bound to `uri` (`nothing`: undeclared), as `prefix` was.
function _ns_prefix_for(w::_NsRewriter, prefix::AbstractString, uri)
    uri === nothing && return String(prefix)          # undeclared: as written (as before D-067)
    p = get(_PREFIX_OF_URI, uri, nothing)
    p === nothing || return p
    return haskey(_URI_OF_PREFIX, prefix) ? _ns_alias!(w, uri) : String(prefix)
end

function _ns_name(w::_NsRewriter, scope::Dict{String,String}, name::String, attribute::Bool)
    c = findfirst(':', name)
    if c === nothing
        attribute && return name                      # an unprefixed attribute has no namespace
        u = get(scope, "", "")
        p = get(_PREFIX_OF_URI, u, nothing)
        return p === nothing ? name : p * ":" * name
    end
    prefix = SubString(name, 1, c - 1)
    prefix == "xml" && return name
    return _ns_prefix_for(w, prefix, get(scope, prefix, nothing)) * SubString(name, c)
end

"""
    _ns_rewrite(xml::String) -> String

`xml` with each element and attribute of a known namespace under its usual prefix (and the
prefix of a QName-valued attribute's value, `fm:=1+1` → `of:=1+1`), the known namespaces
declared once on the root, and everything else as written: text, comments, CDATA,
processing instructions, attribute values, and unknown namespaces (renamed only where their
prefix is a usual one).
"""
function _ns_rewrite(xml::String)
    s = Vector{UInt8}(codeunits(xml))
    known, taken = _ns_survey(s)
    w = _NsRewriter(s, [Dict("xml" => _XML_NS)], String[], Dict{String,String}(), taken)
    out = IOBuffer(sizehint = length(s) + 4096)
    attrs = _NsAttr[]
    n = length(s)
    i = 1
    rooted = false
    while i <= n
        p = findnext(==(UInt8('<')), s, i)
        if p === nothing
            write(out, view(s, i:n)); break
        end
        write(out, view(s, i:p-1))
        b = p < n ? s[p+1] : 0x00
        if b == UInt8('!') || b == UInt8('?')
            e = _ns_markup_end(s, p)
            write(out, view(s, p:e)); i = e + 1
        elseif b == UInt8('/')
            e = findnext(==(UInt8('>')), s, p)
            e === nothing && throw(ArgumentError("malformed XML: an end tag never ends"))
            isempty(w.names) && throw(ArgumentError("malformed XML: an end tag with no start tag"))
            print(out, "</", pop!(w.names), ">")
            pop!(w.scopes)
            i = e + 1
        else
            name, attrs, selfclose, e = _ns_start_tag(s, p, attrs)
            scope = w.scopes[end]
            decls = false
            for (a, v1, v2, _) in attrs
                _ns_isdecl(a) || continue
                decls || (scope = copy(scope); decls = true)
                scope[_ns_declprefix(a)] = String(s[v1:v2])
            end
            ename = _ns_name(w, scope, name, false)
            print(out, '<', ename)
            if !rooted
                rooted = true
                for u in known
                    print(out, " xmlns:", _PREFIX_OF_URI[u], "=\"", u, '"')
                end
            end
            for (a, v1, v2, q) in attrs
                if _ns_isdecl(a)
                    u = String(s[v1:v2])
                    haskey(_PREFIX_OF_URI, u) && continue          # declared on the root
                    dp = _ns_declprefix(a)
                    a = isempty(dp) ? a : "xmlns:" * _ns_prefix_for(w, dp, u)
                    print(out, ' ', a, '=', Char(q)); write(out, view(s, v1:v2)); print(out, Char(q))
                    continue
                end
                aname = _ns_name(w, scope, a, true)
                print(out, ' ', aname, '=', Char(q))
                if aname in _QNAME_VALUED && (c = findnext(==(UInt8(':')), s, v1)) !== nothing && c <= v2 &&
                        all(_ns_namebyte, view(s, v1:c-1)) && c > v1
                    vp = String(s[v1:c-1])
                    print(out, _ns_prefix_for(w, vp, get(scope, vp, nothing)))
                    write(out, view(s, c:v2))
                else
                    write(out, view(s, v1:v2))
                end
                print(out, Char(q))
            end
            if selfclose
                print(out, "/>")
            else
                print(out, '>')
                push!(w.names, ename); push!(w.scopes, scope)
            end
            i = e + 1
        end
    end
    return String(take!(out))
end

# The last index of a comment, CDATA section, processing instruction or DOCTYPE at `p`.
function _ns_markup_end(s::AbstractVector{UInt8}, p::Int)
    n = length(s)
    lit(t) = p + ncodeunits(t) - 1 <= n && view(s, p:p+ncodeunits(t)-1) == codeunits(t)
    term = lit("<!--") ? "-->" : lit("<![CDATA[") ? "]]>" : s[p+1] == UInt8('?') ? "?>" : ""
    if !isempty(term)
        r = findnext(codeunits(term), s, p + 2)
        r === nothing && throw(ArgumentError("malformed XML: markup never ends"))
        return last(r)
    end
    depth = 0; q = 0x00                                   # <!DOCTYPE …[ … ]>
    for j in p+2:n
        b = s[j]
        if q != 0x00
            b == q && (q = 0x00)
        elseif b == UInt8('"') || b == UInt8('\'')
            q = b
        elseif b == UInt8('[')
            depth += 1
        elseif b == UInt8(']')
            depth -= 1
        elseif b == UInt8('>') && depth <= 0
            return j
        end
    end
    throw(ArgumentError("malformed XML: a declaration never ends"))
end

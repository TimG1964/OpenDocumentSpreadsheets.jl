# Document properties (phase 5 step 11; D-064): XLSX.jl's API, stored in meta.xml (a flat file's
# office:meta) as LibreOffice's xlsx import stores XLSX.jl's (experiment 027, F-056).
#
# Adapted from XLSX.jl 0.13.4 (src/docprops.jl `setDocumentProperties`, `getDocumentProperties`,
# `setCustomProperty`, `getCustomProperty`, `getCustomProperties`, `deleteCustomProperty`, the
# W3C date parsing), MIT License, Copyright (c) 2018-2026 Felipe Noronha Tavares and other
# contributors. Changes: ODF's meta elements; the four properties ODF lacks (category, content status,
# company, manager) are user-defined properties named as LibreOffice's import names them; custom
# properties take ODF's value types.
#
# The file's office:meta children are kept as they are (tag => XML, in order); a change replaces,
# removes or adds children, and the element is written again. OpenDocumentSpreadsheets never updates the modification
# date or the generator of a file it saves (D-023, as XLSX.jl).

# LibreOffice's order (experiment 027's import); the generator, statistics and others come after these,
# the user-defined properties last, by name.
const _META_ORDER = ["dc:title", "dc:subject", "meta:initial-creator", "meta:keyword", "dc:description",
                     "dc:creator", "meta:creation-date", "dc:date"]
_meta_rank(tag) = something(findfirst(==(tag), _META_ORDER), tag == "meta:user-defined" ? 100 : 50)

# XLSX.jl's properties: (ODF element, or the user-defined property LibreOffice's import makes).
const _DOC_PROPERTIES = (title = "dc:title", subject = "dc:subject", creator = "meta:initial-creator",
                         keywords = "meta:keyword", description = "dc:description", lastModifiedBy = "dc:creator",
                         category = "user:OOXMLCorePropertyCategory", contentStatus = "user:OOXMLCorePropertyContentStatus",
                         created = "meta:creation-date", modified = "dc:date", company = "user:Company", manager = "user:Manager")
const _MAPPED_USER = ("OOXMLCorePropertyCategory", "OOXMLCorePropertyContentStatus", "Company", "Manager")
const _CUSTOM_NAME_MAX = 255
const _META_RE = r"<office:meta\b[^>]*?(?:/>|>.*?</office:meta>)"s

# The file's office:meta, read on first use.
function _meta(xf::ODSFile)
    xf.meta === nothing || return xf.meta
    s = nothing
    if isnewfile(xf)
        s = _meta_body()                     # the generator and the creation date a new file gets
    else
        t = read_xml(xf.container, :meta)    # (a flat file: the whole document; its meta comes first)
        if t !== nothing
            r = findfirst(_META_RE, t)
            r === nothing || (s = String(SubString(t, first(r), last(r))))
        end
    end
    kids = s === nothing ? Pair{String,String}[] : _children(s)
    isnewfile(xf) && sort!(kids; by = c -> _meta_rank(c.first))
    xf.meta = MetaEdits(kids, false)
    return xf.meta
end

_meta_edited(xf::ODSFile) = xf.meta !== nothing && xf.meta.changed

_user_name(x::AbstractString) = (n = _start_tag_attr(SubString(x, 1, _start_tag_end(x)), "meta:name"); something(n, ""))
_elem_text(x::AbstractString) = endswith(x, "/>") ? "" : XML.unescape(x[nextind(x, _start_tag_end(x)):prevind(x, first(findlast("</", x)))])

# The index of a child (a user-defined property by name, without regard to case), or nothing.
function _meta_index(m::MetaEdits, tag::AbstractString, name::Union{Nothing,AbstractString} = nothing)
    findfirst(m.children) do (t, x)
        t == tag && (name === nothing || lowercase(_user_name(x)) == lowercase(name))
    end
end

# Puts `xml` (nothing: removes) for the child `tag` (`name` for a user-defined one), in place, or where
# LibreOffice writes it.
function _meta_set!(m::MetaEdits, tag::String, xml::Union{Nothing,String}; name = nothing)
    i = _meta_index(m, tag, name)
    if i !== nothing
        xml === nothing ? deleteat!(m.children, i) : (m.children[i] = tag => xml)
    elseif xml !== nothing
        r = _meta_rank(tag)
        j = findfirst(c -> _meta_rank(c.first) > r || (c.first == tag == "meta:user-defined" && _user_name(c.second) > name), m.children)
        j === nothing ? push!(m.children, tag => xml) : insert!(m.children, j, tag => xml)
    else
        return                                   # nothing to remove: the file is unchanged
    end
    m.changed = true
    return
end

_meta_elem(tag, text) = "<$tag>" * _escape_text_string(text) * "</$tag>"
_escape_text_string(s) = (io = IOBuffer(); _escape_text(io, String(s)); String(take!(io)))

function _user_xml(name, type::Union{Nothing,String}, text)
    io = IOBuffer()
    print(io, "<meta:user-defined meta:name=\""); _escape_attr(io, String(name)); print(io, '"')
    type === nothing || print(io, " meta:value-type=\"", type, '"')
    print(io, '>'); _escape_text(io, String(text)); print(io, "</meta:user-defined>")
    return String(take!(io))
end

_odf_datetime(d::Dates.Date) = _odf_datetime(Dates.DateTime(d))
_odf_datetime(d::Dates.DateTime) = Dates.format(d, Dates.dateformat"yyyy-mm-ddTHH:MM:SS")

# An ODF or W3C date-time as a DateTime (a UTC offset applied), or nothing.
function _parse_meta_datetime(s::AbstractString)
    m = match(r"^(\d{4})-(\d\d)-(\d\d)(?:T(\d\d):(\d\d)(?::(\d\d)(?:\.(\d+))?)?)?\s*(Z|[+-]\d\d:\d\d)?$", strip(s))
    m === nothing && return nothing
    n(i) = m[i] === nothing ? 0 : parse(Int, m[i])
    ms = m[7] === nothing ? 0 : parse(Int, rpad(first(m[7], 3), 3, '0'))
    d = try
        Dates.DateTime(n(1), n(2), n(3), n(4), n(5), n(6), ms)
    catch e
        e isa ArgumentError || rethrow()
        return nothing
    end
    z = m[8]
    if z !== nothing && z != "Z"
        sgn = z[1] == '-' ? -1 : 1
        d -= Dates.Minute(sgn * (60 * parse(Int, z[2:3]) + parse(Int, z[5:6])))
    end
    return d
end

"""
    setDocumentProperties(xf; title, subject, creator, keywords, description, lastModifiedBy,
                          category, contentStatus, created, modified, company, manager)

Set the file's document properties, as LibreOffice's *File → Properties* shows them. Only the
keywords given change; `""` removes one. They are stored as LibreOffice's xlsx import stores
XLSX.jl's (F-056):
- `title`, `subject`, `description`: `dc:title`, `dc:subject`, `dc:description`
- `creator`: `meta:initial-creator`; `lastModifiedBy`: `dc:creator`
- `keywords`: one `meta:keyword` for each part between `;` or `,`
- `created`, `modified` (`Date` or `DateTime`): `meta:creation-date`, `dc:date`
- `category`, `contentStatus`, `company`, `manager`, which ODF lacks: the custom properties
  LibreOffice's import makes of them (`OOXMLCorePropertyCategory`, `OOXMLCorePropertyContentStatus`,
  `Company`, `Manager`)

OpenDocumentSpreadsheets never changes `modified` or `lastModifiedBy` when it saves a file (LibreOffice does).
"""
function setDocumentProperties(xf::ODSFile; kw...)
    _require_writable(xf, "set document properties")
    isempty(kw) && throw(ODSError("Give the properties to set as keywords, such as `title=\"Sales\"`."))
    for (k, v) in kw
        haskey(_DOC_PROPERTIES, k) || throw(ODSError("Unknown keyword `$k`. Must be one of $(join(keys(_DOC_PROPERTIES), ", "))."))
        if k in (:created, :modified)
            v isa Union{Dates.Date,Dates.DateTime} || throw(ODSError("`$k` must be a `DateTime` or `Date`, in UTC. Found `$(repr(v))`."))
        else
            v isa AbstractString || throw(ODSError("`$k` must be a string. Found `$(repr(v))`."))
            _check_xml_text(v)
        end
    end
    m = _meta(xf)
    for (k, v) in kw
        target = _DOC_PROPERTIES[k]
        if k === :keywords
            at = findfirst(c -> c.first == "meta:keyword", m.children)
            had = at !== nothing
            filter!(c -> c.first != "meta:keyword", m.children)
            words = filter(!isempty, strip.(split(v, r"[;,]")))
            xs = ["meta:keyword" => _meta_elem("meta:keyword", w) for w in words]
            if at === nothing
                r = _meta_rank("meta:keyword")
                at = something(findfirst(c -> _meta_rank(c.first) > r, m.children), length(m.children) + 1)
            end
            for (i, x) in enumerate(xs)
                insert!(m.children, at + i - 1, x)
            end
            (had || !isempty(xs)) && (m.changed = true)    # nothing to remove: the file is unchanged
        elseif startswith(target, "user:")
            name = target[6:end]
            # as the import writes them: Company without a type, the others as strings
            _meta_set!(m, "meta:user-defined", isempty(v) ? nothing : _user_xml(name, name == "Company" ? nothing : "string", v); name)
        elseif k in (:created, :modified)
            _meta_set!(m, target, _meta_elem(target, _odf_datetime(v)))
        else
            _meta_set!(m, target, isempty(v) ? nothing : _meta_elem(target, v))
        end
    end
    return nothing
end

"""
    getDocumentProperties(xf) -> NamedTuple

The file's document properties, the fields of [`setDocumentProperties`](@ref), each `nothing` if
the file doesn't have it. `keywords` are joined by `", "`; `created` and `modified` are
`DateTime`s (or the text, if it isn't a date). Works on read-only files.
"""
function getDocumentProperties(xf::ODSFile)
    m = _meta(xf)
    function value(k)
        target = _DOC_PROPERTIES[k]
        if k === :keywords
            ws = [_elem_text(x) for (t, x) in m.children if t == "meta:keyword"]
            return isempty(ws) ? nothing : join(ws, ", ")
        end
        i = startswith(target, "user:") ? _meta_index(m, "meta:user-defined", target[6:end]) : _meta_index(m, target)
        i === nothing && return nothing
        t = _elem_text(m.children[i].second)
        isempty(t) && return nothing
        return k in (:created, :modified) ? something(_parse_meta_datetime(t), t) : t
    end
    ks = keys(_DOC_PROPERTIES)
    return NamedTuple{ks}(map(value, ks))
end

# A custom property's ODF type and text (F-056: numbers are floats, dates and date-times dates).
_custom_odf(v::AbstractString) = ("string", String(v))
_custom_odf(v::Bool) = ("boolean", v ? "true" : "false")
_custom_odf(v::Integer) = ("float", string(v))
function _custom_odf(v::Real)
    isfinite(v) || throw(ODSError("A custom property can't be `$v`."))
    return ("float", string(Float64(v)))
end
_custom_odf(v::Union{Dates.Date,Dates.DateTime}) = ("date", _odf_datetime(v))
_custom_odf(v) = throw(ODSError("A custom property is a string, a number, a `Bool`, or a `Date` or `DateTime`. Found `$(repr(v))`."))

function _custom_value(x::AbstractString)
    type = something(_start_tag_attr(SubString(x, 1, _start_tag_end(x)), "meta:value-type"), "string")
    t = _elem_text(x)
    type == "boolean" && return lowercase(t) in ("true", "1")
    if type == "float"
        occursin(r"^[+-]?\d+$", t) && (v = tryparse(Int64, t); v === nothing || return v)
        return something(tryparse(Float64, t), t)
    end
    type == "date" && return something(_parse_meta_datetime(t), t)
    return t
end

"""
    setCustomProperty(xf, name, value)

Set the custom document property `name` (replacing one of that name, without regard to case) to a
string, a number, a `Bool`, or a `Date` or `DateTime`. Stored as LibreOffice's user-defined
properties are (F-056): numbers as `float`, dates and date-times as `date`. The four names
LibreOffice's import gives XLSX.jl's category, content status, company and manager are those
properties: set them with [`setDocumentProperties`](@ref).
"""
function setCustomProperty(xf::ODSFile, name::AbstractString, value)
    _require_writable(xf, "set a custom property")
    1 <= length(name) <= _CUSTOM_NAME_MAX ||
        throw(ODSError("A custom property's name must be 1 to $_CUSTOM_NAME_MAX characters long. Found `$(repr(name))`."))
    any(n -> lowercase(n) == lowercase(name), _MAPPED_USER) &&
        throw(ODSError("`$name` holds a document property in LibreOffice's model: give it to `setDocumentProperties`."))
    _check_xml_text(name)
    type, text = _custom_odf(value)
    type == "string" && _check_xml_text(text)
    m = _meta(xf)
    i = _meta_index(m, "meta:user-defined", name)
    old = i === nothing ? String(name) : _user_name(m.children[i].second)
    _meta_set!(m, "meta:user-defined", _user_xml(old, type, text); name)
    return nothing
end

"""
    getCustomProperties(xf) -> Vector{Pair{String,Any}}

The file's custom document properties, in the file's order: `String`, `Int64` (a whole `float`, on 32-bit Julia too),
`Float64`, `Bool` or `DateTime` values, or the text for other types. The four that hold XLSX.jl's
category, content status, company and manager are left out (they are
[`getDocumentProperties`](@ref)'s). Works on read-only files.
"""
function getCustomProperties(xf::ODSFile)
    out = Pair{String,Any}[]
    for (t, x) in _meta(xf).children
        t == "meta:user-defined" || continue
        n = _user_name(x)
        n in _MAPPED_USER && continue
        push!(out, n => _custom_value(x))
    end
    return out
end

"""
    getCustomProperty(xf, name)

The value of custom property `name` (without regard to case), or `nothing`.
"""
function getCustomProperty(xf::ODSFile, name::AbstractString)
    for (n, v) in getCustomProperties(xf)
        lowercase(n) == lowercase(name) && return v
    end
    return nothing
end

"""
    deleteCustomProperty(xf, name) -> Bool

Delete custom property `name` (without regard to case). `false` if the file hasn't it.
"""
function deleteCustomProperty(xf::ODSFile, name::AbstractString)
    _require_writable(xf, "delete a custom property")
    any(n -> lowercase(n) == lowercase(name), _MAPPED_USER) && return false
    m = _meta(xf)
    _meta_index(m, "meta:user-defined", name) === nothing && return false
    _meta_set!(m, "meta:user-defined", nothing; name)
    return true
end

#
# Writing
#

_meta_inner(xf::ODSFile) = join(last.(_meta(xf).children))

# A document's office:meta, written again with the edits.
_meta_element(xf::ODSFile) = "<office:meta>" * _meta_inner(xf) * "</office:meta>"

# A meta.xml (or the part of a flat document) with its office:meta written again.
function _patched_meta(xf::ODSFile, s::AbstractString)
    r = findfirst(_META_RE, s)
    if r === nothing
        e = findfirst(r"<office:document(-meta)?\b[^>]*>", s)
        return s[1:last(e)] * _meta_element(xf) * s[nextind(s, last(e)):end]
    end
    return s[1:prevind(s, first(r))] * _meta_element(xf) * s[nextind(s, last(r)):end]
end

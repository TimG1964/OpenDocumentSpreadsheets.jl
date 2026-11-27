# A chart object as an XML.jl tree (code review, Phase 3; D-102). The setters find elements as paths
# (the child indices from the document down) and change them through XML.jl's documented calls only:
# `node["k"] = v`, `push!(parent, child)`, `parent[i] = child` and `XML.Element`. An element that
# loses an attribute, or whose children change other than at the end, is rebuilt and put in its
# parent's place. A path holds until its parent's children change.

const _Path = Vector{Int}

_isel(n) = XML.nodetype(n) === XML.Element
_tattr(n, k::AbstractString) = (a = XML.attributes(n); a === nothing ? nothing : get(a, k, nothing))
_tpairs(n) = (a = XML.attributes(n); a === nothing ? Pair{String,String}[] : Pair{String,String}[String(k) => String(v) for (k, v) in a])

function _tnode(o, p::_Path)
    n = _tree!(o)
    for i in p
        n = XML.children(n)[i]
    end
    return n
end
_tget(o, p::_Path, k::AbstractString) = _tattr(_tnode(o, p), k)
_ttag(o, p::_Path) = XML.tag(_tnode(o, p))

# Every element (with `tag`, and for which `pred` holds) under `within`, in document order.
# (Both walk with one path, copied only for an element found: a path made at each element was most
# of the time a setter took.)
function _tall(o, tag::Union{Nothing,AbstractString} = nothing; within::_Path = Int[], pred = nothing)
    out = _Path[]
    p = copy(within)
    function walk(n)
        for (i, c) in enumerate(XML.children(n))
            _isel(c) || continue
            push!(p, i)
            (tag === nothing || XML.tag(c) == tag) && (pred === nothing || pred(c)) && push!(out, copy(p))
            walk(c)
            pop!(p)
        end
    end
    walk(_tnode(o, within))
    return out
end
# The first such element, or nothing.
function _tfirst(o, tag::AbstractString; within::_Path = Int[], pred = nothing)
    p = copy(within)
    function walk(n)
        for (i, c) in enumerate(XML.children(n))
            _isel(c) || continue
            push!(p, i)
            XML.tag(c) == tag && (pred === nothing || pred(c)) && return true
            walk(c) && return true
            pop!(p)
        end
        return false
    end
    return walk(_tnode(o, within)) ? p : nothing
end
# Calls `f` on every element of the tree, in document order, without making paths.
function _teach(f, o)
    walk(n) = for c in XML.children(n)
        _isel(c) || continue
        f(c)
        walk(c)
    end
    walk(_tree!(o))
    return nothing
end

# The element children of `p` with `tag` (any: `nothing`), as paths.
_tkids(o, p::_Path, tag = nothing) = [[p; i] for (i, c) in enumerate(XML.children(_tnode(o, p)))
                                      if _isel(c) && (tag === nothing || XML.tag(c) == tag)]

# An element with other attributes or children (in the same order as before otherwise).
_telement(n, attrs::Vector{Pair{String,String}}, kids) = XML.Element(XML.tag(n), kids...; (Symbol(k) => v for (k, v) in attrs)...)

function _treplace!(o, p::_Path, new)
    parent = _tnode(o, p[1:end-1])
    parent[p[end]] = new
    _tree_edited!(o)
    return new
end

# Sets attributes of the element at `p`; `nothing` removes one. Values are text, not escaped.
function _tset!(o, p::_Path, attrs)
    n = _tnode(o, p)
    a = _tpairs(n)
    if !isempty(a) && all(x -> x.second !== nothing, attrs)
        for (k, v) in attrs                                   # documented: node["key"] = value
            _check_xml_text(v)
            n[k] = String(v)
        end
        _tree_edited!(o)
        return n
    end
    for (k, v) in attrs
        i = findfirst(x -> x.first == k, a)
        if v === nothing
            i === nothing || deleteat!(a, i)
        else
            _check_xml_text(v)
            i === nothing ? push!(a, String(k) => String(v)) : (a[i] = String(k) => String(v))
        end
    end
    return _treplace!(o, p, _telement(n, a, XML.children(n)))
end

# Inserts `nodes` as children of `p` before its child `i` (past the last: at the end).
function _tinsert!(o, p::_Path, i::Integer, nodes...)
    n = _tnode(o, p)
    kids = collect(XML.children(n))
    # at the end: `push!`, but an element read from `<x/>` has no children vector, and is rebuilt
    if i > length(kids) && XML.children(n) isa AbstractVector
        for x in nodes
            push!(n, x)                                       # documented: push!(parent, child)
        end
        _tree_edited!(o)
        return n
    end
    i = min(i, length(kids) + 1)
    return _treplace!(o, p, _telement(n, _tpairs(n), vcat(kids[1:i-1], collect(nodes), kids[i:end])))
end
_tappend!(o, p::_Path, nodes...) = _tinsert!(o, p, typemax(Int), nodes...)

# Removes the element at `p` (`pred` of its parent's children: all those it holds for).
function _tdelete!(o, p::_Path)
    parent = _tnode(o, p[1:end-1])
    kids = collect(XML.children(parent))
    deleteat!(kids, p[end])
    _treplace!(o, p[1:end-1], _telement(parent, _tpairs(parent), kids))
    return nothing
end
function _tdelete_kids!(o, p::_Path, pred)
    n = _tnode(o, p)
    kids = collect(XML.children(n))
    keep = [c for c in kids if !(_isel(c) && pred(c))]
    length(keep) == length(kids) && return false
    _treplace!(o, p, _telement(n, _tpairs(n), keep))
    return true
end

# The nodes an XML fragment (text, as the setters build it) holds.
_tfrag(xml::AbstractString) = collect(XML.children(only(XML.children(parse(XML.Node, "<_x>" * xml * "</_x>")))))
_tfrag1(xml::AbstractString) = only(n for n in _tfrag(xml) if _isel(n))

# An element's copy, sharing nothing with it (`node["k"] = v` changes a node in place).
_tcopy(n) = deepcopy(n)

#
# Automatic styles
#

function _auto_styles(o)
    p = _tfirst(o, "office:automatic-styles")
    p === nothing && throw(ODSError("The chart's object has no automatic styles."))
    return p
end
# The automatic style `name`, or nothing.
function _style_el(o, name::AbstractString)
    a = _tfirst(o, "office:automatic-styles")
    a === nothing && return nothing
    for (i, c) in enumerate(XML.children(_tnode(o, a)))       # read in place: a path only for the one found
        _isel(c) && XML.tag(c) == "style:style" && _tattr(c, "style:name") == name && return [a; i]
    end
    return nothing
end
# How many elements name the style `name` (`chart:style-name`).
function _style_uses(o, name::AbstractString)
    n = 0
    _teach(c -> _tattr(c, "chart:style-name") == name && (n += 1), o)
    return n
end

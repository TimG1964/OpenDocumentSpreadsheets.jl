# Locating the sheets (`table:table` elements) in content.xml or a flat document, without
# parsing their contents. See D-007 and experiment 002.
#
# Each sheet is recorded as an `XML.LazyNode` snapshot. `XML.Cursor(snapshot)` later
# restarts a walk at that sheet. Byte offsets are not used: `Cursor(data, startpos)` is
# deprecated in XML.jl 0.4.10 and will be removed in 0.5, and a snapshot stays valid
# whatever BOM or line-end handling the cursor applied to the source.

"""
    SheetEntry

A sheet found in the document body: its `name`, its position (1-based, in document order)
and `node`, a lazy snapshot of its `table:table` element.
"""
struct SheetEntry{S<:AbstractString}
    name::String
    index::Int
    node::XML.LazyNode{S}
end

Base.show(io::IO, s::SheetEntry) = print(io, "SheetEntry(", repr(s.name), ", ", s.index, ")")

# The element path from the root to the sheets. The root is office:document-content
# (content.xml) or office:document (flat).
const _BODY_PATH = ("office:body", "office:spreadsheet")

"""
    index_sheets(xml::String) -> Vector{SheetEntry}

Find every `table:table` element directly under `office:body/office:spreadsheet`.
Everything else is skipped without being tokenised: automatic styles, font declarations,
master styles, and the sheets' own contents (XML.jl `skip_element!`, about 3 GB/s in
experiment 002).
"""
index_sheets(xml::String) = index_body(xml).sheets

"""
    BodyIndex

What `index_body` finds directly under `office:spreadsheet`: the sheets, and snapshots of the
workbook's `table:named-expressions` and `table:calculation-settings` (`nothing` if absent).
"""
struct BodyIndex
    sheets::Vector{SheetEntry{String}}
    named_expressions::Union{Nothing,XML.LazyNode{String}}
    calculation_settings::Union{Nothing,XML.LazyNode{String}}
end

"""
    index_body(xml::String) -> BodyIndex

[`index_sheets`](@ref), also keeping snapshots of the workbook-level named expressions and
calculation settings. Each child of `office:spreadsheet` is skipped whole.
"""
function index_body(xml::String)
    s = BodyScanner(xml)
    sheets = Vector{SheetEntry{String}}()
    names = nothing
    calc = nothing
    while (item = next_body_item!(s)) !== nothing
        kind, node, name = item
        if kind === :table
            push!(sheets, SheetEntry(name, length(sheets) + 1, node))
        elseif kind === :names
            names = node
        else
            calc = node
        end
    end
    BodyIndex(sheets, names, calc)
end

"""
    BodyScanner(xml::String)

An incremental walk over the children of `office:spreadsheet`: each `next_body_item!` gives
the next sheet, named-expressions or calculation-settings element, skipping each element
whole. Reading the first sheet thus never scans the ones after it, and an item is
skipped only when the next one is asked for, so that finding a sheet doesn't scan it.
"""
mutable struct BodyScanner
    c::XML.Cursor{String}
    depth::Int          # the depth of office:spreadsheet
    done::Bool
    pending::Bool       # the cursor is still on the last item given: skip it first
end

function BodyScanner(xml::String)
    c = XML.Cursor(xml)
    while XML.next!(c) !== nothing
        XML.nodetype(c) === XML.Element && break
    end
    XML.nodetype(c) === XML.Element || throw(ArgumentError("no root element"))
    for step in _BODY_PATH
        _descend_to!(c, step) || return BodyScanner(c, 0, true, false)
    end
    return BodyScanner(c, XML.depth(c), false, false)
end

"""
    next_body_item!(s::BodyScanner) -> Union{Nothing, Tuple{Symbol, LazyNode, String}}

The next `(:table, node, name)`, `(:names, node, "")` or `(:calc, node, "")`, or `nothing`
at the end of the spreadsheet.
"""
function next_body_item!(s::BodyScanner)
    s.done && return nothing
    c = s.c
    if s.pending
        XML.skip_element!(c)
        s.pending = false
    end
    while true
        if XML.next!(c) === nothing || XML.depth(c) <= s.depth
            s.done = true
            return nothing
        end
        (XML.nodetype(c) === XML.Element && XML.depth(c) == s.depth + 1) || continue
        t = XML.tag(c)
        if t == "table:table"
            name = ""
            for (k, v) in XML.eachattribute!(c)
                k == "table:name" && (name = String(v))
            end
            node = XML.LazyNode(c)
            s.pending = true
            return (:table, node, name)
        elseif t == "table:named-expressions" || t == "table:calculation-settings"
            node = XML.LazyNode(c)
            s.pending = true
            return (t == "table:named-expressions" ? :names : :calc, node, "")
        end
        XML.skip_element!(c)
    end
end

# Move the cursor (on an element) to its child element `name`, skipping the other children
# whole. Returns false if there is no such child.
function _descend_to!(c::XML.Cursor, name::AbstractString)
    parent_depth = XML.depth(c)
    while XML.next!(c) !== nothing
        XML.depth(c) <= parent_depth && return false     # left the parent
        XML.nodetype(c) === XML.Element || continue
        XML.tag(c) == name && return true
        XML.skip_element!(c)
    end
    false
end

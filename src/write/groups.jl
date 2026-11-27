# Grouping rows and columns (phase 5 step 7; D-060), with XLSX.jl's API and LibreOffice's rules
# (experiment 023 part B, F-052).
#
# Adapted from XLSX.jl 0.13.4 (src/cellformats/rowscols.jl `groupRows`, `groupColumns`,
# `ungroupRows`, `ungroupColumns`, `getRowOutlineLevel`, `getColumnOutlineLevel`), MIT License,
# Copyright (c) 2018-2026 Felipe Noronha Tavares and other contributors. Changes: Excel keeps an
# outline level per line; ODF and LibreOffice keep groups, nested containers of rows or columns,
# so these follow LibreOffice's outline rules (which groups a call makes, moves or removes).
#
# A sheet's groups are `LineGroup`s in its formats (src/styles/formats.jl), read with them. When
# they change, a save writes the sheet's table and then rebuilds its group containers
# (`_regroup`): the old `table:table-row-group`/`-column-group` tags are dropped, and new ones
# are put around the lines, splitting repeated rows or columns where a group starts or ends.

const _MAX_OUTLINE_DEPTH = 7          # LibreOffice's (F-052)

_holds(g::LineGroup, a::Int, b::Int) = g.first <= a && b <= g.last
_meets(g::LineGroup, a::Int, b::Int) = g.first <= b && a <= g.last

# LibreOffice's grouping of a:b (F-052): inside the deepest group that holds it, and around the
# groups it holds, which go one level deeper. A range that crosses a group, or that would make a
# group deeper than 7, is refused (LibreOffice ignores it).
function _group!(groups::Vector{LineGroup}, a::Int, b::Int, display::Bool, what)
    for g in groups
        _meets(g, a, b) && !_holds(g, a, b) && !(a <= g.first && g.last <= b) &&
            throw(ODSError("Can't group $what $a:$b: it crosses the group $(g.first):$(g.last), as LibreOffice refuses."))
    end
    pd = maximum((g.depth for g in groups if _holds(g, a, b)); init = 0)
    new = [(a <= g.first && g.last <= b && g.depth > pd) ? LineGroup(g.first, g.last, g.depth + 1, g.display) : g for g in groups]
    push!(new, LineGroup(a, b, pd + 1, display))
    maximum(g -> g.depth, new) > _MAX_OUTLINE_DEPTH &&
        throw(ODSError("Can't group $what $a:$b: groups would be nested deeper than $_MAX_OUTLINE_DEPTH, the most LibreOffice allows."))
    empty!(groups); append!(groups, sort!(new; by = g -> (g.first, g.depth)))
    return
end

# LibreOffice's ungrouping of a:b (F-052): the groups at the deepest level a:b meets are removed,
# and the groups they held move up a level. Nothing happens where a:b meets no group.
function _ungroup!(groups::Vector{LineGroup}, a::Int, b::Int)
    touched = [g for g in groups if _meets(g, a, b)]
    isempty(touched) && return false
    level = maximum(g -> g.depth, touched)
    gone = [g for g in touched if g.depth == level]
    keep = LineGroup[]
    for g in groups
        any(x -> x === g || x == g, gone) && continue
        up = count(x -> x.first <= g.first && g.last <= x.last && g.depth > x.depth, gone)
        push!(keep, up == 0 ? g : LineGroup(g.first, g.last, g.depth - up, g.display))
    end
    empty!(groups); append!(groups, sort!(keep; by = g -> (g.first, g.depth)))
    return true
end

_depth_at(groups::Vector{LineGroup}, x::Int) = count(g -> g.first <= x <= g.last, groups)

# Groups through an insert (`n > 0` lines at `at`) or a delete (lines at:at-n-1), as LibreOffice
# moves them (F-052): a group starting at or after an insert moves; one that the insert falls
# inside, or just after, grows. A delete shrinks the groups it cuts and removes those it holds.
function _shift_groups(groups::Vector{LineGroup}, at::Int, n::Int, maxl::Int)
    out = LineGroup[]
    for g in groups
        a, b = g.first, g.last
        if n > 0
            if a >= at
                a += n; b += n
            elseif b + 1 >= at
                b += n
            end
            a > maxl && continue
            b = min(b, maxl)
        else
            d1 = at; d2 = at - n - 1
            if b >= d1 && a <= d2
                (a >= d1 && b <= d2) && continue          # wholly deleted
                if a >= d1
                    a, b = d1, b - (d2 - d1 + 1)
                elseif b <= d2
                    b = d1 - 1
                else
                    b -= d2 - d1 + 1
                end
            elseif a > d2
                a -= d2 - d1 + 1; b -= d2 - d1 + 1
            end
        end
        push!(out, LineGroup(a, b, g.depth, g.display))
    end
    return sort!(out; by = g -> (g.first, g.depth))
end

function _shift_sheet_groups!(f::SheetFormats, axis::Int, at::Int, n::Int, maxl::Int)
    gs = axis == 1 ? f.rowgroups : f.colgroups
    isempty(gs) && return
    new = _shift_groups(gs, at, n, maxl)
    new == gs && return                         # untouched: the containers stay as they are
    axis == 1 ? (f.rowgroups = new) : (f.colgroups = new)
    f.groups_touched = true                     # their containers are written again
    return
end

# Print titles through an insert or delete: as a group (phase 5 step 10).
function _shift_titles!(f::SheetFormats, axis::Int, at::Int, n::Int, maxl::Int)
    tr = axis == 1 ? f.title_rows : f.title_cols
    tr === nothing && return
    g = _shift_groups([LineGroup(first(tr), last(tr), 1, true)], at, n, maxl)
    new = isempty(g) ? nothing : g[1].first:g[1].last
    new == tr && return
    axis == 1 ? (f.title_rows = new) : (f.title_cols = new)
    f.groups_touched = true
    return
end

#
# The API
#

function _group_lines!(ws::Worksheet, axis::Int, x, collapsed::Bool)
    what = axis == 1 ? "rows" : "columns"
    _require_writable(ws, "group $what")
    spans = _hidden_lines(ws, axis, x)          # checked and merged into runs
    f = sheet_formats(ws)
    gs = axis == 1 ? f.rowgroups : f.colgroups
    for r in spans
        _group!(gs, first(r), last(r), !collapsed, what)
        collapsed && (axis == 1 ? set_row_formats!(ws, r; visibility = "collapse") :
                                  set_column_formats!(ws, r; visibility = "collapse"))
    end
    f.groups_touched = true
    return nothing
end

function _ungroup_lines!(ws::Worksheet, axis::Int, x)
    _require_writable(ws, "ungroup $(axis == 1 ? "rows" : "columns")")
    spans = _hidden_lines(ws, axis, x)
    f = sheet_formats(ws)
    gs = axis == 1 ? f.rowgroups : f.colgroups
    changed = false
    for r in spans
        changed |= _ungroup!(gs, first(r), last(r))
    end
    changed && (f.groups_touched = true)
    return nothing
end

"""
    groupRows(sheet, rows; collapsed=false)
    groupRows(xf, "Sheet1.3:5"; collapsed=false)

Group the rows `rows` (given as for [`setRowHidden`](@ref); each run of adjacent rows is a
group), as LibreOffice's *Data → Group and Outline → Group* does:
- the group goes inside the deepest group that holds it, and around the groups it holds, which
  go one level deeper; grouping a group's rows again makes a group within it
- groups next to each other stay separate groups, as in LibreOffice
- a range that crosses a group (overlaps it without holding it), or that would nest groups more
  than 7 deep, is an error: LibreOffice refuses both

With `collapsed=true` the group is collapsed: its rows are hidden.

See also [`ungroupRows`](@ref), [`getRowOutlineLevel`](@ref), [`groupColumns`](@ref).
"""
groupRows(ws::Worksheet, rows; collapsed::Bool = false) = _group_lines!(ws, 1, rows, collapsed)
groupRows(xf::ODSFile, ref::AbstractString; collapsed::Bool = false) = groupRows(_hide_sheet(xf, ref)...; collapsed)

"""
    groupColumns(sheet, cols; collapsed=false)
    groupColumns(xf, "Sheet1.B:D"; collapsed=false)

Group the columns `cols`, as [`groupRows`](@ref) groups rows.
"""
groupColumns(ws::Worksheet, cols; collapsed::Bool = false) = _group_lines!(ws, 2, cols, collapsed)
groupColumns(xf::ODSFile, ref::AbstractString; collapsed::Bool = false) = groupColumns(_hide_sheet(xf, ref)...; collapsed)

"""
    ungroupRows(sheet, rows)
    ungroupRows(xf, "Sheet1.3:5")

Remove a level of grouping from the rows `rows`, as LibreOffice does: the groups at the deepest
level the rows meet are removed whole (even where they reach beyond `rows`), and the groups
inside them move up a level. Rows in no group are left alone. Rows a collapsed group hid stay
hidden: show them with [`setRowHidden`](@ref)`(sheet, rows; hidden=false)`.
"""
ungroupRows(ws::Worksheet, rows) = _ungroup_lines!(ws, 1, rows)
ungroupRows(xf::ODSFile, ref::AbstractString) = ungroupRows(_hide_sheet(xf, ref)...)

"""
    ungroupColumns(sheet, cols)
    ungroupColumns(xf, "Sheet1.B:D")

Remove a level of grouping from the columns `cols`, as [`ungroupRows`](@ref) does for rows.
"""
ungroupColumns(ws::Worksheet, cols) = _ungroup_lines!(ws, 2, cols)
ungroupColumns(xf::ODSFile, ref::AbstractString) = ungroupColumns(_hide_sheet(xf, ref)...)

"""
    getRowOutlineLevel(sheet, row) -> Int
    getRowOutlineLevel(xf, "Sheet1.5") -> Int

How many groups hold row `row`: 0 if none. Works on read-only files.
"""
getRowOutlineLevel(ws::Worksheet, row) = _depth_at(sheet_formats(ws).rowgroups, _single_line(ws, 1, row))
getRowOutlineLevel(xf::ODSFile, ref::AbstractString) = getRowOutlineLevel(_hide_sheet(xf, ref)...)

"""
    getColumnOutlineLevel(sheet, col) -> Int
    getColumnOutlineLevel(xf, "Sheet1.C") -> Int

How many groups hold column `col`: 0 if none. Works on read-only files.
"""
getColumnOutlineLevel(ws::Worksheet, col) = _depth_at(sheet_formats(ws).colgroups, _single_line(ws, 2, col))
getColumnOutlineLevel(xf::ODSFile, ref::AbstractString) = getColumnOutlineLevel(_hide_sheet(xf, ref)...)

#
# Writing the containers
#

_groups_touched(ws::Worksheet) = ws.formats !== nothing && ws.formats.groups_touched
_has_groups(f::Union{Nothing,SheetFormats}) = f !== nothing && !(isempty(f.rowgroups) && isempty(f.colgroups) &&
                                                                 f.title_rows === nothing && f.title_cols === nothing)

# Writes a table through `write` into a string, then its groups' containers.
function _with_groups(write::Function, out::IO, f::SheetFormats)
    io = IOBuffer()
    write(io)
    print(out, _regroup(String(take!(io)), f))
    return
end

const _GROUP_TAGS = ("table:table-row-group", "table:table-column-group")
# Containers the rebuilt groups replace too: the print titles' (rebuilt from the sheet's titles, phase 5
# step 10) and plain `table:table-rows`/`-columns`.
const _OTHER_CONTAINERS = ("table:table-header-rows", "table:table-rows", "table:table-header-columns", "table:table-columns")
const _TITLE_DEPTH = 1000                     # the print titles, as the innermost group
_title_tag(k::Int) = k == 1 ? "table:table-header-rows" : "table:table-header-columns"
_close_tag(k::Int, g::LineGroup) = g.depth == _TITLE_DEPTH ? _title_tag(k) : _GROUP_TAGS[k]

mutable struct _Regroup
    t::String
    out::IOBuffer
    pos::Int                       # the next index of t to copy
    n::Vector{Int}                 # lines written so far: [rows, columns]
    groups::Vector{Vector{LineGroup}}
    opened::Vector{Vector{LineGroup}}   # groups open now, outermost first
    done::Vector{Bool}             # all groups of the kind closed
end

_copy!(st::_Regroup, upto::Int) = (upto >= st.pos && print(st.out, SubString(st.t, st.pos, upto)); st.pos = max(st.pos, upto + 1))

function _group_tag(k::Int, g::LineGroup)
    g.depth == _TITLE_DEPTH && return "<" * _title_tag(k) * ">"
    tag = _GROUP_TAGS[k]
    return g.display ? "<$tag>" : "<$tag table:display=\"false\">"
end

# Closes the groups of kind `k` that end before line `p`, then opens those that start at `p`.
function _boundary!(st::_Regroup, k::Int, p::Int)
    op = st.opened[k]
    while !isempty(op) && op[end].last < p
        g = pop!(op)
        print(st.out, "</", _close_tag(k, g), '>')
    end
    for g in st.groups[k]                    # sorted by first line, outermost first
        g.first == p && (push!(op, g); print(st.out, _group_tag(k, g)))
    end
    return
end

# The next line at which a group of kind `k` starts or ends, after line p.
function _next_boundary(st::_Regroup, k::Int, p::Int)
    nb = typemax(Int)
    for g in st.groups[k]
        g.first > p && (nb = min(nb, g.first))
        g.last + 1 > p && (nb = min(nb, g.last + 1))
    end
    return nb
end

# One row or column element (`text`), repeated `count` times from line `st.n[k] + 1`: split
# where groups start or end, with the containers between the pieces.
function _emit_lines!(st::_Regroup, k::Int, text::AbstractString, count::Int)
    key = k == 1 ? "table:number-rows-repeated" : "table:number-columns-repeated"
    p = st.n[k] + 1
    stop = p + count - 1
    while p <= stop
        _boundary!(st, k, p)
        q = min(stop, _next_boundary(st, k, p) - 1)
        m = q - p + 1
        print(st.out, m == count ? text : _retag(text, key, m == 1 ? nothing : m))
        p = q + 1
    end
    st.n[k] = stop
    return
end

# After the last line of kind `k`: lines added up to the groups' end, then every group closed.
function _finish!(st::_Regroup, k::Int)
    st.done[k] && return
    st.done[k] = true
    last = maximum((g.last for g in st.groups[k]); init = 0)
    if last > st.n[k]
        _emit_lines!(st, k, k == 1 ? "<table:table-row><table:table-cell/></table:table-row>" : "<table:table-column/>",
                     last - st.n[k])
    end
    _boundary!(st, k, typemax(Int))
    return
end

# The number of lines of kind `k` a container holds (its own rows or columns: not those of a
# table inside one of its cells).
function _lines_in(ln, k::Int)
    key = k == 1 ? "table:number-rows-repeated" : "table:number-columns-repeated"
    tag = k == 1 ? "table:table-row" : "table:table-column"
    n = 0
    c = XML.Cursor(ln)
    XML.next!(c)
    XML.for_each_child!(c) do ch
        if XML.nodetype(ch) === XML.Element && XML.tag(ch) == tag
            r = 1
            for (a, v) in XML.eachattribute!(ch)
                a == key && (r = _file_count(v, 1, 1, SheetCore.MAX_ROWS))
            end
            n += r
        end
        XML.skip_element!(ch)
    end
    return n
end

function _regroup_children!(st::_Regroup, c)
    XML.for_each_child!(c) do ch
        XML.nodetype(ch) === XML.Element || return
        tg = XML.tag(ch)
        ln = XML.LazyNode(ch)
        sp = XML.sourcespan(ln)
        _copy!(st, first(sp) - 1)                # the text before it, as it was
        if tg in _GROUP_TAGS || tg in _OTHER_CONTAINERS
            # the old container goes: the text between its children is kept
            (tg in ("table:table-header-rows", "table:table-rows")) && _finish!(st, 2)
            text = SubString(st.t, first(sp), last(sp))
            st.pos = first(sp) + _start_tag_end(text)
            if !endswith(text, "/>")
                cc = XML.Cursor(ln)
                XML.next!(cc)
                _regroup_children!(st, cc)
                _copy!(st, last(sp) - ncodeunits("</$tg>"))
            end
            st.pos = last(sp) + 1
        elseif tg == "table:table-column" || tg == "table:table-row"
            k = tg == "table:table-row" ? 1 : 2
            k == 1 && _finish!(st, 2)            # the rows follow the columns
            text = SubString(st.t, first(sp), last(sp))
            r = match(Regex((k == 1 ? "table:number-rows-repeated" : "table:number-columns-repeated") * "=\"(\\d+)\""),
                      SubString(text, 1, _start_tag_end(text)))
            _emit_lines!(st, k, text, r === nothing ? 1 : parse(Int, r.captures[1]))
            st.pos = last(sp) + 1
        else
            # anything else: the lines of a kind end before it
            st.n[1] > 0 && _finish!(st, 1)
            (st.n[2] > 0 || st.n[1] > 0) && _finish!(st, 2)
        end
        XML.skip_element!(ch)
    end
    return
end

"""
    _regroup(t, f) -> String

A table's text `t` with its group containers, and its print titles' header containers, rebuilt from
`f`. The titles are the innermost container: inside a group or apart from it, never holding one
(ODF's header rows hold rows only).
"""
function _regroup(t::String, f::SheetFormats)
    kinds = Vector{LineGroup}[]
    for (k, gs, tr) in ((1, f.rowgroups, f.title_rows), (2, f.colgroups, f.title_cols))
        v = copy(gs)
        if tr !== nothing
            for g in gs
                (_holds(g, first(tr), last(tr)) || !_meets(g, first(tr), last(tr))) ||
                    throw(ODSError("The print-title $(k == 1 ? "rows" : "columns") $tr cross the group $(g.first):$(g.last): " *
                                   "in ODF they must lie inside a group or apart from it."))
            end
            push!(v, LineGroup(first(tr), last(tr), _TITLE_DEPTH, true))
        end
        push!(kinds, sort!(v; by = g -> (g.first, g.depth)))
    end
    c = XML.Cursor(t)
    while XML.next!(c) !== nothing
        XML.nodetype(c) === XML.Element && break
    end
    st = _Regroup(t, IOBuffer(sizehint = ncodeunits(t) + 256), 1, [0, 0], kinds,
                  [LineGroup[], LineGroup[]], [false, false])
    _regroup_children!(st, c)
    _finish!(st, 2)
    _finish!(st, 1)
    endtag = findprev("</table:table>", t, lastindex(t))
    _copy!(st, first(endtag) - 1)
    print(st.out, SubString(t, first(endtag)))
    return String(take!(st.out))
end

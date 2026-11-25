# Conditional formats (phase 7, D-081): the model, reading and clearing. XLSX.jl's
# `getConditionalFormats` and `clearConditionalFormats` on LibreOffice's rules (F-073):
#   - a sheet's rules are the `calcext:conditional-format`s of its table's `calcext:conditional-formats`
#     (its last child), each a target and one or more entries: conditions, dates, colour scales, data
#     bars and icon sets
#   - the model is each format's XML, current: the file's are read on first use (the table's children
#     walked, the rows skipped) and replayed through the operations logged so far with `rewrite_xml`,
#     the patched save's own rewriting; later operations rewrite the list the same way
#   - a patched save replaces the element of a sheet whose rules were edited, and nothing else (D-023);
#     a sheet whose file had rules and has none left keeps an empty element, or LibreOffice would
#     rebuild them from the `style:map`s left in the cells' styles (F-075)
# The API follows XLSX.jl 0.13.4 (src/conditionalformats/read.jl, clear.jl), MIT License, Copyright
# (c) 2018-2026 Felipe Noronha Tavares and other contributors: names, call forms and return shapes.

const CfInfo = NamedTuple{(:type, :priority),Tuple{String,Int64}}

# The elements a table may hold after its conditional formats (LibreOffice writes them last but these).
const _AFTER_CFS = ("calcext:sparkline-groups", "loext:sparkline-groups", "office:event-listeners")

const _CF_RX = r"<calcext:conditional-format\b.*?</calcext:conditional-format>"s

# The formats of an element's text (or of several formats' text).
_cf_split(x::AbstractString) = String[m.match for m in eachmatch(_CF_RX, x)]

# Text through structural operations (`ops`), as the patched save rewrites it; "" if a format's target is gone.
function _cf_rewritten(x::String, ops, sheet::String; withcopy::Bool = false)
    isempty(ops) && return x
    io = IOBuffer()
    rewrite_xml(io, RefRewriter(Any[ops...], x; withcopy), x, 1, ncodeunits(x); sheet)
    return String(take!(io))
end

"""
    _cf_state(ws) -> CfState

The sheet's conditional formats, read from its table on first use: only the element's span is
taken (the rows are skipped); its formats are replayed through the operations so far.
"""
function _cf_state(ws::Worksheet)
    ws.cfs === nothing || return ws.cfs
    lock(ws.lock) do
        ws.cfs === nothing || return ws.cfs
        st = CfState(String[], false, 0:-1, 0)
        if ws.entry !== nothing
            c = XML.Cursor(ws.entry.node)
            XML.next!(c)
            XML.for_each_child!(c) do ch
                XML.nodetype(ch) === XML.Element || return
                tg = XML.tag(ch)
                if tg == "calcext:conditional-formats"
                    st.span = XML.sourcespan(XML.LazyNode(ch))
                elseif st.at == 0 && isempty(st.span) && tg in _AFTER_CFS
                    st.at = first(XML.sourcespan(XML.LazyNode(ch)))
                end
                XML.skip_element!(ch)
            end
            if !isempty(st.span)
                src = parent(XML.sourcetext(ws.entry.node))
                x = String(SubString(src, first(st.span), last(st.span)))
                xf = get_odsfile(ws)
                ops = ws.copied ? xf.ops[ws.opstart+1:end] : xf.ops
                st.list = _cf_split(_cf_rewritten(x, ops, ws.entry.name))
            end
        end
        ws.cfs = st
        return st
    end
end

_cf_edited(ws::Worksheet) = ws.cfs !== nothing && ws.cfs.edited

# The sheet's element as it is to be written: its formats, an empty element when the file had rules
# and none is left (F-075), or nothing.
function _cf_element(st::CfState)
    isempty(st.list) || return "<calcext:conditional-formats>" * join(st.list) * "</calcext:conditional-formats>"
    return isempty(st.span) ? "" : "<calcext:conditional-formats/>"
end

# The splice of a sheet's source text for its edited rules (or none), for the patched writers.
function _cf_splices(ws::Worksheet, src::AbstractString)
    _cf_edited(ws) || return Tuple{Int,Int,String}[]
    st = ws.cfs
    x = _cf_element(st)
    isempty(st.span) || return [(first(st.span), last(st.span), x)]
    isempty(x) && return Tuple{Int,Int,String}[]
    at = st.at > 0 ? st.at : findprev('<', src, last(XML.sourcespan(ws.entry.node)))   # before </table:table>
    return [(at, at - 1, x)]
end

# The rules' references rewritten by a line or sheet operation (`_rewrite_model_refs!`), on every
# sheet whose rules are loaded. Formats whose target is gone are dropped (F-043, F-076).
function _rewrite_cf_refs!(xf::ODSFile, op)
    for ws in _sheets(xf)
        st = ws.cfs
        (st === nothing || isempty(st.list)) && continue
        # (an unedited file sheet's text is rewritten the same way by the patched save)
        st.list = _cf_split(_cf_rewritten(join(st.list), Any[op], ws.name))
    end
    return
end

# A copy's rules (`copysheet!` of a sheet made here): the source's, rewritten by the copy.
function _copy_cfs!(new::Worksheet, ws::Worksheet, op)
    ws.cfs === nothing && return
    isempty(ws.cfs.list) && return
    new.cfs = CfState(_cf_split(_cf_rewritten(join(ws.cfs.list), Any[op], ws.name; withcopy = true)), true, 0:-1, 0)
    return
end

#
# Reading a format: its target and entries
#

# A target's areas (a range list: `CF.B1:CF.K1 CF.D3:CF.D3`), as (rows, cols).
function _cf_areas(target::AbstractString)
    out = Tuple{UnitRange{Int},UnitRange{Int}}[]
    t = String(target)
    for (a, b) in _areas(t)
        ends = parse_ref(SubString(t, a, b))
        (ends === nothing || any(e -> e.err, ends)) && continue
        e1 = ends[1]; e2 = ends[end]
        r1 = e1.row > 0 ? e1.row : 1; c1 = e1.col > 0 ? e1.col : 1
        r2 = e2.row > 0 ? e2.row : SheetCore.MAX_ROWS; c2 = e2.col > 0 ? e2.col : SheetCore.MAX_COLS
        push!(out, (min(r1, r2):max(r1, r2), min(c1, c2):max(c1, c2)))
    end
    return out
end

function _cf_target(x::AbstractString)
    e = _start_tag_end(x)
    v = _attr_in(SubString(x, 1, e), "calcext:target-range-address")
    return v === nothing ? "" : XML.unescape(v)
end

# The entries of a format: (kind, start tag) for each, in order.
const _CF_ENTRY_RX = r"<calcext:(condition|date-is|color-scale|data-bar|icon-set)(?=[\s/>])[^>]*>"
_cf_entries(x::AbstractString) = [(String(m.captures[1]), m.match) for m in eachmatch(_CF_ENTRY_RX, x)]

# XLSX.jl's rule type for an entry (`kind`, its start tag).
function _cf_type(kind::AbstractString, tag::AbstractString)
    kind == "date-is" && return "timePeriod"
    kind == "color-scale" && return "colorScale"
    kind == "data-bar" && return "dataBar"
    kind == "icon-set" && return "iconSet"
    v = something(_attr_in(tag, "calcext:value"), "")
    v = XML.unescape(v)
    if startswith(v, "formula-is(")
        # the import's form of blanks (F-074)
        occursin(r"^formula-is\(LEN\(TRIM\(\[[^\]]*\]\)\)=0\)$", v) && return "containsBlanks"
        occursin(r"^formula-is\(LEN\(TRIM\(\[[^\]]*\]\)\)>0\)$", v) && return "notContainsBlanks"
        return "expression"
    end
    v == "is-error" && return "containsErrors"
    v == "is-no-error" && return "notContainsErrors"
    v == "duplicate" && return "duplicateValues"
    v == "unique" && return "uniqueValues"
    occursin(r"^(top|bottom)-(elements|percent)\(", v) && return "top10"
    occursin(r"^(above|below)(-equal)?-average$", v) && return "aboveAverage"
    startswith(v, "begins-with(") && return "beginsWith"
    startswith(v, "ends-with(") && return "endsWith"
    startswith(v, "contains-text(") && return "containsText"
    startswith(v, "not-contains-text(") && return "notContainsText"
    return "cellIs"
end

function _cf_range(ws::Worksheet, areas)
    rngs = [CellRange(first(a[1]), first(a[2]), last(a[1]), last(a[2])) for a in areas]
    return length(rngs) == 1 ? rngs[1] : NonContiguousRange(ws.name, Union{CellRef,CellRange}[rngs...])
end

#
# The API
#

"""
    getConditionalFormats(sheet) -> Vector{Pair}

The sheet's conditional formats, as XLSX.jl gives them: each rule as `range => (type = "cellIs",
priority = 1)`, `range` a `CellRange`, or a `NonContiguousRange` for several areas. `type` is
XLSX.jl's name for the rule (`"cellIs"`, `"top10"`, `"aboveAverage"`, `"containsText"`,
`"notContainsText"`, `"beginsWith"`, `"endsWith"`, `"timePeriod"`, `"containsErrors"`,
`"notContainsErrors"`, `"containsBlanks"`, `"notContainsBlanks"`, `"uniqueValues"`,
`"duplicateValues"`, `"expression"`, `"dataBar"`, `"colorScale"`, `"iconSet"`).

Rules are in LibreOffice's order, which is their priority (D-081): a range's rules in the order they
were set, and the ranges in the order they were first given rules. `priority` counts from 1 through
the sheet. LibreOffice's own rules and the rules of an imported workbook are read as they are stored.
"""
function getConditionalFormats(ws::Worksheet)
    out = Pair{Union{CellRange,NonContiguousRange},CfInfo}[]
    p = 0
    for x in _cf_state(ws).list
        areas = _cf_areas(_cf_target(x))
        isempty(areas) && continue
        rng = _cf_range(ws, areas)
        for (kind, tag) in _cf_entries(x)
            p += 1
            push!(out, rng => (type = _cf_type(kind, tag), priority = Int64(p)))
        end
    end
    return out
end

"""
    clearConditionalFormats(sheet, rng) -> Int
    clearConditionalFormats(sheet, :) -> Int

Remove every conditional format whose range lies entirely within `rng` (a cell, a range, whole
columns `"B:D"` or rows `"2:5"`, several of these separated by commas, or a `CellRange`), as
XLSX.jl does, and return the number of rules removed. A format spanning a wider range is left alone,
even where it overlaps. With `:`, every rule on the sheet goes. The file must be writable.
"""
function clearConditionalFormats(ws::Worksheet, rng)
    _require_writable(ws, "clear conditional formats")
    target = rng isa Colon ? _Area[(1:SheetCore.MAX_ROWS, 1:SheetCore.MAX_COLS)] : _cf_blocks(ws, rng)
    within(a) = isempty(foldl((rest, b) -> [p for x in rest for p in _area_minus(x, b)], target; init = _Area[a]))
    st = _cf_state(ws)
    n = 0
    keep = String[]
    for x in st.list
        areas = _cf_areas(_cf_target(x))
        if !isempty(areas) && all(within, areas)
            n += length(_cf_entries(x))
        else
            push!(keep, x)
        end
    end
    if n > 0
        st.list = keep
        st.edited = true
    end
    return n
end

# The blocks a range names on a sheet, as (rows, cols) (the forms of `format_targets`).
function _cf_blocks(ws::Worksheet, rng)
    out = _Area[]
    for (w, blocks) in format_targets(ws, rng)
        w === ws || throw(ODSError("The range names another sheet than `$(ws.name)`."))
        for b in blocks
            push!(out, b.kind === :cells ? (b.rows, b.cols) : b.kind === :rows ? (b.rows, 1:SheetCore.MAX_COLS) : (1:SheetCore.MAX_ROWS, b.cols))
        end
    end
    isempty(out) && throw(ODSError("The range names no cells."))
    return out
end

# Whether a file has rules a new or patched content.xml writes, so that it declares `calcext`.
_has_cfs(xf::ODSFile) = any(ws -> ws.cfs !== nothing && (ws.cfs.edited || ws.entry === nothing) && !isempty(ws.cfs.list), _sheets(xf))

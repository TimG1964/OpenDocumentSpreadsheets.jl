# Sparklines (phase 8 step 8, D-085, D-086): the model, kept as conditional formats are (D-081). A
# sheet's groups are the `calcext:sparkline-group`s of its table's `calcext:sparkline-groups`, which
# LibreOffice writes last (F-084). The file's are read on first use and replayed through the operations
# logged so far; later operations rewrite them the same way (Q-029 option 2: a sparkline goes with its
# cell, its data moves as a chart's does; `_new_attr_values`). A patched save replaces the element of a
# sheet whose sparklines were edited, and nothing else (D-023). The API is `Charts`' (`sparklines.jl`).

const _SPARK_GROUP_RX = r"<calcext:sparkline-group\b.*?</calcext:sparkline-group>"s
const _SPARK_TAGS = ("calcext:sparkline-groups", "loext:sparkline-groups")

# A group's text without the sparklines a rewrite dropped; a group left with none goes.
function _spark_split(x::AbstractString)
    out = String[]
    for m in eachmatch(_SPARK_GROUP_RX, x)
        occursin("<calcext:sparkline ", m.match) && push!(out, String(m.match))
    end
    return out
end

"""
    _spark_state(ws) -> SparkState

The sheet's sparkline groups, read from its table on first use (the rows skipped), replayed through
the operations so far.
"""
function _spark_state(ws::Worksheet)
    ws.sparks === nothing || return ws.sparks
    lock(ws.lock) do
        ws.sparks === nothing || return ws.sparks
        st = SparkState(String[], false, 0:-1, 0)
        if ws.entry !== nothing
            c = XML.Cursor(ws.entry.node)
            XML.next!(c)
            XML.for_each_child!(c) do ch
                XML.nodetype(ch) === XML.Element || return
                tg = XML.tag(ch)
                if tg in _SPARK_TAGS
                    st.span = XML.sourcespan(XML.LazyNode(ch))
                elseif st.at == 0 && isempty(st.span) && tg == "office:event-listeners"
                    st.at = first(XML.sourcespan(XML.LazyNode(ch)))
                end
                XML.skip_element!(ch)
            end
            if !isempty(st.span)
                src = parent(XML.sourcetext(ws.entry.node))
                x = String(SubString(src, first(st.span), last(st.span)))
                x = replace(x, "loext:sparkline" => "calcext:sparkline")        # an older LibreOffice's prefix
                xf = get_odsfile(ws)
                ops = ws.copied ? xf.ops[ws.opstart+1:end] : xf.ops
                st.list = _spark_split(_cf_rewritten(x, ops, ws.entry.name))
            end
        end
        ws.sparks = st
        return st
    end
end

_spark_edited(ws::Worksheet) = ws.sparks !== nothing && ws.sparks.edited
_has_sparks(xf::ODSFile) = any(ws -> ws.sparks !== nothing && (ws.sparks.edited || ws.entry === nothing) && !isempty(ws.sparks.list), _sheets(xf))

_spark_element(st::SparkState) = isempty(st.list) ? "" : "<calcext:sparkline-groups>" * join(st.list) * "</calcext:sparkline-groups>"

# The splice of a sheet's source text for its edited sparklines (or none), for the patched writers:
# after its conditional formats', before the table's end.
function _spark_splices(ws::Worksheet, src::AbstractString)
    _spark_edited(ws) || return Tuple{Int,Int,String}[]
    st = ws.sparks
    x = _spark_element(st)
    isempty(st.span) || return [(first(st.span), last(st.span), x)]
    isempty(x) && return Tuple{Int,Int,String}[]
    at = st.at > 0 ? st.at : findprev('<', src, last(XML.sourcespan(ws.entry.node)))   # before </table:table>
    return [(at, at - 1, x)]
end

# The groups rewritten by a line or sheet operation (`_rewrite_model_refs!`), on every sheet whose
# sparklines are loaded; a sparkline whose cell is gone goes, and a group left empty.
function _rewrite_spark_refs!(xf::ODSFile, op)
    for ws in _sheets(xf)
        st = ws.sparks
        (st === nothing || isempty(st.list)) && continue
        st.list = _spark_split(_cf_rewritten(join(st.list), Any[op], ws.name))
    end
    return
end

# A copy's sparklines (`copysheet!` of a sheet made here): the source's, rewritten by the copy (their
# cells on the copy, their data where it was, as LibreOffice's copies keep it, F-084).
function _copy_sparks!(new::Worksheet, ws::Worksheet, op)
    (ws.sparks === nothing || isempty(ws.sparks.list)) && return
    new.sparks = SparkState(_spark_split(_cf_rewritten(join(ws.sparks.list), Any[op], ws.name; withcopy = true)), true, 0:-1, 0)
    return
end

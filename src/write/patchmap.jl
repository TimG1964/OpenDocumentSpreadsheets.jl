# The patched save of a sheet whose rows or columns were inserted or deleted (phase 5, D-049).
#
# The original table is walked as `_walk!` walks it, but each original row and column element is
# placed through the sheet's index maps (`ws.rowmap`, `ws.colmap`):
#   - lines that were deleted are left out (repeat counts shortened)
#   - lines inserted since are written from the model where they now fall; at a row or column
#     container's first line (header rows, groups) they go before the container (F-043)
#   - every original cell is copied verbatim at its new place, with its references replayed through
#     the operations from its original position (src/write/rewrite.jl)
#   - edited cells, restyled blocks and merges the operations changed are written from the model, as
#     in an ordinary patched save (D-023, D-038)

_pieces(m::Union{Nothing,IndexMap}, o0::Int, n::Int) = m === nothing ? [(o0, n, o0)] : line_pieces(m, o0, o0 + n - 1)

# The lines a row or column container covers in the original (repeats summed, nested ones too).
function _count_lines(node::XML.LazyNode, cols::Bool)
    linetag = cols ? "table:table-column" : "table:table-row"
    key = cols ? "table:number-columns-repeated" : "table:number-rows-repeated"
    conts = cols ? _COL_CONTAINERS : _ROW_CONTAINERS
    n = 0
    c = XML.Cursor(node)
    XML.next!(c)
    XML.for_each_child!(c) do ch
        XML.nodetype(ch) === XML.Element || return
        t = XML.tag(ch)
        if t == linetag
            k = 1
            for (a, v) in XML.eachattribute!(ch)
                a == key && (k = max(1, something(tryparse(Int, v), 1)))
            end
            n += k
        elseif t in conts
            n += _count_lines(XML.LazyNode(ch), cols)
        end
        XML.skip_element!(ch)
    end
    return n
end

# Rows a:b (current numbers) that have no original: from the model, with empty rows where it has
# nothing.
function _write_inserted_rows!(st::_PatchState, a::Int, b::Int)
    a > b && return
    write_model_rows(st.out, st.store, st.fmt, st.styles, a; display = st.display, upto = b, pad = true)
    return
end

# After the last original row: the model's rows from there on.
function _write_new_rows_mapped!(st::_PatchState, at::Function)
    st.new_rows_written && return
    st.new_rows_written = true
    _copy_to!(st, at())
    write_model_rows(st.out, st.store, st.fmt, st.styles, st.nextrow; display = st.display)
    return
end

function _walk_mapped!(st::_PatchState, node::XML.LazyNode, level::Symbol)
    rm = st.ws.rowmap
    cm = st.ws.colmap
    c = XML.Cursor(node)
    XML.next!(c)
    d = XML.depth(c)
    rows_end = 0              # after an early stop: where the original rows end (new rows go there)
    while XML.next!(c) !== nothing && XML.depth(c) > d
        ch = c
        XML.nodetype(ch) === XML.Element || continue
        t = XML.tag(ch)
        if t == "table:table-column"
            orig = _line_attrs(ch, st.styles, "table:number-columns-repeated")
            ln = XML.LazyNode(ch)
            sp = XML.sourcespan(ln)
            n = clamp(orig[1], 1, max(1, SheetCore.MAX_COLS - st.ocol))
            _copy_to!(st, first(sp))
            text = SubString(st.src, first(sp), last(sp))
            for (o, len, cc) in _pieces(cm, st.ocol + 1, n)
                if cc > st.ncols + 1                     # inserted columns before these
                    write_columns(st.out, st.fmt.cols, st.styles, st.ncols + 1, cc - 1)
                end
                print(st.out, _patched_columns(st, text, orig, cc, cc + len - 1))
                st.ncols = cc + len - 1
            end
            st.pos = nextind(st.src, last(sp))
            st.ocol += n
        elseif t in _COL_CONTAINERS
            ln = XML.LazyNode(ch)
            sp = XML.sourcespan(ln)
            k = _count_lines(ln, true)
            ps = _pieces(cm, st.ocol + 1, k)
            _copy_to!(st, first(sp))
            if isempty(ps)                               # all its columns deleted: the container goes
                st.pos = nextind(st.src, last(sp))
                st.ocol += k
            else
                cc = ps[1][3]
                if cc > st.ncols + 1
                    write_columns(st.out, st.fmt.cols, st.styles, st.ncols + 1, cc - 1)
                    st.ncols = cc - 1
                end
                _walk_mapped!(st, ln, :cols)
            end
        elseif t == "table:table-row"
            orig = _line_attrs(ch, st.styles, "table:number-rows-repeated")
            ln = XML.LazyNode(ch)
            sp = XML.sourcespan(ln)
            level === :table && _before_rows!(st, () -> first(sp))
            if level === :table && cm === nothing
                # every row from here on only moves: counted by bytes and left in the gap, unvisited
                r = _rest_only_moves(st, rm, first(sp), node)
                if r !== nothing
                    st.orow += r[1]
                    st.nextrow += r[1]
                    rows_end = r[2]
                    break
                end
            end
            cnt = max(1, min(orig[1], SheetCore.MAX_ROWS - st.orow))
            ps = _pieces(rm, st.orow + 1, cnt)
            if cm === nothing && length(ps) == 1 && ps[1][2] == cnt && ps[1][3] == st.nextrow &&
               !_any_edit(st, st.nextrow, st.nextrow + cnt - 1)
                # a row that only moves: ODF rows carry no number, so it is copied with the gap (its
                # formulas get their row from `posrow`)
                st.orow += cnt
                st.nextrow += cnt
            else
                _copy_to!(st, first(sp))
                text = SubString(st.src, first(sp), last(sp))
                for (o, n, cr) in ps
                    cr > st.nextrow && _write_inserted_rows!(st, st.nextrow, cr - 1)
                    _mapped_rows!(st, ln, text, o, n, cr, orig)
                    st.nextrow = cr + n
                end
                st.pos = nextind(st.src, last(sp))
                st.orow += cnt
                st.posrow = st.orow
            end
        elseif t in _ROW_CONTAINERS
            ln = XML.LazyNode(ch)
            sp = XML.sourcespan(ln)
            level === :table && _before_rows!(st, () -> first(sp))
            k = _count_lines(ln, false)
            ps = _pieces(rm, st.orow + 1, k)
            _copy_to!(st, first(sp))
            if isempty(ps)                               # all its rows deleted: the container goes
                st.pos = nextind(st.src, last(sp))
                st.orow += k
                st.posrow = st.orow
            else
                cr = ps[1][3]
                cr > st.nextrow && _write_inserted_rows!(st, st.nextrow, cr - 1)    # before the container
                st.nextrow = max(st.nextrow, cr)
                _walk_mapped!(st, ln, :rows)
            end
        else
            if level === :table && st.rows_started
                sp = XML.sourcespan(XML.LazyNode(ch))
                _write_new_rows_mapped!(st, () -> first(sp))
            end
        end
        XML.skip_element!(ch)
    end
    if level === :table
        sp = XML.sourcespan(node)
        endtag = findprev('<', st.src, last(sp))
        _before_rows!(st, () -> endtag)
        _write_new_rows_mapped!(st, () -> rows_end > 0 ? rows_end : endtag)
    end
    return
end

# When every original row from the one at `a` on keeps its place relative to the others (the last
# segment of the row map reaches it, nothing is edited after it, none is pushed off the sheet):
# (the number of those rows, where they end), found by bytes; else nothing.
function _rest_only_moves(st::_PatchState, rm::Union{Nothing,IndexMap}, a::Int, node::XML.LazyNode)
    rm === nothing && return nothing
    seg = rm.segs[end]
    o1 = st.orow + 1
    (seg[1] <= o1 && seg[3] + (o1 - seg[1]) == st.nextrow) || return nothing
    (isempty(st.erows) || last(st.erows[end]) < st.nextrow) || return nothing
    src = st.src
    tend = last(XML.sourcespan(node))
    k = findprev("</table:table-row>", src, tend)
    (k === nothing || first(k) < a) && return nothing
    z = last(k) + 1
    while true                    # past white space and the end tags of row containers
        while z <= tend && isspace(src[z])
            z = nextind(src, z)
        end
        hit = false
        for ct in ("</table:table-row-group>", "</table:table-header-rows>", "</table:table-rows>")
            if startswith(SubString(src, z, tend), ct)
                z += ncodeunits(ct)
                hit = true
                break
            end
        end
        hit || break
    end
    s = findnext("<table:table ", src, a)            # a table inside a cell: its rows are not the sheet's
    (s !== nothing && first(s) < z) && return nothing
    n = 0
    i = a
    while (r = findnext("<table:table-row", src, i)) !== nothing && first(r) < z
        nx = src[last(r) + 1]
        if nx == ' ' || nx == '>' || nx == '/'
            e = first(r) - 1 + _start_tag_end(SubString(src, first(r), z))
            n += max(1, _attr_int(SubString(src, first(r), e), "table:number-rows-repeated", 1))
            i = e + 1
        else
            i = last(r) + 1
        end
    end
    st.orow + n <= seg[1] + seg[2] - 1 || return nothing      # rows pushed off the end: walked
    return n, z
end

# Original rows o … o+n-1 (alike), now rows cr … cr+n-1: cut where the edits or the model change,
# each part written by `_write_row_mapped!`.
function _mapped_rows!(st::_PatchState, ln::XML.LazyNode, text::SubString{String}, o::Int, n::Int, cr::Int, orig)
    r0 = cr; r1 = cr + n - 1
    f = st.fmt
    bps = Int[]
    lo = searchsortedfirst(st.drows, r0)
    hi = searchsortedlast(st.drows, r1)
    for k in lo:hi
        push!(bps, st.drows[k], st.drows[k] + 1)
    end
    for (rr, _) in f.rects
        push!(bps, first(rr), last(rr) + 1)
    end
    for tr in f.rows_touched
        push!(bps, first(tr), last(tr) + 1)
    end
    _row_bounds!(bps, st.store.rows, r0, r1)
    _row_bounds!(bps, f.cells, r0, r1)
    _row_bounds!(bps, f.rows, r0, r1)
    pts = _segment_points(bps, r0, r1)
    for k in 1:length(pts)-1
        a = pts[k]; m = pts[k + 1] - a
        cols = _edited_cols(st, a)
        rf = _fmt_at(f.rows, a)
        changes = _line_changes(orig, something(rf, _blank(RowFormat, a, m)), st.styles)
        oa = o + (a - cr)
        if st.ws.colmap === nothing && isempty(cols) && isempty(changes)
            # the original row as it is: only its references (and its repeat count) may change
            _emit(st, m == orig[1] ? text : _retag(text, "table:number-rows-repeated", m); row = oa, orig = _span(text))
        else
            _write_row_mapped!(st, ln, text, oa, a, m, cols, changes)
        end
    end
    return
end

# Rows a … a+m-1 (alike; original row `orow`): the original cells at their new columns (through the
# column map), edited and inserted columns from the model.
function _write_row_mapped!(st::_PatchState, ln::XML.LazyNode, text::SubString{String}, orow::Int, a::Int, m::Int,
                            cols::Vector{UnitRange{Int}}, changes::_AttrChanges)
    src = st.src
    out = st.out
    cm = st.ws.colmap
    e = _start_tag_end(text)
    selfclosing = text[prevind(text, e)] == '/'
    rf = _fmt_at(st.fmt.rows, a)
    rowdefault = rf !== nothing ? rf.default >= 0 : any(((k, _),) -> k == "table:default-cell-style-name", _raw_attrs(text))
    print(out, _set_attrs(_retag(text, "table:number-rows-repeated", m; open = true), changes; open = true))
    ci = 1                     # the next edited range
    cur = 1                    # the next column to write (current numbers)
    ocol = 1                   # the original column of the next cell
    off = first(XML.sourcespan(ln)) - 1
    lpos = off + nextind(text, e)
    endidx = off + lastindex(text)
    done = false               # the rest of the row was copied in one piece
    lastseg = cm === nothing || isempty(cm.segs) ? nothing : cm.segs[end]
    noclip = rf !== nothing && rf.ncells < SheetCore.MAX_COLS
    if !selfclosing
        c = XML.Cursor(ln)
        XML.next!(c)
        d = XML.depth(c)
        while XML.next!(c) !== nothing && XML.depth(c) > d
            ch = c
            XML.nodetype(ch) === XML.Element || continue
            csp = XML.sourcespan(XML.LazyNode(ch))
            first(csp) > lpos && print(out, SubString(src, lpos, prevind(src, first(csp))))
            celltext = SubString(src, first(csp), last(csp))
            t = XML.tag(ch)
            # the rest of the row only moves (the last segment of the column map; nothing edited,
            # clipped or referring there): the columns inserted before it from the model, then the
            # rest as it is, end tag included
            tpc = lastseg === nothing ? 0 : lastseg[3] + (ocol - lastseg[1])
            if lastseg !== nothing && noclip && lastseg[1] <= ocol && tpc >= cur &&
               all(r -> last(r) < tpc, @view(cols[ci:end])) && (st.rw === nothing || !_has_hits(st.rw, first(csp), endidx))
                tpc > cur && _write_model_cols!(st, a, cur, tpc - 1, nothing, rowdefault)
                print(out, SubString(src, first(csp), endidx))
                done = true
                break
            end
            if t == "table:table-cell" || t == "table:covered-table-cell"
                k = max(1, _attr_int(celltext, "table:number-columns-repeated", 1))
                k = min(k, SheetCore.MAX_COLS - ocol + 1)
                if k > 0
                    ex = nothing; exread = false          # the cell's extras, read when an edit reaches it
                    for (po, plen, pc) in _pieces(cm, ocol, k)
                        pc > cur && _write_model_cols!(st, a, cur, pc - 1, nothing, rowdefault)   # inserted columns
                        x = pc
                        y1 = pc + plen - 1
                        while x <= y1
                            while ci <= length(cols) && last(cols[ci]) < x
                                ci += 1
                            end
                            if ci <= length(cols) && first(cols[ci]) <= x
                                y = min(last(cols[ci]), y1)
                                if !exread
                                    ex = _extras_possible(st) && _maybe_extras(celltext) ? _cell_extras(src, XML.LazyNode(ch), celltext) : nothing
                                    exread = true
                                end
                                if ex === nothing
                                    _write_model_cols!(st, a, x, y, celltext, rowdefault)
                                else
                                    _write_model_cols!(st, a, x, y, celltext, rowdefault, ex, orow, po + (x - pc))
                                end
                            else
                                y = ci <= length(cols) ? min(first(cols[ci]) - 1, y1) : y1
                                cnt = y - x + 1
                                _emit(st, cnt == k ? celltext : _retag(celltext, "table:number-columns-repeated", cnt);
                                      row = orow, col = po + (x - pc), orig = _span(celltext))
                            end
                            x = y + 1
                        end
                        cur = y1 + 1
                    end
                    ocol += k
                end
            else
                _emit(st, celltext; row = orow)
            end
            lpos = nextind(src, last(csp))
            XML.skip_element!(ch)
        end
    end
    done && return                 # the rest, end tag included, was copied
    # beyond the original cells: the model's cells there (inserted or moved columns, edits)
    lastm =max(_lastcol(_runs_of(st.store.rows, a)), _lastcol(_runs_of(st.fmt.cells, a)), rf === nothing ? 0 : Int(rf.ncells))
    if cm !== nothing
        lastm >= cur && _write_model_cols!(st, a, cur, lastm, nothing, rowdefault)
    else
        while ci <= length(cols)
            x = max(first(cols[ci]), cur); y = min(last(cols[ci]), lastm)
            if y >= x
                x > cur && write_cell(out, nothing, st.styles; repeat = x - cur)
                _write_model_cols!(st, a, x, y, nothing, rowdefault)
                cur = y + 1
            end
            ci += 1
        end
    end
    if selfclosing
        print(out, "</table:table-row>")
    else
        print(out, SubString(src, lpos, off + lastindex(text)))
    end
    return
end

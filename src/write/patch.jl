# Saving a file that was read: patch its content.xml (D-023).
#
# Everything is copied from the original text, verbatim, except:
#   - a sheet with edits: its table:table is rebuilt from the original, child by child. Rows
#     without edits, and every element that is not a row, are copied as they are. A row
#     element that covers edited rows is split around them (number-rows-repeated), and an
#     edited row is rewritten cell by cell: untouched cells are copied (with their
#     number-columns-repeated split where needed), edited cells are written from the store.
#     Rows and columns beyond the original ones are added after the last row / column.
#   - new sheets, added after the last sheet
#   - OpenDocumentSpreadsheets's typed and formatting styles, added to office:automatic-styles; named
#     styles (D-045) are added to styles.xml (`patched_styles`), or to a flat file's office:styles
#   - namespace declarations the new XML needs, added to the root element
# Original text is reached through XML.jl's `sourcespan` (zero-copy, D-009).

# The index of the `>` that ends the start tag at the beginning of `text`.
function _start_tag_end(text::AbstractString)
    q = '\0'
    for i in eachindex(text)
        c = text[i]
        if q != '\0'
            c == q && (q = '\0')
        elseif c == '"' || c == '\''
            q = c
        elseif c == '>'
            return i
        end
    end
    throw(ODSError("Malformed XML: a start tag is not closed."))
end

const _ATTR_RX = r"([^\s=/<>]+)\s*=\s*(\"[^\"]*\"|'[^']*')"

# The raw attributes of the start tag of `text`: (name, quoted value as written).
_raw_attrs(text::AbstractString) =
    [(String(m.captures[1]), String(m.captures[2])) for m in eachmatch(_ATTR_RX, SubString(text, 1, _start_tag_end(text)))]

function _attr_int(text::AbstractString, name::AbstractString, default::Int)
    # the attribute in the start tag, preceded by white space and followed by `=` and a quote
    e = _start_tag_end(text)
    tag = SubString(text, 1, e)
    i = 1
    while (r = findnext(name, tag, i)) !== nothing
        p = prevind(tag, first(r))
        q = nextind(tag, last(r))
        if p >= 1 && isspace(tag[p])
            while q <= ncodeunits(tag) && isspace(tag[q]); q = nextind(tag, q); end
            if q <= ncodeunits(tag) && tag[q] == '='
                q = nextind(tag, q)
                while q <= ncodeunits(tag) && isspace(tag[q]); q = nextind(tag, q); end
                if q <= ncodeunits(tag) && (tag[q] == '"' || tag[q] == '\'')
                    z = findnext(tag[q], tag, nextind(tag, q))
                    z === nothing && return default
                    return something(tryparse(Int, strip(SubString(tag, nextind(tag, q), prevind(tag, z)))), default)
                end
            end
        end
        i = nextind(tag, last(r))
    end
    return default
end

_tag_name(text::AbstractString) = match(r"^<([^\s/>]+)", text).captures[1]

"""
    _retag(text, name, value; open=false) -> String

`text`, an element's source, with attribute `name` of its start tag set to `value`
(removed when `value` is `nothing` or 1, its default). The other attributes keep their
original text. With `open=true`, only the start tag is returned, as an opening tag even if
the element was self-closing.
"""
function _retag(text::AbstractString, name::AbstractString, value::Union{Nothing,Integer}; open::Bool = false)
    e = _start_tag_end(text)
    selfclosing = text[prevind(text, e)] == '/'
    io = IOBuffer()
    print(io, '<', _tag_name(text))
    for (k, v) in _raw_attrs(text)
        k == name || print(io, ' ', k, '=', v)
    end
    (value === nothing || value == 1) || print(io, ' ', name, "=\"", value, '"')
    if open
        print(io, '>')
    else
        print(io, selfclosing ? "/>" : ">")
        print(io, SubString(text, nextind(text, e)))
    end
    return String(take!(io))
end

"""
    _set_attrs(text, changes; open=false) -> String

`text`, an element's source, with the attributes of its start tag changed: each
`name => value` of `changes` replaces that attribute's value in place (`value` written as
is: already escaped), or removes it when `value === nothing`; new attributes go at the end.
The other attributes keep their original text. With `open=true`, only the start tag is
returned, as an opening tag.
"""
function _set_attrs(text::AbstractString, changes::Vector{Pair{String,Union{Nothing,String}}}; open::Bool = false)
    isempty(changes) && !open && return String(text)
    e = _start_tag_end(text)
    selfclosing = text[prevind(text, e)] == '/'
    used = falses(length(changes))
    io = IOBuffer()
    print(io, '<', _tag_name(text))
    for (k, v) in _raw_attrs(text)
        i = findfirst(p -> p.first == k, changes)
        if i === nothing
            print(io, ' ', k, '=', v)
        else
            used[i] = true
            nv = changes[i].second
            nv === nothing || print(io, ' ', k, "=\"", nv, '"')
        end
    end
    for (i, (k, v)) in enumerate(changes)
        used[i] || v === nothing || print(io, ' ', k, "=\"", v, '"')
    end
    if open
        print(io, '>')
    else
        print(io, selfclosing ? "/>" : ">")
        print(io, SubString(text, nextind(text, e)))
    end
    return String(take!(io))
end

mutable struct _PatchState
    ws::Worksheet
    store::SheetStore
    styles::StyleIndex
    src::String
    out::_ChunkedIO                # the document being written (D-048)
    pos::Int                       # the next index of src to copy
    nextrow::Int                   # the row number of the next table:table-row
    ncols::Int                     # columns defined so far
    need_cols::Int                 # columns the edits reach
    rows_started::Bool
    new_rows_written::Bool
    drows::Vector{Int}             # rows with edited cells, sorted
    dcols::Dict{Int,Vector{Int}}   # edited columns of each such row, sorted
    erows::Vector{UnitRange{Int}}  # every edited row (cells, restyled blocks, row formats), sorted, disjoint
    fmt::Union{Nothing,SheetFormats}   # the sheet's formats, if read
    display::Bool                  # write display text in typed cells (D-029)
    # phase 5: structural edits (D-049)
    rw::Union{Nothing,RefRewriter} # the operations to replay on copied text, or nothing
    sheetname::String              # the sheet's name in the original text
    orow::Int                      # original rows walked so far (the mapped walk)
    ocol::Int                      # original columns walked so far
    posrow::Int                    # original rows before `pos` (the mapped walk; -1 elsewhere)
    extras::Int8                   # whether the original table may hold cell extras (D-071): 1, 0, or -1 unknown yet
    tested::Int                    # cells given the quick test while unknown
    tspan::UnitRange{Int}          # the original table, in src
end

# Copies original text to the output: as it is, or with its references replayed through the
# operations (phase 5). `row`/`col`: the original position of the cell the text is, if any.
# `orig`: where in the source a text made from it (a retagged element) came from.
function _emit(st::_PatchState, s::AbstractString; row::Int = 0, col::Int = 0, orig::Union{Nothing,UnitRange{Int}} = nothing)
    rw = st.rw
    if rw === nothing
        print(st.out, s)
    elseif s isa SubString{String} && parent(s) === rw.src
        r = parentindices(s)[1]
        rewrite_xml(st.out, rw, rw.src, first(r), last(r); sheet = st.sheetname, row, col)
    elseif orig !== nothing && !_has_hits(rw, first(orig), last(orig))
        print(st.out, s)
    else
        t = String(s)
        rewrite_xml(st.out, rw, t, 1, ncodeunits(t); sheet = st.sheetname, row, col)
    end
    return
end

_span(s::SubString{String}) = parentindices(s)[1]

function _copy_to!(st::_PatchState, idx::Int)
    if idx > st.pos
        if st.rw === nothing
            print(st.out, SubString(st.src, st.pos, prevind(st.src, idx)))
        else
            rewrite_xml(st.out, st.rw, st.src, st.pos, prevind(st.src, idx); sheet = st.sheetname, rowbase = st.posrow)
        end
    end
    st.pos = max(st.pos, idx)
    st.posrow >= 0 && (st.posrow = st.orow)
    return
end

# Whether a column in a:b has a default cell style (in the output).
_col_default(st::_PatchState, a::Int, b::Int) = st.fmt !== nothing ? _any_col_default(st.fmt.cols, a, b) :
    any(cr -> cr.default_style >= 0 && cr.col <= b && a <= cr.col + cr.count - 1, st.store.cols)

# Untouched text is not copied element by element: `st.pos` stays behind it, and it is
# copied in one piece when something must be written after it (`_copy_to!`). Only the
# elements that change, and the places where something is inserted, need their position.

# Before the first row (at src index `at`): add the columns the edits need beyond the
# defined ones.
function _before_rows!(st::_PatchState, at::Function)
    st.rows_started && return
    st.rows_started = true
    f = st.fmt
    need = st.need_cols
    if f !== nothing && f.cols_touched && !isempty(f.cols)
        need = max(need, _stop(f.cols[end]))
    end
    if need > st.ncols
        _copy_to!(st, at())
        f === nothing ? write_columns(st.out, ColFormat[], st.styles, st.ncols + 1, need) :
                        write_columns(st.out, f.cols, st.styles, st.ncols + 1, need)
        st.ncols = need
    end
end

# The last row with content in the model (stored cells, formatted cells, row formats).
function _model_last_row(st::_PatchState)
    r = isempty(st.store.rows) ? 0 : _lastrow(st.store.rows[end])
    f = st.fmt
    if f !== nothing
        isempty(f.cells) || (r = max(r, _lastrow(f.cells[end])))
        i = length(f.rows)
        while i >= 1 && _isblank(f.rows[i])
            i -= 1
        end
        i >= 1 && (r = max(r, _stop(f.rows[i])))
    end
    return max(r, _val_lastrow(st.ws))
end

# After the last original row (at src index `at`): the rows of the model beyond it (all of
# them edits).
function _write_new_rows!(st::_PatchState, at::Function)
    st.new_rows_written && return
    st.new_rows_written = true
    # once the walk is past the last edit it stops counting rows: then nothing is new
    _past_edits(st) && return
    _model_last_row(st) >= st.nextrow || return
    _copy_to!(st, at())
    if st.fmt === nothing
        i = _first_row_index(st.store, st.nextrow)
        write_rows(st.out, @view(st.store.rows[i:end]), st.styles, st.nextrow; st.display)
    else
        write_model_rows(st.out, st.store, st.fmt, st.styles, st.nextrow; st.display, ws = st.ws)
    end
end

# Whether a row in a:b is edited.
function _any_edit(st::_PatchState, a::Int, b::Int)
    v = st.erows
    lo, hi = 1, length(v)
    while lo <= hi                               # the first range ending at or after a
        mid = (lo + hi) >>> 1
        if last(v[mid]) < a
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    return lo <= length(v) && first(v[lo]) <= b
end

# Whether every edit is behind the walk: the rest of the table can be copied as it is.
_past_edits(st::_PatchState) = st.rows_started && (isempty(st.erows) || st.nextrow > last(st.erows[end]))

function _walk!(st::_PatchState, node::XML.LazyNode, level::Symbol)
    c = XML.Cursor(node)
    XML.next!(c)
    XML.for_each_child!(c) do ch
        XML.nodetype(ch) === XML.Element || return
        if _past_edits(st)                      # copied with the rest, at the end
            XML.skip_element!(ch)
            return
        end
        t = XML.tag(ch)
        repeat = 1
        if t == "table:table-row" || t == "table:table-column"
            key = t == "table:table-row" ? "table:number-rows-repeated" : "table:number-columns-repeated"
            for (k, v) in XML.eachattribute!(ch)
                k == key && (repeat = something(tryparse(Int, v), 1))
            end
        end
        start() = first(XML.sourcespan(XML.LazyNode(ch)))
        if t == "table:table-column"
            if st.fmt !== nothing && st.fmt.cols_touched
                ln = XML.LazyNode(ch)
                sp = XML.sourcespan(ln)
                text = SubString(st.src, first(sp), last(sp))
                n = clamp(repeat, 1, max(1, SheetCore.MAX_COLS - st.ncols))
                new = _patched_columns(st, text, _line_attrs(ch, st.styles, "table:number-columns-repeated"), st.ncols + 1, st.ncols + n)
                if new != text
                    _copy_to!(st, first(sp))
                    print(st.out, new)
                    st.pos = nextind(st.src, last(sp))
                end
            end
            st.ncols += repeat
        elseif t in _COL_CONTAINERS
            _walk!(st, XML.LazyNode(ch), :cols)
        elseif t == "table:table-row"
            level === :table && _before_rows!(st, start)
            r0 = st.nextrow
            cnt = max(1, min(repeat, SheetCore.MAX_ROWS - r0 + 1))
            if !_any_edit(st, r0, r0 + cnt - 1)
                st.nextrow = r0 + cnt                   # untouched: left in the gap
            else
                ln = XML.LazyNode(ch)
                sp = XML.sourcespan(ln)
                _copy_to!(st, first(sp))
                _patch_row!(st, ln, SubString(st.src, first(sp), last(sp)), cnt,
                            st.fmt === nothing ? nothing : _line_attrs(ch, st.styles, "table:number-rows-repeated"))
                st.pos = nextind(st.src, last(sp))
            end
        elseif t in _ROW_CONTAINERS
            level === :table && _before_rows!(st, start)
            _walk!(st, XML.LazyNode(ch), :rows)
        else
            level === :table && st.rows_started && _write_new_rows!(st, start)
        end
        XML.skip_element!(ch)
    end
    if level === :table
        sp = XML.sourcespan(node)
        endtag = findprev('<', st.src, last(sp))       # the start of </table:table>
        _before_rows!(st, () -> endtag)
        _write_new_rows!(st, () -> endtag)
    end
    return
end

const _AttrChanges = Vector{Pair{String,Union{Nothing,String}}}

# The attribute changes that turn a column or row element with attributes `orig` (repeat,
# style, default, visibility; `_line_attrs`) into one with the format `r`.
function _line_changes(orig, r::Union{ColFormat,RowFormat}, styles::StyleIndex)
    ch = _AttrChanges()
    _, style, default, vis = orig
    r.style == style || push!(ch, "table:style-name" => (isempty(r.style) ? nothing : _escape_attr(r.style)))
    r.default == default ||
        push!(ch, "table:default-cell-style-name" => (r.default < 0 ? nothing : _escape_attr(style_name(styles, r.default))))
    r.visibility == vis || push!(ch, "table:visibility" => (r.visibility == _VISIBLE ? nothing : _escape_attr(r.visibility)))
    return ch
end

# A table:table-column element covering columns a:b, as the columns' formats now say.
function _patched_columns(st::_PatchState, text::AbstractString, orig, a::Int, b::Int)
    cols = st.fmt.cols
    i = _fmt_index(cols, a)
    if i <= length(cols) && _start(cols[i]) <= a && _stop(cols[i]) >= b
        return _set_attrs(text, _line_changes(orig, cols[i], st.styles))     # one format: the element stays whole
    end
    io = IOBuffer()
    c = a
    while c <= b
        r = i <= length(cols) && _start(cols[i]) <= c ? cols[i] : _blank(ColFormat, c, b - c + 1)
        n = min(_stop(r), b) - c + 1
        print(io, _set_attrs(_retag(text, "table:number-columns-repeated", n), _line_changes(orig, r, st.styles)))
        c += n
        i += 1
    end
    return String(take!(io))
end

# The edited columns of row r, as sorted disjoint ranges: its edited cells and the restyled
# blocks it is in.
function _edited_cols(st::_PatchState, r::Int)
    cols = UnitRange{Int}[]
    dc = get(st.dcols, r, nothing)
    dc === nothing || foreach(c -> push!(cols, c:c), dc)
    if st.fmt !== nothing
        for (rr, cc) in st.fmt.rects
            r in rr && push!(cols, cc)
        end
    end
    return _merge_ranges(cols)
end

# Ranges as sorted, disjoint ones (overlapping or adjacent ranges joined).
function _merge_ranges(v::Vector{UnitRange{Int}})
    merged = UnitRange{Int}[]
    for c in sort(v; by = first)
        if !isempty(merged) && first(c) <= last(merged[end]) + 1
            merged[end] = first(merged[end]):max(last(merged[end]), last(c))
        else
            push!(merged, c)
        end
    end
    return merged
end

_attrs_touched(st::_PatchState, r::Int) = st.fmt !== nothing && any(tr -> r in tr, st.fmt.rows_touched)

# The columns the cells of a row element cover.
function _row_extent(ln::XML.LazyNode)
    c = XML.Cursor(ln)
    XML.next!(c)
    n = 0
    XML.for_each_child!(c) do ch
        if XML.nodetype(ch) === XML.Element && XML.tag(ch) in ("table:table-cell", "table:covered-table-cell")
            k = 1
            for (key, v) in XML.eachattribute!(ch)
                key == "table:number-columns-repeated" && (k = max(1, something(tryparse(Int, v), 1)))
            end
            n += k
        end
        XML.skip_element!(ch)
    end
    return n
end

# A row element covering rows nextrow…nextrow+cnt-1, some of them edited, at `st.pos`. It is
# cut into segments within which the edits and the model are the same for every row;
# segments without edits keep the original element (with their repeat count).
function _patch_row!(st::_PatchState, ln::XML.LazyNode, text::SubString{String}, cnt::Int, orig)
    r0 = st.nextrow
    r1 = r0 + cnt - 1
    st.nextrow = r1 + 1
    bps = Int[]
    lo = searchsortedfirst(st.drows, r0)
    hi = searchsortedlast(st.drows, r1)
    for k in lo:hi
        push!(bps, st.drows[k], st.drows[k] + 1)
    end
    f = st.fmt
    if f !== nothing
        for (rr, _) in f.rects
            push!(bps, first(rr), last(rr) + 1)
        end
        for tr in f.rows_touched
            push!(bps, first(tr), last(tr) + 1)
        end
        _row_bounds!(bps, st.store.rows, r0, r1)
        _row_bounds!(bps, f.cells, r0, r1)
        _row_bounds!(bps, f.rows, r0, r1)
    end
    pts = _segment_points(bps, r0, r1)
    plain = 0                                    # untouched rows waiting to be written
    extent = -1                                  # the columns the original row's cells cover
    for k in 1:length(pts)-1
        a = pts[k]; n = pts[k + 1] - a
        cols = _edited_cols(st, a)
        attrs = _attrs_touched(st, a)
        if attrs                                 # cells to add, for the row to cover more columns
            rf = _fmt_at(f.rows, a)
            extent < 0 && (extent = _row_extent(ln))
            if rf !== nothing && rf.ncells > extent
                cols = _merge_ranges(push!(cols, extent+1:Int(rf.ncells)))
            end
        end
        changes = attrs ? _line_changes(orig, something(_fmt_at(f.rows, a), _blank(RowFormat, a, n)), st.styles) : _AttrChanges()
        if isempty(cols) && isempty(changes)     # untouched, or touched but as it was
            plain += n
            continue
        end
        plain > 0 && _emit(st, _retag(text, "table:number-rows-repeated", plain))
        plain = 0
        if isempty(cols)
            _emit(st, _set_attrs(_retag(text, "table:number-rows-repeated", n), changes))
        else
            _write_edited_row!(st, ln, text, a, n, cols, changes)
        end
    end
    if plain == cnt
        _emit(st, text)                          # nothing changed after all: as it was
    elseif plain > 0
        _emit(st, _retag(text, "table:number-rows-repeated", plain))
    end
    return
end

# An edited cell that is now empty keeps the original cell's style, and whether it is
# covered or spans a merge (when the sheet's formats were not read: else they say).
function _empty_cell_like(io::IO, celltext::AbstractString, repeat::Int)
    covered = startswith(celltext, "<table:covered-table-cell")
    print(io, covered ? "<table:covered-table-cell" : "<table:table-cell")
    for (k, v) in _raw_attrs(celltext)
        k in ("table:style-name", "table:number-columns-spanned", "table:number-rows-spanned") && print(io, ' ', k, '=', v)
    end
    repeat > 1 && print(io, " table:number-columns-repeated=\"", repeat, '"')
    print(io, "/>")
end

# Columns x:y of row r from the model; `celltext` is the original cell they replace
# (`nothing` past the row's cells).
function _write_model_cols!(st::_PatchState, r::Int, x::Int, y::Int, celltext, rowdefault::Bool)
    ne = _cell_edits_in(st.ws, r, x, y)
    vs = _val_layer_in(st.ws, r, x, y)
    isempty(ne) && isempty(vs) ? _write_model_cells!(st.out, st, r, x, y, celltext, rowdefault) :
                                 _write_noted_cols!(st, r, x, y, celltext, rowdefault, nothing, 0, 0, ne, vs)
    return
end

# The same, for an original cell that holds more than its value (`ex`, D-071); `row`, `col`: its
# original position (for `_emit`). Callers test `ex === nothing` themselves: a keyword or a union
# here costs a dynamic call on every cell of a restyled block.
function _write_model_cols!(st::_PatchState, r::Int, x::Int, y::Int, celltext, rowdefault::Bool,
                            ex::_CellExtras, row::Int, col::Int)
    ne = _cell_edits_in(st.ws, r, x, y)
    vs = _val_layer_in(st.ws, r, x, y)
    (isempty(ne) && isempty(vs)) || return _write_noted_cols!(st, r, x, y, celltext, rowdefault, ex, row, col, ne, vs)
    _write_with_extras!(st, r, x, y, celltext, rowdefault, ex, row, col)
    return
end

function _write_with_extras!(st::_PatchState, r::Int, x::Int, y::Int, celltext, rowdefault::Bool,
                             ex::_CellExtras, row::Int, col::Int)
    buf = IOBuffer()
    _write_model_cells!(buf, st, r, x, y, celltext, rowdefault)
    frag = String(take!(buf))
    isempty(ex.validation) || (frag = _with_validation(frag, ex.validation))
    if ex.single && x == y && _has_children(ex)
        run = _run_at(_runs_of(st.store.rows, r), x)
        keep = ex.paras !== nothing && run !== nothing && run.data.kind === CK_STRING && (run.data.flags & (F_RICH | F_PLAIN)) == 0 &&
               run.data.formula === nothing && run.data.text == ex.text
        _emit_with_children(st, frag, ex, keep; row, col)
    else
        print(st.out, frag)
    end
    return
end

function _write_model_cells!(io::IO, st::_PatchState, r::Int, x::Int, y::Int, celltext, rowdefault::Bool)
    emps = st.fmt === nothing ? _NO_RUNS : _runs_of(st.fmt.cells, r)
    gap = if st.fmt === nothing && celltext !== nothing
        n -> _empty_cell_like(io, celltext, n)
    else
        n -> write_cell(io, nothing, st.styles; repeat = n)
    end
    write_merged_cells(io, st.styles, _runs_of(st.store.rows, r), emps, x, y, rowdefault,
                       (a, b) -> _col_default(st, a, b), gap; st.display)
end

# Rows a … a+n-1 (alike), with the edited columns `cols` written from the model and the rest
# copied from the original row; `changes` to the row's attributes.
function _write_edited_row!(st::_PatchState, ln::XML.LazyNode, text::SubString{String}, a::Int, n::Int,
                            cols::Vector{UnitRange{Int}}, changes::_AttrChanges)
    src = st.src
    out = st.out
    e = _start_tag_end(text)
    selfclosing = text[prevind(text, e)] == '/'
    rf = st.fmt === nothing ? nothing : _fmt_at(st.fmt.rows, a)
    rowdefault = rf !== nothing ? rf.default >= 0 : any(((k, _),) -> k == "table:default-cell-style-name", _raw_attrs(text))
    print(out, _set_attrs(_retag(text, "table:number-rows-repeated", n; open = true), changes; open = true))
    ci = 1                                      # the next edited range to write
    col = 1
    off = first(XML.sourcespan(ln)) - 1          # src index = off + index in text
    lpos = off + nextind(text, e)                # src index after the start tag
    if !selfclosing
        c = XML.Cursor(ln)
        XML.next!(c)
        XML.for_each_child!(c) do ch
            XML.nodetype(ch) === XML.Element || return
            csp = XML.sourcespan(XML.LazyNode(ch))
            first(csp) > lpos && print(out, SubString(src, lpos, prevind(src, first(csp))))
            celltext = SubString(src, first(csp), last(csp))
            t = XML.tag(ch)
            if t == "table:table-cell" || t == "table:covered-table-cell"
                k = max(1, _attr_int(celltext, "table:number-columns-repeated", 1))
                lastc = col + k - 1
                cur = col
                ex = nothing; exread = false     # the cell's extras (D-071), read when an edit reaches it
                while ci <= length(cols) && first(cols[ci]) <= lastc
                    if !exread
                        ex = _extras_possible(st) && _maybe_extras(celltext) ? _cell_extras(src, XML.LazyNode(ch), celltext) : nothing
                        exread = true
                    end
                    x = max(first(cols[ci]), cur); y = min(last(cols[ci]), lastc)
                    x > cur && _emit(st, _retag(celltext, "table:number-columns-repeated", x - cur))
                    if ex === nothing
                        _write_model_cols!(st, a, x, y, celltext, rowdefault)
                    else
                        _write_model_cols!(st, a, x, y, celltext, rowdefault, ex, 0, 0)
                    end
                    cur = y + 1
                    last(cols[ci]) <= lastc ? (ci += 1) : break
                end
                if cur == col
                    _emit(st, celltext)
                elseif cur <= lastc
                    _emit(st, _retag(celltext, "table:number-columns-repeated", lastc - cur + 1))
                end
                col = lastc + 1
            else
                _emit(st, celltext)
            end
            lpos = nextind(src, last(csp))
            XML.skip_element!(ch)
        end
    end
    # edited columns beyond the row's cells, as far as the model has cells
    lastm = max(_lastcol(_runs_of(st.store.rows, a)), st.fmt === nothing ? 0 : _lastcol(_runs_of(st.fmt.cells, a)),
                rf === nothing ? 0 : Int(rf.ncells), _val_lastcol(st.ws, a))
    while ci <= length(cols)
        x = max(first(cols[ci]), col); y = min(last(cols[ci]), lastm)
        if y >= x
            x > col && write_cell(out, nothing, st.styles; repeat = x - col)
            _write_model_cols!(st, a, x, y, nothing, rowdefault)
            col = y + 1
        end
        ci += 1
    end
    if selfclosing
        print(out, "</table:table-row>")
    else
        endidx = off + lastindex(text)
        print(out, SubString(src, lpos, endidx))   # whitespace and the end tag
    end
    return
end

"""
    write_patched_table(out::_ChunkedIO, ws::Worksheet)

Writes the `table:table` of a sheet read from the file, with its edits (D-023), to `out`
(D-048).
"""
function write_patched_table(out::_ChunkedIO, ws::Worksheet; display::Bool = true, rw::Union{Nothing,RefRewriter} = nothing)
    node = ws.entry.node
    src = parent(XML.sourcetext(node))
    store = _cached_store(ws)
    dcols = Dict{Int,Vector{Int}}(r => sort!(unique(cs)) for (r, cs) in ws.dirty)
    need = maximum((maximum(v) for v in values(dcols)); init = 0)
    drows = sort!(collect(keys(dcols)))
    f = ws.formats
    ranges = UnitRange{Int}[r:r for r in drows]
    if f !== nothing
        for (rr, cc) in f.rects
            push!(ranges, rr)
            need = max(need, last(cc))
        end
        append!(ranges, f.rows_touched)
    end
    erows = _merge_ranges(ranges)
    sp = XML.sourcespan(node)
    st = _PatchState(ws, store, get_odsfile(ws).styles, src, out,
                     first(sp), 1, 0, need, false, false, drows, dcols, erows, f, display, rw, ws.entry.name, 0, 0, -1, ws.mayextras === nothing ? Int8(-1) : Int8(ws.mayextras), 0, sp)
    _start_tag_changed(ws) && _renamed_start_tag!(st, ws)
    if ws.rowmap !== nothing || ws.colmap !== nothing
        st.posrow = 0
        _walk_mapped!(st, node, :table)        # rows or columns inserted or deleted (phase 5)
    else
        _walk!(st, node, :table)
    end
    # the rest of the table, verbatim, with its names' edits (they follow the rows; phase 5)
    for (a, b, rep) in _name_splices(ws.localnames, _names_at!(ws), src)
        _copy_to!(st, a)
        print(out, rep)
        b >= a && (st.pos = max(st.pos, nextind(src, b)))
    end
    _copy_to!(st, nextind(src, last(sp)))
    return nothing
end

# A renamed sheet's start tag: its references replayed, its `table:name` the new one (phase 5).
function _table_start_tag(ws::Worksheet, rw::Union{Nothing,RefRewriter}, src::String, a::Int, e::Int)
    if rw === nothing
        tag = String(SubString(src, a, e))
    else
        io = IOBuffer()
        rewrite_xml(io, rw, src, a, e; sheet = ws.entry.name)
        tag = String(take!(io))
    end
    changed = _props_changed(ws)                   # its table style (phase 5 step 6)
    prot = _prot_changed(ws)                       # its protection (phase 5 step 9)
    area = _area_changed(ws)                       # its print area (phase 5 step 10)
    ws.name == ws.entry.name && !changed && !prot && !area && return tag
    ch = Pair{String,Union{Nothing,String}}[]
    ws.name == ws.entry.name || push!(ch, "table:name" => _escape_attr(ws.name))
    changed && push!(ch, "table:style-name" => (ws.props.style === nothing ? nothing : _escape_attr(ws.props.style)))
    prot && append!(ch, _protection_changes(ws.protection))
    area && push!(ch, "table:print-ranges" => (ws.print.area === nothing ? nothing : _escape_attr(ws.print.area)))
    return _set_attrs(tag, ch; open = true)
end

# Whether a sheet's start tag changes (phase 5).
_start_tag_changed(ws::Worksheet) = ws.name != ws.entry.name || _props_changed(ws) || _prot_changed(ws) || _area_changed(ws)

# A sheet's protection options, when its protection changed: (the span of the text's element, or an
# empty range where it goes, after the start tag ending at `e`; its new XML).
function _protection_splice(ws::Worksheet, e::Int)
    _prot_changed(ws) || return nothing
    p = ws.protection
    return (isempty(p.child) ? (e + 1:e) : p.child, _protection_xml(p))
end

function _renamed_start_tag!(st::_PatchState, ws::Worksheet)
    a = st.pos
    e = a - 1 + _start_tag_end(SubString(st.src, a))
    print(st.out, _table_start_tag(ws, st.rw, st.src, a, e))
    st.pos = e + 1
    ps = _protection_splice(ws, e)
    if ps !== nothing
        sp, x = ps
        _copy_to!(st, first(sp))
        print(st.out, x)
        isempty(sp) || (st.pos = last(sp) + 1)
    end
    return
end

# The operations a sheet's text is to be rewritten by: the file's (`rw`, built once for
# content.xml), or a copy's own (those after the copy, on its own text). Nothing if none.
function _sheet_rewriter(ws::Worksheet, rw::Union{Nothing,RefRewriter})
    xf = get_odsfile(ws)
    if ws.copied
        ops = xf.ops[ws.opstart+1:end]
        any(op -> !(op isa SheetCopy), ops) || return nothing
        return RefRewriter(ops, parent(XML.sourcetext(ws.entry.node)))
    end
    rw !== nothing && return rw
    any(op -> !(op isa SheetCopy), xf.ops) || return nothing
    return RefRewriter(xf.ops, xf.content)
end

# Text through the operations `ops` (a database range added by a copy).
function _rewritten(x::String, ops)
    isempty(ops) && return x
    io = IOBuffer()
    rewrite_xml(io, RefRewriter(Any[ops...], x), x, 1, ncodeunits(x))
    return String(take!(io))
end

"""
    _write_sheet(out, ws, rw; display)

One sheet's table as it is now: written from the model (a sheet made by OpenDocumentSpreadsheets), patched (an
edited sheet read from the file, or a copy), or copied with its references replayed and its name
set (phase 5).
"""
function _write_sheet(out::_ChunkedIO, ws::Worksheet, rw::Union{Nothing,RefRewriter}; display::Bool = true)
    ws.entry === nothing && return write_table(out, ws; display)
    # groups changed (phase 5 step 7): the table is written, then its group containers rebuilt
    _groups_touched(ws) && return _with_groups(io -> _write_chunked(o -> _write_sheet_now(o, ws, rw; display), io), out, ws.formats)
    return _write_sheet_now(out, ws, rw; display)
end

function _write_sheet_now(out::_ChunkedIO, ws::Worksheet, rw::Union{Nothing,RefRewriter}; display::Bool = true)
    srw = _sheet_rewriter(ws, ws.copied ? nothing : rw)
    _has_edits(ws) && return write_patched_table(out, ws; display, rw = srw)
    node = ws.entry.node
    src = parent(XML.sourcetext(node))
    sp = XML.sourcespan(node)
    a = first(sp); b = last(sp)
    e = a - 1 + _start_tag_end(SubString(src, a, b))
    print(out, _table_start_tag(ws, srw, src, a, e))
    put(x, y) = x > y ? nothing : srw === nothing ? print(out, SubString(src, x, y)) :
                                   rewrite_xml(out, srw, src, x, y; sheet = ws.entry.name)
    pos = e + 1
    splices = _name_splices(ws.localnames, _names_at!(ws), src)          # its names' edits (phase 5)
    ps = _protection_splice(ws, e)                                       # its protection options (step 9)
    ps === nothing || pushfirst!(splices, (first(ps[1]), last(ps[1]), ps[2]))
    for (x, y, rep) in splices
        put(pos, prevind(src, x))
        print(out, rep)
        pos = y >= x ? nextind(src, y) : max(pos, x)
    end
    put(pos, b)
    return
end

const _NAMESPACES = [
    "office" => "urn:oasis:names:tc:opendocument:xmlns:office:1.0",
    "style" => "urn:oasis:names:tc:opendocument:xmlns:style:1.0",
    "text" => "urn:oasis:names:tc:opendocument:xmlns:text:1.0",
    "table" => "urn:oasis:names:tc:opendocument:xmlns:table:1.0",
    "number" => "urn:oasis:names:tc:opendocument:xmlns:datastyle:1.0",
    "fo" => "urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0",
    "of" => "urn:oasis:names:tc:opendocument:xmlns:of:1.2",
]

"""
    _top_elements(xml) -> (src, rootspan, children)

The source of an XML document, its root element's span, and the root's first child element
of each tag (`LazyNode`s).
"""
function _top_elements(xml::AbstractString)
    c = XML.Cursor(xml)
    while XML.next!(c) !== nothing
        XML.nodetype(c) === XML.Element && break
    end
    root = XML.LazyNode(c)
    src = parent(XML.sourcetext(root))
    kids = Dict{String,Any}()
    XML.for_each_child!(c) do ch
        XML.nodetype(ch) === XML.Element || return
        t = XML.tag(ch)
        haskey(kids, t) || (kids[t] = XML.LazyNode(ch))
        XML.skip_element!(ch)
    end
    return src, XML.sourcespan(root), kids
end

# The namespace declarations the written XML needs, added to the root's start tag.
function _ns_splice!(splices, src::AbstractString, rootspan, svg::Bool, loext::Bool; xlink::Bool = false, draw::Bool = false,
                     calcext::Bool = false)
    roottext = SubString(src, first(rootspan), last(rootspan))
    tagend = first(rootspan) - 1 + _start_tag_end(roottext)
    tagend_at = src[prevind(src, tagend)] == '/' ? prevind(src, tagend) : tagend
    starttag = SubString(src, first(rootspan), tagend)
    ns = join(" xmlns:$p=\"$u\"" for (p, u) in _NAMESPACES if !occursin("xmlns:$p=", starttag))
    svg && !occursin("xmlns:svg=", starttag) && (ns *= " xmlns:svg=\"$_SVG_NS\"")
    loext && !occursin("xmlns:loext=", starttag) && (ns *= " xmlns:loext=\"$_LOEXT_NS\"")
    xlink && !occursin("xmlns:xlink=", starttag) && (ns *= " xmlns:xlink=\"$_XLINK_NS\"")
    draw && !occursin("xmlns:draw=", starttag) && (ns *= " xmlns:draw=\"$_DRAW_NS\"")
    calcext && !occursin("xmlns:calcext=", starttag) && (ns *= " xmlns:calcext=\"$_CALCEXT_NS\"")
    isempty(ns) || push!(splices, (tagend_at, tagend_at - 1, ns))
    return
end

# Appends `xml` to the content of element `node`, or, if there is none, inserts a new `tag`
# element holding it before `anchor`.
function _append_splice!(splices, src::AbstractString, node, tag::AbstractString, xml::AbstractString, anchor)
    if node === nothing
        anchor === nothing && throw(ODSError("The document has no office:body."))
        at = first(XML.sourcespan(anchor))
        push!(splices, (at, at - 1, "<$tag>$xml</$tag>"))
    else
        sp = XML.sourcespan(node)
        text = SubString(src, first(sp), last(sp))
        if endswith(text, "/>")
            push!(splices, (first(sp), last(sp), _retag(text, "", nothing; open = true) * xml * "</$tag>"))
        else
            at = first(sp) - 1 + findlast("</", text)[1]
            push!(splices, (at, at - 1, xml))
        end
    end
    return
end

# A splice: (first, last, replacement), where last = first - 1 inserts. The replacement is
# text, or a function that writes it to the output (an edited or new sheet, D-048).
const _Splice = Tuple{Int,Int,Union{String,Function}}

# Writes `src` with the splices made to `out`. Splices at the same place keep their order.
function _apply_splices(out::IO, src::AbstractString, splices::Vector{<:Tuple{Int,Int,Any}};
                        rw::Union{Nothing,RefRewriter} = nothing)
    sort!(splices; by = x -> (x[1], x[2]))
    pos = firstindex(src)
    for (a, b, rep) in splices
        if a > pos
            rw === nothing ? write(out, SubString(src, pos, prevind(src, a))) :
                             rewrite_xml(out, rw, String(src), pos, prevind(src, a))   # phase 5: references replayed
        end
        rep isa Function ? rep(out) : write(out, rep)
        pos = b >= a ? nextind(src, b) : max(pos, a)
    end
    if pos <= lastindex(src)
        rw === nothing ? write(out, SubString(src, pos)) : rewrite_xml(out, rw, String(src), pos, lastindex(src))
    end
    return nothing
end

# `src` with the splices made, as a string (for the small parts: styles.xml).
function _apply_splices(src::AbstractString, splices::Vector{<:Tuple{Int,Int,Any}})
    out = IOBuffer(sizehint = ncodeunits(src) + sum(s -> s[3] isa String ? ncodeunits(s[3]) : 0, splices; init = 0))
    _apply_splices(out, src, splices)
    return String(take!(out))
end

"""
    write_patched_content(out::_ChunkedIO, xf::ODSFile)

Writes the content.xml (or flat document) of a file that was read, with its edits, new
sheets and new styles (D-023), to `out` as it is made (D-048). A flat document also gets
the named styles OpenDocumentSpreadsheets added (D-045). Text that isn't edited is copied from the
original in pieces as large as the gaps between edits.
"""
function write_patched_content(out::_ChunkedIO, xf::ODSFile; display::Bool = true)
    src, rootspan, kids = _top_elements(xf.content)
    autostyles = get(kids, "office:automatic-styles", nothing)
    body = get(kids, "office:body", nothing)
    facedecls = get(kids, "office:font-face-decls", nothing)
    splices = _Splice[]
    fx = added_faces_xml(xf.styles)
    _ns_splice!(splices, src, rootspan, !isempty(fx) || _has_notes(xf) || _has_frames(xf), _needs_loext(xf.styles) || _needs_protection_loext(xf) || _has_threads(xf);
                xlink = _needs_xlink(xf.styles) || _has_frames(xf), draw = _has_frames(xf), calcext = _has_footers(xf))
    # font faces (phase 4): in office:font-face-decls, which comes before the styles
    stylesnode = get(kids, "office:styles", nothing)
    isempty(fx) || _append_splice!(splices, src, facedecls, "office:font-face-decls", fx,
                                   something(stylesnode, autostyles, body, Some(nothing)))
    # named styles (a flat document holds office:styles), before the automatic styles
    nx = xf.container.format === :fods ? named_styles_xml(xf.styles) : ""
    isempty(nx) || _append_splice!(splices, src, stylesnode, "office:styles", nx, something(autostyles, body, Some(nothing)))
    # structural edits (phase 5): their references are replayed on all the text that is copied
    rw = any(op -> !(op isa SheetCopy), xf.ops) ? RefRewriter(xf.ops, String(src)) : nothing
    sheets = _sheets(xf)
    orig = [ws for ws in sheets if ws.entry !== nothing && !ws.copied]
    spans = Dict(ws => XML.sourcespan(ws.entry.node) for ws in vcat(orig, Worksheet[w for w in xf.gone]))
    last_table_end = isempty(spans) ? 0 : maximum(last, values(spans))
    # deleted, copied or moved sheets (phase 5): the tables are written in their new order
    k = findfirst(ws -> ws.entry === nothing || ws.copied, sheets)
    restructured = !isempty(xf.gone) || !issorted(orig; by = ws -> first(spans[ws])) ||
                   (k !== nothing && any(ws -> ws.entry !== nothing && !ws.copied, sheets[k:end]))
    if restructured && !isempty(spans)
        a = minimum(first, values(spans))
        push!(splices, (a, last_table_end, io -> foreach(ws -> _write_sheet(io, ws, rw; display), sheets)))
    else
        # edited sheets (and, after structural edits, every other sheet: its references are rewritten)
        for ws in orig
            sp = spans[ws]
            (_has_edits(ws) || rw !== nothing || _start_tag_changed(ws) || _names_edited(ws)) &&
                push!(splices, (first(sp), last(sp), io -> _write_sheet(io, ws, rw; display)))
        end
        # new sheets (and copies), after the last one
        newsheets = [ws for ws in sheets if ws.entry === nothing || ws.copied]
        if !isempty(newsheets)
            at = last_table_end > 0 ? nextind(src, last_table_end) : _spreadsheet_end(body, src)
            push!(splices, (at, at - 1, io -> foreach(ws -> _write_sheet(io, ws, rw; display), newsheets)))
        end
    end
    # validations (phase 6 step 6): before the tables, so first among splices at the same place
    ft = isempty(spans) ? _spreadsheet_end(body, src) : minimum(first, values(spans))
    prepend!(splices, _rules_splices(xf, ft))
    # the threads' people (phase 6 step 4): added to the file's loext:persons, or in a new one after the
    # tables (before the names, as LibreOffice writes them)
    if !isempty(xf.persons.added)
        px = _persons_xml(xf.persons.added)
        k = findfirst("</loext:persons>", src)
        if k !== nothing
            push!(splices, (first(k), first(k) - 1, px))
        else
            at = last_table_end > 0 ? nextind(src, last_table_end) : _spreadsheet_end(body, src)
            push!(splices, (at, at - 1, "<loext:persons>" * px * "</loext:persons>"))
        end
    end
    # the workbook's names (phase 5): deleted ones removed, added ones written, in a new element after
    # the tables if there is none
    if _names_edited(xf)
        ed = xf.nameedits
        if isempty(ed.at)
            at = last_table_end > 0 ? nextind(src, last_table_end) : _spreadsheet_end(body, src)
            ed = NameEdits(ed.removed, at:at-1)
        end
        append!(splices, _name_splices(xf.names, ed, src))
    end
    # database ranges added by copies (phase 5), through the operations after each copy, and the tables
    # added or changed (phase 6 step 7): the file's they replace, or that were removed, go
    de = xf.dbedits
    if !isempty(xf.extras) || _db_edited(xf)
        # a file's range changed is written in its place, so the tables keep their order (D-077)
        repl = Dict{Int,DBRange}(Int(m.order) => m for m in de.model if m.order < 1.0e6 && _db_alive(xf, m))
        x = join(_rewritten(xx, xf.ops[n+1:end]) for (k, (xx, n)) in enumerate(xf.extras) if !(k in de.removedx)) *
            join(_db_xml(m) for m in de.model if m.order >= 1.0e6 && _db_alive(xf, m))
        for k in de.removed
            sp = _file_dbranges(xf)[k][1]
            if haskey(repl, k)
                push!(splices, (first(sp), last(sp), _db_xml(repl[k])))
            else
                a = first(sp)
                while a > 1 && (src[a-1] == ' ' || src[a-1] == '\n' || src[a-1] == '\t' || src[a-1] == '\r'); a -= 1; end
                push!(splices, (a, last(sp), ""))
            end
        end
        k = findlast("</table:database-ranges>", src)
        if k !== nothing
            push!(splices, (first(k), first(k) - 1, x))
        else
            ne = findlast("</table:named-expressions>", src)
            at = ne !== nothing && last(ne) > last_table_end ? last(ne) + 1 :
                 last_table_end > 0 ? nextind(src, last_table_end) : _spreadsheet_end(body, src)
            push!(splices, (at, at - 1, "<table:database-ranges>" * x * "</table:database-ranges>"))
        end
    end
    # a flat document's properties (phase 5 step 11): office:meta written again (first, where it has none)
    if _meta_edited(xf)
        meta = get(kids, "office:meta", nothing)
        if meta === nothing
            at = first(rootspan) + _start_tag_end(SubString(src, first(rootspan), last(rootspan)))
            push!(splices, (at, at - 1, _meta_element(xf)))
        else
            sp = XML.sourcespan(meta)
            push!(splices, (first(sp), last(sp), _meta_element(xf)))
        end
    end
    # a flat document's settings (phase 5): the sheets' entries follow renames, deletes and copies
    setnode = get(kids, "office:settings", nothing)
    if setnode !== nothing && _settings_edited(xf)
        sp = XML.sourcespan(setnode)
        push!(splices, (first(sp), last(sp), patched_settings(xf, String(SubString(src, first(sp), last(sp))))))
    elseif setnode === nothing && xf.container.format === :fods && _views_edited(xf)
        # view settings (phase 5 step 8) in a flat document without settings: after its meta
        meta = get(kids, "office:meta", nothing)
        at = meta === nothing ? first(rootspan) + _start_tag_end(SubString(src, first(rootspan), last(rootspan))) :
                                last(XML.sourcespan(meta)) + 1
        push!(splices, (at, at - 1, _settings_views(xf, "<office:settings></office:settings>")))
    end
    if _views_edited(xf) && xf.container.format === :fods
        # LibreOffice reads view settings only with the config and ooo namespaces declared (F-053)
        roottext = SubString(src, first(rootspan), first(rootspan) - 1 + _start_tag_end(SubString(src, first(rootspan), last(rootspan))))
        ns = (occursin("xmlns:config=", roottext) ? "" : " xmlns:config=\"$_CONFIG_NS\"") *
             (occursin("xmlns:ooo=", roottext) ? "" : " xmlns:ooo=\"$_OOO_NS\"")
        e = first(rootspan) - 1 + _start_tag_end(roottext)
        isempty(ns) || push!(splices, (e, e - 1, ns))
    end
    # typed and formatting styles (before the sheets are written, which add none)
    # the file's structure protection (phase 5 step 9): office:spreadsheet's start tag
    if _wbprot_changed(xf)
        r = _spreadsheet_tag_span(xf)
        tag = SubString(src, first(r), last(r))
        ch = Pair{String,Union{Nothing,String}}[k => (haskey(xf.wbprotection.attrs, k) ? _escape_attr(xf.wbprotection.attrs[k]) : nothing)
                                                for k in _WB_PROT_ATTRS]
        push!(splices, (first(r), last(r), _set_attrs(tag, ch; open = !endswith(tag, "/>"))))
    end
    pautos, pmasters = _page_styles_xml(xf)                                       # page styles: phase 5 step 10
    if xf.container.format === :fods && !isempty(pmasters)
        _append_splice!(splices, src, get(kids, "office:master-styles", nothing), "office:master-styles", pmasters, body)
    end
    sx = added_styles_xml(xf.styles, used_styles(xf)) * _table_styles_xml(xf) *  # table styles: phase 5 step 6
         (xf.container.format === :fods ? pautos : "")
    if !isempty(sx)
        _append_splice!(splices, src, autostyles, "office:automatic-styles", sx, body)
    end
    _apply_splices(out, src, splices; rw)
    return nothing
end

"""
    patched_styles(xf::ODSFile, xml) -> String

A file's styles.xml (`xml`) with the named styles OpenDocumentSpreadsheets added, their data styles in
`office:styles` and the font faces they name in `office:font-face-decls` (D-045, F-040).
Everything else is kept as it was.
"""
function patched_styles(xf::ODSFile, xml::AbstractString)
    src, rootspan, kids = _top_elements(xml)
    splices = Tuple{Int,Int,String}[]
    decls = get(kids, "office:font-face-decls", nothing)
    declared = Set{String}()
    if decls !== nothing
        sp = XML.sourcespan(decls)
        for m in eachmatch(r"<style:font-face\s[^>]*?style:name=\"([^\"]*)\"", SubString(src, first(sp), last(sp)))
            push!(declared, XML.unescape(m.captures[1]))
        end
    end
    fx = faces_xml(filter(n -> !(n in declared), _named_faces(xf.styles)))
    _ns_splice!(splices, src, rootspan, !isempty(fx), _needs_loext(xf.styles))
    stylesnode = get(kids, "office:styles", nothing)
    after = something(get(kids, "office:automatic-styles", nothing), get(kids, "office:master-styles", nothing), Some(nothing))
    isempty(fx) || _append_splice!(splices, src, decls, "office:font-face-decls", fx, something(stylesnode, after, Some(nothing)))
    # page styles (phase 5 step 10): page layouts and text styles in the automatic styles, master pages
    pautos, pmasters = _page_styles_xml(xf)
    rootend = first(findlast("</", SubString(src, first(rootspan), last(rootspan)))) + first(rootspan) - 1
    autos = get(kids, "office:automatic-styles", nothing)
    masters = get(kids, "office:master-styles", nothing)
    if !isempty(pautos)
        autos === nothing ? push!(splices, (something(masters === nothing ? nothing : first(XML.sourcespan(masters)), rootend),
                                            something(masters === nothing ? nothing : first(XML.sourcespan(masters)), rootend) - 1,
                                            "<office:automatic-styles>" * pautos * "</office:automatic-styles>")) :
            _append_splice!(splices, src, autos, "office:automatic-styles", pautos, nothing)
    end
    if !isempty(pmasters)
        masters === nothing ? push!(splices, (rootend, rootend - 1, "<office:master-styles>" * pmasters * "</office:master-styles>")) :
            _append_splice!(splices, src, masters, "office:master-styles", pmasters, nothing)
    end
    has_named_styles(xf.styles) || return _apply_splices(src, splices)
    if stylesnode === nothing && after === nothing
        # a styles.xml with nothing but its root: the styles go before its end tag
        at = first(findlast("</", SubString(src, first(rootspan), last(rootspan)))) + first(rootspan) - 1
        push!(splices, (at, at - 1, "<office:styles>$(named_styles_xml(xf.styles))</office:styles>"))
    else
        _append_splice!(splices, src, stylesnode, "office:styles", named_styles_xml(xf.styles), after)
    end
    return _apply_splices(src, splices)
end

# The index of `</office:spreadsheet>` in the body, where sheets are added to a document
# that has none.
function _spreadsheet_end(body, src::String)
    body === nothing && throw(ODSError("The document has no office:body."))
    sp = XML.sourcespan(body)
    text = SubString(src, first(sp), last(sp))
    r = findlast("</office:spreadsheet>", text)
    r === nothing && throw(ODSError("The document's body has no office:spreadsheet to add sheets to."))
    return first(sp) - 1 + r[1]
end

# Columns x:y of row r where some cells' notes or frames changed (D-073, D-074; `ne`: column => edit,
# sorted) or a validation was set or removed (D-075; `vs`, from `_val_layer_in`): each noted cell
# written alone, its note and frames in place of the original's (`ex`), and each validation segment
# with its validation in place of the original's.
function _write_noted_cols!(st::_PatchState, r::Int, x::Int, y::Int, celltext, rowdefault::Bool,
                            ex::Union{Nothing,_CellExtras}, row::Int, col::Int, ne, vs)
    pts = Int[x, y + 1]
    for (c, _) in ne
        push!(pts, c, c + 1)
    end
    for (a, b, _) in vs
        push!(pts, a, b + 1)
    end
    sort!(unique!(pts))
    for k in 1:length(pts)-1
        a = pts[k]; b = pts[k+1] - 1
        ex2 = ex
        if a == b
            i = findfirst(p -> first(p) == a, ne)
            i === nothing || (ex2 = _with_edit(ex2, last(ne[i]), st.ws))
        end
        j = findfirst(v -> v[1] <= a <= v[2], vs)
        j === nothing || (ex2 = _with_val(ex2, vs[j][3]))
        if ex2 === nothing
            _write_model_cells!(st.out, st, r, a, b, celltext, rowdefault)
        else
            _write_with_extras!(st, r, a, b, celltext, rowdefault, ex2, row, col + (a - x))
        end
    end
    return
end

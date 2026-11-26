# Reading a sheet's rows from its `table:table` snapshot (D-008, D-009, D-020).
#
# A `SheetReader` walks the table with an XML.jl Cursor and yields one `RowData` per
# `table:table-row` that has content. A row keeps LibreOffice's run-length form: it carries
# its `number-rows-repeated` count, and its cells are runs (`CellRun`: first column, count
# and one `CellData`), so a value repeated over many columns or rows is stored once.
# Rows and cells that hold no value and no formula are never stored; the 1048576-row tails
# of whole-column styles therefore cost nothing (F-007).
#
# The same reader feeds the worksheet cache (every row, once), uncached reads (stopping
# after the last row needed) and the streaming `eachrow`.

"""
    CellRun(col, count, data)

`count` adjacent cells of a row, from column `col`, all holding `data`.
"""
struct CellRun
    col::Int32
    count::Int32
    data::CellData
end

"""
    RowData(row, count, runs)

`count` identical rows from row `row` (`number-rows-repeated`), whose cells with content
are the `runs`, in column order.
"""
struct RowData
    row::Int32
    count::Int32
    runs::Vector{CellRun}
end

@inline _lastcol(r::CellRun) = Int(r.col) + Int(r.count) - 1
@inline _lastrow(r::RowData) = Int(r.row) + Int(r.count) - 1

# The run holding column `col`, or `nothing`.
function _run_at(runs::Vector{CellRun}, col::Integer)
    lo, hi = 1, length(runs)
    while lo <= hi
        mid = (lo + hi) >>> 1
        @inbounds r = runs[mid]
        if col < r.col
            hi = mid - 1
        elseif col > _lastcol(r)
            lo = mid + 1
        else
            return r
        end
    end
    return nothing
end

"""
    ColRun(col, count, default_style, visible)

`count` columns from `col` (`table:table-column`, with `number-columns-repeated`), with their
`table:default-cell-style-name` as a style id and their visibility.
"""
struct ColRun
    col::Int32
    count::Int32
    default_style::Int32      # -1: none
    visible::Bool
end

const _ROW_CONTAINERS = ("table:table-rows", "table:table-header-rows", "table:table-row-group")
const _COL_CONTAINERS = ("table:table-columns", "table:table-header-columns", "table:table-column-group")

"""
    SheetReader(node::XML.LazyNode, styles::StyleIndex; skip_before=1, stop_after=MAX_ROWS,
                scan=_SCAN[])

A pull reader over one sheet. `next_row!` gives its rows with content in order. Rows
before `skip_before` are skipped without reading their cells; reading ends once a row
starts after `stop_after`.

With `scan` (the default), rows are read by the byte scanner (src/model/sheetscan.jl,
D-047), which hands what it doesn't read itself to the XML.jl cursor walk below.
"""
mutable struct SheetReader
    node::XML.LazyNode{String}
    c::XML.Cursor{String}
    styles::StyleIndex
    nextrow::Int                 # the row number of the next table:table-row
    cols::Vector{ColRun}
    merges::Vector{CellRange}
    skip_before::Int
    stop_after::Int
    done::Bool
    # the byte scanner (D-047): the document's text, where the next item starts, and the
    # depth of row and column containers open at that point
    scan::Bool
    src::String
    pos::Int
    depth::Int
    attrs::Vector{NTuple{2,UnitRange{Int}}}   # scratch: a start tag's attributes
    # scratch for one row
    runs::Vector{CellRun}
    text::IOBuffer
end

function SheetReader(node::XML.LazyNode{String}, styles::StyleIndex;
                     skip_before::Integer = 1, stop_after::Integer = SheetCore.MAX_ROWS,
                     scan::Bool = _SCAN[])
    c = XML.Cursor(node)
    XML.next!(c)                 # on table:table (depth 1)
    r = SheetReader(node, c, styles, 1, ColRun[], CellRange[], Int(skip_before), Int(stop_after), false,
                    false, "", 0, 0, NTuple{2,UnitRange{Int}}[], CellRun[], IOBuffer())
    scan && _scan_start!(r)
    return r
end

# The default style of column `col`, or -1.
function _col_default(r::SheetReader, col::Integer)
    for cr in r.cols
        cr.col <= col <= cr.col + cr.count - 1 && return Int(cr.default_style)
    end
    return -1
end

"""
    next_row!(r::SheetReader) -> Union{RowData, Nothing}

The next row that has content, or `nothing` at the end of the sheet (or past `stop_after`).
"""
function next_row!(r::SheetReader)
    r.done && return nothing
    if r.scan
        mark = r.nextrow
        nmerges = length(r.merges)
        try
            return _scan_next_row!(r)
        catch e
            e isa _ScanFallback || rethrow()
            _scan_to_cursor!(r, mark, nmerges)
        end
    end
    c = r.c
    while true
        if XML.next!(c) === nothing || XML.depth(c) <= 1
            r.done = true
            return nothing
        end
        XML.nodetype(c) === XML.Element || continue
        t = XML.tag(c)
        if t == "table:table-row"
            row = _read_row!(r)
            row === nothing || return row
            r.done && return nothing
        elseif t == "table:table-column"
            _read_column!(r)
        elseif t in _ROW_CONTAINERS || t in _COL_CONTAINERS
            continue             # descend: next! goes into the container
        else
            XML.skip_element!(c) # named expressions, forms, shapes, scenarios, ...
        end
    end
end

function _read_column!(r::SheetReader)
    c = r.c
    count = 1; ds = Int32(-1); visible = true
    for (k, v) in XML.eachattribute!(c)
        if k == "table:number-columns-repeated"
            count = something(tryparse(Int, v), 1)
        elseif k == "table:default-cell-style-name"
            ds = style_id(r.styles, v)
        elseif k == "table:visibility"
            visible = v == "visible"
        end
    end
    _push_column!(r, count, ds, visible)
    XML.skip_element!(c)
    return
end

function _push_column!(r::SheetReader, count::Int, ds::Int32, visible::Bool)
    first = isempty(r.cols) ? 1 : Int(r.cols[end].col) + Int(r.cols[end].count)
    count = clamp(count, 0, SheetCore.MAX_COLS - first + 1)
    count > 0 && push!(r.cols, ColRun(first, count, ds, visible))
    return
end

# Reads the table:table-row at the cursor; returns its RowData if it has content.
function _read_row!(r::SheetReader)
    c = r.c
    rowno = r.nextrow
    count = 1; rowdefault = Int32(-1)
    for (k, v) in XML.eachattribute!(c)
        if k == "table:number-rows-repeated"
            count = max(1, something(tryparse(Int, v), 1))
        elseif k == "table:default-cell-style-name"
            rowdefault = style_id(r.styles, v)
        end
    end
    rowno, count, read = _row_span!(r, count)
    r.done && return nothing
    if !read
        XML.skip_element!(c)
        return nothing
    end
    runs = r.runs
    empty!(runs)
    col = 1
    XML.@for_each_child! c ch begin
        if XML.nodetype(ch) === XML.Element
            t = XML.tag(ch)
            if t == "table:table-cell" || t == "table:covered-table-cell"
                col = _read_cell!(r, ch, rowno, count, col, rowdefault, t == "table:covered-table-cell")
            else
                XML.skip_element!(ch)
            end
        end
    end
    isempty(runs) && return nothing
    return RowData(rowno, count, copy(runs))
end

# Places a row of `count` repeats at `r.nextrow`: returns its first row number, its count
# (cut at the sheet's end) and whether its cells are to be read. Past `stop_after`, the
# reader is done.
function _row_span!(r::SheetReader, count::Int)
    rowno = r.nextrow
    count = min(count, SheetCore.MAX_ROWS - rowno + 1)
    r.nextrow = rowno + count
    if rowno > r.stop_after
        r.done = true
        return rowno, count, false
    end
    return rowno, count, !(rowno + count - 1 < r.skip_before || count <= 0)
end

const _NO_ATTR = SubString("", 1, 0)

"""
    CellAttrs

The attributes of a `table:table-cell` that the reader uses, as read by the cursor walk or
the byte scanner; values are as XML.jl reports them.
"""
struct CellAttrs
    count::Int
    style::Int32
    vtype::SubString{String}     # office:value-type
    cvtype::SubString{String}    # calcext:value-type
    value::SubString{String}
    datev::SubString{String}
    timev::SubString{String}
    boolv::SubString{String}
    strv::Union{Nothing,String}
    currency::Union{Nothing,String}
    formula::Union{Nothing,String}
    colspan::Int
    rowspan::Int
end

# Reads the cell at the cursor `c`, starting at column `col`; pushes its run if it has
# content. Returns the column after it.
function _read_cell!(r::SheetReader, c::XML.Cursor, rowno::Int, rowcount::Int, col::Int, rowdefault::Int32, covered::Bool)
    a = _cursor_cell_attrs(r, c)
    count = min(a.count, SheetCore.MAX_COLS - col + 1)
    count <= 0 && (XML.skip_element!(c); return col)
    kind, flags, bits, text, needs_text = _cell_value(a, covered)
    if needs_text
        kind, text = _with_text(kind, text, _cell_text!(r, c))   # consumes the cell's children
    else
        XML.skip_element!(c)
    end
    return _store_cell!(r, a, rowno, rowcount, col, count, rowdefault, kind, flags, bits, text)
end

function _cursor_cell_attrs(r::SheetReader, c::XML.Cursor)
    count = 1
    style = Int32(-1)
    vtype = _NO_ATTR     # office:value-type
    cvtype = _NO_ATTR    # calcext:value-type
    value = _NO_ATTR; datev = _NO_ATTR; timev = _NO_ATTR; boolv = _NO_ATTR
    strv = nothing; currency = nothing
    formula = nothing
    colspan = 1; rowspan = 1
    for (k, v) in XML.eachattribute!(c)
        # by frequency in LibreOffice output
        if k == "office:value-type"
            vtype = v
        elseif k == "calcext:value-type"
            cvtype = v
        elseif k == "office:value"
            value = v
        elseif k == "table:style-name"
            style = style_id(r.styles, v)
        elseif k == "table:number-columns-repeated"
            count = max(1, something(tryparse(Int, v), 1))
        elseif k == "table:formula"
            formula = String(v)
        elseif k == "office:date-value"
            datev = v
        elseif k == "office:time-value"
            timev = v
        elseif k == "office:boolean-value"
            boolv = v
        elseif k == "office:string-value"
            strv = String(v)
        elseif k == "office:currency"
            currency = String(v)
        elseif k == "table:number-columns-spanned"
            colspan = max(1, something(tryparse(Int, v), 1))
        elseif k == "table:number-rows-spanned"
            rowspan = max(1, something(tryparse(Int, v), 1))
        end
    end
    return CellAttrs(count, style, vtype, cvtype, value, datev, timev, boolv, strv, currency, formula, colspan, rowspan)
end

# The cell's value from its attributes: (kind, flags, bits, text, needs_text), where
# `needs_text` asks for the text of its paragraphs.
@inline function _cell_value(a::CellAttrs, covered::Bool)
    vtype = a.vtype; cvtype = a.cvtype; value = a.value
    kind = CK_EMPTY; flags = covered ? F_COVERED : 0x00; bits = UInt64(0); text = nothing
    needs_text = false
    if cvtype == "error"
        kind = CK_ERROR; needs_text = true
    elseif vtype == "float" || vtype == "percentage" || vtype == "currency"
        kind = vtype == "float" ? CK_FLOAT : vtype == "percentage" ? CK_PERCENT : CK_CURRENCY
        bits = reinterpret(UInt64, _parse_float(value))
        _is_intlike(value) && (flags |= F_INTLIKE)
        kind === CK_CURRENCY && (text = a.currency)
    elseif vtype == "date"
        d = parse_odf_date(a.datev)
        if d isa Dates.Date
            kind = CK_DATE; bits = reinterpret(UInt64, Dates.value(d))
        elseif d isa Dates.DateTime
            kind = CK_DATETIME; bits = reinterpret(UInt64, Dates.value(d))
        end
    elseif vtype == "time"
        ns = parse_odf_duration(a.timev)
        ns === nothing || (kind = CK_TIME; bits = reinterpret(UInt64, ns))
    elseif vtype == "boolean"
        kind = CK_BOOL
        bits = UInt64(a.boolv == "true" || a.boolv == "1")
    elseif vtype == "string"
        kind = CK_STRING
        a.strv === nothing ? (needs_text = true) : (text = a.strv)
    elseif vtype == "" || vtype == "void"
        # F-022: paragraphs without a value type are a string (unless it is a formula
        # without a result, written with an empty paragraph)
        needs_text = true
    end
    return kind, flags, bits, text, needs_text
end

# The kind and text once the paragraphs' text `t` (`nothing`: no paragraph) is read.
@inline function _with_text(kind::CellKind, text, t::Union{Nothing,String})
    if kind === CK_EMPTY
        (t === nothing || isempty(t)) && return kind, text
        return CK_STRING, t
    end
    return kind, something(t, "")
end

# Stores the cell (its run, if it has content, and its merge); returns the column after it.
function _store_cell!(r::SheetReader, a::CellAttrs, rowno::Int, rowcount::Int, col::Int, count::Int,
                      rowdefault::Int32, kind::CellKind, flags::UInt8, bits::UInt64, text)
    formula = a.formula; colspan = a.colspan; rowspan = a.rowspan
    # the effective style (F-009): the cell's own, else the row's, else the column's
    style = a.style
    if style < 0
        style = rowdefault
    end
    if colspan > 1 || rowspan > 1
        for k in 0:rowcount-1, j in 0:count-1
            push!(r.merges, CellRange(CellRef(rowno + k, col + j), CellRef(rowno + k + rowspan - 1, col + j + colspan - 1)))
        end
    end
    if kind !== CK_EMPTY || formula !== nothing
        if style >= 0
            push!(r.runs, CellRun(col, count, CellData(kind, flags, style, bits, text, formula, colspan, rowspan)))
        else
            _push_col_styled!(r, col, count, CellData(kind, flags, Int32(0), bits, text, formula, colspan, rowspan))
        end
    end
    return col + count
end

# Pushes a run whose style comes from the column defaults, split where those differ.
function _push_col_styled!(r::SheetReader, col::Int, count::Int, d::CellData)
    last = col + count - 1
    a = col
    while a <= last
        s = _col_default(r, a)
        b = a
        while b < last && _col_default(r, b + 1) == s
            b += 1
        end
        st = s < 0 ? Int32(0) : Int32(s)
        push!(r.runs, CellRun(a, b - a + 1, CellData(d.kind, d.flags, st, d.bits, d.text, d.formula, d.colspan, d.rowspan)))
        a = b + 1
    end
    return
end

# The text of the cell at the cursor (F-021): its text:p / text:h paragraphs joined by
# "\n"; text:s is spaces (`text:c`, default 1), text:tab a tab, text:line-break a newline;
# spans, links and other inline elements give their text; annotations are skipped.
# Returns `nothing` when the cell has no paragraph. Consumes the cell's children.
function _cell_text!(r::SheetReader, c::XML.Cursor)
    buf = r.text
    truncate(buf, 0)
    nparas = 0
    XML.@for_each_child! c ch begin
        if XML.nodetype(ch) === XML.Element
            t = XML.tag(ch)
            if t == "text:p" || t == "text:h"
                nparas > 0 && write(buf, '\n')
                nparas += 1
                _para_text!(buf, ch)
            else
                XML.skip_element!(ch)    # office:annotation, draw:frame, ...
            end
        end
    end
    return _paragraphs_text(buf, nparas)
end

# The text written to `buf` for `nparas` paragraphs (`nothing` for none), with any CR as
# a line end.
function _paragraphs_text(buf::IOBuffer, nparas::Int)
    nparas == 0 && return nothing
    s = String(take!(buf))
    return occursin('\r', s) ? replace(s, "\r\n" => "\n", '\r' => '\n') : s
end

function _para_text!(buf::IOBuffer, c::XML.Cursor)
    XML.@for_each_child! c ch begin
        nt = XML.nodetype(ch)
        if nt === XML.Text || nt === XML.CData
            v = XML.value(ch)
            v === nothing || write(buf, v)
        elseif nt === XML.Element
            t = XML.tag(ch)
            if t == "text:s"
                n = 1
                for (k, v) in XML.eachattribute!(ch)
                    k == "text:c" && (n = something(tryparse(Int, v), 1))
                end
                for _ in 1:n
                    write(buf, ' ')
                end
                XML.skip_element!(ch)
            elseif t == "text:tab"
                write(buf, '\t'); XML.skip_element!(ch)
            elseif t == "text:line-break"
                write(buf, '\n'); XML.skip_element!(ch)
            elseif t == "office:annotation" || t == "text:note" || startswith(t, "draw:")
                XML.skip_element!(ch)
            else
                _para_text!(buf, ch)     # text:span, text:a, text:meta, ...
            end
        end
    end
    return
end

#
# The sheet store: every row with content, for the cache and for uncached range reads
#

"""
    SheetStore

The rows of a sheet that have content, as `RowData` in row order, with the column runs, the
merges, and the bounds of the content (`nothing` for a sheet without any). Edits
(`store_set!`) keep the bounds up to date when they grow them, and mark them stale when a
cell is removed; `store_dimension` recomputes stale bounds.
"""
mutable struct SheetStore
    rows::Vector{RowData}
    cols::Vector{ColRun}
    merges::Vector{CellRange}
    dimension::Union{Nothing,CellRange}
    stale::Bool
end
SheetStore(rows, cols, merges, dim) = SheetStore(rows, cols, merges, dim, false)
SheetStore() = SheetStore(RowData[], ColRun[], CellRange[], nothing, false)

"""
    store_dimension(s::SheetStore) -> Union{CellRange, Nothing}

The bounds of the stored cells, recomputed if edits have removed cells since.
"""
function store_dimension(s::SheetStore)
    s.stale || return s.dimension
    minc = typemax(Int); maxc = 0
    for rd in s.rows
        isempty(rd.runs) && continue
        minc = min(minc, Int(rd.runs[1].col))
        maxc = max(maxc, _lastcol(rd.runs[end]))
    end
    s.dimension = isempty(s.rows) ? nothing :
        CellRange(CellRef(Int(s.rows[1].row), minc), CellRef(_lastrow(s.rows[end]), maxc))
    s.stale = false
    return s.dimension
end

"""
    read_store(node, styles; skip_before=1, stop_after=MAX_ROWS) -> SheetStore

Read the sheet's rows with content (only those between `skip_before` and `stop_after`).
"""
function read_store(node::XML.LazyNode{String}, styles::StyleIndex;
                    skip_before::Integer = 1, stop_after::Integer = SheetCore.MAX_ROWS)
    r = SheetReader(node, styles; skip_before, stop_after)
    rows = RowData[]
    minc = typemax(Int); maxc = 0
    while true
        row = next_row!(r)
        row === nothing && break
        push!(rows, row)
        minc = min(minc, Int(row.runs[1].col))
        maxc = max(maxc, _lastcol(row.runs[end]))
    end
    dim = isempty(rows) ? nothing :
          CellRange(CellRef(Int(rows[1].row), minc), CellRef(_lastrow(rows[end]), maxc))
    return SheetStore(rows, r.cols, r.merges, dim)
end

# The row holding row number `row`, or `nothing`.
_row_at(s::SheetStore, row::Integer) = _row_at(s.rows, row)
function _row_at(rows::Vector{RowData}, row::Integer)
    lo, hi = 1, length(rows)
    while lo <= hi
        mid = (lo + hi) >>> 1
        @inbounds rd = rows[mid]
        if row < rd.row
            hi = mid - 1
        elseif row > _lastrow(rd)
            lo = mid + 1
        else
            return rd
        end
    end
    return nothing
end

# The stored data of cell (row, col), or `nothing`.
function cell_data(s::SheetStore, row::Integer, col::Integer)
    rd = _row_at(s, row)
    rd === nothing && return nothing
    run = _run_at(rd.runs, col)
    run === nothing ? nothing : run.data
end

# The index of the first stored row that ends at or after `row` (length + 1 if none).
_first_row_index(s::SheetStore, row::Integer) = _first_row_index(s.rows, row)
function _first_row_index(rows::Vector{RowData}, row::Integer)
    lo, hi = 1, length(rows)
    while lo <= hi
        mid = (lo + hi) >>> 1
        if _lastrow(@inbounds rows[mid]) < row
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    return lo
end

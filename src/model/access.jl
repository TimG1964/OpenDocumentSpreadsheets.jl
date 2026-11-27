# Reading cells and values: `getdata`, `getcell`, `getcellrange`, indexing, `readdata`,
# `iserror`/`geterror`.
#
# Adapted from XLSX.jl 0.13.4 (src/worksheet.jl `ref_chooser`, `getdata`, `getcell`,
# `getcellrange`; src/workbook.jl the file-level forms; src/read.jl `readdata`;
# src/cell.jl `iserror`/`geterror`), MIT License, Copyright (c) 2018-2026 Felipe Noronha
# Tavares and other contributors. Changes: values come from the run-length store
# (sheetreader.jl); sheet-qualified references use LibreOffice's notation and also accept
# Excel's (D-014, D-015); plain references may carry `$` marks; lists of ranges may use
# `~` or `,`.

#
# Filling from the store
#

# Calls f(row, col, data) for each stored cell in rows top:bottom × columns left:right.
function _each_stored(f::F, s::SheetStore, top::Int, bottom::Int, left::Int, right::Int) where {F}
    i = _first_row_index(s, top)
    rows = s.rows
    while i <= length(rows)
        @inbounds rd = rows[i]
        rd.row > bottom && break
        r1 = max(Int(rd.row), top); r2 = min(_lastrow(rd), bottom)
        for run in rd.runs
            run.col > right && break
            c1 = max(Int(run.col), left); c2 = min(_lastcol(run), right)
            c1 > c2 && continue
            for r in r1:r2, c in c1:c2
                f(r, c, run.data)
            end
        end
        i += 1
    end
    return
end

function _data_matrix(ws::Worksheet, s::SheetStore, rng::CellRange)::Matrix{Any}
    top, left = row_number(rng.start), column_number(rng.start)
    bottom, right = row_number(rng.stop), column_number(rng.stop)
    result = Matrix{Any}(missing, bottom - top + 1, right - left + 1)
    styles = get_odsfile(ws).styles
    _each_stored(s, top, bottom, left, right) do r, c, d
        @inbounds result[r - top + 1, c - left + 1] = cell_value(d, styles)
    end
    return result
end

function _cell_matrix(ws::Worksheet, s::SheetStore, rng::CellRange)::Matrix{AbstractCell}
    top, left = row_number(rng.start), column_number(rng.start)
    bottom, right = row_number(rng.stop), column_number(rng.stop)
    result = Matrix{AbstractCell}(undef, bottom - top + 1, right - left + 1)
    for c in left:right, r in top:bottom
        result[r - top + 1, c - left + 1] = EmptyCell(CellRef(r, c))
    end
    styles = get_odsfile(ws).styles
    _each_stored(s, top, bottom, left, right) do r, c, d
        @inbounds result[r - top + 1, c - left + 1] = Cell(CellRef(r, c), d, styles)
    end
    return result
end

_rows_of(rng::CellRange) = row_number(rng.start):row_number(rng.stop)

# Rows `rows`, cols `cols` of a sheet whose dimension is not known yet: one store serves
# both the dimension and the values.
function _span_range(s::SheetStore, rows, cols)
    dim = something(store_dimension(s), CellRange(CellRef(1, 1), CellRef(1, 1)))
    r = rows === nothing ? (row_number(dim.start):row_number(dim.stop)) : rows
    c = cols === nothing ? (column_number(dim.start):column_number(dim.stop)) : cols
    return CellRange(CellRef(first(r), first(c)), CellRef(last(r), last(c)))
end

#
# Sheet names in references
#

function do_sheet_names_match(ws::Worksheet, sheet::AbstractString)
    (sheet == ws.name || _same_sheetname(sheet, ws.name)) && return true
    throw(ODSError("The reference names sheet `$sheet`, not `$(ws.name)`."))
end
do_sheet_names_match(ws::Worksheet, r) = do_sheet_names_match(ws, r.sheet)

# A plain (not sheet-qualified) reference with its `$` marks removed, or `nothing` if `ref`
# names a sheet.
function _plain_ref(ref::AbstractString)
    (occursin('.', ref) || occursin('!', ref) || occursin('\'', ref)) && return nothing
    return replace(ref, "\$" => "")
end

_is_list(ref::AbstractString) = length(SheetCore._split_unquoted(ref, ('~', ','))) > 1

# A list of areas on `ws`; areas may leave the sheet out (`A1:A4,C1`, `A1~C1`).
function _nc_on_sheet(ws::Worksheet, ref::AbstractString)::NonContiguousRange
    areas = Vector{Union{CellRef,CellRange}}()
    for it in SheetCore._split_unquoted(ref, ('~', ','))
        s, x = SheetCore._odf_parse_area(it)
        s === nothing || do_sheet_names_match(ws, s)
        x isa Union{CellRef,CellRange} ||
            throw(ODSError("`$ref`: a list of ranges holds cells and cell ranges only."))
        push!(areas, x)
    end
    return NonContiguousRange(ws.name, areas)
end

"""
    ref_chooser(f, ws::Worksheet, ref::AbstractString)

Resolve `ref` on `ws` and call `f(ws, typed_ref)`, or `f(xf, …)` for a defined name, the sheet's
own or the workbook's, that refers to cells: its reference names its sheet, which may be another
one, as in LibreOffice (Q-031). Tried in order: a cell (`A1`, `\$A\$1`), a cell range, a column
range (`A:C`), a row range (`2:5`), a name local to the sheet, a workbook name, a list of
areas (`A1:A4,C1` or `A1:A4~C1`), and a sheet-qualified reference in LibreOffice's or
Excel's notation (`Sheet1.A1:B2`, `Sheet1!A1:B2`), which must name this sheet.

XLSX.jl tries names first; the order makes no difference, because LibreOffice does not allow
names that read as cell or range references. Trying references first spares reading the
workbook's names, which come after every sheet in the file.
"""
function ref_chooser(f::Function, ws::Worksheet, ref::AbstractString)
    ref = String(ref)
    p = _plain_ref(ref)
    if p !== nothing
        is_valid_cellname(p) && return f(ws, CellRef(p))
        is_valid_cellrange(p) && return f(ws, CellRange(p))
        is_valid_column_range(p) && return f(ws, ColumnRange(p))
        is_valid_row_range(p) && return f(ws, RowRange(p))
    end
    if is_worksheet_defined_name(ws, ref)
        # a sheet's own name may refer to cells on another sheet, which LibreOffice reads there (Q-031)
        v = get_defined_name_value(ws, ref)
        return is_defined_name_value_a_reference(v) ? f(get_odsfile(ws), v) : v
    elseif is_workbook_defined_name(get_odsfile(ws), ref)
        v = get_defined_name_value(get_odsfile(ws), ref)
        return is_defined_name_value_a_reference(v) ? f(get_odsfile(ws), v) : v
    end
    if _is_list(ref)
        return f(ws, _nc_on_sheet(ws, ref))
    end
    typed = try
        parse_sheet_ref(ref)
    catch e
        e isa ODSError || rethrow()
        throw(ODSError("`$ref` is not a valid cell or range reference."))
    end
    return f(ws, typed)
end

function ref_chooser(f::Function, xf::ODSFile, ref::AbstractString)
    ref = String(ref)
    # a sheet-qualified reference first (a name can't read as one), then a name
    typed = try
        parse_sheet_ref(ref)
    catch e
        e isa ODSError || rethrow()
        nothing
    end
    typed === nothing || return f(xf, typed)
    if is_workbook_defined_name(xf, ref)
        v = get_defined_name_value(xf, ref)
        return is_defined_name_value_a_reference(v) ? f(xf, v) : v
    end
    throw(ODSError("`$ref` is not a valid sheet reference (such as `Sheet1.A1` or `Sheet1!A1:B2`) or defined name."))
end

#
# getdata
#

"""
    getdata(sheet, ref)
    getdata(sheet, row, column)
    getdata(sheet)

Values from a worksheet: a scalar for a single cell, a `Matrix{Any}` for a rectangular
range, or a vector of matrices for a list of ranges. Empty cells, empty strings and errors
read as `missing`.

`ref` is a cell or range (`"A1"`, `"A1:C4"`, `"A:B"`, `"1:4"`, `"A1:A4,C1"`), one with its
sheet named (`"Sheet1.A1:C4"`; `"Sheet1!A1:C4"` also works), or a named range. Rows and columns can also be integers, unit ranges,
step ranges, vectors or `:`. For whole columns or rows, the other extent is the sheet's
[`get_dimension`](@ref).

Indexing a `Worksheet` calls `getdata`: `sheet["A1"]`, `sheet[1:3, 2]`, `sheet[:]`.

The value types are described in [`Cell`](@ref): Int64 or Float64 for numbers, `String`,
`Bool`, `Date` or `DateTime`, and `Time` (or a `CompoundPeriod` for 24 hours or more).
"""
getdata(ws::Worksheet, ref::AbstractString) = ref_chooser(getdata, ws, ref)
getdata(::Worksheet, cell::Cell) = cell.value
getdata(::Worksheet, ::EmptyCell) = missing

function getdata(ws::Worksheet, single::CellRef)
    r, c = row_number(single), column_number(single)
    d = cell_data(_store_for(ws, r:r), r, c)
    return d === nothing ? missing : cell_value(d, get_odsfile(ws).styles)
end
getdata(ws::Worksheet, row::Integer, col::Integer) = getdata(ws, CellRef(row, col))
getdata(ws::Worksheet, rng::CellRange) = _data_matrix(ws, _store_for(ws, _rows_of(rng)), rng)

function getdata(ws::Worksheet, rng::ColumnRange)
    s = _store_for(ws)
    return _data_matrix(ws, s, _span_range(s, nothing, rng.start:rng.stop))
end
function getdata(ws::Worksheet, rng::RowRange)
    s = _store_for(ws)   # the dimension needs the whole sheet
    return _data_matrix(ws, s, _span_range(s, rng.start:rng.stop, nothing))
end
function getdata(ws::Worksheet, rng::NonContiguousRange)
    do_sheet_names_match(ws, rng)
    return [getdata(ws, r isa CellRef ? CellRange(r, r) : r) for r in rng.rng]
end
getdata(ws::Worksheet, s::SheetCellRef) = (do_sheet_names_match(ws, s); getdata(ws, s.cellref))
getdata(ws::Worksheet, s::SheetCellRange) = (do_sheet_names_match(ws, s); getdata(ws, s.rng))
getdata(ws::Worksheet, s::SheetColumnRange) = (do_sheet_names_match(ws, s); getdata(ws, s.colrng))
getdata(ws::Worksheet, s::SheetRowRange) = (do_sheet_names_match(ws, s); getdata(ws, s.rowrng))

function getdata(ws::Worksheet)
    s = _store_for(ws)
    return _data_matrix(ws, s, _span_range(s, nothing, nothing))
end
getdata(ws::Worksheet, ::Colon) = getdata(ws)
getdata(ws::Worksheet, ::Colon, ::Colon) = getdata(ws)

const _Span = Union{Integer,AbstractUnitRange{<:Integer}}
const _Pick = Union{AbstractVector{<:Integer},StepRange{<:Integer}}

getdata(ws::Worksheet, row::_Span, col::_Span) =
    getdata(ws, CellRange(CellRef(first(row), first(col)), CellRef(last(row), last(col))))
function getdata(ws::Worksheet, row::_Span, ::Colon)
    s = _store_for(ws)
    return _data_matrix(ws, s, _span_range(s, first(row):last(row), nothing))
end
function getdata(ws::Worksheet, ::Colon, col::_Span)
    s = _store_for(ws)
    return _data_matrix(ws, s, _span_range(s, nothing, first(col):last(col)))
end

# element by element, from one store covering the rows
function _getdata_each(ws::Worksheet, rows, cols)
    rr = collect(Int, rows)
    s = isempty(rr) ? _store_for(ws, 1:0) : _store_for(ws, minimum(rr):maximum(rr))
    styles = get_odsfile(ws).styles
    return Any[(d = cell_data(s, a, b); d === nothing ? missing : cell_value(d, styles)) for a in rows, b in cols]
end
getdata(ws::Worksheet, row::_Span, col::_Pick) = _getdata_each(ws, row, col)
getdata(ws::Worksheet, row::_Pick, col::_Span) = _getdata_each(ws, row, col)
getdata(ws::Worksheet, row::_Pick, col::_Pick) = _getdata_each(ws, row, col)
function getdata(ws::Worksheet, row::_Pick, ::Colon)
    dim = get_dimension(ws)
    return _getdata_each(ws, row, column_number(dim.start):column_number(dim.stop))
end
function getdata(ws::Worksheet, ::Colon, col::_Pick)
    dim = get_dimension(ws)
    return _getdata_each(ws, row_number(dim.start):row_number(dim.stop), col)
end

Base.getindex(ws::Worksheet, r) = getdata(ws, r)
Base.getindex(ws::Worksheet, r, c) = getdata(ws, r, c)
Base.getindex(ws::Worksheet, ::Colon) = getdata(ws)

# file level
getdata(xf::ODSFile, s::AbstractString) = ref_chooser(getdata, xf, s)
getdata(xf::ODSFile, r::SheetCellRef) = getdata(getsheet(xf, r.sheet), r.cellref)
getdata(xf::ODSFile, r::SheetCellRange) = getdata(getsheet(xf, r.sheet), r.rng)
getdata(xf::ODSFile, r::SheetColumnRange) = getdata(getsheet(xf, r.sheet), r.colrng)
getdata(xf::ODSFile, r::SheetRowRange) = getdata(getsheet(xf, r.sheet), r.rowrng)
getdata(xf::ODSFile, r::NonContiguousRange) = getdata(getsheet(xf, r.sheet), r)

#
# getcell / getcellrange
#

"""
    getcell(sheet, ref)
    getcell(sheet, row, col)

The [`Cell`](@ref) at `ref`, or an [`EmptyCell`](@ref) where the sheet holds nothing. For a
range, a `Matrix{AbstractCell}` (see [`getcellrange`](@ref)); `ref` takes the same forms as
in [`getdata`](@ref).
"""
function getcell(ws::Worksheet, single::CellRef)::AbstractCell
    r, c = row_number(single), column_number(single)
    d = cell_data(_store_for(ws, r:r), r, c)
    return d === nothing ? EmptyCell(single) : Cell(single, d, get_odsfile(ws).styles)
end
getcell(ws::Worksheet, row::Integer, col::Integer) = getcell(ws, CellRef(row, col))
getcell(ws::Worksheet, ref::AbstractString) = ref_chooser(getcell, ws, ref)
getcell(ws::Worksheet, s::SheetCellRef) = (do_sheet_names_match(ws, s); getcell(ws, s.cellref))
getcell(ws::Worksheet, s::Union{CellRange,ColumnRange,RowRange,NonContiguousRange,SheetCellRange,SheetColumnRange,SheetRowRange}) =
    getcellrange(ws, s)
getcell(ws::Worksheet, row::Union{_Span,_Pick}, col::Union{_Span,_Pick}) = getcellrange(ws, row, col)
getcell(ws::Worksheet, row::Union{_Span,_Pick}, ::Colon) = getcellrange(ws, row, :)
getcell(ws::Worksheet, ::Colon, col::Union{_Span,_Pick}) = getcellrange(ws, :, col)
getcell(ws::Worksheet, ::Colon) = getcellrange(ws, :)

"""
    getcellrange(sheet, rng)

The cells of a range as a `Matrix{AbstractCell}`, or a vector of matrices for a list of
ranges. `rng` takes the forms of [`getdata`](@ref).
"""
getcellrange(ws::Worksheet, rng::CellRange) = _cell_matrix(ws, _store_for(ws, _rows_of(rng)), rng)
function getcellrange(ws::Worksheet, rng::ColumnRange)
    s = _store_for(ws)
    return _cell_matrix(ws, s, _span_range(s, nothing, rng.start:rng.stop))
end
function getcellrange(ws::Worksheet, rng::RowRange)
    s = _store_for(ws)
    return _cell_matrix(ws, s, _span_range(s, rng.start:rng.stop, nothing))
end
function getcellrange(ws::Worksheet, rng::NonContiguousRange)
    do_sheet_names_match(ws, rng)
    return [getcellrange(ws, r isa CellRef ? CellRange(r, r) : r) for r in rng.rng]
end
getcellrange(ws::Worksheet, s::SheetCellRange) = (do_sheet_names_match(ws, s); getcellrange(ws, s.rng))
getcellrange(ws::Worksheet, s::SheetColumnRange) = (do_sheet_names_match(ws, s); getcellrange(ws, s.colrng))
getcellrange(ws::Worksheet, s::SheetRowRange) = (do_sheet_names_match(ws, s); getcellrange(ws, s.rowrng))
getcellrange(ws::Worksheet, ref::AbstractString) = ref_chooser(getcellrange, ws, ref)
getcellrange(ws::Worksheet, row::_Span, col::_Span) =
    getcellrange(ws, CellRange(CellRef(first(row), first(col)), CellRef(last(row), last(col))))
function getcellrange(ws::Worksheet, row::_Span, ::Colon)
    s = _store_for(ws)
    return _cell_matrix(ws, s, _span_range(s, first(row):last(row), nothing))
end
function getcellrange(ws::Worksheet, ::Colon, col::_Span)
    s = _store_for(ws)
    return _cell_matrix(ws, s, _span_range(s, nothing, first(col):last(col)))
end
function getcellrange(ws::Worksheet, ::Colon)
    s = _store_for(ws)
    return _cell_matrix(ws, s, _span_range(s, nothing, nothing))
end
function _getcell_each(ws::Worksheet, rows, cols)
    rr = collect(Int, rows)
    s = isempty(rr) ? _store_for(ws, 1:0) : _store_for(ws, minimum(rr):maximum(rr))
    styles = get_odsfile(ws).styles
    return AbstractCell[(d = cell_data(s, a, b); d === nothing ? EmptyCell(CellRef(a, b)) : Cell(CellRef(a, b), d, styles))
                        for a in rows, b in cols]
end
getcellrange(ws::Worksheet, row::_Span, col::_Pick) = _getcell_each(ws, row, col)
getcellrange(ws::Worksheet, row::_Pick, col::Union{_Span,_Pick}) = _getcell_each(ws, row, col)
function getcellrange(ws::Worksheet, row::_Pick, ::Colon)
    dim = get_dimension(ws)
    return _getcell_each(ws, row, column_number(dim.start):column_number(dim.stop))
end
function getcellrange(ws::Worksheet, ::Colon, col::_Pick)
    dim = get_dimension(ws)
    return _getcell_each(ws, row_number(dim.start):row_number(dim.stop), col)
end

# file level
getcell(xf::ODSFile, s::AbstractString) = ref_chooser(getcell, xf, s)
getcell(xf::ODSFile, r::SheetCellRef) = getcell(getsheet(xf, r.sheet), r.cellref)
getcell(xf::ODSFile, r::Union{SheetCellRange,SheetColumnRange,SheetRowRange,NonContiguousRange}) = getcellrange(xf, r)
getcellrange(xf::ODSFile, s::AbstractString) = ref_chooser(getcellrange, xf, s)
getcellrange(xf::ODSFile, r::SheetCellRange) = getcellrange(getsheet(xf, r.sheet), r.rng)
getcellrange(xf::ODSFile, r::SheetColumnRange) = getcellrange(getsheet(xf, r.sheet), r.colrng)
getcellrange(xf::ODSFile, r::SheetRowRange) = getcellrange(getsheet(xf, r.sheet), r.rowrng)
getcellrange(xf::ODSFile, r::NonContiguousRange) = getcellrange(getsheet(xf, r.sheet), r)

#
# Errors
#

"""
    iserror(sheet, ref)
    iserror(sheet, row, col)

Whether a cell holds an error result (`#DIV/0!`, `#N/A`, `Err:502`, ...), which
[`getdata`](@ref) reads as `missing`. For a range, a matrix of `Bool`s (a vector of them
for a list of ranges). The ODF file marks errors with `calcext:value-type="error"`.
"""
iserror(c::AbstractCell) = c isa Cell && c.datatype === :error
iserror(ws::Worksheet, args...) = _map_cells(iserror, getcell(ws, args...))
iserror(xf::ODSFile, ref::AbstractString) = _map_cells(iserror, getcell(xf, ref))

"""
    geterror(sheet, ref)
    geterror(sheet, row, col)

The displayed text of an error result, such as `"#DIV/0!"` or `"Err:502"`, or `""` for a
cell without one. For a range, a matrix of strings.
"""
geterror(c::AbstractCell) = iserror(c) ? something(c.error, "") : ""
geterror(ws::Worksheet, args...) = _map_cells(geterror, getcell(ws, args...))
geterror(xf::ODSFile, ref::AbstractString) = _map_cells(geterror, getcell(xf, ref))

_map_cells(f, c::AbstractCell) = f(c)
_map_cells(f, m::AbstractMatrix) = map(f, m)
_map_cells(f, v::AbstractVector) = [_map_cells(f, x) for x in v]

#
# readdata
#

"""
    readdata(source, sheet, ref)
    readdata(source, sheetref)

Open `source` (a path or an `IO`) without the cache, and return [`getdata`](@ref) of `ref`
on `sheet` (a name or a number), or of a sheet-qualified reference such as
`"Sheet1.A1:B3"` (`"Sheet1!A1:B3"` also works).

```julia
readdata("budget.ods", "Costs", "B2:B4")   # a 3×1 matrix: 50.0, 100.0, 150.0
readdata("budget.ods", "Costs.B2")         # 50.0
```
"""
function readdata(source::Union{AbstractString,IO}, sheet::Union{AbstractString,Integer}, ref)
    # a workbook name is stored after all the sheets: then the whole file is read
    plain = !(ref isa AbstractString) || _plain_ref(ref) !== nothing && (is_valid_cellname(_plain_ref(ref)) ||
            is_valid_cellrange(_plain_ref(ref)) || is_valid_column_range(_plain_ref(ref)) || is_valid_row_range(_plain_ref(ref)))
    xf = plain ? _open_through(source, sheet) : openods(source; enable_cache = false)
    return getdata(getsheet(xf, sheet), ref)
end

function readdata(source::Union{AbstractString,IO}, sheetref::AbstractString)
    ref = try parse_sheet_ref(sheetref) catch; nothing end
    ref === nothing && return getdata(openods(source; enable_cache = false), sheetref)   # a name
    return getdata(_open_through(source, ref.sheet), ref)
end

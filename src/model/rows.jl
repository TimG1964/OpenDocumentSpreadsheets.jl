# Rows: `SheetRow`, `eachrow` over the cache, and the streaming `SheetRowStreamIterator`
# (enable_cache=false). Both give every row that has at least one cell with a value or a
# formula, expanding repeated rows (`number-rows-repeated`) into one row each (D-020).
# Rows without content, such as LibreOffice's padding rows and the 1048576-row tails of
# whole-column styles, are not given: this is the ODS counterpart of XLSX.jl giving only
# the rows present in the file.
#
# SheetRow's accessors follow XLSX.jl 0.13.4 (src/stream.jl `row_number`, `getcell`,
# `getdata`, `isempty` of a `SheetRow`), MIT License, Copyright (c) 2018-2026 Felipe
# Noronha Tavares and other contributors.

"""
    SheetRow

A row of a worksheet, as [`eachrow`](@ref Base.eachrow(::Worksheet)) gives it. `row_number(r)` is its number;
`r[col]` (a column number or name such as `"B"`) is a value, `getcell(r, col)` a cell.
"""
struct SheetRow
    sheet::Worksheet
    row::Int
    data::RowData
end

SheetCore.row_number(r::SheetRow) = r.row

function getcell(r::SheetRow, col::Integer)::AbstractCell
    run = _run_at(r.data.runs, col)
    run === nothing && return EmptyCell(CellRef(r.row, col))
    return Cell(CellRef(r.row, col), run.data, get_odsfile(r.sheet).styles)
end
getcell(r::SheetRow, col::AbstractString) = getcell(r, SheetCore.decode_column_number(col))

function getdata(r::SheetRow, col::Integer)
    run = _run_at(r.data.runs, col)
    run === nothing && return missing
    return cell_value(run.data, get_odsfile(r.sheet).styles)
end
getdata(r::SheetRow, col::AbstractString) = getdata(r, SheetCore.decode_column_number(col))
getdata(r::SheetRow, cols::Union{AbstractVector,AbstractRange}) = Any[getdata(r, c) for c in cols]

Base.getindex(r::SheetRow, x) = getdata(r, x)
Base.isempty(r::SheetRow) = isempty(r.data.runs)

function Base.show(io::IO, r::SheetRow)
    print(io, "SheetRow(", repr(r.sheet.name), ", row ", r.row, ")")
end

# The row protocol of SheetCore's table reader (src/core/tablerows.jl)
SheetCore.table_row_value(r::SheetRow, col::Int) = getdata(r, col)
SheetCore.table_row_isempty(r::SheetRow) = isempty(r.data.runs)
SheetCore.table_row_columns(r::SheetRow) = Int[c for run in r.data.runs for c in run.col:_lastcol(run)]
# A SheetRow's runs are its own (the reader copies them), so rows can be held in batches.
SheetCore.table_rows_batchable(::Type{SheetRow}) = true
function SheetCore.table_push_value!(col::Vector, r::SheetRow, column::Int, ms::Set{String})
    run = _run_at(r.data.runs, column)
    run === nothing && return SheetCore._push_column!(col, missing)
    return _with_cell_value(run.data, get_odsfile(r.sheet).styles) do x
        SheetCore._push_column!(col, SheetCore._apply_missing_strings(x, ms))
    end
end

#
# Iterators
#

"""
    WorksheetRows

The rows of a cached sheet, as [`eachrow`](@ref Base.eachrow(::Worksheet)) gives them.
"""
struct WorksheetRows
    sheet::Worksheet
    store::SheetStore
end

Base.show(io::IO, it::WorksheetRows) = print(io, "WorksheetRows(", repr(it.sheet.name), ", ", length(it), " rows)")

Base.eltype(::Type{WorksheetRows}) = SheetRow
Base.IteratorSize(::Type{WorksheetRows}) = Base.HasLength()
Base.length(it::WorksheetRows) = sum(Int(rd.count) for rd in it.store.rows; init = 0)

function Base.iterate(it::WorksheetRows, st::Tuple{Int,Int} = (1, 0))
    i, k = st
    rows = it.store.rows
    i > length(rows) && return nothing
    @inbounds rd = rows[i]
    row = SheetRow(it.sheet, Int(rd.row) + k, rd)
    return row, (k + 1 < rd.count ? (i, k + 1) : (i + 1, 0))
end

"""
    SheetRowStreamIterator

The rows of a sheet read as they are iterated, keeping nothing: [`eachrow`](@ref Base.eachrow(::Worksheet)) with the
cache off. Each iteration from the start reads the sheet again.
"""
struct SheetRowStreamIterator
    sheet::Worksheet
end

Base.show(io::IO, it::SheetRowStreamIterator) = print(io, "SheetRowStreamIterator(", repr(it.sheet.name), ")")

Base.eltype(::Type{SheetRowStreamIterator}) = SheetRow
Base.IteratorSize(::Type{SheetRowStreamIterator}) = Base.SizeUnknown()

function Base.iterate(it::SheetRowStreamIterator)
    reader = SheetReader(it.sheet.entry.node, get_odsfile(it.sheet).styles)
    rd = next_row!(reader)
    rd === nothing && return nothing
    return SheetRow(it.sheet, Int(rd.row), rd), (reader, rd, 0)
end

function Base.iterate(it::SheetRowStreamIterator, st::Tuple{SheetReader,RowData,Int})
    reader, rd, k = st
    if k + 1 < rd.count
        return SheetRow(it.sheet, Int(rd.row) + k + 1, rd), (reader, rd, k + 1)
    end
    nrd = next_row!(reader)
    nrd === nothing && return nothing
    return SheetRow(it.sheet, Int(nrd.row), nrd), (reader, nrd, 0)
end

"""
    eachrow(sheet::Worksheet)

Iterate the rows of `sheet` that have content, as [`SheetRow`](@ref)s, in order. Repeated
rows are given one by one. With the cache on, the sheet is read into the cache first; with
`enable_cache=false` ([`openods`](@ref)), rows are read as they are iterated.

```julia
for r in eachrow(xf["Sheet1"])
    println(row_number(r), ": ", r[1], ", ", r["B"])
end
```
"""
Base.eachrow(ws::Worksheet) =
    is_cache_enabled(ws) ? WorksheetRows(ws, _cached_store(ws)) : SheetRowStreamIterator(ws)

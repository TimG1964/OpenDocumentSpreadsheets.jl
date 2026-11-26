# Tables from worksheets: `eachtablerow`, `gettable`, `readtable`, `readto`. The table logic
# is SheetCore's (src/core/tablerows.jl); this file gives it a worksheet's rows.
#
# Signatures and keywords follow XLSX.jl 0.13.4 (src/table.jl `eachtablerow`, `gettable`;
# src/read.jl `readtable`, `readto`), MIT License, Copyright (c) 2018-2026 Felipe Noronha
# Tavares and other contributors. `table_name` reads a table: LibreOffice's database range
# (phase 6 step 7, D-077).

const TABLE_READ_KEYWORDS_DOC = """
Use `first_row` to give the first row of the table (its header, if `header=true`). Without
it, the table starts at the first row with data in its first column.

`header` (default `true`) says whether the first row holds the column labels. Without a
header, and without `column_labels`, the labels are the column letters.

`column_labels` gives the labels as a vector of `Symbol`s or strings.

`normalizenames=true` turns the labels into valid Julia identifiers.

`missing_strings` gives strings (one, or a vector) to read as `missing`.

`infer_eltypes` (default `true`) gives each column the narrowest element type of its
values; otherwise columns are `Vector{Any}`.

`stop_in_empty_row` (default `true`) ends the table at the first empty row.
`stop_in_row_function` is a function of a `TableRow` returning `true` at the row that ends
the table (that row is left out).

`keep_empty_rows` (default `false`) keeps rows whose values are all `missing` between the
first and the last row of the table."""

"""
    eachtablerow(sheet, [columns]; [first_row], [column_labels], [header],
                 [stop_in_empty_row], [stop_in_row_function], [keep_empty_rows],
                 [normalizenames], [missing_strings]) -> TableRowIterator

An iterator of the rows of the table in `sheet`, each a `TableRow` (index it with a column
number or label: `r[1]`, `r[:name]`). `columns` is a column range such as `"B:E"`; without
it, the columns are the first run of consecutive non-empty cells in the table's first row.

$TABLE_READ_KEYWORDS_DOC
"""
eachtablerow(ws::Worksheet, cols::Union{ColumnRange,AbstractString}; kw...) =
    SheetCore.eachtablerow(eachrow(ws), cols; sheetname = ws.name, kw...)
eachtablerow(ws::Worksheet; kw...) =
    SheetCore.eachtablerow(eachrow(ws); sheetname = ws.name, kw...)

"""
    gettable(sheet, [columns]; [first_row], [column_labels], [header], [infer_eltypes],
             [stop_in_empty_row], [stop_in_row_function], [keep_empty_rows],
             [normalizenames], [missing_strings]) -> DataTable

The table in `sheet` as a `DataTable`, which any Tables.jl sink accepts
(`DataFrame(gettable(sheet))`). `columns` selects the columns (`"B:D"`); without it, the
table's columns are found as in [`eachtablerow`](@ref).

$TABLE_READ_KEYWORDS_DOC
"""
function gettable(ws::Worksheet, cols::Union{ColumnRange,AbstractString}; infer_eltypes::Bool = true, kw...)
    return SheetCore.gettable(eachtablerow(ws, cols; kw...); infer_eltypes)
end
function gettable(ws::Worksheet; infer_eltypes::Bool = true, kw...)
    return SheetCore.gettable(eachtablerow(ws; kw...); infer_eltypes)
end

"""
    readtable(source, [sheet, [columns]]; [table_name], [first_row], [column_labels], [header],
              [infer_eltypes], [stop_in_empty_row], [stop_in_row_function],
              [keep_empty_rows], [normalizenames], [missing_strings]) -> DataTable

Read a table, a block of rows under a header row, from a file path or `IO`: the table on `sheet` (a
name or number; the first sheet if not given), as [`gettable`](@ref) reads it. The sheet is read
row by row and not kept in memory.

```julia
using DataFrames
df = DataFrame(readtable("budget.ods", "Income"))
readtable("budget.ods", "Income", "A:B")          # only columns A and B
```

$TABLE_READ_KEYWORDS_DOC

`table_name` reads a database range (see [`table`](@ref)) instead: its data rows, without its
header and totals rows, as [`gettable`](@ref) reads a [`Table`](@ref), from `sheet` or, if none is
given, from the whole file. The range's cells are its own, so `columns`, `first_row`, `header`,
`column_labels`, `stop_in_empty_row`, `stop_in_row_function` and `keep_empty_rows` don't apply
(`columns` with `table_name` is an error).

An `enable_cache` keyword is accepted, and has no effect.
"""
function readtable(source::Union{AbstractString,IO}, sheet::Union{AbstractString,Integer},
                   cols::Union{ColumnRange,AbstractString}; enable_cache::Bool = false,
                   table_name::Union{Nothing,AbstractString} = nothing, kw...)
    table_name === nothing || throw(ODSError("Give `columns` or `table_name`, not both: a table's range is its own."))
    xf = _open_through(source, sheet)
    return gettable(getsheet(xf, sheet), cols; kw...)
end
function readtable(source::Union{AbstractString,IO}, sheet::Union{AbstractString,Integer};
                   enable_cache::Bool = false, table_name::Union{Nothing,AbstractString} = nothing, kw...)
    table_name === nothing || return _read_named_table(source, sheet, table_name; kw...)
    xf = _open_through(source, sheet)
    return gettable(getsheet(xf, sheet); kw...)
end
function readtable(source::Union{AbstractString,IO}; table_name::Union{Nothing,AbstractString} = nothing, kw...)
    table_name === nothing || return _read_named_table(source, nothing, table_name; kw...)
    return readtable(source, 1; kw...)
end

# A table's data rows from a file: the whole content is read, as the tables follow the sheets.
function _read_named_table(source, sheet, name::AbstractString; infer_eltypes::Bool = true, normalizenames::Bool = false,
                           missing_strings = nothing, kw...)
    source isa AbstractString && !isfile(source) && throw(ODSError("File $source not found."))
    xf = _open_bytes(read(source), source isa AbstractString ? String(source) : "IO", false)
    t = sheet === nothing ? table(xf, name) : table(getsheet(xf, sheet), name)
    return gettable(t; infer_eltypes, normalizenames, missing_strings)
end

"""
    readto(source, [sheet, [columns]], sink; kw...)

Read a table with [`readtable`](@ref) and pass it to the Tables.jl `sink`, such as
`DataFrame`: `readto("budget.ods", "Income", DataFrame)`.
"""
readto(source::Union{AbstractString,IO}, sink; kw...) = sink(Tables.CopiedColumns(readtable(source; kw...)))
readto(source::Union{AbstractString,IO}, sheet::Union{AbstractString,Integer}, sink; kw...) =
    sink(Tables.CopiedColumns(readtable(source, sheet; kw...)))
readto(source::Union{AbstractString,IO}, sheet::Union{AbstractString,Integer},
       cols::Union{ColumnRange,AbstractString}, sink; kw...) =
    sink(Tables.CopiedColumns(readtable(source, sheet, cols; kw...)))

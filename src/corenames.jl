# The shared core's public names, bound here as constants under the same names (D-091). They are
# the same objects (`OpenDocumentSpreadsheets.CellRef === SheetCore.CellRef`), and the methods this
# package defines extend the core's functions as before. Binding them here gives them this package's
# own documentation: the docstrings below, and those of the methods defined in this package
# (`getdata(::Worksheet, …)`, `gettable(::Worksheet, …)`, …), are what `?name` and the manual show,
# while the core's docstrings stay format-neutral for its other users (records/core-migration.md).

"""
    CellRef(ref::AbstractString)
    CellRef(row, column)

A cell's position on a sheet, without the sheet: `CellRef("B6")` is column 2, row 6, and so is
`CellRef(6, 2)`. [`row_number`](@ref) and [`column_number`](@ref) give its row and column, and
`string` its name. Anywhere a cell is given as a string (`"B6"`), a `CellRef` can be given instead.

```julia
c = CellRef("AB1")
row_number(c)              # 1
column_number(c)           # 28
string(CellRef(1, 28))     # "AB1"
```

[`SheetCellRef`](@ref) names the sheet too.
"""
const CellRef = SheetCore.CellRef

"""
    row_number(x) -> Int

The row number of a [`CellRef`](@ref) (`row_number(CellRef("B6"))` is 6), of a [`Cell`](@ref), or
of a row from [`eachrow`](@ref Base.eachrow(::Worksheet)). For a [`TableRow`](@ref), its position in
the table (1 for the first row under the header), not its row on the sheet.
"""
const row_number = SheetCore.row_number

"""
    column_number(x) -> Int

The column number of a [`CellRef`](@ref) or a [`Cell`](@ref): `column_number(CellRef("B6"))` is 2.
"""
const column_number = SheetCore.column_number

# Functions this package adds methods to; their docstrings are on those methods
# (src/model/access.jl, src/model/tables.jl, src/write/dbtables.jl).
const getdata = SheetCore.getdata
const gettable = SheetCore.gettable
const eachtablerow = SheetCore.eachtablerow

"""
    DataTable

A table read from a sheet, as [`readtable`](@ref) and [`gettable`](@ref) return it: its columns and
their labels. Any Tables.jl sink accepts it, such as `DataFrame(dt)`.
"""
const DataTable = SheetCore.DataTable

"""
    TableRow

A row of a table, as [`eachtablerow`](@ref) gives it. Index it with a column number or label:
`r[1]`, `r[:Amount]`. `row_number(r)` is its position in the table (1 for the first row under the
header), not its row on the sheet.
"""
const TableRow = SheetCore.TableRow

"""
    TableRowIterator

What [`eachtablerow`](@ref) returns: an iterator of [`TableRow`](@ref)s, which is also a Tables.jl
table. `gettable(itr)` reads all its rows into a [`DataTable`](@ref).
"""
const TableRowIterator = SheetCore.TableRowIterator

# Sheet-qualified references are always in LibreOffice's notation (D-015): they print as
# `Sheet1.A1`, and parse that form as well as `Sheet1!A1`.
"""
    SheetCellRef(ref::AbstractString)
    SheetCellRef(sheet::AbstractString, cellref::CellRef)

A cell on a named sheet, written as LibreOffice's Name Box shows it: `SheetCellRef("Sheet1.B2")`,
or `SheetCellRef("'My sheet'.B2")` for a sheet whose name needs quotes. Its fields are `sheet`, the
sheet's name, and `cellref`, a [`CellRef`](@ref). It prints in the same form. Parsing also accepts
`\$` marks (`"\$Sheet1.\$B\$2"`) and the form other spreadsheet programs use (`"Sheet1!B2"`).

```julia
r = SheetCellRef("'My sheet'.B2")
r.sheet                                # "My sheet"
r.cellref                              # B2
SheetCellRef("Data", CellRef("A1"))    # Data.A1
```
"""
const SheetCellRef       = SheetCore.SheetCellRef{SheetCore.ODFStyle}
const SheetCellRange     = SheetCore.SheetCellRange{SheetCore.ODFStyle}
const SheetColumnRange   = SheetCore.SheetColumnRange{SheetCore.ODFStyle}
const SheetRowRange      = SheetCore.SheetRowRange{SheetCore.ODFStyle}
const NonContiguousRange = SheetCore.NonContiguousRange{SheetCore.ODFStyle}
parse_sheet_ref(s::AbstractString) = SheetCore.parse_sheet_ref(SheetCore.ODFStyle, s)

"""
    ODSError

The exception OpenDocumentSpreadsheets throws for its own errors: an invalid reference, a missing
sheet, a file that is not an OpenDocument spreadsheet, and so on. `e isa ODSError` tells these apart
from other errors, and `e.msg` is the message.
"""
const ODSError = SheetCoreError

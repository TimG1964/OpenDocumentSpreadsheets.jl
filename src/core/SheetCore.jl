"""
    SheetCore

The format-independent core shared by the spreadsheet back ends (D-001): cell references
and ranges, tabular data and Tables.jl input, number formats and displayed text, date
serial numbers, text widths for autofit, colours, and reading zip parts.

It knows nothing about ODF or OOXML. It is developed inside OpenDocumentSpreadsheets.jl, and is kept
self-contained so that it can later become a package of its own that XLSX.jl can also use
(see `records/core-migration.md` in the workspace). Most of its code is adapted from
XLSX.jl 0.13.4 (MIT License, Copyright (c) 2018-2026 Felipe Noronha Tavares and other
contributors); each file says what it came from and what changed.

Its names are the ones XLSX.jl uses, so that adopting it is a matter of imports.
"""
module SheetCore

import Colors
import Dates
import Printf: @printf
import Tables
import Unicode
import ZipArchives

include("errors.jl")      # SheetCoreError, MAX_ROWS, MAX_COLS
include("cellref.jl")     # CellRef, CellRange, ColumnRange, RowRange, Sheet*Ref/Range, quoting
include("tables.jl")      # DataTable, CellConcreteType, column inference, writetable input
include("tablerows.jl")   # eachtablerow, TableRowIterator, TableRow, gettable (row protocol)
include("dates.jl")       # day numbers: Excel 1900/1904 and ODF null-date epochs
include("numfmt.jl")      # format codes → displayed text
include("charwidths.jl")  # text widths for autofit
include("colors.jl")      # colour parsing and ODF colour form
include("zipio.jl")       # zero-copy reading of zip parts
include("numwrite.jl")    # writing floats and integers without allocating

end # module SheetCore

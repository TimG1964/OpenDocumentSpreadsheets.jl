```@meta
CurrentModule = OpenDocumentSpreadsheets
```

# OpenDocumentSpreadsheets.jl

Read and write OpenDocument spreadsheets (`.ods`, `.fods`, `.ots`) in pure Julia.

OpenDocument (ISO/IEC 26300) is the spreadsheet format of LibreOffice and of the public
bodies that standardise on open formats. OpenDocumentSpreadsheets reads and writes it directly: no Python, no
LibreOffice and no other program is needed.

Its interface follows [XLSX.jl](https://github.com/JuliaData/XLSX.jl), so code written for
Excel files carries over with few changes (see [Coming from XLSX.jl](@ref)). Where LibreOffice
works differently, OpenDocumentSpreadsheets follows LibreOffice: references print as `Sheet1.A1`, formulas
read and write in LibreOffice's notation, and sheets are as LibreOffice saves them.

## Installation

```julia
using Pkg
Pkg.add(url = "https://github.com/TimG1964/OpenDocumentSpreadsheets.jl")
```

OpenDocumentSpreadsheets supports Julia 1.10 and later.

## A first look

```julia
using OpenDocumentSpreadsheets

xf = readods("budget.ods")        # open a file
sheetnames(xf)                    # ["Income", "Costs"]
sh = xf["Costs"]
sh["B3"]                          # one value
sh["A1:C10"]                      # a matrix of values

dt = readtable("budget.ods", "Costs")   # a table, for DataFrames or any Tables.jl sink

writetable("out.ods", dt; sheetname = "Costs")   # write it back
```

## What it does

- **Reading:** typed values (numbers, text, dates, times and durations, booleans, errors),
  repeated rows and cells, merged cells, named ranges, formulas, hidden sheets; reading a
  whole file, one sheet, or rows as they stream.
- **Tables:** `readtable`, `gettable`, `eachtablerow` and the Tables.jl interface.
- **Writing:** new files, editing an existing file, tables, and streaming large files row by
  row. An edited file keeps everything OpenDocumentSpreadsheets does not change exactly as it was.
- **Formats:** `.ods`, flat `.fods` and `.ots` templates; ODF 1.4 (as LibreOffice writes)
  or 1.3.
- **Formatting:** fonts, fills, borders, alignment, number formats (shown as LibreOffice
  shows them), named cell styles, merged cells, column widths, row heights and autofit,
  with XLSX.jl's functions, and conditional formats (rules, data bars, colour scales and
  icon sets, stored as LibreOffice's).
- **Sheets and settings:** inserting and deleting rows and columns (with references
  following), renaming, copying, moving and deleting sheets, defined names, hidden lines and
  sheets, tab colours, groups, panes and the view, protection, printing settings, headers and
  footers, and document properties, with XLSX.jl's functions, stored as LibreOffice stores them.
- **Links, notes, pictures and tables:** hyperlinks, notes and threaded comments, pictures, data
  validation, tables (LibreOffice's database ranges) with totals, and AutoFilters that filter and
  sort as LibreOffice does, with XLSX.jl's functions. They stay with their cells through edits,
  inserted and deleted lines, sorts and sheet copies.
- **Charts and sparklines:** XLSX.jl's chart API in a `Charts` submodule (making, reading and
  formatting charts, histograms and chart sheets) and its sparklines, stored as LibreOffice's chart
  objects and sparkline groups, in LibreOffice's look.
- **Speed:** comparable with XLSX.jl on XLSX.jl's own benchmarks.


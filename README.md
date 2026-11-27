# OpenDocumentSpreadsheets.jl

[![CI](https://github.com/TimG1964/OpenDocumentSpreadsheets.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/TimG1964/OpenDocumentSpreadsheets.jl/actions/workflows/CI.yml)
[![Docs](https://img.shields.io/badge/docs-dev-blue.svg)](https://TimG1964.github.io/OpenDocumentSpreadsheets.jl/dev)

Read, write and edit OpenDocument spreadsheets (`.ods`, `.fods`, `.ots`), the format of
LibreOffice Calc, in pure Julia. No LibreOffice installation is needed, and editing a file keeps
everything you didn't change exactly as it was. Tables go straight to and from DataFrames and any
other Tables.jl source.

## Features

- **Reading and writing** `.ods`, flat `.fods` and `.ots` files: typed values, tables
  (Tables.jl), formulas, whole files or rows as they stream. An edited file keeps everything not
  changed exactly as it was.
- **Formatting:** fonts, fills, borders, alignment, number formats, named styles, merges,
  widths, heights, and conditional formats.
- **Sheets and settings:**
  - row and column inserts and deletes, with references following;
  - sheet operations, named ranges, hiding, grouping, panes, protection, printing and document
    properties.
- **Objects:** hyperlinks, notes and threaded comments, pictures, validity rules, database ranges
  and AutoFilters.
- **Charts and sparklines:** create, read and format LibreOffice's charts (22 kinds, stock charts,
  histograms and chart sheets) and sparklines.

Everything is stored as LibreOffice stores it, and behaves as it does in LibreOffice Calc. The
package is tested against LibreOffice. OpenDocument files from other programs are read by the
standard; the documentation's
[Supported features](https://TimG1964.github.io/OpenDocumentSpreadsheets.jl/dev/features/#Files-from-other-programs)
page says what that covers.

## Installation

```julia
using Pkg
Pkg.add(url = "https://github.com/TimG1964/OpenDocumentSpreadsheets.jl")
```

## Example

```julia
using OpenDocumentSpreadsheets

# Read a sheet as a table
dt = readtable("data.ods", "Sheet1")

# Read single values
xf = readods("data.ods")
xf["Sheet1"]["B2"]

# Write a table
writetable("out.ods", "Results" => (a = [1, 2, 3], b = ["x", "y", "z"]))
```

See the [documentation](https://TimG1964.github.io/OpenDocumentSpreadsheets.jl/dev) for more.

## Coming from XLSX.jl?

The functions have XLSX.jl's names and arguments, with `ods` in place of `xlsx` (`readods`,
`openods`, `writeods`, …).
[Coming from XLSX.jl](https://TimG1964.github.io/OpenDocumentSpreadsheets.jl/dev/xlsx/) lists the
differences.

## Licence

MIT. See [LICENSE](LICENSE).

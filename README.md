# OpenDocumentSpreadsheets.jl

[![CI](https://github.com/TimG1964/OpenDocumentSpreadsheets.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/TimG1964/OpenDocumentSpreadsheets.jl/actions/workflows/CI.yml)
[![Docs](https://img.shields.io/badge/docs-dev-blue.svg)](https://TimG1964.github.io/OpenDocumentSpreadsheets.jl/dev)

Read and write OpenDocument spreadsheets (`.ods`, `.fods`, `.ots`) in Julia, with an API
modelled on [XLSX.jl](https://github.com/JuliaData/XLSX.jl).

Formerly ODSFiles.jl.

## Features

- **Reading and writing** `.ods`, flat `.fods` and `.ots` files: typed values, tables
  (Tables.jl), formulas, whole files or rows as they stream. An edited file keeps everything not
  changed exactly as it was.
- **Formatting:** fonts, fills, borders, alignment, number formats, named styles, merges,
  widths, heights, and conditional formats.
- **Sheets and settings:**
  - row and column inserts and deletes, with references following;
  - sheet operations, defined names, hiding, grouping, panes, protection, printing and document
    properties.
- **Objects:** hyperlinks, notes and threaded comments, pictures, validation, tables (database
  ranges) and AutoFilters.
- **Charts and sparklines:** XLSX.jl's chart API in a `Charts` submodule, and its sparklines.

Everything is stored as LibreOffice stores it, and behaves as LibreOffice behaves where Excel and
LibreOffice differ.

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

## Licence

MIT. See [LICENSE](LICENSE).

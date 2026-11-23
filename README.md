# OpenDocumentSpreadsheets.jl

[![CI](https://github.com/TimG1964/OpenDocumentSpreadsheets.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/TimG1964/OpenDocumentSpreadsheets.jl/actions/workflows/CI.yml)
[![Docs](https://img.shields.io/badge/docs-dev-blue.svg)](https://TimG1964.github.io/OpenDocumentSpreadsheets.jl/dev)

Read and write OpenDocument spreadsheets (`.ods`, `.fods`, `.ots`) in Julia, with an API
modelled on [XLSX.jl](https://github.com/JuliaData/XLSX.jl).

Formerly ODSFiles.jl.

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

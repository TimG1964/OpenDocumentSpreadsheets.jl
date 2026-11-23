```@meta
CurrentModule = OpenDocumentSpreadsheets
```

# Getting started

## Reading

[`readods`](@ref) opens a file and returns an [`ODSFile`](@ref). A sheet is read the first
time it is used.

```julia
using OpenDocumentSpreadsheets

xf = readods("data.ods")
sheetnames(xf)            # the sheets, in order
sh = xf["Sheet1"]         # or xf[1]

sh["A1"]                  # a value: a number, string, Date, ..., or missing
sh["A1:C3"]               # a Matrix{Any}
sh[2, 3]                  # row 2, column 3
sh[:, 1]                  # a whole column, as far as the sheet has data
sh[:]                     # everything
```

To read one value or range without keeping the file open, use [`readdata`](@ref):

```julia
readdata("data.ods", "Sheet1", "B2:D5")
readdata("data.ods", "Sheet1.B2:D5")       # LibreOffice's notation
readdata("data.ods", "Sheet1!B2:D5")       # Excel's notation works too
```

## Tables

A table is a block of rows with a header. [`readtable`](@ref) reads it into a `DataTable`,
which any Tables.jl sink accepts:

```julia
using DataFrames
df = DataFrame(readtable("data.ods", "Sheet1"))
```

Without further keywords, the table starts at the first row with data and spans the first
run of non-empty header cells. Columns, the first row, labels and the handling of empty rows
can all be chosen; see [`readtable`](@ref).

## Rows

[`eachrow`](@ref Base.eachrow(::Worksheet)) gives the rows that have content:

```julia
for r in eachrow(xf["Sheet1"])
    println(row_number(r), ": ", r[1], " ", r["B"])
end
```

For files too large to hold in memory, open them with `enable_cache=false`: rows are then
read as they are iterated.

```julia
openods("big.ods"; enable_cache = false) do xf
    for r in eachrow(xf[1])
        # ...
    end
end
```

## Writing a new file

```julia
using Dates

xf = newods("Results")
sh = xf["Results"]
sh["A1"] = "Name"
sh["B1"] = "Score"
sh["A2:B3"] = ["Ann" 9.5; "Bob" 7]
sh["C2"] = Date(2026, 11, 18)
setFormula(sh, "B4"; val = "=SUM(B2:B3)")
writeods("results.ods", xf)
```

Or write a whole table at once:

```julia
writetable("results.ods", df; sheetname = "Results")
writetable("all.ods", "Results" => df, "Notes" => notes)
```

## Formatting

XLSX.jl's formatting functions work on ODS cells, and so do LibreOffice's named styles:

```julia
setFont(sh, "A1:B1"; bold = true)
setFill(sh, "A1:B1"; pattern = "solid", fgColor = "DDEEFF")
setFormat(sh, "B2:B4"; format = "0.0")
setColumnWidth(sh, "A"; width = 15)
mergeCells(sh, "A6:B6")
setCellStyle(sh, "A4", "Accent 1")
```

See [Formatting](guide/formatting.md) for the rest.

## Editing a file

Open it with `mode="rw"`. The do-block form saves the file when the block ends:

```julia
openods("budget.ods"; mode = "rw") do xf
    xf["Costs"]["B7"] = 1250.0
    addsheet!(xf, "Summary")["A1"] = "Total"
end
```

Everything OpenDocumentSpreadsheets does not change — styles, column widths, comments, images, charts,
settings — is kept exactly as it was ([Saving and writing](@ref)).

## Changing sheets

Rows, columns and sheets can be inserted, deleted, renamed, copied and moved, and the
references to them follow, as in LibreOffice:

```julia
openods("budget.ods"; mode = "rw") do xf
    s = xf["Costs"]
    insertRows(s, 5; count = 3)            # =SUM(B2:B9) becomes =SUM(B2:B12)
    renamesheet!(s, "Costs 2027")
    copysheet!(s)                          # "Costs 2027 (copy)"
    freezePanes(s; nrows = 1)
    setPageSetup(s; orientation = :landscape, fitToWidth = 1)
    setDocumentProperties(xf; title = "Budget 2027")
end
```

[Sheets, names and settings](guide/sheets.md) covers these and the rest: defined names,
hiding, groups, the view, protection, printing and document properties.

## Streaming a large file

[`streamods`](@ref) writes rows as they are produced, in bounded memory:

```julia
streamods("big.ods") do s
    sh = addsheet!(s, "data"; columns = ["n", "square"])
    for n in 1:1_000_000
        writerow!(sh, (n, n^2))
    end
end
```

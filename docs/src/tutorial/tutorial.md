```@meta
CurrentModule = OpenDocumentSpreadsheets
```

# Tutorial

This tutorial makes a small budget file, reads it, writes and formats a new file, then edits the
budget. Run the examples in order, in one Julia session: each uses what the ones before it made. The
files are written to the current directory (`pwd()`). Each step links to the page that covers it in
full.

## A file to work with

The tutorial reads and edits `budget.ods`, a year of income and costs. This example makes it; the
steps below explain the functions it uses:

```julia
using OpenDocumentSpreadsheets

months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

xf = newods("Income")                     # a new file, with one sheet
income = xf["Income"]
income["A1:C1"] = ["Month" "Amount" "Source"]
for (i, m) in enumerate(months)
    income[i+1, 1] = m
    income[i+1, 2] = 1000.0 + 25i
    income[i+1, 3] = isodd(i) ? "Sales" : "Grants"
end

costs = addsheet!(xf, "Costs")
costs["A1:C1"] = ["Month" "Amount" "Status"]
for (i, m) in enumerate(months)
    costs[i+1, 1] = m
    costs[i+1, 2] = 50.0i
    costs[i+1, 3] = "Open"
end

writeods("budget.ods", xf; overwrite = true)
```

## Reading a file

[`readods`](@ref) opens a file and returns an [`ODSFile`](@ref). A sheet is read the first time it
is used.

```julia
xf = readods("budget.ods")
sheetnames(xf)            # ["Income", "Costs"]
sh = xf["Costs"]          # or xf[2]

sh["B3"]                  # 100.0; a cell gives a number, string, Date, ..., or missing
sh["A1:C3"]               # a 3×3 Matrix{Any}
sh[2, 3]                  # row 2, column 3: "Open"
sh[:, 1]                  # column A, as far as the sheet has data
sh[:]                     # everything
```

To read one value or range without keeping the file open, use [`readdata`](@ref):

```julia
readdata("budget.ods", "Costs", "B2:B4")
readdata("budget.ods", "Costs.B2:B4")       # the sheet named in the reference
```

[Addressing cells and ranges](../concepts/addressing.md) covers every form a reference can take, and
[Values and types](../concepts/values.md) what each kind of cell reads as.

## Reading a table

Here a *table* is any block of rows under a header row, which is how most sheets hold their data. It
doesn't have to be a database range (Data ▸ Define Range); those are covered in
[Database ranges](../data/tables.md).

[`readtable`](@ref) reads a table into a `DataTable`, which any Tables.jl sink accepts, such as a
DataFrame (this example needs DataFrames.jl installed):

```julia
using DataFrames
df = DataFrame(readtable("budget.ods", "Income"))    # 12 rows: Month, Amount, Source
```

Without further keywords, the table starts at the first row with data and spans the first run of
non-empty header cells. Columns, the first row, labels and the handling of empty rows can all be
chosen: see [`readtable`](@ref).

## Rows

[`eachrow`](@ref Base.eachrow(::Worksheet)) gives the rows that have content:

```julia
for r in eachrow(xf["Costs"])
    println(row_number(r), ": ", r[1], " ", r["B"])
end
```

## Writing a new file

```julia
using Dates

xf = newods("Results")
sh = xf["Results"]
sh["A1"] = "Name"
sh["B1"] = "Score"
sh["C1"] = "Date"
sh["A2:B3"] = ["Ann" 9.5; "Bob" 7]
sh["C2"] = Date(2026, 11, 18)
sh["C3"] = Date(2026, 11, 19)
setFormula(sh, "B4"; val = "=SUM(B2:B3)")
writeods("results.ods", xf; overwrite = true)
```

Opened in LibreOffice, the file shows the values, the dates in ISO form, and the formula's result,
which LibreOffice calculates when it loads the file:

<!-- shot: tutorial_write cells=6x6 -->
![A LibreOffice sheet with Name, Score and Date in row 1, Ann 9.5 and Bob 7 below with their dates, and 16.5 in B4](../images/tutorial_write.png)

Or write a whole table at once, from any Tables.jl source, such as the DataFrame read above or a
named tuple of vectors:

```julia
writetable("income.ods", df; sheetname = "Income", overwrite = true)

people = (Name = ["Ann", "Bob"], Team = ["North", "South"])
writetable("all.ods", "Income" => df, "People" => people; overwrite = true)   # one sheet each
```

## Formatting

Cells take fonts, fills, borders, number formats and LibreOffice's named cell styles:

```julia
setFont(sh, "A1:C1"; bold = true)
setFill(sh, "A1:C1"; pattern = "solid", fgColor = "DDEEFF")   # a pale blue background
setBorder(sh, "A1:C1"; bottom = ["style" => "medium"])
setFormat(sh, "B2:B4"; format = "0.0")
setColumnWidth(sh, "A:C"; width = 14)
setCellStyle(sh, "A4", "Accent 1")
setConditionalFormat(sh, "B2:B3", :dataBar)
writeods("results.ods", xf; overwrite = true)                 # save the formatting
```

<!-- shot: tutorial_format cells=5x6 -->
![The same sheet with a bold header on a pale blue fill above a thick line, scores shown to one decimal place with blue data bars, and the empty cell A4 filled black by the Accent 1 style](../images/tutorial_format.png)

[Cell formats](../formatting/cellFormatting.md) and
[Conditional formats](../formatting/conditionalFormatting.md) cover the rest.

## Editing a file

Open it with `mode="rw"`. The do-block form saves the file when the block ends:

```julia
openods("budget.ods"; mode = "rw") do xf
    xf["Costs"]["C7"] = "Paid"                    # June's costs are paid
    addsheet!(xf, "Summary")["A1"] = "Total"
end
```

Everything you don't change (styles, column widths, notes, pictures, charts, settings) is kept
exactly as it was: see [Creating and editing files](creatingFiles.md).

## Charts and sparklines

```julia
using OpenDocumentSpreadsheets.Charts

openods("budget.ods"; mode = "rw") do xf
    s = xf["Costs"]
    c = addChart(s, :column; anchor = "F2:M18", title = "Costs by month")
    addSeries(c, "B2:B13"; categories = "A2:A13", name_ref = "B1")
    setLegendPos(c, :b)                       # the legend at the bottom
    addSparklines(s, "A15", "B2:B13")         # the year's amounts, in one cell
end
```

<!-- shot: tutorial_chart file=budget.ods sheet=Costs cells=13x19 -->
![The Costs sheet: months, amounts and statuses in columns A to C, with June marked Paid, a small line chart of the twelve amounts in A15, and a column chart titled Costs by month with its legend below](../images/tutorial_chart.png)

[Charts](../charts/overview.md) covers charts, histograms, chart sheets and sparklines.

## Links, notes, database ranges and filters

```julia
openods("budget.ods"; mode = "rw") do xf
    s = xf["Costs"]
    addHyperlink(s, "E1"; url = "https://example.org/budget", display = "Budget notes")
    addComment(s, "B7", "Agreed with finance"; author = "Ann")
    addDataValidation(s, "C2:C13"; type = :list, values = ["Open", "Paid"])   # a drop-down
    t = addtable!(s, "A1:C13"; name = "Costs")             # a database range
    settotals!(t, "Month" => "Total", "Amount" => :sum)   # a totals row, in row 14
    setAutoFilter(xf["Income"], "A1:C13"; filters = ["Source" => ["Sales"]],
                  sort = "Amount" => :descending)
end
```

[`addtable!`](@ref) makes A1:C13 a database range, LibreOffice's Data ▸ Define Range: see
[Database ranges](../data/tables.md). [Validity](../data/validity.md),
[AutoFilter and sorting](../data/autoFilter.md), [Notes and comments](../objects/notes.md) and
[Hyperlinks](../objects/hyperlinks.md) cover the others.

## Rows, columns and sheets

Rows, columns and sheets can be inserted, deleted, renamed, copied and moved, and references to them
follow, as they do in LibreOffice:

```julia
openods("budget.ods"; mode = "rw") do xf
    s = xf["Costs"]
    insertRows(s, 5; count = 3)            # the totals row moves to row 17, and sums B2:B16
    renamesheet!(s, "Costs 2027")
    copysheet!(s)                          # "Costs 2027 (copy)"
    freezePanes(s; nrows = 1)
    setPageSetup(s; orientation = :landscape, fitToWidth = 1)
    setDocumentProperties(xf; title = "Budget 2027")
end
```

## Large files

For files too large to hold in memory, write rows as they are produced, and read them one at a time
without loading the whole sheet (`enable_cache = false`):

```julia
streamods("squares.ods"; overwrite = true) do s
    sh = addsheet!(s, "data"; columns = ["n", "square"])
    for n in 1:1_000_000
        writerow!(sh, (n, n^2))
    end
end

openods("squares.ods"; enable_cache = false) do xf
    for r in eachrow(xf["data"])
        row_number(r) == 1 && continue      # the header
        # ... use r[1] and r[2]
    end
end
```

See [Saving and large files](../saving.md).

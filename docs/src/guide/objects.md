```@meta
CurrentModule = OpenDocumentSpreadsheets
```

# Links, notes, pictures and tables

These are XLSX.jl's functions, with its names, arguments and return values. Each is stored as
LibreOffice stores it: where Excel and LibreOffice differ, OpenDocumentSpreadsheets does what
LibreOffice does, and LibreOffice's own options are extra keywords ([Coming from XLSX.jl](../xlsx.md)
lists both). A file must be open for writing (`mode="rw"`, or made by [`newods`](@ref)); the
getters also work on files opened for reading.

The getters are public but not exported, as in XLSX.jl. The examples below import them:

```julia
using OpenDocumentSpreadsheets
using OpenDocumentSpreadsheets: getHyperlink, getHyperlinks, getComment, getThreadedComment, getImages,
    getDataValidation, table, getAutoFilter
```

All of these survive editing. A cell whose value you change keeps its note, links, pictures and
validation, as it does in LibreOffice. Inserting or deleting rows and columns, sorting and copying
sheets move them with their cells.

## Hyperlinks

```julia
xf = openods("report.ods"; mode = "rw")
s = xf["Summary"]

addHyperlink(s, "A2"; url = "https://example.org/", display = "Our site")
addHyperlink(s, "A3"; location = "Data!B10", display = "See the data")   # or "Data.B10"
addHyperlink(s, "B5:B9"; url = "https://example.org/list")              # one link per cell
getHyperlink(s, "A2")       # (sheet, ref, url, location, display, tooltip)
getHyperlinks(s)            # every link on the sheet
deleteHyperlink(s, "A3")
```

A text cell gets a link around its text, a number or formula a link of the cell itself, as
LibreOffice's import gives XLSX.jl's links. LibreOffice has no tooltips, so `tooltip` is an error.

## Notes and threaded comments

```julia
addComment(s, "C4", "Checked against the invoice"; author = "Ann")
getComment(s, "C4").text
deleteComment(s, "C4")

addThreadedComment(s, "D4", "Is this final?"; author = "Ann")
addThreadedReply(s, "D4", "Yes."; author = "Bob")
setThreadedCommentResolved(s, "D4")
getThreadedComment(s, "D4")
```

A note is LibreOffice's comment. A threaded comment is kept as LibreOffice keeps Excel's: inside a
note, which shows the thread's text in versions without threads.

## Pictures

```julia
addImage(s, "F2", "logo.png")                        # one cell per 64 × 20 pixels of the picture
addImage(s, "F10:H20", "chart.jpg"; alt = "Sales by month")
getImages(s)                                          # (sheet, media_name, from, to, alt, description)
deleteImage(s, "F2")
```

A picture (PNG, JPEG or GIF) is anchored in its first cell and resizes with its cells. LibreOffice
has no pictures inside cells, so `inCell=true` is an error.

## Data validation

```julia
addDataValidation(s, "B2:B100"; type = :list, values = ["Red", "Green", "Blue"])
addDataValidation(s, "C2:C100"; type = :whole, operator = :between, formula1 = 1, formula2 = 10,
                  error = "A whole number from 1 to 10", errorStyle = :stop)
addDataValidation(s, "D2:D100"; type = :list, formula1 = "Lists.\$A\$1:\$A\$9", sortEntries = true)
getDataValidation(s, "C5")
deleteDataValidation(s, "B2:B100")
```

These are the rules of LibreOffice's Data ▸ Validity. A cell has one rule: a new one replaces the
rule of the cells it covers.

## Tables

A table is LibreOffice's database range (Data ▸ Define Range): a named block of rows under a header
row, with filter buttons.

```julia
t = addtable!(s, "A1:B50"; name = "Sales")
settotals!(t, "Revenue" => :sum, "Region" => "Total")    # a totals row under the table
appendtable!(t, (Region = ["North"], Revenue = [1200]))  # rows added inside it
gettablerange(t, "Revenue")                              # the column's data cells
readtable("report.ods", "Summary"; table_name = "Sales")
writetable("out.ods", df; sheetname = "Data", as_table = true, table_name = "People")
deletetable!(t)
```

LibreOffice has no table styles: `style` is accepted only as `nothing` or `"None"`.

## AutoFilters and sorting

A sheet's AutoFilter is LibreOffice's Data ▸ AutoFilter. [`setAutoFilter`](@ref) hides the rows the
criteria don't show, and puts the rows in order, so the file opens filtered and sorted:

```julia
setAutoFilter(s, "A1:D50"; filters = ["Region" => ["North", "South"], "Revenue" => (">" => 1000)],
              sort = "Revenue" => :descending)
setAutoFilter(s, :; sort = ["Region", "Revenue" => :descending], naturalSort = true)
getAutoFilter(s)            # CellRange("A1:D50")
removeAutoFilter(s)         # shows every row again
```

Both follow LibreOffice:
- **Filters:** rows are hidden as LibreOffice's Refresh Range hides them. Text that LibreOffice reads
  as a number is compared with numbers by value, and list items as text. LibreOffice's own options
  are `caseSensitive`, `noDuplicates` and regular expressions as criteria (`r"^a.*"`).
- **Sorting:** rows are put in LibreOffice's order: numbers (and `FALSE`, `TRUE`), then text in
  LibreOffice's alphabetical order, then errors, with empty cells last. Each row's cells move with
  their formats, validations, notes, links and pictures, and formulas move as if copied. Row
  heights, and formulas that refer to the sorted cells, stay as they are. LibreOffice's own options
  are `caseSensitive`, `naturalSort` (`"a2"` before `"a10"`) and `includeFormats=false`, which moves
  the values but leaves the formats.

Above- and below-average and relative-date filters can't be stored by LibreOffice, so they are
errors, and so is a sort of merged cells (unless `includeFormats=false`) or of array formulas.

```@meta
CurrentModule = OpenDocumentSpreadsheets
```

# AutoFilter and sorting

A sheet's AutoFilter is LibreOffice's Data ▸ AutoFilter: filter buttons on a range's header row.
[`setAutoFilter`](@ref) can also filter and sort the range, so the file opens filtered and sorted:

```julia
using OpenDocumentSpreadsheets
using OpenDocumentSpreadsheets: getAutoFilter

xf = newods("Sales")
s = xf["Sales"]
s["A1:C1"] = ["Region" "Product" "Revenue"]
rows = [("North", "Tea", 1200), ("South", "Cake", 950), ("East", "Tea", 1430),
        ("West", "Soup", 610), ("North", "Cake", 880), ("South", "Soup", 1020)]
for (i, r) in enumerate(rows)
    s[i+1, 1] = r[1]; s[i+1, 2] = r[2]; s[i+1, 3] = r[3]
end
setColumnWidth(s, "A:C"; width = 12)

setAutoFilter(s, "A1:C7"; filters = ["Region" => ["North", "South"], "Revenue" => (">" => 900)],
              sort = "Revenue" => :descending)
getAutoFilter(s)            # CellRange("A1:C7")
```

<!-- shot: autofilter cells=4x8 -->
![The sales range with filter buttons on its header, showing only North and South rows over 900, in descending order of revenue: 1200, 1020, 950; rows 2, 6 and 7 are hidden](../images/autofilter.png)

```julia
setAutoFilter(s, :; sort = ["Region", "Revenue" => :descending], naturalSort = true)
removeAutoFilter(s)         # shows every row again
```

## Filtering

Rows are hidden as LibreOffice's Data ▸ More Filters ▸ Refresh Range hides them:
- Text that LibreOffice reads as a number (`"10"`, `"2026-11-23"`) is compared with numbers by value.
- List items are compared as text, so a date matches only at midnight.
- `caseSensitive` and `noDuplicates` are LibreOffice's *Case sensitive* and *No duplications*
  options, and a regular expression (`r"^a.*"`) can be a criterion.
- LibreOffice can't store above-average, below-average or relative-date filters, so they are errors.

## Sorting

Rows are put in LibreOffice's order: numbers (and `FALSE`, `TRUE`), then text in LibreOffice's
alphabetical order, then errors, with empty cells last.
- Each row's cells move with their formats, validity rules, notes, links and pictures, and formulas
  move as if copied.
- Row heights, and formulas elsewhere that refer to the sorted cells, stay as they are.
- The options are `caseSensitive`, `naturalSort` (`"a2"` before `"a10"`) and
  `includeFormats=false`, which moves the values but leaves the formats.
- A sort of merged cells (unless `includeFormats=false`) or of array formulas is an error.

```@meta
CurrentModule = OpenDocumentSpreadsheets
```

# Inserting and deleting rows and columns

```julia
using OpenDocumentSpreadsheets
using OpenDocumentSpreadsheets: getFormula

xf = newods("Costs")
sh = xf["Costs"]
sh["A1:B1"] = ["Item" "Cost"]
sh["A2:B5"] = ["Rent" 900; "Power" 120; "Water" 40; "Phone" 35]
sh["A6"] = "Total"
setFormula(sh, "B6"; val = "=SUM(B2:B5)")
setFont(sh, "A1:B1"; bold = true)
setBorder(sh, "A6:B6"; top = ["style" => "thin"])

insertRows(sh, 4; count = 2)     # two empty rows before row 4
sh["A4:B5"] = ["Internet" 30; "Insurance" 55]
getFormula(sh, "B8")             # "=SUM(B2:B7)"
```

```@raw html
<!-- shot: insert_rows cells=3x9 -->
```
![The costs list with Internet and Insurance inserted as rows 4 and 5 between Power and Water, and the total, now in row 8, summing all six costs](../images/insert_rows.png)

```julia
deleteRows(sh, 3)                # Power
insertColumns(sh, "B")           # or a number: insertColumns(sh, 2)
deleteColumns(sh, "B")
insertRows(xf, "Costs.2")        # on the file, with the sheet named
```

References follow the lines they point to, as they do in LibreOffice:
- formulas on every sheet, named ranges, validity rules, conditional formats, database ranges, print
  ranges and chart series;
- a range grows when lines are inserted inside it, and shrinks when some of its lines are deleted;
- a reference whose cells are all deleted becomes `#REF!`.

Merged cells, formats, hidden lines, groups, notes, pictures and charts move with their cells. An
inserted row takes the cell formats of the row above, and an inserted column those of the column to
its left, with the width of the column it pushes right.

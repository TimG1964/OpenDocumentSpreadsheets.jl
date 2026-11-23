# Formatting

OpenDocumentSpreadsheets formats cells with XLSX.jl's functions: [`setFont`](@ref), [`setFill`](@ref),
[`setBorder`](@ref), [`setAlignment`](@ref) and [`setFormat`](@ref), with their getters and
uniform variants. They take XLSX.jl's address forms: a cell (`"B2"`), a range (`"B2:D4"`),
whole columns (`"A:C"`) or rows (`"3:5"`), a list of ranges (`"A1:B2,D4"`), a defined name,
a sheet-qualified reference on the file (`xf["Sheet1.A1"]` style: `setFont(xf, "Sheet1.A1"; …)`),
or rows and columns as integers, ranges, vectors or `:`.

```julia
using OpenDocumentSpreadsheets

xf = newods()
s = xf[1]
s["A1"] = "Total"
s["B1"] = 1234.5

setFont(s, "A1"; bold = true, size = 12, color = "darkblue")
setFill(s, "A1:B1"; pattern = "solid", fgColor = "FFF2CC")
setBorder(s, "A1:B1"; outside = ["style" => "medium"])
setAlignment(s, "B1"; horizontal = "right")
setFormat(s, "B1"; format = "#,##0.00")

OpenDocumentSpreadsheets.getText(s, "B1")      # "1,234.50"
writeods("report.ods", xf)
```

## Merged cells

```julia
mergeCells(s, "A1:C1")                 # A1 keeps its value; B1 and C1 are emptied and covered
getMergedCells(s)                      # [A1:C1], or nothing
isMergedCell(s, "B1")                  # true
getMergedBaseCell(s, "B1")             # (baseCell = A1, baseValue = …)
removeMergedCells(s, "A1:C1")          # or removeMergedCells(s) for every merge
```

A merge is an anchor cell and the cells it covers, as LibreOffice writes it. Covered cells
keep their formatting. An explicit range may reach past the used area.

## Column widths, row heights and autofit

```julia
setColumnWidth(s, "A:B"; width = 20)           # in characters, as in XLSX.jl
setColumnWidth(s, "C"; width = 3, unit = :cm)  # or :mm, :in, :pt
OpenDocumentSpreadsheets.getColumnWidth(s, "A1")               # 20.7109375, as XLSX.jl reports it
setRowHeight(s, 1; height = 30)                # in points
autofitColumns(s)                              # LibreOffice's optimal width for every column

writetable("out.ods", df; column_widths = [12, 30], column_formats = Dict("price" => "#,##0.00"))
```

ODF widths are lengths. A character is the width LibreOffice gives one when it opens an
XLSX.jl file, so a width looks the same in both. [`autofitColumns`](@ref) measures each
cell's text as LibreOffice shows it, in the cell's font. `column_widths` and
`column_formats` also work when streaming.

## Named cell styles

ODF documents have named cell styles, the ones LibreOffice shows in its Styles deck: "Default",
"Heading 1", "Good", and styles of your own. XLSX.jl has nothing like them.
- [`setCellStyle`](@ref) applies a style.
- [`addCellStyle!`](@ref) defines one, from the same keywords the setters take.
- [`getCellStyle`](@ref OpenDocumentSpreadsheets.getCellStyle) gives a cell's style.

```julia
addCellStyle!(xf, "Total"; parent = "Default",
              font = (bold = true, size = 12), fill = (pattern = "solid", fgColor = "FFF2CC"),
              border = (top = ["style" => "double"],), format = "#,##0.00")
setCellStyle(s, "A10:B10", "Total")
setCellStyle(s, "A1", "Heading 1")      # one of LibreOffice's built-in styles
OpenDocumentSpreadsheets.getCellStyle(s, "A1")         # "Heading 1"
```

- **Direct formatting stays on top**, as in LibreOffice. Applying a style removes the cell's
  own settings only for what the style sets (its font size, say). The rest stays, including
  the number format unless the style has one.
- **LibreOffice's built-in styles** are added, in LibreOffice's own definitions, to a file
  that lacks them: Heading, Heading 1, Heading 2, Text, Note, Footnote, Hyperlink, Status,
  Good, Neutral, Bad, Warning, Error, Accent, Accent 1 to 3, and Result.
- **Names** are the ones LibreOffice shows. In the file, a name such as "My Style" is stored
  as `My_20_Style`; either form is accepted.

## How it differs from XLSX.jl

- **Empty cells are formatted**, as in LibreOffice. Whole columns and rows are formatted to
  the end of the sheet, not only up to the used area.
- **Styles, not tables.** ODF has no font, fill or border tables: a cell has a style, which
  OpenDocumentSpreadsheets derives from the cell's current one (named styles stay its parent). Setters return
  the new style's name for a single cell, and getters report the properties the cell's style
  resolves to, also on files opened read-only.
- **What ODF can't hold:** superscript and subscript (`vertAlign`) are refused; pattern fills
  are blended into one colour, as LibreOffice does when it opens an xlsx file.
- **Number formats** are stored as ODF data styles, in the form LibreOffice writes for the
  same code. [`getText`](@ref OpenDocumentSpreadsheets.getText) shows a value as LibreOffice shows it, which differs from Excel
  in places (General shows up to 15 significant digits, for example).
- **Merged cells** are an anchor cell and covered cells, as LibreOffice writes them.

The full list is in the workspace's `records/api-divergence.md`.

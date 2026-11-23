```@meta
CurrentModule = OpenDocumentSpreadsheets
```

# References and names

## Cells and ranges

Within a sheet, references are the usual ones: `"B2"`, `"A1:C3"`, whole columns `"A:C"`,
whole rows `"2:4"`. `$` marks are accepted (`"$A$1"`). Several areas are joined with `,` or
LibreOffice's `~`:

```julia
sh["A1:A4,C1"]     # a vector of matrices, one per area
sh["A1:A4~C1"]     # the same
```

Rows and columns can also be given as numbers, ranges or vectors: `sh[2, 3]`,
`sh[2:5, [1, 3]]`, `sh[:, 2]`.

## Naming a sheet

OpenDocumentSpreadsheets reads and prints sheet-qualified references in LibreOffice's notation, and also
accepts Excel's:

| LibreOffice | Excel | |
|---|---|---|
| `Sheet1.A1` | `Sheet1!A1` | |
| `'My sheet'.A1:B2` | `'My sheet'!A1:B2` | quoted names |
| `$Sheet1.$A$1` | | absolute |
| `Sheet1.A1~Sheet1.C3` | `Sheet1!A1,Sheet1!C3` | lists |

```julia
xf["Sheet1.B2"]            # a value from the file
xf["'My sheet'!A1:C3"]
```

References that OpenDocumentSpreadsheets returns, such as `SheetCellRef`, print in LibreOffice's notation.

## Defined names

Named ranges and named expressions, for the whole file or for one sheet, can be used wherever
a reference can:

```julia
xf["Totals"]              # a workbook name
sh["LocalRange"]          # a name local to the sheet
```

A name whose expression is a constant gives that value. A name that is a formula can't be
read: OpenDocumentSpreadsheets does not evaluate formulas. A name that refers to cells can be written through
(`sh["LocalRange"] = 0`).

Sheet and defined names match without regard to case, as in LibreOffice.

Names are added, listed and deleted as in XLSX.jl:

```julia
addDefinedName(xf, "Prices", "Data.B2:B20")         # the file's
addDefinedName(xf["Data"], "Rate", 0.2)             # the sheet's
addDefinedName(xf, "Total", raw"=SUM($Data.$B$2:$B$20)")
OpenDocumentSpreadsheets.getAllDefinedNames(xf)                     # every name, with its scope and value
deleteDefinedName(xf, "Prices")
```

They follow LibreOffice's rules: a letter or `_` first, then letters, digits, `_` and `?`, and
nothing it reads as a cell reference (`A1`, `R1C1`, `C1x`). In a name's formula, as in
LibreOffice, a reference without `$` is relative, the sheet's name included: write
`$Data.$B$2` to fix it. Saving an edited file changes only the names added or deleted.

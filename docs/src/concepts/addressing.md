```@meta
CurrentModule = OpenDocumentSpreadsheets
```

# Addressing cells and ranges

## Within a sheet

References within a sheet are the ones LibreOffice uses: `"B2"`, `"A1:C3"`, whole columns `"A:C"`
and whole rows `"2:4"`. `$` marks are accepted (`"$A$1"`). Several areas are joined with `~`, as in
LibreOffice, or with `,`:

```julia
sh["A1:A4~C1"]     # a vector of matrices, one per area
sh["A1:A4,C1"]     # the same
```

Rows and columns can also be given as numbers, ranges or vectors: `sh[2, 3]`, `sh[2:5, [1, 3]]`,
`sh[:, 2]`.

## Naming the sheet

On a file, a reference names its sheet as LibreOffice's Name Box shows it:

| Reference | |
|---|---|
| `Sheet1.A1` | a cell |
| `'My sheet'.A1:B2` | a sheet whose name needs quotes |
| `$Sheet1.$A$1` | absolute |
| `Sheet1.A1~Sheet1.C3` | a list of areas |

```julia
xf["Sheet1.B2"]            # a value from the file
xf["'My sheet'.A1:C3"]
```

The form other spreadsheet programs use, `Sheet1!A1`, is accepted too. References the package
returns, such as a [`SheetCellRef`](@ref), print in LibreOffice's form.

## Names

Named ranges and named expressions, for the whole file or for one sheet, can be used wherever a
reference can:

```julia
xf["Totals"]              # a name of the file
sh["LocalRange"]          # a name local to the sheet
```

A name whose expression is a constant gives that value. A name that is a formula can't be read,
since OpenDocumentSpreadsheets doesn't calculate formulas. A name that refers to cells can be
written through (`sh["LocalRange"] = 0`). [Named ranges](../data/namedRanges.md) shows how to add
and delete them.

Sheet names and defined names match without regard to case, as in LibreOffice.

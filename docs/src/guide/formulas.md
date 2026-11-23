```@meta
CurrentModule = OpenDocumentSpreadsheets
```

# Formulas

OpenDocument stores formulas in OpenFormula syntax (`of:=SUM([.A1:.B2];1)`). OpenDocumentSpreadsheets reads
and writes them in the notation LibreOffice shows in its formula bar:

```julia
getFormula(sh, "C1")                 # "=SUM(A1:B2,1)"
getFormula(sh, "C1"; raw = true)     # "of:=SUM([.A1:.B2];1)"

setFormula(sh, "D1"; val = "=AVERAGE(A1:A10,'Other sheet'.B2)")
setFormula(sh, "D2"; val = "of:=[.A1]*2", raw = true)
```

The notation is LibreOffice's with English function names and separators: `,` between
arguments, and in inline arrays `,` between columns and `;` between rows (`{1,2;3,4}`).
Function names are translated with LibreOffice's own table, so `IFS` is stored as
`COM.MICROSOFT.IFS`, `CEILING.XCL` as `COM.MICROSOFT.CEILING`, and so on.

OpenDocumentSpreadsheets does not calculate formulas. A formula written by OpenDocumentSpreadsheets has no result until the
file is opened in LibreOffice (or another spreadsheet program), which computes it.

```@meta
CurrentModule = OpenDocumentSpreadsheets
```

# Named ranges

LibreOffice's Sheet ▸ Named Ranges and Expressions gives names to ranges, cells and constants, for
the whole file or for one sheet. The functions for them have `DefinedName` in their names:
[`addDefinedName`](@ref), [`deleteDefinedName`](@ref) and the others below. A file must be open for
writing (`mode="rw"`, or made by [`newods`](@ref)); the getters also work on files opened for
reading.

```julia
using OpenDocumentSpreadsheets

xf = newods("Data")
sh = xf["Data"]
sh["A1:B1"] = ["Month" "Rate"]
for i in 1:12
    sh[i+1, 1] = i; sh[i+1, 2] = 0.01i
end

addDefinedName(xf, "rates", "Data.B2:B13")                  # a named range, absolute ($Data.$B$2:$B$13)
addDefinedName(xf, "vat", 0.2)                              # a named expression
addDefinedName(sh, "first", "A1"; absolute = false)         # local to the sheet, relative
addDefinedName(xf, "total", raw"=SUM($Data.$B$2:$B$13)")    # a formula
setFormula(sh, "D1"; val = "=SUM(rates)*(1+vat)")

xf["rates"]                                         # the range's values
OpenDocumentSpreadsheets.getDefinedNames(xf)        # the file's names
OpenDocumentSpreadsheets.getAllDefinedNames(xf)     # every name, with its scope and value
deleteDefinedName(xf, "total")
```

Names are used in formulas, and wherever a reference can be ([Addressing cells and
ranges](../concepts/addressing.md)).

## LibreOffice's rules

- A name starts with a letter or `_`, then has letters, digits, `_` and `?`.
- A name can't be something LibreOffice reads as a cell reference: `A1`, `AB1`, `R1C1`, `C1x`.
- In a name's formula a reference without `$` is relative, the sheet's name included: write
  `$Data.$B$2` to fix it.
- Names match without regard to case.
- Whole columns and rows can be named (`"Data.A:A"`).
- A sheet's own name may refer to cells on another sheet. Read, written or formatted through its
  sheet (`sh["name"]`), it gives those cells, as a formula using it does in LibreOffice.
- A constant keeps its type: `true` reads back as `true`, not as 1.

Saving an edited file changes only the names added or deleted.

```@meta
CurrentModule = OpenDocumentSpreadsheets
```

# Validity

LibreOffice's Data ▸ Validity limits what a cell accepts: a list of values (shown as a drop-down), a
whole number or decimal within limits, a date, a time, a text length, or a formula. A file must be
open for writing; [`getDataValidation`](@ref OpenDocumentSpreadsheets.getDataValidation) also works
on files opened for reading.

```julia
using OpenDocumentSpreadsheets
using OpenDocumentSpreadsheets: getDataValidation

xf = newods("Orders")
o = xf["Orders"]
o["A1:C1"] = ["Colour" "Quantity" "Size"]
lists = addsheet!(xf, "Lists")
lists["A1:A3"] = ["Small"; "Medium"; "Large";;]

addDataValidation(o, "A2:A20"; type = :list, values = ["Red", "Green", "Blue"])
addDataValidation(o, "B2:B20"; type = :whole, operator = :between, formula1 = 1, formula2 = 10,
                  error = "A whole number from 1 to 10", errorStyle = :stop)
addDataValidation(o, "C2:C20"; type = :list, formula1 = "Lists.\$A\$1:\$A\$3", sortEntries = true)
o["A2"] = "Green"
getDataValidation(o, "B5")
```

LibreOffice shows a list rule's values as a drop-down on the cell:

<!-- shot: validity cells=4x6 cursor=A2 dropdown -->
![The Orders sheet in LibreOffice with the cursor on A2, which holds Green, and its drop-down open listing Red, Green and Blue](../images/validity.png)

A cell has one rule: a new rule replaces the rule of the cells it covers, and
[`deleteDataValidation`](@ref) removes one:

```julia
deleteDataValidation(o, "C2:C20")
```

LibreOffice's own options are keywords too: `caseSensitive` for text comparisons, and `sortEntries`
to show a list's values in order.

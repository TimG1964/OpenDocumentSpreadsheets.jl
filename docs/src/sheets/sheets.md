```@meta
CurrentModule = OpenDocumentSpreadsheets
```

# Managing sheets

A file must be open for writing (`mode="rw"`, or made by [`newods`](@ref)).

```julia
using OpenDocumentSpreadsheets

xf = newods("Sheet1")
xf["Sheet1"]["A1"] = 10
addsheet!(xf, "Summary")
setFormula(xf["Summary"], "A1"; val = "=Sheet1.A1*2")

renamesheet!(xf["Sheet1"], "Data")    # =Sheet1.A1*2 becomes =Data.A1*2
c = copysheet!(xf["Data"])            # "Data (copy)", appended
movesheet!(c; before = 1)             # or after = "Data", or a sheet
deletesheet!(xf, "Data (copy)")       # references to it would become #REF!
sheetnames(xf)                        # ["Data", "Summary"]
```

These follow LibreOffice's Sheet menu:
- **References follow.** A renamed sheet's references, in formulas, names, charts and the rest,
  take its new name. References to a deleted sheet become `#REF!`.
- **A copy is a full copy:** values, formats, merges, names local to the sheet, settings, charts and
  page style. In the copy, a reference to the source sheet whose sheet name is relative
  (`Data.A5`) points to the copy, and one whose sheet name is absolute (`$Data.A5`) stays on the
  source.
- **Names** must be new: a name already in use is an error.

To hide a sheet, or give its tab a colour, see [Panes, the view and tab
colours](../layout/panesAndView.md).

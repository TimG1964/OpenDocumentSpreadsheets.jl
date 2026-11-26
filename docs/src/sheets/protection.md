```@meta
CurrentModule = OpenDocumentSpreadsheets
```

# Protecting sheets

LibreOffice's Tools ▸ Protect Sheet stops a sheet's cells being changed, except the cells whose
protection is turned off (Format ▸ Cells ▸ Cell Protection). Tools ▸ Protect Spreadsheet Structure
stops sheets being added, deleted, moved or renamed.

```julia
using OpenDocumentSpreadsheets

xf = newods("Form")
s = xf["Form"]
s["A1:A3"] = ["Name"; "Email"; "Days"]
setCellProtection(s, "B1:B3"; locked = false)          # cells left editable
setFill(s, "B1:B3"; pattern = "solid", fgColor = "FFF2CC")
protectSheet(s; password = "secret", insertRows = true, deleteRows = true)
protectWorkbook(xf; password = "secret")

OpenDocumentSpreadsheets.getSheetProtection(s)   # the permissions, and whether there is a password
unprotectSheet(s)
```

- **Passwords** are stored as LibreOffice stores them, so any text works.
- **Permissions** are LibreOffice's: selecting protected and unprotected cells, and inserting and
  deleting rows and columns. LibreOffice has no permission to format, sort, insert hyperlinks or edit
  objects and scenarios on a protected sheet, and no window protection: asking for them is an error.
- **Hiding contents:** `hideAll` and `hidePrint` (*Hide all* and *Hide when printing*) hide a cell's
  contents on screen or in print while the sheet is protected.

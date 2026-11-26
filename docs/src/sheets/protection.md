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
sh = xf["Form"]
sh["A1:A3"] = ["Name"; "Email"; "Days"]
setCellProtection(sh, "B1:B3"; locked = false)         # cells left editable
setFill(sh, "B1:B3"; pattern = "solid", fgColor = "FFF2CC")
protectSheet(sh; password = "secret", insertRows = true, deleteRows = true)
protectWorkbook(xf; password = "secret")

OpenDocumentSpreadsheets.getSheetProtection(sh)  # the permissions, and whether there is a password
unprotectSheet(sh)
```

- **Passwords** are stored as LibreOffice stores them, so any text works.
- **Permissions** are LibreOffice's: selecting protected and unprotected cells, and inserting and
  deleting rows and columns.
- **Hiding contents:** `hideAll` and `hidePrint` (*Hide all* and *Hide when printing*) hide a cell's
  contents on screen or in print while the sheet is protected.

## Not available

LibreOffice can't store these, so asking for one is an error that says why: permissions to format,
sort, insert hyperlinks, or edit objects and scenarios on a protected sheet, and window protection
(`protectWorkbook`'s `windows`).

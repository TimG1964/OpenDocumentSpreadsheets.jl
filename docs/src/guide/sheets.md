```@meta
CurrentModule = OpenDocumentSpreadsheets
```

# Sheets, names and settings

These functions are XLSX.jl's, with its names and arguments. What they store is what
LibreOffice stores: where Excel and LibreOffice differ, OpenDocumentSpreadsheets does what LibreOffice does
([Coming from XLSX.jl](../xlsx.md) lists the differences). A file must be open for writing
(`mode="rw"`, or made by [`newods`](@ref)); the getters also work on files opened for reading.

## Inserting and deleting rows and columns

```julia
xf = openods("budget.ods"; mode = "rw")
s = xf["Costs"]

insertRows(s, 5; count = 2)      # two empty rows before row 5
deleteRows(s, 10:12)
insertColumns(s, "C")            # or a number: insertColumns(s, 3)
deleteColumns(s, "E:F")
insertRows(xf, "Costs.5")        # the file and a sheet-qualified line (also "Costs!5")
```

References follow the lines they point to, as they do in LibreOffice:
- formulas on every sheet, defined names, validations, conditional formats, database ranges,
  print ranges and chart series
- a range grows when lines are inserted inside it, and shrinks when some of its lines are deleted
- a reference whose cells are all deleted becomes `#REF!`

Merged cells, formats, hidden lines, groups, comments and anchored images move with their
cells. As in LibreOffice, an inserted row takes the cell formats of the row above, and an
inserted column those of the column to its left, with the width of the column it pushes right.

## Sheet operations

```julia
renamesheet!(xf["Sheet1"], "Data")    # references to the sheet follow the new name
c = copysheet!(xf["Data"])            # "Data (copy)", appended
movesheet!(c; before = 1)             # or after = "Data", or a sheet
deletesheet!(xf, "Data (copy)")       # references to it become #REF!
addsheet!(xf, "Summary")
```

A copy is a full copy: values, formats, merges, names local to the sheet, settings, charts and
page style.

## Defined names

```julia
addDefinedName(xf, "rates", "Data!B2:B13")           # a named range ($-absolute by default)
addDefinedName(xf, "vat", 0.2)                       # a named expression
addDefinedName(xf["Data"], "first", "A1"; absolute = false)  # local to the sheet, relative
setFormula(s, "C1"; val = "=SUM(rates)")
xf["rates"]                                          # the range's values
OpenDocumentSpreadsheets.getDefinedNames(xf)                         # [DefinedName(...), ...]
deleteDefinedName(xf, "vat")
```

Names follow LibreOffice's rules: letters, digits, `_` and `?`; not a cell reference such as
`AB1`, and not an R1C1 form.

## Hiding, visibility and tab colours

```julia
setRowHidden(s, 3:4)                     # hidden = true by default
setColumnHidden(s, "D"; hidden = false)
OpenDocumentSpreadsheets.isRowHidden(s, 3)               # true

setSheetVisibility(xf["Notes"], :hidden)   # :veryHidden hides it too: ODF has no very hidden sheets
setTabColor(s, "FF8000")                   # or a colour name: "orange"
removeTabColor(s)
```

The last visible sheet can't be hidden.

## Grouping

```julia
groupRows(s, 2:10)
groupRows(s, 4:6; collapsed = true)    # a group inside it, its lines hidden
groupColumns(s, "B:D")
OpenDocumentSpreadsheets.getRowOutlineLevel(s, 5)      # 2
ungroupRows(s, 4:6)
```

Groups are LibreOffice's nested groups: two groups side by side stay two groups, a group may not
cross another, and there are at most seven levels.

## Panes and the view

```julia
freezePanes(s; nrows = 1, ncols = 1)       # or freezePanes(s, "B2")
splitPanes(s; nrows = 10)                  # a split that doesn't freeze
removePanes(s)
setSheetView(s; zoom = 125, showGridLines = false, rightToLeft = false, activeCell = "C3")
OpenDocumentSpreadsheets.getSheetView(s)
```

The view is LibreOffice's view settings (settings.xml). In LibreOffice `showRowColHeaders`,
`showZeros` and the page-break preview belong to the whole file, not to one sheet.

## Protection

```julia
protectSheet(s; password = "secret", insertRows = true, deleteRows = true)
setCellProtection(s, "B2:B10"; locked = false)   # cells left editable
protectWorkbook(xf; password = "secret")         # the sheets can't be added, moved or renamed
OpenDocumentSpreadsheets.getSheetProtection(s)                   # the permissions, and whether there is a password
unprotectSheet(s)
```

Passwords are stored as LibreOffice stores them, so any text works. LibreOffice has no
permission for formatting, sorting, hyperlinks, objects or scenarios on a protected sheet, and no
window protection: asking for them is an error.

## Printing

```julia
setPageSetup(s; orientation = :landscape, paperSize = :A4, fitToWidth = 1, fitToHeight = 0)
setPageMargins(s; left = 0.5, right = 0.5, top = 0.75, bottom = 0.75)   # inches
setPrintOptions(s; gridLines = true, horizontalCentered = true)
setPrintArea(s, "A1:F40")
setPrintTitles(s; rows = 1)                      # repeated on every page
setHeaderFooter(s; header = (center = "&A",), footer = (right = "Page &P of &N",))
setHeaderFooter(s; header = headerFooterFont(bold = true) * "Budget " * headerFooterField(:date))
```

Header and footer text takes Excel's codes (`&P`, `&N`, `&D`, `&T`, `&A`, `&F`, font codes),
stored as LibreOffice's fields and text styles. Each sheet's settings go into a page style of
its own (`PageStyle_<sheet>`), so changing one sheet leaves the others alone. Print titles must
lie inside a group or apart from it (ODF keeps them in a container of rows).

## Document properties

```julia
setDocumentProperties(xf; title = "Budget 2027", creator = "Finance", keywords = "budget; plan")
setCustomProperty(xf, "Approved", true)
setCustomProperty(xf, "Version", 3)
OpenDocumentSpreadsheets.getDocumentProperties(xf).title     # "Budget 2027"
OpenDocumentSpreadsheets.getCustomProperties(xf)             # ["Approved" => true, "Version" => 3]
deleteCustomProperty(xf, "Version")
```

They are what LibreOffice shows in *File → Properties*. Excel's category, content status,
company and manager are kept as the custom properties LibreOffice makes of them. Saving never
changes the modification date: set `modified` yourself if you want it.

## Saving

Each of these changes only what it must. Saving a file that was read still copies the rest as
it was ([Saving and writing](saving.md)): an insert or delete rewrites the references that
move, and a setting rewrites its sheet's start tag or the part of settings.xml, meta.xml or
styles.xml that holds it.

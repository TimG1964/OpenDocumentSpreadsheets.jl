```@meta
CurrentModule = OpenDocumentSpreadsheets
```

# API reference

```@docs
OpenDocumentSpreadsheets
```

## Files and sheets

```@docs
readods
openods
newods
writeods
saveods
ODSFile
Worksheet
sheetnames
sheetcount
hassheet
addsheet!
ODSError
```

## Reading cells

```@docs
getdata
readdata
getcell
getcellrange
get_dimension
Cell
EmptyCell
iserror
geterror
getFormula
SheetRow
Base.eachrow(::Worksheet)
row_number
column_number
CellRef
SheetCellRef
```

## Tables

```@docs
readtable
gettable
eachtablerow
readto
DataTable
TableRow
TableRowIterator
```

## Writing

```@docs
setdata!
setFormula
writetable
writetable!
streamods
StreamWriter
StreamSheet
writerow!
writerows!
```

## Rows and columns

Inserting and deleting rows and columns moves every reference to them as LibreOffice moves it:
formulas on every sheet, defined names, merges, conditional formats, validations, database
ranges, print ranges, charts and anchored shapes.

```@docs
insertRows
insertColumns
deleteRows
deleteColumns
```

## Sheet operations

Renaming, deleting, copying and moving sheets, with references following as they follow in
LibreOffice.

```@docs
renamesheet!
deletesheet!
copysheet!
movesheet!
```

## Defined names

Named ranges and named expressions, the file's own and each sheet's. They follow LibreOffice's
rules for names and are stored as LibreOffice stores them.

```@docs
addDefinedName
deleteDefinedName
deleteAllDefinedNames
getDefinedNames
getAllDefinedNames
DefinedName
```

## Hiding and tab colours

Hidden rows and columns, hidden sheets and tab colours, stored as LibreOffice stores them.

```@docs
setRowHidden
setColumnHidden
isRowHidden
isColumnHidden
setSheetVisibility
getSheetVisibility
setTabColor
getTabColor
removeTabColor
```

Groups of rows and columns, as LibreOffice nests them:

```@docs
groupRows
groupColumns
ungroupRows
ungroupColumns
getRowOutlineLevel
getColumnOutlineLevel
```

## Panes and the sheet view

How a sheet looks when LibreOffice opens it, kept in its view settings (settings.xml):

```@docs
freezePanes
splitFreeze
splitPanes
removePanes
setSheetView
getSheetView
```

## Protection

Sheets, the file's structure and cells, protected as LibreOffice protects them:

```@docs
protectSheet
unprotectSheet
isSheetProtected
getSheetProtection
protectWorkbook
unprotectWorkbook
isWorkbookProtected
getWorkbookProtection
setCellProtection
getCellProtection
```

## Printing

Page setup, margins, print options, print areas and titles, headers and footers, kept in each
sheet's page style as LibreOffice keeps them:

```@docs
setPageSetup
getPageSetup
setPageMargins
getPageMargins
setPrintOptions
getPrintOptions
setPrintArea
getPrintArea
removePrintArea
setPrintTitles
getPrintTitles
removePrintTitles
setHeaderFooter
getHeaderFooter
removeHeaderFooter
headerFooterField
headerFooterFont
```

## Document properties

The file's properties and custom properties, kept in meta.xml as LibreOffice keeps them:

```@docs
setDocumentProperties
getDocumentProperties
setCustomProperty
getCustomProperty
getCustomProperties
deleteCustomProperty
```

## Formatting

Fonts, fills, borders and alignment:

```@docs
setFont
setFill
setBorder
setOutsideBorder
setAlignment
getFont
getFill
getBorder
getAlignment
getDefaultFont
CellFont
CellFill
CellBorder
CellAlignment
```

Number formats and the text a cell shows:

```@docs
setFormat
getFormat
CellFormat
getText
```

Uniform formatting:

```@docs
setUniformFont
setUniformFill
setUniformBorder
setUniformAlignment
setUniformFormat
setUniformStyle
```

Column widths and row heights:

```@docs
setColumnWidth
getColumnWidth
setRowHeight
getRowHeight
autofitColumns
```

Named cell styles:

```@docs
setCellStyle
getCellStyle
addCellStyle!
```

Merged cells:

```@docs
mergeCells
removeMergedCells
getMergedCells
isMergedCell
getMergedBaseCell
```

## The shared core

The format-independent parts of OpenDocumentSpreadsheets (references, tables, number formats, dates) live in
a submodule meant to be shared with XLSX.jl in future. It is not part of the public API.

```@docs
OpenDocumentSpreadsheets.SheetCore
```

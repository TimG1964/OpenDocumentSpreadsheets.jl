```@meta
CurrentModule = OpenDocumentSpreadsheets
```

# API reference: sheets and settings

Row and column inserts and deletes, sheet operations, names, visibility, panes, protection, printing and document properties (phase 5).

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


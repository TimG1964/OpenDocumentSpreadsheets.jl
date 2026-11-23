```@meta
CurrentModule = OpenDocumentSpreadsheets
```

# API reference: files, cells and tables

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

## The shared core

The format-independent parts of OpenDocumentSpreadsheets (references, tables, number formats, dates) live in
a submodule meant to be shared with XLSX.jl in future. It is not part of the public API.

```@docs
OpenDocumentSpreadsheets.SheetCore
```

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
getRichTextString
RichTextString
RichTextRun
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

```@meta
CurrentModule = OpenDocumentSpreadsheets
```

# API reference: links, notes and objects

Hyperlinks, notes and threaded comments, pictures, data validation, tables, AutoFilters and sorting (phase 6). [Links, notes, pictures and tables](guide/objects.md) introduces them.

## Hyperlinks

LibreOffice's two kinds of link: a URL field in a cell's text, and a cell link in its style (F-058):

```@docs
addHyperlink
getHyperlink
getHyperlinks
deleteHyperlink
```

## Notes and threaded comments

LibreOffice's annotations, and the threaded comments it keeps inside them (F-059):

```@docs
addComment
getComment
getComments
deleteComment
addThreadedComment
addThreadedReply
setThreadedCommentResolved
deleteThreadedComment
getThreadedComment
getThreadedComments
```


## Pictures

Pictures anchored in cells, resizing with them, as LibreOffice's import places XLSX.jl's (F-060):

```@docs
addImage
getImages
deleteImage
```

## Data validation

The rules of LibreOffice's Data ▸ Validity, stored as its import stores XLSX.jl's (F-061, F-068):

```@docs
addDataValidation
getDataValidation
getDataValidations
deleteDataValidation
```

## Tables

Tables are LibreOffice's database ranges (Data ▸ Define Range), stored as its import stores XLSX.jl's tables (F-062, F-070). LibreOffice has no table styles, and keeps no totals settings: they are read from the totals cells' formulas.

```@docs
Table
TableStyleInfo
tables
table
addtable!
deletetable!
settotals!
gettotals
removetotals!
appendtable!
gettablerange
```

## AutoFilters

A sheet's AutoFilter is LibreOffice's anonymous database range of the sheet, with filter buttons (F-062). Its criteria are stored as LibreOffice stores them, and rows are hidden as LibreOffice's Refresh Range hides them (F-071); a sort puts the rows in LibreOffice's order and moves what LibreOffice's Data ▸ Sort moves (F-072). Both differ from Excel in places: see [`setAutoFilter`](@ref).

```@docs
setAutoFilter
getAutoFilter
removeAutoFilter
```

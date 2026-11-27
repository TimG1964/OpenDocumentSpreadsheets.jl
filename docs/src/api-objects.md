```@meta
CurrentModule = OpenDocumentSpreadsheets
```

# API reference: links, notes and objects

Hyperlinks, notes and threaded comments, pictures, Validity rules, database ranges, AutoFilters and sorting.
The guide introduces them: [Pictures](objects/pictures.md), [Notes and comments](objects/notes.md),
[Hyperlinks](objects/hyperlinks.md), [Validity](data/validity.md), [Database ranges](data/tables.md) and
[AutoFilter and sorting](data/autoFilter.md).

## Hyperlinks

LibreOffice's two kinds of link: a URL field in a cell's text, and a cell link in its style:

```@docs
addHyperlink
getHyperlink
getHyperlinks
deleteHyperlink
```

## Notes and threaded comments

LibreOffice's annotations, and the threaded comments it keeps inside them:

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

Pictures anchored in cells, resizing with them:

```@docs
addImage
getImages
deleteImage
```

## Data validation

The rules of LibreOffice's Data ▸ Validity:

```@docs
addDataValidation
getDataValidation
getDataValidations
deleteDataValidation
```

## Tables

Tables are LibreOffice's database ranges (Data ▸ Define Range). LibreOffice has no styles for them, and keeps no totals settings: they are read from the totals cells' formulas.

```@docs
Table
TableStyleInfo
tables
table
addtable!
deletetable!
settotals!
gettotals
deletetotals!
appendtable!
gettablerange
```

## AutoFilters

A sheet's AutoFilter is LibreOffice's anonymous database range of the sheet, with filter buttons. Its criteria are stored as LibreOffice stores them, and rows are hidden as LibreOffice's Refresh Range hides them; a sort puts the rows in LibreOffice's order and moves what LibreOffice's Data ▸ Sort moves.

```@docs
setAutoFilter
getAutoFilter
deleteAutoFilter
```

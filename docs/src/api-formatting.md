```@meta
CurrentModule = OpenDocumentSpreadsheets
```

# API reference: formatting

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


Conditional formats, as LibreOffice stores them:

```@docs
setConditionalFormat
setColoredDataBars
getConditionalFormats
clearConditionalFormats
```

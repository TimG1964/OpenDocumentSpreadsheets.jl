```@meta
CurrentModule = OpenDocumentSpreadsheets
```

# Supported features

- **Reading:** typed values (numbers, text, dates, times and durations, booleans, errors), rich text,
  repeated rows and cells, merged cells, named ranges, formulas and hidden sheets. Read a whole
  file, one sheet, or rows as they stream ([Values and types](concepts/values.md),
  [Addressing cells and ranges](concepts/addressing.md)).
- **Tables of data:** `readtable`, `gettable`, `eachtablerow` and the Tables.jl interface, so a
  sheet goes straight into a DataFrame and back ([Getting started](tutorial/tutorial.md)).
- **Writing:** new files, edits to an existing file, whole tables, and very large files streamed row
  by row. An edited file keeps everything you didn't change exactly as it was
  ([Creating and editing files](tutorial/creatingFiles.md), [Saving and large files](saving.md)).
- **Formats:** `.ods`, flat `.fods` and `.ots` templates, in ODF 1.4 (as LibreOffice writes) or 1.3.
- **Formulas** in the notation LibreOffice's formula bar shows, and **named ranges and
  expressions** ([Formulas](data/formulas.md), [Named ranges](data/namedRanges.md)).
- **Database ranges** with totals rows, **AutoFilters** that filter and sort as LibreOffice does,
  and **Validity** rules with drop-down lists ([Database ranges](data/tables.md),
  [AutoFilter and sorting](data/autoFilter.md), [Validity](data/validity.md)).
- **Cell formatting:** fonts, fills, borders, alignment, number formats shown as LibreOffice shows
  them, and named cell styles, LibreOffice's built-in ones included
  ([Cell formats](formatting/cellFormatting.md)).
- **Conditional formatting:** conditions, data bars, colour scales and icon sets
  ([Conditional formats](formatting/conditionalFormatting.md)), and **merged cells**
  ([Merged cells](formatting/mergedCells.md)).
- **Layout and view:** column widths and row heights (and optimal widths), inserting and deleting
  rows and columns with references following, hidden and grouped rows and columns, frozen and split
  panes, zoom, gridlines and tab colours.
- **Sheets:** renaming, copying, moving, deleting and hiding sheets; sheet and document protection;
  page styles, print ranges, headers and footers; document properties.
- **Pictures, notes and hyperlinks**, which stay with their cells through edits, inserts, deletes,
  sorts and sheet copies.
- **Charts and sparklines:** making, reading and formatting LibreOffice's charts (22 kinds, stock
  charts, histograms and chart sheets), and sparkline groups ([Charts](charts/overview.md)).
- **Speed:** large sheets are read and written quickly, and can be streamed in bounded memory.

## Files from other programs

OpenDocumentSpreadsheets is tested against LibreOffice Calc: its test files were made in
LibreOffice, and the files it writes are checked by opening them in LibreOffice.

Other programs that save OpenDocument spreadsheets, such as Apache OpenOffice, Microsoft Excel and
Google Sheets, write the same format, and their files are read as the standard describes them:

- The file can be ODF 1.2, 1.3 or 1.4. An edited file keeps its version.
- A file can hold only its sheets, without the styles, settings or properties that LibreOffice adds.
  It can still be edited and saved, and LibreOffice opens the result.
- The XML can use any namespace prefixes, not just LibreOffice's.

Files saved by those programs themselves aren't part of the tests, and nor is opening the files
written here in them. New files are written in ODF 1.4, or 1.3 with `version = "1.3"`.

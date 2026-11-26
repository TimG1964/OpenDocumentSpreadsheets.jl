```@meta
CurrentModule = OpenDocumentSpreadsheets.Charts
```

# Charts

The chart functions are in a submodule:

```julia
using OpenDocumentSpreadsheets
using OpenDocumentSpreadsheets.Charts
```

A chart is LibreOffice's Insert ▸ Chart: an embedded chart object in a frame, anchored to a cell. The
functions make charts, change their formatting, and read them, both the charts made here and a file's
own. They work in zipped (`.ods`) and flat (`.fods`) files, new or edited.

- [Creating charts](creating.md): the kinds, series, combo charts, and LibreOffice's chart options.
- [Formatting charts](formatting.md): colours, lines, legends, axes, titles, labels, trendlines and
  error bars.
- [Reading charts](reading.md): finding a file's charts and reading their data and formatting.
- [Histograms and chart sheets](histograms.md).
- [Sparklines](sparklines.md): small charts inside cells.

A new chart takes LibreOffice's own look (its palette, symbols, fonts and legend), so it looks as a
chart made in LibreOffice does. What a LibreOffice chart can't store is an error that says why.

## Through edits and operations

Charts follow edits and operations as LibreOffice's do:
- **Inserts and deletes:** a chart's references follow inserted and deleted rows and columns.
  LibreOffice clips them and never makes them `#REF!`.
- **Renames:** references follow a renamed sheet.
- **Copies:** a copied sheet's charts keep pointing at the source.
- **Sheet deletes:** references to a deleted sheet move to the one before it.
- **Frames:** a chart's frame moves with its cells, and goes when all its cells do.

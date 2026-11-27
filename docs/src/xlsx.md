```@meta
CurrentModule = OpenDocumentSpreadsheets
```

# Coming from XLSX.jl

OpenDocumentSpreadsheets follows XLSX.jl's interface, so most code needs only its file names changed:

| XLSX.jl | OpenDocumentSpreadsheets |
|---|---|
| `XLSX.readxlsx`, `XLSX.openxlsx` | [`readods`](@ref), [`openods`](@ref) |
| `XLSX.newxlsx`, `XLSX.writexlsx`, `XLSX.savexlsx` | [`newods`](@ref), [`writeods`](@ref), [`saveods`](@ref) |
| `XLSX.streamxlsx` | [`streamods`](@ref) |
| `XLSXFile`, `XLSXError` | [`ODSFile`](@ref), [`ODSError`](@ref) |

These work as in XLSX.jl: `readtable`, `gettable`, `eachtablerow`, `readdata`, `getdata`,
indexing, `getcell`, `getcellrange`, `eachrow`, `iserror`, `geterror`, `setdata!`,
`writetable`, `writetable!`, `addsheet!`, `writerow!`, `writerows!` and the Tables.jl
interface.

The formatting functions work as in XLSX.jl too, with the differences listed below:
- `setFont`, `setFill`, `setBorder`, `setAlignment`, `setFormat` and their getters
- the `setUniform*` variants, and `setBorder`'s `outside`
- `getText`
- `mergeCells` and the other merge functions
- `setColumnWidth`, `setRowHeight`, their getters and `autofitColumns`
- `writetable`'s `column_widths` and `column_formats`

## Renamed functions

Every removal is named `delete…` here. XLSX.jl's names still work, as other names for the same
functions, but they aren't exported: call them as `OpenDocumentSpreadsheets.removeAutoFilter`, or
bring them in with `using OpenDocumentSpreadsheets: removeAutoFilter`.

| XLSX.jl | OpenDocumentSpreadsheets |
|---|---|
| `removeAutoFilter` | [`deleteAutoFilter`](@ref) |
| `removeHeaderFooter` | [`deleteHeaderFooter`](@ref) |
| `removeMergedCells` | [`deleteMergedCells`](@ref) |
| `removePanes` | [`deletePanes`](@ref) |
| `removePrintArea` | [`deletePrintArea`](@ref) |
| `removePrintTitles` | [`deletePrintTitles`](@ref) |
| `removeTabColor` | [`deleteTabColor`](@ref) |
| `removetotals!` | [`deletetotals!`](@ref) |
| `clearConditionalFormats` | [`deleteConditionalFormats`](@ref) |

```@docs
removeAutoFilter
removeHeaderFooter
removeMergedCells
removePanes
removePrintArea
removePrintTitles
removeTabColor
removetotals!
clearConditionalFormats
```

## Differences

- **References** print in LibreOffice's notation (`Sheet1.A1`); Excel's (`Sheet1!A1`) is
  still accepted. Lists of areas can also use `~`.
- **Formulas** read and write in LibreOffice's notation (`=SUM(Sheet2.A1:B2,1)`), not
  Excel's.
- **Durations:** a time cell of 24 hours or more, or a negative one, reads as a
  `Dates.CompoundPeriod`, not a `Time`.
- **Cells:** a [`Cell`](@ref) holds its decoded value, its value type as a symbol, its
  style's name and its formula text, rather than XLSX.jl's internal indices.
- **Error codes** are the text LibreOffice shows, including its own `Err:NNN`.
- **Saving an edited file** keeps everything not edited, rather than rewriting the file.
- **`display_text=false`** (no XLSX.jl counterpart) writes smaller files; see
  [Saving and large files](@ref).
- **Formatting** works on ODF's styles:
  - **Styles, not tables.** ODF has no font, fill or border tables: a cell has a style, derived
    from its current one (named styles stay its parent). Setters return the new style's name for
    a single cell, and getters report what the cell's style resolves to, also on read-only files.
  - **Empty cells are formatted**, as in LibreOffice, and whole columns and rows are formatted to
    the end of the sheet, not only up to the used area.
  - **What ODF can't hold:** superscript and subscript (`vertAlign`) are refused in cell formats
    (use rich text); pattern fills are blended into one colour, as LibreOffice does when it opens
    an xlsx file.
  - **Number formats** are ODF data styles, in the form LibreOffice writes for the same code, and
    `getText` shows a value as LibreOffice shows it, which differs from Excel in places (General
    shows up to 15 significant digits, for example).
  - **Column widths** in characters are the widths LibreOffice gives an XLSX.jl file's, so a width
    looks the same in both; `getColumnWidth` reports them as XLSX.jl does.
  - **Merged cells** are an anchor cell and covered cells, as LibreOffice writes them.
  - **Named cell styles** ([`setCellStyle`](@ref), [`addCellStyle`](@ref)) are LibreOffice's,
    which XLSX.jl lacks.
- **Inserting and deleting rows and columns** ([`insertRows`](@ref), [`insertColumns`](@ref),
  [`deleteRows`](@ref), [`deleteColumns`](@ref)) take XLSX.jl's arguments and behave as
  LibreOffice does: a deleted reference is stored as `#REF!` without its sheet, 3-D references
  follow, new rows copy the formatting of the row above (borders included), and new columns
  that of the column to their left, with the width of the column they push right.
- **Sheet operations** ([`renamesheet!`](@ref), [`deletesheet!`](@ref), [`copysheet!`](@ref),
  [`movesheet!`](@ref)) take XLSX.jl's arguments and behave as LibreOffice does; a copy repoints only
  references whose sheet name is relative, and a name already in use is an error.
- **Defined names** ([`addDefinedName`](@ref), [`deleteDefinedName`](@ref),
  [`deleteAllDefinedNames`](@ref), [`getDefinedNames`](@ref), [`getAllDefinedNames`](@ref)) take
  XLSX.jl's arguments, with LibreOffice's rules: a name may hold `?` but not `\`, and names such
  as `C1x` that LibreOffice reads as references are refused. A sheet's name may refer to another
  sheet, whole columns and rows can be named, and `Bool` constants stay `Bool`. A formula's
  sheet names without `$` are relative, as in LibreOffice. ODF has no system names, so `force` and
  `include_system` change nothing.
- **Hiding** ([`setRowHidden`](@ref), [`setColumnHidden`](@ref), [`setSheetVisibility`](@ref)) and
  **tab colours** ([`setTabColor`](@ref)) take XLSX.jl's arguments. ODF has no very hidden sheets:
  `:veryHidden` hides a sheet as `:hidden` does, as LibreOffice imports Excel's. Theme colours are
  not accepted, as elsewhere in OpenDocumentSpreadsheets.
- **Grouping** ([`groupRows`](@ref), [`groupColumns`](@ref), [`ungroupRows`](@ref),
  [`ungroupColumns`](@ref)) takes XLSX.jl's arguments, but follows LibreOffice, whose groups are
  nested containers rather than Excel's levels per line: groups next to each other stay separate,
  ungrouping removes a whole group (and lifts the groups inside it), and a range that crosses a
  group, or an eighth level, is an error.
- **Panes and the sheet view** ([`freezePanes`](@ref), [`splitPanes`](@ref), [`setSheetView`](@ref),
  [`getSheetView`](@ref)) take XLSX.jl's arguments and are kept as LibreOffice keeps them, in its view
  settings: the page-break view, row and column headers and zeros are the whole file's; a selection
  is kept as its cursor only; zoom runs from 20 to 600; LibreOffice has no page layout view and no
  "frozen split" (`splitFreeze` freezes). A split's position is in screen pixels, so it falls at the
  edge of the rows and columns given on a 96-dpi screen at 100% zoom.
- **Protection** ([`protectSheet`](@ref), [`protectWorkbook`](@ref), [`setCellProtection`](@ref)
  and their getters) takes XLSX.jl's arguments, stored as LibreOffice stores it. Passwords are
  hashed as LibreOffice hashes them (SHA-1 of the UTF-16 text), so any text works, not only 15
  ASCII characters. LibreOffice has no permission to format, sort, insert hyperlinks or edit
  objects and scenarios on a protected sheet, and no window protection: asking for them is an
  error.
- **Printing** ([`setPageSetup`](@ref), [`setPageMargins`](@ref), [`setPrintOptions`](@ref),
  [`setPrintArea`](@ref), [`setPrintTitles`](@ref), [`setHeaderFooter`](@ref) and their getters)
  takes XLSX.jl's arguments, Excel's header codes included, and stores everything as
  LibreOffice's xlsx import stores it: a page style of the sheet's own (`PageStyle_<sheet>`), ODF
  fields and text styles for the codes, `table:print-ranges` and header-row containers. `paperSize`s
  are those the import knows (Excel's 1, 3, 4, 5, 7, 8, 9, 11, 12, 13 and 70), and any other size is
  `paperWidth` and `paperHeight`; headers can't be
  told not to scale or align with the margins (`scaleWithDoc`, `alignWithMargins`), as in
  LibreOffice. A sheet without a page style of its own prints LibreOffice's default header and
  footer, and `getHeaderFooter` says so.
- **Document properties** ([`setDocumentProperties`](@ref), [`setCustomProperty`](@ref) and their
  getters) take XLSX.jl's arguments, stored in meta.xml as LibreOffice's xlsx import stores them.
  ODF has no category, content status, company or manager: they are the custom properties the import
  makes of them (`OOXMLCorePropertyCategory`, `OOXMLCorePropertyContentStatus`, `Company`,
  `Manager`), which `getCustomProperties` leaves out. Custom numbers are ODF's floats (a whole one
  is read back as an `Int64`), and custom properties are kept in name order, as LibreOffice keeps
  them. `getCustomProperties` gives a `Vector` of pairs, not an `OrderedDict`.
- **Hyperlinks** ([`addHyperlink`](@ref) and the rest) take XLSX.jl's arguments. A text cell gets a
  link round its text and a number or formula a link of the cell itself, as LibreOffice's import
  gives XLSX.jl's links. LibreOffice has no tooltips, so `tooltip` is an error.
- **Notes** ([`addComment`](@ref)) are LibreOffice's comments. **Threaded comments** are kept as
  LibreOffice keeps Excel's: inside a note, which shows the thread's text where threads aren't
  supported.
- **Pictures** ([`addImage`](@ref)) are anchored in their first cell and resize with their cells, as
  LibreOffice's import places XLSX.jl's. LibreOffice has no pictures inside cells, so `inCell=true`
  is an error.
- **Data validation** ([`addDataValidation`](@ref)) is LibreOffice's Data ▸ Validity, stored as its
  import stores XLSX.jl's. A cell has one rule.
- **Tables** ([`addtable!`](@ref), [`settotals!`](@ref), [`appendtable!`](@ref), [`table`](@ref),
  `readtable(…; table_name)`, `writetable(…; as_table)` and the rest) are LibreOffice's database
  ranges. LibreOffice has no table styles (`style` is an error) and keeps no totals settings: a
  totals cell's setting is read from its formula, written as LibreOffice saves a structured
  reference (`SUBTOTAL(109,$Sheet.$B$2:$B$5)`). As in LibreOffice, a table's name is formed as a
  defined name's but is apart from them, tables may overlap, and a table may be its header alone.
- **AutoFilters** ([`setAutoFilter`](@ref), [`getAutoFilter`](@ref), [`deleteAutoFilter`](@ref)) take
  XLSX.jl's arguments and criteria, stored in the sheet's anonymous database range as LibreOffice
  stores them. Rows are hidden as LibreOffice's Refresh Range hides them, not as Excel does: text
  LibreOffice reads as a number (`"10"`, `"2026-11-23"`) is compared with numbers by value, list
  items are compared as text (a date matches only at midnight), and rankings count text and
  errors. LibreOffice can't store above- or below-average or relative-date filters, so they are
  errors. `deleteAutoFilter` shows every row of the range, as LibreOffice does. `sort` puts the
  rows in LibreOffice's order (numbers and logicals, text, errors; blanks last), and moves formats,
  validations, notes, links, pictures and hidden rows with them; formulas move as copied and are
  saved without a value. Merged cells (with formats) and array formulas are refused.
- **LibreOffice's own options** are keywords and fields of the XLSX.jl functions they belong with:
  a validation's `caseSensitive` and `sortEntries`, cell protection's `hideAll` and
  `hidePrint`, a note's `date`, a picture's `alt` and `description`, any paper size
  (`paperWidth`, `paperHeight`), `scaleToPages`, six more print options, a table's
  `has_header_row` and `filterButtons`, a filter's `caseSensitive`, `noDuplicates` and regular
  expressions, and a sort's `naturalSort` and `includeFormats`.
- **Rich text** ([`RichTextString`](@ref), [`RichTextRun`](@ref), `getRichTextString`) is LibreOffice's: a run is a span whose text style holds only the run's attributes, so a run takes the attributes it doesn't set from the cell, as in LibreOffice. In Excel those come from the default font. Colours are stored as RGB, and a line break starts a new paragraph. Chart titles take rich text too.
- **Conditional formats** ([`setConditionalFormat`](@ref), `getConditionalFormats`,
  `deleteConditionalFormats`, `setColoredDataBars`) take XLSX.jl's types, keywords and presets,
  and are stored as LibreOffice's rules:
  - **Formats:** each rule's format is a named cell style (`ConditionalStyle_N`), as LibreOffice's
    import makes them; `style` applies any named style instead.
  - **Order:** rules on one range are applied in the order they were set, the first that holds
    winning.
  - **Errors:** what LibreOffice doesn't support (`stopIfTrue`, standard deviations, data bar
    borders, right-to-left bars, custom and reversed icon sets).
  - **Fixed:** `greaterEqual` and `lessEqual` work; XLSX.jl's own files lose them in
    LibreOffice.
  - **LibreOffice's own options:** this, last and next year, its smiley icon sets, and a bar's
    `minLength` and `maxLength`.
- **Charts** (`XLSX.Charts`'s functions, in `OpenDocumentSpreadsheets.Charts`) are LibreOffice's
  chart objects. See [Charts](charts/overview.md).
  - **Look:** new charts take LibreOffice's own.
  - **Data:** values are read from their cells.
  - **References:** a chart's references follow edits and sheet operations as LibreOffice moves
    them (clipped, never `#REF!`; a copy's stay on the source).
  - **LibreOffice's model:** categories are the x axis'; smoothing is the chart's; a line series
    has one colour; theme colours are resolved against the document's theme; legend corners are
    custom positions; a minor unit divides the major one.
  - **Errors:** what LibreOffice can't store (titles from cells, compound lines, joins, marker
    borders, bubble-size labels, text caps, kerning and outlines; the chartex kinds but the
    histogram).
  - **Histograms:** `addChartEx(ws, :histogram, values; …)` works, and makes the same chart as
    `addChart(ws, :histogram; …)` followed by `addSeries`, the form the guide uses. A histogram is an
    ordinary chart in an OpenDocument file; its handle is still a `ChartEx`, with XLSX.jl's histogram
    functions, and `getChartSchema` gives `:cx`.
  - **Chart sheets** are ordinary sheets holding a page-anchored chart.
  - **LibreOffice's own options:** 3-D, stock charts, subtitles, data tables, stepped and B-spline
    lines, empty and hidden cells, the chart wizard's `data`, gradients and hatches, trendlines and
    error bars, explosion, and axis label arrangement.
- **Sparklines** ([`addSparklines`](@ref), [`getSparklines`](@ref), [`deleteSparklines`](@ref)) are
  LibreOffice's sparkline groups. `dateRange` is an error, since LibreOffice keeps none. A sparkline
  goes with its cell through inserts and deletes, and its data moves as a chart's does.

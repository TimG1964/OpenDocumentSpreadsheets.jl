```@meta
CurrentModule = OpenDocumentSpreadsheets.Charts
```

# Charts and sparklines

Charts are XLSX.jl's chart API, in a submodule as in XLSX.jl:

```julia
using OpenDocumentSpreadsheets
using OpenDocumentSpreadsheets.Charts
```

Each chart is stored as LibreOffice stores one: an embedded chart object in a frame. Where Excel and
LibreOffice differ, OpenDocumentSpreadsheets does what LibreOffice does. What LibreOffice can't store
is an error that says why, and LibreOffice's own options are extra keywords ([Coming from
XLSX.jl](../xlsx.md) lists both). Charts work in zipped (`.ods`) and flat (`.fods`) files, new or
edited.

## Making a chart

```julia
xf = newods("Data")
ws = xf["Data"]
ws["A1"] = "Month"; ws["B1"] = "North"; ws["C1"] = "South"
for (i, m) in enumerate(["Jan", "Feb", "Mar", "Apr"])
    ws[i+1, 1] = m; ws[i+1, 2] = 10i; ws[i+1, 3] = 40 - 5i
end

c = addChart(ws, :column; anchor = "E2:L18", title = "Sales", xtitle = "Month", ytitle = "£k")
addSeries(c, "B2:B5"; categories = "A2:A5", name_ref = "B1")
addSeries(c, "C2:C5"; categories = "A2:A5", name_ref = "C1", color = :accent2)
writeods("sales.ods", xf)
```

A chart takes LibreOffice's own look: its palette, symbols, fonts and legend. Its frame is anchored
in the anchor's first cell and resizes with its cells. XLSX.jl's 22 kinds are there (`:column`,
`:stackedBar`, `:lineMarkers`, `:pie`, `:doughnut`, `:scatter`, `:bubble`, `:radar`, `:combo` and the
rest), plus LibreOffice's `:pieOfPie`, `:barOfPie` and four stock charts.

LibreOffice's model shows in a few rules:
- A chart's categories are its x axis': every series of a non-XY chart shares them.
- Smoothing is the chart's: all its lines or none.
- Titles are text: LibreOffice has no titles that follow a cell.

`addChart` also takes LibreOffice's options:
- `subtitle`;
- `threeD` and `deep`;
- `dataTable`;
- `interpolation`: B-spline and stepped lines;
- `emptyCells`, `includeHidden`, `sortByX`;
- a pie's `startAngle`;
- its chart wizard's `data` and `seriesIn`, which make the series of a range at once:

```julia
addChart(ws, :line; anchor = "E20:L36", data = "A1:C5", seriesIn = :columns, interpolation = :stepStart)
```

## Changing a chart

XLSX.jl's setters work on the charts added and on a file's own:

```julia
xf = openods("sales.ods"; mode = "rw")
c = getCharts(xf)[1]
setSeriesFill(c, 1, SchemeColor(:accent1; lumMod = 75))
setSeriesLine(c, 2; width = 2, dash = :sysDash)
setLegendPos(c, :b)
setAxisMin(c, :y, 0); setAxisMajorUnit(c, :y, 10)
setChartTitleTextProp(c, :bold, true)
addTrendline(c, 1, :linear; displayEquation = true)     # LibreOffice's own: XLSX.jl only reads them
writeods("sales.ods", xf; overwrite = true)
```

Some setters follow LibreOffice's model:
- **Theme colours** (`:accent1`, `SchemeColor`) are resolved against the document's theme, with their
  tints and shades applied as LibreOffice's import applies them. LibreOffice keeps no theme link in
  a chart.
- **Line, XY and radar series** have one colour, their line's and their symbols'.
- **Legend corners** (`:tr`, `:tl`, `:bl`, `:br`) are custom positions, as LibreOffice writes `:tr`.
- **A minor unit** must divide the major one, since LibreOffice stores the number of minor steps.

## Reading a chart

```julia
xf = readods("sales.ods")
c = getChart(xf, "Object 1")          # by object name, path, or the frame's name
getChartTypes(c)                       # [:barChart]
getChartData(c)                        # the series' values, read from their cells now
getChartRanges(c)
getSeriesFill(c, 1)                    # an Effective: the value and where it comes from
```

The getters read LibreOffice's own charts, the charts its import makes of Excel's, and the charts
added here. They read a chart as it is now, after the edits and operations since the file was read.
A chart's values come from its cells, as LibreOffice draws them.

## Histograms and chart sheets

Of XLSX.jl's chartex kinds, LibreOffice has the histogram:

```julia
h = addChartEx(ws, :histogram, "B2:B200"; anchor = "N2:U18", name_ref = "B1")
setSeriesBinning(h, 1; binCount = 8)
```

The six other kinds (waterfall, funnel, treemap, sunburst, pareto, box and whisker) are errors.
LibreOffice reads them without a diagram. LibreOffice draws a histogram's bins from their width or
count, but labels the bars with the ranges of its own automatic bins.

A chart sheet (`addChart(xf, kind; sheetname)`, `addChartEx(xf, …)`) is an ordinary sheet holding
the chart anchored to the page, as LibreOffice's import makes one. Its references name their sheet:
`"Data!B2:B7"`.

## Through edits and operations

Charts follow edits and operations as LibreOffice's do:
- **Inserts and deletes:** a chart's references follow inserted and deleted rows and columns.
  LibreOffice clips them and never makes them `#REF!`.
- **Renames:** references follow a renamed sheet.
- **Copies:** a copied sheet's charts keep pointing at the source.
- **Sheet deletes:** references to a deleted sheet move to the one before it.
- **Frames:** a chart's frame moves with its cells, and goes when all its cells do.

## Sparklines

Sparklines are XLSX.jl's, at the top level as in XLSX.jl:

```julia
addSparklines(ws, "F2:F5", "B2:E5"; high = true, highColor = "red")   # one per row
addSparklines(ws, "B6", "B2:B5"; type = :column)
getSparklines(ws)
deleteSparklines(ws, "F3")
```

They are LibreOffice's sparkline groups. `:winloss` is LibreOffice's stacked type. LibreOffice keeps
no date range, so `dateRange` is an error. A sparkline goes with its cell through inserts and
deletes, and its data moves as a chart's does. LibreOffice itself leaves both where they were;
following them keeps each sparkline charting its own cells.

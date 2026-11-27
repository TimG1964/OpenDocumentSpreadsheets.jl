```@meta
CurrentModule = OpenDocumentSpreadsheets.Charts
```

# Reading charts

The getters read a file's charts: those made in LibreOffice, the charts it makes when it opens other
spreadsheet formats, and the charts made here.

```julia
using OpenDocumentSpreadsheets
using OpenDocumentSpreadsheets.Charts

xf = newods("Data")
sh = xf["Data"]
sh["A1:B1"] = ["Month" "Sales"]
sh["A2:B4"] = ["Jan" 10; "Feb" 20; "Mar" 15]
addSeries(addChart(sh, :column; anchor = "D2:J16", title = "Sales"), "B2:B4"; categories = "A2:A4", name_ref = "B1")
writeods("sales.ods", xf; overwrite = true)

xf = readods("sales.ods")
getCharts(xf)                          # every chart in the file
c = getChart(xf, "Object 1")           # by object name, path, or the frame's name
getChartKind(c)                        # :column, as addChart names it
getChartTypes(c)                       # [:barChart] (see below)
getChartTitleText(c)                   # "Sales"
getChartData(c)                        # the series' values, read from their cells now
getChartRanges(c)                      # the series' references
getSeriesFill(c, 1)                    # an Effective: the value, and where it comes from
```

A chart is read as it is now, after the edits and operations since the file was read, and its values
come from its cells, as LibreOffice draws them.

## Chart types

[`getChartKind`](@ref) gives a chart's type as [`addChart`](@ref) names it, the type LibreOffice's
Chart Type dialog shows: whether bars run up (`:column`) or across (`:bar`), whether they are
stacked (`:stackedBar`, `:percentStackedColumn`), and whether lines have points (`:lineMarkers`). It
reads any chart, whatever made it. A few of LibreOffice's types have no kind of their own and give
the nearest: XY with lines only is `:scatter`, and a net with points is `:radar`.

```julia
c2 = addChart(sh, :percentStackedBar; anchor = "D18:J32")
getChartKind(c2)                       # :percentStackedBar
```

[`getChartTypes`](@ref) gives the chart's types, which are broader: one type for each kind of series
group in the chart.

| Made with `addChart` as | `getChartTypes` gives |
|---|---|
| `:column`, `:bar` and their stacked forms | `[:barChart]` |
| `:line`, `:lineMarkers` and their stacked forms | `[:lineChart]` |
| `:area` and its stacked forms | `[:areaChart]` |
| `:pie` / `:doughnut` | `[:pieChart]` / `[:doughnutChart]` |
| `:pieOfPie`, `:barOfPie` | `[:ofPieChart]` |
| `:scatter` / `:bubble` | `[:scatterChart]` / `[:bubbleChart]` |
| `:radar`, `:filledRadar` | `[:radarChart]` |
| `:stock`, `:stockOHLC` | `[:stockChart]` |
| `:stockVolume`, `:stockVolumeOHLC` | `[:barChart, :stockChart]` |
| `:combo`, or any chart after [`makeCombo`](@ref) | `[:barChart, :lineChart]` |

A 3-D chart gives `:bar3DChart`, `:line3DChart`, `:area3DChart` or `:pie3DChart`.
[`getChartType`](@ref) gives the one type, or `:combo` for a chart of two. 3-D isn't part of
`getChartKind`'s kind: these 3-D types tell it.

A chart's formatting is read from LibreOffice's chart styles into the types the setters take. Where a
value isn't set on the chart itself, an `Effective` says where it comes from: LibreOffice's defaults,
the chart's style, or the series.

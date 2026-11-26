```@meta
CurrentModule = OpenDocumentSpreadsheets.Charts
```

# Reading charts

The getters read a file's charts: LibreOffice's own, the charts it makes when it opens other
spreadsheet formats, and the charts made here.

```julia
using OpenDocumentSpreadsheets
using OpenDocumentSpreadsheets.Charts

xf = newods("Data")
ws = xf["Data"]
ws["A1:B1"] = ["Month" "Sales"]
ws["A2:B4"] = ["Jan" 10; "Feb" 20; "Mar" 15]
addSeries(addChart(ws, :column; anchor = "D2:J16", title = "Sales"), "B2:B4"; categories = "A2:A4", name_ref = "B1")
writeods("sales.ods", xf; overwrite = true)

xf = readods("sales.ods")
getCharts(xf)                          # every chart in the file
c = getChart(xf, "Object 1")           # by object name, path, or the frame's name
getChartTypes(c)                       # [:barChart]
getChartTitleText(c)                   # "Sales"
getChartData(c)                        # the series' values, read from their cells now
getChartRanges(c)                      # the series' references
getSeriesFill(c, 1)                    # an Effective: the value, and where it comes from
```

A chart is read as it is now, after the edits and operations since the file was read, and its values
come from its cells, as LibreOffice draws them.

A chart's formatting is read from LibreOffice's chart styles into the types the setters take. Where a
value isn't set on the chart itself, an `Effective` says where it comes from: LibreOffice's defaults,
the chart's style, or the series.

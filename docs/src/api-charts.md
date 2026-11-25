```@meta
CurrentModule = OpenDocumentSpreadsheets.Charts
```

# API reference: charts

Charts are LibreOffice's embedded chart objects (phase 8). As in XLSX.jl, the chart functions are
in a submodule:

```julia
using OpenDocumentSpreadsheets.Charts
```

A few names are also available at the top level: `getCharts`, `getChart`, `getChartData`,
`getChartRanges`, `getChartType`, `getChartSchema` and the chart types.

The functions read a chart as it is now: after the edits and structural operations made since the file
was read. A series' values are read from its cells, as LibreOffice draws them.

```@docs
Charts
```

## Creating charts

A chart added here takes LibreOffice's own look (its colours, symbols, fonts and legend). It is a
frame anchored in its first cell and resizing with its cells, and its references follow inserts,
deletes and sheet operations as LibreOffice moves them.

```@docs
addChart
addSeries
makeCombo
deleteChart
```

## Histograms and chart sheets

Of XLSX.jl's chartex kinds LibreOffice has the histogram, which `addChartEx` makes as LibreOffice's
own; the other six are errors. A chart sheet is LibreOffice's form of one: an ordinary sheet holding
one chart anchored to the page.

```@docs
addChartEx
addChart(::OpenDocumentSpreadsheets.ODSFile, ::Symbol)
getChartSeriesCount
setSeriesName
getSeriesSubtotals
ChartExDimension
ChartExData
ChartExBinning
```

## Changing formatting

XLSX.jl's setters, on LibreOffice's chart styles: for charts added here and for a zipped file's own
charts. Each returns the chart, and `:inherit` removes a setting. What LibreOffice can't store is an
error (D-084): compound lines, joins and miter limits; a marker's own fill or border; bubble-size labels;
text capitals, kerning sizes and outlines; a minor unit that doesn't divide the major one. Theme colours
are resolved against the document's theme, as LibreOffice's import resolves them: LibreOffice keeps no
theme reference in a chart. A line, XY or radar series has one colour, its line's and its symbols'.

```@docs
setSeriesFill
setSeriesLine
setMarker
setLabelFlag
setLabelText
setChartTitleText
setChartTitleTextProp
setLegendPos
setPlotAreaLine
setAxisScaling
setGroupGapWidth
SchemeColor
```

### LibreOffice's own

Trendlines and error bars (which XLSX.jl reads but can't set), explosion and axis label arrangement
(D-076). `addChart`'s own options (stock charts, interpolation, empty and hidden cells, the data table,
the chart wizard's `data` and `seriesIn`) are under [`addChart`](@ref).

```@docs
addTrendline
setErrorBars
setSeriesExplosion
setAxisLabelArrangement
```

## Finding charts

```@docs
getCharts
getChart
getChartSchema
getChartType
getChartTypes
getChartGroups
getChartTitle
```

## Series and data

```@docs
getChartSeries
getChartRanges
getChartData
iserror(::ChartRef)
```

## Reading formatting

A chart's formatting is read from LibreOffice's styles, in XLSX.jl's DrawingML-shaped types. Fields ODF
has no value for are `nothing`.

### Titles, legend and chart

```@docs
getChartTitleText
getChartTitleShapeProps
getChartTitleRef
getChartLegend
getLegendPos
getLegendOverlay
getLegendShapeProps
getLegendEntryDeleted
getPlotAreaShapeProps
```

### Series, points and labels

```@docs
getSeriesShapeProps
getSeriesMarker
getSeriesGroup
getSeriesDataPoints
getDataPointShapeProps
getSeriesDataLabels
getDataLabelTextProps
getLabelFlag
getSeriesFill
getLabelTextProp
```

### Trendlines, error bars and groups

```@docs
getSeriesTrendlines
getSeriesErrorBars
getGroupDropLines
getGroupUpDownBars
getGroupGapWidth
getGroupLabelTextProps
```

### Axes

```@docs
getChartAxes
getChartAxis
getAxisShapeProps
getAxisTitle
getAxisGridlines
getAxisPartner
getAxisNumberFormatCode
getAxisMajorTickMark
getAxisTickLabelPos
getAxisOrientation
getAxisCrosses
getAxisMajorUnit
getAxisLabelAlign
hasFill
```

## Types

```@docs
AbstractChart
Chart
ChartEx
ChartRef
ChartSeries
ChartRange
ChartRanges
ChartGroup
ChartAxis
ChartDataPoint
ChartDataLabel
ChartMarker
ChartTrendline
ChartErrorBars
ChartUpDownBars
ColorSpec
DrawingColor
DrawingFill
DrawingLine
DrawingShapeProps
DrawingRunProps
DrawingParaProps
DrawingRun
DrawingParagraph
DrawingBodyProps
DrawingText
Effective
FormatSite
```

## Sparklines

Sparklines are LibreOffice's sparkline groups. As in XLSX.jl, the functions are bound at the top level
(`addSparklines`, not `Charts.addSparklines`). A sparkline follows its cell through inserts and deletes,
and its data moves as a chart's does. LibreOffice itself leaves both where they were.

```@docs
addSparklines
getSparklines
deleteSparklines
```

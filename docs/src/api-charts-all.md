```@meta
CurrentModule = OpenDocumentSpreadsheets.Charts
```

# API reference: every chart function

[Charts](api-charts.md) documents most chart functions in families: [`setAxisScaling`](@ref) covers
`setAxisMin`, `setAxisMax` and the axis's other limits, for example. This page gives each of those
functions an entry of its own, with its signature and a link to its family, grouped by what it
works on.

## Titles, legend and the chart

```@docs
getAutoTitleDeleted
getChartTitleRange
getChartTitleTextProps
getChartSpaceShapeProps
getChartSpaceTextProps
setChartSpaceTextProp
getLegendTextProps
setLegendEntryDeleted
setLegendOverlay
setLegendTextProp
```

## Series and their lines

```@docs
getSeriesName
getSeriesNameRange
getSeriesData
getSeriesHidden
getSeriesAxes
getSeriesAxisIds
getChartAxisIds
getSeriesLine
hasLine
setSeriesLineColor
setSeriesLineWidth
setSeriesLineDash
setSeriesLineCap
setSeriesLineCompound
setSeriesLineJoin
setSeriesLineMiterLimit
```

## Markers and points

```@docs
getSeriesDataPoint
getDataPointMarker
getMarkerFill
setMarkerSymbol
setMarkerSize
setMarkerFill
setMarkerLineColor
setMarkerLineWidth
```

## Data labels

```@docs
getSeriesDataLabel
getSeriesLabelTextProps
getDataLabelText
getDataLabelPosition
getDataLabelOffset
getDataLabelShapeProps
getLabelPosition
setLabelDeleted
setLabelTextProp
```

## Trendlines, error bars and groups

```@docs
getTrendlineShapeProps
getTrendlineLabelText
getTrendlineLabelTextProps
getTrendlineLabelShapeProps
deleteSeriesTrendlines
getErrorBarsShapeProps
getErrorBarsCustomRefs
deleteSeriesErrorBars
getGroupAxes
getGroupOverlap
setGroupOverlap
getGroupHiLowLines
getGroupSeriesLines
getUpBarShapeProps
getDownBarShapeProps
setGroupLabelTextProp
```

## Axes

```@docs
getAxisMin
getAxisMax
getAxisLogBase
setAxisLogBase
getAxisMinorUnit
getAxisMinorTickMark
getAxisCrossesAt
getAxisCrossBetween
getAxisLabelOffset
getAxisMultiLevelLabels
getAxisNumberFormatLinked
getAxisTextProps
getAxisTitleText
getAxisTitleRef
getAxisTitleRange
getAxisTitleTextProps
setAxisMin
setAxisMax
setAxisMajorUnit
setAxisMinorUnit
setAxisOrientation
setAxisCrosses
setAxisCrossesAt
setAxisMajorTickMark
setAxisMinorTickMark
setAxisTickLabelPos
setAxisGridlines
setAxisLine
setAxisNumberFormatCode
setAxisNumberFormatLinked
setAxisTextProp
setAxisTitleText
setAxisTitleTextProp
```

## Histograms

A histogram's bins, and the settings of chart kinds LibreOffice doesn't have, which a histogram
doesn't have either: their setters are errors, and their getters give `nothing`.

```@docs
setSeriesBinning
getSeriesBinning
getChartDataBlocks
getSeriesLayout
setSeriesAggregation
getSeriesAggregation
setSeriesQuartileMethod
getSeriesQuartileMethod
setSeriesParentLabelLayout
getSeriesParentLabelLayout
setSeriesLayoutFlag
getSeriesLayoutFlag
setSeriesSubtotals
```

## Constants

```@docs
COLOR_TRANSFORMS
SCHEME_TOKENS
CX_KINDS
```

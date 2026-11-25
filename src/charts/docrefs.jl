# Docstrings of the public names documented with their families (phase 9): each its own signature
# and a link to its family, so that `?name` shows something. Generated, then checked by hand.

"""
    deleteErrorBars(c, i) -> Chart

See [`setErrorBars`](@ref), which documents it with the functions like it.
"""
deleteErrorBars

"""
    deleteTrendlines(c, i) -> Chart

See [`addTrendline`](@ref), which documents it with the functions like it.
"""
deleteTrendlines

"""
    getAutoTitleDeleted(c) -> Nothing

See [`getChartTitleRef`](@ref), which documents it with the functions like it.
"""
getAutoTitleDeleted

"""
    getAxisCrossBetween(c, ax)

See [`getAxisLabelAlign`](@ref), which documents it with the functions like it.
"""
getAxisCrossBetween

"""
    getAxisCrossesAt(c, ax) -> Union{Nothing,Float64}

See [`getAxisCrosses`](@ref), which documents it with the functions like it.
"""
getAxisCrossesAt

"""
    getAxisLabelOffset(c, ax)

See [`getAxisLabelAlign`](@ref), which documents it with the functions like it.
"""
getAxisLabelOffset

"""
    getAxisLogBase(c, ax)

See [`getAxisOrientation`](@ref), which documents it with the functions like it.
"""
getAxisLogBase

"""
    getAxisMax(c, ax)

See [`getAxisOrientation`](@ref), which documents it with the functions like it.
"""
getAxisMax

"""
    getAxisMin(c, ax)

See [`getAxisOrientation`](@ref), which documents it with the functions like it.
"""
getAxisMin

"""
    getAxisMinorTickMark(c, ax) -> Union{Nothing,Symbol}

See [`getAxisMajorTickMark`](@ref), which documents it with the functions like it.
"""
getAxisMinorTickMark

"""
    getAxisMinorUnit(c, ax) -> Union{Nothing,Float64}

See [`getAxisMajorUnit`](@ref), which documents it with the functions like it.
"""
getAxisMinorUnit

"""
    getAxisMultiLevelLabels(c, ax)

See [`getAxisLabelAlign`](@ref), which documents it with the functions like it.
"""
getAxisMultiLevelLabels

"""
    getAxisNumberFormatLinked(c, ax) -> Union{Nothing,Bool}

See [`getAxisNumberFormatCode`](@ref), which documents it with the functions like it.
"""
getAxisNumberFormatLinked

"""
    getAxisTextProps(c, ax)

See [`getAxisShapeProps`](@ref), which documents it with the functions like it.
"""
getAxisTextProps

"""
    getAxisTitleRange(c, ax) -> Nothing

See [`getAxisTitle`](@ref), which documents it with the functions like it.
"""
getAxisTitleRange

"""
    getAxisTitleRef(c, ax) -> Nothing

See [`getAxisTitle`](@ref), which documents it with the functions like it.
"""
getAxisTitleRef

"""
    getAxisTitleText(c, ax) -> Union{Nothing,DrawingText}

See [`getAxisTitle`](@ref), which documents it with the functions like it.
"""
getAxisTitleText

"""
    getAxisTitleTextProps(c, ax) -> Union{Nothing,DrawingText}

See [`getAxisTitle`](@ref), which documents it with the functions like it.
"""
getAxisTitleTextProps

"""
    getChartAxisIds(c::ChartEx)

See [`getChartSeriesCount`](@ref), which documents it with the functions like it.
"""
getChartAxisIds

"""
    getChartDataBlocks(c::ChartEx)

See [`getChartSeriesCount`](@ref), which documents it with the functions like it.
"""
getChartDataBlocks

"""
    getChartSpaceShapeProps(c) -> Union{Nothing,DrawingShapeProps}

See [`getPlotAreaShapeProps`](@ref), which documents it with the functions like it.
"""
getChartSpaceShapeProps

"""
    getChartSpaceTextProps(c) -> Union{Nothing,DrawingText}

See [`getPlotAreaShapeProps`](@ref), which documents it with the functions like it.
"""
getChartSpaceTextProps

"""
    getChartTitleRange(c) -> Nothing

See [`getChartTitleRef`](@ref), which documents it with the functions like it.
"""
getChartTitleRange

"""
    getChartTitleTextProps(c) -> Union{Nothing,DrawingText}

See [`getChartTitleShapeProps`](@ref), which documents it with the functions like it.
"""
getChartTitleTextProps

"""
    getDataLabelOffset(c, d)

See [`getDataLabelTextProps`](@ref), which documents it with the functions like it.
"""
getDataLabelOffset

"""
    getDataLabelPosition(c, d)

See [`getDataLabelTextProps`](@ref), which documents it with the functions like it.
"""
getDataLabelPosition

"""
    getDataLabelShapeProps(c, d)

See [`getDataLabelTextProps`](@ref), which documents it with the functions like it.
"""
getDataLabelShapeProps

"""
    getDataLabelText(c, d)

See [`getDataLabelTextProps`](@ref), which documents it with the functions like it.
"""
getDataLabelText

"""
    getDataPointMarker(c, d::ChartDataPoint) -> Union{Nothing,ChartMarker}

See [`getDataPointShapeProps`](@ref), which documents it with the functions like it.
"""
getDataPointMarker

"""
    getDownBarShapeProps(c, b)

See [`getGroupUpDownBars`](@ref), which documents it with the functions like it.
"""
getDownBarShapeProps

"""
    getErrorBarsCustomRefs(c, e) -> (plus, minus)

See [`getSeriesErrorBars`](@ref), which documents it with the functions like it.
"""
getErrorBarsCustomRefs

"""
    getErrorBarsShapeProps(c, e) -> Union{Nothing,DrawingShapeProps}

See [`getSeriesErrorBars`](@ref), which documents it with the functions like it.
"""
getErrorBarsShapeProps

"""
    getGroupAxes(c, g) -> Vector{ChartAxis}

See [`getSeriesGroup`](@ref), which documents it with the functions like it.
"""
getGroupAxes

"""
    getGroupHiLowLines(c, g) -> Nothing

See [`getGroupDropLines`](@ref), which documents it with the functions like it.
"""
getGroupHiLowLines

"""
    getGroupOverlap(c, g) -> Union{Nothing,Int}

See [`getGroupGapWidth`](@ref), which documents it with the functions like it.
"""
getGroupOverlap

"""
    getGroupSeriesLines(c, g) -> Nothing

See [`getGroupDropLines`](@ref), which documents it with the functions like it.
"""
getGroupSeriesLines

"""
    getLabelPosition(c::ChartEx, i)

See [`getChartSeriesCount`](@ref), which documents it with the functions like it.
"""
getLabelPosition

"""
    getLegendTextProps(c) -> Union{Nothing,DrawingText}

See [`getLegendShapeProps`](@ref), which documents it with the functions like it.
"""
getLegendTextProps

"""
    getMarkerFill(c, i, point) -> Effective{DrawingFill}

See [`getSeriesFill`](@ref), which documents it with the functions like it.
"""
getMarkerFill

"""
    getSeriesAggregation(c::ChartEx, i)

See [`getSeriesSubtotals`](@ref), which documents it with the functions like it.
"""
getSeriesAggregation

"""
    getSeriesAxes(c, i) -> Vector{ChartAxis}

See [`getSeriesGroup`](@ref), which documents it with the functions like it.
"""
getSeriesAxes

"""
    getSeriesAxisIds(c::ChartEx, i)

See [`getChartSeriesCount`](@ref), which documents it with the functions like it.
"""
getSeriesAxisIds

"""
    getSeriesBinning(c::ChartEx, i)

See [`getChartSeriesCount`](@ref), which documents it with the functions like it.
"""
getSeriesBinning

"""
    getSeriesData(c::ChartEx, i)

See [`getChartSeriesCount`](@ref), which documents it with the functions like it.
"""
getSeriesData

"""
    getSeriesDataLabel(c, i, point) -> Union{Nothing,ChartDataLabel}

See [`getSeriesDataLabels`](@ref), which documents it with the functions like it.
"""
getSeriesDataLabel

"""
    getSeriesDataPoint(c, i, point) -> Union{Nothing,ChartDataPoint}

See [`getSeriesDataPoints`](@ref), which documents it with the functions like it.
"""
getSeriesDataPoint

"""
    getSeriesHidden(c::ChartEx, i)

See [`getChartSeriesCount`](@ref), which documents it with the functions like it.
"""
getSeriesHidden

"""
    getSeriesLabelTextProps(c, i) -> Union{Nothing,DrawingText}

See [`getSeriesShapeProps`](@ref), which documents it with the functions like it.
"""
getSeriesLabelTextProps

"""
    getSeriesLayout(c::ChartEx, i) -> Symbol

See [`getChartSeriesCount`](@ref), which documents it with the functions like it.
"""
getSeriesLayout

"""
    getSeriesLayoutFlag(c::ChartEx, i, flag)

See [`getSeriesSubtotals`](@ref), which documents it with the functions like it.
"""
getSeriesLayoutFlag

"""
    getSeriesLine(c, i; point = nothing) -> Effective{DrawingLine}

See [`getSeriesFill`](@ref), which documents it with the functions like it.
"""
getSeriesLine

"""
    getSeriesName(c::ChartEx, i)

See [`getChartSeriesCount`](@ref), which documents it with the functions like it.
"""
getSeriesName

"""
    getSeriesNameRange(c::ChartEx, i)

See [`getChartSeriesCount`](@ref), which documents it with the functions like it.
"""
getSeriesNameRange

"""
    getSeriesParentLabelLayout(c::ChartEx, i)

See [`getSeriesSubtotals`](@ref), which documents it with the functions like it.
"""
getSeriesParentLabelLayout

"""
    getSeriesQuartileMethod(c::ChartEx, i)

See [`getSeriesSubtotals`](@ref), which documents it with the functions like it.
"""
getSeriesQuartileMethod

"""
    getTrendlineLabelShapeProps(c, t)

See [`getSeriesTrendlines`](@ref), which documents it with the functions like it.
"""
getTrendlineLabelShapeProps

"""
    getTrendlineLabelText(c, t)

See [`getSeriesTrendlines`](@ref), which documents it with the functions like it.
"""
getTrendlineLabelText

"""
    getTrendlineLabelTextProps(c, t)

See [`getSeriesTrendlines`](@ref), which documents it with the functions like it.
"""
getTrendlineLabelTextProps

"""
    getTrendlineShapeProps(c, t)

See [`getSeriesTrendlines`](@ref), which documents it with the functions like it.
"""
getTrendlineShapeProps

"""
    getUpBarShapeProps(c, b)

See [`getGroupUpDownBars`](@ref), which documents it with the functions like it.
"""
getUpBarShapeProps

"""
    hasLine(x) -> Bool

See [`hasFill`](@ref), which documents it with the functions like it.
"""
hasLine

"""
    setAxisCrosses(c, ax, rule) -> Chart

See [`setAxisScaling`](@ref), which documents it with the functions like it.
"""
setAxisCrosses

"""
    setAxisCrossesAt(c, ax, value) -> Chart

See [`setAxisScaling`](@ref), which documents it with the functions like it.
"""
setAxisCrossesAt

"""
    setAxisGridlines(c, ax; major, minor) -> Chart

See [`setAxisScaling`](@ref), which documents it with the functions like it.
"""
setAxisGridlines

"""
    setAxisLine(c, ax; …) -> Chart

See [`setAxisScaling`](@ref), which documents it with the functions like it.
"""
setAxisLine

"""
    setAxisMajorTickMark(c, ax, mark) -> Chart

See [`setAxisScaling`](@ref), which documents it with the functions like it.
"""
setAxisMajorTickMark

"""
    setAxisMajorUnit(c, ax, value) -> Chart

See [`setAxisScaling`](@ref), which documents it with the functions like it.
"""
setAxisMajorUnit

"""
    setAxisMax(c, ax, value) -> Chart

See [`setAxisScaling`](@ref), which documents it with the functions like it.
"""
setAxisMax

"""
    setAxisMin(c, ax, value) -> Chart

See [`setAxisScaling`](@ref), which documents it with the functions like it.
"""
setAxisMin

"""
    setAxisMinorTickMark(c, ax, mark) -> Chart

See [`setAxisScaling`](@ref), which documents it with the functions like it.
"""
setAxisMinorTickMark

"""
    setAxisMinorUnit(c, ax, value) -> Chart

See [`setAxisScaling`](@ref), which documents it with the functions like it.
"""
setAxisMinorUnit

"""
    setAxisNumberFormatCode(c, ax, code) -> Chart

See [`setAxisScaling`](@ref), which documents it with the functions like it.
"""
setAxisNumberFormatCode

"""
    setAxisNumberFormatLinked(c, ax, linked) -> Chart

See [`setAxisScaling`](@ref), which documents it with the functions like it.
"""
setAxisNumberFormatLinked

"""
    setAxisOrientation(c, ax, orientation) -> Chart

See [`setAxisScaling`](@ref), which documents it with the functions like it.
"""
setAxisOrientation

"""
    setAxisTextProp(c, ax, field, value) -> Chart

See [`setChartTitleTextProp`](@ref), which documents it with the functions like it.
"""
setAxisTextProp

"""
    setAxisTickLabelPos(c, ax, pos) -> Chart

See [`setAxisScaling`](@ref), which documents it with the functions like it.
"""
setAxisTickLabelPos

"""
    setAxisTitleText(c, ax, text) -> Chart

See [`setChartTitleText`](@ref), which documents it with the functions like it.
"""
setAxisTitleText

"""
    setAxisTitleTextProp(c, ax, field, value) -> Chart

See [`setChartTitleTextProp`](@ref), which documents it with the functions like it.
"""
setAxisTitleTextProp

"""
    setChartSpaceTextProp(c, field, value) -> Chart

See [`setChartTitleTextProp`](@ref), which documents it with the functions like it.
"""
setChartSpaceTextProp

"""
    setGroupLabelTextProp(c, g, field, value) -> Chart

See [`setChartTitleTextProp`](@ref), which documents it with the functions like it.
"""
setGroupLabelTextProp

"""
    setGroupOverlap(c, g, pct) -> Chart

See [`setGroupGapWidth`](@ref), which documents it with the functions like it.
"""
setGroupOverlap

"""
    setLabelDeleted(c, i, point, deleted) -> Chart

See [`setLabelText`](@ref), which documents it with the functions like it.
"""
setLabelDeleted

"""
    setLabelTextProp(c, i, field, value) -> Chart

See [`setChartTitleTextProp`](@ref), which documents it with the functions like it.
"""
setLabelTextProp

"""
    setLegendEntryDeleted(c, positions, deleted) -> Chart

See [`setLegendPos`](@ref), which documents it with the functions like it.
"""
setLegendEntryDeleted

"""
    setLegendOverlay(c, overlay) -> Chart

See [`setLegendPos`](@ref), which documents it with the functions like it.
"""
setLegendOverlay

"""
    setLegendTextProp(c, field, value) -> Chart

See [`setChartTitleTextProp`](@ref), which documents it with the functions like it.
"""
setLegendTextProp

"""
    setMarkerFill(c, i, value; point = nothing) -> error

See [`setMarker`](@ref), which documents it with the functions like it.
"""
setMarkerFill

"""
    setMarkerLineColor(c, i, value; point = nothing) -> error

See [`setMarker`](@ref), which documents it with the functions like it.
"""
setMarkerLineColor

"""
    setMarkerLineWidth(c, i, value; point = nothing) -> error

See [`setMarker`](@ref), which documents it with the functions like it.
"""
setMarkerLineWidth

"""
    setMarkerSize(c, i, size; point = nothing) -> Chart

See [`setMarker`](@ref), which documents it with the functions like it.
"""
setMarkerSize

"""
    setMarkerSymbol(c, i, symbol; point = nothing) -> Chart

See [`setMarker`](@ref), which documents it with the functions like it.
"""
setMarkerSymbol

"""
    setSeriesBinning(c::ChartEx, i; binSize, binCount, intervalClosed, underflow, overflow) -> ChartEx

See [`setSeriesName`](@ref), which documents it with the functions like it.
"""
setSeriesBinning

"""
    setSeriesLineCap(c, i, value) -> Chart

See [`setSeriesLine`](@ref), which documents it with the functions like it.
"""
setSeriesLineCap

"""
    setSeriesLineColor(c, i, value) -> Chart

See [`setSeriesLine`](@ref), which documents it with the functions like it.
"""
setSeriesLineColor

"""
    setSeriesLineCompound(c, i, value) -> error

See [`setSeriesLine`](@ref), which documents it with the functions like it.
"""
setSeriesLineCompound

"""
    setSeriesLineDash(c, i, value) -> Chart

See [`setSeriesLine`](@ref), which documents it with the functions like it.
"""
setSeriesLineDash

"""
    setSeriesLineJoin(c, i, value) -> error

See [`setSeriesLine`](@ref), which documents it with the functions like it.
"""
setSeriesLineJoin

"""
    setSeriesLineMiterLimit(c, i, value) -> error

See [`setSeriesLine`](@ref), which documents it with the functions like it.
"""
setSeriesLineMiterLimit

"""
    setSeriesLineWidth(c, i, value) -> Chart

See [`setSeriesLine`](@ref), which documents it with the functions like it.
"""
setSeriesLineWidth

"""
    setSeriesSubtotals(c::ChartEx, i, points) / setSeriesAggregation(c::ChartEx, i, on)
    setSeriesQuartileMethod(c::ChartEx, i, method) / setSeriesParentLabelLayout(c::ChartEx, i, layout)
    setSeriesLayoutFlag(c::ChartEx, i, flag, value) -> error

Settings of the chartex kinds LibreOffice lacks (waterfall, box and whisker, treemap) and of an
aggregated histogram: errors (D-086). See [`setSeriesName`](@ref).
"""
setSeriesSubtotals
@doc (@doc setSeriesSubtotals) setSeriesAggregation
@doc (@doc setSeriesSubtotals) setSeriesQuartileMethod
@doc (@doc setSeriesSubtotals) setSeriesParentLabelLayout
@doc (@doc setSeriesSubtotals) setSeriesLayoutFlag

"""
    SCHEME_TOKENS, COLOR_TRANSFORMS

A [`SchemeColor`](@ref)'s tokens (`:bg1`, `:tx1`, …, `:accent1` … `:accent6`, `:hlink`, `:folHlink`
and the aliases `:lt1`, `:dk1`, `:lt2`, `:dk2`) and transforms (`:lumMod`, `:lumOff`, `:shade`, `:tint`,
`:satMod`, `:alpha`), as XLSX.jl's.
"""
SCHEME_TOKENS
@doc (@doc SCHEME_TOKENS) COLOR_TRANSFORMS

"""
    CX_KINDS

XLSX.jl's chartex kinds: `:waterfall`, `:funnel`, `:treemap`, `:sunburst`, `:histogram`, `:pareto`,
`:boxWhisker`. LibreOffice has the histogram; see [`addChartEx`](@ref).
"""
CX_KINDS

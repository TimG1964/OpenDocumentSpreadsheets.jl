"""
    OpenDocumentSpreadsheets.Charts

Charts: LibreOffice's embedded chart objects. Make, format and read a file's charts, with
LibreOffice's behaviour.

    using OpenDocumentSpreadsheets.Charts

A chart is an object (`Object 1/content.xml`) framed in a sheet. The functions read it as it is
now, after the edits and structural operations made since the file was read.
"""
module Charts

using ..OpenDocumentSpreadsheets: OpenDocumentSpreadsheets, ODSFile, Worksheet, ODSError, SheetCore, XML, DataTable,
    SheetCellRef, SheetCellRange, SheetColumnRange, SheetRowRange, NonContiguousRange,
    getcell, Cell, get_odsfile, hassheet, getFormat, FileFrame, _chart_text_now,
    _sheets, _file_frames, _frame_end, _current_line, _line_at, _attr_cm, _sort_cleared, _moved_now,
    _rewritten, _object_source, read_part_text, partnames, _areas, parse_ref, _style_code,
    ImageData, ChartObj, _start_tag_end, CellRange, row_number, column_number, CellRef, _col_cm, _row_cm, _frame_edit!, _touch_cell!,
    _escape_attr, _escape_text, _check_xml_text, _space_count, _content_error, _new_object_name, _require_writable, numfmt_to_odf, _ds_body, addsheet!, _spark_state,
    RichTextString, RichTextRun
using Colors: Colors

import ..OpenDocumentSpreadsheets: iserror, geterror

include("types.jl")
include("discovery.jl")
include("data.jl")
include("drawing.jl")
include("format.jl")
include("axes.jl")
include("create.jl")
include("setters.jl")
include("chartex.jl")
include("sparklines.jl")
include("show.jl")
include("docrefs.jl")

export
    # creating
    addChart, addSeries, makeCombo, deleteChart,
    # finding and reading
    getCharts, getChart, getChartSchema, getChartType, getChartTypes, getChartGroups, getChartTitle,
    getChartSeries, getChartRanges, getChartData,
    # chart-level formatting
    getChartTitleText, getChartTitleRef, getChartTitleRange, getChartTitleShapeProps, getChartTitleTextProps,
    getAutoTitleDeleted, getChartLegend, getLegendPos, getLegendOverlay, getLegendShapeProps, getLegendTextProps,
    getLegendEntryDeleted, getPlotAreaShapeProps, getChartSpaceShapeProps, getChartSpaceTextProps,
    # series, points, markers and labels
    getSeriesShapeProps, getSeriesLabelTextProps, getSeriesMarker, getSeriesGroup, getSeriesAxes, getGroupAxes,
    getGroupLabelTextProps, getSeriesDataPoints, getSeriesDataPoint, getDataPointShapeProps, getDataPointMarker,
    getSeriesDataLabels, getSeriesDataLabel, getDataLabelTextProps, getDataLabelShapeProps, getDataLabelText,
    getDataLabelPosition, getDataLabelOffset, getLabelFlag, getSeriesFill, getSeriesLine, getMarkerFill, getLabelTextProp,
    # trendlines, error bars and groups
    getSeriesTrendlines, getTrendlineShapeProps, getTrendlineLabelText, getTrendlineLabelTextProps,
    getTrendlineLabelShapeProps, getSeriesErrorBars, getErrorBarsShapeProps, getErrorBarsCustomRefs,
    getGroupDropLines, getGroupHiLowLines, getGroupSeriesLines, getGroupUpDownBars, getUpBarShapeProps,
    getDownBarShapeProps, getGroupGapWidth, getGroupOverlap,
    # axes
    getChartAxes, getChartAxis, getAxisShapeProps, getAxisTextProps, getAxisTitle, getAxisTitleText,
    getAxisTitleTextProps, getAxisTitleRef, getAxisTitleRange, getAxisGridlines, getAxisPartner,
    getAxisNumberFormatCode, getAxisNumberFormatLinked, getAxisMajorTickMark, getAxisMinorTickMark,
    getAxisTickLabelPos, getAxisOrientation, getAxisMin, getAxisMax, getAxisLogBase, getAxisCrosses,
    getAxisCrossesAt, getAxisMajorUnit, getAxisMinorUnit, getAxisLabelAlign, getAxisLabelOffset,
    getAxisMultiLevelLabels, getAxisCrossBetween,
    # predicates
    hasFill, hasLine,
    # formatting setters (step 6)
    setChartTitleText, setChartTitleTextProp, setChartSpaceTextProp, setLegendTextProp, setLegendEntryDeleted,
    setLegendPos, setLegendOverlay, setPlotAreaLine,
    setSeriesFill, setSeriesLine, setSeriesLineColor, setSeriesLineWidth, setSeriesLineDash, setSeriesLineCap,
    setSeriesLineCompound, setSeriesLineJoin, setSeriesLineMiterLimit, setGroupLabelTextProp, setGroupGapWidth,
    setGroupOverlap, setAxisTitleText, setAxisTitleTextProp, setAxisTickLabelPos, setAxisScaling, setAxisMin, setAxisMax,
    setAxisOrientation, setAxisCrosses, setAxisCrossesAt, setAxisNumberFormatCode, setAxisNumberFormatLinked,
    setAxisMajorTickMark, setAxisMinorTickMark, setAxisGridlines, setAxisTextProp, setAxisLine, setAxisMajorUnit,
    setAxisMinorUnit, setMarker, setMarkerSymbol, setMarkerSize, setMarkerFill, setMarkerLineColor, setMarkerLineWidth,
    setLabelText, setLabelTextProp, setLabelDeleted, setLabelFlag,
    # LibreOffice's own (D-076); a chart's kind read back (D-095)
    getChartKind, addTrendline, deleteTrendlines, setErrorBars, deleteErrorBars, setAxisLabelArrangement, setSeriesExplosion,
    # types users construct
    SchemeColor,
    # chartex charts and chart sheets (step 7)
    addChartEx, getChartSeriesCount, getSeriesLayout, getSeriesName, getSeriesNameRange, getChartDataBlocks, getSeriesData,
    getSeriesHidden, getSeriesAxisIds, getChartAxisIds, getLabelPosition, getSeriesBinning, getSeriesSubtotals,
    getSeriesAggregation, getSeriesQuartileMethod, getSeriesParentLabelLayout, getSeriesLayoutFlag, setSeriesName,
    setSeriesBinning, setSeriesSubtotals, setSeriesAggregation, setSeriesQuartileMethod, setSeriesParentLabelLayout,
    setSeriesLayoutFlag

if VERSION >= v"1.11.0-DEV.469"
    eval(Meta.parse("public AbstractChart, Chart, ChartEx, ChartRef, ChartRange, ChartRanges, ChartSeries, ChartGroup, " *
                    "ChartAxis, ChartDataPoint, ChartDataLabel, ChartMarker, ChartTrendline, ChartErrorBars, ChartUpDownBars, " *
                    "ColorSpec, DrawingColor, DrawingFill, DrawingLine, DrawingShapeProps, DrawingRunProps, DrawingParaProps, " *
                    "DrawingRun, DrawingParagraph, DrawingBodyProps, DrawingText, Effective, FormatSite, SCHEME_TOKENS, COLOR_TRANSFORMS, CX_KINDS, ChartExDimension, ChartExData, ChartExBinning, " *
                    "addSparklines, getSparklines, deleteSparklines"))
end

end # module Charts

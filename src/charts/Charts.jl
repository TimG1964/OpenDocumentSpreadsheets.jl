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
    ImageData, ChartObj, _tree!, _tree_edited!, _start_tag_end, _font_keys, CellRange, row_number, column_number, CellRef, _col_cm, _row_cm, _frame_edit!, _touch_cell!,
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
include("tree.jl")
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
    getChartTitleText, getChartTitleShapeProps, getChartTitleTextProps,
    getChartLegend, getLegendPos, getLegendOverlay, getLegendShapeProps, getLegendTextProps,
    getLegendEntryDeleted, getPlotAreaShapeProps, getChartSpaceShapeProps, getChartSpaceTextProps,
    # series, points, markers and labels
    getSeriesShapeProps, getSeriesLabelTextProps, getSeriesMarker, getSeriesGroup, getSeriesAxes, getGroupAxes,
    getGroupLabelTextProps, getSeriesDataPoints, getSeriesDataPoint, getDataPointShapeProps, getDataPointMarker,
    getSeriesDataLabels, getSeriesDataLabel, getDataLabelTextProps, getDataLabelShapeProps, getDataLabelText,
    getDataLabelPosition, getDataLabelOffset, getLabelFlag, getSeriesFill, getSeriesLine, getMarkerFill, getLabelTextProp,
    # trendlines, error bars and groups
    getSeriesTrendlines, getTrendlineShapeProps, getTrendlineLabelText, getTrendlineLabelTextProps,
    getTrendlineLabelShapeProps, getSeriesErrorBars, getErrorBarsShapeProps, getErrorBarsCustomRefs,
    getGroupUpDownBars, getUpBarShapeProps,
    getDownBarShapeProps, getGroupGapWidth, getGroupOverlap,
    # axes
    getChartAxes, getChartAxis, getAxisShapeProps, getAxisTextProps, getAxisTitle, getAxisTitleText,
    getAxisTitleTextProps, getAxisGridlines, getAxisPartner,
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
    setGroupLabelTextProp, setGroupGapWidth,
    setGroupOverlap, setAxisTitleText, setAxisTitleTextProp, setAxisTickLabelPos, setAxisScaling, setAxisMin, setAxisMax,
    setAxisOrientation, setAxisCrosses, setAxisCrossesAt, setAxisNumberFormatCode, setAxisNumberFormatLinked,
    setAxisMajorTickMark, setAxisMinorTickMark, setAxisGridlines, setAxisTextProp, setAxisLine, setAxisMajorUnit,
    setAxisMinorUnit, setMarker, setMarkerSymbol, setMarkerSize,
    setLabelText, setLabelTextProp, setLabelDeleted, setLabelFlag,
    # LibreOffice's own (D-076); a chart's kind read back (D-095)
    getChartKind, addSeriesTrendline, deleteSeriesTrendlines, setSeriesErrorBars, deleteSeriesErrorBars, setAxisLabelArrangement, setSeriesExplosion,
    setAxisLogBase, getSeriesExplosion, getAxisLabelArrangement, getLabelDeleted,
    # types users construct
    SchemeColor,
    # chartex charts and chart sheets (step 7)
    addChartEx, getChartSeriesCount, getSeriesLayout, getSeriesName, getSeriesNameRange, getChartDataBlocks, getSeriesData,
    getSeriesHidden, getSeriesAxisIds, getChartAxisIds, getLabelPosition, getSeriesBinning,
    setSeriesName,
    setSeriesBinning

# The functions for what LibreOffice can't store (D-084, D-086: they throw, or give `nothing`) are public,
# not exported (API consistency R8): code written for XLSX.jl that calls them gets their clear error.
@static if VERSION >= v"1.11"
    eval(Meta.parse("public setMarkerFill, setMarkerLineColor, setMarkerLineWidth, setSeriesLineCompound, setSeriesLineJoin, setSeriesLineMiterLimit, setSeriesSubtotals, setSeriesQuartileMethod, setSeriesParentLabelLayout, setSeriesAggregation, setSeriesLayoutFlag, getAxisTitleRef, getAxisTitleRange, getAutoTitleDeleted, getChartTitleRef, getChartTitleRange, getGroupDropLines, getGroupHiLowLines, getGroupSeriesLines, getSeriesSubtotals, getSeriesAggregation, getSeriesQuartileMethod, getSeriesParentLabelLayout, getSeriesLayoutFlag, " *
                    "AbstractChart, Chart, ChartEx, ChartRef, ChartRange, ChartRanges, ChartSeries, ChartGroup, " *
                    "ChartAxis, ChartDataPoint, ChartDataLabel, ChartMarker, ChartTrendline, ChartErrorBars, ChartUpDownBars, " *
                    "ColorSpec, DrawingColor, DrawingFill, DrawingLine, DrawingShapeProps, DrawingRunProps, DrawingParaProps, " *
                    "DrawingRun, DrawingParagraph, DrawingBodyProps, DrawingText, Effective, FormatSite, SCHEME_TOKENS, COLOR_TRANSFORMS, CX_KINDS, ChartExDimension, ChartExData, ChartExBinning, " *
                    "addSparklines, getSparklines, deleteSparklines"))
end

end # module Charts

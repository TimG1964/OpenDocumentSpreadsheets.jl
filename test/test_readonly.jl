# Every function that changes a file refuses a read-only one, before it changes anything (code
# review Phase 1 item 8, Phase 6): one call each, on a file opened without mode "rw".

using OpenDocumentSpreadsheets: ODSError

const _RO_C = OpenDocumentSpreadsheets.Charts

# A table of a read-only file.
_ro_table() = first(OpenDocumentSpreadsheets.tables(readods(joinpath(DATA, "dbranges", "lo-dbranges-own.fods"))))

# The calls: (name, call on the read-only file `xf` and its sheet `ws`; for charts, on a sheet `ws`,
# its chart `c` and a histogram `h`).
const _RO_SHEET_CALLS = [
    "addCellStyle" => (xf, ws) -> addCellStyle(xf, "Mine"; font = (bold = true,)),
    "addComment" => (xf, ws) -> addComment(ws, "A1", "x"),
    "addDataValidation" => (xf, ws) -> addDataValidation(ws, "A1:A3"; type = :whole, operator = :between, formula1 = "1", formula2 = "9"),
    "addDefinedName" => (xf, ws) -> addDefinedName(xf, "Nm", "S01-gaps.A1"),
    "addHyperlink" => (xf, ws) -> addHyperlink(ws, "A1"; url = "https://example.org"),
    "addImage" => (xf, ws) -> addImage(ws, "A1", IOBuffer(UInt8[0x89, 0x50, 0x4e, 0x47])),
    "addSparklines" => (xf, ws) -> addSparklines(ws, "F1", "A1:E1"),
    "addThreadedComment" => (xf, ws) -> addThreadedComment(ws, "A1", "x"; author = "A"),
    "addThreadedReply" => (xf, ws) -> addThreadedReply(ws, "A1", "x"; author = "A"),
    "addsheet!" => (xf, ws) -> addsheet!(xf, "New"),
    "addtable!" => (xf, ws) -> addtable!(ws, "A1:B3"),
    "autofitColumns" => (xf, ws) -> autofitColumns(ws),
    "copysheet!" => (xf, ws) -> copysheet!(ws),
    "deleteAllDefinedNames" => (xf, ws) -> deleteAllDefinedNames(xf),
    "deleteAutoFilter" => (xf, ws) -> deleteAutoFilter(ws),
    "deleteColumns" => (xf, ws) -> deleteColumns(ws, "B"),
    "deleteComment" => (xf, ws) -> deleteComment(ws, "A1"),
    "deleteConditionalFormats" => (xf, ws) -> OpenDocumentSpreadsheets.deleteConditionalFormats(ws, "A1:A5"),
    "deleteCustomProperty" => (xf, ws) -> deleteCustomProperty(xf, "p"),
    "deleteDataValidation" => (xf, ws) -> deleteDataValidation(ws, "A1"),
    "deleteDefinedName" => (xf, ws) -> deleteDefinedName(xf, "Nm"),
    "deleteHeaderFooter" => (xf, ws) -> deleteHeaderFooter(ws),
    "deleteHyperlink" => (xf, ws) -> deleteHyperlink(ws, "A1"),
    "deleteImage" => (xf, ws) -> deleteImage(ws, "A1"),
    "deleteMergedCells" => (xf, ws) -> deleteMergedCells(ws, "A1:B2"),
    "deletePanes" => (xf, ws) -> deletePanes(ws),
    "deletePrintArea" => (xf, ws) -> deletePrintArea(ws),
    "deletePrintTitles" => (xf, ws) -> deletePrintTitles(ws),
    "deleteRows" => (xf, ws) -> deleteRows(ws, 2),
    "deleteSparklines" => (xf, ws) -> deleteSparklines(ws, "F1"),
    "deleteTabColor" => (xf, ws) -> deleteTabColor(ws),
    "deleteThreadedComment" => (xf, ws) -> deleteThreadedComment(ws, "A1"),
    "deletesheet!" => (xf, ws) -> deletesheet!(xf, "S02-identical"),
    "deletetable!" => (xf, ws) -> deletetable!(_ro_table()),
    "deletetotals!" => (xf, ws) -> deletetotals!(_ro_table()),
    "freezePanes" => (xf, ws) -> freezePanes(ws; nrows = 1, ncols = 1),
    "groupColumns" => (xf, ws) -> groupColumns(ws, "B:C"),
    "groupRows" => (xf, ws) -> groupRows(ws, "2:3"),
    "insertColumns" => (xf, ws) -> insertColumns(ws, "B"),
    "insertRows" => (xf, ws) -> insertRows(ws, 2),
    "mergeCells" => (xf, ws) -> mergeCells(ws, "D1:E1"),
    "movesheet!" => (xf, ws) -> movesheet!(xf, "S02-identical"; before = 1),
    "protectSheet" => (xf, ws) -> protectSheet(ws),
    "protectWorkbook" => (xf, ws) -> protectWorkbook(xf),
    "renamesheet!" => (xf, ws) -> renamesheet!(ws, "Renamed"),
    "setAlignment" => (xf, ws) -> setAlignment(ws, "A1"; horizontal = "center"),
    "setAutoFilter" => (xf, ws) -> setAutoFilter(ws, "A1:C5"),
    "setBorder" => (xf, ws) -> setBorder(ws, "A1"; allsides = ["style" => "thin"]),
    "setCellProtection" => (xf, ws) -> setCellProtection(ws, "A1"; locked = false),
    "setCellStyle" => (xf, ws) -> setCellStyle(ws, "A1", "Default"),
    "setColoredDataBars" => (xf, ws) -> OpenDocumentSpreadsheets.setColoredDataBars(ws, "A1:A5"),
    "setColumnHidden" => (xf, ws) -> setColumnHidden(ws, "B"; hidden = true),
    "setColumnWidth" => (xf, ws) -> setColumnWidth(ws, "A1"; width = 20),
    "setConditionalFormat" => (xf, ws) -> setConditionalFormat(ws, "A1:A5", :cellIs; operator = "greaterThan", value = "1"),
    "setCustomProperty" => (xf, ws) -> setCustomProperty(xf, "p", "v"),
    "setDocumentProperties" => (xf, ws) -> setDocumentProperties(xf; title = "T"),
    "setFill" => (xf, ws) -> setFill(ws, "A1"; pattern = "solid", fgColor = "FFFF00"),
    "setFont" => (xf, ws) -> setFont(ws, "A1"; bold = true),
    "setFormat" => (xf, ws) -> setFormat(ws, "A1"; format = "0.00"),
    "setFormula" => (xf, ws) -> setFormula(ws, "A1"; val = "=1+1"),
    "setHeaderFooter" => (xf, ws) -> setHeaderFooter(ws; oddHeader = "&CTitle"),
    "setPageMargins" => (xf, ws) -> setPageMargins(ws; left = 1.0),
    "setPageSetup" => (xf, ws) -> setPageSetup(ws; orientation = :landscape),
    "setPrintArea" => (xf, ws) -> setPrintArea(ws, "A1:C5"),
    "setPrintOptions" => (xf, ws) -> setPrintOptions(ws; gridLines = true),
    "setPrintTitles" => (xf, ws) -> setPrintTitles(ws; rows = "1:1"),
    "setRowHeight" => (xf, ws) -> setRowHeight(ws, "A1"; height = 20),
    "setRowHidden" => (xf, ws) -> setRowHidden(ws, 2; hidden = true),
    "setSheetView" => (xf, ws) -> setSheetView(ws; zoomScale = 150),
    "setSheetVisibility" => (xf, ws) -> setSheetVisibility(ws, :hidden),
    "setTabColor" => (xf, ws) -> setTabColor(ws, "FF0000"),
    "setThreadedCommentResolved" => (xf, ws) -> setThreadedCommentResolved(ws, "A1", true),
    "setUniformAlignment" => (xf, ws) -> setUniformAlignment(ws, "A1:B2"; horizontal = "center"),
    "setUniformBorder" => (xf, ws) -> setUniformBorder(ws, "A1:B2"; allsides = ["style" => "thin"]),
    "setUniformFill" => (xf, ws) -> setUniformFill(ws, "A1:B2"; pattern = "solid", fgColor = "FFFF00"),
    "setUniformFont" => (xf, ws) -> setUniformFont(ws, "A1:B2"; bold = true),
    "setUniformFormat" => (xf, ws) -> setUniformFormat(ws, "A1:B2"; format = "0.00"),
    "setUniformStyle" => (xf, ws) -> setUniformStyle(ws, "A1:B2"),
    "setdata!" => (xf, ws) -> setdata!(ws, "A1", 1),
    "settotals!" => (xf, ws) -> settotals!(_ro_table(), 1 => :sum),
    "splitFreeze" => (xf, ws) -> splitFreeze(ws; nrows = 2, ncols = 2),
    "splitPanes" => (xf, ws) -> splitPanes(ws; nrows = 2, ncols = 2),
    "ungroupColumns" => (xf, ws) -> ungroupColumns(ws, "B:C"),
    "ungroupRows" => (xf, ws) -> ungroupRows(ws, "2:3"),
    "unprotectSheet" => (xf, ws) -> unprotectSheet(ws),
    "unprotectWorkbook" => (xf, ws) -> unprotectWorkbook(xf),
]

const _RO_CHART_CALLS = [
    "addChart" => (ws, c, h) -> _RO_C.addChart(ws, :column; anchor = "H2:O18"),
    "addChartEx" => (ws, c, h) -> _RO_C.addChartEx(ws, :histogram, "A1:A5"; anchor = "H2:O18"),
    "addSeries" => (ws, c, h) -> _RO_C.addSeries(c, "B2:B7"),
    "addSeriesTrendline" => (ws, c, h) -> _RO_C.addSeriesTrendline(c, 1, :linear),
    "deleteChart" => (ws, c, h) -> _RO_C.deleteChart(c),
    "deleteSeriesErrorBars" => (ws, c, h) -> _RO_C.deleteSeriesErrorBars(c, 1),
    "deleteSeriesTrendlines" => (ws, c, h) -> _RO_C.deleteSeriesTrendlines(c, 1),
    "makeCombo" => (ws, c, h) -> _RO_C.makeCombo(c),
    "setAxisCrosses" => (ws, c, h) -> _RO_C.setAxisCrosses(c, :x, :min),
    "setAxisCrossesAt" => (ws, c, h) -> _RO_C.setAxisCrossesAt(c, :x, 1),
    "setAxisGridlines" => (ws, c, h) -> _RO_C.setAxisGridlines(c, :y; minor = true),
    "setAxisLabelArrangement" => (ws, c, h) -> _RO_C.setAxisLabelArrangement(c, :x; stagger = :odd),
    "setAxisLine" => (ws, c, h) -> _RO_C.setAxisLine(c, :y; width = 1),
    "setAxisLogBase" => (ws, c, h) -> _RO_C.setAxisLogBase(c, :y, 10),
    "setAxisMajorTickMark" => (ws, c, h) -> _RO_C.setAxisMajorTickMark(c, :y, :cross),
    "setAxisMajorUnit" => (ws, c, h) -> _RO_C.setAxisMajorUnit(c, :y, 10),
    "setAxisMax" => (ws, c, h) -> _RO_C.setAxisMax(c, :y, 100),
    "setAxisMin" => (ws, c, h) -> _RO_C.setAxisMin(c, :y, 0),
    "setAxisMinorTickMark" => (ws, c, h) -> _RO_C.setAxisMinorTickMark(c, :y, :in),
    "setAxisMinorUnit" => (ws, c, h) -> _RO_C.setAxisMinorUnit(c, :y, 2),
    "setAxisNumberFormatCode" => (ws, c, h) -> _RO_C.setAxisNumberFormatCode(c, :y, "0.0"),
    "setAxisNumberFormatLinked" => (ws, c, h) -> _RO_C.setAxisNumberFormatLinked(c, :y, false),
    "setAxisOrientation" => (ws, c, h) -> _RO_C.setAxisOrientation(c, :x, :maxMin),
    "setAxisScaling" => (ws, c, h) -> _RO_C.setAxisScaling(c, :y; min = 0),
    "setAxisTextProp" => (ws, c, h) -> _RO_C.setAxisTextProp(c, :y, :bold, true),
    "setAxisTickLabelPos" => (ws, c, h) -> _RO_C.setAxisTickLabelPos(c, :y, :low),
    "setAxisTitleText" => (ws, c, h) -> _RO_C.setAxisTitleText(c, :x, "X"),
    "setAxisTitleTextProp" => (ws, c, h) -> _RO_C.setAxisTitleTextProp(c, :x, :bold, true),
    "setChartSpaceTextProp" => (ws, c, h) -> _RO_C.setChartSpaceTextProp(c, :size, 12),
    "setChartTitleText" => (ws, c, h) -> _RO_C.setChartTitleText(c, "T"),
    "setChartTitleTextProp" => (ws, c, h) -> _RO_C.setChartTitleTextProp(c, :bold, true),
    "setGroupGapWidth" => (ws, c, h) -> _RO_C.setGroupGapWidth(c, _RO_C.getChartGroups(c)[1], 50),
    "setGroupLabelTextProp" => (ws, c, h) -> _RO_C.setGroupLabelTextProp(c, _RO_C.getChartGroups(c)[1], :bold, true),
    "setGroupOverlap" => (ws, c, h) -> _RO_C.setGroupOverlap(c, _RO_C.getChartGroups(c)[1], 10),
    "setLabelDeleted" => (ws, c, h) -> _RO_C.setLabelDeleted(c, 1, 1, true),
    "setLabelFlag" => (ws, c, h) -> _RO_C.setLabelFlag(c, 1, :value, true),
    "setLabelText" => (ws, c, h) -> _RO_C.setLabelText(c, 1, 1, "x"),
    "setLabelTextProp" => (ws, c, h) -> _RO_C.setLabelTextProp(c, 1, :bold, true),
    "setLegendEntryDeleted" => (ws, c, h) -> _RO_C.setLegendEntryDeleted(c, [1], true),
    "setLegendOverlay" => (ws, c, h) -> _RO_C.setLegendOverlay(c, true),
    "setLegendPos" => (ws, c, h) -> _RO_C.setLegendPos(c, :b),
    "setLegendTextProp" => (ws, c, h) -> _RO_C.setLegendTextProp(c, :bold, true),
    "setMarker" => (ws, c, h) -> _RO_C.setMarker(c, 1; symbol = :diamond),
    "setMarkerSize" => (ws, c, h) -> _RO_C.setMarkerSize(c, 1, 9),
    "setMarkerSymbol" => (ws, c, h) -> _RO_C.setMarkerSymbol(c, 1, :diamond),
    "setPlotAreaLine" => (ws, c, h) -> _RO_C.setPlotAreaLine(c; width = 1),
    "setSeriesBinning" => (ws, c, h) -> _RO_C.setSeriesBinning(h, 1; binCount = 3),   # a ChartEx chart's
    "setSeriesErrorBars" => (ws, c, h) -> _RO_C.setSeriesErrorBars(c, 1; type = :percent, value = 10),
    "setSeriesExplosion" => (ws, c, h) -> _RO_C.setSeriesExplosion(c, 1, 10),
    "setSeriesFill" => (ws, c, h) -> _RO_C.setSeriesFill(c, 1, "FF0000"),
    "setSeriesLine" => (ws, c, h) -> _RO_C.setSeriesLine(c, 1; width = 2),
    "setSeriesLineCap" => (ws, c, h) -> _RO_C.setSeriesLineCap(c, 1, :sq),
    "setSeriesLineColor" => (ws, c, h) -> _RO_C.setSeriesLineColor(c, 1, "FF0000"),
    "setSeriesLineDash" => (ws, c, h) -> _RO_C.setSeriesLineDash(c, 1, :dash),
    "setSeriesLineWidth" => (ws, c, h) -> _RO_C.setSeriesLineWidth(c, 1, 2),
    "setSeriesName" => (ws, c, h) -> _RO_C.setSeriesName(h, 1, "S"),
]

# The exported functions that change a file, as their names say (the streaming writer's work on
# a stream, not a file).
const _MUTATOR_RX = r"^(set|add|delete|insert|merge|protect|unprotect|freeze|split|group|ungroup|rename|copy|move|autofit|make)"
# (`names` lists the `public` names too on Julia 1.11 and later: the exported ones only.)
_exported(m, n) = VERSION < v"1.11" || Base.isexported(m, n)
_mutators(m) = Set(string(n) for n in names(m) if _exported(m, n) && isdefined(m, n) && getfield(m, n) isa Function && occursin(_MUTATOR_RX, string(n)))

_readonly_error(e) = e isa ODSError && occursin("read-only", e.msg)

@testset "every change to a read-only file is refused (Phase 6)" begin
    # every exported one is called (and some that are only `public`)
    @test setdiff(_mutators(OpenDocumentSpreadsheets), first.(_RO_SHEET_CALLS)) == Set{String}()
    @test setdiff(_mutators(_RO_C), first.(_RO_CHART_CALLS)) == Set{String}()
    xf = readods(joinpath(DATA, "lo-scenarios.ods")); ws = xf["S01-gaps"]
    for (name, call) in _RO_SHEET_CALLS
        e = try call(xf, ws); nothing catch err; err end
        @test (name, _readonly_error(e)) == (name, true)
    end
    cx = readods(joinpath(DATA, "charts", "lo-charts-own.ods"))
    c = first(c for c in _RO_C.getCharts(cx) if _RO_C.getChartType(c) === :lineChart)
    cws = cx[1]
    hx = newods("D"); hx["D"]["A1:A5"] = reshape(Any[1, 2, 3, 4, 5], 5, 1)
    _RO_C.addChartEx(hx["D"], :histogram, "A1:A5"; anchor = "C2:H12")
    hx = readods(writeods(joinpath(mktempdir(), "h.ods"), hx))
    h = only(_RO_C.getCharts(hx))
    for (name, call) in _RO_CHART_CALLS
        e = try call(cws, c, h); nothing catch err; err end
        @test (name, _readonly_error(e)) == (name, true)
    end
    # nothing was changed on the way: no operation, no sheet marked for writing, no chart taken
    for f in (xf, cx, hx)
        @test isempty(f.ops) && isempty(f.chartobjs) && !any(s -> s.touched, f.sheets)
    end
end

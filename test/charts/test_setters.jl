# Formatting setters and LibreOffice's own options (phase 8 step 6, D-085, D-086): each setter read back by
# its getter, the refusals, theme colours as LibreOffice's import resolves them (experiment 039 part B2),
# and LibreOffice keeping what is written (a round trip through LibreOffice, read with the getters).
# Uses `_ch`, `OC` and `_chart_data_sheet` from the files before.

# A line chart with every setter applied (the same chart for the in-process and LibreOffice checks).
function _setters_chart()
    xf, ws = _chart_data_sheet()
    c = OC.addChart(ws, :lineMarkers; anchor = "H2:O18", title = "T", xtitle = "X", ytitle = "Y")
    OC.addSeries(c, "B2:B7"; categories = "A2:A7", name_ref = "B1")
    OC.addSeries(c, "C2:C7"; name_ref = "C1")
    OC.setSeriesLine(c, 1; color = OC.SchemeColor(:accent2; lumMod = 75), width = 2.5, dash = :sysDash, cap = :rnd)
    OC.setSeriesFill(c, 2, OC.SchemeColor(:accent3; lumMod = 60, lumOff = 40))
    OC.setMarker(c, 2; symbol = :diamond, size = 9)
    OC.setMarker(c, 2; point = 3, symbol = :x)
    OC.setLabelFlag(c, 1, :value, true); OC.setLabelFlag(c, 1, :categoryName, true)
    OC.setLabelText(c, 1, 4, "peak")
    OC.setLabelTextProp(c, 1, :bold, true)
    OC.setChartTitleTextProp(c, :size, 16); OC.setChartTitleTextProp(c, :fill, :accent1)
    OC.setChartTitleText(c, "New title")
    OC.setAxisTitleText(c, :x, "Months")
    OC.setAxisTitleTextProp(c, :y, :italic, true)
    OC.setLegendPos(c, :b; overlay = false, expansion = :wide)
    OC.setLegendEntryDeleted(c, [2], true)
    OC.setPlotAreaLine(c; color = "333333", width = 1)
    OC.setAxisMin(c, :y, 0); OC.setAxisMax(c, :y, 60); OC.setAxisMajorUnit(c, :y, 10); OC.setAxisMinorUnit(c, :y, 2)
    OC.setAxisMajorTickMark(c, :y, :cross); OC.setAxisMinorTickMark(c, :y, :in); OC.setAxisGridlines(c, :y; minor = true)
    OC.setAxisNumberFormatCode(c, :y, "0.0")
    OC.setAxisCrosses(c, :x, :min); OC.setAxisOrientation(c, :x, :maxMin); OC.setAxisTickLabelPos(c, :y, :low)
    OC.setAxisLine(c, :y; color = "00FF00", width = 1.5, dash = :dash)
    OC.addTrendline(c, 1, :poly; order = 2, name = "Fit", displayEquation = true)
    OC.setErrorBars(c, 2; type = :percent, value = 10)
    OC.setAxisLabelArrangement(c, :x; stagger = :odd)
    return xf, c
end

# The properties the setters set, as the getters read them (compared between our file and LibreOffice's).
_n(x) = replace(repr(x), "OpenDocumentSpreadsheets.Charts." => "", r"Dict\{String, String\}\(.*?\)\)" => "", r"Element <[^>]*>( \(\d+ child(ren)?\))?" => "")
_label_text(c, i, p) = (d = OC.getSeriesDataLabel(c, i, p); d === nothing ? nothing : (t = OC.getDataLabelText(c, d); t === nothing ? nothing : join(r.text for q in t.paragraphs for r in q.runs if r.text !== nothing)))
const _SETTER_PROBES = [
    "line1" => c -> OC.getSeriesLine(c, 1).value,
    "fill1" => c -> OC.getSeriesFill(c, 1).value,
    "fill2" => c -> OC.getSeriesFill(c, 2).value,
    "marker2" => c -> (m = OC.getSeriesMarker(c, 2); (m.symbol, m.size)),
    "point2.3" => c -> (m = OC.getDataPointMarker(c, only(filter(p -> p.idx == 2, OC.getSeriesDataPoints(c, 2)))); m === nothing ? nothing : m.symbol),
    "labelflags" => c -> (OC.getLabelFlag(c, 1, :value), OC.getLabelFlag(c, 1, :categoryName), OC.getLabelFlag(c, 1, :seriesName)),
    "labeltext" => c -> _label_text(c, 1, 4),
    "labelbold" => c -> OC.getLabelTextProp(c, 1, :bold).value,
    "title" => c -> OC.getChartTitle(c),
    "titlerun" => c -> (r = OC.getChartTitleTextProps(c).paragraphs[1].props.defprops; (r.size, r.fill)),
    "xtitle" => c -> OC.getAxisTitle(c, :x),
    "ytitleitalic" => c -> OC.getAxisTitleTextProps(c, :y).paragraphs[1].props.defprops.italic,
    "legend" => c -> (OC.getLegendPos(c), OC.getLegendOverlay(c), OC.getLegendEntryDeleted(c, 2)),
    "wall" => c -> (l = OC.getPlotAreaShapeProps(c).line; (l.width, l.fill.fgcolor.rgb)),
    "yscale" => c -> (OC.getAxisMin(c, :y), OC.getAxisMax(c, :y), OC.getAxisMajorUnit(c, :y), OC.getAxisMinorUnit(c, :y)),
    "yticks" => c -> (OC.getAxisMajorTickMark(c, :y), OC.getAxisMinorTickMark(c, :y), OC.getAxisTickLabelPos(c, :y)),
    "ygrid" => c -> OC.getAxisGridlines(c, :y),
    "yformat" => c -> (OC.getAxisNumberFormatCode(c, :y), OC.getAxisNumberFormatLinked(c, :y)),
    "xcross" => c -> (OC.getAxisCrosses(c, :x), OC.getAxisOrientation(c, :x)),
    "yline" => c -> OC.getAxisShapeProps(c, :y).line,
    "trend" => c -> [(t.kind, t.name, t.order, t.disp_eq) for t in OC.getSeriesTrendlines(c, 1)],
    "errbars" => c -> [(e.direction, e.bar_type, e.value_type, e.value) for e in OC.getSeriesErrorBars(c, 2)],
]

@testset "setters, read back" begin
    xf, c = _setters_chart()
    # a line series has one colour: its fill follows its line (LibreOffice's series colour)
    l1 = OC.getSeriesLine(c, 1).value
    @test l1.fill.fgcolor.rgb == "024F7A" && OC.getSeriesFill(c, 1).value.fgcolor.rgb == "024F7A"
    @test l1.width ≈ 2.49 && l1.dash == "odsfDashSysDash" && l1.cap == "rnd"
    @test OC.getSeriesFill(c, 2).value.fgcolor.rgb == OC.getSeriesLine(c, 2).value.fill.fgcolor.rgb == "FB7E34"
    @test (OC.getSeriesMarker(c, 2).symbol, OC.getSeriesMarker(c, 2).size) == (:diamond, 9)
    @test OC.getDataPointMarker(c, only(filter(p -> p.idx == 2, OC.getSeriesDataPoints(c, 2)))).symbol === :x
    @test OC.getLabelFlag(c, 1, :value) && OC.getLabelFlag(c, 1, :categoryName) && !OC.getLabelFlag(c, 1, :percent)
    @test _label_text(c, 1, 4) == "peak"
    @test OC.getChartTitle(c) == "New title" && OC.getAxisTitle(c, :x) == "Months" && OC.getAxisTitle(c, :y) == "Y"
    @test OC.getChartTitleTextProps(c).paragraphs[1].props.defprops.size == 16
    @test OC.getLegendPos(c) === :b && OC.getLegendOverlay(c) === false && OC.getLegendEntryDeleted(c, 2) === true
    @test (OC.getAxisMin(c, :y), OC.getAxisMax(c, :y), OC.getAxisMajorUnit(c, :y), OC.getAxisMinorUnit(c, :y)) == (0, 60, 10, 2)
    @test OC.getAxisMajorTickMark(c, :y) === :cross && OC.getAxisMinorTickMark(c, :y) === :in
    @test OC.getAxisNumberFormatCode(c, :y) == "0.0" && OC.getAxisNumberFormatLinked(c, :y) === false
    @test OC.getAxisCrosses(c, :x) === :min && OC.getAxisOrientation(c, :x) === :maxMin
    t = only(OC.getSeriesTrendlines(c, 1)); @test (t.kind, t.name, t.order, t.disp_eq) == (:poly, "Fit", 2, true)
    e = only(OC.getSeriesErrorBars(c, 2)); @test (e.value_type, e.value) == ("percentage", 10.0)
    # the x axis: its title before its categories (ODF's order, which LibreOffice needs)
    text = OC._object_text(OC._frame(c))
    @test occursin(r"<chart:axis [^>]*primary-x[^>]*><chart:title\b.*?</chart:title><chart:categories"s, text)
    # :inherit removes; deletes
    OC.setAxisMin(c, :y, :inherit); @test OC.getAxisMin(c, :y) === nothing
    OC.deleteTrendlines(c, 1); OC.deleteErrorBars(c, 2)
    @test isempty(OC.getSeriesTrendlines(c, 1)) && isempty(OC.getSeriesErrorBars(c, 2))
    OC.setLegendPos(c, :inherit); @test OC.getLegendPos(c) === :r
    # the dash's definition is in the object's styles.xml, and saved
    @test occursin("draw:name=\"odsfDashSysDash\"", xf.chartobjs[c.name].styles)
    mktempdir() do dir
        p = joinpath(dir, "s.ods"); f = joinpath(dir, "s.fods")
        OpenDocumentSpreadsheets.writeods(p, xf); OpenDocumentSpreadsheets.writeods(f, xf)
        z = ZipArchives.ZipReader(read(p))
        @test occursin("odsfDashSysDash", String(ZipArchives.zip_readentry(z, c.name * "/styles.xml")))
        @test occursin(r"<office:styles><draw:stroke-dash draw:name=\"odsfDashSysDash\""s, read(f, String))
        for path in (p, f)
            b = only(getCharts(readods(path)))
            @test OC.getSeriesLine(b, 1).value.dash == "odsfDashSysDash"
            @test OC.getAxisMajorUnit(b, :y) == 10
        end
    end
end

@testset "theme colours as LibreOffice resolves them" begin
    # experiment 039 part B2: LibreOffice's import of XLSX.jl's SchemeColors against the xlsx theme
    for (hex, tr, want) in [("#4472c4", [:lumMod => 75.0], "#2f5597"), ("#4472c4", [:lumMod => 60.0, :lumOff => 40.0], "#8faadc"),
                            ("#4472c4", [:tint => 40.0], "#cfd5e9"), ("#ed7d31", [:tint => 75.0], "#f1aa8f"),
                            ("#4472c4", [:shade => 50.0], "#325490"), ("#ed7d31", [:shade => 75.0], "#d16e2b"),
                            ("#4472c4", [:satMod => 50.0], "#647ba4"), ("#ed7d31", [:satMod => 150.0], "#ff7a1f"),
                            ("#000000", [:lumMod => 50.0, :lumOff => 50.0], "#808080")]
        @test (tr, OC._apply_transforms(hex, tr)) == (tr, want)
    end
    @test OC.SchemeColor(:lt1) == OC.SchemeColor(:bg1) && hash(OC.SchemeColor(:dk1)) == hash(OC.SchemeColor(:tx1))
    @test_throws OpenDocumentSpreadsheets.ODSError OC.SchemeColor(:accent9)
    xf, ws = _chart_data_sheet()
    c = OC.addChart(ws, :column; anchor = "H2:O18")
    OC.addSeries(c, "B2:B7"; categories = "A2:A7", color = OC.SchemeColor(:accent1; lumMod = 75))
    OC.setSeriesFill(c, 1, OC.SchemeColor(:accent2; alpha = 40))
    f = OC.getSeriesFill(c, 1).value
    @test f.fgcolor.kind === :srgb && f.fgcolor.rgb == "0369A3"             # a new document's theme, resolved
    @test occursin("draw:opacity=\"40%\"", OC._object_text(OC._frame(c)))
    @test !occursin("complex-color", OC._object_text(OC._frame(c)))          # LibreOffice keeps no theme reference
    @test_throws OpenDocumentSpreadsheets.ODSError OC.setChartTitleTextProp(c, :fill, OC.SchemeColor(:accent1; alpha = 50))
end

@testset "setters' refusals (D-084, D-086)" begin
    E = OpenDocumentSpreadsheets.ODSError
    xf, c = _setters_chart()
    @test_throws E OC.setSeriesLineCompound(c, 1, :dbl)
    @test_throws E OC.setSeriesLineJoin(c, 1, :round)
    @test_throws E OC.setSeriesLineMiterLimit(c, 1, 8)
    @test_throws E OC.setMarkerFill(c, 2, "00FF00")
    @test_throws E OC.setMarkerLineColor(c, 2, "00FF00")
    @test_throws E OC.setMarkerLineWidth(c, 2, 1)
    @test_throws E OC.setLabelFlag(c, 1, :bubbleSize, true)
    @test_throws E OC.setAxisMinorUnit(c, :y, 3)                    # 3 doesn't divide 10
    @test_throws E OC.setChartTitleTextProp(c, :caps, :all)
    @test_throws E OC.setChartTitleTextProp(c, :kern, 12)
    @test_throws E OC.setChartTitleTextProp(c, :line, "FF0000")
    @test_throws E OC.setChartTitleText(c, OpenDocumentSpreadsheets.CellRef("A1"))
    @test_throws E OC.setSeriesFill(c, 1, :none)                    # a line series' one colour
    @test_throws E OC.setSeriesFill(c, 1, "FF0000"; gradient = "00FF00")
    @test_throws E OC.setSeriesExplosion(c, 1, 10)                  # not a pie
    @test_throws E OC.setMarkerSize(c, 1, 100)
    @test_throws E OC.setSeriesLineDash(c, 1, :wiggly)
    @test_throws E OC.setLegendPos(c, :tr; expansion = :wide)
    xf2, ws2 = _chart_data_sheet()
    col = OC.addChart(ws2, :column; anchor = "H2:O18"); OC.addSeries(col, "B2:B7"; categories = "A2:A7")
    @test_throws E OC.setMarkerSymbol(col, 1, :circle)              # not a line series
    @test_throws E OC.setAxisMinorUnit(col, :y, 1)                  # no major unit
    @test_throws E OC.setAxisMajorUnit(col, :x, 1)                  # a category axis
    @test_throws E OC.addTrendline(col, 1, :poly)                   # no order
    @test_throws E OC.setErrorBars(col, 1; type = :fixed)           # no value
    # a file read for reading only can't be changed
    flat = readods(_ch("lo-charts-flat-cf.fods"))
    @test_throws E OC.setChartTitleText(first(getCharts(flat)), "x")
end

@testset "LibreOffice's own options (D-076)" begin
    xf, ws = _chart_data_sheet()
    s = OC.addChart(ws, :stockVolumeOHLC; anchor = "H2:O18")
    for col in ("E", "B", "D", "C", "B"); OC.addSeries(s, "$(col)2:$(col)7"; categories = "A2:A7"); end
    @test_throws OpenDocumentSpreadsheets.ODSError OC.addSeries(s, "B2:B7")      # five series: volume, open, low, high, close
    text = OC._object_text(OC._frame(s))
    @test occursin("chart:japanese-candle-stick=\"true\"", text) && occursin("chart:name=\"secondary-y\"", text)
    @test occursin(r"<chart:series [^>]*chart:class=\"chart:bar\"", text)
    @test occursin(r"</chart:series><chart:stock-gain-marker [^>]*/><chart:stock-loss-marker [^>]*/><chart:stock-range-line [^>]*/><chart:wall"s, text)
    @test OC.getChartTypes(s) == [:barChart, :stockChart]
    w = OC.addChart(ws, :line; anchor = "H20:O36", data = "A1:D7", seriesIn = :rows, interpolation = :stepStart,
                    emptyCells = :zero, includeHidden = false, dataTable = true)
    @test [x.values.ref for x in getChartSeries(w)] == ["Data.B2:D2", "Data.B3:D3", "Data.B4:D4", "Data.B5:D5", "Data.B6:D6", "Data.B7:D7"]
    @test [x.name for x in getChartSeries(w)] == ["Jan", "Feb", "Mar", "Apr", "May", "Jun"]
    t = OC._object_text(OC._frame(w))
    @test occursin("chart:series-source=\"rows\"", t) && occursin("chart:interpolation=\"step-start\"", t)
    @test occursin("chart:treat-empty-cells=\"use-zero\"", t) && occursin("<loext:data-table/>", t)
    @test occursin("table:cell-range-address=\"Data.A1:Data.D7\" chart:data-source-has-labels=\"both\"", t)
    p = OC.addChart(ws, :pie; anchor = "H40:O56", startAngle = 45); OC.addSeries(p, "B2:B7"; categories = "A2:A7")
    OC.setSeriesExplosion(p, 1, 15; point = 2)
    @test occursin("chart:angle-offset=\"45\"", OC._object_text(OC._frame(p)))
    @test [d.idx for d in OC.getSeriesDataPoints(p, 1)] == collect(0:5)
    g = OC.addChart(ws, :column; anchor = "H60:O76"); OC.addSeries(g, "B2:B7"); OC.addSeries(g, "C2:C7")
    OC.setSeriesFill(g, 1, "FF0000"; gradient = "0000FF", gradientAngle = 30)
    OC.setSeriesFill(g, 2, "00AA00"; hatch = :double, hatchAngle = 45)
    @test OC.getSeriesFill(g, 1).value.kind === :gradient && OC.getSeriesFill(g, 2).value.kind === :pattern
    for (pos, x, y) in ((:tr, true, false), (:tl, false, false), (:bl, false, true), (:br, true, true))
        OC.setLegendPos(g, pos)
        @test OC.getLegendPos(g) === pos
    end
    E = OpenDocumentSpreadsheets.ODSError
    @test_throws E OC.addChart(ws, :column; anchor = "A1:B2", interpolation = :smooth)
    @test_throws E OC.addChart(ws, :line; anchor = "A1:B2", startAngle = 10)
    @test_throws E OC.addChart(ws, :column; anchor = "A1:B2", sortByX = true)
    @test_throws E OC.addChart(ws, :stock; anchor = "A1:B2", threeD = true)
    @test_throws E OC.addChart(ws, :bubble; anchor = "A1:B2", data = "A1:D7")
end

@testset "a file's chart, edited" begin
    xf = openods(_ch("lo-charts-ops-base.ods"); mode = "rw")
    c = first(getCharts(xf))
    OC.setChartTitleText(c, "Edited")
    OC.setSeriesLineDash(c, 1, :dash)
    mktempdir() do dir
        p = joinpath(dir, "e.ods")
        OpenDocumentSpreadsheets.writeods(p, xf)
        b = first(getCharts(readods(p)))
        @test OC.getChartTitle(b) == "Edited"
        @test OC.getSeriesLine(b, 1).value.dash == "odsfDashDash"
        frames, orphans = chart_frames(p)
        @test isempty(orphans) && all(x -> x.parts && x.manifest, frames)
    end
end

@testset "LibreOffice keeps what the setters write" begin
    if isfile(SOFFICE) && lo_major(SOFFICE) >= LO_FIXTURE_MAJOR
        xf, c = _setters_chart()
        # LibreOffice's options too, on a second sheet's charts
        ws = xf["Data"]
        s = OC.addChart(ws, :stockVolumeOHLC; anchor = "H40:O56")
        for col in ("E", "B", "D", "C", "B"); OC.addSeries(s, "$(col)2:$(col)7"; categories = "A2:A7"); end
        w = OC.addChart(ws, :line; anchor = "H60:O76", data = "A1:D7", seriesIn = :rows, interpolation = :bspline,
                        emptyCells = :zero, dataTable = true)
        OC.setLegendPos(w, :bl)
        g = OC.addChart(ws, :column; anchor = "H80:O96"); OC.addSeries(g, "B2:B7"); OC.addSeries(g, "C2:C7")
        OC.setSeriesFill(g, 1, "FF0000"; gradient = "0000FF", gradientAngle = 30)
        OC.setSeriesFill(g, 2, "00AA00"; hatch = :double, hatchAngle = 45)
        mine = getCharts(xf)
        mktempdir() do dir
            p = joinpath(dir, "s.ods"); f = joinpath(dir, "sf.fods")
            OpenDocumentSpreadsheets.writeods(p, xf); OpenDocumentSpreadsheets.writeods(f, xf)
            out = joinpath(dir, "lo")
            run(pipeline(`$SOFFICE -env:UserInstallation=$(lo_profile_url(joinpath(dir, "profile"))) --headless --norestore --convert-to ods --outdir $out $p $f`;
                         stdout = devnull, stderr = devnull))
            for path in (joinpath(out, "s.ods"), joinpath(out, "sf.ods"))
                back = getCharts(readods(path))
                @test length(back) == 4
                lo = back[1]
                for (k, g) in _SETTER_PROBES
                    @test (k, _n(g(c))) == (k, _n(g(lo)))
                end
                plot(x) = (d = OC._doc(x); OC._style(d, OC._plot_area(d)))
                @test getChartTypes(back[2]) == [:barChart, :stockChart]
                @test get(plot(back[2]), "chart:japanese-candle-stick", "") == "true"
                @test [x.values.ref for x in getChartSeries(back[2])] == [x.values.ref for x in getChartSeries(mine[2])]
                @test get(plot(back[3]), "chart:interpolation", "") == "b-spline" && get(plot(back[3]), "chart:series-source", "") == "rows"
                @test get(plot(back[3]), "chart:treat-empty-cells", "") == "use-zero"
                @test OC._first(OC._doc(back[3]).chart, "loext:data-table") !== nothing
                @test OC.getLegendPos(back[3]) === :bl
                @test [OC.getSeriesFill(back[4], i).value.kind for i in 1:2] == [:gradient, :pattern]
            end
        end
    else
        @test_skip false
    end
end

@testset "a flat file's own charts, changed and deleted (phase 8 step 9)" begin
    xf = openods(_ch("lo-charts-flat-cf.fods"); mode = "rw")
    cs = getCharts(xf)
    n = length(cs)
    a, b = cs[1], cs[2]
    OC.setChartTitleText(a, "Edited flat")
    OC.setSeriesLineDash(a, 1, :dash)
    OC.deleteChart(b)
    @test length(getCharts(xf)) == n - 1 && OC.getChartTitle(getChart(xf, a.name)) == "Edited flat"
    @test getCharts(xf)[1].name == a.name
    insertRows(xf[a.sheet], 1)                                    # an operation after the change
    mktempdir() do dir
        p = joinpath(dir, "f.fods")
        writeods(p, xf)
        back = getCharts(readods(p))
        @test length(back) == n - 1
        @test OC.getChartTitle(back[1]) == "Edited flat" && OC.getSeriesLine(back[1], 1).value.dash == "odsfDashDash"
        @test n == 2
        t = read(p, String)
        # the flat document itself, and its one chart left
        @test count("<office:document ", t) == n && occursin("draw:name=\"odsfDashDash\"", t)
        if isfile(SOFFICE) && lo_major(SOFFICE) >= LO_FIXTURE_MAJOR
            out = joinpath(dir, "lo")
            run(pipeline(`$SOFFICE -env:UserInstallation=$(lo_profile_url(joinpath(dir, "profile"))) --headless --norestore --convert-to ods --outdir $out $p`;
                         stdout = devnull, stderr = devnull))
            lo = getCharts(readods(joinpath(out, "f.ods")))
            @test length(lo) == n - 1
            @test OC.getChartTitle(lo[1]) == "Edited flat" && OC.getSeriesLine(lo[1], 1).value.dash == "odsfDashDash"
        else
            @test_skip false
        end
    end
end

@testset "setter fixes (code review, Phase 1 item 9)" begin
    E = OpenDocumentSpreadsheets.ODSError
    xf, ws = _chart_data_sheet()
    sc = OC.addChart(ws, :scatter; anchor = "H2:O18")
    OC.addSeries(sc, "B2:B7"; categories = "F2:F7", name_ref = "B1")
    # x and y error bars together: setting one direction kept the other (it deleted both)
    OC.setErrorBars(sc, 1; type = :percent, value = 10, direction = :y)
    OC.setErrorBars(sc, 1; type = :fixed, value = 2, direction = :x)
    @test sort([e.direction for e in OC.getSeriesErrorBars(sc, 1)]) == ["x", "y"]
    OC.setErrorBars(sc, 1; type = :fixed, value = 3, direction = :x)          # replaces the x ones only
    @test length(OC.getSeriesErrorBars(sc, 1)) == 2
    OC.deleteErrorBars(sc, 1)
    @test isempty(OC.getSeriesErrorBars(sc, 1))
    # an indicator with children is deleted too
    o = OC._editable(sc)
    OC.setErrorBars(sc, 1; type = :percent, value = 10)
    o.text = replace(o.text, r"(<chart:error-indicator\b[^>]*)/>" => s"\1><text:p/></chart:error-indicator>")
    OC.deleteErrorBars(sc, 1)
    @test !occursin("chart:error-indicator", o.text)

    c = OC.addChart(ws, :line; anchor = "H20:O36")
    OC.addSeries(c, "B2:B7"; categories = "A2:A7")
    # removing the minimum while setting a maximum below it: no longer checked against the old minimum
    OC.setAxisMin(c, :y, 50)
    OC.setAxisScaling(c, :y; min = :inherit, max = 20)
    @test OC.getAxisMin(c, :y) === nothing && OC.getAxisMax(c, :y) == 20
    @test_throws E OC.setAxisScaling(c, :y; min = 30)                          # still checked against the kept maximum
    # each format call added a data style; the replaced one stayed
    nstyles(c) = length(collect(eachmatch(r"<number:[a-z-]+-style style:name=\"N1\d\d", OC._editable(c).text)))
    for code in ("0.0", "0.00", "0.0", "0.0", "0%")
        OC.setAxisNumberFormatCode(c, :y, code)
    end
    @test nstyles(c) == 1 && OC.getAxisNumberFormatCode(c, :y) == "0%"
    # unchecked values
    @test_throws E OC.SchemeColor(:accent1; alpha = 150)                     # was written as transparency -50
    @test_throws E OC.SchemeColor(:accent1; lumMod = NaN)
    @test_throws E OC.setLegendEntryDeleted(c, [1], :yes)                    # showed the entries
end

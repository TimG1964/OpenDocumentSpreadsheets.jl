# `addChartEx` and chart sheets (phase 8 step 7, D-085, D-086): LibreOffice's histogram, the six kinds it
# lacks as errors, chart sheets as ordinary sheets holding a page-anchored chart, and LibreOffice reading
# them. Uses `_ch`, `OC`, `chart_frames` and `_chart_data_sheet` from the files before.

@testset "addChartEx: LibreOffice's histogram" begin
    xf, ws = _chart_data_sheet()
    h = OC.addChartEx(ws, :histogram, "B2:B7"; anchor = "H2:O18", name_ref = "B1", title = "Spread")
    @test h isa OC.ChartEx && OC.getChartSchema(h) === :cx
    @test OC.getChartTypes(h) == [:histogram] && OC.getChartTitle(h) == "Spread"
    @test OC.getChartSeriesCount(h) == 1 && OC.getSeriesLayout(h, 1) === :clusteredColumn
    @test OC.getSeriesName(h, 1) == "North" && string(OC.getSeriesNameRange(h, 1)) == "Data.B1"
    d = OC.getSeriesData(h, 1)
    @test d.id == 0 && only(d.dimensions).type === :val && only(d.dimensions).formula == "Data.B2:B7"
    @test OC.getSeriesAxisIds(h, 1) == [0, 1] && OC.getChartAxisIds(h) == [0, 1] && OC.getSeriesHidden(h, 1) === nothing
    b = OC.getSeriesBinning(h, 1)
    @test (b.binSize, b.binCount, b.intervalClosed) == (:auto, :auto, nothing)
    OC.setSeriesBinning(h, 1; binSize = 5)
    @test OC.getSeriesBinning(h, 1).binSize == 5.0 && OC.getSeriesBinning(h, 1).binCount === nothing
    OC.setSeriesBinning(h, 1; binCount = 4)
    @test OC.getSeriesBinning(h, 1).binCount == 4
    OC.setSeriesName(h, 1, "Typed")
    @test OC.getSeriesName(h, 1) == "Typed" && OC.getSeriesNameRange(h, 1) === nothing
    text = OC._object_text(OC._frame(h))
    @test occursin("loext:class=\"loext:histogram\"", text) && occursin(r"<chart:series [^>]*chart:class=\"chart:histogram\"", text)
    @test getCharts(xf)[1] isa OC.ChartEx
    E = OpenDocumentSpreadsheets.ODSError
    for k in (:waterfall, :funnel, :treemap, :sunburst, :pareto, :boxWhisker)
        @test_throws E OC.addChartEx(ws, k, "B2:B7"; anchor = "A20:B30")
    end
    @test_throws E OC.addChartEx(ws, :spiral, "B2:B7"; anchor = "A20:B30")
    @test_throws E OC.addChartEx(ws, :histogram, "B2:B7"; anchor = "A20:B30", categories = "A2:A7")
    @test_throws E OC.addSeries(h, "C2:C7")
    @test_throws E OC.setSeriesBinning(h, 1; intervalClosed = :l)
    @test_throws E OC.setSeriesBinning(h, 1; underflow = 2)
    @test_throws E OC.setSeriesBinning(h, 1; binSize = 2, binCount = 3)
    @test_throws E OC.setSeriesSubtotals(h, 1, [1])
    @test_throws E OC.setSeriesAggregation(h, 1, true)
    @test_throws E OC.getSeriesName(h, 1; pareto = true)
    @test length(getCharts(xf)) == 1                           # the refused calls added nothing
end

@testset "addChart(…, :histogram) and addSeries (D-092)" begin
    E = OpenDocumentSpreadsheets.ODSError
    # the same object as addChartEx's, on a sheet and on a chart sheet
    xf1, ws1 = _chart_data_sheet(); xf2, ws2 = _chart_data_sheet()
    a = OC.addChartEx(ws1, :histogram, "B2:B7"; anchor = "H2:O18", name_ref = "B1", title = "Spread")
    h = OC.addSeries(OC.addChart(ws2, :histogram; anchor = "H2:O18", title = "Spread"), "B2:B7"; name_ref = "B1")
    @test h isa OC.ChartEx && OC.getChartTypes(h) == [:histogram] && OC.getSeriesName(h, 1) == "North"
    @test OC._object_text(OC._frame(a)) == OC._object_text(OC._frame(h))
    s1 = OC.addChartEx(xf1, :histogram, "Data.C2:C7"; sheetname = "Spread", name = "South")
    s2 = OC.addSeries(OC.addChart(xf2, :histogram; sheetname = "Spread"), "Data.C2:C7"; name = "South")
    @test s2 isa OC.ChartEx && s2.sheet == "Spread" && OC._object_text(OC._frame(s1)) == OC._object_text(OC._frame(s2))
    # what a histogram doesn't take
    @test_throws E OC.addSeries(h, "C2:C7")                                    # one series
    n = length(getCharts(xf2))
    for kw in ((threeD = true,), (dataTable = true,), (emptyCells = :gap,), (includeHidden = true,), (data = "B1:B7",),
               (interpolation = :smooth,))
        @test_throws E OC.addChart(ws2, :histogram; anchor = "A20:B30", kw...)
    end
    @test length(getCharts(xf2)) == n                                          # the refused calls added nothing
    e = OC.addChart(ws2, :histogram; anchor = "A20:B30")
    @test_throws E OC.addSeries(e, "B2:B7"; categories = "A2:A7")
    @test_throws E OC.addSeries(e, "B2:B7"; color = "red")
    @test_throws E OC.addSeries(e, "B2:B7"; name = "x", name_ref = "B1")
    @test !occursin("<chart:series", OC._object_text(OC._frame(e)))          # still without a series
    # its titles, as LibreOffice keeps them
    xf, ws = _chart_data_sheet()
    t = OC.addChart(ws, :histogram; anchor = "H2:O18", title = "Spread", subtitle = "Six months", xtitle = "Sales",
                    ytitle = "Months")
    OC.addSeries(t, "B2:B7"; name_ref = "B1")
    # each title's text, without the spans LibreOffice puts in it
    titles(text) = [replace(m.captures[2], r"<[^>]*>" => "") for m in eachmatch(r"<chart:(title|subtitle)\b[^>]*>(.*?)</chart:\1>"s, text)]
    @test titles(OC._object_text(OC._frame(t))) == ["Spread", "Six months", "Sales", "Months"]
    if isfile(SOFFICE) && lo_version(SOFFICE) >= LO_FIXTURE_VERSION
        mktempdir() do dir
            p = joinpath(dir, "h.ods"); OpenDocumentSpreadsheets.writeods(p, xf)
            out = joinpath(dir, "lo")
            run(pipeline(`$SOFFICE -env:UserInstallation=$(lo_profile_url(joinpath(dir, "profile"))) --headless --norestore --convert-to ods --outdir $out $p`;
                         stdout = devnull, stderr = devnull))
            c = only(getCharts(readods(joinpath(out, "h.ods"))))
            @test c isa OC.ChartEx && OC.getChartTypes(c) == [:histogram]
            @test [x.values.ref for x in getChartSeries(c)] == ["Data.B2:B7"]
            @test sort(titles(OC._object_text(OC._frame(c)))) == sort(["Spread", "Six months", "Sales", "Months"])
        end
    else
        @test_skip false
    end
end

@testset "the chart setters and getters on a histogram, as on a column chart" begin
    E = OpenDocumentSpreadsheets.ODSError
    g1(c) = OC.getChartGroups(c)[1]
    # (setter, getter): each run on a histogram and on a one-series column chart of the same data
    cases = [
        (c -> OC.setSeriesFill(c, 1, "FF0000"; transparency = 40), c -> OC.getSeriesFill(c, 1)),
        (c -> OC.setSeriesLine(c, 1; color = "0000FF", width = 2, dash = :dash), c -> OC.getSeriesLine(c, 1)),
        (c -> OC.setChartTitleTextProp(c, :bold, true), c -> OC.getChartTitleTextProps(c)),
        (c -> OC.setAxisTitleText(c, :x, "Bins"), c -> OC.getAxisTitle(c, :x)),
        (c -> OC.setAxisTextProp(c, :y, :size, 14), c -> OC.getAxisTextProps(c, :y)),
        (c -> OC.setLegendPos(c, :b), c -> OC.getLegendPos(c)),
        (c -> OC.setPlotAreaLine(c; color = "FF0000", width = 1), c -> OC.getPlotAreaShapeProps(c)),
        (c -> OC.setLabelFlag(c, 1, :value, true), c -> OC.getLabelFlag(c, 1, :value)),
        (c -> (OC.setAxisMin(c, :y, 0); OC.setAxisMax(c, :y, 12)), c -> (OC.getAxisMin(c, :y), OC.getAxisMax(c, :y))),
        (c -> (OC.setAxisMajorUnit(c, :y, 4); OC.setAxisMinorUnit(c, :y, 1)), c -> (OC.getAxisMajorUnit(c, :y), OC.getAxisMinorUnit(c, :y))),
        (c -> OC.setAxisGridlines(c, :y; minor = true), c -> OC.getAxisGridlines(c, :y; minor = true)),
        (c -> OC.setAxisNumberFormatCode(c, :y, "0.0"), c -> OC.getAxisNumberFormatCode(c, :y)),
        (c -> OC.setGroupGapWidth(c, g1(c), 50), c -> OC.getGroupGapWidth(c, g1(c))),
        (c -> OC.addSeriesTrendline(c, 1, :linear), c -> OC.getSeriesTrendlines(c, 1)),
        (c -> OC.setSeriesErrorBars(c, 1; type = :percent, value = 10), c -> OC.getSeriesErrorBars(c, 1)),
    ]
    # a getter's whole result, as text (a dump, without the memory addresses it shows)
    seen(x) = replace(sprint(io -> dump(io, x; maxdepth = 12)), r"Ptr\{Nothing\}\(0x[0-9a-f]+\)" => "", r"\s+" => " ")
    function make(kind)
        xf, ws = _chart_data_sheet()
        c = kind === :histogram ? OC.addChart(ws, :histogram; anchor = "H2:O18", title = "T", xtitle = "X", ytitle = "Y") :
                                  OC.addChart(ws, :column; anchor = "H2:O18", title = "T", xtitle = "X", ytitle = "Y")
        OC.addSeries(c, "B2:B7"; name_ref = "B1")
        return xf, c
    end
    mktempdir() do dir
        paths = Dict{Tuple{Int,Symbol},String}()
        for (k, (set!, get)) in enumerate(cases), kind in (:column, :histogram)
            xf, c = make(kind)
            before = seen(get(c))
            set!(c)
            @test seen(get(c)) != before                                  # the setter changed it
            kind === :histogram && @test c isa OC.ChartEx
            paths[(k, kind)] = p = joinpath(dir, "c$(k)_$kind.ods")
            OpenDocumentSpreadsheets.writeods(p, xf)
        end
        # as on a column chart: markers and explosion are errors; a histogram is no combo
        xf, h = make(:histogram)
        @test_throws E OC.setMarker(h, 1; symbol = :square)
        @test_throws E OC.setSeriesExplosion(h, 1, 10)
        @test_throws E OC.makeCombo(h)
        if isfile(SOFFICE) && lo_version(SOFFICE) >= LO_FIXTURE_VERSION
            out = joinpath(dir, "lo")
            run(pipeline(`$SOFFICE -env:UserInstallation=$(lo_profile_url(joinpath(dir, "profile"))) --headless --norestore --convert-to ods --outdir $out $(collect(values(paths)))`;
                         stdout = devnull, stderr = devnull))
            back(k, kind) = only(getCharts(readods(joinpath(out, basename(paths[(k, kind)])))))
            for (k, (_, get)) in enumerate(cases)
                h, col = back(k, :histogram), back(k, :column)
                @test h isa OC.ChartEx && OC.getChartTypes(h) == [:histogram]    # still a histogram
                @test seen(get(h)) == seen(get(col))                          # kept as LibreOffice keeps a column chart's
            end
        else
            @test_skip false
        end
    end
end

@testset "chart sheets" begin
    xf, ws = _chart_data_sheet()
    c = OC.addChart(xf, :line; title = "On its own sheet", xtitle = "Month")
    @test c.sheet == "Chart1" && OpenDocumentSpreadsheets.sheetnames(xf) == ["Data", "Chart1"]
    OC.addSeries(c, "Data!B2:B7"; categories = "Data!A2:A7", name_ref = "Data!B1")
    h = OC.addChartEx(xf, :histogram, "Data!C2:C7"; sheetname = "Spread")
    @test h isa OC.ChartEx && h.sheet == "Spread"
    E = OpenDocumentSpreadsheets.ODSError
    @test_throws E OC.addChartEx(xf, :histogram, "C2:C7")      # a chart sheet's references name their sheet
    @test_throws E OC.addChart(xf, :line; sheetname = "Data")
    @test_throws E OC.addChart(xf, :line; anchor = "A1:B2")
    c3 = OC.addChart(xf, :column)
    @test c3.sheet == "Chart2"
    OC.deleteChart(c3)
    @test length(getCharts(xf["Chart2"])) == 0
    @test [x.sheet for x in getCharts(xf)] == ["Chart1", "Spread"]
    mktempdir() do dir
        p = joinpath(dir, "cs.ods"); f = joinpath(dir, "cs.fods")
        OpenDocumentSpreadsheets.writeods(p, xf); OpenDocumentSpreadsheets.writeods(f, xf)
        frames, orphans = chart_frames(p)
        @test length(frames) == 2 && isempty(orphans) && all(x -> x.parts && x.manifest, frames)
        t = String(ZipArchives.zip_readentry(ZipArchives.ZipReader(read(p)), "content.xml"))
        @test occursin(r"<table:table table:name=\"Chart1\"><table:shapes><draw:frame [^>]*svg:width=\"25.821cm\" svg:height=\"16.856cm\" svg:x=\"0cm\" svg:y=\"0cm\"", t)
        for path in (p, f)
            back = readods(path)
            cs = getCharts(back)
            @test [x.sheet for x in cs] == ["Chart1", "Spread"] && cs[2] isa OC.ChartEx
            @test OC.getChartTitle(cs[1]) == "On its own sheet" && OC.getAxisTitle(cs[1], :x) == "Month"
            @test [x.values.ref for x in getChartSeries(cs[1])] == ["Data.B2:B7"]
        end
        if isfile(SOFFICE) && lo_major(SOFFICE) >= LO_FIXTURE_MAJOR
            out = joinpath(dir, "lo")
            run(pipeline(`$SOFFICE -env:UserInstallation=$(lo_profile_url(joinpath(dir, "profile"))) --headless --norestore --convert-to ods --outdir $out $p $f`;
                         stdout = devnull, stderr = devnull))
            for path in (joinpath(out, "cs.ods"), joinpath(out, "cs.fods.ods"))
                isfile(path) || (path = joinpath(out, "cs.ods"))
                cs = getCharts(readods(path))
                @test [x.sheet for x in cs] == ["Chart1", "Spread"]
                @test [x.values.ref for x in getChartSeries(cs[1])] == ["Data.B2:B7"]
                # the histogram: LibreOffice 26.8 has it; an older one (CI's 26.x) reads it without its series
                if lo_version(SOFFICE) >= LO_FIXTURE_VERSION
                    @test cs[2] isa OC.ChartEx && OC.getChartTypes(cs[2]) == [:histogram]
                    @test [x.values.ref for x in getChartSeries(cs[2])] == ["Data.C2:C7"]
                else
                    @test_skip cs[2] isa OC.ChartEx
                end
                @test OC.getChartTitle(cs[1]) == "On its own sheet"
            end
        else
            @test_skip false
        end
    end
    # a chart sheet copied, and the data's sheet renamed
    copysheet!(xf["Chart1"], "Chart1 copy")
    renamesheet!(xf["Data"], "Numbers")
    cs = getCharts(xf)
    @test [x.sheet for x in cs] == ["Chart1", "Spread", "Chart1 copy"]
    @test all(x -> getChartSeries(x)[1].values.ref == (x isa OC.ChartEx ? "Numbers.C2:C7" : "Numbers.B2:B7"), cs)
    @test length(unique(x.name for x in cs)) == 3
end

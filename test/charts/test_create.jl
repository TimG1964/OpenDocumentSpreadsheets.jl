# Creating charts (phase 8 step 5, D-085, D-086): XLSX.jl's addChart, addSeries, makeCombo and deleteChart
# in LibreOffice's own look, checked against LibreOffice's own charts of each kind (experiment 039 part
# A) and by LibreOffice reading what is written. Uses `_ch`, `chart_frames`, `OC` from the files before.

function _chart_data_sheet()
    xf = newods("Data")
    ws = xf["Data"]
    for (j, h) in enumerate(["Month", "North", "South", "West", "Size", "X"])
        ws[1, j] = h
    end
    for i in 1:6
        ws[i+1, 1] = ["Jan", "Feb", "Mar", "Apr", "May", "Jun"][i]
        ws[i+1, 2] = 10i + 3; ws[i+1, 3] = 40 - 3i; ws[i+1, 4] = 5 + (i % 3) * 7; ws[i+1, 5] = i; ws[i+1, 6] = 1.5i
    end
    return xf, ws
end

# The series of each kind, as XLSX.jl's "addSeries for every kind" testset adds them.
function _add_kind_series!(c, kind)
    if kind === :scatter
        addSeries(c, "B2:B7"; categories = "F2:F7", name_ref = "B1")
    elseif kind === :bubble
        addSeries(c, "B2:B7"; categories = "F2:F7", bubble_sizes = "E2:E7", name_ref = "B1")
    elseif kind in (:pie, :doughnut, :pieOfPie, :barOfPie)
        addSeries(c, "B2:B7"; categories = "A2:A7", name_ref = "B1")
    elseif kind === :combo
        addSeries(c, "B2:B7"; categories = "A2:A7", name_ref = "B1", group = :column)
        addSeries(c, "C2:C7"; categories = "A2:A7", name_ref = "C1", group = :line)
    else
        addSeries(c, "B2:B7"; categories = "A2:A7", name_ref = "B1")
        addSeries(c, "C2:C7"; categories = "A2:A7", name_ref = "C1")
    end
    return c
end

const _KIND_TAGS = Dict(:column => [:barChart], :bar => [:barChart], :stackedColumn => [:barChart], :stackedBar => [:barChart],
    :percentStackedColumn => [:barChart], :percentStackedBar => [:barChart], :line => [:lineChart], :lineMarkers => [:lineChart],
    :stackedLine => [:lineChart], :percentStackedLine => [:lineChart], :stackedLineMarkers => [:lineChart],
    :percentStackedLineMarkers => [:lineChart], :area => [:areaChart], :stackedArea => [:areaChart],
    :percentStackedArea => [:areaChart], :pie => [:pieChart], :doughnut => [:doughnutChart], :scatter => [:scatterChart],
    :bubble => [:bubbleChart], :radar => [:radarChart], :filledRadar => [:radarChart], :combo => [:barChart, :lineChart],
    :pieOfPie => [:ofPieChart], :barOfPie => [:ofPieChart])

@testset "addChart: every kind, as LibreOffice's own chart of the kind" begin
    xf, ws = _chart_data_sheet()
    kinds = [OC.C_KINDS..., :pieOfPie, :barOfPie]
    charts = Dict{Symbol,Any}()
    for (i, kind) in enumerate(kinds)
        r = 20i
        c = addChart(ws, kind; anchor = "H$r:O$(r + 15)", title = "Kind $kind")
        @test c isa OC.Chart && c.from == "H$r" && c.to == "O$(r + 15)" && c.sheet == "Data"
        _add_kind_series!(c, kind)
        charts[kind] = c
        @test (kind, getChartTypes(c)) == (kind, _KIND_TAGS[kind])
        @test (kind, getChartKind(c)) == (kind, kind)                              # Q-030, D-095
        @test OC.getChartTitle(c) == "Kind $kind"
    end
    # LibreOffice's own look (F-082): colours, symbols and lines as its templates make them
    own = readods(_ch("lo-charts-own.ods"))
    for (kind, tpl) in ((:column, "tpl_Column"), (:line, "tpl_Line"), (:lineMarkers, "tpl_LineSymbol"), (:pie, "tpl_Pie"),
                        (:bubble, "tpl_Bubble"), (:bar, "tpl_Bar"), (:stackedColumn, "tpl_StackedColumn"), (:doughnut, "tpl_Donut"),
                        (:area, "tpl_Area"), (:filledRadar, "tpl_FilledNet"), (:pieOfPie, "tpl_PieOfPie"), (:barOfPie, "tpl_BarOfPie"))
        mine = charts[kind]; lo = getChart(own, tpl)
        @test (kind, getChartTypes(mine)) == (kind, getChartTypes(lo))
        for i in 1:min(length(getChartSeries(mine)), length(getChartSeries(lo)))
            fm = OC.getSeriesFill(mine, i).value; fl = OC.getSeriesFill(lo, i).value
            @test (kind, i, fm === nothing ? nothing : fm.fgcolor.rgb) == (kind, i, fl === nothing ? nothing : fl.fgcolor.rgb)
            mm = OC.getSeriesMarker(mine, i); ml = OC.getSeriesMarker(lo, i)
            @test (kind, i, mm === nothing ? nothing : (mm.symbol, mm.size)) == (kind, i, ml === nothing ? nothing : (ml.symbol, ml.size))
            lm = OC.getSeriesLine(mine, i).value; ll = OC.getSeriesLine(lo, i).value
            @test (kind, i, lm === nothing ? nothing : lm.width) == (kind, i, ll === nothing ? nothing : ll.width)
        end
        @test (kind, length(OC.getSeriesDataPoints(mine, 1))) == (kind, length(OC.getSeriesDataPoints(lo, 1)))
    end
    @test getChartRanges(charts[:bubble])[1].bubble_sizes == OpenDocumentSpreadsheets.SheetCellRange("Data.E2:E7")
    @test string(getChartRanges(charts[:scatter])[1].categories) == "Data.F2:F7"
    @test OC.getChartAxis(charts[:combo], :y2).axid == 4 && OC.getSeriesGroup(charts[:combo], 2).axids == [3, 4]
    # the file: every chart's object and frame, and LibreOffice reading them
    mktempdir() do dir
        p = joinpath(dir, "kinds.ods"); f = joinpath(dir, "kinds.fods")
        writeods(p, xf); writeods(f, xf)
        frames, orphans = chart_frames(p)
        @test length(frames) == length(kinds) && isempty(orphans) && all(x -> x.parts && x.manifest, frames)
        for path in (p, f)
            back = readods(path)
            @test length(getCharts(back)) == length(kinds)
            @test [getChartTypes(c) for c in getCharts(back)] == [_KIND_TAGS[k] for k in kinds]
            @test [getChartKind(c) for c in getCharts(back)] == kinds
        end
        if lo_ok(LO_FIXTURE_MAJOR)
            out = joinpath(dir, "lo")
            lo_convert([p, f], "ods"; outdir = out, profile = lo_profile_url(joinpath(dir, "profile")))
            for path in (joinpath(out, "kinds.ods"), joinpath(out, "kinds.fods.ods"))
                isfile(path) || (path = replace(path, "kinds.fods.ods" => "kinds.ods"))
                lo = readods(path)
                cs = getCharts(lo)
                @test length(cs) == length(kinds)
                for (c, kind) in zip(cs, kinds)
                    @test (kind, getChartTypes(c)) == (kind, _KIND_TAGS[kind])
                    @test (kind, getChartKind(c)) == (kind, kind)       # LibreOffice keeps the kind
                    mine = charts[kind]
                    @test (kind, [s.values.ref for s in getChartSeries(c)]) == (kind, [s.values.ref for s in getChartSeries(mine)])
                    @test (kind, [s.name for s in getChartSeries(c)]) == (kind, [s.name for s in getChartSeries(mine)])
                    @test (kind, OC.getChartTitle(c)) == (kind, "Kind $kind")
                end
            end
        end
    end
end

@testset "getChartKind: any chart's kind, as addChart names it (Q-030, D-095)" begin
    # LibreOffice's own charts, one per chart type template (experiment 039 part A)
    own = readods(_ch("lo-charts-own.ods"))
    for (tpl, kind) in ("tpl_Column" => :column, "tpl_Bar" => :bar, "tpl_StackedColumn" => :stackedColumn,
                        "tpl_PercentStackedColumn" => :percentStackedColumn, "tpl_Line" => :line,
                        "tpl_LineSymbol" => :lineMarkers, "tpl_Symbol" => :lineMarkers, "tpl_StackedLine" => :stackedLine,
                        "tpl_Area" => :area, "tpl_Pie" => :pie, "tpl_Donut" => :doughnut, "tpl_PieOfPie" => :pieOfPie,
                        "tpl_BarOfPie" => :barOfPie, "tpl_ScatterSymbol" => :scatter, "tpl_ScatterLine" => :scatter,
                        "tpl_ScatterLineSymbol" => :scatter, "tpl_Bubble" => :bubble, "tpl_NetLine" => :radar,
                        "tpl_Net" => :radar, "tpl_FilledNet" => :filledRadar, "tpl_ColumnWithLine" => :combo,
                        "tpl_StackedColumnWithLine" => :combo, "tpl_StockLowHighClose" => :stock,
                        "tpl_StockVolumeOpenLowHighClose" => :stockVolumeOHLC, "tpl_Histogram" => :histogram,
                        # 3-D isn't part of the kind
                        "tpl_ThreeDColumnDeep" => :column, "tpl_PercentStackedThreeDColumnFlat" => :percentStackedColumn,
                        "tpl_ThreeDLine" => :line, "tpl_ThreeDPie" => :pie,
                        # a secondary axis alone doesn't make a combo; a chart without a diagram is unknown
                        "opt_secondary_y" => :column, "tpl_Waterfall" => :unknown)
        @test (tpl, getChartKind(getChart(own, tpl))) == (tpl, kind)
    end
    # LibreOffice's import of XLSX.jl's 22 kinds (experiment 039 part B): Object 1 to 22, in C_KINDS order
    imp = readods(_ch("lo-charts-import.ods"))
    @test [getChartKind(getChart(imp, "Object $i")) for i in 1:22] == collect(OC.C_KINDS)
    # stock charts, before and after their series; 3-D; histograms
    xf, ws = _chart_data_sheet()
    for (i, kind) in enumerate((:stock, :stockOHLC, :stockVolume, :stockVolumeOHLC))
        c = addChart(ws, kind; anchor = "H$(20i):O$(20i + 15)")
        @test (kind, getChartKind(c)) == (kind, kind)
        cols = kind === :stock ? ("B", "C", "D") : kind === :stockOHLC ? ("B", "C", "D", "E") :
               kind === :stockVolume ? ("E", "B", "C", "D") : ("E", "B", "C", "D", "F")
        for col in cols
            addSeries(c, "$(col)2:$(col)7"; categories = "A2:A7")
        end
        @test (kind, getChartKind(c), length(getChartSeries(c))) == (kind, kind, length(cols))
    end
    @test getChartKind(addChart(ws, :stackedBar; anchor = "H100:O115", threeD = true, deep = true)) === :stackedBar
    h = addChart(ws, :histogram; anchor = "H120:O135")
    @test getChartKind(h) === :histogram && getChartKind(addSeries(h, "B2:B7")) === :histogram
    m = addChart(ws, :column; anchor = "H140:O155")
    _add_kind_series!(m, :column)
    @test getChartKind(makeCombo(m)) === :combo
end

@testset "addSeries' options" begin
    xf, ws = _chart_data_sheet()
    c = addChart(ws, :line; anchor = "H2:O16", xtitle = "Month", ytitle = "£m")
    addSeries(c, "B2:B7"; categories = "A2:A7", markers = :diamond, smooth = true, color = "FF0000")
    addSeries(c, "Data!\$C\$2:\$C\$7"; categories = "Data!\$A\$2:\$A\$7", markers = :bowTie, smooth = true, color = :accent2)
    @test OC.getSeriesMarker(c, 1).symbol === :diamond && OC.getSeriesMarker(c, 2).symbol === :bowTie
    @test OC.getSeriesFill(c, 1).value.fgcolor.rgb == "FF0000"
    f = OC.getSeriesFill(c, 2).value.fgcolor
    @test f.kind === :srgb && f.rgb == "0369A3"          # a new document's theme, resolved: LibreOffice keeps no theme reference (experiment 039 B2)
    @test OC.getAxisTitle(c, :x) == "Month" && OC.getAxisTitle(c, :y) == "£m"
    @test OC.getAxisTitleText(c, :y).body.rotation == 90
    s = addChart(ws, :scatter; anchor = "H20:O36")
    addSeries(s, "B2:B7"; categories = "F2:F7", line = true, markers = false)
    addSeries(s, "C2:C7"; categories = "F2:F7", name = "Literal")
    @test OC.getSeriesMarker(s, 1).symbol === :none && OC.getSeriesLine(s, 1).value.width ≈ 2.27
    @test getChartSeries(s)[2].name == "Literal" && getChartSeries(s)[2].name_ref === nothing
    @test OC.getSeriesLine(s, 2).value.fill.kind === :none                       # markers only
    # XLSX.jl's refusals, and LibreOffice's (D-086)
    E = OpenDocumentSpreadsheets.ODSError
    col = addChart(ws, :column; anchor = "H40:O56")
    @test_throws E addSeries(col, "B2:B7"; smooth = true)
    @test_throws E addSeries(col, "B2:B7"; markers = :circle)
    @test_throws E addSeries(col, "B2:B7"; name = "a", name_ref = "B1")
    @test_throws E addSeries(col, "B2:B7"; bubble_sizes = "E2:E7")
    @test_throws E addSeries(col, "B2:B7"; group = :line)
    @test_throws E addSeries(col, "B2:B7"; color = "notacolor")
    addSeries(col, "B2:B7"; categories = "A2:A7")
    @test_throws E addSeries(col, "C2:C7"; categories = "D2:D7")      # LibreOffice's categories are the chart's
    @test_throws E addSeries(c, "D2:D7"; smooth = false)              # smoothing is the chart's
    @test_throws E addSeries(c, "D2:D7"; markers = :picture)
    @test_throws E addSeries(s, "D2:D7"; markers = false)             # an XY series without markers needs a line
    pie = addChart(ws, :pie; anchor = "H60:O76")
    @test_throws E addSeries(pie, "B2:B7"; color = "red")
    addSeries(pie, "B2:B7")
    @test_throws E addSeries(pie, "C2:C7")
    bub = addChart(ws, :bubble; anchor = "H80:O96")
    @test_throws E addSeries(bub, "B2:B7"; categories = "F2:F7")
    combo = addChart(ws, :combo; anchor = "H100:O116")
    @test_throws E addSeries(combo, "B2:B7")
    @test_throws E addChart(ws, :column; anchor = "H2:O16", title = OpenDocumentSpreadsheets.CellRef("A1"))
    @test_throws E addChart(ws, :pie; anchor = "H2:O16", xtitle = "x")
    @test_throws E addChart(ws, :waterfall; anchor = "H2:O16")
    @test_throws E addChart(ws, :column; anchor = "H2:O16", title = true)
    @test_throws E addChart(ws, :column; anchor = "H2:O16", deep = true)
    # LibreOffice's own (D-076): a subtitle, 3-D
    t = addChart(ws, :column; anchor = "Q2:X16", title = "Main", subtitle = "Sub", threeD = true, deep = true)
    _add_kind_series!(t, :column)
    @test getChartTypes(t) == [:bar3DChart] && 5 in [a.axid for a in OC.getChartAxes(t)]
end

@testset "makeCombo and deleteChart" begin
    xf, ws = _chart_data_sheet()
    c = _add_kind_series!(addChart(ws, :column; anchor = "H2:O16", title = "C"), :column)
    makeCombo(c)
    @test getChartTypes(c) == [:barChart, :lineChart] && OC.getSeriesGroup(c, 2).axids == [3, 4]
    @test_throws OpenDocumentSpreadsheets.ODSError makeCombo(c)
    l = _add_kind_series!(addChart(ws, :line; anchor = "H20:O36"), :line)
    makeCombo(l)
    @test getChartTypes(l) == [:barChart, :lineChart]
    # the line is stroked (a column's style has none, which hid it) and the columns aren't; the
    # secondary axis comes before the series, as ODF orders them (LibreOffice ignores it after)
    mktempdir() do dir
        p = joinpath(dir, "combo.ods")
        writeods(p, xf)
        z = ZipArchives.ZipReader(read(p))
        for ch in (c, l)
            t = String(ZipArchives.zip_readentry(z, ch.name * "/content.xml"))
            @test findfirst("chart:name=\"secondary-y\"", t) < findfirst("<chart:series ", t)
            sts = [m.captures[1] for m in eachmatch(r"<chart:series\b[^>]*chart:style-name=\"([^\"]*)\"", t)]
            gp(st) = match(Regex("<style:style style:name=\"" * st * "\"[^>]*>.*?</style:style>", "s"), t).match
            @test occursin("svg:stroke-width", gp(last(sts))) && !occursin("draw:stroke=\"none\"", gp(last(sts)))
            @test all(st -> occursin("draw:stroke=\"none\"", gp(st)), sts[1:end-1])
            ax = match(r"chart:name=\"secondary-y\" chart:style-name=\"([^\"]*)\"", t).captures[1]
            @test occursin("chart:axis-position=\"end\"", gp(ax))      # at the right, not over the primary
        end
    end
    one = addChart(ws, :column; anchor = "H40:O56"); addSeries(one, "B2:B7")
    @test_throws OpenDocumentSpreadsheets.ODSError makeCombo(one)
    @test_throws OpenDocumentSpreadsheets.ODSError makeCombo(_add_kind_series!(addChart(ws, :bar; anchor = "H60:O76"), :bar))
    n = length(getCharts(xf))
    deleteChart(one)
    @test length(getCharts(xf)) == n - 1 && !any(x -> x.name == one.name, getCharts(xf))
    # a file's chart anchored to a cell goes with its object; one on the page can't
    f = openods(_ch("lo-charts-ops-base.ods"); mode = "rw")
    deleteChart(getChart(f, "opt_anchor_cell"))
    @test_throws OpenDocumentSpreadsheets.ODSError deleteChart(getChart(f, "opt_plain"))
    @test !any(x -> x.name == "opt_anchor_cell", getCharts(f))
    mktempdir() do dir
        p = joinpath(dir, "del.ods")
        writeods(p, f)
        frames, orphans = chart_frames(p)
        @test length(frames) == 8 && isempty(orphans) && !any(x -> x.object == "opt_anchor_cell", frames)
    end
end

@testset "new charts through edits and operations" begin
    xf, ws = _chart_data_sheet()
    c = _add_kind_series!(addChart(ws, :column; anchor = "H2:O16"), :column)
    insertRows(ws, 3; count = 2)
    @test [string(r.values) for r in getChartRanges(c)] == ["Data.B2:B9", "Data.C2:C9"]
    @test (getChart(xf, c.name).from, getChart(xf, c.name).to) == ("H2", "O18")    # the insert is below its anchor: it grows
    deleteColumns(ws, 2)
    @test [string(r.values) for r in getChartRanges(c)] == ["Data.B2:B9", "Data.B2:B9"]   # wholly deleted: kept (F-043)
    other = addsheet!(xf, "Other")
    oc = addChart(other, :line; anchor = "B2:H16")
    addSeries(oc, "Data!B2:B9"; categories = "Data!A2:A9")
    renamesheet!(ws, "My Data")
    @test string(getChartRanges(oc)[1].values) == "'My Data'.B2:B9"
    cp = copysheet!(xf["My Data"], "Copy")
    cc = getCharts(cp)
    @test length(cc) == 1 && cc[1].name != c.name && string(getChartRanges(cc[1])[1].values) == "'My Data'.B2:B9"
    deleteRows(xf["Copy"], 1:30)                 # the copy's chart goes with its cells
    @test isempty(getCharts(xf["Copy"]))
    deletesheet!(xf["My Data"])                  # the data's sheet: re-pointed to the sheet before (F-047)
    @test length(getCharts(xf)) == 1
    mktempdir() do dir
        p = joinpath(dir, "ops.ods")
        writeods(p, xf)
        frames, orphans = chart_frames(p)
        @test length(frames) == 1 && isempty(orphans)
    end
    # a file's sheet: a chart added, then operations, then a patched save
    f = openods(_ch("lo-charts-ops-base.ods"); mode = "rw")
    n = _add_kind_series!(addChart(f["Data"], :line; anchor = "T2:Z16", title = "Added"), :line)
    insertRows(f["Data"], 1)
    @test string(getChartRanges(n)[1].values) == "Data.B3:B8"
    mktempdir() do dir
        p = joinpath(dir, "added.ods")
        writeods(p, f)
        frames, orphans = chart_frames(p)
        @test length(frames) == 10 && isempty(orphans) && all(x -> x.parts && x.manifest, frames)
        back = readods(p)
        @test OC.getChartTitle(getChart(back, n.name)) == "Added"
        @test [s.values.ref for s in getChartSeries(getChart(back, n.name))] == ["Data.B3:B8", "Data.C3:C8"]
        if lo_ok(LO_FIXTURE_MAJOR)
            out = joinpath(dir, "lo")
            lo_convert(p, "ods"; outdir = out, profile = lo_profile_url(joinpath(dir, "profile")))
            lo = readods(joinpath(out, "added.ods"))
            @test length(getCharts(lo)) == 10
            s = [x for x in getCharts(lo) if OC.getChartTitle(x) == "Added"]
            @test length(s) == 1 && [r.values.ref for r in getChartSeries(s[1])] == ["Data.B3:B8", "Data.C3:C8"]
        end
    end
end

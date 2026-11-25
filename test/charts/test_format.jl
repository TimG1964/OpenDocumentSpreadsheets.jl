# Reading charts' formatting (phase 8 step 4, D-085), against LibreOffice's API reading the same files
# (experiment 039's oracle). Uses `_ch`, `_oracle_charts_lines` and `OC` from test_reading.jl.

const _O_SYMBOLS = [:square, :diamond, :arrowDown, :triangle, :dot, :arrowLeft, :bowTie, :hourglass, :circle,
                    :loStar, :x, :plus, :star, :dash, :vBar]
_mm100_pt(v) = round(parse(Float64, v) * 72 / 2540; digits = 1)
_rgb(f) = f === nothing || f.fgcolor === nothing ? nothing : f.fgcolor.rgb

function check_format(path, oracle; skip = String[])
    xf = readods(path)
    n = 0
    for c in getCharts(xf)
        c isa OC.Chart || continue
        ch = oracle[c.name]
        (haskey(ch, "nodiagram") || c.name in skip) && continue
        # the legend
        hasleg = ch["diagram2"][1]["HasLegend"] == "True"
        if !hasleg
            @test (c.name, OC.getLegendPos(c)) == (c.name, nothing)
        else
            lg = ch["legend"][1]
            want = Dict("0" => :l, "1" => :r, "2" => :t, "3" => :b)[lg["AnchorPosition"]]
            @test (c.name, OC.getLegendPos(c) in (want, :tr, :tl, :bl, :br) && (OC.getLegendPos(c) == want || want == :r)) == (c.name, true)
            @test (c.name, OC.getLegendOverlay(c)) == (c.name, lg["Overlay"] == "True")
        end
        :stockChart in getChartTypes(c) && continue
        # the series: fill, line, symbol, label flags, legend entries
        for (i, s) in enumerate(get(ch, "series", Dict{String,String}[]))
            n += 1
            f = OC.getSeriesFill(c, i).value
            if get(s, "FillStyle", "") == "0"
                @test (c.name, i, f === nothing || f.kind === :none) == (c.name, i, true)
            elseif f !== nothing && f.kind === :solid
                @test (c.name, i, _rgb(f)) == (c.name, i, uppercase(s["FillColor"]))
            end
            l = OC.getSeriesLine(c, i).value
            if l !== nothing && l.width !== nothing
                @test (c.name, i, l.width) == (c.name, i, _mm100_pt(s["LineWidth"])) ||
                      (c.name, i, abs(l.width - _mm100_pt(s["LineWidth"])) < 0.15) == (c.name, i, true)
            end
            sy = match(r"^(\d+)/(\d+)/(\d+)x", get(s, "Symbol", ""))
            m = OC.getSeriesMarker(c, i)
            if sy !== nothing && m !== nothing
                style, std = parse(Int, sy[1]), parse(Int, sy[2])
                want = style == 0 ? :none : style == 1 ? :auto : style == 2 ? _O_SYMBOLS[std+1] : m.symbol
                @test (c.name, i, m.symbol) == (c.name, i, want)
                style == 2 && @test (c.name, i, abs(m.size - parse(Int, sy[3]) * 72 / 2540) <= 1) == (c.name, i, true)
            end
            lb = match(r"num:(\w+)/pct:(\w+)/cat:(\w+)/key:(\w+)/custom:\w+/ser:(\w+)", get(s, "Label", ""))
            if lb !== nothing
                for (flag, k) in ((:value, 1), (:percent, 2), (:categoryName, 3), (:legendKey, 4), (:seriesName, 5))
                    v = OC.getLabelFlag(c, i, flag)
                    v === nothing || @test (c.name, i, flag, v) == (c.name, i, flag, lb[k] == "True")
                end
            end
            haskey(s, "ShowLegendEntry") && s["ShowLegendEntry"] == "False" && @test OC.getLegendEntryDeleted(c, i) === true
        end
        # the axes
        for a in get(ch, "axis", Dict{String,String}[])
            (haskey(a, "ERR") || isempty(get(a, "Orientation", ""))) && continue
            id = a["dim"] == "2" ? 5 : parse(Int, a["dim"]) + 1 + 2 * parse(Int, a["idx"])
            any(x -> x.axid == id, OC.getChartAxes(c)) || continue
            @test (c.name, id, OC.getAxisMin(c, id)) == (c.name, id, isempty(a["Minimum"]) ? nothing : parse(Float64, a["Minimum"]))
            @test (c.name, id, OC.getAxisMax(c, id)) == (c.name, id, isempty(a["Maximum"]) ? nothing : parse(Float64, a["Maximum"]))
            @test (c.name, id, OC.getAxisOrientation(c, id)) == (c.name, id, a["Orientation"] == "1" ? :maxMin : :minMax)
            @test (c.name, id, OC.getAxisLogBase(c, id)) == (c.name, id, occursin("Logarithmic", a["Scaling"]) ? 10.0 : nothing)
            @test (c.name, id, OC.getAxisMajorUnit(c, id)) == (c.name, id, isempty(a["Distance"]) ? nothing : parse(Float64, a["Distance"]))
            if !isempty(a["Distance"]) && !isempty(get(a, "SubIntervals", ""))
                @test (c.name, id, OC.getAxisMinorUnit(c, id)) == (c.name, id, parse(Float64, a["Distance"]) / parse(Int, a["SubIntervals"]))
            end
            ticks = Dict("0" => :none, "1" => :in, "2" => :out, "3" => :cross)
            haskey(a, "MajorTickmarks") && @test (c.name, id, OC.getAxisMajorTickMark(c, id)) == (c.name, id, ticks[a["MajorTickmarks"]])
            haskey(a, "MinorTickmarks") && @test (c.name, id, OC.getAxisMinorTickMark(c, id)) == (c.name, id, ticks[a["MinorTickmarks"]])
            lp = a["DisplayLabels"] == "False" ? :none : Dict("0" => :nextTo, "1" => :nextTo, "2" => :low, "3" => :high)[a["LabelPosition"]]
            @test (c.name, id, OC.getAxisTickLabelPos(c, id)) == (c.name, id, lp)
            cp = a["CrossoverPosition"]
            @test (c.name, id, OC.getAxisCrosses(c, id)) == (c.name, id, cp == "0" ? :autoZero : cp == "1" ? :min : cp == "2" ? :max : nothing)
            cp == "3" && @test (c.name, id, OC.getAxisCrossesAt(c, id)) == (c.name, id, parse(Float64, a["CrossoverValue"]))
            @test (c.name, id, OC.getAxisGridlines(c, id) !== nothing) == (c.name, id, startswith(a["grid"], "True"))
            haskey(a, "subgrid") && @test (c.name, id, OC.getAxisGridlines(c, id; minor = true) !== nothing) == (c.name, id, a["subgrid"] == "True")
            if a["LinkNumberFormatToSource"] == "False"
                @test (c.name, id, OC.getAxisNumberFormatCode(c, id)) == (c.name, id, split(a["NumberFormat"], '|'; limit = 2)[2])
            end
            @test (c.name, id, OC.getAxisNumberFormatLinked(c, id)) == (c.name, id, a["LinkNumberFormatToSource"] == "True")
        end
        # the title's runs: bold, italic, colour, size
        t = get(ch, "title", nothing)
        if t !== nothing
            dt = OC.getChartTitleText(c)
            runs = [r for p in dt.paragraphs for r in p.runs if r.kind === :run]
            for (k, r) in enumerate(runs)
                rp = match(Regex("runprops$(k-1)=\\{([^}]*)\\}"), join(("$a=$b" for (a, b) in t[1]), "\t"))
                rp === nothing && continue
                props = Dict(split(x, "=", limit = 2) for x in split(rp[1], ' ') if occursin('=', x))
                r.props === nothing && continue
                r.props.bold === nothing || @test (c.name, k, r.props.bold) == (c.name, k, props["CharWeight"] == "150")
                r.props.italic === nothing || @test (c.name, k, r.props.italic) == (c.name, k, props["CharPosture"] == "2")
            end
        end
        # trendlines and error bars
        for tr in get(ch, "trend", Dict{String,String}[])
            ts = OC.getSeriesTrendlines(c, parse(Int, tr["n"]))
            kinds = Dict("Linear" => :linear, "Logarithmic" => :log, "Exponential" => :exp, "Potential" => :power,
                         "Polynomial" => :poly, "MovingAverage" => :movingAvg)
            k = first(v for (key, v) in kinds if occursin(key, tr["kind"]))
            @test (c.name, k in [x.kind for x in ts]) == (c.name, true)
        end
        for e in get(ch, "errbar", Dict{String,String}[])
            es = OC.getSeriesErrorBars(c, parse(Int, e["n"]))
            want = Dict("3" => "fixedVal", "4" => "percentage", "2" => "stdDev", "6" => "stdErr", "7" => "cust")[e["ErrorBarStyle"]]
            @test (c.name, [x.value_type for x in es if x.direction == (e["which"] == "ErrorBarY" ? "y" : "x")]) == (c.name, [want])
            if want == "cust"
                r = OC.getErrorBarsCustomRefs(c, es[1])
                @test r.plus.ref == replace(e["ErrorBarRangePositive"], '$' => "")
            end
        end
    end
    return n
end

@testset "LibreOffice's own charts' formatting, as its API reads it" begin
    @test check_format(_ch("lo-charts-own.ods"), _oracle_charts_lines("own.tsv")) > 150
end

@testset "LibreOffice's import's formatting, as its API reads it" begin
    @test check_format(_ch("lo-charts-import.ods"), _oracle_charts_lines("import.tsv")) > 80
end

@testset "formatting getters: shapes, text and the value types" begin
    xf = readods(_ch("lo-charts-own.ods"))
    c = getChart(xf, "opt_title_rich")
    t = OC.getChartTitleText(c)
    @test [r.text for r in t.paragraphs[1].runs] == ["Rich ", "title"]
    @test t.paragraphs[1].runs[1].props.bold === true && t.paragraphs[1].runs[2].props.italic === true
    @test t.paragraphs[1].runs[2].props.fill.fgcolor.rgb == "FF0000"
    @test OC.getChartTitleRef(c) === nothing && OC.getAutoTitleDeleted(c) === nothing
    c = getChart(xf, "opt_series_colors")
    @test OC.hasFill(OC.getSeriesFill(c, 1)) && !OC.hasFill(OC.getSeriesFill(c, 2))
    @test OC.getSeriesFill(c, 1).site.level === :series
    c = getChart(xf, "opt_point_color")
    @test OC.getSeriesFill(c, 1; point = 4).value.fgcolor.rgb == "FFFF00"
    @test OC.getSeriesFill(c, 1; point = 4).site.level === :point
    @test OC.getSeriesFill(c, 1; point = 1).site.level === :series
    @test length(OC.getSeriesDataPoints(c, 1)) == 1 && OC.getSeriesDataPoint(c, 1, 4).idx == 3
    c = getChart(xf, "opt_label_custom_text")
    ls = OC.getSeriesDataLabels(c, 1)
    @test length(ls) == 1 && ls[1].idx == 4
    @test OC.getDataLabelText(c, ls[1]).paragraphs[1].runs[1].text == "peak"
    c = getChart(xf, "opt_label_point_off")
    @test OC.getSeriesDataLabel(c, 1, 2).delete === true
    c = getChart(xf, "opt_gap_overlap")
    g = getChartGroups(c)[1]
    @test OC.getGroupGapWidth(c, g) == 50 && OC.getGroupOverlap(c, g) == -30
    @test OC.getGroupDropLines(c, g) === nothing && OC.getGroupUpDownBars(c, g) === nothing
    c = getChart(xf, "opt_secondary_y")
    @test [a.axid for a in OC.getChartAxes(c)] == [1, 2, 4]
    @test OC.getChartAxis(c, :y2).axid == 4 && OC.getChartAxis(c, :x).kind === :catAx
    @test OC.getSeriesGroup(c, 2).axids == [3, 4] && OC.getAxisPartner(c, :x).axid == 2
    @test_throws OpenDocumentSpreadsheets.ODSError OC.getChartAxis(c, :z)
    c = getChart(xf, "tpl_Bar")                        # a horizontal bar chart: categories on the left
    @test OC.getChartAxis(c, :y).kind === :catAx && OC.getChartAxis(c, :x).kind === :valAx
    c = getChart(xf, "opt_ax_titles")
    @test OC.getAxisTitle(c, :x) == "Month" && OC.getAxisTitle(c, :y) == "Value"
    @test OC.getAxisTitleText(c, :y).body.rotation == 90
    c = getChart(xf, "opt_legend_text")
    @test OC.getLegendTextProps(c).paragraphs[1].props.defprops.size == 14
    @test OC.getChartLegend(c) isa OpenDocumentSpreadsheets.XML.Node
    c = getChart(xf, "tpl_StockVolumeOpenLowHighClose")
    sg = [g for g in getChartGroups(c) if g.kind === :stockChart]
    @test !isempty(sg) && OC.getGroupUpDownBars(c, sg[1]) isa OC.ChartUpDownBars
    @test OC.getLabelTextProp(getChart(xf, "opt_label_text_props"), 1, :bold).value === true
end

# Charts (code review, Phase 3; D-102): making a chart, setting and reading its format, and saving.
#
#   julia --project=bench bench/charts.jl [results.tsv]
#
# Cases, on a new file with a 5-series line chart over 30 rows (as a test would make it):
#   add_chart     addChart and 5 addSeries
#   setters_20    20 setter calls over the chart's parts (series, markers, axes, legend, titles)
#   getters_20    20 getter calls on the same parts
#   save          the file with the chart, to an IOBuffer
#   all           the four, on one chart
# and on a file read from disk (LibreOffice's 136 charts, test/data/charts/lo-charts-own.ods):
#   read_getters  getChartType, getSeriesFill and getAxisMin on every chart
#   edit_save     one setter on every chart, then a save
# The median of 5 runs (after a warm-up) is kept, with its allocation.
using OpenDocumentSpreadsheets, Printf
const ODS = OpenDocumentSpreadsheets
const OC = ODS.Charts
const OUT = isempty(ARGS) ? joinpath(@__DIR__, "results", "charts-latest.tsv") : ARGS[1]
const OWN = joinpath(@__DIR__, "..", "test", "data", "charts", "lo-charts-own.ods")

function newchart()
    xf = newods("Data"); ws = xf[1]
    for r in 1:30, c in 1:6; ws[r, c] = r * c; end
    ch = OC.addChart(ws, :lineMarkers; anchor = "H2:O18", title = "T", xtitle = "X", ytitle = "Y")
    for k in 2:6; OC.addSeries(ch, ODS.SheetCore.CellRange(1, k, 30, k)); end
    return xf, ch
end
function setters!(ch)
    OC.setSeriesLine(ch, 1; color = "FF0000", width = 2); OC.setSeriesLine(ch, 2; dash = :dash)
    OC.setSeriesFill(ch, 3, "00FF00"); OC.setSeriesFill(ch, 4, OC.SchemeColor(:accent2; lumMod = 75))
    OC.setMarker(ch, 1; symbol = :diamond, size = 7); OC.setMarker(ch, 5; symbol = :x)
    OC.setMarker(ch, 2; point = 3, symbol = :circle)
    OC.setLabelFlag(ch, 1, :value, true); OC.setLabelTextProp(ch, 1, :bold, true)
    OC.setAxisMin(ch, :y, 0); OC.setAxisMax(ch, :y, 200); OC.setAxisMajorUnit(ch, :y, 50)
    OC.setAxisGridlines(ch, :y; minor = true); OC.setAxisNumberFormatCode(ch, :y, "0.0")
    OC.setAxisTitleText(ch, :x, "Rows"); OC.setLegendPos(ch, :b)
    OC.setChartTitleText(ch, "New title"); OC.setChartTitleTextProp(ch, :size, 16)
    OC.setPlotAreaLine(ch; color = "333333"); OC.setErrorBars(ch, 2; type = :percent, value = 10)
    return ch
end
function getters(ch)
    (OC.getSeriesLine(ch, 1), OC.getSeriesLine(ch, 2), OC.getSeriesFill(ch, 3), OC.getSeriesFill(ch, 4),
     OC.getSeriesMarker(ch, 1), OC.getSeriesMarker(ch, 5), OC.getSeriesDataPoints(ch, 2), OC.getLabelFlag(ch, 1, :value),
     OC.getAxisMin(ch, :y), OC.getAxisMax(ch, :y), OC.getAxisMajorUnit(ch, :y), OC.getAxisGridlines(ch, :y),
     OC.getAxisNumberFormatCode(ch, :y), OC.getAxisTitleText(ch, :x), OC.getLegendPos(ch), OC.getChartTitle(ch),
     OC.getChartTitleTextProps(ch), OC.getPlotAreaShapeProps(ch), OC.getSeriesErrorBars(ch, 2), OC.getChartType(ch))
end
save(xf) = (io = IOBuffer(); writeods(io, xf); io)

const CASES = [
    "add_chart"    => (() -> nothing, _ -> newchart()),
    "setters_20"   => (() -> newchart()[2], ch -> setters!(ch)),
    "getters_20"   => (() -> setters!(newchart()[2]), ch -> getters(ch)),
    "save"         => (() -> (x = newchart(); setters!(x[2]); x[1]), xf -> save(xf)),
    "all"          => (() -> nothing, _ -> (x = newchart(); setters!(x[2]); getters(x[2]); save(x[1]))),
    "read_getters" => (() -> openods(OWN), xf -> [(OC.getChartType(c), OC.getSeriesFill(c, 1), OC.getAxisMin(c, :y))
                                                  for c in OC.getCharts(xf) if c isa OC.Chart && !isempty(OC.getChartSeries(c)) &&
                                                      !isempty(OC.getChartAxes(c))]),
    "edit_save"    => (() -> openods(OWN; mode = "rw"), xf -> (foreach(c -> OC.setChartTitleText(c, "x"), OC.getCharts(xf)); save(xf))),
]

function measure(setup, f, k = 5)
    f(setup())
    ts = Float64[]; bs = Int[]
    for _ in 1:k
        x = setup(); GC.gc()
        st = @timed f(x)
        push!(ts, st.time); push!(bs, st.bytes)
    end
    i = sortperm(ts)[(k + 1) ÷ 2]
    return ts[i], bs[i]
end

mkpath(dirname(OUT))
open(OUT, "w") do io
    println(io, "case\tms\tmib")
    for (name, (setup, f)) in CASES
        t, b = measure(setup, f)
        @printf(io, "%s\t%.2f\t%.1f\n", name, 1000t, b / 2^20)
        @printf("%-14s %9.2f ms %8.1f MiB\n", name, 1000t, b / 2^20)
    end
end

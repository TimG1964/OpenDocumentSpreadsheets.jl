# Reading charts: discovery and data (phase 8 step 3, D-085), against LibreOffice's API reading the same
# files (experiment 039's oracle, test/data/charts/lo-charts-oracle.zip). Uses `_ch`, `_chart_oracle`,
# `_CHART_OPS` and `_lo_chart_ops` from write/test_chartobjects.jl.
using OpenDocumentSpreadsheets.Charts
const OC = OpenDocumentSpreadsheets.Charts

# The oracle's charts: object => Dict(kind => [Dict(field => value)…]) in order.
function _oracle_charts(name)
    out = Dict{String,Dict{String,Any}}()
    cur = nothing
    for l in eachline(IOBuffer(_chart_oracle(name)))
        f = split(l, '\t')
        kv = Dict{String,String}()
        for x in f[2:end]
            p = split(x, "=", limit = 2)
            length(p) == 2 && (kv[p[1]] = p[2])
        end
        if f[1] == "chart"
            cur = get!(Dict{String,Any}, out, kv["object"])
            cur["chart"] = [kv]
        elseif cur !== nothing
            push!(get!(Vector{Dict{String,String}}, cur, f[1]), kv)
        end
    end
    return out
end

const _O_TAGS = Dict("com.sun.star.chart2.ColumnChartType" => :barChart, "com.sun.star.chart2.LineChartType" => :lineChart,
    "com.sun.star.chart2.AreaChartType" => :areaChart, "com.sun.star.chart2.ScatterChartType" => :scatterChart,
    "com.sun.star.chart2.BubbleChartType" => :bubbleChart, "com.sun.star.chart2.NetChartType" => :radarChart,
    "com.sun.star.chart2.FilledNetChartType" => :radarChart, "com.sun.star.chart2.CandleStickChartType" => :stockChart,
    "com.sun.star.chart2.HistogramChartType" => :histogram)
const _O_3D = Dict(:barChart => :bar3DChart, :lineChart => :line3DChart, :areaChart => :area3DChart, :pieChart => :pie3DChart)

# The tags the oracle's chart types give, as this package names them.
function _oracle_tags(ch)
    dim3 = ch["diagram"][1]["Dim3D"] == "True"
    tags = Symbol[]
    for ct in get(ch, "charttype", Dict{String,String}[])
        t = ct["type"]
        tag = t == "com.sun.star.chart2.PieChartType" ?
              (get(ct, "UseRings", "") == "True" ? :doughnutChart : get(ct, "SubPieType", "0") != "0" ? :ofPieChart : :pieChart) :
              get(_O_TAGS, t, :unknown)
        tag in (:pieChart, :barChart, :lineChart, :areaChart) && dim3 && (tag = _O_3D[tag])
        push!(tags, tag)
    end
    return tags
end

_unpref(r) = replace(r, '$' => "")
_nums(s) = [x == "" ? missing : something(tryparse(Float64, x), x) for x in split(s, '|')]
_same_values(ours::Vector, oracle) = length(ours) == length(oracle) &&
    all(((a, b),) -> (a === missing && (b === missing || b == 0.0)) || (a isa Real && b isa Real ? a ≈ b : string(a) == string(b)), zip(ours, oracle))

function check_against_oracle(path, oracle)
    xf = readods(path)
    charts = getCharts(xf)
    @test sort([c.name for c in charts]) == sort(collect(keys(oracle)))
    nseries = 0
    for c in charts
        ch = oracle[c.name]
        haskey(ch, "nodiagram") && continue                     # a kind LibreOffice can't read back
        tags = _oracle_tags(ch)
        mine = c isa OC.ChartEx ? [:histogram] : unique(getChartTypes(c))
        @test (c.name, mine) == (c.name, unique(tags))
        @test c.sheet == ch["chart"][1]["sheet"]
        a = ch["chart"][1]["anchor"]
        a == "page" || @test (c.name, c.from) == (c.name, replace(a, r".*\.\$?([A-Z]+)\$?(\d+)" => s"\1\2"))
        # the title, as LibreOffice reads it
        t = get(ch, "title", nothing)
        want = t === nothing ? nothing : join((t[1]["run$k"] for k in 0:20 if haskey(t[1], "run$k")), "")
        @test (c.name, OC.getChartTitle(c)) == (c.name, want === nothing ? nothing : replace(want, "\\n" => "\n"))
        :stockChart in tags && continue                        # ODF splits a candle into one series per role
        series = getChartSeries(c)
        oser = get(ch, "series", Dict{String,String}[])
        @test (c.name, length(series)) == (c.name, length(oser))
        # the oracle's sequences, series by series
        seqs = Vector{Vector{Dict{String,String}}}()
        for l in ch["__lines"]
            l[1] == "series" && push!(seqs, Dict{String,String}[])
            l[1] == "seq" && !isempty(seqs) && push!(seqs[end], l[2])
        end
        cats = [ax for ax in get(ch, "axis", Dict{String,String}[]) if ax["dim"] == "0" && ax["idx"] == "0"]
        for (s, sq) in zip(series, seqs)
            nseries += 1
            byrole = Dict(get(q, "role", "") => q for q in sq)
            v = get(byrole, "values-y", get(byrole, "values-last", nothing))
            if v !== nothing && s.values !== nothing && !isempty(v["range"])
                @test (c.name, s.values.ref) == (c.name, _unpref(v["range"]))
                @test _same_values(s.values.data, _nums(v["data"]))
            end
            if haskey(byrole, "values-x")
                @test (c.name, s.categories === nothing ? nothing : s.categories.ref) == (c.name, _unpref(byrole["values-x"]["range"]))
            elseif !isempty(cats) && haskey(cats[1], "categories") && !isempty(cats[1]["categories"]) && s.charttype !== :histogram
                @test (c.name, s.categories === nothing ? nothing : s.categories.ref) == (c.name, _unpref(cats[1]["categories"]))
            end
            haskey(byrole, "values-size") && @test (c.name, s.bubble_sizes.ref) == (c.name, _unpref(byrole["values-size"]["range"]))
            # the name: a label cell's text, or a literal
            if v !== nothing && haskey(v, "labeldata")
                lab = get(v, "label", "")
                if startswith(lab, "\"")
                    @test (c.name, s.name) == (c.name, lab[2:end-1])
                elseif !isempty(lab)
                    @test (c.name, s.name) == (c.name, v["labeldata"])
                end
            end
        end
    end
    return nseries
end

# The oracle's lines in order, kept with the chart (for series and their sequences).
function _oracle_charts_lines(name)
    out = _oracle_charts(name)
    cur = nothing
    for l in eachline(IOBuffer(_chart_oracle(name)))
        f = split(l, '\t')
        kv = Dict{String,String}()
        for x in f[2:end]
            p = split(x, "=", limit = 2)
            length(p) == 2 && (kv[p[1]] = p[2])
        end
        if f[1] == "chart"
            cur = out[kv["object"]]
            cur["__lines"] = Any[]
        elseif cur !== nothing
            push!(cur["__lines"], (f[1], kv))
        end
    end
    return out
end

@testset "LibreOffice's own charts, read as its API reads them" begin
    n = check_against_oracle(_ch("lo-charts-own.ods"), _oracle_charts_lines("own.tsv"))
    @test n > 150
end

@testset "LibreOffice's import of XLSX.jl's charts, read as its API reads them" begin
    n = check_against_oracle(_ch("lo-charts-import.ods"), _oracle_charts_lines("import.tsv"))
    @test n > 80
end

@testset "chart handles, lookups and the data table" begin
    xf = readods(_ch("lo-charts-ops-base.ods"))
    @test length(getCharts(xf)) == 9
    @test length(getCharts(xf["Data"])) == 8 && length(getCharts(xf["Other"])) == 1
    c = getChart(xf, "opt_plain")
    @test c isa OC.Chart && getChartSchema(c) === :c && c.rId === nothing
    @test c == getChart(xf["Data"], "opt_plain/content.xml") && hash(c) == hash(getChart(xf, "opt_plain"))
    @test_throws OpenDocumentSpreadsheets.ODSError getChart(xf["Other"], "opt_plain")
    @test getChart(xf, "opt_anchor_cell").from == "K46" && getChart(xf, "opt_anchor_cell").to == "N57"
    @test getChartType(c) === :barChart && OC.getChartTitle(c) === nothing
    t = getChartData(c)
    @test t.column_labels == [:categories, :North, :South]
    @test t.data[1] == ["Jan", "Feb", "Mar", "Apr", "May", "Jun"] && t.data[2] == [13.0, 23.0, 33.0, 43.0, 53.0, 63.0]
    # XY: each series' x values; bubble: sizes
    t = getChartData(xf, "opt_bubble")
    @test t.column_labels == [:categories, :X, :X_size]           # one series shares its x values
    @test t.data[3] == [1.5, 3.0, 4.5, 6.0, 7.5, 9.0]
    r = getChartRanges(xf, "opt_bubble")[1]
    @test string(r.categories) == "Data.B2:B7" && string(r.values) == "Data.E2:E7" && string(r.bubble_sizes) == "Data.F2:F7"
    @test length(getChartRanges(xf["Other"])) == 1
    s = getChartSeries(c)[1]
    @test s.values.kind === :num && s.categories.kind === :str && s.name_ref.data == ["North"]
    @test iserror(s.values) == falses(6) && geterror(s.values, 2) == "" && s.values.format_code == "General"
    @test s.raw isa OpenDocumentSpreadsheets.XML.Node
end

@testset "charts read after edits and operations" begin
    lo = _lo_chart_ops()
    for op in ("ins_row_5", "del_col_B", "rename", "del_data", "copy_data", "edit")
        xf = openods(_ch("lo-charts-ops-base.ods"); mode = "rw")
        _CHART_OPS[op](xf)
        # every chart's values as LibreOffice's object holds them after the operation
        want = sort([filter(a -> startswith(a, "values-cell-range-address="), x[4]) for x in lo[op]])
        got = String[]
        mine = sort([begin
            doc = OC._doc(c)
            ["values-cell-range-address=" * OC._get(s, "chart:values-cell-range-address") for s in OC._series_nodes(doc)]
        end for c in getCharts(xf)])
        @test (op, mine) == (op, want)
        if op == "edit"
            @test getChartSeries(getChart(xf, "opt_plain"))[1].values.data[2] == 99.0    # the cells now
        end
        if op == "copy_data"
            cs = getCharts(xf["Data_2"])
            @test length(cs) == 8 && all(c -> startswith(c.name, "Object "), cs)
            @test getChartSeries(cs[1])[1].values.ref == "Data.B2:B7"         # a copy points at its source (F-083)
        end
    end
end

@testset "flat files and chart frames moved by deletes" begin
    xf = readods(_ch("lo-charts-flat-cf.fods"))
    cs = getCharts(xf)
    @test [c.name for c in cs] == ["Object 1", "Object 2"]
    @test getChartSeries(cs[1])[1].values.ref == "Data.B2:B7"
    xf = openods(_ch("lo-charts-ops-base.ods"); mode = "rw")
    deleteRows(xf["Data"], 46)                       # the anchor row of a resizing chart: it stays in K46
    c = getChart(xf, "opt_anchor_cell")
    @test (c.from, c.to) == ("K46", "N56")
    deleteRows(xf["Data"], 40:60)                    # now all its cells: it goes (F-083)
    @test !any(c -> c.name == "opt_anchor_cell", getCharts(xf))
    @test isempty(getCharts(newods()))
end

# What the REPL shows (issue #1 and its audit): sizes without a read first, and compact forms of the
# types that printed their internals (the sheet store, XML nodes, Dicts, Union-typed rows).

const _D = OpenDocumentSpreadsheets
const _C = OpenDocumentSpreadsheets.Charts
_plain(x) = sprint(show, MIME"text/plain"(), x; context = :limit => true)
_line(x) = sprint(show, x)

@testset "rows and iterators read nothing and stay short" begin
    ws = readods(joinpath(DATA, "lo-values.ods"))[1]
    @test _line(eachrow(ws)) == "WorksheetRows(\"V\", 78 rows)"
    @test _line(eachrow(openods(joinpath(DATA, "lo-values.ods"); enable_cache = false)[1])) == "SheetRowStreamIterator(\"V\")"
    xf = newods(); sh = xf[1]
    sh["A1"] = "Name"; sh["B1"] = "Score"; sh["A2"] = "Ann"; sh["B2"] = 9.5
    @test _line(eachtablerow(sh)) == "TableRowIterator(2 columns: :Name, :Score; data from row 2)"
    @test _line(first(eachtablerow(sh))) == "TableRow 1: (Name = \"Ann\", Score = 9.5)"
    @test length(_plain(eachtablerow(ws))) < 200 && length(_plain(collect(eachtablerow(ws))[1:2])) < 400
end

@testset "cell formats" begin
    xf = newods(); sh = xf[1]
    setFont(sh, "A1"; bold = true, color = "FF0000", size = 14)
    f = _line(_D.getFont(sh, "A1"))
    @test startswith(f, "CellFont(\"") && occursin("b, ", f) && occursin("sz = 14", f) && !occursin("Dict", f)
    @test occursin("\n  sz = 14", _plain(_D.getFont(sh, "A1")))
    @test _line(_D.getBorder(sh, "B1")) == "CellBorder(\"Default\": nothing set)"
    @test _line(_D.getFill(sh, "B1")) == "CellFill(\"Default\": patternType = none)"
    @test _line(_D.getAlignment(sh, "B1")) == "CellAlignment(nothing set)"
    setAlignment(sh, "C1"; horizontal = "center")
    @test _line(_D.getAlignment(sh, "C1")) == "CellAlignment(horizontal = center)"
    @test _line(_D.getFormat(sh, "B1")) == "CellFormat(\"General\")"
end

@testset "errors show the name users catch" begin
    @test _line(_D.ODSError("boom")) == "ODSError(\"boom\")"
    @test startswith(sprint(showerror, try newods()["nope"] catch e; e end), "ODSError: ")
end

@testset "getters' rows print as plain NamedTuples" begin
    xf = newods(); sh = xf[1]
    addComment(sh, "A1", "hi"; author = "Ann")
    addHyperlink(sh, "B1"; url = "https://example.org")
    addDataValidation(sh, "C1"; type = :whole, operator = :between, formula1 = "1", formula2 = "9")
    for rows in (_D.getComments(sh), _D.getHyperlinks(sh), _D.getDataValidations(sh))
        s = _plain(rows)
        @test startswith(s, "1-element Vector{NamedTuple}:\n (sheet = \"Sheet1\"") && !occursin("@NamedTuple", s)
    end
    @test startswith(_line(_D.getComment(sh, "A1")), "(sheet = \"Sheet1\", ref = \"A1\", author = \"Ann\", text = \"hi\"")
end

@testset "charts: compact, never an XML node" begin
    xf = openods(joinpath(DATA, "charts", "lo-charts-own.ods"))
    ch = _C.getCharts(xf[1])[1]
    @test _line(ch) == "Chart(\"tpl_Area\" on \"Data\" at J1:M12)"
    @test _plain(ch) == "Chart \"tpl_Area\" on sheet \"Data\" at J1:M12\n  title: \"Area\"\n  type: areaChart\n  series: 2\n" *
                        "    [1] North - Data.B2:B7 (6 pts)\n    [2] South - Data.C2:C7 (6 pts)"
    @test _line(_C.getChartSeries(ch)[1]) == "ChartSeries(North, areaChart)"
    @test _line(_C.getChartSeries(ch)[1].values) == "ChartRef(Data.B2:B7, 6 pts)"
    @test _line(_C.getChartGroups(ch)[1]) == "ChartGroup(:areaChart, axes [1, 2])"
    @test _line(_C.getChartAxes(ch)[1]) == "ChartAxis(:catAx, id 1, bottom)"
    @test _line(_C.getSeriesFill(ch, 1)) == "Effective{DrawingFill}(DrawingFill(solid, #004586) from series shape)"
    @test _line(_C.getSeriesShapeProps(ch, 1)) == "DrawingShapeProps(fill solid, no line)"
    @test startswith(_plain(_C.getChartRanges(ch)), "2-element Vector{NamedTuple}:\n (idx = 0, name = \"North\"")
    for x in (_C.getChartSeries(ch), _C.getChartAxes(ch), _C.getChartTitleTextProps(ch), _C.getSeriesLine(ch, 1))
        s = _plain(x)
        @test !occursin("Element <", s) && !occursin("OpenDocumentSpreadsheets.Charts.Drawing", s) && length(s) < 600
    end
    @test _line(_D.TableStyleInfo("TableStyleMedium2", true, false, true, false)) == "TableStyleInfo(TableStyleMedium2, first+rows)"
end

# Rich text (D-088, F-087): XLSX.jl's RichTextRun and RichTextString written as LibreOffice keeps them
# and read back with getRichTextString; LibreOffice's own rich text (experiment 040 part A) and its import of
# XLSX.jl's (part B); through edits and operations; LibreOffice reading ours; chart titles.

import ZipArchives
using OpenDocumentSpreadsheets: getRichTextString, getFont

const RICH = joinpath(@__DIR__, "..", "data", "richtext")
const O_R = OpenDocumentSpreadsheets
_R(t, a...) = RichTextRun(t, isempty(a) ? nothing : Pair{Symbol,Any}[a...])
_runs(g) = g === nothing ? nothing : [(r.text, O_R._norm_atts(r.atts)) for r in g.runs]

const _RICH_CASES = [
    RichTextString(_R("plain "), _R("bold", :bold => true)),
    RichTextString(_R("H"), _R("2", :vertAlign => "subscript"), _R("O")),
    RichTextString(_R("x"), _R("2", :vertAlign => "superscript")),
    RichTextString(_R("all ", :bold => true, :italic => true, :under => true, :strike => true, :color => "FF0070C0", :size => 14,
                      :name => "Courier New"), _R("then plain")),
    RichTextString(_R("line one\nline "), _R("two", :bold => true)),
    RichTextString(_R("first", :bold => true), _R("\nsecond")),
    RichTextString(_R("  lead"), _R("  mid  ", :bold => true), _R("trail  ")),
    RichTextString(_R("a < b & "), _R("c > d", :italic => true, :color => "red")),
    RichTextString(_R("π ≈ "), _R("3.14", :size => 10.5), _R(" ✓")),
]

@testset "RichTextRun and RichTextString" begin
    E = OpenDocumentSpreadsheets.ODSError
    @test_throws E RichTextRun("")
    @test_throws E RichTextRun("x", Pair{Symbol,Any}[:shadow => true])
    @test_throws E RichTextRun("x", Pair{Symbol,Any}[:color => "notacolour"])
    @test_throws E RichTextRun("x", Pair{Symbol,Any}[:vertAlign => "up"])
    @test_throws E RichTextRun("x", Pair{Symbol,Any}[:size => 0])
    @test_throws E RichTextString(RichTextRun[])
    rt = RichTextString(_R("Water is H"), _R("2", :vertAlign => "subscript"), _R("O!"))
    @test rt.text == "Water is H2O!" && String(rt) == "Water is H2O!" && length(rt) == 13 && rt isa AbstractString
    @test _R("a", :color => "red") == _R("a", :color => "FFFF0000") && _R("a", :bold => 1) == _R("a", :bold => true)
    @test hash(_R("a", :size => 10)) == hash(_R("a", :size => 10.0))
    @test occursin("containing 3 runs", sprint(show, MIME"text/plain"(), rt))
end

@testset "rich text written and read back" begin
    xf = newods("Rich"); ws = xf["Rich"]
    for (k, v) in enumerate(_RICH_CASES)
        ws[k, 1] = v
    end
    @test all(k -> getRichTextString(ws, k, 1) == _RICH_CASES[k], eachindex(_RICH_CASES))
    @test ws[1, 1] == "plain bold" && ws[5, 1] == "line one\nline two"
    @test getRichTextString(xf, "Rich!A2") == _RICH_CASES[2] && getRichTextString(ws, "A3") == _RICH_CASES[3]
    # runs without attributes: plain text; one run: plain text and the cell's font, as XLSX.jl writes it
    ws["B1"] = RichTextString(_R("just "), _R("text"))
    @test getRichTextString(ws, "B1") === nothing && ws["B1"] == "just text"
    ws["B2"] = RichTextString(_R("single", :bold => true, :color => "FF0000", :size => 12))
    @test getRichTextString(ws, "B2") === nothing && ws["B2"] == "single"
    f = getFont(ws, "B2").font
    @test haskey(f, "b") && f["color"]["rgb"] == "FFFF0000" && f["sz"]["val"] == "12"
    ws["B3"] = RichTextString(_R("e", :vertAlign => "superscript"))     # a cell style can't: a span
    @test getRichTextString(ws, "B3") == RichTextString(_R("e", :vertAlign => "superscript"))
    # numbers, empty cells and plain text have none
    ws["C1"] = 3; ws["C2"] = "plain"
    @test getRichTextString(ws, "C1") === nothing && getRichTextString(ws, "C2") === nothing && getRichTextString(ws, "Z99") === nothing
    # a new value drops the runs, as in LibreOffice
    ws["B3"] = "overwritten"
    @test getRichTextString(ws, "B3") === nothing
    # LibreOffice's form: one text style per set of properties, only the run's attributes
    mktempdir() do dir
        p = joinpath(dir, "r.ods"); f = joinpath(dir, "r.fods")
        writeods(p, xf); writeods(f, xf)
        t = String(ZipArchives.zip_readentry(ZipArchives.ZipReader(read(p)), "content.xml"))
        @test occursin("<text:p>plain <text:span text:style-name=\"TR1\">bold</text:span></text:p>", t)
        @test occursin("<style:style style:name=\"TR1\" style:family=\"text\"><style:text-properties fo:font-weight=\"bold\" style:font-weight-asian=\"bold\" style:font-weight-complex=\"bold\"/></style:style>", t)
        @test occursin("style:text-position=\"sub 58%\"", t) && occursin("<text:p>line one</text:p><text:p>line ", t)
        @test count("style:family=\"text\"", t) == length(unique([O_R._run_props(xf.styles, r) for v in _RICH_CASES for r in v.runs if r.atts !== nothing]))
        for path in (p, f)
            b = readods(path)["Rich"]
            @test all(k -> getRichTextString(b, k, 1) == _RICH_CASES[k], eachindex(_RICH_CASES))
        end
        if lo_ok()
            out = joinpath(dir, "lo")
            lo_convert(p, "ods"; outdir = out, profile = lo_profile_url(joinpath(dir, "profile")))
            lo = readods(joinpath(out, "r.ods"))["Rich"]
            for (k, v) in enumerate(_RICH_CASES)
                @test (k, _runs(getRichTextString(lo, k, 1))) == (k, _runs(v))
            end
        end
    end
end

@testset "LibreOffice's own rich text (experiment 040 part A)" begin
    ws = readods(joinpath(RICH, "lo-rich-own.fods"))["Rich"]
    want = Dict("bold" => [("plain ", nothing), ("bold", :bold => true)], "italic" => [("plain ", nothing), ("italic", :italic => true)],
                "under" => [("plain ", nothing), ("under", :under => true)], "strike" => [("plain ", nothing), ("strike", :strike => true)],
                "superscript" => [("x", nothing), ("2", :vertAlign => "superscript")],
                "subscript" => [("H", nothing), ("2", :vertAlign => "subscript"), ("O", nothing)],
                "color" => [("plain ", nothing), ("red", :color => "FFFF0000")], "size" => [("plain ", nothing), ("big", :size => 16.0)],
                "name" => [("plain ", nothing), ("arial", :name => "Arial")],
                "cellsize_bold" => [("big plain then ", nothing), ("bold", :bold => true)],     # the cell's 14 pt is the cell's
                "newline" => [("line one\nline ", nothing), ("two", :bold => true)])
    for k in 1:12
        nm = ws[k, 1]
        haskey(want, nm) || continue
        expect = RichTextString([_R(t, (a === nothing ? () : (a,))...) for (t, a) in want[nm]])
        @test (nm, getRichTextString(ws, k, 2)) == (nm, expect)
    end
    @test getRichTextString(ws, 11, 2) === nothing          # only a smaller height: no attribute of XLSX.jl's
end

@testset "LibreOffice's import of XLSX.jl's rich text (experiment 040 part B)" begin
    xf = openods(joinpath(RICH, "lo-rich-import.ods"); mode = "rw")
    ws = xf["Rich"]
    g = getRichTextString(ws, 2, 2)                  # bold: the import spells out the run's whole font
    @test _runs(g) == [("plain ", Dict{Symbol,Any}()), ("bold", Dict{Symbol,Any}(:bold => true, :name => "Cambria", :size => 11.0))]
    @test getRichTextString(ws, 1, 2) === nothing    # runs without attributes: plain text
    @test getRichTextString(ws, 21, 2) === nothing   # a single run: plain text, the cell's font
    @test [r.text for r in getRichTextString(ws, 18, 2).runs] == ["line one\nline ", "two"]
    @test getRichTextString(ws, 23, 2).runs[2].atts[:bold] && ws[23, 2] == "a < b & c > d"
    # after an insert above, and a restyle that leaves the text (D-071), its runs are still the cell's
    insertRows(ws, 1)
    setFont(ws, "B3"; size = 20)
    @test getRichTextString(ws, 3, 2) == g
    # a new value drops them
    ws["B4"] = "new"
    @test getRichTextString(ws, 4, 2) === nothing
    mktempdir() do dir
        p = joinpath(dir, "i.ods"); writeods(p, xf)
        b = readods(p)["Rich"]
        @test getRichTextString(b, 3, 2) == g && getRichTextString(b, 4, 2) === nothing
        @test getRichTextString(b, 8, 2) == getRichTextString(readods(joinpath(RICH, "lo-rich-import.ods"))["Rich"], 7, 2)
    end
end

@testset "rich text through operations" begin
    xf = newods("S"); ws = xf["S"]
    ws["B2"] = _RICH_CASES[1]
    insertRows(ws, 1; count = 2); insertColumns(ws, 1)
    @test getRichTextString(ws, "C4") == _RICH_CASES[1]
    c = copysheet!(ws, "S2")
    @test getRichTextString(c, "C4") == _RICH_CASES[1]
    sortRows = OpenDocumentSpreadsheets.getcell(ws, "C4")
    @test sortRows.value == "plain bold"
end

@testset "rich chart titles" begin
    OCR = OpenDocumentSpreadsheets.Charts
    xf = newods("Data"); ws = xf["Data"]
    for i in 1:4; ws[i, 1] = "m$i"; ws[i, 2] = i; end
    title = RichTextString(_R("Rich ", :bold => true), _R("title", :italic => true, :color => "FF0000"))
    c = OCR.addChart(ws, :column; anchor = "D1:J15", title = title, xtitle = "Months")
    OCR.addSeries(c, "B1:B4"; categories = "A1:A4")
    OCR.setAxisTitleText(c, :y, RichTextString(_R("£"), _R("k", :vertAlign => "superscript", :size => 9)))
    tr(t) = [(r.text, r.props === nothing ? nothing : (r.props.bold, r.props.italic, r.props.size,
              r.props.fill === nothing ? nothing : r.props.fill.fgcolor.rgb)) for p in t.paragraphs for r in p.runs]
    @test tr(OCR.getChartTitleText(c)) == [("Rich ", (true, nothing, nothing, nothing)), ("title", (nothing, true, nothing, "FF0000"))]
    @test OCR.getChartTitle(c) == "Rich title" && OCR.getAxisTitle(c, :x) == "Months"
    y = OCR.getAxisTitleText(c, :y).paragraphs[1].runs
    @test y[2].text == "k" && y[2].props.size == 9 && y[2].props.baseline > 0
    # a DrawingText's run formatting is kept, and LibreOffice's refusals are errors
    dt = OCR.getChartTitleText(c)
    OCR.setChartTitleText(c, dt)
    @test tr(OCR.getChartTitleText(c)) == tr(dt)
    mktempdir() do dir
        p = joinpath(dir, "c.ods"); writeods(p, xf)
        b = OCR.getCharts(readods(p))[1]
        @test tr(OCR.getChartTitleText(b)) == tr(dt)
        if lo_ok()
            out = joinpath(dir, "lo")
            lo_convert(p, "ods"; outdir = out, profile = lo_profile_url(joinpath(dir, "profile")))
            lc = OCR.getCharts(readods(joinpath(out, "c.ods")))[1]
            @test tr(OCR.getChartTitleText(lc)) == tr(dt)
            @test OCR.getAxisTitleText(lc, :y).paragraphs[1].runs[2].props.baseline > 0
        end
    end
end

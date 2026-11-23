# Printing (phase 5 step 10; D-063, F-055): page setup, margins, print options, print areas and
# titles, headers and footers, against LibreOffice's import of XLSX.jl's file (experiment 026,
# test/data/printing/), in saved files and through LibreOffice. XLSX.jl's printing cases are ported
# where they apply.

using OpenDocumentSpreadsheets: getPageSetup, getPageMargins, getPrintOptions, getPrintArea, getPrintTitles, getHeaderFooter,
    ODSError, insertRows, renamesheet!, copysheet!, groupRows, getRowOutlineLevel
using OpenDocumentSpreadsheets.SheetCore: CellRange, CellRef

const PRINTDIR = joinpath(DATA, "printing")
const LOPRINT = joinpath(PRINTDIR, "lo-print-xlsx-import.fods")

# A sheet's page-layout properties in a saved flat file, read without OpenDocumentSpreadsheets.
function layout_props(path, sheet)
    f = read(path, String)
    attrs(t) = Dict(m.captures[1] => m.captures[2] for m in eachmatch(r"([\w:-]+)=\"([^\"]*)\"", t))
    t = attrs(match(Regex("<table:table table:name=\"" * sheet * "\"[^>]*>"), f).match)
    st = attrs(match(Regex("<style:style style:name=\"" * t["table:style-name"] * "\" style:family=\"table\"[^>]*>"), f).match)
    mp = match(Regex("<style:master-page style:name=\"" * st["style:master-page-name"] * "\"[^>]*>"), f).match
    pl = attrs(mp)["style:page-layout-name"]
    lay = match(Regex("<style:page-layout style:name=\"" * pl * "\".*?</style:page-layout>", "s"), f).match
    return attrs(match(r"<style:page-layout-properties[^>]*>", lay).match)
end

@testset "LibreOffice's import of XLSX.jl's printing, read (experiment 026)" begin
    xf = readods(LOPRINT)
    ps(n) = getPageSetup(xf[n])
    @test ps("Plain") == (orientation = :portrait, paperSize = nothing, scale = nothing, fitToWidth = nothing, fitToHeight = nothing)
    @test ps("Landscape").orientation === :landscape && ps("Landscape").paperSize == 1
    @test [ps(n).paperSize for n in ("A4", "Letter", "Legal", "A3", "A5", "B5", "Tabloid", "Executive", "B4", "Paper70")] ==
          [9, 1, 5, 8, 11, 13, 3, 7, 12, 70]
    @test ps("Ledger").paperSize == 4                               # tabloid turned, as the import writes it
    @test ps("LandA4") == (orientation = :landscape, paperSize = 9, scale = nothing, fitToWidth = nothing, fitToHeight = nothing)
    @test ps("Scale80").scale == 80 && ps("FitW1").fitToWidth == 1 && ps("FitW1").fitToHeight == 0
    @test ps("FitW2H3").fitToWidth == 2 && ps("FitW2H3").fitToHeight == 3 && ps("FitW2H3").scale === nothing
    m = getPageMargins(xf["Margins"])
    @test (m.left, m.right, m.top, m.bottom) == (0.5, 1.25, 1.0, 0.25)       # no header shown: its distance isn't kept
    @test getPageMargins(xf["HFMargins"]) == (left = 0.7, right = 0.7, top = 1.5, bottom = 1.2, header = 0.5, footer = 0.6)
    @test getPageMargins(xf["HFCenter"]) == (left = 0.7, right = 0.7, top = 0.75, bottom = 0.75, header = 0.3, footer = 0.3)
    @test getPrintOptions(xf["Grid"]).gridLines && getPrintOptions(xf["Headings"]).headings && !getPrintOptions(xf["Plain"]).gridLines
    @test getPrintOptions(xf["Centered"]) == (gridLines = false, headings = false, horizontalCentered = true, verticalCentered = true)
    @test getPrintOptions(xf["CenterH"]).horizontalCentered && !getPrintOptions(xf["CenterH"]).verticalCentered && getPrintOptions(xf["CenterV"]).verticalCentered
    @test getPrintArea(xf["Area"]) == CellRange("B2:D8") && getPrintArea(xf["Plain"]) === nothing
    @test getPrintArea(xf["Areas"]) == OpenDocumentSpreadsheets.NonContiguousRange("Areas", Union{CellRef,CellRange}[CellRange("A1:B4"), CellRange("D6:E9")])
    @test getPrintTitles(xf["TitleRows"]) == (rows = 1:2, cols = nothing) && getPrintTitles(xf["TitleCols"]) == (rows = nothing, cols = 1:2)
    @test getPrintTitles(xf["TitleBoth"]) == (rows = 2:2, cols = 1:1) && getPrintTitles(xf["Plain"]) === nothing
    hf(n) = getHeaderFooter(xf[n])
    @test hf("Plain") === nothing
    @test hf("HFCenter").header.center == "Report" && hf("HFCenter").footer.center == "Page &P of &N"
    @test hf("HFSections").header == (left = "L &D", center = "C &T", right = "R &A")
    @test hf("HFSections").footer == (left = "&F", center = nothing, right = "&Z&F")
    @test hf("HFFonts").header.center == "&\"Arial,Bold\"&14Big&\"Calibri,Italic\"&KFF0000 red"
    @test hf("HFFonts").footer.left == "&Uunder&U &Sstrike&S &X2"          # (XLSX.jl gave "&Uunder&U &Sstrike&S &X2&X")
    @test hf("HFFirst").differentFirst && hf("HFFirst").firstHeader.center == "First" && hf("HFFirst").header.center == "All"
    @test hf("HFEven").differentOddEven && hf("HFEven").evenHeader.center == "Even" && hf("HFEven").evenFooter.center == "e"
    @test hf("HFAmp").header.center == "A && B"
end

@testset "printing written as LibreOffice's import writes it (experiment 026)" begin
    calls = Pair{String,Function}[
        "Landscape" => ws -> setPageSetup(ws; orientation = :landscape),
        "A4" => ws -> setPageSetup(ws; paperSize = :A4), "Legal" => ws -> setPageSetup(ws; paperSize = :legal),
        "B5" => ws -> setPageSetup(ws; paperSize = :B5), "Paper70" => ws -> setPageSetup(ws; paperSize = 70),
        "Ledger" => ws -> setPageSetup(ws; paperSize = :ledger),
        "LandA4" => ws -> setPageSetup(ws; orientation = :landscape, paperSize = :A4),
        "Scale80" => ws -> setPageSetup(ws; scale = 80), "FitW2H3" => ws -> setPageSetup(ws; fitToWidth = 2, fitToHeight = 3),
        "Margins" => ws -> setPageMargins(ws; left = 0.5, right = 1.25, top = 1.0, bottom = 0.25, header = 0.2, footer = 0.4),
        "Grid" => ws -> setPrintOptions(ws; gridLines = true), "Headings" => ws -> setPrintOptions(ws; headings = true),
        "Centered" => ws -> setPrintOptions(ws; horizontalCentered = true, verticalCentered = true),
        "HFMargins" => ws -> (setHeaderFooter(ws; header = "H", footer = "F");
                              setPageMargins(ws; left = 0.7, right = 0.7, top = 1.5, bottom = 1.2, header = 0.5, footer = 0.6)),
    ]
    keys_ = ("fo:page-width", "fo:page-height", "style:print-orientation", "style:scale-to", "style:scale-to-X", "style:scale-to-Y",
             "style:print", "style:table-centering", "fo:margin-left", "fo:margin-right", "fo:margin-top", "fo:margin-bottom")
    # from LibreOffice's own sheet (whose page style is Excel's defaults, as the import makes it)
    xf = openods(LOPRINT; mode = "rw")
    for (n, f) in calls
        f(xf[n])
    end
    p = writeods(joinpath(mktempdir(), "w.fods"), xf)
    cm(v) = (x = OpenDocumentSpreadsheets._length_cm(v); x === nothing ? v : round(x; digits = 2))
    for (n, _) in calls
        got = layout_props(p, n); want = layout_props(LOPRINT, n)
        for k in keys_
            @test cm(get(got, k, nothing)) == cm(get(want, k, nothing)) || (@info "layout" n k get(got, k, nothing) get(want, k, nothing); false)
        end
    end
    r = readods(p)
    @test getPageMargins(r["HFMargins"]) == getPageMargins(readods(LOPRINT)["HFMargins"])
    @test getHeaderFooter(r["HFMargins"]).footer.center == "F"
end

@testset "printing: XLSX.jl's cases and errors" begin
    xf = newods("S")
    s = xf[1]
    s["A1:F40"] = 1
    setPageSetup(s; orientation = :landscape, paperSize = :A4, fitToWidth = 1)
    @test getPageSetup(s) == (orientation = :landscape, paperSize = 9, scale = nothing, fitToWidth = 1, fitToHeight = 0)
    setPageSetup(s; scale = 75)                                   # scale turns fitting off
    @test getPageSetup(s).scale == 75 && getPageSetup(s).fitToWidth === nothing
    setPageSetup(s; orientation = :portrait)
    @test getPageSetup(s).orientation === :portrait && getPageSetup(s).paperSize == 9
    @test_throws ODSError setPageSetup(s; scale = 50, fitToWidth = 1)
    @test_throws ODSError setPageSetup(s; scale = 5)
    @test_throws ODSError setPageSetup(s; orientation = :sideways)
    @test_throws ODSError setPageSetup(s; paperSize = :A7)
    @test_throws ODSError setPageSetup(s; paperSize = 999)
    @test_throws ODSError setPageSetup(s; fitToWidth = -1)
    setPageMargins(s; left = 0.5, right = 0.5)
    @test getPageMargins(s).left == 0.5 && getPageMargins(s).right == 0.5
    @test_throws ODSError setPageMargins(s; left = -1)
    @test_throws ODSError setPageMargins(s; gutter = 1)
    setPrintOptions(s; gridLines = true, headings = true, verticalCentered = true)
    @test getPrintOptions(s) == (gridLines = true, headings = true, horizontalCentered = false, verticalCentered = true)
    setPrintOptions(s; gridLines = false)
    @test !getPrintOptions(s).gridLines && getPrintOptions(s).headings
    @test_throws ODSError setPrintOptions(s; bogus = true)
    @test_throws ODSError setPrintOptions(s; gridLines = 1)
    setPrintArea(s, "A1:F40")
    @test getPrintArea(s) == CellRange("A1:F40")
    setPrintArea(s, "A1:B4,D6:E9")
    @test getPrintArea(s) isa OpenDocumentSpreadsheets.NonContiguousRange
    addDefinedName(s, "pa", "A2:C3")
    setPrintArea(s, "pa")
    @test getPrintArea(s) == CellRange("A2:C3")
    @test_throws ODSError setPrintArea(s, "A:C")
    @test removePrintArea(s) && !removePrintArea(s) && getPrintArea(s) === nothing
    setPrintTitles(s; rows = 1)
    setPrintTitles(s; cols = "A:B")
    @test getPrintTitles(s) == (rows = 1:1, cols = 1:2)
    @test_throws ODSError setPrintTitles(s)
    @test_throws ODSError setPrintTitles(s; rows = [1, 3])
    @test removePrintTitles(s) && !removePrintTitles(s) && getPrintTitles(s) === nothing
    setPrintTitles(s; rows = 1:2)
    setHeaderFooter(s; header = (center = headerFooterFont(bold = true, size = 14) * "Quarterly report",),
                       footer = (left = "&F", right = "Page " * headerFooterField(:page) * " of " * headerFooterField(:pages)))
    h = getHeaderFooter(s)
    @test h.header.center == "&\"-,Bold\"&14Quarterly report" && h.footer == (left = "&F", center = nothing, right = "Page &P of &N")
    setHeaderFooter(s; firstHeader = "")                         # a blank first page header
    @test getHeaderFooter(s).differentFirst && getHeaderFooter(s).firstHeader === nothing
    setHeaderFooter(s; differentFirst = false, evenFooter = "even")
    @test !getHeaderFooter(s).differentFirst && getHeaderFooter(s).differentOddEven && getHeaderFooter(s).evenFooter.center == "even"
    setHeaderFooter(s; header = "A && B  two  spaces\nline 2")
    @test getHeaderFooter(s).header.center == "A && B  two  spaces\nline 2"
    @test_throws ODSError setHeaderFooter(s; scaleWithDoc = false)    # no LibreOffice counterpart
    @test_throws ODSError setHeaderFooter(s; header = 1)
    @test_throws ODSError setHeaderFooter(s; header = (middle = "x",))
    @test_throws ODSError setHeaderFooter(s; header = (left = "&Cx",))
    @test_throws ODSError setHeaderFooter(s; header = repeat("x", 256))
    @test_throws ODSError setHeaderFooter(s)
    @test headerFooterField(:sheet) == "&A" && headerFooterFont(name = "Arial", bold = true, size = 14) == "&\"Arial,Bold\"&14"
    @test headerFooterFont(italic = true, color = "red") == "&\"-,Italic\"&KFF0000"
    @test_throws ODSError headerFooterField(:bogus)
    @test_throws ODSError headerFooterFont(size = 500)
    @test_throws ODSError setPageSetup(readods(LOPRINT)[1]; scale = 50)
    # saved and read back, zipped and flat; other sheets keep LibreOffice's default page style
    addsheet!(xf, "Other")
    for ext in ("ods", "fods")
        r = readods(writeods(joinpath(mktempdir(), "p.$ext"), xf))
        @test getPageSetup(r["S"]) == getPageSetup(s) && getPageMargins(r["S"]) == getPageMargins(s)
        @test getPrintOptions(r["S"]) == getPrintOptions(s) && getPrintTitles(r["S"]) == (rows = 1:2, cols = nothing)
        @test getHeaderFooter(r["S"]) == getHeaderFooter(s)
        @test getHeaderFooter(r["Other"]).header.center == "&A" && getPageSetup(r["Other"]).paperSize === nothing
        @test r["S"]["F40"] == 1
    end
    removeHeaderFooter(s)
    @test getHeaderFooter(s) === nothing && !removeHeaderFooter(s)
    # titles inside a group, not across one
    groupRows(s, 1:5)
    r = readods(writeods(joinpath(mktempdir(), "g.ods"), xf))
    @test getPrintTitles(r["S"]).rows == 1:2 && getRowOutlineLevel(r["S"], 3) == 1
    groupRows(s, 2:3)
    @test_throws ODSError writeods(joinpath(mktempdir(), "g2.ods"), xf)
end

@testset "a patched save adds a page style and changes only that sheet (D-023)" begin
    orig = read(LOPRINT, String)
    xf = openods(LOPRINT; mode = "rw")
    setPageSetup(xf["Plain"]; orientation = :landscape)
    out = read(writeods(joinpath(mktempdir(), "a.fods"), xf), String)
    table(s, n) = match(Regex("<table:table table:name=\"" * n * "\".*?</table:table>", "s"), s).match
    for n in ("A4", "HFFonts", "TitleBoth", "Area")
        @test table(out, n) == table(orig, n)
    end
    # the Plain sheet's table differs only in its start tag (its table style)
    tp(s) = replace(table(s, "Plain"), r"^<table:table [^>]*>" => "")
    @test tp(out) == tp(orig)
    @test getPageSetup(readods(IOBuffer(out))["Plain"]).orientation === :landscape
    # the old page style is still there, unchanged; the new one is added
    @test occursin(match(r"<style:master-page style:name=\"PageStyle_5f_Plain\".*?</style:master-page>"s, orig).match, out)
    @test occursin("style:display-name=\"PageStyle_Plain\"", out)
    # a print area and titles on a file read, through an insert and a rename
    xf = openods(LOPRINT; mode = "rw")
    setPrintArea(xf["Plain"], "B2:C5")
    setPrintTitles(xf["Plain"]; rows = 1)
    insertRows(xf["Plain"], 1; count = 2)
    renamesheet!(xf["Plain"], "Plain 2")
    r = readods(writeods(joinpath(mktempdir(), "b.fods"), xf))
    @test getPrintArea(r["Plain 2"]) == CellRange("B4:C7") && getPrintTitles(r["Plain 2"]).rows == 3:3
    @test getPrintArea(r["Area"]) == CellRange("B2:D8")
    # a copy keeps its page style
    xf = openods(LOPRINT; mode = "rw")
    setPageSetup(xf["Plain"]; paperSize = :A3)
    c = copysheet!(xf["Plain"], "Copy")
    r = readods(writeods(joinpath(mktempdir(), "c.fods"), xf))
    @test getPageSetup(r["Copy"]).paperSize == 8 && getPageSetup(r["Plain"]).paperSize == 8
    @test read(writeods(joinpath(mktempdir(), "u.fods"), openods(LOPRINT; mode = "rw")), String) == orig
end

@testset "LibreOffice reads the printing settings" begin
    if isempty(SOFFICE) || !isfile(SOFFICE)
        @info "LibreOffice not found; skipping the printing oracle (set ODS_SOFFICE)"
        @test_skip false
    else
        dir = mktempdir()
        profile = lo_profile_url(joinpath(dir, "lo-profile"))
        xf = newods("A"); addsheet!(xf, "B")
        xf["A"]["A1:F30"] = 1
        setPageSetup(xf["A"]; orientation = :landscape, paperSize = :A4, fitToWidth = 1, fitToHeight = 2)
        setPageMargins(xf["A"]; left = 0.5, right = 0.6, top = 1.0, bottom = 0.9, header = 0.4, footer = 0.3)
        setPrintOptions(xf["A"]; gridLines = true, horizontalCentered = true)
        setPrintArea(xf["A"], "B2:D8,F1:F3")
        setPrintTitles(xf["A"]; rows = 1:2, cols = "A")
        setHeaderFooter(xf["A"]; header = (left = "L &D", center = headerFooterFont(name = "Arial", bold = true) * "Title", right = "Page &P of &N"),
                        footer = "&F &A", firstHeader = "First")
        setPageSetup(xf["B"]; scale = 70)
        files = [writeods(joinpath(dir, "new.ods"), xf)]
        pf = openods(LOPRINT; mode = "rw")
        setPageSetup(pf["Plain"]; paperSize = :legal); setPrintArea(pf["Area"], "A1:A3"); removePrintTitles(pf["TitleRows"])
        setHeaderFooter(pf["HFCenter"]; header = (right = "new",))
        push!(files, writeods(joinpath(dir, "patched.fods"), pf))
        run(pipeline(`$SOFFICE -env:UserInstallation=$profile --headless --norestore --convert-to fods --outdir $(joinpath(dir, "lo")) $files`;
                     stdout = devnull, stderr = devnull))
        lo = readods(joinpath(dir, "lo", "new.fods"))
        a = lo["A"]
        @test getPageSetup(a) == getPageSetup(xf["A"]) && getPageMargins(a) == getPageMargins(xf["A"])
        @test getPrintOptions(a) == getPrintOptions(xf["A"]) && getPrintTitles(a) == (rows = 1:2, cols = 1:1)
        @test getPrintArea(a) == getPrintArea(xf["A"])
        h = getHeaderFooter(a)
        @test h.header.left == "L &D" && h.header.right == "Page &P of &N" && occursin("Title", h.header.center)
        @test occursin("Arial,Bold", h.header.center) && h.footer.center == "&F &A" && h.differentFirst && h.firstHeader.center == "First"
        @test getPageSetup(lo["B"]).scale == 70
        lp = readods(joinpath(dir, "lo", "patched.fods"))
        @test getPageSetup(lp["Plain"]).paperSize == 5 && getPrintArea(lp["Area"]) == CellRange("A1:A3")
        @test getPrintTitles(lp["TitleRows"]) === nothing && getHeaderFooter(lp["HFCenter"]).header.right == "new"
        @test getPageSetup(lp["A4"]).paperSize == 9 && getHeaderFooter(lp["HFSections"]).header.right == "R &A"
    end
end

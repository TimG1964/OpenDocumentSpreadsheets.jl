# LibreOffice's own options in XLSX.jl's functions (D-076, F-069): validations' case sensitivity and
# sorted lists, cell protection's hide all and hide when printing, notes' dates, pictures' alt text
# and description, any paper size, fitting to a number of pages, and LibreOffice's print options.
# Fixtures: experiment 034 (test/data/lo-options/lo-options-own.fods, LibreOffice's own forms), and
# those of experiments 030–032.
using Dates
const O_X = OpenDocumentSpreadsheets
using OpenDocumentSpreadsheets: ODSError
const LOX = joinpath(@__DIR__, "..", "data", "lo-options", "lo-options-own.fods")
const LOX_PNG = joinpath(@__DIR__, "..", "data", "images", "red.png")
# A file written to a new temporary path (`.fods` or `.ods`).
_lox_path(xf, ext = "fods") = writeods(joinpath(mktempdir(), "t." * ext), xf)

@testset "LibreOffice's own forms, read (experiment 034)" begin
    own = readods(LOX)["Ext"]
    @test O_X.getCellProtection(own, "A1") == (locked = true, hidden = true, hideAll = true, hidePrint = false)
    @test O_X.getCellProtection(own, "A2") == (locked = true, hidden = false, hideAll = false, hidePrint = true)
    @test O_X.getCellProtection(own, "A3").hideAll                        # hide all on an unlocked cell: stored locked
    ps = O_X.getPageSetup(own)
    @test ps.paperWidth == 20.001 && ps.paperHeight == 25.0 && ps.scaleToPages === Int64(3)
    @test ps.fitToWidth === nothing && ps.scale === nothing && ps.paperSize === nothing
    @test O_X.getPrintOptions(own) == (gridLines = false, headings = false, horizontalCentered = false, verticalCentered = false,
                                       comments = true, formulas = true, zeroValues = false, charts = false, drawings = false, objects = false)
    v = readods(joinpath(@__DIR__, "..", "data", "validation", "lo-validation-own.fods"))["Own"]
    @test O_X.getDataValidation(v, "B18").caseSensitive && !O_X.getDataValidation(v, "B18").sortEntries
    @test O_X.getDataValidation(v, "B12").sortEntries && !O_X.getDataValidation(v, "B12").caseSensitive
    @test !O_X.getDataValidation(v, "B11").sortEntries                    # a hidden list isn't sorted
    n = readods(joinpath(@__DIR__, "..", "data", "links", "lo-links-own.fods"))["Own"]
    @test O_X.getComment(n, "B11").date == DateTime(2026, 11, 23, 16, 3, 6, 869)
    imp = readods(joinpath(@__DIR__, "..", "data", "links", "lo-links-xlsx-import.fods"))
    @test all(c -> c.date === nothing, O_X.getComments(imp))           # the import's notes have `meta:date-string`
    im = O_X.getImages(readods(joinpath(@__DIR__, "..", "data", "images", "lo-images-own.ods"))["Own"])
    @test [(i.from, i.alt, i.description) for i in im if !isempty(i.alt)] == [("B10", "Pic title", "Pic description")]
end

@testset "validations: caseSensitive and sortEntries" begin
    xf = newods("S"); ws = xf["S"]
    a = O_X.addDataValidation(ws, "B1:B3"; values = ["b", "a"], caseSensitive = true, sortEntries = true)
    @test a.caseSensitive && a.sortEntries
    b = O_X.addDataValidation(ws, "C1"; values = ["b", "a"])
    @test !b.caseSensitive && !b.sortEntries
    c = O_X.addDataValidation(ws, "D1"; type = :textLength, operator = :lessThan, formula1 = 3, caseSensitive = true)
    @test c.caseSensitive && !c.sortEntries
    @test_throws ODSError O_X.addDataValidation(ws, "E1"; type = :whole, formula1 = 1, formula2 = 2, sortEntries = true)
    @test_throws ODSError O_X.addDataValidation(ws, "E1"; values = ["a"], dropdown = false, sortEntries = true)
    # rules differing only in these options are separate rules
    O_X.addDataValidation(ws, "F1"; values = ["b", "a"], caseSensitive = true)
    @test length(O_X.getDataValidations(ws)) == 4
    s = read(_lox_path(xf), String)
    @test occursin("table:case-sensitive=\"true\" table:display-list=\"sort-ascending\"", s)
    @test occursin("table:allow-empty-cell=\"true\" table:case-sensitive=\"true\" table:base-cell-address=\"S.D1\"", s)
    @test count("table:case-sensitive", s) == 3
    r = readods(IOBuffer(s))["S"]
    @test [(x.caseSensitive, x.sortEntries) for x in O_X.getDataValidations(r)] == [(true, true), (false, false), (true, false), (true, false)]
    # a patched file keeps them through inserts (the rules are rewritten)
    p = openods(IOBuffer(s); mode = "rw")
    O_X.insertRows(p["S"], 1)
    @test O_X.getDataValidation(p["S"], "B2").sortEntries && O_X.getDataValidation(p["S"], "B2").caseSensitive
    q = readods(_lox_path(p))["S"]
    @test O_X.getDataValidation(q, "B4").sortEntries && O_X.getDataValidation(q, "D2").caseSensitive
end

@testset "cell protection: hideAll and hidePrint" begin
    xf = newods("S"); ws = xf["S"]
    ws["A1"] = 1; ws["A2"] = 2; ws["A3"] = 3
    O_X.setCellProtection(ws, "A1"; hideAll = true)
    @test O_X.getCellProtection(ws, "A1") == (locked = true, hidden = true, hideAll = true, hidePrint = false)
    O_X.setCellProtection(ws, "A1"; locked = false)                    # changes nothing while hide all is set
    @test O_X.getCellProtection(ws, "A1").hideAll && O_X.getCellProtection(ws, "A1").locked
    O_X.setCellProtection(ws, "A1"; hideAll = false, locked = false)   # hide all off: as LibreOffice loads it, formulas hidden
    @test O_X.getCellProtection(ws, "A1") == (locked = false, hidden = true, hideAll = false, hidePrint = false)
    O_X.setCellProtection(ws, "A2"; hidePrint = true)
    @test O_X.getCellProtection(ws, "A2") == (locked = true, hidden = false, hideAll = false, hidePrint = true)
    O_X.setCellProtection(ws, "A2"; hidePrint = false)
    @test !O_X.getCellProtection(ws, "A2").hidePrint
    O_X.setCellProtection(ws, "A3:A5"; locked = false, hidePrint = true)
    @test O_X.getCellProtection(ws, "A5") == (locked = false, hidden = false, hideAll = false, hidePrint = true)
    @test_throws ODSError O_X.setCellProtection(ws, "A1"; hideall = true)
    s = read(_lox_path(xf), String)
    @test occursin("style:print-content=\"true\"", s) && occursin("style:print-content=\"false\"", s)
    r = readods(IOBuffer(s))["S"]
    @test [O_X.getCellProtection(r, "A$i") for i in 1:5] == [O_X.getCellProtection(ws, "A$i") for i in 1:5]
end

@testset "notes: date" begin
    xf = newods("S"); ws = xf["S"]
    t0 = floor(now(Dates.UTC), Second)
    c = O_X.addComment(ws, "A1", "now")
    @test c.date !== nothing && t0 <= c.date <= now(Dates.UTC)
    @test O_X.addComment(ws, "A2", "given"; date = DateTime(2026, 1, 2, 3, 4, 5, 60)).date == DateTime(2026, 1, 2, 3, 4, 5, 60)
    @test O_X.addComment(ws, "A3", "a day"; date = Date(2025, 12, 31)).date == DateTime(2025, 12, 31)
    s = read(_lox_path(xf), String)
    @test occursin("<dc:date>2026-01-02T03:04:05.060</dc:date>", s) && occursin("<dc:date>2025-12-31T00:00:00</dc:date>", s)
    r = readods(IOBuffer(s))["S"]
    @test O_X.getComments(r) == O_X.getComments(ws)
    @test O_X.getComment(r, "A2") == (sheet = "S", ref = "A2", author = "", text = "given", date = DateTime(2026, 1, 2, 3, 4, 5, 60))
end

@testset "pictures: alt and description" begin
    xf = newods("S"); ws = xf["S"]
    a = O_X.addImage(ws, "B2", LOX_PNG; alt = "Red", description = "A red <square> & \"more\"")
    @test a.alt == "Red" && a.description == "A red <square> & \"more\""
    b = O_X.addImage(ws, "D2", LOX_PNG)
    @test b.alt == "" && b.description == ""
    @test_throws ODSError O_X.addImage(ws, "F2", LOX_PNG; inCell = true, alt = "x")
    for fmt in ("ods", "fods")
        r = readods(_lox_path(xf, fmt))["S"]
        nomedia(v) = [(i.sheet, i.from, i.to, i.alt, i.description) for i in v]
        @test nomedia(O_X.getImages(r)) == nomedia(O_X.getImages(ws))
    end
    s = read(_lox_path(xf), String)
    @test occursin("</draw:image><svg:title>Red</svg:title><svg:desc>A red &lt;square&gt; &amp; \"more\"</svg:desc></draw:frame>", s)
    @test O_X.deleteImage(ws, a) == 1 && length(O_X.getImages(ws)) == 1
    # a picture moved by a delete keeps them
    p = openods(IOBuffer(s); mode = "rw")
    O_X.deleteRows(p["S"], 2)
    @test [(i.from, i.alt) for i in O_X.getImages(p["S"])] == [("B2", "Red"), ("D2", "")]
end

@testset "page setup: paperWidth, paperHeight, scaleToPages" begin
    xf = newods("S"); ws = xf["S"]
    O_X.setPageSetup(ws; paperWidth = 20, paperHeight = 25)
    ps = O_X.getPageSetup(ws)
    @test ps.orientation === :portrait && ps.paperWidth == 20.0 && ps.paperHeight == 25.0 && ps.paperSize === nothing
    O_X.setPageSetup(ws; paperWidth = 25, paperHeight = 20)                # wider than high: landscape, as LibreOffice's dialog
    @test O_X.getPageSetup(ws).orientation === :landscape
    O_X.setPageSetup(ws; paperWidth = 8.5, paperHeight = 11, unit = :in, orientation = :landscape)   # swapped to suit
    ps = O_X.getPageSetup(ws; unit = :in)
    @test ps.orientation === :landscape && ps.paperWidth == 11.0 && ps.paperHeight == 8.5 && O_X.getPageSetup(ws).paperSize == 1
    O_X.setPageSetup(ws; paperHeight = 300, unit = :mm)                    # one side: the other kept
    @test O_X.getPageSetup(ws; unit = :mm).paperHeight == 300.0 && O_X.getPageSetup(ws).paperWidth == 27.94
    O_X.setPageSetup(ws; paperSize = :A4, orientation = :portrait)
    @test O_X.getPageSetup(ws).paperWidth == 21.001 && O_X.getPageSetup(ws).paperSize == 9
    @test_throws ODSError O_X.setPageSetup(ws; paperSize = :A4, paperWidth = 20)
    @test_throws ODSError O_X.setPageSetup(ws; paperWidth = -1)
    @test_throws ODSError O_X.setPageSetup(ws; paperWidth = 10, unit = :chars)
    @test_throws ODSError O_X.getPageSetup(ws; unit = :px)
    O_X.setPageSetup(ws; scaleToPages = 3)
    ps = O_X.getPageSetup(ws)
    @test ps.scaleToPages === Int64(3) && ps.scale === nothing && ps.fitToWidth === nothing
    O_X.setPageSetup(ws; fitToWidth = 1)                                   # alternatives: one replaces another
    @test O_X.getPageSetup(ws).scaleToPages === nothing && O_X.getPageSetup(ws).fitToWidth == 1
    O_X.setPageSetup(ws; scaleToPages = 2)
    O_X.setPageSetup(ws; scale = 80)
    @test O_X.getPageSetup(ws).scaleToPages === nothing && O_X.getPageSetup(ws).scale == 80
    @test_throws ODSError O_X.setPageSetup(ws; scaleToPages = 2, scale = 50)
    @test_throws ODSError O_X.setPageSetup(ws; scaleToPages = 0)
    O_X.setPageSetup(ws; scaleToPages = 4)
    r = readods(_lox_path(xf))["S"]
    @test O_X.getPageSetup(r) == O_X.getPageSetup(ws)
end

@testset "print options: LibreOffice's" begin
    xf = newods("S"); ws = xf["S"]
    po = O_X.getPrintOptions(ws)
    @test (po.comments, po.formulas, po.zeroValues, po.charts, po.drawings, po.objects) == (false, false, true, true, true, true)
    O_X.setPrintOptions(ws; comments = true, formulas = true, zeroValues = false, charts = false, gridLines = true)
    po = O_X.getPrintOptions(ws)
    @test (po.gridLines, po.comments, po.formulas, po.zeroValues, po.charts, po.drawings, po.objects) == (true, true, true, false, false, true, true)
    @test_throws ODSError O_X.setPrintOptions(ws; annotations = true)
    @test_throws ODSError O_X.setPrintOptions(ws; comments = 1)
    s = read(_lox_path(xf), String)
    @test occursin("style:print=\"annotations drawings formulas grid objects\"", s)
    @test O_X.getPrintOptions(readods(IOBuffer(s))["S"]) == po
end

@testset "LibreOffice reads the options" begin
    if isempty(SOFFICE) || !isfile(SOFFICE)
        @info "LibreOffice not found; skipping the options oracle (set ODS_SOFFICE)"
        @test_skip false
    else
        dir = mktempdir()
        profile = lo_profile_url(joinpath(dir, "lo-profile"))
        function opts!(ws)
            O_X.addDataValidation(ws, "B1:B3"; values = ["b", "a"], caseSensitive = true, sortEntries = true)
            O_X.addDataValidation(ws, "B5"; type = :textLength, operator = :lessThan, formula1 = 5, caseSensitive = true)
            O_X.setCellProtection(ws, "A1"; hideAll = true); O_X.setCellProtection(ws, "A2"; hidePrint = true)
            O_X.addComment(ws, "C1", "dated"; author = "Ann", date = DateTime(2026, 1, 2, 3, 4, 5))
            O_X.addImage(ws, "D4", LOX_PNG; alt = "Red", description = "A red square")
            O_X.setPageSetup(ws; paperWidth = 25, paperHeight = 20, scaleToPages = 3)
            O_X.setPrintOptions(ws; comments = true, formulas = true, zeroValues = false, objects = false)
        end
        xf = newods("S"); ws = xf["S"]; ws["A1"] = 1; ws["A2"] = 2
        opts!(ws)
        a = writeods(joinpath(dir, "new.ods"), xf)
        b = writeods(joinpath(dir, "newflat.fods"), xf)
        p = openods(joinpath(@__DIR__, "..", "data", "validation", "lo-validation-own.fods"); mode = "rw")
        opts!(p["Own"])
        c = writeods(joinpath(dir, "own.fods"), p)
        run(pipeline(`$SOFFICE -env:UserInstallation=$profile --headless --norestore --convert-to fods --outdir $(joinpath(dir, "lo")) $a $b $c`;
                     stdout = devnull, stderr = devnull))
        seen(x) = ([(v.caseSensitive, v.sortEntries) for v in O_X.getDataValidations(x) if string(v.range) in ("B1:B3", "B5")],
                   O_X.getCellProtection(x, "A1"), O_X.getCellProtection(x, "A2"), O_X.getComment(x, "C1").date,
                   [(i.alt, i.description) for i in O_X.getImages(x) if i.from == "D4"], O_X.getPrintOptions(x),
                   (O_X.getPageSetup(x).orientation, O_X.getPageSetup(x).scaleToPages))
        for (f, sheet, orig) in (("new.fods", "S", ws), ("newflat.fods", "S", ws), ("own.fods", "Own", p["Own"]))
            lo = readods(joinpath(dir, "lo", f))[sheet]
            @test seen(lo) == seen(orig)
            @test abs(O_X.getPageSetup(lo).paperWidth - 25) < 0.01 && abs(O_X.getPageSetup(lo).paperHeight - 20) < 0.01
        end
    end
end

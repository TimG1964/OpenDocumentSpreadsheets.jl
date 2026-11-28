# Hyperlinks (phase 6 step 3, D-072): LibreOffice's URL fields and cell links (F-058), with XLSX.jl's
# API. Fixtures: experiment 030 (test/data/links).
import ZipArchives
const O_H = OpenDocumentSpreadsheets
using OpenDocumentSpreadsheets: ODSError
const HL_OWN = joinpath(@__DIR__, "..", "data", "links", "lo-links-own.fods")
const HL_IMPORT = joinpath(@__DIR__, "..", "data", "links", "lo-links-xlsx-import.fods")

_hl(sheet, ref, url, location, display) = (sheet = sheet, ref = ref, url = url, location = location, display = display, tooltip = nothing)
_links(ws) = [(h.ref, something(h.url, "#" * something(h.location, "")), h.display) for h in O_H.getHyperlinks(ws)]

@testset "LibreOffice's own links" begin
    ws = readods(HL_OWN)["Own"]
    @test O_H.getHyperlink(ws, "B1") == _hl("Own", "B1", "https://example.org/whole", nothing, "Whole")
    @test O_H.getHyperlink(ws, "B2") == _hl("Own", "B2", "https://example.org/mid", nothing, "link")   # inside text
    @test O_H.getHyperlink(ws, "B5") == _hl("Own", "B5", nothing, "Target.B2", "Go")
    @test O_H.getHyperlink(ws, 6, 2).display == "second"                                     # second paragraph
    @test O_H.getHyperlink(ws, "B31") == _hl("Own", "B31", "https://example.org/pn", nothing, nothing)   # cell links
    @test O_H.getHyperlink(ws, "B32").url == "https://example.org/pf"
    @test O_H.getHyperlink(ws, "B34").url == "https://example.org/pe"                         # an empty cell
    @test O_H.getHyperlink(ws, "B35").url == "https://example.org/field"                      # the field first
    @test O_H.getHyperlink(ws, "A1") === nothing
    @test_throws ODSError O_H.getHyperlink(ws, "A1:B2")
    l = _links(ws)
    @test count(x -> x[1] == "B3", l) == 2                                    # two fields in one cell
    @test ("B35", "https://example.org/prop", nothing) in l                   # and the cell link after the field
    @test length(l) == 15
    @test issorted([(parse(Int, h[1][2:end]), h[1][1]) for h in l])           # by row, then column
    @test length(O_H.getHyperlinks(readods(HL_OWN))) == 15                    # the workbook
end

@testset "LibreOffice's import of XLSX.jl's links" begin
    ws = readods(HL_IMPORT)["Links"]
    @test O_H.getHyperlink(ws, "B1").url == "https://example.org/a"
    @test O_H.getHyperlink(ws, "B2").display == "Shown"
    @test O_H.getHyperlink(ws, "B5") == _hl("Links", "B5", "https://example.org/e", nothing, nothing)    # a number: a cell link
    @test O_H.getHyperlink(ws, "B7").url == "../report.pdf"                     # a flat file: from the document's folder (F-065)
    @test O_H.getHyperlink(ws, "B8").location == "Other.B2"
    @test O_H.getHyperlink(ws, "B9").location == "'My Sheet'!C3"                                 # kept as the import wrote it
    @test O_H.getHyperlink(ws, "B10").location == "MyName"
    @test O_H.getHyperlink(ws, "D11").display == "Range"
    @test [O_H.getHyperlink(ws, r).url for r in ("E11", "D12", "E12")] == fill("https://example.org/range", 3)
    @test O_H.getHyperlink(ws, "B13").url == "https://example.org/q?a=1&b=2#frag"
    @test O_H.getHyperlink(ws, "B14").url == "https://example.org/f"                             # a formula: a cell link
    @test all(h -> h.tooltip === nothing, O_H.getHyperlinks(ws))
end

@testset "addHyperlink: arguments (XLSX.jl's checks)" begin
    xf = newods("Data"); ws = xf["Data"]
    @test_throws ODSError addHyperlink(ws, "A1")
    @test_throws ODSError addHyperlink(ws, "A1"; url = "https://x", location = "Data.A1")
    @test_throws ODSError addHyperlink(ws, "A1"; url = "")
    @test_throws ODSError addHyperlink(ws, "A1"; location = "")
    @test_throws ODSError addHyperlink(ws, "notacell"; url = "https://x")
    @test_throws ODSError addHyperlink(ws, "A1"; url = "https://x", tooltip = "tip")     # LibreOffice has none
    @test isempty(O_H.getHyperlinks(ws))
    @test ws["A1"] === missing
    for (args, ref) in (((1, 1), "A1"), (("B2",), "B2"), ((CellRef("E7"),), "E7"))
        info = addHyperlink(ws, args...; url = "https://julialang.org")
        @test info == _hl("Data", ref, "https://julialang.org/", nothing, "https://julialang.org")       # normalized as LibreOffice does (F-065)
        @test O_H.getHyperlink(ws, args...) == info
        @test ws[ref] == "https://julialang.org"                                         # the empty cell's text
    end
    @test_throws ODSError addHyperlink(readods(HL_OWN)["Own"], "A1"; url = "https://x")   # read-only
end

@testset "addHyperlink: LibreOffice's two kinds" begin
    xf = newods("Data"); ws = xf["Data"]
    ws["B2"] = "Has text"; ws["B3"] = 42; setFormula(ws, "B4"; val = "=1+1"); ws["B5"] = true
    @test addHyperlink(ws, "A1"; url = "https://julialang.org", display = "Julia").display == "Julia"
    @test addHyperlink(ws, "B2"; url = "https://example.org/b", display = "ignored").display == "Has text"
    @test ws["B2"] == "Has text"
    @test addHyperlink(ws, "B3"; location = "Data!A1") == _hl("Data", "B3", nothing, "Data.A1", nothing)
    @test ws["B3"] == 42
    @test addHyperlink(ws, "B4"; url = "report.pdf").url == "report.pdf"
    @test addHyperlink(ws, "B5"; location = "'My Sheet'!C3").location == "'My Sheet'.C3"
    @test addHyperlink(ws, "A6"; location = "Total").location == "Total"                   # a defined name
    @test addHyperlink(ws, "A7"; location = "Data.B2:C3").display == "Data.B2:C3"
    @test addHyperlink(ws, "D1:E2"; url = "https://example.org/range", display = "Range").ref == "D1"
    @test ws["D1"] == "Range" && ws["E1"] === missing
    @test [O_H.getHyperlink(ws, r).display for r in ("D1", "E1", "D2", "E2")] == ["Range", nothing, nothing, nothing]
    # replacing
    addHyperlink(ws, "A1"; url = "https://other.org")
    @test O_H.getHyperlink(ws, "A1") == _hl("Data", "A1", "https://other.org/", nothing, "Julia")
    addHyperlink(ws, "B3"; url = "https://other.org")
    @test count(h -> h.ref == "B3", O_H.getHyperlinks(ws)) == 1
    # a new value drops a field and keeps a cell link, as in LibreOffice
    ws["A1"] = "plain"; ws["B3"] = 43
    @test O_H.getHyperlink(ws, "A1") === nothing
    @test O_H.getHyperlink(ws, "B3").url == "https://other.org/"
    # formatting keeps both
    setFont(ws, "B2:B3"; bold = true)
    @test O_H.getHyperlink(ws, "B2").url == "https://example.org/b" && O_H.getHyperlink(ws, "B3").url == "https://other.org/"
    # deleting
    @test deleteHyperlink(ws, "B2") && ws["B2"] == "Has text" && O_H.getHyperlink(ws, "B2") === nothing
    @test deleteHyperlink(ws, "D1:E2") && all(r -> O_H.getHyperlink(ws, r) === nothing, ("D1", "E1", "D2", "E2"))
    @test ws["D1"] == "Range"
    @test !deleteHyperlink(ws, "D1") && !deleteHyperlink(ws, 9, 9)
    @test length(O_H.getHyperlinks(xf)) == length(O_H.getHyperlinks(ws)) == 5
    # saved and read back
    dir = mktempdir()
    for ext in ("ods", "fods")
        r = readods(writeods(joinpath(dir, "new.$ext"), xf))
        @test O_H.getHyperlinks(r) == O_H.getHyperlinks(xf)
        @test r["Data"]["B3"] == 43 && r["Data"]["B2"] == "Has text"
    end
    t = read(joinpath(dir, "new.fods"), String)
    @test occursin("xlink:href=\"report.pdf\"", t) && !occursin("../report.pdf", t)          # flat: from the document's folder
    z = String(ZipArchives.zip_readentry(ZipArchives.ZipReader(read(joinpath(dir, "new.ods"))), "content.xml"))
    @test occursin("xlink:href=\"../report.pdf\"", z)                                    # zipped: from the package
    @test occursin("<style:hyperlink xlink:href=\"https://other.org/\"", t)
    @test occursin("<loext:hyperlink", t) && occursin("xmlns:loext=", t)
end

function _edit_links_file()
    xf = openods(HL_OWN; mode = "rw")
    ws = xf["Own"]
    addHyperlink(ws, "C8"; url = "https://new.org", display = "New")      # an empty cell
    addHyperlink(ws, "A2"; url = "https://new.org/a2")                    # text, read from the file
    addHyperlink(ws, "B14"; location = "Target.B2")                       # a number with a note
    deleteHyperlink(ws, "B1")                                             # LibreOffice's field
    deleteHyperlink(ws, "B31")                                            # LibreOffice's cell link
    return xf
end

@testset "a patched save: links added and removed in LibreOffice's file" begin
    xf = _edit_links_file()
    ws = xf["Own"]
    @test O_H.getHyperlink(ws, "B1") === nothing && O_H.getHyperlink(ws, "B31") === nothing
    @test O_H.getHyperlink(ws, "C8").display == "New"
    @test O_H.getHyperlink(ws, "B14").location == "Target.B2"
    before = O_H.getHyperlinks(ws)
    dir = mktempdir()
    out = writeods(joinpath(dir, "own.fods"), xf)
    r = readods(out)["Own"]
    @test O_H.getHyperlinks(r) == before
    @test r["B1"] == "Whole" && r["B31"] == 12 && r["B14"] == 7 && r["A2"] == "partial"
    t = read(out, String)
    src = read(HL_OWN, String)
    # untouched cells as they were (D-023): two fields in one cell, the target frame
    @test occursin("<text:a xlink:href=\"https://example.org/frame\" xlink:type=\"simple\" office:target-frame-name=\"_blank\">Framed</text:a>", t)
    @test count("<text:a ", t) == count("<text:a ", src) - 1 + 2                             # B1 gone, A2 and C8 new
    @test occursin("On seven", t)                                                         # B14's note kept (D-071)
end

@testset "links follow inserted and deleted rows and columns" begin
    xf = openods(HL_OWN; mode = "rw")
    ws = xf["Own"]
    insertRows(ws, 1; count = 2)
    deleteColumns(ws, "A")
    @test O_H.getHyperlink(ws, "A3").url == "https://example.org/whole"                   # B1
    @test O_H.getHyperlink(ws, "A33").url == "https://example.org/pn"                     # B31, a cell link
    @test O_H.getHyperlink(ws, "B3") === nothing
    r = readods(writeods(joinpath(mktempdir(), "shifted.fods"), xf))["Own"]
    @test O_H.getHyperlinks(r) == O_H.getHyperlinks(ws)
end

@testset "LibreOffice reads the links" begin
    if lo_ok(; what = "the hyperlinks oracle")
        dir = mktempdir()
        profile = lo_profile_url(joinpath(dir, "lo-profile"))
        xf = newods("Data"); ws = xf["Data"]
        ws["B3"] = 42
        addHyperlink(ws, "A1"; url = "https://julialang.org", display = "Julia")
        addHyperlink(ws, "B3"; location = "Data!A1")
        addHyperlink(ws, "A4"; url = "report.pdf")
        addHyperlink(ws, "D1:E2"; url = "https://example.org/range", display = "Range")
        a = writeods(joinpath(dir, "new.ods"), xf)
        b = writeods(joinpath(dir, "own.fods"), _edit_links_file())
        # the new file converted beside itself, so that its relative link stays as it is (F-065)
        lo_convert(a, "fods"; outdir = dir, profile = profile)
        lo_convert(b, "fods"; outdir = joinpath(dir, "lo"), profile = profile)
        @test _links(readods(joinpath(dir, "new.fods"))["Data"]) == _links(xf["Data"])
        lo = readods(joinpath(dir, "lo", "own.fods"))["Own"]
        @test _links(lo) == _links(readods(b)["Own"])
    end
end

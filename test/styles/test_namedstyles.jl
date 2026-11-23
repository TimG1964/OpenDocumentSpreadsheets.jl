# Named cell styles (phase 4 step 8, D-045): getCellStyle, setCellStyle, addCellStyle!.
# XLSX.jl has no named styles; the expectations are LibreOffice's (experiment 018, F-039 to
# F-041).

using OpenDocumentSpreadsheets: ODSError, getCellStyle, getFont, getFill, getBorder, getAlignment, getFormat, getText, encode_style_name
using Dates
import ZipArchives

ntmp(name) = joinpath(mktempdir(), name)
_part(path, name) = String(ZipArchives.zip_readentry(ZipArchives.ZipReader(read(path)), name))

@testset "name encoding (F-040)" begin
    for (d, n) in ("My Style" => "My_20_Style", "a&b" => "a_26_b", "1st" => "_31_st", "x_y" => "x_5f_y",
                   "a.b c" => "a.b_20_c", "Größe" => "Größe", "Heading 1" => "Heading_20_1", "Good" => "Good")
        @test encode_style_name(d) == n
    end
end

@testset "getCellStyle on LibreOffice's files" begin
    for f in ("lo-named-styles.ods", "lo-named-styles.fods")
        s = openods(joinpath(DATA, f))[1]          # read-only
        # A1-A4: direct formatting over a style (automatic styles, and column A's default)
        @test [getCellStyle(s, "A$i") for i in 1:8] ==
              ["Heading 1", "Good", "Accent 1", "Heading 1", "Heading 1", "Good", "My Style", "Good"]
        @test [getCellStyle(s, "B$i") for i in 1:5] == ["Größe", "a&b", "1st", "x_y", "a.b c"]
        @test getCellStyle(s, "D20") == "Default"
        @test getCellStyle(s, 7, 1) == "My Style"
        @test getCellStyle(openods(joinpath(DATA, f)), "Sheet1.B2") == "a&b"
        @test s["A8"] == Date(2023, 3, 15)        # a date under Good keeps its format (F-039)
    end
    @test getCellStyle(openods(joinpath(DATA, "lo-scenarios.ods"))[1], "A1") == "Default"
    @test_throws ODSError getCellStyle(openods(joinpath(DATA, "lo-named-styles.ods"))[1], "A1:B2")
end

@testset "setCellStyle" begin
    f = newods(); s = f[1]
    s["A1"] = Date(2024, 1, 2); s["A2"] = 1; s["A3"] = "x"; s["A4"] = 2
    setFont(s, "A1:A2"; bold = true, italic = true, size = 13)
    setFill(s, "A1:A2"; pattern = "solid", fgColor = "FF0000")
    setAlignment(s, "A1:A2"; horizontal = "center")
    # Heading 1 sets the size, and through Heading bold and an upright posture: those go,
    # the fill, the alignment and the date format stay (F-039)
    n = setCellStyle(s, "A1", "Heading 1")
    @test n isa String && n != "Heading_20_1"
    @test getCellStyle(s, "A1") == "Heading 1"
    fo = getFont(s, "A1").font
    @test fo["sz"]["val"] == "18" && haskey(fo, "b") && !haskey(fo, "i")
    @test getFill(s, "A1").fill["patternFill"]["fgrgb"] == "FFFF0000"
    @test getAlignment(s, "A1").alignment["alignment"]["horizontal"] == "center"
    @test s["A1"] == Date(2024, 1, 2) && getText(s, "A1") == "2024-01-02"
    # Good sets the fill and colour: the fill goes, bold, italic and 13 pt stay
    setCellStyle(s, "A2", "Good")
    fo = getFont(s, "A2").font
    @test getCellStyle(s, "A2") == "Good" && fo["sz"]["val"] == "13" && haskey(fo, "b") && haskey(fo, "i")
    @test getFill(s, "A2").fill["patternFill"]["fgrgb"] == "FFCCFFCC"
    # no direct formatting: the cell refers to the named style itself
    @test setCellStyle(s, "A3", "Accent_20_1") == "Accent_20_1"
    @test getCellStyle(s, "A3") == "Accent 1"
    @test setCellStyle(s, 4, 1, "Good") == "Good"
    # ranges, whole columns and rows
    @test setCellStyle(s, "C1:D3", "Bad") == -1
    @test all(getCellStyle(s, r, c) == "Bad" for r in 1:3, c in 3:4)
    setCellStyle(s, "F:F", "Neutral"); setCellStyle(s, 9, :, "Note")
    @test getCellStyle(s, "F5") == "Neutral" && getCellStyle(s, "Z9") == "Note"
    @test getCellStyle(s, "E5") == "Default"
    # errors
    @test_throws ODSError setCellStyle(s, "A1", "No such style")
    @test_throws ODSError setCellStyle(s, "A1")
    @test_throws ODSError setCellStyle(openods(joinpath(DATA, "lo-named-styles.ods"))[1], "A1", "Good")
    # a value written later keeps the style
    s["A3"] = Date(2020, 5, 6)
    @test getCellStyle(s, "A3") == "Accent 1" && s["A3"] == Date(2020, 5, 6)
    # built-ins are added with their parents, once, LibreOffice's own XML
    for p in (writeods(ntmp("n.ods"), f), writeods(ntmp("n.fods"), f))
        r = openods(p)[1]
        @test getCellStyle(r, "A1") == "Heading 1" && getCellStyle(r, "A3") == "Accent 1" && getCellStyle(r, "D3") == "Bad"
        @test getFont(r, "A1").font["sz"]["val"] == "18" && r["A1"] == Date(2024, 1, 2)
        xml = endswith(p, ".ods") ? _part(p, "styles.xml") : read(p, String)
        for n in ("Heading", "Heading_20_1", "Status", "Good", "Bad", "Neutral", "Accent", "Accent_20_1", "Text", "Note")
            @test count("style:name=\"$n\"", xml) == 1
        end
        @test !occursin("style:name=\"Heading_20_2\"", xml)
        @test occursin("""<style:style style:name="Heading_20_1" style:display-name="Heading 1" style:family="table-cell" style:parent-style-name="Heading">""", xml)
    end
end

@testset "addCellStyle!" begin
    f = newods(); s = f[1]
    s["A1"] = 3.5; s["A2"] = 1
    @test addCellStyle!(f, "My Style"; parent = "Heading 1", font = (bold = true, name = "Liberation Serif", color = "0000FF"),
                        fill = (pattern = "solid", fgColor = "FFFF00"), border = (allsides = ["style" => "thin"],),
                        alignment = (horizontal = "right",), format = "0.00\" kg\"") == "My_20_Style"
    @test addCellStyle!(f, "a&b"; font = Dict("italic" => true)) == "a_26_b"
    @test addCellStyle!(f, "Child"; parent = "My Style", font = [:size => 9]) == "Child"
    @test setCellStyle(s, "A1", "My Style") == "My_20_Style"
    setCellStyle(s, "A2", "Child"); setCellStyle(s, "B1", "a&b")
    function check(s)
        @test getCellStyle(s, "A1") == "My Style" && getCellStyle(s, "A2") == "Child" && getCellStyle(s, "B1") == "a&b"
        fo = getFont(s, "A1").font
        @test fo["name"]["val"] == "Liberation Serif" && fo["sz"]["val"] == "18" && haskey(fo, "b") && fo["color"]["rgb"] == "FF0000FF"
        @test getFill(s, "A1").fill["patternFill"]["fgrgb"] == "FFFFFF00"
        @test getBorder(s, "A1").border["top"]["style"] == "thin"
        @test getAlignment(s, "A1").alignment["alignment"]["horizontal"] == "right"
        @test getFormat(s, "A1").format["numFmt"]["formatCode"] == "0.00\" kg\""
        @test getText(s, "A1") == "3.50 kg"
        @test getFont(s, "A2").font["sz"]["val"] == "9" && getText(s, "A2") == "1.00 kg"   # inherited
        @test haskey(getFont(s, "B1").font, "i")
    end
    check(s)
    p = writeods(ntmp("a.ods"), f)
    check(openods(p)[1])
    sx = _part(p, "styles.xml"); cx = _part(p, "content.xml")
    # the data style and the font face are in styles.xml (F-040), not in content.xml
    @test occursin("<number:text> kg</number:text>", sx) && !occursin("<number:text> kg</number:text>", cx)
    @test occursin("<style:font-face style:name=\"Liberation Serif\"", sx) && occursin("xmlns:svg=", sx)
    @test occursin("style:display-name=\"a&amp;b\"", sx)
    check(openods(writeods(ntmp("a.fods"), f))[1])
    # errors
    @test_throws ODSError addCellStyle!(f, "My Style")
    @test_throws ODSError addCellStyle!(f, "Good")
    @test_throws ODSError addCellStyle!(f, "Default")
    @test_throws ODSError addCellStyle!(f, "")
    @test_throws ODSError addCellStyle!(f, "x"; parent = "nope")
    @test_throws ODSError addCellStyle!(f, "x"; font = (heavy = true,))
    @test_throws ODSError addCellStyle!(f, "x"; border = (outside = ["style" => "thin"],))
    @test_throws ODSError addCellStyle!(f, "x"; font = 1)
    @test_throws ODSError addCellStyle!(f, "x"; colour = "red")
    @test_throws ODSError addCellStyle!(openods(joinpath(DATA, "lo-values.ods")), "x")
    # a format reused by direct formatting is declared once, in styles.xml
    setFormat(s, "C1"; format = "0.00\" kg\"")
    p = writeods(ntmp("b.ods"), f)
    @test count("<number:text> kg</number:text>", _part(p, "styles.xml")) == 1 && !occursin(" kg</number:text>", _part(p, "content.xml"))
    @test getText(openods(p)[1], "C1") == ""
end

@testset "patching styles.xml (D-023)" begin
    src = joinpath(DATA, "lo-scenarios.ods")
    before = _part(src, "styles.xml")
    # no named styles: styles.xml is copied byte for byte
    q = ntmp("p.ods"); cp(src, q)
    g = openods(q; mode = "rw"); setFont(g[1], "A1"; bold = true); setCellStyle(g[1], "A2", "Good")
    p1 = writeods(ntmp("p1.ods"), g)
    @test _part(p1, "styles.xml") == before
    # a new style: only office:styles (and the faces) change
    g = openods(q; mode = "rw")
    addCellStyle!(g, "Mine"; font = (name = "Courier New", bold = true), format = "0.000")
    setCellStyle(g[1], "B2", "Mine")
    p2 = writeods(ntmp("p2.ods"), g)
    after = _part(p2, "styles.xml")
    i = findfirst("</office:styles>", before)
    @test startswith(after, before[1:findfirst("<office:font-face-decls>", before).stop])
    @test endswith(after, before[first(i):end])
    @test occursin("<style:font-face style:name=\"Courier New\"", after) && occursin("style:name=\"Mine\"", after)
    @test _part(p2, "meta.xml") == _part(src, "meta.xml")
    r = openods(p2)
    @test getCellStyle(r[1], "B2") == "Mine" && getFont(r[1], "B2").font["name"]["val"] == "Courier New"
    for k in 2:sheetcount(r)
        @test isequal(getdata(r[k]), getdata(openods(src)[k]))
    end
    # a LibreOffice file with named styles: its own styles are kept, ours appended
    q2 = ntmp("n.ods"); cp(joinpath(DATA, "lo-named-styles.ods"), q2)
    g = openods(q2; mode = "rw")
    addCellStyle!(g, "Extra"; parent = "My Style", fill = (pattern = "solid", fgColor = "00FF00"))
    setCellStyle(g[1], "C1", "Extra"); setCellStyle(g[1], "C2", "My Style")
    r = openods(writeods(ntmp("n2.ods"), g))[1]
    @test getCellStyle(r, "C1") == "Extra" && getCellStyle(r, "C2") == "My Style" && getCellStyle(r, "B2") == "a&b"
    @test getFill(r, "C1").fill["patternFill"]["fgrgb"] == "FF00FF00"
    # flat files
    q3 = ntmp("n.fods"); cp(joinpath(DATA, "lo-named-styles.fods"), q3)
    g = openods(q3; mode = "rw")
    addCellStyle!(g, "Flat one"; font = (size = 20,)); setCellStyle(g[1], "C3", "Flat one"); setCellStyle(g[1], "C4", "Heading 2")
    r = openods(writeods(ntmp("n3.fods"), g))[1]
    @test getCellStyle(r, "C3") == "Flat one" && getFont(r, "C3").font["sz"]["val"] == "20" && getCellStyle(r, "C4") == "Heading 2"
end

@testset "LibreOffice keeps named styles" begin
    if isempty(SOFFICE) || !isfile(SOFFICE)
        @info "LibreOffice not found; skipping the named styles oracle (set ODS_SOFFICE)"
        @test_skip false
    else
        dir = mktempdir()
        profile = lo_profile_url(joinpath(dir, "lo-profile"))
        f = newods("N"); s = f["N"]
        s["A1"] = 3.5; s["A2"] = Date(2024, 1, 2); s["A3"] = "t"; s["A4"] = 4
        addCellStyle!(f, "My Style"; parent = "Heading 1", font = (bold = true, name = "Liberation Serif"),
                      fill = (pattern = "solid", fgColor = "FFFF00"), format = "0.00\" kg\"")
        setCellStyle(s, "A1", "My Style")
        setFont(s, "A2"; italic = true); setCellStyle(s, "A2", "Good")
        setCellStyle(s, "A3", "Accent 1"); setCellStyle(s, "A4", "Heading 2")
        f1 = writeods(joinpath(dir, "new.ods"), f)
        f3 = writeods(joinpath(dir, "flat.fods"), f)
        q = joinpath(dir, "patched.ods"); cp(joinpath(DATA, "lo-scenarios.ods"), q)
        g = openods(q; mode = "rw"); w = g[1]
        addCellStyle!(g, "a&b"; font = (size = 16, name = "Liberation Mono"), format = "0.0%")
        w["A1"] = 0.25; setCellStyle(w, "A1", "a&b"); setCellStyle(w, "B1", "Warning")
        f2 = writeods(joinpath(dir, "patched2.ods"), g)
        run(pipeline(`$SOFFICE -env:UserInstallation=$profile --headless --norestore --convert-to ods --outdir $(joinpath(dir, "lo")) $f1 $f2 $f3`;
                     stdout = devnull, stderr = devnull))
        for (mine, lo) in ((f1, "new.ods"), (f3, "flat.ods"))
            a = openods(mine)["N"]; b = openods(joinpath(dir, "lo", lo))["N"]
            for c in ("A1", "A2", "A3", "A4")
                @test getCellStyle(b, c) == getCellStyle(a, c)
                @test filter(p -> !startswith(p.first, "odf:"), getFont(b, c).font) == getFont(a, c).font
                @test getFill(b, c).fill == getFill(a, c).fill
                @test getText(b, c) == getText(a, c)
            end
            @test getText(b, "A1") == "3.50 kg" && getCellStyle(b, "A2") == "Good" && haskey(getFont(b, "A2").font, "i")
        end
        a = openods(f2)[1]; b = openods(joinpath(dir, "lo", "patched2.ods"))[1]
        @test getCellStyle(b, "A1") == "a&b" && getCellStyle(b, "B1") == "Warning"
        @test getText(b, "A1") == getText(a, "A1") == "25.0%"
        @test getFont(b, "A1").font["name"]["val"] == "Liberation Mono" && getFont(b, "A1").font["sz"]["val"] == "16"
    end
end

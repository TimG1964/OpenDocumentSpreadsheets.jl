# Hidden rows and columns, sheet visibility and tab colours (phase 5 step 6; D-059, F-051), against
# LibreOffice's own files (experiment 023 part A, test/data/visibility/), in the model, in saved files
# and through LibreOffice. XLSX.jl's hide-group.jl and settings.jl visibility cases are ported where
# they apply. Uses SHIFT from formula/test_refs.jl.

using OpenDocumentSpreadsheets: isRowHidden, isColumnHidden, getSheetVisibility, getTabColor, ODSError,
    renamesheet!, copysheet!, deletesheet!, insertRows, deleteColumns

const VIS = joinpath(DATA, "visibility")

@testset "LibreOffice's hidden lines, sheets and tab colours, read (experiment 023)" begin
    xf = readods(joinpath(VIS, "lo-vis.fods"))
    s1 = xf["S1"]
    @test [isRowHidden(s1, r) for r in 1:6] == [false, false, true, true, false, false]
    @test [isColumnHidden(s1, c) for c in 1:6] == [false, false, true, true, false, false]
    @test [getSheetVisibility(xf[i]) for i in 1:6] == [:visible, :hidden, :visible, :visible, :hidden, :hidden]
    @test [getTabColor(xf[i]) for i in 1:6] == [nothing, nothing, "FFFF0000", nothing, "FF008000", nothing]
    # LibreOffice's import of an xlsx XLSX.jl wrote: very hidden is hidden; theme colours resolved
    im = readods(joinpath(VIS, "lo-xlsx-import.fods"))
    @test [getSheetVisibility(im[n]) for n in ("Vis", "Hid", "VeryHid", "HidTab")] == [:visible, :hidden, :hidden, :hidden]
    @test [getTabColor(im[n]) for n in ("TabRGB", "TabARGB", "TabName", "TabAccent2", "TabTx1", "HidTab")] ==
          ["FFFF0000", "FF00FF00", "FFFFA500", "FFED7D31", "FF000000", "FF0000FF"]
    @test isRowHidden(im["Vis"], "3") && isRowHidden(xf, "S1.4") && !isRowHidden(im["Vis"], 5)
    @test isColumnHidden(im["Vis"], "C") && isColumnHidden(xf, "S1!D") && isColumnHidden(s1, "D7")
    @test_throws ODSError isRowHidden(s1, "3:4")
    @test_throws ODSError isColumnHidden(s1, 0)
end

@testset "hiding rows and columns (XLSX.jl's cases)" begin
    xf = newods("Sheet1")
    s = xf[1]
    s["A1:F10"] = 1
    setRowHidden(s, 2:4)
    @test [isRowHidden(s, r) for r in 1:5] == [false, true, true, true, false]
    setRowHidden(s, "3"; hidden = false)
    @test !isRowHidden(s, 3) && isRowHidden(s, 2) && isRowHidden(s, 4)
    setRowHidden(s, [7, 9])
    setRowHidden(xf, "Sheet1.20:21")
    setRowHidden(xf, "Sheet1!30")
    @test isRowHidden(s, 7) && !isRowHidden(s, 8) && isRowHidden(s, 9) && isRowHidden(s, 21) && isRowHidden(s, 30)
    setColumnHidden(s, "B:C,F")
    setColumnHidden(s, 8)
    @test [isColumnHidden(s, c) for c in 1:8] == [false, true, true, false, false, true, false, true]
    setColumnHidden(s, "A2:B2"; hidden = false)
    @test !isColumnHidden(s, 2) && isColumnHidden(s, 3)
    addDefinedName(s, "hideme", "D1:E3")
    setColumnHidden(s, "hideme")
    setRowHidden(s, "hideme")
    @test isColumnHidden(s, "E") && isRowHidden(s, 1)
    setRowHidden(s, 1048576)                         # rows without data, to the sheet's end
    @test isRowHidden(s, 1048576) && !isRowHidden(s, 1048575)
    @test_throws ODSError setRowHidden(s, 0)
    @test_throws ODSError setRowHidden(s, 1048577)
    @test_throws ODSError setColumnHidden(s, 16385)
    @test_throws ODSError setColumnHidden(s, "nosuchname")
    @test_throws ODSError setRowHidden(xf, "Nope.3")
    @test_throws ODSError setRowHidden(readods(joinpath(VIS, "lo-vis.fods"))[1], 1)
    r = readods(writeods(joinpath(mktempdir(), "h.ods"), xf))[1]
    @test [isRowHidden(r, i) for i in (1, 2, 3, 4, 7, 8, 9, 21, 30, 1048576)] == [true, true, true, true, true, false, true, true, true, true]
    @test [isColumnHidden(r, c) for c in 1:8] == [false, false, true, true, true, true, false, true]
    @test r["A1"] == 1 && r["F10"] == 1
end

@testset "sheet visibility and tab colours" begin
    xf = newods("A")
    addsheet!(xf, "B"); addsheet!(xf, "C")
    setSheetVisibility(xf["B"], :hidden)
    @test getSheetVisibility(xf["B"]) === :hidden && !OpenDocumentSpreadsheets.isvisible(xf["B"])
    setSheetVisibility(xf["C"], :veryHidden)                       # ODF has none: hidden (F-051)
    @test getSheetVisibility(xf["C"]) === :hidden
    @test_throws ODSError setSheetVisibility(xf["A"], :hidden)     # the last visible sheet
    @test_throws ODSError setSheetVisibility(xf["A"], :bogus)
    setSheetVisibility(xf["C"], :visible)
    setSheetVisibility(xf["A"], :hidden)                           # C is visible now
    @test getSheetVisibility(xf["A"]) === :hidden
    setTabColor(xf["A"], "#FF0000"); setTabColor(xf["B"], "80FF0000"); setTabColor(xf["C"], :orange)
    @test getTabColor(xf["A"]) == "FFFF0000" && getTabColor(xf["B"]) == "FFFF0000" && getTabColor(xf["C"]) == "FFFFA500"
    @test_throws ODSError setTabColor(xf["A"], :accent2)          # theme colours: Excel's
    @test removeTabColor(xf["B"]) && !removeTabColor(xf["B"]) && getTabColor(xf["B"]) === nothing
    for ext in ("ods", "fods")                                       # (a new flat file wrote no table styles until step 8)
        r = readods(writeods(joinpath(mktempdir(), "v.$ext"), xf))
        @test [getSheetVisibility(r[i]) for i in 1:3] == [:hidden, :hidden, :visible]
        @test [getTabColor(r[i]) for i in 1:3] == ["FFFF0000", nothing, "FFFFA500"]
    end
    @test_throws ODSError setSheetVisibility(readods(joinpath(VIS, "lo-vis.fods"))[1], :hidden)
    # the same properties share one derived style
    xf = newods("A"); addsheet!(xf, "B"); addsheet!(xf, "C")
    setTabColor(xf["A"], "00FF00"); setTabColor(xf["B"], "00FF00")
    @test xf["A"].props.style == xf["B"].props.style
    @test length(collect(eachmatch(r"style:family=\"table\"", OpenDocumentSpreadsheets._table_styles_xml(xf)))) == 1
end

@testset "a patched save changes only the sheet edited (D-023)" begin
    src = joinpath(VIS, "lo-vis.fods")
    orig = read(src, String)
    dir = mktempdir()
    ta4 = match(r"<style:style style:name=\"ta4\".*?</style:style>"s, orig).match
    # S1 (ta1) hidden with S5's colour: the derived style is LibreOffice's ta4, renamed
    xf = openods(src; mode = "rw")
    setSheetVisibility(xf["S1"], :hidden)
    setTabColor(xf["S1"], "008000")
    derived = only(x for (n, x) in xf.tstyles.added if n == xf["S1"].props.style)
    @test replace(derived, "style:name=\"$(xf["S1"].props.style)\"" => "style:name=\"ta4\"", r">\s+<" => "><") ==
          replace(ta4, r">\s+<" => "><")
    out = read(writeods(joinpath(dir, "a.fods"), xf), String)
    n = xf["S1"].props.style
    k = findfirst("</office:automatic-styles>", orig)
    want = orig[1:prevind(orig, first(k))] * derived * orig[first(k):end]
    want = replace(want, "<table:table table:name=\"S1\" table:style-name=\"ta1\">" => "<table:table table:name=\"S1\" table:style-name=\"$n\">")
    @test out == want
    # changed and changed back: the file as it was
    xf = openods(src; mode = "rw")
    setTabColor(xf["S4"], "0000FF"); removeTabColor(xf["S4"])
    setSheetVisibility(xf["S2"], :visible); setSheetVisibility(xf["S2"], :hidden)
    @test read(writeods(joinpath(dir, "b.fods"), xf), String) == orig
    # S3's colour removed: a style without it
    xf = openods(src; mode = "rw")
    removeTabColor(xf["S3"])
    r = readods(writeods(joinpath(dir, "c.fods"), xf))
    @test getTabColor(r["S3"]) === nothing && getSheetVisibility(r["S3"]) === :visible && getTabColor(r["S5"]) == "FF008000"
    # rows shown again, a column hidden
    xf = openods(src; mode = "rw")
    setRowHidden(xf["S1"], 3:4; hidden = false)
    setColumnHidden(xf["S2"], "A")
    r = readods(writeods(joinpath(dir, "d.fods"), xf))
    @test !isRowHidden(r["S1"], 3) && !isRowHidden(r["S1"], 4) && isColumnHidden(r["S1"], 3) && isColumnHidden(r["S2"], 1)
    @test r["S1"]["F8"] == 86 && r["S2"]["A1"] == 11
end

@testset "with sheet operations and the active sheet" begin
    src = joinpath(VIS, "lo-vis.fods")
    xf = openods(src; mode = "rw")
    setTabColor(xf["S1"], "123456")
    renamesheet!(xf["S1"], "First")
    c = copysheet!(xf["First"], "Copy")
    insertRows(xf["First"], 1; count = 2)                          # hidden rows move down
    deletesheet!(xf, "S6")
    @test getTabColor(c) == "FF123456" && isRowHidden(xf["First"], 5) && !isRowHidden(xf["First"], 3)
    r = readods(writeods(joinpath(mktempdir(), "o.fods"), xf))
    @test getTabColor(r["First"]) == "FF123456" && getTabColor(r["Copy"]) == "FF123456"
    @test isRowHidden(r["First"], 5) && isRowHidden(r["First"], 6) && !isRowHidden(r["First"], 3) && isRowHidden(r["Copy"], 3)
    @test getSheetVisibility(r["S2"]) === :hidden
    # a new sheet's copy keeps its properties
    n = newods("A"); addsheet!(n, "B")
    setTabColor(n["B"], "FF00FF"); setSheetVisibility(n["B"], :hidden)
    cc = copysheet!(n["B"])
    @test getTabColor(cc) == "FFFF00FF" && getSheetVisibility(cc) === :hidden
    # the active sheet, hidden, moves to the visible sheet before it, else after it (F-051)
    xf = openods(src; mode = "rw")                                # S2, S5 and S6 hidden
    st(a) = "<config:config-item config:name=\"ActiveTable\" config:type=\"string\">$a</config:config-item>"
    @test !OpenDocumentSpreadsheets._settings_edited(xf)
    setSheetVisibility(xf["S4"], :hidden)
    @test OpenDocumentSpreadsheets.patched_settings(xf, st("S4")) == st("S3")
    @test OpenDocumentSpreadsheets.patched_settings(xf, st("S6")) == st("S3")       # S4, S5 hidden too
    setSheetVisibility(xf["S1"], :hidden)
    @test OpenDocumentSpreadsheets.patched_settings(xf, st("S1")) == st("S3")       # none before: the next
    @test OpenDocumentSpreadsheets.patched_settings(xf, st("S3")) == st("S3")
end

@testset "LibreOffice reads the hidden lines, sheets and tab colours" begin
    if isempty(SOFFICE) || !isfile(SOFFICE)
        @info "LibreOffice not found; skipping the visibility oracle (set ODS_SOFFICE)"
        @test_skip false
    else
        dir = mktempdir()
        profile = lo_profile_url(joinpath(dir, "lo-profile"))
        xf = newods("A")
        addsheet!(xf, "B"); addsheet!(xf, "C")
        xf["A"]["A1:E6"] = 1
        setRowHidden(xf["A"], 2:3); setColumnHidden(xf["A"], "B,D")
        setSheetVisibility(xf["B"], :hidden); setTabColor(xf["B"], "112233"); setTabColor(xf["C"], "FF8000")
        files = [writeods(joinpath(dir, "new.ods"), xf)]
        pf = openods(joinpath(VIS, "lo-vis.fods"); mode = "rw")
        setSheetVisibility(pf["S2"], :visible); setTabColor(pf["S2"], "00FFFF"); setSheetVisibility(pf["S3"], :hidden)
        setRowHidden(pf["S1"], 6); setColumnHidden(pf["S1"], "C"; hidden = false)
        push!(files, writeods(joinpath(dir, "patched.fods"), pf))
        run(pipeline(`$SOFFICE -env:UserInstallation=$profile --headless --norestore --convert-to fods --outdir $(joinpath(dir, "lo")) $files`;
                     stdout = devnull, stderr = devnull))
        lo = readods(joinpath(dir, "lo", "new.fods"))
        @test [getSheetVisibility(lo[i]) for i in 1:3] == [:visible, :hidden, :visible]
        @test [getTabColor(lo[i]) for i in 1:3] == [nothing, "FF112233", "FFFF8000"]
        @test [isRowHidden(lo["A"], r) for r in 1:4] == [false, true, true, false]
        @test [isColumnHidden(lo["A"], c) for c in 1:5] == [false, true, false, true, false]
        lp = readods(joinpath(dir, "lo", "patched.fods"))
        @test [getSheetVisibility(lp[i]) for i in 1:6] == [:visible, :visible, :hidden, :visible, :hidden, :hidden]
        @test getTabColor(lp["S2"]) == "FF00FFFF" && getTabColor(lp["S3"]) == "FFFF0000"
        @test isRowHidden(lp["S1"], 6) && !isColumnHidden(lp["S1"], 3) && isColumnHidden(lp["S1"], 4)
    end
end

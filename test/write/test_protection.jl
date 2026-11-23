# Protection (phase 5 step 9; D-062, F-054): sheets, the file's structure and cells, against
# LibreOffice's own files (experiment 025, test/data/protection/), in saved files and through
# LibreOffice. Part B of the experiment showed LibreOffice accepting OpenDocumentSpreadsheets' keys (lo-prot.tsv's
# `odsf` rows): unprotecting needs a view's API, not a conversion. XLSX.jl's protection cases are
# ported where they apply.

using OpenDocumentSpreadsheets: isSheetProtected, getSheetProtection, getCellProtection, isWorkbookProtected,
    getWorkbookProtection, ODSError, renamesheet!, copysheet!

const PROT = joinpath(DATA, "protection")

@testset "LibreOffice's protection, read (experiment 025)" begin
    own = readods(joinpath(PROT, "lo-prot-own.fods"))
    @test [isSheetProtected(own[n]) for n in ("Secret", "NoPassword", "Unicode", "Cells", "Open")] == [true, true, true, true, false]
    @test getSheetProtection(own["Secret"]).password && !getSheetProtection(own["NoPassword"]).password
    @test getSheetProtection(own["Open"]) === nothing
    p = getSheetProtection(own["Secret"])
    @test p.selectLockedCells && p.selectUnlockedCells && !p.insertRows && !p.sort
    @test isWorkbookProtected(own) && getWorkbookProtection(own) == (password = true, structure = true, windows = false)
    c = own["Cells"]
    @test getCellProtection(c, "A1") == (locked = true, hidden = false)            # unformatted: locked
    @test getCellProtection(c, "B2") == (locked = false, hidden = false)
    @test getCellProtection(c, "C3") == (locked = true, hidden = true)
    @test getCellProtection(c, "A4") == (locked = false, hidden = true)
    @test getCellProtection(c, "A3") == (locked = true, hidden = true)             # LibreOffice's "hide all"
    # its import of XLSX.jl's file: 8 of the 15 permissions; workbook protection dropped
    im = readods(joinpath(PROT, "lo-prot-xlsx-import.fods"))
    @test !isWorkbookProtected(im) && getWorkbookProtection(im) === nothing
    @test getSheetProtection(im["Password"]).password                               # the legacy Excel hash
    @test getSheetProtection(im["Nothing"]).selectLockedCells == false && getSheetProtection(im["Nothing"]).selectUnlockedCells == false
    for (sheet, kept) in (("insertColumns", true), ("insertRows", true), ("deleteColumns", true), ("deleteRows", true),
                          ("autoFilter", true), ("pivotTables", true), ("formatCells", false), ("formatColumns", false),
                          ("formatRows", false), ("insertHyperlinks", false), ("sort", false), ("objects", false), ("scenarios", false))
        @test getfield(getSheetProtection(im[sheet]), Symbol(sheet)) == kept
    end
    @test getCellProtection(im["Cells"], "B2").locked == false && getCellProtection(im["Cells"], "C3").hidden
end

@testset "keys and forms are LibreOffice's (experiment 025)" begin
    own = read(joinpath(PROT, "lo-prot-own.fods"), String)
    key(sheet) = match(Regex("<table:table table:name=\"" * sheet * "\"[^>]*table:protection-key=\"([^\"]*)\""), own).captures[1]
    @test OpenDocumentSpreadsheets._protection_key("secret") == key("Secret")
    @test OpenDocumentSpreadsheets._protection_key("pässwörd€") == key("Unicode")
    @test OpenDocumentSpreadsheets._protection_key("book") == match(r"<office:spreadsheet [^>]*table:protection-key=\"([^\"]*)\"", own).captures[1]
    # a new file's tables, as LibreOffice wrote its own
    xf = newods("Secret")
    addsheet!(xf, "NoPassword"); addsheet!(xf, "Open")
    protectSheet(xf["Secret"]; password = "secret")
    protectSheet(xf["NoPassword"]; password = "")                  # an empty password is none, as in LibreOffice
    protectWorkbook(xf; password = "book")
    t = read(writeods(joinpath(mktempdir(), "n.fods"), xf), String)
    lotag(s, n) = replace(match(Regex("<table:table table:name=\"" * n * "\"[^>]*>\\s*<loext:table-protection[^>]*/>"), s).match,
                          r" table:style-name=\"[^\"]*\"" => "", r">\s+<" => "><")
    @test lotag(t, "Secret") == lotag(own, "Secret") && lotag(t, "NoPassword") == lotag(own, "NoPassword")
    @test match(r"<office:spreadsheet[^>]*>", t).match == match(r"<office:spreadsheet[^>]*>", own).match
    @test occursin("xmlns:loext=", match(r"<office:document [^>]*>", t).match)
    # the options as LibreOffice's import wrote them for XLSX.jl's permissions
    im = read(joinpath(PROT, "lo-prot-xlsx-import.fods"), String)
    opts(s, n) = match(Regex("<table:table table:name=\"" * n * "\"[^>]*>\\s*(<loext:table-protection[^>]*/>)"), s).captures[1]
    xf = newods("insertColumns")
    for n in ("insertRows", "deleteColumns", "deleteRows", "autoFilter", "pivotTables", "Nothing")
        addsheet!(xf, n)
    end
    for n in ("insertColumns", "insertRows", "deleteColumns", "deleteRows", "autoFilter", "pivotTables")
        protectSheet(xf[n]; Symbol(n) => true)
    end
    protectSheet(xf["Nothing"]; selectLockedCells = false, selectUnlockedCells = false)
    t = read(writeods(joinpath(mktempdir(), "o.fods"), xf), String)
    for n in ("insertColumns", "insertRows", "deleteColumns", "deleteRows", "autoFilter", "pivotTables", "Nothing")
        @test opts(t, n) == opts(im, n)
    end
    # LibreOffice accepted OpenDocumentSpreadsheets' keys (part B): a wrong password refused, the right one taken
    rows = [split(l, '\t') for l in eachline(joinpath(PROT, "lo-prot.tsv")) if startswith(l, "odsf\t")]
    @test any(r -> r[2] == "Unicode right" && startswith(r[3], "ok isProtected=False"), rows)
    @test all(r -> !endswith(r[2], " wrong") || startswith(r[3], "refused"), rows) && count(r -> endswith(r[2], " right"), rows) == 6
    @test all(r -> !endswith(r[2], " right") || startswith(r[3], "ok"), rows)
end

@testset "protection: XLSX.jl's cases and errors" begin
    xf = newods("S")
    s = xf[1]
    s["A1:C3"] = 1
    @test !isSheetProtected(s) && getSheetProtection(s) === nothing && !unprotectSheet(s)
    protectSheet(s)
    @test isSheetProtected(s) && getSheetProtection(s) == (password = false, selectLockedCells = true, selectUnlockedCells = true,
        formatCells = false, formatColumns = false, formatRows = false, insertColumns = false, insertRows = false,
        insertHyperlinks = false, deleteColumns = false, deleteRows = false, sort = false, autoFilter = false,
        pivotTables = false, objects = false, scenarios = false)
    protectSheet(s; password = "x", insertRows = true, sort = false)       # replaces the settings
    @test getSheetProtection(s).password && getSheetProtection(s).insertRows
    @test_throws ODSError protectSheet(s; sort = true)                     # LibreOffice has no such permission
    @test_throws ODSError protectSheet(s; formatCells = true)
    @test_throws ODSError protectSheet(s; bogus = true)
    @test_throws ODSError protectSheet(s; insertRows = 1)
    @test unprotectSheet(s) && !isSheetProtected(s)
    @test !isWorkbookProtected(xf) && !unprotectWorkbook(xf)
    protectWorkbook(xf)
    @test getWorkbookProtection(xf) == (password = false, structure = true, windows = false)
    @test_throws ODSError protectWorkbook(xf; windows = true)
    @test_throws ODSError protectWorkbook(xf; structure = false)
    @test unprotectWorkbook(xf) && !isWorkbookProtected(xf)
    ro = readods(joinpath(PROT, "lo-prot-own.fods"))
    @test_throws ODSError protectSheet(ro["Open"])
    @test_throws ODSError unprotectWorkbook(ro)
    @test_throws ODSError setCellProtection(ro["Open"], "A1"; locked = false)
    # cells
    setCellProtection(s, "B2"; locked = false)
    setCellProtection(s, "B2:C3"; hidden = true)                           # B2 stays unlocked
    setCellProtection(xf, "S.A:A"; locked = false)                         # a whole column
    @test getCellProtection(s, "B2") == (locked = false, hidden = true) && getCellProtection(s, "C3") == (locked = true, hidden = true)
    @test getCellProtection(s, 1000, 1) == (locked = false, hidden = false) && getCellProtection(xf, "S.D9") == (locked = true, hidden = false)
    @test_throws ODSError setCellProtection(s, "B2"; bogus = true)
    # a new file keeps them all
    protectSheet(s; password = "x")
    protectWorkbook(xf; password = "y")
    for ext in ("ods", "fods")
        r = readods(writeods(joinpath(mktempdir(), "p.$ext"), xf))
        @test getSheetProtection(r["S"]).password && isWorkbookProtected(r) && getWorkbookProtection(r).password
        @test getCellProtection(r["S"], "B2") == (locked = false, hidden = true) && getCellProtection(r["S"], "A500").locked == false
    end
    # copies and renames keep it
    c = copysheet!(s, "Copy")
    renamesheet!(s, "S2")
    r = readods(writeods(joinpath(mktempdir(), "c.ods"), xf))
    @test isSheetProtected(r["Copy"]) && isSheetProtected(r["S2"]) && getCellProtection(r["Copy"], "B2").locked == false
end

@testset "a patched save changes only the protection edited (D-023)" begin
    src = joinpath(PROT, "lo-prot-own.fods")
    orig = read(src, String)
    dir = mktempdir()
    starttag(s, n) = match(Regex("<table:table table:name=\"" * n * "\"[^>]*>"), s).match
    # unprotected: the start tag loses its attributes, the options go
    xf = openods(src; mode = "rw")
    unprotectSheet(xf["Secret"])
    out = read(writeods(joinpath(dir, "a.fods"), xf), String)
    m = match(r"(<table:table table:name=\"Secret\"[^>]*>)(\s*)(<loext:table-protection[^>]*/>)", orig)
    @test out == replace(orig, m.match => "<table:table table:name=\"Secret\" table:style-name=\"ta1\">" * m.captures[2])
    # protected: attributes added, the options after the start tag
    xf = openods(src; mode = "rw")
    protectSheet(xf["Open"]; password = "secret")
    out = read(writeods(joinpath(dir, "b.fods"), xf), String)
    k = OpenDocumentSpreadsheets._protection_key("secret")
    @test out == replace(orig, starttag(orig, "Open") =>
        "<table:table table:name=\"Open\" table:style-name=\"ta1\" table:protected=\"true\" table:protection-key=\"$k\" " *
        "table:protection-key-digest-algorithm=\"http://www.w3.org/2000/09/xmldsig#sha1\">" *
        "<loext:table-protection loext:select-protected-cells=\"true\" loext:select-unprotected-cells=\"true\"/>")
    # the structure unprotected: office:spreadsheet's start tag alone changes
    xf = openods(src; mode = "rw")
    unprotectWorkbook(xf)
    out = read(writeods(joinpath(dir, "c.fods"), xf), String)
    @test out == replace(orig, match(r"<office:spreadsheet[^>]*>", orig).match => "<office:spreadsheet>")
    # an edited sheet (its cells patched) keeps its new protection too
    xf = openods(src; mode = "rw")
    xf["Secret"]["E5"] = "new"
    protectSheet(xf["Secret"]; password = "other", insertRows = true)
    r = readods(writeods(joinpath(dir, "d.fods"), xf))
    @test getSheetProtection(r["Secret"]).insertRows && r["Secret"]["E5"] == "new"
    @test occursin(OpenDocumentSpreadsheets._protection_key("other"), read(joinpath(dir, "d.fods"), String))
    # cell protection on a file read
    xf = openods(src; mode = "rw")
    setCellProtection(xf["Cells"], "B2"; locked = true)
    r = readods(writeods(joinpath(dir, "e.fods"), xf))
    @test getCellProtection(r["Cells"], "B2").locked && getCellProtection(r["Cells"], "A4") == (locked = false, hidden = true)
    @test read(writeods(joinpath(dir, "u.fods"), openods(src; mode = "rw")), String) == orig
end

@testset "LibreOffice reads the protection" begin
    if isempty(SOFFICE) || !isfile(SOFFICE)
        @info "LibreOffice not found; skipping the protection oracle (set ODS_SOFFICE)"
        @test_skip false
    else
        dir = mktempdir()
        profile = lo_profile_url(joinpath(dir, "lo-profile"))
        xf = newods("A"); addsheet!(xf, "B")
        xf["A"]["A1:C3"] = 1
        protectSheet(xf["A"]; password = "secret", insertColumns = true, autoFilter = true, selectLockedCells = false)
        setCellProtection(xf["A"], "B2"; locked = false); setCellProtection(xf["A"], "C3"; hidden = true)
        protectWorkbook(xf; password = "book")
        files = [writeods(joinpath(dir, "new.ods"), xf)]
        pf = openods(joinpath(PROT, "lo-prot-own.fods"); mode = "rw")
        unprotectSheet(pf["Secret"]); protectSheet(pf["Open"]; deleteRows = true); unprotectWorkbook(pf)
        setCellProtection(pf["Open"], "A1"; hidden = true)
        push!(files, writeods(joinpath(dir, "patched.fods"), pf))
        run(pipeline(`$SOFFICE -env:UserInstallation=$profile --headless --norestore --convert-to fods --outdir $(joinpath(dir, "lo")) $files`;
                     stdout = devnull, stderr = devnull))
        lo = readods(joinpath(dir, "lo", "new.fods"))
        p = getSheetProtection(lo["A"])
        @test p.password && p.insertColumns && p.autoFilter && !p.selectLockedCells && p.selectUnlockedCells && !isSheetProtected(lo["B"])
        @test getCellProtection(lo["A"], "B2") == (locked = false, hidden = false) && getCellProtection(lo["A"], "C3") == (locked = true, hidden = true)
        @test getWorkbookProtection(lo) == (password = true, structure = true, windows = false)
        t = read(joinpath(dir, "lo", "new.fods"), String)
        @test occursin(OpenDocumentSpreadsheets._protection_key("secret"), t) && occursin(OpenDocumentSpreadsheets._protection_key("book"), t)
        lp = readods(joinpath(dir, "lo", "patched.fods"))
        @test !isSheetProtected(lp["Secret"]) && getSheetProtection(lp["Open"]).deleteRows && !isWorkbookProtected(lp)
        @test getCellProtection(lp["Open"], "A1") == (locked = true, hidden = true)
    end
end

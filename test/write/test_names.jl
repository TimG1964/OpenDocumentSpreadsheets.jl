# Defined names (phase 5 step 5; D-058, F-050): addDefinedName, deleteDefinedName,
# deleteAllDefinedNames, getDefinedNames, getAllDefinedNames, against LibreOffice's rules and stored
# forms (experiment 028, test/data/names/), in the model, in saved files and through LibreOffice.
# XLSX.jl's sheets/defined-names.jl cases are ported where ODF has them. Uses SHIFT from
# formula/test_refs.jl.

using OpenDocumentSpreadsheets: getDefinedNames, getAllDefinedNames, DefinedName, NameDef, ODSError, getFormula,
    insertRows, renamesheet!, copysheet!, deletesheet!
using OpenDocumentSpreadsheets.SheetCore: CellRange, CellRef

ref(s) = OpenDocumentSpreadsheets.parse_sheet_ref(s)
nc(sheet, areas...) = OpenDocumentSpreadsheets.NonContiguousRange(sheet, Union{CellRef,CellRange}[areas...])

const NAMES = joinpath(DATA, "names")

# The text of the only match of `rx` in `s`.
only_match(rx, s) = (ms = collect(eachmatch(rx, s)); @assert length(ms) == 1; ms[1].match)

@testset "names LibreOffice accepts (experiment 028)" begin
    xf = newods("S")
    for l in eachline(joinpath(NAMES, "lo-names-rules.tsv"))
        name, scope, verdict = split(l, '\t'; limit = 3)
        target = scope == "local" ? xf["S"] : xf
        ok = try
            addDefinedName(target, name, "S.A1")
            true
        catch e
            e isa ODSError || rethrow()
            false
        end
        @test ok == (verdict == "ok") || (@info "name rule" name verdict; false)
    end
end

@testset "stored forms are LibreOffice's (experiment 028)" begin
    lo = Dict{String,Vector{String}}()
    for l in eachline(joinpath(NAMES, "lo-names-stored.tsv"))
        f = split(l, '\t')
        lo[f[1] * "|" * f[2]] = String.(f[3:5])
    end
    xf = newods("S")
    addDefinedName(xf, "Abc", "\$S.\$A\$1")
    addDefinedName(xf["S"], "Abc", "S.B2")
    addDefinedName(xf, "multi2", "S.A1:A2~S.C1")
    addDefinedName(xf, "num", 42)
    addDefinedName(xf, "txt", "hi")
    addDefinedName(xf, "frm", "=SUM(\$S.\$A\$1:\$A\$3)*2")
    addDefinedName(xf, "fx_a", "=SUM(S.A2:A4)*2")
    form(dn) = [dn.range === nothing ? "named-expression" : "named-range", dn.base, something(dn.range, dn.expression)]
    for dn in OpenDocumentSpreadsheets._wb_names(xf)
        @test form(dn) == lo["|" * dn.name]
    end
    @test form(only(OpenDocumentSpreadsheets._local_names(xf["S"]))) == lo["S|Abc"]
    # what OpenDocumentSpreadsheets reads LibreOffice's forms as
    v(dn) = DefinedName(NameDef(dn, nothing, nothing, lo["|" * dn][3], "\$S.\$A\$1"))
    @test v("multi").value == nc("S", CellRange("A1:A2"), CellRef("C1"))   # `;` between the areas
    @test v("multi2").value == v("multi").value && v("multi2").absolute == [true, true]
    @test v("num").value === Int64(42) && v("txt").value == "hi" && v("frm").value == "=SUM(\$S.\$A\$1:\$A\$3)*2"
    rel = DefinedName(NameDef("rel", nothing, ".B2", nothing, "\$S.\$A\$1"))       # no sheet: the base's
    @test rel.value == ref("S.B2") && rel.absolute == false
end

@testset "adding, reading and deleting names (XLSX.jl's cases)" begin
    xf = newods()
    s = xf[1]
    s["A1:B3"] = "Hello world"
    addDefinedName(xf, "Life_the_Universe_and_Everything", 42)
    addDefinedName(xf[1], "FirstName", "Hello World")
    addDefinedName(xf, "MyCell", "Sheet1!A1")
    addDefinedName(xf[1], "YourCells", "Sheet1.A2:B3")
    @test_throws ODSError addDefinedName(s, "yourcells", "Sheet1!A2:B3")    # not unique (case insensitive)
    @test_throws ODSError addDefinedName(s, "firstname", "NewText")
    @test_throws ODSError addDefinedName(xf, "A1", "Sheet1!B1")
    @test_throws ODSError addDefinedName(xf, "A1:A3", "Sheet1!B2:B3")
    @test_throws ODSError addDefinedName(xf, "A1,A3", 42)
    @test_throws ODSError addDefinedName(s, "Sheet1!A1", "Sheet1!B1")
    @test_throws ODSError addDefinedName(xf, "rc", 1)
    @test_throws ODSError addDefinedName(xf, "", 1)
    @test_throws ODSError addDefinedName(xf, "empty", "")
    @test_throws ODSError addDefinedName(xf, "nosheet", "A1")               # a workbook name needs its sheet
    @test_throws ODSError addDefinedName(xf, "nosuch", "Nope.A1")
    @test_throws ODSError addDefinedName(xf, "inf", Inf)
    @test_throws ODSError addDefinedName(xf, "nc", "Sheet1.A1,Sheet1.B2"; absolute = [true])
    @test_throws ODSError addDefinedName(readods(joinpath(DATA, "lo-tables.ods")), "x", 1)
    s["MyCell"] = true
    @test s["MyCell"] == true
    s["YourCells"] = false
    @test s["YourCells"] == Any[false false; false false]
    @test xf["Life_the_Universe_and_Everything"] == 42 && s["FirstName"] == "Hello World"
    # the same name in a sheet's scope and the file's: the sheet's wins on the sheet
    addDefinedName(xf, "FirstName", "Other")
    @test s["FirstName"] == "Hello World" && xf["FirstName"] == "Other"
    # values of each kind come back as they went in
    addDefinedName(xf, "nc", "Sheet1.A1:A2,Sheet1.C1"; absolute = [true, false])
    addDefinedName(xf, "cols", "Sheet1.B:D")
    addDefinedName(xf, "rows", ref("Sheet1.2:3"))
    addDefinedName(xf, "rel", "Sheet1.B2:C3"; absolute = false)
    addDefinedName(xf, "flt", 2.5)
    addDefinedName(xf, "yes", true)
    addDefinedName(xf, "f", "=MyCell*2")
    addDefinedName(s, "loc", "A1,B2")
    got = Dict(dn.name => dn for dn in getAllDefinedNames(xf))
    @test got["nc"].value == nc("Sheet1", CellRange("A1:A2"), CellRef("C1")) && got["nc"].absolute == [true, false]
    @test got["cols"].value == ref("Sheet1.B:D") && got["cols"].absolute
    @test got["rows"].value == ref("Sheet1.2:3")
    @test got["rel"].value == ref("Sheet1.B2:C3") && got["rel"].absolute == false
    @test got["flt"].value === 2.5 && got["yes"].value === true && got["f"].value == "=MyCell*2"
    @test got["loc"].value == nc("Sheet1", CellRef("A1"), CellRef("B2")) && got["loc"].scope == "Sheet1"
    # sorted: by name in a scope, and by scope (the file's first) then name
    all_ = getAllDefinedNames(xf)
    @test issorted(all_; by = dn -> (something(dn.scope, ""), uppercase(dn.name)))
    @test [dn.name for dn in getDefinedNames(xf[1])] == ["FirstName", "loc", "YourCells"]
    @test [dn.name for dn in all_ if dn.scope === nothing] == [dn.name for dn in getDefinedNames(xf)]
    # every name can be made again from what getDefinedNames gives
    xf2 = newods()
    for dn in getDefinedNames(xf)
        addDefinedName(xf2, dn.name, dn.value; absolute = dn.absolute)
    end
    @test getDefinedNames(xf2) == getDefinedNames(xf)
    # show
    @test sprint(show, got["flt"]) == "flt = 2.5"
    @test occursin("[Worksheet: \"Sheet1\"]", sprint(show, MIME"text/plain"(), all_))
    @test occursin("scope: Workbook", sprint(show, MIME"text/plain"(), got["f"]))
    @test sprint(show, MIME"text/plain"(), DefinedName[]) == "0-element Vector{DefinedName}"
    # a new file saves them, and reads them back
    p = writeods(joinpath(mktempdir(), "names.ods"), xf)
    r = readods(p)
    @test getAllDefinedNames(r) == getAllDefinedNames(xf)
    @test r[1]["MyCell"] == true && r[1]["YourCells"] == Any[false false; false false] && r["FirstName"] == "Other"
    # sheets with names that need quoting
    q = newods("Tim's Sheet")
    addsheet!(q, "Ano'ther She'et")
    q[1]["A1"] = "tim"; q[2]["A1"] = "another"
    addDefinedName(q, "mine", "'Tim''s Sheet'!A1")       # quoted, as every reference with a ' in its sheet
    addDefinedName(q, "yours", "'Ano''ther She''et'.A1")
    @test q["mine"] == "tim" && q["yours"] == "another"
    q2 = readods(writeods(joinpath(mktempdir(), "q.ods"), q))
    @test q2["mine"] == "tim" && q2["yours"] == "another"
end

@testset "a name refers to cells on another sheet (Q-031)" begin
    xf = newods("S")
    s = xf["S"]
    d = addsheet!(xf, "Data")
    d["A1"] = 42; d["B1:B3"] = [1; 2; 3;;]
    addDefinedName(s, "other", "Data.A1")             # S's own name, Data's cells
    addDefinedName(s, "otherRange", "Data.B1:B3")
    addDefinedName(xf, "fileName", "Data.A1")
    # read through the sheet, as LibreOffice reads `=other` on S (42; the oracle below)
    @test s["other"] == 42 && s["fileName"] == 42
    @test s["otherRange"] == Any[1; 2; 3;;]
    @test OpenDocumentSpreadsheets.getcell(s, "other").value == 42
    # written and formatted where the cells are
    s["other"] = 7
    @test d["A1"] == 7 && s["A1"] === missing
    s["fileName"] = 8
    @test d["A1"] == 8 && s["A1"] === missing
    setFont(s, "otherRange"; bold = true)
    bold(sh, c) = haskey(OpenDocumentSpreadsheets.getFont(sh, c).font, "b")     # bold is a flag key
    @test bold(d, "B2") && !bold(s, "B2")                                       # Data's cells, not S's
    # a name of S on S's own cells is unchanged
    addDefinedName(s, "mine", "S.C1")
    s["mine"] = 3
    @test s["C1"] == 3 && s["mine"] == 3
end

@testset "deleteDefinedName and deleteAllDefinedNames (XLSX.jl's cases)" begin
    mk() = begin
        f = newods("S")
        addDefinedName(f, "A_one", "S.A1"); addDefinedName(f, "B_two", 2); addDefinedName(f, "both", 3)
        addDefinedName(f["S"], "both", 4); addDefinedName(f["S"], "L_only", "B2")
        f
    end
    f = mk()
    deleteDefinedName(f, "a_ONE")                                         # without regard to case
    @test [dn.name for dn in getDefinedNames(f)] == ["both", "B_two"]
    deleteDefinedName(f["S"], "both")                                    # the scopes are independent
    @test [dn.name for dn in getDefinedNames(f)] == ["both", "B_two"] && [dn.name for dn in getDefinedNames(f["S"])] == ["L_only"]
    f = mk()
    @test_throws ODSError deleteDefinedName(f, "NO_SUCH_NAME")
    @test_throws ODSError deleteDefinedName(f["S"], "B_two")              # the file's, not the sheet's
    @test_throws ODSError deleteDefinedName(f, "")
    @test_throws ODSError deleteDefinedName(f, ["A_one", "NO_SUCH_NAME"])  # checked before any is deleted
    @test_throws ODSError deleteDefinedName(f, ["A_one", "a_one"])         # given twice
    @test length(getDefinedNames(f)) == 3
    @test_throws ODSError deleteDefinedName(f["S"], getDefinedNames(f))    # DefinedNames of another scope
    @test_throws ODSError deleteDefinedName(f, getDefinedNames(f["S"]))
    @test_throws ODSError deleteDefinedName(f["S"], getAllDefinedNames(f))
    deleteDefinedName(f, ["A_one", "both"]; force = true)
    @test [dn.name for dn in getDefinedNames(f)] == ["B_two"]
    deleteDefinedName(f["S"], getDefinedNames(f["S"]))                    # clearing one scope
    @test isempty(getDefinedNames(f["S"])) && length(getDefinedNames(f)) == 1
    deleteDefinedName(f, String[])                                        # nothing to do
    f = mk()
    deleteAllDefinedNames(f)
    @test isempty(getAllDefinedNames(f))
    r = readods(writeods(joinpath(mktempdir(), "none.ods"), f))
    @test isempty(getAllDefinedNames(r))
    @test_throws ODSError deleteDefinedName(readods(joinpath(DATA, "lo-tables.ods")), "x")
end

@testset "a patched save changes only the names edited (D-023)" begin
    src = joinpath(SHIFT, "lo-shift-before.fods")
    orig = read(src, String)
    dir = mktempdir()
    nr = only_match(r"<table:named-range table:name=\"NR\"[^>]*/>", orig)
    localel = only_match(r"<table:named-expressions>\s*<table:named-range table:name=\"LocalN\"[^>]*/>\s*</table:named-expressions>", orig)
    # a workbook name deleted, one added: the rest of the file is as it was
    xf = openods(src; mode = "rw")
    deleteDefinedName(xf, "NR")
    addDefinedName(xf, "Added", "Data.B2:C3")
    out = read(writeods(joinpath(dir, "a.fods"), xf), String)
    added = "<table:named-range table:name=\"Added\" table:base-cell-address=\"\$Data.\$A\$1\" table:cell-range-address=\"\$Data.\$B\$2:.\$C\$3\"/>"
    k = findlast("</table:named-expressions>", orig)
    want = replace(orig[1:prevind(orig, first(k))], nr => "") * added * orig[first(k):end]
    @test out == want
    # the only local name deleted: its element goes
    xf = openods(src; mode = "rw")
    deleteDefinedName(xf["Data"], "LocalN")
    out = read(writeods(joinpath(dir, "b.fods"), xf), String)
    @test out == replace(orig, localel => "")
    # a local name added beside it
    xf = openods(src; mode = "rw")
    addDefinedName(xf["Data"], "LAdd", 7)
    out = read(writeods(joinpath(dir, "c.fods"), xf), String)
    la = "<table:named-expression table:name=\"LAdd\" table:base-cell-address=\"\$Data.\$A\$1\" table:expression=\"7\"/>"
    @test out == replace(orig, localel => replace(localel, "</table:named-expressions>" => la * "</table:named-expressions>"))
    # all of them
    xf = openods(src; mode = "rw")
    deleteAllDefinedNames(xf)
    out = read(writeods(joinpath(dir, "d.fods"), xf), String)
    wbel = only_match(r"<table:named-expressions>\s*<table:named-expression table:name=\"NExpr\".*?</table:named-expressions>"s, orig)
    @test out == replace(orig, localel => "", wbel => "")
    @test isempty(getAllDefinedNames(readods(joinpath(dir, "d.fods"))))
    # a file whose names' element is empty (`<table:named-expressions/>`)
    xf = openods(joinpath(DATA, "lo-values.fods"); mode = "rw")
    @test isempty(getAllDefinedNames(xf))
    addDefinedName(xf, "V_one", 5)
    out = read(writeods(joinpath(dir, "v.fods"), xf), String)
    vo = read(joinpath(DATA, "lo-values.fods"), String)
    base = "\$" * OpenDocumentSpreadsheets.SheetCore.quoteit(OpenDocumentSpreadsheets.sheetnames(xf)[1]) * ".\$A\$1"
    @test out == replace(vo, "<table:named-expressions/>" => "<table:named-expressions><table:named-expression table:name=\"V_one\" " *
                         "table:base-cell-address=\"$base\" table:expression=\"5\"/></table:named-expressions>")
    # a file without the element gets one after its tables; a sheet, at its end
    nf = newods("One")
    nf["One"]["A1"] = 3
    xf = openods(writeods(joinpath(dir, "none.ods"), nf); mode = "rw")
    addDefinedName(xf, "T_one", "\$One.\$A\$1")
    addDefinedName(xf[1], "T_two", 5)
    p = writeods(joinpath(dir, "e.ods"), xf)
    r = readods(p)
    @test [dn.name for dn in getAllDefinedNames(r)] == ["T_one", "T_two"] && r["T_one"] == 3 && r[1]["T_two"] == 5
    c = String(OpenDocumentSpreadsheets.read_xml(OpenDocumentSpreadsheets.open_container(p), :content))
    @test occursin(r"</table:table><table:named-expressions><table:named-range table:name=\"T_one\""s, c)
    @test occursin(r"<table:named-expressions><table:named-expression table:name=\"T_two\"[^>]*/></table:named-expressions></table:table>"s, c)
end

@testset "names with structural edits" begin
    src = joinpath(SHIFT, "lo-shift-before.fods")
    xf = openods(src; mode = "rw")
    addDefinedName(xf, "Mine", "Data.A5:A8")
    deleteDefinedName(xf, "NExpr")
    insertRows(xf["Data"], 5; count = 2)                                 # both the new and the kept names move
    @test xf["Mine"] == xf["NR"]
    @test getAllDefinedNames(xf)[findfirst(dn -> dn.name == "Mine", getAllDefinedNames(xf))].value == ref("Data.A7:A10")
    renamesheet!(xf["Data"], "D2")
    p = writeods(joinpath(mktempdir(), "s.fods"), xf)
    r = readods(p)
    got = Dict(dn.name => dn.value for dn in getAllDefinedNames(r))
    @test got["Mine"] == ref("D2.A7:A10") && got["NR"] == ref("D2.A7:A10") && !haskey(got, "NExpr")
    # a copy has the source's local names, those added too
    xf = openods(src; mode = "rw")
    addDefinedName(xf["Data"], "LAdd", "Data.B2")
    deleteDefinedName(xf["Data"], "LocalN")
    c = copysheet!(xf["Data"], "Copy")
    cn = [dn.name for dn in getDefinedNames(c)]
    @test "LAdd" in cn && !("LocalN" in cn)
    r = readods(writeods(joinpath(mktempdir(), "c.fods"), xf))
    @test "LAdd" in [dn.name for dn in getDefinedNames(r["Copy"])] && "LAdd" in [dn.name for dn in getDefinedNames(r["Data"])]
    @test getDefinedNames(r["Copy"])[findfirst(dn -> dn.name == "LAdd", getDefinedNames(r["Copy"]))].value == ref("Copy.B2")
    # deleting the sheet a name refers to: #REF!, as LibreOffice
    xf = newods("A")
    addsheet!(xf, "B")
    addDefinedName(xf, "toB", "B.A1")
    deletesheet!(xf, "B")
    @test getDefinedNames(xf)[1].value == "=#REF!"
    # a zipped file
    xf = openods(joinpath(SHIFT, "lo-shift-before.ods"); mode = "rw")
    addDefinedName(xf, "Zip", 3)
    deleteDefinedName(xf, "NRel")
    r = readods(writeods(joinpath(mktempdir(), "z.ods"), xf))
    @test sort([dn.name for dn in getDefinedNames(r)]) == ["NExpr", "NR", "Zip"]
end

@testset "LibreOffice evaluates the names" begin
    if lo_ok(; what = "the names oracle")
        dir = mktempdir()
        profile = lo_profile_url(joinpath(dir, "lo-profile"))
        # experiment 028's sheet-relative names, used from two sheets
        xf = newods("S")
        addsheet!(xf, "T")
        for (k, (a, b)) in enumerate(((1, 10), (2, 20), (3, 30)))
            xf["S"][4 + k, 5] = a; xf["T"][4 + k, 5] = b
        end
        xf["S"]["B3"] = 5; xf["T"]["B3"] = 50; xf["S"]["A1"] = 5; xf["S"]["A2"] = 6; xf["S"]["C1"] = 7
        addDefinedName(xf, "fx_a", "=SUM(S.A2:A4)*2")
        addDefinedName(xf, "rl_a", "S.A2"; absolute = false)              # its sheet stays S (D-058)
        addDefinedName(xf, "multi", "S.A1:A2,S.C1")
        addDefinedName(xf, "num", 42)
        addDefinedName(xf, "txt", "hi")
        addDefinedName(xf["T"], "num", 1)                                  # hides the file's on T
        addDefinedName(xf["S"], "onT", "T.B3")                              # S's own name, T's cell (Q-031)
        setFormula(xf["S"], "F4"; val = "=onT")
        for (sh, cell) in (("S", "E4"), ("T", "E4"))
            setFormula(xf[sh], cell; val = "=fx_a")
        end
        setFormula(xf["S"], "B2"; val = "=rl_a")
        setFormula(xf["T"], "B2"; val = "=rl_a")
        setFormula(xf["S"], "F1"; val = "=SUM(multi)")
        setFormula(xf["S"], "F2"; val = "=num+1")
        setFormula(xf["T"], "F2"; val = "=num+1")
        setFormula(xf["S"], "F3"; val = "=txt")
        files = [writeods(joinpath(dir, "new.ods"), xf)]
        # a file LibreOffice wrote, patched
        pf = openods(joinpath(SHIFT, "lo-shift-before.ods"); mode = "rw")
        addDefinedName(pf, "Seven", 7)
        deleteDefinedName(pf, "NExpr")
        setFormula(pf["Data"], "Z1"; val = "=Seven*SUM(NR)")
        nrsum = sum(x -> x isa Number ? x : 0, pf["NR"])
        push!(files, writeods(joinpath(dir, "patched.ods"), pf))
        lo_convert(files, "fods"; outdir = joinpath(dir, "lo"), profile = profile)
        lo = readods(joinpath(dir, "lo", "new.fods"))
        want = Dict(split(l, '\t')[1] => parse(Float64, split(l, '\t')[2]) for l in eachline(joinpath(NAMES, "lo-names-values.tsv")))
        @test lo["S"]["E4"] == want["S.E4=fx_a"] && lo["T"]["E4"] == want["T.E4=fx_a"]
        @test lo["S"]["B2"] == 5 && lo["T"]["B2"] == 5                     # (LibreOffice's own rl_a gives 50 on T)
        @test lo["S"]["F1"] == 18 && lo["S"]["F2"] == 43 && lo["T"]["F2"] == 2 && lo["S"]["F3"] == "hi"
        @test lo["S"]["F4"] == 50 == xf["S"]["onT"]                         # LibreOffice and the package agree
        @test Set(dn.name for dn in getAllDefinedNames(lo)) == Set(dn.name for dn in getAllDefinedNames(xf))
        lp = readods(joinpath(dir, "lo", "patched.fods"))
        @test lp["Data"]["Z1"] == 7 * nrsum
        @test "Seven" in [dn.name for dn in getDefinedNames(lp)] && !("NExpr" in [dn.name for dn in getDefinedNames(lp)])
    end
end

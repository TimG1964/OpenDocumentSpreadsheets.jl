# Data validation (phase 6 step 6, D-075): LibreOffice's validations (F-061, F-068), with XLSX.jl's
# API. Fixtures: experiment 032 (test/data/validation): LibreOffice's own rules, the same with two
# removed, after an insert or delete (part C), and its import of XLSX.jl's 63 cases.
using Dates
const O_V = OpenDocumentSpreadsheets
using OpenDocumentSpreadsheets: ODSError
const VD = joinpath(@__DIR__, "..", "data", "validation")
_vd(f) = joinpath(VD, f)
const _DV_RULE = (:type, :operator, :formula1, :formula2, :allowBlank, :dropdown, :showInputMessage, :promptTitle, :prompt,
                  :showErrorMessage, :errorTitle, :error, :errorStyle)

_dv_key(v) = join((repr(x) for x in values(v[_DV_RULE])), "|")
# Every validated cell of a sheet (within `rows`, `cols`): (row, col) => the rule, without its range.
function _dv_grid(ws; rows = 1:80, cols = 1:10)
    g = Dict{Tuple{Int,Int},Any}()
    for v in O_V.getDataValidations(ws)
        for part in split(string(v.range), r"[~,]")
            p = occursin('.', part) ? split(part, '.')[end] : part
            cr = O_V.CellRange(occursin(':', p) ? p : p * ":" * p)
            for r in max(first(rows), O_V.row_number(cr.start)):min(last(rows), O_V.row_number(cr.stop)),
                c in max(first(cols), O_V.column_number(cr.start)):min(last(cols), O_V.column_number(cr.stop))
                @assert !haskey(g, (r, c))
                g[(r, c)] = _dv_key(v)
            end
        end
    end
    return g
end

# A file's rule elements, by the first cell that uses them, without name, base cell and whitespace.
function _dv_xml_by_cell(xf, sheet)
    ws = xf[sheet]
    s = xf.content
    rules = Dict(f.name => s[f.span] for f in O_V._file_rules(xf))
    out = Dict{String,String}()
    for v in O_V.getDataValidations(ws)
        first_ref = split(split(string(v.range), r"[~,]")[1], '.')[end]
        first_ref = split(first_ref, ':')[1]
        name = O_V._val_at(ws, O_V.row_number(O_V.CellRef(first_ref)), O_V.column_number(O_V.CellRef(first_ref)))
        x = replace(rules[name], r" table:name=\"[^\"]*\"" => "", r" table:base-cell-address=\"[^\"]*\"" => "", r">\s+<" => "><")
        out[first_ref] = x
    end
    return out
end

@testset "LibreOffice's own validations" begin
    xf = readods(_vd("lo-validation-own.fods")); ws = xf["Own"]
    v = O_V.getDataValidations(ws)
    @test length(v) == 19
    @test string(v[1].range) == "Own.B1:B1~Own.B24:B24~Own.B26:B26"         # one rule, three cells
    @test (v[1].type, v[1].operator, v[1].formula1, v[1].formula2) == (:whole, :between, "1", "10")
    @test (v[2].type, v[2].operator, v[2].formula1) == (:decimal, :greaterThan, "1.5")
    @test (v[3].type, v[3].formula1) == (:date, "DATE(2025,1,1)")
    @test (v[5].type, v[5].formula1, v[5].formula2) == (:time, "TIME(9,0,0)", "TIME(17,30,0)")
    @test (v[6].type, v[6].operator) == (:textLength, :notBetween)
    @test (v[7].type, v[7].operator, v[7].formula1, v[7].dropdown) == (:list, nothing, "\"a\",\"b\",\"c\"", true)
    @test v[8].formula1 == "\$D\$1:\$D\$2"
    @test (v[9].type, v[9].formula1) == (:custom, "ISNUMBER(B9)")
    @test v[10].dropdown == false && v[11].dropdown == true                 # hidden; sorted (shown)
    @test (v[12].promptTitle, v[12].prompt, v[12].errorTitle, v[12].error, v[12].errorStyle) == ("Range", "0 to 5", "Oops", "Out of range", :stop)
    @test (v[13].errorStyle, v[13].error) == (:warning, "Sure?") && v[14].errorStyle == :information
    @test v[15].allowBlank == false
    @test (v[16].showInputMessage, v[16].prompt, v[16].showErrorMessage) == (false, "hidden", false)
    @test string(v[18].range) == "B20:C22"
    g = _dv_grid(ws)
    @test _dv_key(O_V.getDataValidation(ws, "C21")) == g[(21, 3)] == _dv_key(v[18])
    @test O_V.getDataValidation(ws, 21, 3).range == v[18].range
    @test O_V.getDataValidation(ws, "A1") === nothing
    @test length(O_V.getDataValidations(xf)) == 19
    p = openods(_vd("lo-validation-own.fods"); mode = "rw")
    @test deleteDataValidation(p["Own"], "B1") == 0                        # B24 has it too
    @test deleteDataValidation(p, "Own.A1:B1,B20:C23") == 1                # val18's cells
    @test deleteDataValidation(p["Own"], "B1:B24") == 16                    # val2 to val17; val1 reaches B26
    @test _dv_grid(p["Own"]) == Dict(k => g[k] for k in ((1, 2), (24, 2), (26, 2), (28, 2)))
end

@testset "removing as LibreOffice removes: cells, and unused rules dropped" begin
    lo = _dv_grid(readods(_vd("lo-validation-own-removed.fods"))["Own"])
    for ext in ("fods",)
        p = openods(_vd("lo-validation-own.$ext"); mode = "rw"); ws = p["Own"]
        # LibreOffice's macro set B1 and B26 to `any`: here they are removed one by one
        O_V._set_val_blocks!(ws, [(1:1, 2:2), (26:26, 2:2)], nothing)
        @test _dv_grid(ws) == lo
        r = readods(writeods(joinpath(mktempdir(), "removed.$ext"), p))
        @test _dv_grid(r["Own"]) == lo
        @test length(O_V._file_rules(r)) == 19                              # val1 is still used by B24
    end
    p = openods(_vd("lo-validation-own.fods"); mode = "rw")
    @test deleteDataValidation(p["Own"], "B2") == 1
    @test deleteDataValidation(p["Own"], "B9:B9") == 1
    dp = writeods(joinpath(mktempdir(), "dropped.fods"), p); s = read(dp, String)
    @test !occursin("table:name=\"val2\"", s) && !occursin("table:name=\"val9\"", s)
    @test occursin("table:name=\"val3\"", s)                                # names kept (D-075)
    @test !occursin(r"\n\s*\n\s*<table:content-validation ", s)            # no blank lines left
    @test length(O_V.getDataValidations(readods(dp)["Own"])) == 17
    # all removed: the element goes
    p = openods(_vd("lo-validation-own.fods"); mode = "rw")
    @test deleteDataValidation(p["Own"], :) == 19
    s = read(writeods(joinpath(mktempdir(), "none.fods"), p), String)
    @test !occursin("content-validation", s)
end

@testset "XLSX.jl's 63 cases, as LibreOffice's import stores them" begin
    xf = newods("Val")
    ws = xf["Val"]
    ops = (:between, :notBetween, :equal, :notEqual, :greaterThan, :lessThan, :greaterThanOrEqual, :lessThanOrEqual)
    args = Dict(:whole => (1, 10), :decimal => (1.5, 9.25), :textLength => (2, 8),
                :date => (Date(2025, 1, 1), Date(2025, 12, 31)), :time => (Time(9, 0), Time(17, 30)))
    r = 0
    for t in (:whole, :decimal, :date, :time, :textLength), op in ops
        r += 1
        a, b = args[t]
        if op in (:between, :notBetween)
            addDataValidation(ws, "B$r"; type = t, operator = op, formula1 = a, formula2 = b)
        else
            addDataValidation(ws, "B$r"; type = t, operator = op, formula1 = a)
        end
    end
    addDataValidation(ws, "B41"; values = ["Red", "Green", "Blue"])
    addDataValidation(ws, "B42"; values = ["a \"q\"", "b;c", "Größe"])
    addDataValidation(ws, "B43"; type = :list, formula1 = "\$D\$1:\$D\$3")
    addDataValidation(ws, "B44"; type = :list, formula1 = "Lists!\$A\$1:\$A\$4")
    addDataValidation(ws, "B45"; values = ["x", "y"], dropdown = false)
    addDataValidation(ws, "B46"; type = :list, formula1 = "Colours")
    addDataValidation(ws, "B47"; type = :custom, formula1 = "=ISNUMBER(B47)")
    addDataValidation(ws, "B48:B49"; type = :custom, formula1 = "B48>A48")
    addDataValidation(ws, "B50"; type = :any, prompt = "Type here", promptTitle = "Hint")
    addDataValidation(ws, "B51"; type = :whole, formula1 = 0, formula2 = 5, prompt = "0 to 5", promptTitle = "Range", error = "Out of range", errorTitle = "Oops")
    addDataValidation(ws, "B52"; type = :whole, formula1 = 0, formula2 = 5, errorStyle = :warning, error = "Sure?")
    addDataValidation(ws, "B53"; type = :whole, formula1 = 0, formula2 = 5, errorStyle = :information)
    addDataValidation(ws, "B54"; type = :whole, formula1 = 0, formula2 = 5, prompt = "hidden", showInputMessage = false)
    addDataValidation(ws, "B55"; type = :whole, formula1 = 0, formula2 = 5, showErrorMessage = false)
    addDataValidation(ws, "B56"; type = :whole, formula1 = 0, formula2 = 5, allowBlank = false)
    addDataValidation(ws, "B57:C59"; type = :decimal, operator = :greaterThan, formula1 = 0)
    addDataValidation(ws, "B60,B62:C63"; type = :whole, operator = :lessThan, formula1 = 100)
    addDataValidation(ws, "F:F"; type = :textLength, operator = :lessThanOrEqual, formula1 = 3)
    addDataValidation(ws, "B64"; type = :whole, operator = :lessThan, formula1 = "\$D\$5")
    addDataValidation(ws, "B65"; type = :decimal, operator = :between, formula1 = "=D5/2", formula2 = "D5*2")
    addDataValidation(ws, "B66"; type = :date, operator = :greaterThan, formula1 = DateTime(2025, 6, 1, 12, 0))
    addDataValidation(ws, "B67"; type = :whole, formula1 = 0, formula2 = 5, prompt = "0 to 5", promptTitle = "Range", error = "Out of range", errorTitle = "Oops")
    ws["D1"] = "one"; ws["D2"] = "two"; ws["D3"] = "three"; ws["D5"] = 10
    l = addsheet!(xf, "Lists")
    for (i, v) in enumerate(("p", "q", "r", "s")); l[i, 1] = v; end
    addDefinedName(xf, "Colours", "Lists.\$A\$1:\$A\$3")
    o = addsheet!(xf, "Other"); o["A1"] = "x"
    addDataValidation(xf, "Other.A2:A5"; type = :whole, formula1 = 1, formula2 = 2)
    lo = readods(_vd("lo-validation-xlsx-import.fods"))
    for ext in ("ods", "fods")
        rd = readods(writeods(joinpath(mktempdir(), "cases.$ext"), xf))
        for sh in ("Val", "Other")
            @test _dv_grid(rd[sh]; rows = 1:70) == _dv_grid(lo[sh]; rows = 1:70)
            @test _dv_grid(rd[sh]; rows = 1:70) == _dv_grid(xf[sh]; rows = 1:70)
            @test sort(string.(getproperty.(O_V.getDataValidations(rd[sh]), :range))) == sort(string.(getproperty.(O_V.getDataValidations(lo[sh]), :range)))
        end
        ext == "fods" && @test _dv_xml_by_cell(rd, "Val") == _dv_xml_by_cell(lo, "Val")
        # the base cell is the rule's first cell, on its own sheet (the import's are all on `Other`, F-061)
        s = rd.content
        @test occursin("table:base-cell-address=\"Val.B48\"", s) && occursin("table:base-cell-address=\"Other.A2\"", s)
    end
    # one rule a case: the same rule at another first cell is its own (its base cell differs), as in the import
    @test count("<table:content-validation ", read(writeods(joinpath(mktempdir(), "c.fods"), xf), String)) == 63
end

@testset "addDataValidation: XLSX.jl's checks" begin
    xf = newods("S"); ws = xf["S"]
    @test_throws ODSError addDataValidation(ws, "A1")                                       # no type
    @test_throws ODSError addDataValidation(ws, "A1"; type = :bogus)
    @test_throws ODSError addDataValidation(ws, "A1"; type = :whole, formula1 = 1)           # between needs two
    @test_throws ODSError addDataValidation(ws, "A1"; type = :whole, operator = :equal, formula1 = 1, formula2 = 2)
    @test_throws ODSError addDataValidation(ws, "A1"; type = :whole, operator = :near, formula1 = 1)
    @test_throws ODSError addDataValidation(ws, "A1"; type = :whole, operator = :equal)
    @test_throws ODSError addDataValidation(ws, "A1"; type = :list)
    @test_throws ODSError addDataValidation(ws, "A1"; type = :list, values = String[])
    @test_throws ODSError addDataValidation(ws, "A1"; type = :whole, values = ["a"])
    @test_throws ODSError addDataValidation(ws, "A1"; values = ["a"], formula1 = "\$B\$1:\$B\$2")
    @test_throws ODSError addDataValidation(ws, "A1"; type = :list, operator = :equal, formula1 = "\$B\$1")
    @test_throws ODSError addDataValidation(ws, "A1"; type = :custom, formula1 = "A1>0", formula2 = "1")
    @test_throws ODSError addDataValidation(ws, "A1"; type = :any, formula1 = 1)
    @test_throws ODSError addDataValidation(ws, "A1"; type = :whole, operator = :equal, formula1 = 1, dropdown = false)
    @test_throws ODSError addDataValidation(ws, "A1"; type = :whole, operator = :equal, formula1 = 1, errorStyle = :fatal)
    @test_throws ODSError addDataValidation(ws, "A1"; type = :whole, operator = :equal, formula1 = true)
    @test_throws ODSError addDataValidation(ws, "A1"; type = :whole, operator = :equal, formula1 = "  ")
    @test_throws ODSError addDataValidation(ws, "A1"; type = :whole, operator = :equal, formula1 = [1])
    @test_throws ODSError addDataValidation(xf, "A1"; type = :any)                           # no sheet
    @test_throws ODSError addDataValidation(readods(_vd("lo-validation-own.fods"))["Own"], "A1"; type = :any)
    @test_throws ODSError deleteDataValidation(readods(_vd("lo-validation-own.fods"))["Own"], "A1")
    @test isempty(O_V.getDataValidations(ws))
    # the result, and replacing: one validation a cell
    v = addDataValidation(ws, "A1:A5"; type = :whole, operator = :greaterThan, formula1 = 0)
    @test (v.sheet, string(v.range), v.type, v.operator, v.formula1, v.formula2, v.dropdown) == ("S", "A1:A5", :whole, :greaterThan, "0", nothing, false)
    w = addDataValidation(ws, "A3"; values = [1, 2.5, "x"])
    @test (w.type, w.formula1, string(w.range)) == (:list, "\"1\",\"2.5\",\"x\"", "A3:A3")
    @test string(O_V.getDataValidation(ws, "A1").range) == "S.A1:A2~S.A4:A5"
    # the same rule again at the same first cell shares its name; a sheet-qualified range
    addDataValidation(ws, "A1:A5"; type = :whole, operator = :greaterThan, formula1 = 0)
    @test length(O_V.getDataValidations(ws)) == 1 && length(xf.valedits.added) == 2
    @test addDataValidation(xf, "S.C1"; type = :time, operator = :lessThan, formula1 = Time(12)).formula1 == "0.5"
    @test addDataValidation(xf, "'S'!D1"; type = :date, operator = :equal, formula1 = Date(1899, 12, 31)).formula1 == "1"
    @test deleteDataValidation(xf, "S.C1:D1") == 2
    @test deleteDataValidation(ws, "A1") == 0
    @test addDataValidation(ws, "A2"; type = :any) === nothing                    # restricts nothing: none stored
    @test O_V.getDataValidation(ws, "A2") === nothing && O_V.getDataValidation(ws, "A1") !== nothing
    @test deleteDataValidation(ws, "A1:A9") == 1
    @test isempty(O_V.getDataValidations(xf))
    @test !occursin("content-validation", read(writeods(joinpath(mktempdir(), "e.fods"), xf), String))
    # whole rows; a defined name
    addDefinedName(xf, "Area", "S.\$E\$2:\$F\$3")
    @test string(addDataValidation(ws, "Area"; type = :decimal, operator = :lessThan, formula1 = 1).range) == "E2:F3"
    @test string(addDataValidation(ws, "7:8"; type = :decimal, operator = :lessThan, formula1 = 1).range) == "A7:XFD8"
end

@testset "a patched save: validations added in LibreOffice's file, the rest kept" begin
    for ext in ("fods",)
        p = openods(_vd("lo-validation-own.$ext"); mode = "rw"); ws = p["Own"]
        g = _dv_grid(ws)
        v = addDataValidation(ws, "H1:H3"; type = :textLength, operator = :lessThan, formula1 = 5, error = "short")
        addDataValidation(ws, "B3"; values = ["p", "q"])                     # replaces val3 (B3 only): val3 dropped
        ws["H2"] = "value"; ws["B4"] = 12                                     # a validated cell's value set
        addDataValidation(ws, "J40"; type = :any, prompt = "beyond the table")
        r = readods(writeods(joinpath(mktempdir(), "added.$ext"), p))["Own"]
        g2 = _dv_grid(r; rows = 1:50)
        @test g2 == _dv_grid(ws; rows = 1:50)
        @test g2[(1, 8)] == g2[(3, 8)] == _dv_key(v) && startswith(g2[(3, 2)], ":list")
        @test all(g2[k] == g[k] for k in keys(g) if k != (3, 2))
        @test r["H2"] == "value" && r["B4"] == 12
        @test occursin("beyond the table", g2[(40, 10)])
        s = read(writeods(joinpath(mktempdir(), "added2.$ext"), p), String)
        @test !occursin("table:name=\"val3\"", s) && occursin("table:name=\"val20\"", s)
    end
    # a file without validations: the element is made before the first table
    p = openods(joinpath(@__DIR__, "..", "data", "images", "lo-images-own.fods"); mode = "rw")
    addDataValidation(p["Own"], "A1"; type = :whole, operator = :equal, formula1 = 1)
    vp = writeods(joinpath(mktempdir(), "v.fods"), p); s = read(vp, String)
    @test occursin(r"</table:content-validations>\s*<table:table ", s)
    @test _dv_grid(readods(vp)["Own"]) == Dict((1, 1) => _dv_grid(p["Own"])[(1, 1)])
end

@testset "inserts and deletes as LibreOffice does them (experiment 032 part C)" begin
    for (fix, f) in (("ins-r21", ws -> insertRows(ws, 21)), ("ins-r20", ws -> insertRows(ws, 20)),
                     ("ins-cC", ws -> insertColumns(ws, "C")), ("del-r2", ws -> deleteRows(ws, 2)))
        lo = _dv_grid(readods(_vd("lo-validation-own-$fix.fods"))["Own"])
        p = openods(_vd("lo-validation-own.fods"); mode = "rw"); ws = p["Own"]
        f(ws)
        @test _dv_grid(ws) == lo
        r = readods(writeods(joinpath(mktempdir(), "$fix.fods"), p))["Own"]
        @test _dv_grid(r) == lo
    end
    # after an insert (a mapped save): a validation and a note in an inserted row, and on one cell
    p = openods(_vd("lo-validation-own.fods"); mode = "rw"); ws = p["Own"]
    insertRows(ws, 5; count = 2)
    addDataValidation(ws, "B5:D5"; type = :whole, operator = :equal, formula1 = 7)
    addComment(ws, "C5", "both")
    addComment(ws, "E6", "note alone")
    addDataValidation(ws, "K60"; type = :whole, operator = :equal, formula1 = 8)  # past the table
    r = readods(writeods(joinpath(mktempdir(), "mapped.fods"), p))["Own"]
    @test _dv_grid(r; cols = 1:12) == _dv_grid(ws; cols = 1:12)
    @test O_V.getDataValidation(r, "C5").formula1 == "7" && O_V.getDataValidation(r, "B6").type == :date   # row 4's, copied
    @test O_V.getComment(r, "C5").text == "both" && O_V.getComment(r, "E6").text == "note alone"
    @test O_V.getDataValidation(r, "K60").formula1 == "8"
    # del-r2: val2's only cell goes, so val2 goes
    p = openods(_vd("lo-validation-own.fods"); mode = "rw"); deleteRows(p["Own"], 2)
    @test !occursin("table:name=\"val2\"", read(writeods(joinpath(mktempdir(), "d.fods"), p), String))
    # validations added, then moved: inserted lines take the line before's
    xf = newods("S"); ws = xf["S"]
    addDataValidation(ws, "B2:C4"; type = :custom, formula1 = "B2>\$A\$9")
    insertRows(ws, 3; count = 2)                  # inside: the block grows to B2:C6
    insertColumns(ws, "B")                        # at its first column: nothing to copy from A
    deleteRows(ws, 1)
    v = O_V.getDataValidations(ws)
    @test length(v) == 1 && string(v[1].range) == "C1:D5" && v[1].formula1 == "C1>\$A\$10"
    r = readods(writeods(joinpath(mktempdir(), "s.ods"), xf))
    @test _dv_grid(r["S"]) == _dv_grid(ws)
    @test occursin("base-cell-address=\"S.C1\"", r.content)
    deleteColumns(ws, "C:D")
    @test isempty(O_V.getDataValidations(ws))
    @test !occursin("content-validation", read(writeods(joinpath(mktempdir(), "s2.fods"), xf), String))
    # a renamed sheet's rules follow it; a copy of a new sheet has the same validations
    xf = newods("S"); ws = xf["S"]
    addDataValidation(ws, "A1:A2"; type = :list, formula1 = "\$B\$1:\$B\$3")
    renamesheet!(ws, "T")
    c = copysheet!(ws, "U")
    r = readods(writeods(joinpath(mktempdir(), "t.fods"), xf))
    @test _dv_grid(r["T"]) == _dv_grid(r["U"]) == _dv_grid(ws)
    @test occursin("base-cell-address=\"T.A1\"", r.content)
end

@testset "LibreOffice reads the validations" begin
    if isempty(SOFFICE) || !isfile(SOFFICE)
        @info "LibreOffice not found; skipping the validation oracle (set ODS_SOFFICE)"
        @test_skip false
    else
        dir = mktempdir()
        profile = lo_profile_url(joinpath(dir, "lo-profile"))
        xf = newods("S"); ws = xf["S"]
        addDataValidation(ws, "B2:B5"; type = :whole, formula1 = 1, formula2 = 10, prompt = "1 to 10", error = "No")
        addDataValidation(ws, "C:C"; values = ["a", "b \"c\""], dropdown = false)
        addDataValidation(ws, "D2"; type = :custom, formula1 = "=D2>B2")
        addDataValidation(ws, "E2"; type = :date, operator = :greaterThan, formula1 = Date(2025, 1, 1), errorStyle = :warning)
        ws["B2"] = 3
        a = writeods(joinpath(dir, "new.ods"), xf)
        b = writeods(joinpath(dir, "newflat.fods"), xf)
        p = openods(_vd("lo-validation-own.fods"); mode = "rw")
        addDataValidation(p["Own"], "H1:H3"; type = :textLength, operator = :lessThan, formula1 = 5)
        deleteDataValidation(p["Own"], "B2"); insertRows(p["Own"], 21); deleteRows(p["Own"], 5)
        c = writeods(joinpath(dir, "own.fods"), p)
        run(pipeline(`$SOFFICE -env:UserInstallation=$profile --headless --norestore --convert-to fods --outdir $(joinpath(dir, "lo")) $a $b $c`;
                     stdout = devnull, stderr = devnull))
        @test _dv_grid(readods(joinpath(dir, "lo", "new.fods"))["S"]) == _dv_grid(ws)
        @test _dv_grid(readods(joinpath(dir, "lo", "newflat.fods"))["S"]) == _dv_grid(ws)
        @test _dv_grid(readods(joinpath(dir, "lo", "own.fods"))["Own"]) == _dv_grid(p["Own"])
    end
end

# The file-level forms take the sheet up to the first `.` or `!` outside quotes, by character
# (code review, Phase 1 item 2): a quoted name ending in a multi-byte character threw, and a range
# naming its sheet twice was read as a sheet called `Sheet1.A1:Sheet1`.
@testset "file-level ranges: sheet names by character" begin
    xf = newods("Résumé")
    addsheet!(xf, "Two")
    addDataValidation(xf, "'Résumé'.A1:A3"; type = :whole, operator = :greaterThan, formula1 = 0)
    addDataValidation(xf, "Two.B1:Two.B3"; type = :whole, operator = :greaterThan, formula1 = 0)
    addDataValidation(xf, "'Two'!C1:C2"; type = :whole, operator = :greaterThan, formula1 = 0)
    @test sort(collect(keys(_dv_grid(xf["Résumé"])))) == [(1, 1), (2, 1), (3, 1)]
    @test sort(collect(keys(_dv_grid(xf["Two"])))) == [(1, 2), (1, 3), (2, 2), (2, 3), (3, 2)]
    @test_throws ODSError addDataValidation(xf, "Three.A1"; type = :any, prompt = "x")
end

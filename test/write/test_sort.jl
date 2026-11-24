# Sorting (phase 6 step 9, D-079): `setAutoFilter(...; sort)` as LibreOffice's Data ▸ Sort sorts
# (F-064, F-072). Fixtures: experiment 037 (test/data/sort: LibreOffice's save of the data before it
# sorted, the cases, and the rows its sort gave for each).
using Dates
const O_S = OpenDocumentSpreadsheets
using OpenDocumentSpreadsheets: ODSError, setAutoFilter, getAutoFilter, removeAutoFilter, isRowHidden, getFormula
const SD = joinpath(@__DIR__, "..", "data", "sort")
_sx(s) = (i = findfirst("<table:database-ranges", s); i === nothing ? "" : s[first(i):last(findnext("</table:database-ranges>", s, last(i)))])
_spath(xf, ext = "ods") = writeods(joinpath(mktempdir(), "s." * ext), xf)

# A row as experiment 037's ModuleA.bas writes it: columns A..F as LibreOffice's getFormula shows them.
function _srow(ws, r)
    parts = String[]
    for c in 1:6
        f = getFormula(ws, r, c)
        if f !== nothing && !isempty(f)
            push!(parts, f)
        else
            v = getdata(ws, r, c)
            s = v === missing ? "" : v isa Bool ? (v ? "1" : "0") : v isa AbstractFloat && isinteger(v) ? string(Int(v)) :
                v isa Date ? string(Dates.value(v - Date(1899, 12, 30))) : string(v)
            if v isa AbstractString
                (startswith(v, "'") || O_S._lo_number(v, Date(1899, 12, 30)) !== nothing) && (s = "'" * v)
            end
            push!(parts, s)
        end
    end
    s = join(parts, " | ")
    isRowHidden(ws, r) && (s *= " [hidden]")
    return s
end
# getFormula writes `,` between arguments and no braces around an array formula
_snorm(x) = join([startswith(p, "=") ? replace(p, ';' => ',') : p
                  for p in split(strip(replace(x, r"\s+" => " ", r"\{(=[^}]*)\}" => s"\1")), " | ")], " | ")

const _LO_SORTED = Dict(String(first(f)) => String.(f[2:end]) for f in (split(l, '\t') for l in eachline(joinpath(SD, "lo-sort-sorted.tsv"))))
const _SORT_CASES = [split(l, '\t') for l in eachline(joinpath(SD, "lo-sort-cases.tsv")) if !isempty(l)]
const _SORT_REFUSED = ("r_merge", "r_merge_row", "r_merge_in", "r_arrayin", "r_array1")   # r_array1: LibreOffice moves a one-cell array

_skeys(k) = [parse(Int, split(x, ':')[1]) => (split(x, ':')[2] == "asc" ? :ascending : :descending) for x in split(k, ',')]

@testset "Sort: LibreOffice's order and what it moves" begin
    xf = openods(joinpath(SD, "lo-sort-presort.ods"); mode = "rw")
    for f in _SORT_CASES
        name, cs, nat, attr, keys, rng = f[1], f[2] == "true", f[3] == "true", f[4] == "true", f[5], f[7]
        ws = xf[name]
        kw = (sort = _skeys(keys), caseSensitive = cs, naturalSort = nat, includeFormats = attr)
        if name in _SORT_REFUSED
            @test_throws ODSError setAutoFilter(ws, rng; kw...)
            continue
        end
        setAutoFilter(ws, rng; kw...)
        lo = _LO_SORTED[name]
        ours = [_srow(ws, r) for r in 2:length(lo)+1]
        if name == "r_array2"          # the array beside the range shows its values here
            ours = [join(split(x, " | ")[1:2], " | ") for x in ours]; lo = [join(split(x, " | ")[1:2], " | ") for x in lo]
        end
        @test (name => _snorm.(ours)) == (name => _snorm.(lo))
    end
    # the patched file, read again: LibreOffice's sort of the carry sheet (experiment 037 part C)
    r = readods(_spath(xf))
    ws = r["carry"]
    @test [getdata(ws, i, 1) for i in 2:7] == ["L3", "L5", "L2", "L7", "L4", "L6"]
    @test [getFormula(ws, i, 3) for i in 2:7] == ["=B1", "=E3", "=B4*2", "=B\$7+Pick", "=\$B\$2", "=SUM(B3:B8)"]
    @test all(i -> getdata(ws, i, 3) === missing, 2:7)                  # saved without values: LibreOffice computes them
    @test [getFormula(ws, i, 6) for i in 2:4] == ["=B3", "=SUM(B2:B7)", "=VLOOKUP(10,B2:C7,2,0)"]   # what refers to them stays
    @test O_S.getComment(ws, "D4").text == "note on D2" && O_S.getComment(ws, "D2") === nothing
    @test O_S.getHyperlink(ws, "D2").url == "https://example.org/" && O_S.getHyperlink(ws, "D3") === nothing
    @test O_S.getDataValidation(ws, "D6") !== nothing && O_S.getDataValidation(ws, "D4") === nothing
    @test sort([(i.from, i.to) for i in O_S.getImages(ws)]) == [("D3", "E4"), ("D4", "E5")]
    @test [isRowHidden(ws, i) for i in 2:7] == [false, false, false, false, false, true]
    @test O_S.getRowHeight(ws, "A4") == O_S.getRowHeight(readods(joinpath(SD, "lo-sort-presort.ods"))["carry"], "A4") > 25   # heights stay
    @test haskey(O_S.getFont(ws, "A4").font, "b") && !haskey(O_S.getFont(ws, "A2").font, "b")
    @test O_S.getFormat(ws, "B6").format["numFmt"]["formatCode"] == "0.00"
    ws = r["carry_noattr"]                                              # formats and validations stay
    @test haskey(O_S.getFont(ws, "A2").font, "b") && O_S.getDataValidation(ws, "D4") !== nothing && O_S.getDataValidation(ws, "D6") === nothing
    @test O_S.getComment(ws, "D4").text == "note on D2" && O_S.getHyperlink(ws, "D2").url == "https://example.org/"
    @test sort([(i.from, i.to) for i in O_S.getImages(ws)]) == [("D3", "E4"), ("D4", "E5")]
end

@testset "Sort: the stored form" begin
    xf = newods()
    ws = xf[1]
    for (i, (a, b)) in enumerate([("N", "K"), ("b", 2), ("a", 1), ("B", 3), ("c", 1)])
        ws[i, 1] = a; ws[i, 2] = b
    end
    setAutoFilter(ws, "A1:B5"; sort = ["K" => :descending, 1])
    @test [getdata(ws, i, 1) for i in 2:5] == ["B", "b", "a", "c"]
    @test occursin("<table:database-range table:name=\"__Anonymous_Sheet_DB__0\" table:target-range-address=\"Sheet1.A1:Sheet1.B5\" " *
                   "table:display-filter-buttons=\"true\"><table:sort><table:sort-by table:field-number=\"1\" table:order=\"descending\" " *
                   "table:data-type=\"automatic\"/><table:sort-by table:field-number=\"0\" table:data-type=\"automatic\"/></table:sort>" *
                   "</table:database-range>", _sx(read(_spath(xf, "fods"), String)))
    setAutoFilter(ws, "A1:B5"; sort = "A", caseSensitive = true, naturalSort = true, includeFormats = false)
    @test [getdata(ws, i, 1) for i in 2:5] == ["a", "b", "B", "c"]
    @test occursin("<table:sort table:bind-styles-to-content=\"false\" table:case-sensitive=\"true\" table:embedded-number-behavior=\"double\">" *
                   "<table:sort-by table:field-number=\"0\" table:data-type=\"automatic\"/></table:sort>", _sx(read(_spath(xf, "fods"), String)))
    # criteria join the sort, before it; the same range keeps it; removing the AutoFilter keeps it
    setAutoFilter(ws, "A1:B5"; filters = ["K" => 1])
    x = _sx(read(_spath(xf, "fods"), String))
    @test occursin("</table:filter><table:sort table:bind-styles-to-content=\"false\"", x)
    @test [isRowHidden(ws, i) for i in 2:5] == [false, true, true, false]
    @test removeAutoFilter(ws)
    @test occursin("table:target-range-address=\"Sheet1.A1:Sheet1.B5\"><table:sort ", _sx(read(_spath(xf, "fods"), String)))
    setAutoFilter(ws, "A1:B4")                                          # a new range has no sort
    @test !occursin("table:sort", _sx(read(_spath(xf, "fods"), String)))
    # sorted, then filtered: duplicates keep the first row in the sorted order
    xf = newods()
    ws = xf[1]
    ws[1, 1] = "V"; ws[1, 2] = "K"
    for (i, (v, k)) in enumerate([("x", 3), ("y", 1), ("x", 2)])
        ws[i + 1, 1] = v; ws[i + 1, 2] = k
    end
    setAutoFilter(ws, "A1:A4"; filters = ["V" => ("!=" => "")], noDuplicates = true, sort = 1 => :descending)
    @test [getdata(ws, i, 1) for i in 2:4] == ["y", "x", "x"] && [isRowHidden(ws, i) for i in 2:4] == [false, false, true]
    # a filter with the sort sees the formulas the sort moved with the values they had (they are saved
    # without one): right for formulas on their own row (=B4*2, 60); LibreOffice computes =B$7+Pick anew (80)
    xf = openods(joinpath(SD, "lo-sort-presort.ods"); mode = "rw")
    ws = xf["carry"]
    setAutoFilter(ws, "A1:D7"; sort = "Key", filters = ["F" => (">=" => 60)])
    @test [isRowHidden(ws, i) for i in 2:7] == [true, true, false, true, true, false]
end

@testset "Sort: notes, links, pictures and validations of a new sheet" begin
    xf = newods()
    ws = xf[1]
    ws[1, 1] = "K"; ws[1, 2] = "T"
    for (i, k) in enumerate([3, 1, 2])
        ws[i + 1, 1] = k
    end
    addComment(ws, "B2", "three")
    addHyperlink(ws, "B3"; url = "https://example.org/one", display = "one")
    addDataValidation(ws, "B4"; type = :whole, operator = :between, formula1 = 1, formula2 = 9)
    addImage(ws, "B2", joinpath(@__DIR__, "..", "data", "images", "red.png"))
    O_S.setFormula(ws, "C2"; val = "=A2*10")
    setAutoFilter(ws, "A1:C4"; sort = "K")
    check(ws) = begin
        @test [getdata(ws, i, 1) for i in 2:4] == [1, 2, 3]
        @test O_S.getComment(ws, "B4").text == "three" && O_S.getComment(ws, "B2") === nothing
        @test O_S.getHyperlink(ws, "B2").url == "https://example.org/one" && O_S.getHyperlink(ws, "B3") === nothing
        @test O_S.getDataValidation(ws, "B3") !== nothing && O_S.getDataValidation(ws, "B4") === nothing
        @test [i.from for i in O_S.getImages(ws)] == ["B4"]
        @test getFormula(ws, "C4") == "=A4*10"
    end
    check(ws)
    check(readods(_spath(xf, "fods"))[1])
    check(readods(_spath(xf, "ods"))[1])
end

@testset "Sort, then lines inserted and deleted" begin
    xf = openods(joinpath(SD, "lo-sort-presort.ods"); mode = "rw")
    ws = xf["carry"]
    setAutoFilter(ws, "A1:D7"; sort = "Key")
    insertRows(ws, 1)
    deleteRows(ws, 4)                                                   # L5's row (now 4): its picture is rescued
    exp = sort([(i.from, i.to) for i in O_S.getImages(ws)])
    @test exp == [("D4", "E4"), ("D4", "E5")]                         # the rescued one ends where its end cell went
    r = readods(_spath(xf))
    @test sort([(i.from, i.to) for i in O_S.getImages(r["carry"])]) == exp
    @test O_S.getComment(r["carry"], "D4").text == "note on D2" && O_S.getHyperlink(r["carry"], "D3").url == "https://example.org/"
    @test [getdata(r["carry"], i, 1) for i in 2:7] == ["Label", "L3", "L2", "L7", "L4", "L6"]
    # sheets the sort didn't touch are written as they were (D-023)
    src = joinpath(SD, "lo-sort-presort.ods")
    a = openods(src; mode = "rw")
    setAutoFilter(a["carry"], "A1:D7"; sort = "Key")
    s0 = readods(_spath(openods(src; mode = "rw"))).content; s1 = readods(_spath(a)).content     # content.xml
    t(s, n) = (i = findfirst("<table:table table:name=\"$n\"", s); s[first(i):last(findnext("</table:table>", s, last(i)))])
    @test t(s0, "asc") == t(s1, "asc") && t(s0, "punct") == t(s1, "punct")
end

@testset "Sort: LibreOffice's collation" begin
    lt(a, b; cs = false) = O_S._lo_collate(a, b, cs) < 0
    @test lt("ss", "ß") && lt("ae", "Æ") && lt("Æ", "af") && lt("a-b", "a%") && lt("_x", "#x") && lt(" lead", "_x")
    @test lt("e", "é") && lt("á", "å") && lt("å", "ä") && lt("z", "α") && lt("ω", "ж") && lt("한", "ア") && lt("ア", "中")
    @test O_S._lo_collate("a", "A", false) == 0 && lt("a", "A"; cs = true) && lt("あ", "ア"; cs = true)
    @test lt("1,000", "10") && lt("10", "10a") && lt("9", "a") && lt("th", "™") && lt("１", "¹"; cs = true)
    nat(a, b) = O_S._lo_nat_cmp(O_S._lo_nat_key(a), O_S._lo_nat_key(b), false)
    @test nat("a2", "a10") < 0 && nat("x9y", "x09y") == 0 && nat("v1.10", "v1.9") < 0 && nat("1e3", "999") > 0 && nat("item10", "item 9") < 0
    # numbers in other digits are text to the filters' number reader (a regression: `\d` matched them)
    @test O_S._lo_number("１２", Date(1899, 12, 30)) === nothing
end

@testset "Sort errors" begin
    xf = openods(joinpath(SD, "lo-sort-presort.ods"); mode = "rw")
    ws = xf["carry"]
    @test_throws ODSError setAutoFilter(ws, "A1:D7"; sort = [])
    @test_throws ODSError setAutoFilter(ws, "A1:D7"; sort = "Nope")
    @test_throws ODSError setAutoFilter(ws, "A1:D7"; sort = 5)
    @test_throws ODSError setAutoFilter(ws, "A1:D7"; sort = "Key" => :up)
    @test_throws ODSError setAutoFilter(ws, "A1:D7"; naturalSort = true)
    @test_throws ODSError setAutoFilter(ws, "A1:D7"; includeFormats = false)
    @test_throws ODSError setAutoFilter(ws, "A1:D7"; caseSensitive = true)
    @test_throws ODSError setAutoFilter(ws, "A1:D7"; sort = "Key", noDuplicates = true)
    @test [getdata(ws, i, 1) for i in 2:7] == ["L2", "L3", "L4", "L5", "L6", "L7"]   # nothing moved
    m = xf["r_merge"]
    @test_throws ODSError setAutoFilter(m, "A1:B4"; sort = 1)
    setAutoFilter(m, "A1:B4"; sort = 1, includeFormats = false)          # LibreOffice sorts it without formats
    @test [getdata(m, i, 1) for i in 2:4] == [1, 2, 3] && O_S.getMergedCells(m) == [O_S.CellRange("B2:B3")]
end

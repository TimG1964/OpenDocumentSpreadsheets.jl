# AutoFilters (phase 6 step 8, D-078): XLSX.jl's API on LibreOffice's anonymous sheet database range,
# with criteria stored and applied as LibreOffice stores and applies them (F-063, F-071). Fixtures:
# experiment 036 (test/data/filters: the data as LibreOffice saved it, and the rows LibreOffice's Refresh
# Range hides for each case) and experiment 033 (test/data/dbranges).
using Dates
const O_F = OpenDocumentSpreadsheets
using OpenDocumentSpreadsheets: ODSError, setAutoFilter, getAutoFilter, removeAutoFilter, isRowHidden, setRowHidden
const FD = joinpath(@__DIR__, "..", "data", "filters")
_fd(f) = joinpath(FD, f)
_fx(s) = (i = findfirst("<table:database-ranges", s); i === nothing ? "" : s[first(i):last(findnext("</table:database-ranges>", s, last(i)))])
_hidden(ws, rows) = [r for r in rows if isRowHidden(ws, r)]
_fpath(xf, ext = "fods") = writeods(joinpath(mktempdir(), "f." * ext), xf)

# The cases of experiment 036 part C (oracle.jl), on the data A1:E19.
const _DS = string('$')
const _AF_CASES = [
    "v_apple"      => (["Name" => "apple"], (;)),
    "v_list"       => (["Name" => ["apple", "pig", missing]], (;)),
    "v_num"        => (["Num" => 10], (;)),
    "v_nums"       => (["Num" => [2, 5]], (;)),
    "v_bool"       => (["Flag" => [true]], (;)),
    "v_boolnum"    => (["Num" => [true]], (;)),
    "v_date"       => (["When" => Date(2026, 11, 23)], (;)),
    "v_dates"      => (["When" => [Date(2026, 11, 23), DateTime(2026, 11, 23, 15)]], (;)),
    "v_missing"    => (["Name" => missing], (;)),
    "v_mixed"      => (["Num" => [10, "TRUE", missing]], (;)),
    "v_E_texts"    => (["Val" => [_DS * "3.00", "15:00"]], (;)),
    "v_dt"         => (["Val" => [DateTime(2026, 11, 23, 15)]], (;)),
    "c_eq_txt"     => (["Name" => ("==" => "apple")], (;)),
    "c_ne_txt"     => (["Name" => ("!=" => "apple")], (;)),
    "c_notempty"   => (["Name" => ("!=" => "")], (;)),
    "c_notempty_B" => (["Num" => ("!=" => "")], (;)),
    "c_gt"         => (["Num" => (">" => 4)], (;)),
    "c_ge_txt"     => (["Num" => (">=" => "5")], (;)),
    "c_lt_b"       => (["Name" => ("<" => "b")], (;)),
    "c_gt_b"       => (["Name" => (">" => "b")], (;)),
    "c_le_Big"     => (["Name" => ("<=" => "Big")], (;)),
    "c_date_ge"    => (["When" => (">=" => Date(2026, 11, 23))], (;)),
    "c_dt_lt"      => (["When" => ("<" => DateTime(2026, 11, 23, 12))], (;)),
    "c_time"       => (["Val" => ("<" => "12:00")], (;)),
    "c_iso"        => (["Val" => (">" => "2026-01-01")], (;)),
    "c_paren"      => (["Val" => ("==" => "(1)")], (;)),
    "c_thousands"  => (["Val" => ("==" => "1,000")], (;)),
    "c_currency"   => (["Val" => ("==" => _DS * "3.00")], (;)),
    "c_fraction"   => (["Val" => ("==" => "1/4")], (;)),
    "w_begins"     => (["Name" => ("==" => "a*")], (;)),
    "w_ends"       => (["Name" => ("==" => "*e")], (;)),
    "w_contains"   => (["Name" => ("==" => "*pp*")], (;)),
    "w_ncontains"  => (["Name" => ("!=" => "*pp*")], (;)),
    "w_q"          => (["Name" => ("==" => "?ig")], (;)),
    "w_escape"     => (["Name" => ("==" => "A~*star")], (;)),
    "w_mid"        => (["Name" => ("==" => "a*e")], (;)),
    "w_nbegins"    => (["Name" => ("!=" => "a*")], (;)),
    "w_star"       => (["Name" => ("==" => "*")], (;)),
    "w_num_begins" => (["Num" => ("==" => "1*")], (;)),
    "w_q_lit"      => (["Name" => ("==" => "b~?g")], (;)),
    "and"          => (["Num" => (">=" => 2, :and, "<" => 10)], (;)),
    "or"           => (["Name" => ("==" => "apple", :or, "==" => "pig")], (;)),
    "or2cols"      => (["Name" => ("==" => "apple", :or, "==" => "banana"), "Num" => (">" => 1)], (;)),
    "or3cols"      => (["Name" => ("==" => "a*", :or, "==" => "*g"), "Num" => (">" => 0, :or, "<" => -0.5),
                        "Flag" => ("==" => "TRUE", :or, "==" => "FALSE")], (;)),
    "cols_and"     => (["Name" => ["abc", "apple"], "Num" => (">" => 50)], (;)),
    "top5"         => (["Num" => (:top, 5)], (;)),
    "bot4"         => (["Num" => (:bottom, 4)], (;)),
    "top25p"       => (["Num" => (:top, 25, :percent)], (;)),
    "bot25p"       => (["Num" => (:bottom, 25, :percent)], (;)),
    "top3_E"       => (["Val" => (:top, 3)], (;)),
    "bot3_E"       => (["Val" => (:bottom, 3)], (;)),
    "top20p_E"     => (["Val" => (:top, 20, :percent)], (;)),
    "top30_C"      => (["When" => (:top, 30)], (;)),
    "bot2_A"       => (["Name" => (:bottom, 2)], (;)),
    "rx"           => (["Name" => r"app.*"], (;)),
    "rx_ne"        => (["Name" => ("!=" => r"app.*")], (;)),
    "rx_num"       => (["Num" => r"1.*"], (;)),
    "rx_E"         => (["Val" => r"1,5.*"], (;)),
    "cs_eq"        => (["Name" => "apple"], (caseSensitive = true,)),
    "cs_list"      => (["Name" => ["apple", "ABC"]], (caseSensitive = true,)),
    "cs_begins"    => (["Name" => ("==" => "A*")], (caseSensitive = true,)),
    "cs_gt"        => (["Name" => (">" => "apple")], (caseSensitive = true,)),
    "cs_ge_A"      => (["Name" => (">=" => "Apple")], (caseSensitive = true,)),
    "cs_rx"        => (["Name" => r"a.*"], (caseSensitive = true,)),
    "nodup_ne"     => (["Name" => ("!=" => "zzz")], (noDuplicates = true,)),
    "nodup_crit"   => (["Num" => (">" => 50)], (noDuplicates = true,)),
    "by_letter"    => (["B" => 10], (;)),
    "by_position"  => ([2 => 10], (;)),
]

@testset "AutoFilter criteria, as LibreOffice applies them" begin
    lo = Dict(first(p) => (length(p) > 1 && !isempty(p[2]) ? parse.(Int, split(p[2], ',')) : Int[])
              for p in (split(l, '\t') for l in eachline(_fd("lo-filters-refresh.tsv")) if !isempty(l)))
    @test length(lo) == length(_AF_CASES)
    xf = openods(_fd("lo-filters-data.fods"); mode = "rw")
    ws = xf["Data"]
    for (name, (filters, kw)) in _AF_CASES
        setAutoFilter(ws, "A1:E19"; filters, kw...)
        @test (name => _hidden(ws, 2:19)) == (name => lo[name])
    end
    setAutoFilter(ws, "A1:E19"; filters = [])                          # no criteria: every row shown
    @test isempty(_hidden(ws, 2:19))
    @test getAutoFilter(ws) == O_F.CellRange("A1:E19")
end

@testset "AutoFilter: the stored forms" begin
    xf = openods(_fd("lo-filters-data.fods"); mode = "rw")
    ws = xf["Data"]
    form(filters; kw...) = (setAutoFilter(ws, "A1:E19"; filters, kw...); _fx(read(_fpath(xf), String)))
    x = form(["Name" => ["apple", "pig", missing]])
    @test occursin("<table:database-range table:name=\"__Anonymous_Sheet_DB__0\" table:target-range-address=\"Data.A1:Data.E19\" table:display-filter-buttons=\"true\">", x)
    @test occursin("<table:filter><table:filter-and><table:filter-condition table:value=\"apple\" table:operator=\"=\" table:field-number=\"0\">" *
                   "<table:filter-set-item table:value=\"apple\"/><table:filter-set-item table:value=\"pig\"/><table:filter-set-item table:value=\"\"/>" *
                   "</table:filter-condition></table:filter-and></table:filter>", x)
    @test occursin("table:value=\"TRUE\" table:operator=\"=\" table:field-number=\"3\"/>", form(["Flag" => true]))
    @test occursin("table:data-type=\"number\" table:value=\"46349\" table:operator=\"&gt;=\"", form(["When" => (">=" => Date(2026, 11, 23))]))
    @test occursin("table:data-type=\"number\" table:value=\"46349.5\" table:operator=\"&lt;\"", form(["When" => ("<" => DateTime(2026, 11, 23, 12))]))
    @test occursin("table:value=\"2026-11-23\" table:operator=\"=\"", form(["When" => [Date(2026, 11, 23)]]))
    @test occursin("table:value=\"2026-11-23 15:00\"", form(["When" => [DateTime(2026, 11, 23, 15)]]))
    @test occursin("table:value=\"2026-11-23 15:00:07.250\"", form(["When" => [DateTime(2026, 11, 23, 15, 0, 7, 250)]]))
    # wildcards: LibreOffice's text tests where they can be, else a regular expression
    @test occursin("table:value=\"a\" table:operator=\"begins-with\"", form(["Name" => ("==" => "a*")]))
    @test occursin("table:value=\"e\" table:operator=\"does-not-end-with\"", form(["Name" => ("!=" => "*e")]))
    @test occursin("table:value=\"pp\" table:operator=\"contains\"", form(["Name" => ("==" => "*pp*")]))
    @test occursin("table:value=\".ig\" table:operator=\"match\"", form(["Name" => ("==" => "?ig")]))
    @test occursin("table:value=\"A\\*star\" table:operator=\"=\"", form(["Name" => ("==" => "A~*star")])) == false
    @test occursin("table:value=\"A*star\" table:operator=\"=\"", form(["Name" => ("==" => "A~*star")]))
    @test occursin("table:value=\"a.*e\\.x\" table:operator=\"!match\"", form(["Name" => ("!=" => "a*e.x")]))
    @test occursin("table:value=\"^a\" table:operator=\"match\"", form(["Name" => r"^a"]))
    @test occursin("table:value=\"x\" table:operator=\"!match\"", form(["Name" => ("!=" => r"x")]))
    # rankings, options, and the disjunctive form
    @test occursin("table:data-type=\"number\" table:value=\"25\" table:operator=\"bottom percent\"", form(["Num" => (:bottom, 25, :percent)]))
    @test occursin("table:field-number=\"0\" table:case-sensitive=\"true\"/>", form(["Name" => "apple"]; caseSensitive = true))
    @test occursin("<table:filter table:display-duplicates=\"false\">", form(["Num" => (">" => 50)]; noDuplicates = true))
    x = form(["Name" => ("==" => "apple", :or, "==" => "pig"), "Num" => (">" => 1)])
    @test occursin("<table:filter><table:filter-or><table:filter-and><table:filter-condition table:value=\"apple\"", x)
    @test count("<table:filter-and>", x) == 2 && count("table:operator=\"&gt;\"", x) == 2
    x = form(["Name" => ("==" => "apple", :or, "==" => "pig")])
    @test occursin("<table:filter-or><table:filter-condition table:value=\"apple\"", x) && !occursin("filter-and", x)
    # the same range keeps its criteria; filters=[] removes them
    setAutoFilter(ws, "A1:E19"; filters = ["Name" => "apple"])
    setAutoFilter(ws, "A1:E19")
    x = _fx(read(_fpath(xf), String))
    @test occursin("table:value=\"apple\"", x) && _hidden(ws, 2:19) == [4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19]
    setAutoFilter(ws, "A1:E19"; filters = [])
    x = _fx(read(_fpath(xf), String))
    @test !occursin("<table:filter", x) && occursin("table:display-filter-buttons=\"true\"/>", x)
end

@testset "AutoFilter: ranges, getAutoFilter and removeAutoFilter" begin
    xf = newods("S")
    ws = xf[1]
    ws[1, :] = ["K", "V"]
    for r in 2:7
        ws[r, :] = [isodd(r) ? "x" : "y", r]
    end
    @test getAutoFilter(ws) === nothing
    @test !removeAutoFilter(ws)
    setAutoFilter(ws, :)                                                # the used range
    @test getAutoFilter(ws) == O_F.CellRange("A1:B7")
    setAutoFilter(xf, "S.A1:B5"; filters = ["K" => "x"])
    @test getAutoFilter(ws) == O_F.CellRange("A1:B5") && _hidden(ws, 1:7) == [2, 4]
    setAutoFilter(ws, "A1:B7")                                           # a new range drops the criteria; rows stay
    @test _hidden(ws, 1:7) == [2, 4] && !occursin("<table:filter>", _fx(read(_fpath(xf), String)))
    setAutoFilter(ws, "A1:B7"; filters = ["K" => "x"])
    setRowHidden(ws, 7)                                                  # by hand
    @test _hidden(ws, 1:7) == [2, 4, 6, 7]
    p = _fpath(xf)
    s = read(p, String)
    @test occursin("table:visibility=\"filter\"", s) && occursin("table:visibility=\"collapse\"", s)
    r = openods(p)                                                       # read-only
    @test getAutoFilter(r["S"]) == O_F.CellRange("A1:B7") && _hidden(r["S"], 1:7) == [2, 4, 6, 7]
    # removing it shows every row, as LibreOffice does, and keeps the anonymous range (F-071)
    @test removeAutoFilter(ws)
    @test getAutoFilter(ws) === nothing && isempty(_hidden(ws, 1:7))
    @test _fx(read(_fpath(xf), String)) == "<table:database-ranges><table:database-range table:name=\"__Anonymous_Sheet_DB__0\" table:target-range-address=\"S.A1:S.B7\"/></table:database-ranges>"
    @test !removeAutoFilter(ws)
    setAutoFilter(ws, "A1:B7")                                           # the range again gets its buttons back
    @test getAutoFilter(ws) == O_F.CellRange("A1:B7") && length(O_F._db_now(xf)) == 1
    # the range moves with inserted rows, and copies with the sheet
    O_F.insertRows(ws, 1; count = 2)
    @test getAutoFilter(ws) == O_F.CellRange("A3:B9")
    c = O_F.copysheet!(ws, "S2")
    @test getAutoFilter(c) == O_F.CellRange("A3:B9") && getAutoFilter(ws) == O_F.CellRange("A3:B9")
    names = [d.name for d in O_F._db_now(xf)]
    @test length(names) == 2 && allunique(names) && all(startswith("__Anonymous_Sheet_DB__"), names)
    # a second sheet's filter gets its own name
    ws3 = addsheet!(xf, "T")
    ws3[1, 1] = "H"; ws3[2, 1] = 1
    setAutoFilter(ws3, "A1:A2")
    @test length(unique(d.name for d in O_F._db_now(xf))) == 3
end

@testset "AutoFilter on LibreOffice's files" begin
    DBD = joinpath(@__DIR__, "..", "data", "dbranges")
    imp = readods(joinpath(DBD, "lo-dbranges-xlsx-import.fods"))
    @test getAutoFilter(imp["F01"]) == O_F.CellRange("A1:D13")
    @test getAutoFilter(imp["Tables"]) === nothing                     # tables' filters aren't included
    own = readods(joinpath(DBD, "lo-dbranges-own.fods"))
    @test getAutoFilter(own["Own"]) == O_F.CellRange("A1:D13")         # a range sorted, with buttons
    # a patched save replaces the filter in its place, keeping the rest byte for byte
    src = joinpath(DBD, "lo-dbranges-xlsx-import.fods")
    xf = openods(src; mode = "rw")
    setAutoFilter(xf["F02"], "A1:D13"; filters = ["Name" => "pig"])
    s0, s1 = read(src, String), read(_fpath(xf), String)
    x0, x1 = _fx(s0), _fx(s1)
    i = findfirst("__Anonymous_Sheet_DB__1\"", x1)
    @test i !== nothing && findfirst("__Anonymous_Sheet_DB__0\"", x1) < i < findfirst("__Anonymous_Sheet_DB__2\"", x1)
    a = findfirst("<table:database-range table:name=\"__Anonymous_Sheet_DB__1\"", x0)
    b = findnext("</table:database-range>", x0, last(a))
    @test replace(x1, r"<table:database-range table:name=\"__Anonymous_Sheet_DB__1\".*?</table:database-range>"s => "") ==
          x0[1:first(a)-1] * x0[last(b)+1:end]
    @test occursin("<table:filter><table:filter-and><table:filter-condition table:value=\"pig\" table:operator=\"=\" table:field-number=\"0\"/>", x1)
    # removing one keeps the range without its filter, and a sort it holds
    xf = openods(joinpath(DBD, "lo-dbranges-own.fods"); mode = "rw")
    @test removeAutoFilter(xf["Own"])
    x = _fx(read(_fpath(xf), String))
    @test occursin(r"<table:database-range table:name=\"__Anonymous_Sheet_DB__0\" table:target-range-address=\"Own.A1:Own.D13\">\s*<table:sort>", x)
    @test getAutoFilter(xf["Own"]) === nothing
end

@testset "AutoFilter errors" begin
    xf = openods(_fd("lo-filters-data.fods"); mode = "rw")
    ws = xf["Data"]
    for f in (:aboveAverage, :belowAverage, :today, :yearToDate, :Q1, :M12)
        @test_throws ODSError setAutoFilter(ws, "A1:E19"; filters = ["When" => f])
    end
    @test_throws ODSError setAutoFilter(ws, "A1:E19"; filters = ["Name" => :nope])
    @test_throws ODSError setAutoFilter(ws, "A1:E19"; filters = ["Name" => String[]])
    @test_throws ODSError setAutoFilter(ws, "A1:E19"; filters = ["Name" => ("~" => 1)])
    @test_throws ODSError setAutoFilter(ws, "A1:E19"; filters = ["Flag" => ("==" => true)])
    @test_throws ODSError setAutoFilter(ws, "A1:E19"; filters = ["Name" => (">" => r"a")])
    @test_throws ODSError setAutoFilter(ws, "A1:E19"; filters = ["Num" => (:top, 0)])
    @test_throws ODSError setAutoFilter(ws, "A1:E19"; filters = ["Num" => (:top, 101, :percent)])
    @test_throws ODSError setAutoFilter(ws, "A1:E19"; filters = ["Num" => (:top, 2, :items)])
    @test_throws ODSError setAutoFilter(ws, "A1:E19"; filters = ["Nope" => 1])
    @test_throws ODSError setAutoFilter(ws, "A1:E19"; filters = [9 => 1])
    @test_throws ODSError setAutoFilter(ws, "A1:E19"; filters = ["F" => 1])
    @test_throws ODSError setAutoFilter(ws, "A1:E19"; filters = "Name")
    @test_throws ODSError setAutoFilter(ws, "A1:E19"; caseSensitive = true)
    @test_throws ODSError setAutoFilter(ws, "A1:E19"; filters = [], noDuplicates = true)
    @test_throws ODSError setAutoFilter(ws, "A1:B5,D1:D5")
    @test_throws ODSError setAutoFilter(ws, "B:B")
    ws[1, 7] = "G"; ws[1, 8] = "H"
    O_F.addtable!(ws, "G1:H3"; name = "T")
    @test_throws ODSError setAutoFilter(ws, "A1:G3")
    @test_throws ODSError setAutoFilter(readods(_fd("lo-filters-data.fods"))["Data"], "A1:E19")
    @test_throws ODSError removeAutoFilter(readods(_fd("lo-filters-data.fods"))["Data"])
end

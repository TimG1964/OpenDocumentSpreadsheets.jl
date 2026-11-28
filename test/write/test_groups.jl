# Grouping rows and columns (phase 5 step 7; D-060, F-052), against LibreOffice's own groups
# (experiment 023 part B, test/data/visibility/lo-groups*), in the model, in saved files and through
# LibreOffice. XLSX.jl's hide-group.jl grouping cases are ported where they apply. Uses SHIFT from
# formula/test_refs.jl.

using OpenDocumentSpreadsheets: getRowOutlineLevel, getColumnOutlineLevel, isRowHidden, isColumnHidden, ODSError,
    insertRows, deleteRows, insertColumns, sheet_formats

# The groups and hidden lines of a sheet in a saved file, read from its XML without OpenDocumentSpreadsheets (as
# experiments/023-lo-visibility/extract_b.jl prints them): "rows 3:5 depth 1 <attributes>", …
function group_structure(path, sheet)
    f = read(path, String)
    if !endswith(path, ".fods")
        f = String(OpenDocumentSpreadsheets.read_xml(OpenDocumentSpreadsheets.open_container(path), :content))
    end
    t = match(Regex("<table:table table:name=\"" * sheet * "\".*?</table:table>", "s"), f).match
    lines = String[]
    hidden = Dict("rows" => Set{Int}(), "cols" => Set{Int}())
    for (kind, line, grp, rep) in (("rows", "table:table-row", "table:table-row-group", "table:number-rows-repeated"),
                                    ("cols", "table:table-column", "table:table-column-group", "table:number-columns-repeated"))
        n = 0
        stack = Tuple{Int,String}[]
        groups = String[]
        for cm in eachmatch(Regex("<(/?)(" * grp * "|" * line * ")\\b([^>]*?)(/?)>"), t)
            close, name, attrs, _ = cm.captures
            if name == grp
                if close == "/"
                    a, at = pop!(stack)
                    push!(groups, strip("$kind $(a+1):$n depth $(length(stack)+1) $(strip(at))"))
                else
                    push!(stack, (n, attrs))
                end
            elseif close == ""
                r = match(Regex(rep * "=\"(\\d+)\""), attrs)
                k = r === nothing ? 1 : parse(Int, r.captures[1])
                occursin(r"table:visibility=\"(collapse|filter)\"", attrs) && union!(hidden[kind], n+1:n+k)
                n += k
            end
        end
        append!(lines, groups)
    end
    return sortgroups(lines), hidden
end

# Group lines in one order: rows, then columns; by first line, then text.
sortgroups(v) = sort(String.(v); by = l -> (l[1:4] == "rows" ? 0 : 1, parse(Int, match(r" (\d+):", l).captures[1]), l))

# The same from the fixtures that extract_b.jl wrote.
function fixture_structure(file)
    lines = String[]
    hidden = Dict("rows" => Set{Int}(), "cols" => Set{Int}())
    for l in eachline(joinpath(VIS, file))
        m = match(r"^(rows|cols) hidden: ?(.*)$", l)
        if m === nothing
            push!(lines, strip(l))
        else
            for r in split(m.captures[2])
                a, b = parse.(Int, split(r, ':'))
                union!(hidden[m.captures[1]], a:b)
            end
        end
    end
    return sortgroups(lines), hidden
end

# A sheet's groups as the model holds them, in the same form.
model_structure(ws) = (f = sheet_formats(ws); sortgroups(
    [["rows $(g.first):$(g.last) depth $(g.depth)" * (g.display ? "" : " table:display=\"false\"") for g in f.rowgroups];
     ["cols $(g.first):$(g.last) depth $(g.depth)" * (g.display ? "" : " table:display=\"false\"") for g in f.colgroups]]))

# Experiment 023 part B's calls on sheets G, H and I, through the API. LibreOffice's refusals (a
# group crossing another, an eighth level) are errors in OpenDocumentSpreadsheets (D-060).
function apply_lo_groups!(xf, sheet)
    s = xf[sheet]
    if sheet == "G"
        groupRows(s, 3:5); groupRows(s, 4)
        groupRows(s, 10:12; collapsed = true)
        groupRows(s, 15:16); groupRows(s, 17:18)
        groupRows(s, 20:22)
        @test_throws ODSError groupRows(s, 21:24)
        for k in 1:9
            k <= 7 ? groupRows(s, 30:(40 - k + 1)) : @test_throws(ODSError, groupRows(s, 30:(40 - k + 1)))
        end
        groupRows(s, 45:52); ungroupRows(s, 48:49)
        groupRows(s, 55:56; collapsed = true); groupRows(s, 55:57)
        groupColumns(s, "C:D"); groupColumns(s, "D")
        groupColumns(s, "F:G"; collapsed = true)
    elseif sheet == "H"
        groupRows(s, 3:5); groupRows(s, 3:5)
        groupRows(s, 13:15); groupRows(s, 14); ungroupRows(s, 13)
        groupRows(s, 23:25); groupRows(s, 24); ungroupRows(s, 24:25)
        groupRows(s, 33:34); groupRows(s, 35:36); ungroupRows(s, 34:35)
        groupRows(s, 43:45); groupRows(s, 44); groupRows(s, 42:46)
        groupRows(s, 53:55); groupRows(s, 54); groupRows(s, 54:55)
        groupRows(s, 63:65); groupRows(s, 64:65); @test_throws ODSError groupRows(s, 63:64)
        groupRows(s, 73:74; collapsed = true); ungroupRows(s, 73:74)
        groupRows(s, 83:85); groupRows(s, 84)
        groupRows(s, 93:95); @test_throws ODSError groupRows(s, 94:97)
        groupRows(s, 103:105); @test_throws ODSError groupRows(s, 101:103)
    else
        for k in 0:7
            groupRows(s, (10k + 3):(10k + 5))
        end
        groupRows(s, 74)
        deleteRows(s, 74:75); deleteRows(s, 62:63); deleteRows(s, 53:55); deleteRows(s, 44)
        insertRows(s, 36; count = 2); insertRows(s, 25; count = 2); insertRows(s, 14; count = 2); insertRows(s, 3; count = 2)
    end
end

function lo_groups_file()
    xf = newods("G")
    addsheet!(xf, "H"); addsheet!(xf, "I")
    for r in 1:60, c in 1:12
        xf["G"][r, c] = 100r + c
    end
    for r in 1:120
        xf["H"][r, 1] = r
        xf["I"][r, 1] = r
    end
    return xf
end

@testset "LibreOffice's groups, read (experiment 023 part B)" begin
    xf = readods(joinpath(VIS, "lo-groups.fods"))
    for s in ("G", "H", "I")
        want, _ = fixture_structure("lo-groups-$s.txt")
        @test model_structure(xf[s]) == want
    end
    g = xf["G"]
    @test [getRowOutlineLevel(g, r) for r in (2, 3, 4, 5, 6, 30, 34, 35, 40, 41)] == [0, 1, 2, 1, 0, 7, 7, 6, 1, 0]
    @test getColumnOutlineLevel(g, "D") == 2 && getColumnOutlineLevel(xf, "G.F") == 1 && getRowOutlineLevel(xf, "G!4") == 2
    @test isRowHidden(g, 11) && isColumnHidden(g, 6)
    # its import of XLSX.jl's levels: adjacent groups at one level are one group
    im = readods(joinpath(VIS, "lo-groups-xlsx-import.fods"))
    @test model_structure(im["G"]) == fixture_structure("lo-groups-xlsx-import-G.txt")[1]
    @test_throws ODSError getRowOutlineLevel(g, "3:4")
end

@testset "grouping as LibreOffice groups (experiment 023 part B)" begin
    xf = openods(writeods(joinpath(mktempdir(), "base.ods"), lo_groups_file()); mode = "rw")
    fresh = lo_groups_file()
    dir = mktempdir()
    for s in ("G", "H", "I")
        apply_lo_groups!(fresh, s)                 # a new file
        apply_lo_groups!(xf, s)                    # a file read (patched save)
        want = fixture_structure("lo-groups-$s.txt")
        @test model_structure(fresh[s]) == want[1]
        @test model_structure(xf[s]) == want[1]
    end
    pn = writeods(joinpath(dir, "new.ods"), fresh)
    pp = writeods(joinpath(dir, "patched.ods"), xf)
    for s in ("G", "H", "I"), p in (pn, pp)
        @test group_structure(p, s) == fixture_structure("lo-groups-$s.txt")
        @test model_structure(readods(p)[s]) == fixture_structure("lo-groups-$s.txt")[1]
    end
    r = readods(pp)
    @test r["G"]["A30"] == 3001 && r["G"]["L60"] == 6012 && r["I"]["A5"] == 3 && r["H"]["A120"] == 120
end

@testset "grouping: XLSX.jl's cases and errors" begin
    xf = newods("Sheet1")
    s = xf[1]
    s["A1:F20"] = 1
    groupRows(s, "2:4,8:9")                        # each run a group
    @test [getRowOutlineLevel(s, r) for r in 1:10] == [0, 1, 1, 1, 0, 0, 0, 1, 1, 0]
    groupRows(xf, "Sheet1!3:4"; collapsed = true)
    @test getRowOutlineLevel(s, 3) == 2 && isRowHidden(s, 3) && !isRowHidden(s, 2)
    ungroupRows(s, 3)
    @test getRowOutlineLevel(s, 3) == 1 && isRowHidden(s, 3)   # still hidden, as in XLSX.jl and LibreOffice
    ungroupRows(s, 20)                             # no group: nothing happens
    groupColumns(s, [2, 3]); groupColumns(xf, "Sheet1.C")
    @test [getColumnOutlineLevel(s, c) for c in 1:4] == [0, 1, 2, 0]
    ungroupColumns(xf, "Sheet1!B:C")
    @test [getColumnOutlineLevel(s, c) for c in 1:4] == [0, 1, 1, 0]   # the deepest group (C) goes; C is still in B:C
    @test_throws ODSError groupRows(s, 0)
    @test_throws ODSError groupColumns(s, 16385)
    @test_throws ODSError groupRows(s, "1:3")      # crosses 2:4
    @test_throws ODSError groupRows(readods(joinpath(VIS, "lo-groups.fods"))["G"], 1)
    # groups to the sheet's end, and beyond the rows a file has
    groupRows(s, 1048570:1048576); groupColumns(s, "XFA:XFD")
    r = readods(writeods(joinpath(mktempdir(), "e.ods"), xf))[1]
    @test getRowOutlineLevel(r, 1048576) == 1 && getColumnOutlineLevel(r, "XFD") == 1 && getRowOutlineLevel(r, 1048569) == 0
    @test [getRowOutlineLevel(r, i) for i in 1:10] == [0, 1, 1, 1, 0, 0, 0, 1, 1, 0] && r["F20"] == 1
end

@testset "a patched save changes only the sheet regrouped (D-023)" begin
    src = joinpath(VIS, "lo-groups.fods")
    orig = read(src, String)
    table(s, name) = match(Regex("<table:table table:name=\"" * name * "\".*?</table:table>", "s"), s).match
    xf = openods(src; mode = "rw")
    groupRows(xf["H"], 110:112)
    ungroupColumns(xf["G"], "D")
    out = read(writeods(joinpath(mktempdir(), "a.fods"), xf), String)
    @test table(out, "I") == table(orig, "I")
    @test replace(out, table(out, "H") => "", table(out, "G") => "") == replace(orig, table(orig, "H") => "", table(orig, "G") => "")
    ls, _ = group_structure(joinpath(mktempdir(), "a.fods") |> p -> (write(p, out); p), "H")
    @test "rows 110:112 depth 1" in ls && length(ls) == length(fixture_structure("lo-groups-H.txt")[1]) + 1
    lg, hg = group_structure(joinpath(mktempdir(), "g.fods") |> p -> (write(p, out); p), "G")
    @test !("cols 4:4 depth 2" in lg) && "cols 3:4 depth 1" in lg && hg["cols"] == Set(6:7)
    # the cells are as they were
    r = readods(IOBuffer(out))
    o = readods(src)
    @test r["G"][:] == o["G"][:] && r["H"][:] == o["H"][:]
    # print-title rows (at the top of experiment 021's Data) can be grouped around, not across
    src2 = joinpath(SHIFT, "lo-shift-before.fods")
    t = table(read(src2, String), "Data")
    @test !occursin(r"<table:table-row\b.*<table:table-header-rows>"s, t)     # the titles come first
    hrows = length(collect(eachmatch(r"<table:table-row\b", match(r"<table:table-header-rows>.*?</table:table-header-rows>"s, t).match)))
    xf = openods(src2; mode = "rw")
    groupRows(xf["Data"], 1:(hrows + 2))                      # around the titles
    groupRows(xf["Data"], (hrows + 3):(hrows + 4))
    r = readods(writeods(joinpath(mktempdir(), "h.fods"), xf))["Data"]
    @test getRowOutlineLevel(r, 1) == 1 && getRowOutlineLevel(r, hrows + 3) == 1 && getRowOutlineLevel(r, hrows + 5) == 0
    @test isequal(r[:], readods(src2)["Data"][:])
    xf = openods(src2; mode = "rw")
    groupRows(xf["Data"], hrows:(hrows + 1))                  # across the end of the titles
    @test_throws ODSError writeods(joinpath(mktempdir(), "h2.fods"), xf)
end

@testset "LibreOffice reads the groups" begin
    if lo_ok(; what = "the groups oracle")
        dir = mktempdir()
        profile = lo_profile_url(joinpath(dir, "lo-profile"))
        fresh = lo_groups_file()
        foreach(s -> apply_lo_groups!(fresh, s), ("G", "H", "I"))
        files = [writeods(joinpath(dir, "new.ods"), fresh)]
        pf = openods(joinpath(VIS, "lo-groups.fods"); mode = "rw")
        groupRows(pf["H"], 110:112; collapsed = true); ungroupColumns(pf["G"], "D"); insertRows(pf["I"], 16; count = 3)
        push!(files, writeods(joinpath(dir, "patched.fods"), pf))
        lo_convert(files, "fods"; outdir = joinpath(dir, "lo"), profile = profile)
        for s in ("G", "H", "I")
            @test group_structure(joinpath(dir, "lo", "new.fods"), s) == fixture_structure("lo-groups-$s.txt")
        end
        lp = joinpath(dir, "lo", "patched.fods")
        for s in ("G", "H", "I")
            @test group_structure(lp, s)[1] == model_structure(pf[s])
        end
        @test isRowHidden(readods(lp)["H"], 111)
    end
end

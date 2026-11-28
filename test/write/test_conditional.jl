# Conditional formats (phase 7, D-081): reading LibreOffice's rules, clearing them, the patched save,
# and rules through structural edits. The expectations are LibreOffice's API reading the same files
# (experiment 038's oracle, `test/data/conditional/*.tsv`) and LibreOffice reading ours.
using Test
using OpenDocumentSpreadsheets
using OpenDocumentSpreadsheets: ODSError, getConditionalFormats, deleteConditionalFormats

_cfd(f) = joinpath(@__DIR__, "..", "data", "conditional", f)

# The oracle's operator numbers (F-073) as XLSX.jl's types.
function _cf_oracle_type(kind, fields)
    kind == "date" && return "timePeriod"
    kind == "colorscale" && return "colorScale"
    kind == "databar" && return "dataBar"
    kind == "iconset" && return "iconSet"
    op = parse(Int, fields["op"])
    op <= 7 && return "cellIs"
    op == 24 && return occursin(r"^LEN\(TRIM\(", fields["f1"]) ? (endswith(fields["f1"], "=0") ? "containsBlanks" : "notContainsBlanks") : "expression"
    return Dict(8 => "duplicateValues", 9 => "uniqueValues", 10 => "top10", 11 => "top10", 12 => "top10", 13 => "top10",
                14 => "aboveAverage", 15 => "aboveAverage", 16 => "aboveAverage", 17 => "aboveAverage", 18 => "containsErrors",
                19 => "notContainsErrors", 20 => "beginsWith", 21 => "endsWith", 22 => "containsText", 23 => "notContainsText")[op]
end

# A range as areas "B1:K1" (single cells as "D83:D83"): the oracle's `CF.B82:C82,CF.F82:G82`, or ours.
_cf_norm(a::AbstractString) = (b = replace(a, r"^.*\." => ""); occursin(':', b) ? b : b * ":" * b)
_cf_areas(s::AbstractString) = [_cf_norm(x) for x in split(s, ',')]
_cf_areas(r::SheetCore.CellRange) = [string(r)]
_cf_areas(r::SheetCore.NonContiguousRange) = [_cf_norm(string(x)) for x in r.rng]

# The oracle's rules of a sheet: (areas, type) in order.
function _cf_oracle(file, sheet; prefix = nothing)
    out = Tuple{Vector{String},String}[]
    for l in readlines(_cfd(file))
        f = split(l, '\t')
        if prefix !== nothing
            f[1] == prefix || continue
            f = f[2:end]
        end
        (f[1] == "style" || f[1] != sheet) && continue
        fields = Dict(String(first(split(x, '=', limit = 2))) => String(last(split(x, '=', limit = 2))) for x in f[6:end] if occursin('=', x))
        push!(out, (_cf_areas(f[3]), _cf_oracle_type(f[5], fields)))
    end
    return out
end
_cf_ours(ws) = [(_cf_areas(p.first), p.second.type) for p in getConditionalFormats(ws)]

# The `calcext:conditional-formats` element of each table of a file's content, by sheet.
function _cf_elements(xf)
    out = Dict{String,String}()
    for m in eachmatch(r"<table:table table:name=\"([^\"]*)\".*?</table:table>"s, xf.content)
        e = match(r"<calcext:conditional-formats(?:/>|>.*?</calcext:conditional-formats>)"s, m.match)
        out[m.captures[1]] = e === nothing ? "" : e.match
    end
    return out
end

@testset "Conditional formats" begin
    @testset "LibreOffice's own rules and its import of XLSX.jl's read as its API reads them" begin
        own = readods(_cfd("lo-cf-own.ods"))
        @test _cf_ours(own["Own"]) == _cf_oracle("lo-cf-own.tsv", "Own")
        @test _cf_ours(own["Second"]) == _cf_oracle("lo-cf-own.tsv", "Second")
        @test length(getConditionalFormats(own["Own"])) === 136
        imp = readods(_cfd("lo-cf-import.ods"))
        @test _cf_ours(imp["CF"]) == _cf_oracle("lo-cf-import.tsv", "CF")
        @test _cf_ours(imp["Other"]) == _cf_oracle("lo-cf-import.tsv", "Other")
        cf = getConditionalFormats(imp["CF"])
        @test cf[1] == (SheetCore.CellRange("B1:K1") => (type = "cellIs", priority = Int64(1)))
        @test cf[end].second.priority === Int64(length(cf))
        # several areas, a single cell, the import's blanks, the three kinds in one format
        p = findfirst(x -> x.first isa SheetCore.NonContiguousRange, cf)
        @test _cf_areas(cf[p].first) == ["B82:C82", "F82:G82"]
        @test any(x -> x.first == SheetCore.CellRange("D83:D83"), cf)
        @test [x.second.type for x in cf if x.first == SheetCore.CellRange("B48:K48")] == ["containsBlanks"]
        @test [x.second.type for x in cf if x.first == SheetCore.CellRange("B81:K81")] == ["cellIs", "dataBar", "colorScale"]
        @test [x.second.type for x in cf if x.first == SheetCore.CellRange("B79:K79")] == ["cellIs", "cellIs", "cellIs"]
        # a sheet without rules, and a new file
        @test isempty(getConditionalFormats(readods(_cfd("lo-cf-ops-base.ods"))["S"])) == false
        @test isempty(getConditionalFormats(newods()[1]))
    end

    @testset "deleteConditionalFormats removes the formats inside the range, as XLSX.jl does" begin
        xf = openods(_cfd("lo-cf-import.ods"); mode = "rw")
        ws = xf["CF"]
        n0 = length(getConditionalFormats(ws))
        @test deleteConditionalFormats(ws, "B1:K1") === 1
        @test deleteConditionalFormats(ws, "B1:K1") === 0
        @test deleteConditionalFormats(ws, "B79:J79") === 0          # wider than the range: kept
        @test deleteConditionalFormats(ws, "B79:K79") === 3          # a format's three rules
        @test deleteConditionalFormats(ws, "B82:C82") === 0          # only part of the format's areas
        @test deleteConditionalFormats(ws, "B82:G82") === 1
        @test deleteConditionalFormats(ws, "2:3") === 1              # rows: B3:K3 (row 2 has no rule)
        @test deleteConditionalFormats(ws, "O:O") === 1              # the whole column's data bar
        @test length(getConditionalFormats(ws)) === n0 - 7
        @test deleteConditionalFormats(ws, "B5:K5,B6:K6") === 2
        @test deleteConditionalFormats(xf["Other"], :) === 3
        @test isempty(getConditionalFormats(xf["Other"]))
        @test_throws ODSError deleteConditionalFormats(readods(_cfd("lo-cf-import.ods"))["CF"], :)
        # the patched save: the edited sheets' elements change, and nothing else
        dir = mktempdir()
        r = readods(writeods(joinpath(dir, "cleared.ods"), xf))
        @test _cf_ours(r["CF"]) == _cf_ours(ws)
        el = _cf_elements(r)
        @test el["Other"] == "<calcext:conditional-formats/>"   # emptied, not removed (F-075)
        orig = readods(_cfd("lo-cf-import.ods"))
        a = replace(orig.content, r"<calcext:conditional-formats>.*?</calcext:conditional-formats>"s => "")
        b = replace(r.content, r"<calcext:conditional-formats(?:/>|>.*?</calcext:conditional-formats>)"s => "")
        @test a == b
        # an unedited file saves its rules byte for byte
        u = openods(_cfd("lo-cf-import.ods"); mode = "rw")
        getConditionalFormats(u["CF"])
        @test readods(writeods(joinpath(dir, "same.ods"), u)).content == orig.content
        # all of a new file's rules cleared: no element
        n = newods(); deleteConditionalFormats(n[1], :)
        @test !occursin("calcext:conditional-formats", readods(writeods(joinpath(dir, "n.ods"), n)).content)
    end

    @testset "Rules follow inserts, deletes and copies as in LibreOffice (experiment 038 part B)" begin
        base = _cfd("lo-cf-ops-base.ods")
        ops = Dict(
            "ins-row5" => ws -> insertRows(ws, 5), "ins-row11" => ws -> insertRows(ws, 11),
            "del-rows2-3" => ws -> deleteRows(ws, 2:3), "del-row1" => ws -> deleteRows(ws, 1),
            "ins-colB" => ws -> insertColumns(ws, "B"), "del-colB" => ws -> deleteColumns(ws, "B"),
            "edit-cell" => ws -> (ws["B4"] = 100),
            "sort-formats" => ws -> setAutoFilter(ws, "A1:C10"; sort = 1 => :descending),
            "sort-noformats" => ws -> setAutoFilter(ws, "A1:C10"; sort = 1 => :descending, includeFormats = false))
        dir = mktempdir()
        for (name, op) in ops
            for read_first in (false, true)          # rules read before the edit, or only after it
                xf = openods(base; mode = "rw")
                ws = xf["S"]
                read_first && getConditionalFormats(ws)
                op(ws)
                expect = _cf_oracle("lo-cf-ops.tsv", "S"; prefix = name)
                @test _cf_ours(ws) == expect
                # and as saved: the patched text replayed through the edit
                @test _cf_ours(readods(writeods(joinpath(dir, "$name-$read_first.ods"), xf))["S"]) == expect
            end
        end
        # the conditions as LibreOffice rewrote them (experiment 038's out/lo/ops-del-row1.fods)
        xf = openods(base; mode = "rw"); deleteRows(xf["S"], 1)
        el = _cf_elements(readods(writeods(joinpath(dir, "d1.ods"), xf)))["S"]
        @test occursin("<calcext:conditional-format calcext:target-range-address=\"S.C1:S.C9\"><calcext:condition calcext:apply-style-name=\"Good\" calcext:value=\"formula-is([#REF!]&gt;[#REF!])\" calcext:base-cell-address=\"S.C1\"/></calcext:conditional-format>", el)
        @test occursin("calcext:target-range-address=\"S.A4:S.C4\"><calcext:condition calcext:apply-style-name=\"Accent\" calcext:value=\"formula-is([#REF!]&gt;0)\" calcext:base-cell-address=\"S.A4\"/>", el)
        # a copy gets the rules, retargeted
        xf = openods(base; mode = "rw")
        getConditionalFormats(xf["S"])
        c = copysheet!(xf["S"], "S2")
        @test _cf_ours(c) == _cf_oracle("lo-cf-ops.tsv", "S2"; prefix = "copy")
        r = readods(writeods(joinpath(dir, "copy.ods"), xf))
        @test _cf_ours(r["S2"]) == _cf_ours(r["S"]) == _cf_oracle("lo-cf-ops.tsv", "S"; prefix = "copy")
        @test occursin("target-range-address=\"'S2'.B1:'S2'.B10\"", _cf_elements(r)["S2"])   # quoted, as LibreOffice writes it
        # a sheet renamed: the targets follow
        xf = openods(base; mode = "rw"); deleteConditionalFormats(xf["S"], "A2:A3"); renamesheet!(xf["S"], "T T")
        el = _cf_elements(readods(writeods(joinpath(dir, "ren.ods"), xf)))["T T"]
        @test occursin("target-range-address=\"'T T'.B1:'T T'.B10\"", el)
        @test !occursin("A2:", el)
    end

    @testset "LibreOffice reads the saved rules" begin
        if lo_ok(; what = "the conditional formats oracle")
            dir = mktempdir()
            profile = lo_profile_url(joinpath(dir, "lo-profile"))
            xf = openods(_cfd("lo-cf-import.ods"); mode = "rw")
            deleteConditionalFormats(xf["CF"], "B1:K10"); deleteConditionalFormats(xf["Other"], :)
            insertRows(xf["CF"], 20; count = 2); deleteColumns(xf["CF"], "C")
            a = writeods(joinpath(dir, "patched.ods"), xf)
            lo_convert(a, "fods"; outdir = joinpath(dir, "lo"), profile = profile)
            r = readods(joinpath(dir, "lo", "patched.fods"))
            @test _cf_ours(r["CF"]) == _cf_ours(xf["CF"])
            @test isempty(getConditionalFormats(r["Other"]))       # the empty element kept the maps out
        end
    end
end

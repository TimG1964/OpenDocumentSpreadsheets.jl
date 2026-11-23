# Merged cells (phase 4, step 6).
#
# "mergeCells, and a round trip" and "whole-row, whole-column and whole-sheet merges" are
# ported from XLSX.jl 0.13.4 (test/test_files/sheets/merge.jl), MIT License, Copyright (c)
# 2018-2026 Felipe Noronha Tavares and other contributors. Adapted: the template file is
# replaced by a new sheet with the same values; the getters work on read-only files; a
# range past the used area can be merged (D-033, D-041).

using OpenDocumentSpreadsheets: ODSError, CellRange, getFont, getFill, getMergedCells, isMergedCell, getMergedBaseCell, mergeCells, removeMergedCells

mtmp(name) = joinpath(mktempdir(), name)

@testset "merges LibreOffice wrote" begin
    xf = openods(joinpath(DATA, "lo-scenarios.ods"))                         # read-only: getters work
    ws = xf["S09-merge"]
    @test getMergedCells(ws) == [CellRange("A1:B2")]
    @test isMergedCell(ws, "B2") && !isMergedCell(ws, "C1")
    @test getMergedBaseCell(xf, "S09-merge.B2") == (baseCell = CellRef("A1"), baseValue = 9)
    @test getMergedBaseCell(ws, 1, 3) === nothing
    @test getMergedCells(xf["S01-gaps"]) === nothing
    @test_throws ODSError isMergedCell(ws, "A1:B2")                          # one cell only
    @test_throws ODSError mergeCells(ws, "D1:E1")                            # read-only
    mt = openods(joinpath(DATA, "lo-tables.ods"))["Merged"]
    @test getMergedCells(mt) !== nothing
end

@testset "mergeCells, and a round trip (XLSX.jl)" begin
    f = newods()
    s = f[1]
    for i in 1:13, j in 1:12
        s[i, j] = i * j
    end
    s["A1"] = "Tables"
    @test mergeCells(f, "Sheet1!A1:B2") == 0
    @test s["A1"] == "Tables" && ismissing(s["B2"]) && s["C3"] == 9
    @test mergeCells(s, 4:6, 4:6) == 0
    @test s[4, 4] == 16 && ismissing(s[5, 5]) && s[7, 7] == 49
    @test mergeCells(s, "J") == 0                                            # a whole column: to the used area
    @test s["J1"] == 10 && ismissing(s["J2"]) && ismissing(s["J12"])
    @test isMergedCell(s, "J8")
    mc = getMergedCells(s)
    @test isMergedCell(s, "J9"; mergedCells = mc)
    @test getMergedBaseCell(s, "J12") == (baseCell = CellRef("J1"), baseValue = 10)
    @test_throws ODSError mergeCells(s, "Sheet1!M13:M13")                  # a single cell
    @test_throws ODSError mergeCells(s, 1, :)                              # overlapping
    @test_throws ODSError mergeCells(s, 10, :)
    @test_throws ODSError mergeCells(s, "Sheet2!L1:M2")                    # another sheet
    @test mergeCells(s, "M1:P15") == 0                                     # past the used area: merged (D-041)
    p = writeods(mtmp("merge.ods"), f)
    openods(p; mode = "rw") do r
        rs = r["Sheet1"]
        mc = getMergedCells(rs)
        @test mc == [CellRange("A1:B2"), CellRange("J1:J13"), CellRange("M1:P15"), CellRange("D4:F6")] ||
              sort(string.(mc)) == sort(["A1:B2", "D4:F6", "J1:J13", "M1:P15"])
        @test isMergedCell(rs, "B2") && isMergedCell(rs, 6, 6; mergedCells = mc)
        @test getMergedBaseCell(rs, "F6") == (baseCell = CellRef("D4"), baseValue = 16)
        @test rs["A1"] == "Tables" && ismissing(rs["B2"]) && rs["C3"] == 9 && ismissing(rs["J12"])
    end
end

@testset "whole-row, whole-column and whole-sheet merges (XLSX.jl)" begin
    grid(n) = (f = newods(); s = f[1]; for i in 1:n, j in 1:n; s[i, j] = i + j; end; (f, s))
    f, s = grid(3)
    mergeCells(s, "Sheet1!A:B")
    @test getMergedBaseCell(f, "Sheet1!B2") == (baseCell = CellRef("A1"), baseValue = 2)
    f, s = grid(4)
    mergeCells(s, "Sheet1!2:3")
    @test getMergedBaseCell(f, "Sheet1!C3") == (baseCell = CellRef("A2"), baseValue = 3)
    mergeCells(s, "Sheet1!4:4")
    @test getMergedBaseCell(f, "Sheet1!C4") == (baseCell = CellRef("A4"), baseValue = 5)
    f, s = grid(3)
    mergeCells(s, :, 2:3)
    @test getMergedBaseCell(f, "Sheet1!C3") == (baseCell = CellRef("B1"), baseValue = 3)
    f, s = grid(3)
    mergeCells(s, :, :)
    @test getMergedBaseCell(f, "Sheet1.B2") == (baseCell = CellRef("A1"), baseValue = 2)
end

@testset "removeMergedCells" begin
    f = newods(); s = f[1]
    s["A1"] = 1; s["D1"] = 2
    mergeCells(s, "A1:B2"); mergeCells(s, "D1:E3"); mergeCells(s, "G1:G2")
    @test removeMergedCells(s, "D47:J47") == 0 && length(getMergedCells(s)) == 3   # encloses nothing
    removeMergedCells(s, "E2")                                             # one cell is enough
    @test getMergedCells(s) == [CellRange("A1:B2"), CellRange("G1:G2")]
    @test s["D1"] == 2 && !isMergedCell(s, "E3")
    removeMergedCells(s)
    @test getMergedCells(s) === nothing && s["A1"] == 1
    p = writeods(mtmp("unmerged.ods"), f)
    @test getMergedCells(openods(p)[1]) === nothing
    c = OpenDocumentSpreadsheets.read_xml(OpenDocumentSpreadsheets.open_container(read(p)), :content)
    @test !occursin("covered-table-cell", c) && !occursin("spanned", c)
end

@testset "merging keeps the formatting, and patches only the merged rows" begin
    src = joinpath(DATA, "lo-scenarios.ods")
    xf = openods(src; mode = "rw")
    ws = xf["S05-styled-empty"]
    setFont(ws, "B3"; bold = true)
    mergeCells(ws, "A2:C3")
    @test haskey(getFont(ws, "B3").font, "b") && getMergedCells(ws) == [CellRange("A2:C3")]
    p = writeods(mtmp("p.ods"), xf)
    back = openods(p)
    for k in 1:sheetcount(back)
        sheetnames(back)[k] == "S05-styled-empty" && continue
        @test String(OpenDocumentSpreadsheets.XML.sourcetext(back[k].entry.node)) == String(OpenDocumentSpreadsheets.XML.sourcetext(openods(src)[k].entry.node))
    end
    b = back["S05-styled-empty"]
    @test getMergedCells(b) == [CellRange("A2:C3")] && haskey(getFont(b, "B3").font, "b") && b["A1"] === Int64(1)
    # unmerging a merge LibreOffice wrote
    xf = openods(src; mode = "rw")
    removeMergedCells(xf["S09-merge"], "A1")
    back = openods(writeods(mtmp("u.ods"), xf))
    @test getMergedCells(back["S09-merge"]) === nothing && back["S09-merge"]["A1"] === Int64(9)
end

@testset "LibreOffice keeps OpenDocumentSpreadsheets's merges" begin
    if isempty(SOFFICE) || !isfile(SOFFICE)
        @info "LibreOffice not found; skipping the merge oracle (set ODS_SOFFICE)"
        @test_skip false
    else
        dir = mktempdir()
        profile = lo_profile_url(joinpath(dir, "lo-profile"))
        f = newods("M"); s = f["M"]
        for i in 1:5, j in 1:5
            s[i, j] = 10i + j
        end
        mergeCells(s, "A1:B2"); mergeCells(s, "D1:D4"); mergeCells(s, "B4:C5")
        setFill(s, "C5"; pattern = "solid", fgColor = "yellow")
        x = openods(joinpath(DATA, "lo-scenarios.ods"); mode = "rw")
        mergeCells(x["S01-gaps"], "A1:C2")
        f1 = writeods(joinpath(dir, "m.ods"), f)
        f2 = writeods(joinpath(dir, "p.ods"), x)
        run(pipeline(`$SOFFICE -env:UserInstallation=$profile --headless --norestore --convert-to ods --outdir $(joinpath(dir, "lo")) $f1 $f2`;
                     stdout = devnull, stderr = devnull))
        r = openods(joinpath(dir, "lo", "m.ods"))["M"]
        @test getMergedCells(r) == getMergedCells(s)
        @test isequal([r[i, j] for i in 1:5, j in 1:5], [s[i, j] for i in 1:5, j in 1:5])
        @test getFill(r, "C5").fill == getFill(s, "C5").fill
        r2 = openods(joinpath(dir, "lo", "p.ods"))["S01-gaps"]
        @test getMergedCells(r2) == [CellRange("A1:C2")] && r2["A1"] === Int64(1) && ismissing(r2["C1"])
    end
end

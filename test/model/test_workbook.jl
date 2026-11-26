# The workbook and its sheets: opening, modes, sheet lookup, show, defined names, the
# getdata/getindex/getcell forms, repeats and tails, merges, rows, cached against uncached.
# Themes ported from XLSX.jl's tests (files/modes.jl, files/fixtures.jl, cells/getcell.jl,
# cells/getindex-setindex.jl, cells/ranges.jl, cells/error-values.jl,
# sheets/defined-names.jl), rewritten for ODS fixtures.

using Dates
using OpenDocumentSpreadsheets: getcell, getcellrange, getsheet, get_dimension, Cell, EmptyCell, ODSError,
    SheetRow, isvisible, defined_names, getFormula

const TABLES = joinpath(DATA, "lo-tables.ods")

@testset "opening and modes" begin
    xf = readods(TABLES)
    @test xf isa ODSFile
    @test sheetnames(xf) == ["Table", "Names", "Merged", "Hidden", "My sheet", "Formulas"]
    @test sheetcount(xf) == 6
    @test xf.version == "1.4"
    # from an IO, and the do-block form
    @test sheetnames(readods(IOBuffer(read(TABLES)))) == sheetnames(xf)
    @test open(readods, TABLES) isa ODSFile
    @test openods(xf -> xf["Names"]["B1"], TABLES) == 10
    @test openods(TABLES; enable_cache = false)["Names"]["C2"] == 40
    @test openods(TABLES; mode = "R") isa ODSFile
    @test readods(joinpath(DATA, "lo-tables.fods"))["Names"]["B1"] == 10
    @test readods(joinpath(DATA, "lo-scenarios.ots"))["S01-gaps"]["A1"] == 1
    # writing modes (phase 2; D-019 superseded): "rw" reads the file, "w" starts a new one
    @test openods(TABLES; mode = "rw").writable && sheetcount(openods(TABLES; mode = "rw")) == 6
    @test sheetnames(openods(TABLES; mode = "w")) == ["Sheet1"]
    @test !readods(TABLES).writable
    @test_throws ODSError openods(TABLES; mode = "x")
    @test_throws ODSError readods(joinpath(DATA, "no such file.ods"))
    @test_throws ODSError readods(IOBuffer("this is not a spreadsheet"))
    @test_throws ODSError readods(joinpath(DATA, "README.md"))
    @test ODSError === SheetCore.SheetCoreError
end

@testset "sheets" begin
    xf = readods(TABLES)
    @test xf[1].name == "Table" && xf["Table"] === xf[1]
    @test hassheet(xf, "Names") && hassheet(xf, "names") && hassheet(xf, "'My sheet'") && !hassheet(xf, "Nope")
    @test xf["my SHEET"].name == "My sheet"
    @test_throws ODSError xf[7]
    @test_throws ODSError xf[0]
    @test_throws ODSError getsheet(xf, "Nope")
    @test isvisible(xf["Table"]) && !isvisible(xf["Hidden"])
    # show: sizes appear before a sheet is used, as show reads it (issue #1)
    s = sprint(show, xf)
    @test occursin("ODSFile(\"", s) && occursin("containing 6 Worksheets", s) && !occursin("size unknown", s)
    @test occursin("(hidden)", s) && occursin("8x7", s) && occursin("B2:H9", s)
    ws = xf["Table"]
    @test sprint(show, ws) == "8×7 OpenDocumentSpreadsheets.Worksheet: [\"Table\"](B2:H9)"
    @test size(ws) == (8, 7)
    @test sprint(show, openods(TABLES)["Table"]) == "8×7 OpenDocumentSpreadsheets.Worksheet: [\"Table\"](B2:H9)"
    @test sprint(show, openods(TABLES; enable_cache = false)["Table"]) == "8×7 OpenDocumentSpreadsheets.Worksheet: [\"Table\"](B2:H9)"
    @test occursin("8x7", sprint(show, openods(TABLES; enable_cache = false)))
    @test sprint(show, xf["Hidden"]) == "1×1 OpenDocumentSpreadsheets.Worksheet: [\"Hidden\"](A1:A1) (hidden)"
    @test startswith(sprint(show, readods(IOBuffer(read(TABLES)))), "ODSFile(IOBuffer)")
    # an empty sheet shows as empty; get_dimension and size keep A1:A1 and (1, 1)
    nf = newods()
    @test occursin(r"Sheet1 empty$", sprint(show, nf))
    @test sprint(show, nf[1]) == "OpenDocumentSpreadsheets.Worksheet: [\"Sheet1\"] (empty)"
    @test get_dimension(nf[1]) == SheetCore.CellRange("A1:A1") && size(nf[1]) == (1, 1)
    @test get_dimension(readods(TABLES)["Names"]; allow_load = false) == SheetCore.CellRange("A1:A1")
    @test get_dimension(xf["Names"]) == SheetCore.CellRange("A1:C2")
end

@testset "getdata forms (cache=$cache)" for cache in (true, false)
    xf = openods(TABLES; enable_cache = cache)
    ws = xf["Table"]
    @test ws["B3"] == 1 && ws["C3"] == "a" && ws["E3"] == Date(2024, 1, 1) && ws["F3"] === true
    @test ws["\$B\$3"] == 1
    @test ismissing(ws["A1"]) && ismissing(ws["C5"]) && ismissing(ws["Z1000"])
    @test ws[3, 2] == 1
    @test isequal(ws["B2:C4"], Any["id" "name"; 1 "a"; 2 "b"])
    @test isequal(ws["B2:\$C\$4"], ws["B2:C4"])
    @test isequal(ws[2:4, 2:3], ws["B2:C4"])
    @test isequal(ws[3, 2:3], Any[1 "a"])
    @test isequal(ws[[3, 5], [2, 4]], Any[1 1.5; 3 3])
    @test isequal(ws[3:4, [2, 4]], Any[1 1.5; 2 2.5])
    @test isequal(ws[2:2:4, 2], Any["id", 2])     # a vector, as in XLSX.jl
    @test size(ws["B:C"]) == (8, 2) && ws["B:C"][2, 1] == 1     # rows from the dimension B2:H9
    @test size(ws["3:4"]) == (2, 7) && ws["3:4"][1, 1] == 1     # columns from the dimension
    @test size(ws[:]) == (8, 7) && size(ws[:, :]) == (8, 7)
    @test isequal(ws[:, 2], ws["B2:B9"]) && isequal(ws[3, :], ws["B3:H3"])
    @test isequal(ws[:, [2, 3]], ws["B2:C9"]) && isequal(ws[[3], :], ws["B3:H3"])
    @test ws["H3"] == "note"
    # lists of areas, in Excel's and LibreOffice's separators
    @test isequal(ws["B3,C3:C4"], [Any[1;;], Any["a"; "b";;]])
    @test isequal(ws["B3~C3:C4"], ws["B3,C3:C4"])
    # sheet-qualified, in either notation; it must name this sheet
    @test ws["Table.B3"] == 1 && ws["Table!B3"] == 1 && ws["\$Table.\$B\$3"] == 1
    @test isequal(ws["Table.B2:C3"], ws["B2:C3"]) && size(ws["Table.B:C"]) == (8, 2) && size(ws["Table.3:4"]) == (2, 7)
    @test_throws ODSError ws["Names.A1"]
    @test_throws ODSError ws["not a ref"]
    @test_throws ODSError ws["A0"]
    # file level
    @test xf["Table.B3"] == 1 && xf["Table!B3"] == 1 && xf["'My sheet'.A1"] == 5 && xf["'My sheet'!B1"] == "x"
    @test isequal(xf["Names.B1:C2"], Any[10 20; 30 40])
    @test isequal(xf["Names.B1~Names.C2"], [Any[10;;], Any[40;;]])
    @test size(xf["Table.B:B"]) == (8, 1)
    @test_throws ODSError xf["Nope.A1"]
    @test_throws ODSError xf["A1"]           # no sheet named
    @test getdata(xf, "Names.B1") == 10
    @test getdata(ws, getcell(ws, "B3")) == 1 && ismissing(getdata(ws, getcell(ws, "A1")))
end

@testset "getcell (cache=$cache)" for cache in (true, false)
    xf = openods(TABLES; enable_cache = cache)
    ws = xf["Table"]
    c = getcell(ws, "B3")
    @test c isa Cell && c.ref == SheetCore.CellRef("B3") && c.value == 1 && c.datatype === :float
    @test row_number(c) == 3 && column_number(c) == 2 && !isempty(c)
    @test getcell(ws, 3, 2) == c && getcell(ws, SheetCore.CellRef(3, 2)) == c && getcell(ws, "Table.B3") == c
    e = getcell(ws, "A1")
    @test e isa EmptyCell && isempty(e) && e.ref == SheetCore.CellRef("A1")
    @test sprint(show, e) == "EmptyCell(A1)"
    @test sprint(show, c) == "Cell(B3, :float, 1)"
    m = getcell(ws, "B2:C3")
    @test m isa Matrix{OpenDocumentSpreadsheets.AbstractCell} && size(m) == (2, 2) && m[2, 1] == c
    @test getcellrange(ws, "B2:C3") == m && getcellrange(ws, 2:3, 2:3) == m
    @test size(getcell(ws, :)) == (8, 7) && size(getcellrange(ws, "B:C")) == (8, 2) && size(getcellrange(ws, "3:4")) == (2, 7)
    @test getcell(ws, [3, 4], [2]) == reshape([c, getcell(ws, "B4")], 2, 1)
    @test getcellrange(ws, "B3,C3")[1][1, 1] == c
    @test getcell(xf, "Table.B3") == c && getcellrange(xf, "Table.B2:C3") == m
    @test size(getcell(ws, 3, :)) == (1, 7) && size(getcell(ws, :, 2)) == (8, 1)
end

@testset "errors and formulas" begin
    xf = readods(TABLES)
    ws = xf["Formulas"]
    @test ws["A1"] == 23.75 && ws["B1"] == 10 && ismissing(ws["C1"]) && ws["D1"] == "ab"
    @test iserror(ws, "C1") && geterror(ws, "C1") == "#DIV/0!"
    @test iserror(ws, "E1") && geterror(ws, "E1") == "#VALUE!"
    @test !iserror(ws, "A1") && geterror(ws, "A1") == "" && !iserror(ws, "Z9")
    @test iserror(ws, "A1:E1") == [false false true false true]
    @test geterror(ws, 1, 3) == "#DIV/0!" && geterror(xf, "Formulas.C1") == "#DIV/0!"
    @test iserror(ws, "A1,C1") == [fill(false, 1, 1), fill(true, 1, 1)]
    # formulas in LibreOffice's notation (D-018), or as stored
    @test getFormula(ws, "A1") == "=SUM(Table.D4:D10)"
    @test getFormula(ws, "B1") == "='My sheet'.A1*2"
    @test getFormula(ws, "E1") == "=myrange"
    @test getFormula(ws, "A2") == "=CEILING.XCL(1.5,1)"
    @test getFormula(ws, "B2") == "=SUM({1,2;3,4})"
    @test getFormula(ws, 2, 3) == "=answer+1"
    @test getFormula(ws, "A1"; raw = true) == "of:=SUM([Table.D4:.D10])"
    @test getFormula(xf, "Formulas.B1") == "='My sheet'.A1*2"
    @test getFormula(ws, "Z9") === nothing && getFormula(xf["Names"], "B1") === nothing
    @test_throws ODSError getFormula(ws, "A1:B2")
end

@testset "defined names (cache=$cache)" for cache in (true, false)
    xf = openods(TABLES; enable_cache = cache)
    @test isequal(xf["myrange"], xf["Table.B2:F6"])
    @test xf["onecell"] == 10 && xf["ONECELL"] == 10
    @test isequal(xf["listnm"], [Any[10;;], Any[40;;]])     # several areas (F-026)
    @test xf["answer"] == 42 && xf["greeting"] == "hi"
    @test xf["Names"]["onecell"] == 10                        # a workbook name, from a sheet
    @test isequal(xf["Names"]["localr"], Any[10 20; 30 40])   # a sheet-local name
    @test_throws ODSError xf["Table"]["localr"]               # local to Names only
    @test getcell(xf, "onecell").value == 10
    names = defined_names(xf)
    @test sort([n.name for n in names]) == ["answer", "greeting", "listnm", "myrange", "onecell"]
    @test [n.name for n in defined_names(xf["Names"])] == ["localr"]
    @test defined_names(xf["Names"])[1].scope == "Names"
    @test_throws ODSError OpenDocumentSpreadsheets.get_defined_name_value(OpenDocumentSpreadsheets.NameDef("e", nothing, nothing, "of:=1+[.A1]", nothing))
    @test OpenDocumentSpreadsheets.get_defined_name_value(OpenDocumentSpreadsheets.NameDef("e", nothing, nothing, "of:=TRUE()", nothing)) === true
    @test OpenDocumentSpreadsheets.get_defined_name_value(OpenDocumentSpreadsheets.NameDef("e", nothing, nothing, "2.5", nothing)) === 2.5
    @test OpenDocumentSpreadsheets.get_defined_name_value(OpenDocumentSpreadsheets.NameDef("e", nothing, nothing, "of:=[\$S.\$A\$1]~[\$S.\$B\$2]", nothing)) isa OpenDocumentSpreadsheets.NonContiguousRange
end

@testset "merged cells" begin
    ws = readods(TABLES)["Merged"]
    a1 = getcell(ws, "A1")
    @test a1.value == "m" && a1.colspan == 2 && a1.rowspan == 2 && !a1.covered
    @test getcell(ws, "B1") isa EmptyCell && getcell(ws, "B2") isa EmptyCell
    @test OpenDocumentSpreadsheets._cached_store(ws).merges == [SheetCore.CellRange("A1:B2")]
end

@testset "repeats, tails and containers" begin
    # number-rows-repeated / number-columns-repeated with values, row groups, header rows,
    # a 1048576-row tail, column groups, and a cell beyond the last column (clamped)
    body = """<table:table table:name="R">
      <table:table-column-group><table:table-header-columns><table:table-column/></table:table-header-columns>
        <table:table-column table:number-columns-repeated="16383"/></table:table-column-group>
      <table:table-header-rows><table:table-row><table:table-cell office:value-type="string"><text:p>h</text:p></table:table-cell></table:table-row></table:table-header-rows>
      <table:table-row-group>
        <table:table-row table:number-rows-repeated="3"><table:table-cell table:number-columns-repeated="2" office:value-type="float" office:value="7"/><table:table-cell/></table:table-row>
        <table:table-rows><table:table-row><table:table-cell table:number-columns-repeated="16383"/><table:table-cell office:value-type="float" office:value="1"/><table:table-cell office:value-type="float" office:value="2"/></table:table-row></table:table-rows>
      </table:table-row-group>
      <table:table-row table:number-rows-repeated="1048570"><table:table-cell table:number-columns-repeated="16384"/></table:table-row>
      <table:table-row><table:table-cell office:value-type="float" office:value="9"/></table:table-row>
      <table:table-row table:number-rows-repeated="5"><table:table-cell office:value-type="float" office:value="5"/></table:table-row>
    </table:table>"""
    for cache in (true, false)
        ws = open_fods(body; cache)[1]
        @test ws["A1"] == "h"
        @test isequal(ws["A2:C4"], Any[7 7 missing; 7 7 missing; 7 7 missing])
        @test ws["XFD5"] == 1                      # the cell after it is beyond XFD: dropped
        @test ws["A1048576"] == 9 && ismissing(ws["A1048575"])   # rows after 1048576 are dropped
        @test get_dimension(ws) == SheetCore.CellRange("A1:XFD1048576")
        rows = [row_number(r) for r in eachrow(ws)]
        @test rows == [1, 2, 3, 4, 5, 1048576]
        @test [r[1] for r in eachrow(ws)][2:4] == [7, 7, 7]
    end
end

@testset "lo-scenarios" begin
    for f in ("lo-scenarios.ods", "lo-scenarios.fods", "lo-scenarios.ots")
        xf = readods(joinpath(DATA, f))
        @test get_dimension(xf["S01-gaps"]) == SheetCore.CellRange("A1:E10")
        @test isequal(xf["S02-identical"][:], Any[7 7 7 7 7; "x" 1 missing missing missing; "x" 1 missing missing missing; "x" 1 missing missing missing])
        # whole-column and whole-row styles and styled empty cells add no content (F-007, F-009)
        for s in ("S03c-col-style-allrows", "S04-row-style", "S05-styled-empty")
            @test get_dimension(xf[s]) == SheetCore.CellRange("A1:A1")
            @test length(collect(eachrow(xf[s]))) == 1
        end
        @test isempty(collect(eachrow(xf["S08-empty"])))
        @test xf["S11-far"]["A1000000"] == 1000000 && get_dimension(xf["S11-far"]) == SheetCore.CellRange("A1:A1000000")
        @test isequal(xf["S10-formula"][:], Any[2 6 missing])
        @test geterror(xf["S10-formula"], "C1") == "#DIV/0!"
        # F-011: LibreOffice gave both date cells a date-time format, so both read as DateTime
        @test xf["S12-types"]["A1"] isa DateTime && xf["S12-types"]["B1"] == DateTime(2026, 11, 18, 13, 45)
        @test xf["S09-merge"]["A1"] == 9 && getcell(xf["S09-merge"], "A1").colspan == 2
    end
end

@testset "eachrow" begin
    for cache in (true, false)
        ws = openods(TABLES; enable_cache = cache)["Table"]
        rows = collect(eachrow(ws))
        @test eltype(rows) == SheetRow
        @test [row_number(r) for r in rows] == [2, 3, 4, 5, 6, 8, 9]
        r = rows[2]
        @test r[2] == 1 && r["C"] == "a" && ismissing(r[1]) && isequal(r[2:3], Any[1, "a"]) && r[[8]] == ["note"]
        @test getcell(r, 2) == getcell(ws, "B3") && getcell(r, "A") isa EmptyCell
        @test !isempty(r)
        @test sprint(show, r) == "SheetRow(\"Table\", row 3)"
        # iterating again starts over
        @test length(collect(eachrow(ws))) == 7
    end
    @test length(eachrow(readods(TABLES)["Table"])) == 7
end

@testset "readdata" begin
    @test readdata(TABLES, "Table", "B3") == 1
    @test readdata(TABLES, 1, "B3") == 1
    @test isequal(readdata(TABLES, "Names", "B1:C2"), Any[10 20; 30 40])
    @test readdata(TABLES, "Names.C2") == 40
    @test readdata(TABLES, "Names!C2") == 40
    @test readdata(IOBuffer(read(TABLES)), "Names.B1") == 10
    @test readdata(TABLES, "onecell") == 10
end

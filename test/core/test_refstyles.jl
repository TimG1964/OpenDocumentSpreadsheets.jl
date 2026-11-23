# Reference styles (D-015): each back end's references print, and parse, in its own
# notation. The ODF renderings are LibreOffice's own, from experiment 006 (F-017).

const XL = SheetCore.ExcelStyle
const OD = SheetCore.ODFStyle

@testset "no style-less constructors" begin
    # the core must always be told which notation is meant
    @test_throws MethodError SheetCore.SheetCellRef("Sheet1!A1")
    @test_throws MethodError SheetCore.SheetCellRange("Sheet1!A1:B2")
    @test_throws MethodError SheetCore.NonContiguousRange("Sheet1!A1,Sheet1!B2")
    @test_throws MethodError SheetCore.SheetCellRef("Sheet1", SheetCore.CellRef("A1"))
end

@testset "printing: LibreOffice's notation (experiment 006)" begin
    # LibreOffice's FORMULA() output for `=<ref>`, without the leading "=", for each sheet
    lo = Dict("Plain" => "Plain.A1", "My sheet" => "'My sheet'.A1", "It's" => "'It''s'.A1",
              "a.b" => "'a.b'.A1", "1st" => "'1st'.A1", "A1" => "'A1'.A1", "x-y" => "'x-y'.A1",
              "Ünï" => "Ünï.A1", "R1C1" => "'R1C1'.A1", "sheet!x" => "'sheet!x'.A1")
    for (sheet, text) in lo
        r = SheetCore.SheetCellRef{OD}(sheet, SheetCore.CellRef("A1"))
        @test string(r) == text
        @test sprint(show, r) == text
        @test SheetCore.SheetCellRef{OD}(text) == r              # and it parses back
        @test SheetCore.SheetCellRef{OD}(text).sheet == sheet
        # LibreOffice's absolute form, from CELL("ADDRESS"; …)
        abs = "\$" * replace(text, ".A1" => ".\$A\$1")
        @test SheetCore.SheetCellRef{OD}(abs) == r
        # the same reference in Excel style quotes the same way, with `!`
        @test string(SheetCore.SheetCellRef{XL}(sheet, SheetCore.CellRef("A1"))) == replace(text, r"\.A1$" => "!A1")
    end
    ms = "My sheet"
    @test string(SheetCore.SheetCellRange{OD}(ms, SheetCore.CellRange("A1:B2"))) == "'My sheet'.A1:B2"
    @test string(SheetCore.SheetColumnRange{OD}(ms, SheetCore.ColumnRange("A:C"))) == "'My sheet'.A:C"
    @test string(SheetCore.SheetColumnRange{OD}(ms, SheetCore.ColumnRange("A:A"))) == "'My sheet'.A:A"
    @test string(SheetCore.SheetRowRange{OD}(ms, SheetCore.RowRange("2:4"))) == "'My sheet'.2:4"
    nc = SheetCore.NonContiguousRange{OD}(ms, Union{SheetCore.CellRef,SheetCore.CellRange}[
        SheetCore.CellRange("A1:A2"), SheetCore.CellRange("B1:B2")])
    @test string(nc) == "'My sheet'.A1:A2~'My sheet'.B1:B2"
    @test string(SheetCore.NonContiguousRange{XL}(ms, nc.rng)) == "'My sheet'!A1:A2,'My sheet'!B1:B2"
end

@testset "parsing in ODFStyle" begin
    P(s) = SheetCore.parse_sheet_ref(OD, s)
    # every form experiment 006 saw LibreOffice write
    @test P("'My sheet'.A1:B2") == SheetCore.SheetCellRange{OD}("My sheet", SheetCore.CellRange("A1:B2"))
    @test P("'My sheet'.A1:'My sheet'.B2") == P("'My sheet'.A1:B2")
    @test P("\$'My sheet'.\$A\$1:\$B\$2") == P("'My sheet'.A1:B2")
    @test P("'My sheet'.A:C") isa SheetCore.SheetColumnRange{OD}
    @test P("'My sheet'.A:A").colrng == SheetCore.ColumnRange("A:A")
    @test P("'My sheet'.2:4") isa SheetCore.SheetRowRange{OD}
    @test P("'My sheet'.1:1").rowrng == SheetCore.RowRange("1:1")
    @test P("'My sheet'.A1:A2~'My sheet'.B1:B2") isa SheetCore.NonContiguousRange{OD}
    @test length(P("'My sheet'.A1:A2~'My sheet'.B1:B2")) == 4
    @test P("Plain.A1") isa SheetCore.SheetCellRef{OD}
    # and Excel's forms, so references written for XLSX.jl keep working (D-014)
    @test P("Plain!A1") == P("Plain.A1")
    @test P("'My sheet'!A1:B2") == P("'My sheet'.A1:B2")
    @test P("Sheet1!\$A\$1") == P("Sheet1.A1")
    @test P("Sheet1!A1,Sheet1!B2:C3") == P("Sheet1.A1~Sheet1.B2:C3")
    @test P("Sheet1.A1~B2") == P("Sheet1.A1~Sheet1.B2")       # later areas may leave the sheet out
    # names with dots, quotes, `!` and `~`
    @test P("'a.b'.C3").sheet == "a.b"
    @test P("a.b.C3").sheet == "a.b"                          # unquoted: the last `.` separates
    @test P("'It''s'.A1").sheet == "It's"
    @test P("'sheet!x'.A1").sheet == "sheet!x"
    @test P("'x~y'.A1~'x~y'.B1").sheet == "x~y"
    @test P("'My sheet'.A1").cellref == SheetCore.CellRef("A1")
    # printing the parsed reference gives LibreOffice's canonical form
    @test string(P("\$'My sheet'.\$A\$1:'My sheet'.\$B\$2")) == "'My sheet'.A1:B2"
    @test string(P("Sheet1!A1,Sheet1!B2:C3")) == "Sheet1.A1~Sheet1.B2:C3"
    # errors
    E = SheetCore.SheetCoreError
    @test_throws E P("A1")                                    # no sheet
    @test_throws E P(".A1")
    @test_throws E P("'Open.A1")                              # unbalanced quote
    @test_throws E P("S1.A1:S2.B2")                           # spans sheets
    @test_throws E P("S1.A1~S2.B2")
    @test_throws E P("S1.A0")
    @test_throws E P("S1.A:C~S1.B1")                          # lists hold cells and ranges only
    @test_throws E P("S1.A1:B2:C3")
    @test_throws E SheetCore.SheetCellRef{OD}("S1.A1:B2")     # a range is not a cell
    @test_throws E SheetCore.SheetCellRange{OD}("S1.A1")
    @test_throws E SheetCore.SheetColumnRange{OD}("S1.2:4")
end

@testset "parsing in ExcelStyle is unchanged" begin
    P(s) = SheetCore.parse_sheet_ref(XL, s)
    @test P("Sheet1!A1") isa SheetCore.SheetCellRef{XL}
    @test P("'My sheet'!A1:B2") isa SheetCore.SheetCellRange{XL}
    @test P("Sheet1!A:C") isa SheetCore.SheetColumnRange{XL}
    @test P("Sheet1!2:4") isa SheetCore.SheetRowRange{XL}
    @test P("Sheet1!A1,Sheet1!B2:C3") isa SheetCore.NonContiguousRange{XL}
    @test P("Sheet1!\$A\$1") == P("Sheet1!A1")
    # LibreOffice's form is not Excel's
    @test_throws SheetCore.SheetCoreError P("Sheet1.A1")
    @test_throws SheetCore.SheetCoreError SheetCore.SheetCellRef{XL}("Sheet1.A1")
end

@testset "styles are presentation only" begin
    a = SheetCore.SheetCellRef{XL}("Sheet1!B2")
    b = SheetCore.SheetCellRef{OD}("Sheet1.B2")
    @test a == b && hash(a) == hash(b)
    @test string(a) == "Sheet1!B2" && string(b) == "Sheet1.B2"
    @test SheetCore.refstyle(a) === XL && SheetCore.refstyle(b) === OD
    @test b in SheetCore.NonContiguousRange{OD}("Sheet1.A1:C3")
end

@testset "OpenDocumentSpreadsheets binds the ODF style" begin
    @test OpenDocumentSpreadsheets.SheetCellRef === SheetCore.SheetCellRef{OD}
    @test string(OpenDocumentSpreadsheets.SheetCellRef("Sheet1!A1")) == "Sheet1.A1"
    @test string(OpenDocumentSpreadsheets.SheetCellRange("'My sheet'.A1:'My sheet'.B2")) == "'My sheet'.A1:B2"
    @test string(OpenDocumentSpreadsheets.parse_sheet_ref("Data!A1,Data!C3")) == "Data.A1~Data.C3"
    @test OpenDocumentSpreadsheets.NonContiguousRange === SheetCore.NonContiguousRange{OD}
end

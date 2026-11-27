# Ported from XLSX.jl 0.13.4 test/test_files/cells/ranges.jl (MIT License, Copyright (c)
# 2018-2026 Felipe Noronha Tavares and other contributors). See records/provenance.md.
# Renamed: XLSX → SheetCore, XLSXError → SheetCoreError, EXCEL_MAX_* → MAX_*.
# D-015: the sheet-qualified constructors take the style explicitly (`SheetCellRef{SheetCore.ExcelStyle}(…)`, `nCR(SheetCore.ExcelStyle, …)`).
# Left out (19 lines): the parts that need a workbook (`NonContiguousRange(sheet, ...)`,
# `getcellrange`), which belong to a back end.

@testset "ranges" begin
    @testset "Range intersect" begin
        @test SheetCore.intersects(SheetCore.CellRange(SheetCore.CellRef("A3"), SheetCore.CellRef("E4")), SheetCore.CellRange(SheetCore.CellRef("C1"), SheetCore.CellRef("D6")))
        @test SheetCore.intersects(SheetCore.CellRange(SheetCore.CellRef("C1"), SheetCore.CellRef("D6")), SheetCore.CellRange(SheetCore.CellRef("A3"), SheetCore.CellRef("E4")))
        @test SheetCore.intersects(SheetCore.CellRange(SheetCore.CellRef("A3"), SheetCore.CellRef("D4")), SheetCore.CellRange(SheetCore.CellRef("C1"), SheetCore.CellRef("E6")))
        @test SheetCore.intersects(SheetCore.CellRange(SheetCore.CellRef("C1"), SheetCore.CellRef("E6")), SheetCore.CellRange(SheetCore.CellRef("A3"), SheetCore.CellRef("D4")))
        @test SheetCore.intersects(SheetCore.CellRange(SheetCore.CellRef("C3"), SheetCore.CellRef("E4")), SheetCore.CellRange(SheetCore.CellRef("C1"), SheetCore.CellRef("G6")))
        @test SheetCore.intersects(SheetCore.CellRange(SheetCore.CellRef("C1"), SheetCore.CellRef("G6")), SheetCore.CellRange(SheetCore.CellRef("C3"), SheetCore.CellRef("E4")))
        @test SheetCore.intersects(SheetCore.CellRange(SheetCore.CellRef("A1"), SheetCore.CellRef("E4")), SheetCore.CellRange(SheetCore.CellRef("C3"), SheetCore.CellRef("G6")))
        @test SheetCore.intersects(SheetCore.CellRange(SheetCore.CellRef("C3"), SheetCore.CellRef("G6")), SheetCore.CellRange(SheetCore.CellRef("A1"), SheetCore.CellRef("E4")))
        @test SheetCore.intersects(SheetCore.CellRange(SheetCore.CellRef("C3"), SheetCore.CellRef("D4")), SheetCore.CellRange(SheetCore.CellRef("A1"), SheetCore.CellRef("E6")))
    end

    @testset "Column Range" begin

        @testset "Single Column" begin
            c = SheetCore.ColumnRange("C")
            @test c.start == 3
            @test c.stop == 3
            show(IOBuffer(), c)

            c = SheetCore.ColumnRange("AA")
            @test c.start == 27
            @test c.stop == 27
        end

        @testset "Multiple Columns" begin
            c = SheetCore.ColumnRange("A:Z")
            @test c.start == 1
            @test c.stop == 26

            c = SheetCore.ColumnRange("A:AA")
            @test c.start == 1
            @test c.stop == 27

            cr = SheetCore.ColumnRange("B:D")
            @test string(cr) == "B:D"
            @test cr.start == 2
            @test cr.stop == 4
            @test length(cr) == 3

            cr = SheetCore.ColumnRange("B")
            @test string(cr) == "B:B"
            @test cr.start == 2
            @test cr.stop == 2
            @test length(cr) == 1

            @test SheetCore.ColumnRange("B1:D3") == SheetCore.ColumnRange("B:D")

            @test_throws SheetCore.SheetCoreError SheetCore.ColumnRange("D:A")
            @test collect(SheetCore.ColumnRange("B:D")) == ["B", "C", "D"]
            @test SheetCore.ColumnRange("B:D") == SheetCore.ColumnRange("B:D")
            @test hash(SheetCore.ColumnRange("B:D")) == hash(SheetCore.ColumnRange("B:D"))

            @test SheetCore.SheetColumnRange{SheetCore.ExcelStyle}("Sheet1!\$A:\$C") == SheetCore.SheetColumnRange{SheetCore.ExcelStyle}("Sheet1!A:C")
            @test string(SheetCore.SheetColumnRange{SheetCore.ExcelStyle}("'My Sheet'!\$A:\$C")) == "'My Sheet'!A:C"
            @test string(SheetCore.SheetCellRange{SheetCore.ExcelStyle}("'My Sheet'!\$A\$1:\$B\$2")) == "'My Sheet'!A1:B2"
            @test SheetCore.SheetCellRange{SheetCore.ExcelStyle}("'My Sheet'!\$A\$1:\$B\$2").sheet == "My Sheet"
            @test_throws SheetCore.SheetCoreError SheetCore.SheetColumnRange{SheetCore.ExcelStyle}("Sheet1!\$A:C")   # mixed anchoring

        end
    end
    @testset "Row Range" begin # Issue #150
        cr = SheetCore.RowRange("2:5")
        @test string(cr) == "2:5"
        @test cr.start == 2
        @test cr.stop == 5
        @test length(cr) == 4
        @test collect(cr) == ["2", "3", "4", "5"]

        cr = SheetCore.RowRange("2")
        @test string(cr) == "2:2"
        @test cr.start == 2
        @test cr.stop == 2
        @test length(cr) == 1
        @test collect(cr) == ["2"]

        @test SheetCore.RowRange("B1:D3") == SheetCore.RowRange("1:3")
        @test_throws SheetCore.SheetCoreError SheetCore.RowRange("5:2")
        @test SheetCore.RowRange("2:5") == SheetCore.RowRange("2:5")
        @test hash(SheetCore.RowRange("2:5")) == hash(SheetCore.RowRange("2:5"))

        @test SheetCore.SheetRowRange{SheetCore.ExcelStyle}("Sheet1!\$1:\$5") == SheetCore.SheetRowRange{SheetCore.ExcelStyle}("Sheet1!1:5")

    end

    @testset "Non-contiguous Range" begin
        cr = SheetCore.NonContiguousRange{SheetCore.ExcelStyle}("Sheet1!D1:D3,Sheet1!B1:B3")
        @test string(cr) == "Sheet1!D1:D3,Sheet1!B1:B3"
        @test cr.sheet == "Sheet1"
        @test cr.rng == [SheetCore.CellRange("D1:D3"), SheetCore.CellRange("B1:B3")]
        @test length(cr) == 6
        @test length(SheetCore.NonContiguousRange{SheetCore.ExcelStyle}("Sheet1!B1:B1,Sheet1!B1")) == 1
        @test collect(cr.rng) == [SheetCore.CellRange("D1:D3"), SheetCore.CellRange("B1:B3")]
        @test SheetCore.NonContiguousRange{SheetCore.ExcelStyle}("Sheet1!D1:D3,Sheet1!B1:B3") == SheetCore.NonContiguousRange{SheetCore.ExcelStyle}("Sheet1!D1:D3,Sheet1!B1:B3")
        @test hash(SheetCore.NonContiguousRange{SheetCore.ExcelStyle}("Sheet1!D1:D3,Sheet1!B1:B3")) == hash(SheetCore.NonContiguousRange{SheetCore.ExcelStyle}("Sheet1!D1:D3,Sheet1!B1:B3"))


        @test_throws SheetCore.SheetCoreError SheetCore.NonContiguousRange{SheetCore.ExcelStyle}("Sheet1!D1:D3,B1:B3")
        @test_throws SheetCore.SheetCoreError SheetCore.NonContiguousRange{SheetCore.ExcelStyle}("Sheet1!D1:D3,Sheet2!B1:B3")
        @test_throws SheetCore.SheetCoreError SheetCore.NonContiguousRange{SheetCore.ExcelStyle}("B1:D3")
        @test_throws SheetCore.SheetCoreError SheetCore.NonContiguousRange{SheetCore.ExcelStyle}("2:5")

    end

    @testset "CellRange iterator" begin
        rng = SheetCore.CellRange("A2:C4")
        @test collect(rng) == [SheetCore.CellRef("A2"), SheetCore.CellRef("B2"), SheetCore.CellRef("C2"), SheetCore.CellRef("A3"), SheetCore.CellRef("B3"), SheetCore.CellRef("C3"), SheetCore.CellRef("A4"), SheetCore.CellRef("B4"), SheetCore.CellRef("C4")]
    end

    @testset "Base methods on references and ranges" begin

        # cell ranges and Base methods on references
        # by position, row by row (D-098; XLSX.jl compares the strings, so A2 < B1 and B10 < B2)
        @test isless(SheetCore.CellRef("B1"), SheetCore.CellRef("A2")) && isless(SheetCore.CellRef("B2"), SheetCore.CellRef("B10"))
        @test 2 in SheetCore.ColumnRange("A:C") && 2 in SheetCore.RowRange("1:3")
        @test convert(SheetCore.RowRange, "2:4") == SheetCore.RowRange("2:4")
        @test convert(SheetCore.RowRange, SheetCore.RowRange("2:4")) == SheetCore.RowRange("2:4")
        srr = SheetCore.SheetRowRange{SheetCore.ExcelStyle}("Sheet1!2:4")
        @test string(srr) == "Sheet1!2:4"
        @test hash(srr) == hash(SheetCore.SheetRowRange{SheetCore.ExcelStyle}("Sheet1!2:4"))
    end
end

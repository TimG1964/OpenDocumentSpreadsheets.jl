# Ported from XLSX.jl 0.13.4 test/test_files/cells/references.jl (MIT License, Copyright (c)
# 2018-2026 Felipe Noronha Tavares and other contributors). See records/provenance.md.
# Renamed: XLSX → SheetCore, XLSXError → SheetCoreError, EXCEL_MAX_* → MAX_*.
# D-015: the sheet-qualified constructors take the style explicitly (`SheetCellRef{SheetCore.ExcelStyle}(…)`, `nCR(SheetCore.ExcelStyle, …)`).
# Left out (1 line): `relative_cell_position(EmptyCell(...), rng)`, which needs XLSX.jl's cell types.

@testset "cell names" begin
    @test !SheetCore.is_valid_cellname("A0")
    @test SheetCore.is_valid_cellname("A1")
    @test !SheetCore.is_valid_cellname("A")
    @test !SheetCore.is_valid_cellname("1")
    @test SheetCore.is_valid_cellname("XFD1048576")
    @test !SheetCore.is_valid_cellname("XFD1048577")
    @test SheetCore.is_valid_cellname("XFD1")
    @test !SheetCore.is_valid_cellname("ZFD1")
    @test SheetCore.is_valid_column_name("A")
    @test SheetCore.is_valid_column_name("AZ")
    @test SheetCore.is_valid_column_name("AAZ")
    @test !SheetCore.is_valid_column_name("AAAZ")
    @test !SheetCore.is_valid_column_name(":")
    @test !SheetCore.is_valid_column_name("É")
    @test SheetCore.is_valid_row_name("1")
    @test SheetCore.is_valid_row_name("12")
    @test SheetCore.is_valid_row_name("123")
    @test !SheetCore.is_valid_row_name("012")
    @test !SheetCore.is_valid_row_name(":")
    @test !SheetCore.is_valid_row_name("A")

    @test SheetCore.is_valid_sheet_cellname("Sheet1!A2")
    @test !SheetCore.is_valid_sheet_cellname("Sheet1!A2:B3")
    @test !SheetCore.is_valid_sheet_cellname("Sheet1!A0")
    @test !SheetCore.is_valid_sheet_cellname("A1")
    @test !SheetCore.is_valid_sheet_cellname("Sheet1!")
    @test !SheetCore.is_valid_sheet_cellname("Sheet1")
    @test !SheetCore.is_valid_sheet_cellname("Sheet1!A")
    @test !SheetCore.is_valid_sheet_cellname("Sheet1!1")
    @test SheetCore.is_valid_sheet_cellname("NEGOCIAÇÕES Descrição!A1")

    @test SheetCore.is_valid_sheet_cellrange("Sheet1!A1:B4")
    @test !SheetCore.is_valid_sheet_cellrange("Sheet1!:B4")
    @test !SheetCore.is_valid_sheet_cellrange("Sheet1!A1:")
    @test !SheetCore.is_valid_sheet_cellrange("Sheet1!:")
    @test !SheetCore.is_valid_sheet_cellrange("A1:B4")
    @test !SheetCore.is_valid_sheet_cellrange("Sheet1!")
    @test !SheetCore.is_valid_sheet_cellrange("Sheet1")
    @test !SheetCore.is_valid_sheet_cellrange("mysheet!A1")

    @test SheetCore.is_valid_sheet_column_range("Sheet1!A:B")
    @test SheetCore.is_valid_sheet_column_range("Sheet1!AB:BC")
    @test !SheetCore.is_valid_sheet_column_range("A:B")
    @test !SheetCore.is_valid_sheet_column_range("Sheet1!")
    @test !SheetCore.is_valid_sheet_column_range("Sheet1")
    @test SheetCore.is_valid_sheet_row_range("Sheet1!1:2")
    @test SheetCore.is_valid_sheet_row_range("Sheet1!12:23")
    @test !SheetCore.is_valid_sheet_row_range("1:2")
    @test !SheetCore.is_valid_sheet_row_range("Sheet1!")
    @test !SheetCore.is_valid_sheet_row_range("Sheet1")

    @test SheetCore.is_valid_non_contiguous_range("Sheet1!B1,Sheet1!B3")
    @test SheetCore.is_valid_non_contiguous_range("Sheet1!B1,Sheet1!GZ75:HB127")
    @test SheetCore.is_valid_non_contiguous_range("B2,B5")
    @test SheetCore.is_valid_non_contiguous_range("C3:C5,D6,G7:G8")
    @test !SheetCore.is_valid_non_contiguous_range("Sheet1!C3,Sheet2!C3")
    @test !SheetCore.is_valid_non_contiguous_range("Sheet1!B3")
    @test !SheetCore.is_valid_non_contiguous_range("Sheet1!B3:C6")

    @test in(SheetCore.SheetCellRef{SheetCore.ExcelStyle}("Sheet1!A1"), SheetCore.NonContiguousRange{SheetCore.ExcelStyle}("Sheet1!A1,Sheet1!B2")) == true
    @test in(SheetCore.SheetCellRef{SheetCore.ExcelStyle}("Sheet1!B2"), SheetCore.NonContiguousRange{SheetCore.ExcelStyle}("Sheet1!A1,Sheet1!B2")) == true
    @test in(SheetCore.SheetCellRef{SheetCore.ExcelStyle}("Sheet1!A2"), SheetCore.NonContiguousRange{SheetCore.ExcelStyle}("Sheet1!A1,Sheet1!B2")) == false

    ncrng_mixed = SheetCore.NonContiguousRange{SheetCore.ExcelStyle}("Sheet1!A1,Sheet1!C3:E5")
    @test in(SheetCore.SheetCellRef{SheetCore.ExcelStyle}("Sheet1!D4"), ncrng_mixed) == true  # interior of the range piece
    @test in(SheetCore.SheetCellRef{SheetCore.ExcelStyle}("Sheet1!C3"), ncrng_mixed) == true  # top-left corner of the range piece
    @test in(SheetCore.SheetCellRef{SheetCore.ExcelStyle}("Sheet1!E5"), ncrng_mixed) == true  # bottom-right corner of the range piece
    @test in(SheetCore.SheetCellRef{SheetCore.ExcelStyle}("Sheet1!F6"), ncrng_mixed) == false # just outside the range piece
    @test in(SheetCore.SheetCellRef{SheetCore.ExcelStyle}("Sheet1!B2"), ncrng_mixed) == false # matches neither piece
    @test in(SheetCore.SheetCellRef{SheetCore.ExcelStyle}("Sheet2!D4"), ncrng_mixed) == false # right position, wrong sheet

    @testset "CellRef and column names" begin
        cn = SheetCore.CellRef("A1")
        @test string(cn) == "A1"
        @test SheetCore.column_name(cn) == "A"
        @test SheetCore.row_number(cn) == 1
        @test SheetCore.column_number(cn) == 1

        cn = SheetCore.CellRef("AB1")
        @test string(cn) == "AB1"
        @test SheetCore.column_name(cn) == "AB"
        @test SheetCore.row_number(cn) == 1
        @test SheetCore.column_number(cn) == 28

        cn = SheetCore.CellRef("AMI1")
        @test string(cn) == "AMI1"
        @test SheetCore.column_name(cn) == "AMI"
        @test SheetCore.row_number(cn) == 1
        @test SheetCore.column_number(cn) == 1023

        cn = SheetCore.CellRef("XFD1048576")
        @test string(cn) == "XFD1048576"
        @test SheetCore.column_name(cn) == "XFD"
        @test SheetCore.row_number(cn) == SheetCore.MAX_ROWS
        @test SheetCore.column_number(cn) == SheetCore.MAX_COLS

        v_column_numbers = [1, 15, 22, 23, 24, 25, 26, 27, 28, 29, 30, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83, 84, 85, 86, 284, 285, 286, 287, 288, 289, 296, 297, 299, 300, 301, 700, 701, 702, 703, 704, 705, 706, 727, 728, 729, 730, 731, 1008, 1013, 1014, 1015, 1016, 1017, 1018, 1023, 1024, 1376, 1377, 1378, 1379, 1380, 1381, 3379, 3380, 3381, 3382, 3383, 3403, 3404, 3405, 3406, 3407, 16250, 16251, 16354, 16355, 16384]

        v_column_names = ["A", "O", "V", "W", "X", "Y", "Z", "AA", "AB", "AC", "AD", "AL", "AM", "AN", "AO", "AP", "AQ", "AR", "AS", "AT", "AU", "AV", "AW", "AX", "AY", "AZ", "BA", "BB", "BC", "BD", "BE", "BF", "BG", "BH", "BI", "BV", "BW", "BX", "BY", "BZ", "CA", "CB", "CC", "CD", "CE", "CF", "CG", "CH", "JX", "JY", "JZ", "KA", "KB", "KC", "KJ", "KK", "KM", "KN", "KO", "ZX", "ZY", "ZZ", "AAA", "AAB", "AAC", "AAD", "AAY", "AAZ", "ABA", "ABB", "ABC", "ALT", "ALY", "ALZ", "AMA", "AMB", "AMC", "AMD", "AMI", "AMJ", "AZX", "AZY", "AZZ", "BAA", "BAB", "BAC", "DYY", "DYZ", "DZA", "DZB", "DZC", "DZW", "DZX", "DZY", "DZZ", "EAA", "WZZ", "XAA", "XDZ", "XEA", "XFD"]

        @assert length(v_column_names) == length(v_column_numbers) "Test script is wrong."

        for i in axes(v_column_names, 1)
            @test SheetCore.encode_column_number(v_column_numbers[i]) == v_column_names[i]
            @test SheetCore.decode_column_number(v_column_names[i]) == v_column_numbers[i]
        end

        ref = SheetCore.CellRef(12, 2)
        @test SheetCore.cellname(ref) == "B12"
        show(IOBuffer(), ref)
    end

    cr = SheetCore.range"A1:C4"
    @test string(cr) == "A1:C4"
    @test SheetCore.row_number(cr.start) == 1
    @test SheetCore.column_number(cr.start) == 1
    @test SheetCore.row_number(cr.stop) == 4
    @test SheetCore.column_number(cr.stop) == 3
    @test size(cr) == (4, 3)
    show(IOBuffer(), cr)

    cr = SheetCore.range"B2:C8"
    @test SheetCore.ref"B2" ∈ cr
    @test SheetCore.ref"B3" ∈ cr
    @test SheetCore.ref"C2" ∈ cr
    @test SheetCore.ref"C3" ∈ cr
    @test SheetCore.ref"C8" ∈ cr
    @test SheetCore.ref"A1" ∉ cr
    @test SheetCore.ref"C9" ∉ cr
    @test SheetCore.ref"D4" ∉ cr
    @test size(cr) == (7, 2)

    fullrng = SheetCore.range"B2:E5"
    @test fullrng ⊆ fullrng
    @test SheetCore.range"B3:D4" ⊆ fullrng
    @test !issubset(SheetCore.range"A1:E5", fullrng)

    @test SheetCore.is_valid_cellrange("B2:C8")
    @test !SheetCore.is_valid_cellrange("A:B")
    @test_throws SheetCore.SheetCoreError SheetCore.CellRange("Z10:A1")
    @test_throws SheetCore.SheetCoreError SheetCore.CellRange("Z1:A1")

    # hashing and equality
    @test SheetCore.CellRef("AMI1") == SheetCore.CellRef("AMI1")
    @test hash(SheetCore.CellRef("AMI1")) == hash(SheetCore.CellRef("AMI1"))
    @test SheetCore.CellRange("A1:C4") == SheetCore.CellRange("A1:C4")
    @test hash(SheetCore.CellRange("A1:C4")) == hash(SheetCore.CellRange("A1:C4"))

    # relative cell position
    rng = SheetCore.range"B2:D4"
    @test SheetCore.relative_cell_position(SheetCore.ref"C3", rng) == (2, 2)
    @test SheetCore.relative_cell_position(SheetCore.ref"B2", rng) == (1, 1)
    @test SheetCore.relative_cell_position(SheetCore.ref"C4", rng) == (3, 2)
    @test SheetCore.relative_cell_position(SheetCore.ref"D4", rng) == (3, 3)

    # SheetCellRef, SheetCellRange, SheetColumnRange
    ref = SheetCore.SheetCellRef{SheetCore.ExcelStyle}("Sheet1!A2")
    @test string(ref) == "Sheet1!A2"
    @test ref.sheet == "Sheet1"
    @test ref.cellref == SheetCore.CellRef("A2")
    @test SheetCore.SheetCellRef{SheetCore.ExcelStyle}("Sheet1!A2") == SheetCore.SheetCellRef{SheetCore.ExcelStyle}("Sheet1!A2")
    @test hash(SheetCore.SheetCellRef{SheetCore.ExcelStyle}("Sheet1!A2")) == hash(SheetCore.SheetCellRef{SheetCore.ExcelStyle}("Sheet1!A2"))
    show(IOBuffer(), ref)

    ref = SheetCore.SheetCellRange{SheetCore.ExcelStyle}("Sheet1!A1:B4")
    @test ref.sheet == "Sheet1"
    @test ref.rng == SheetCore.CellRange("A1:B4")
    @test_throws SheetCore.SheetCoreError SheetCore.SheetCellRange{SheetCore.ExcelStyle}("Sheet1!B4:A1")
    @test SheetCore.SheetCellRange{SheetCore.ExcelStyle}("Sheet1!A1:B4") == SheetCore.SheetCellRange{SheetCore.ExcelStyle}("Sheet1!A1:B4")
    @test hash(SheetCore.SheetCellRange{SheetCore.ExcelStyle}("Sheet1!A1:B4")) == hash(SheetCore.SheetCellRange{SheetCore.ExcelStyle}("Sheet1!A1:B4"))
    show(IOBuffer(), ref)

    ref = SheetCore.SheetColumnRange{SheetCore.ExcelStyle}("Sheet1!A:B")
    @test string(ref) == "Sheet1!A:B"
    @test ref.sheet == "Sheet1"
    @test ref.colrng == SheetCore.ColumnRange("A:B")
    @test SheetCore.SheetColumnRange{SheetCore.ExcelStyle}("Sheet1!A:B") == SheetCore.SheetColumnRange{SheetCore.ExcelStyle}("Sheet1!A:B")
    @test hash(SheetCore.SheetColumnRange{SheetCore.ExcelStyle}("Sheet1!A:B")) == hash(SheetCore.SheetColumnRange{SheetCore.ExcelStyle}("Sheet1!A:B"))
    show(IOBuffer(), ref)

    ref = SheetCore.SheetColumnRange{SheetCore.ExcelStyle}("Sheet1!A:AA")
    @test string(ref) == "Sheet1!A:AA"
    @test ref.sheet == "Sheet1"
    @test ref.colrng == SheetCore.ColumnRange("A:AA")
    @test SheetCore.SheetColumnRange{SheetCore.ExcelStyle}("Sheet1!A:AA") == SheetCore.SheetColumnRange{SheetCore.ExcelStyle}("Sheet1!A:AA")
    @test hash(SheetCore.SheetColumnRange{SheetCore.ExcelStyle}("Sheet1!A:AA")) == hash(SheetCore.SheetColumnRange{SheetCore.ExcelStyle}("Sheet1!A:AA"))
    show(IOBuffer(), ref)

    ref = SheetCore.SheetColumnRange{SheetCore.ExcelStyle}("Sheet1!AA:AA")
    @test string(ref) == "Sheet1!AA:AA"
    @test ref.sheet == "Sheet1"
    @test ref.colrng == SheetCore.ColumnRange("AA:AA")
    @test SheetCore.SheetColumnRange{SheetCore.ExcelStyle}("Sheet1!AA:AA") == SheetCore.SheetColumnRange{SheetCore.ExcelStyle}("Sheet1!AA:AA")
    @test hash(SheetCore.SheetColumnRange{SheetCore.ExcelStyle}("Sheet1!AA:AA")) == hash(SheetCore.SheetColumnRange{SheetCore.ExcelStyle}("Sheet1!AA:AA"))
    show(IOBuffer(), ref)

    @test SheetCore.is_valid_fixed_sheet_cellname("named_ranges!\$A\$2")
    @test SheetCore.is_valid_fixed_sheet_cellrange("named_ranges!\$B\$4:\$C\$5")
    @test !SheetCore.is_valid_fixed_sheet_cellname("named_ranges!A2")
    @test !SheetCore.is_valid_fixed_sheet_cellrange("named_ranges!B4:C5")
    @test SheetCore.SheetCellRef{SheetCore.ExcelStyle}("named_ranges!\$A\$2") == SheetCore.SheetCellRef{SheetCore.ExcelStyle}("named_ranges!A2")
    @test SheetCore.SheetCellRange{SheetCore.ExcelStyle}("named_ranges!\$B\$4:\$C\$5") == SheetCore.SheetCellRange{SheetCore.ExcelStyle}("named_ranges!B4:C5")

    @testset "out-of-range and malformed references are rejected" begin
        # out-of-range column and row numbers are rejected
        @test_throws SheetCore.SheetCoreError SheetCore.encode_column_number(0)
        @test_throws SheetCore.SheetCoreError SheetCore.encode_column_number(SheetCore.MAX_COLS + 1)
        @test SheetCore.encode_column_number(SheetCore.MAX_COLS) == "XFD"
        @test !SheetCore.is_valid_row_range(string(SheetCore.MAX_ROWS + 1))     # a validator says no, not throws
        @test SheetCore.is_valid_row_range(string(SheetCore.MAX_ROWS))
        @test_throws SheetCore.SheetCoreError SheetCore.split_cellname("A")

        # validators given numbers too long for any integer say no (they threw OverflowError)
        big = "99999999999999999999"
        @test !SheetCore.is_valid_row_name(big) && !SheetCore.is_valid_row_range(big)
        @test !SheetCore.is_valid_cellname("A" * big) && !SheetCore.is_valid_cellrange("A1:A" * big)
        @test !SheetCore.is_valid_column_range("ZZZ")                           # one column, past XFD
        @test SheetCore.is_valid_column_range("XFD")

        # CellRef checks its bounds (it gave A0, a wrapped column, or InexactError)
        for bad in ("A" * big, "A1048577", "XFE1", "ZZZ1", "ZZZZZZZZZZZZZZ1")
            @test_throws SheetCore.SheetCoreError SheetCore.CellRef(bad)
        end
        for (r, c) in ((0, 1), (1, 0), (SheetCore.MAX_ROWS + 1, 1), (1, SheetCore.MAX_COLS + 1), (-1, -1))
            @test_throws SheetCore.SheetCoreError SheetCore.CellRef(r, c)
            # Int32, as every Int is on a 32-bit build: the default constructor skipped the check
            @test_throws SheetCore.SheetCoreError SheetCore.CellRef(Int32(r), Int32(c))
        end
        @test string(SheetCore.CellRef("XFD1048576")) == "XFD1048576"
        @test SheetCore.CellRef(SheetCore.MAX_ROWS, SheetCore.MAX_COLS) == SheetCore.CellRef("XFD1048576")

        # column names are the letters A to Z only (`b` read as column AH, `A1` as K)
        for bad in ("b", "A1", "", "Ä", "A-")
            @test_throws SheetCore.SheetCoreError SheetCore.decode_column_number(bad)
        end
        @test SheetCore.decode_column_number("XFD") == SheetCore.MAX_COLS
        @test SheetCore.decode_column_number("Z"^30) == SheetCore.MAX_COLS + 1      # past the last: no overflow

        @test !SheetCore.is_valid_row_name("0")
        @test !SheetCore.is_valid_cellrange("A0:B2") && !SheetCore.is_valid_cellrange("A1:B0")
        @test !SheetCore.is_valid_column_range("A:ZZZZ")
        @test !SheetCore.is_valid_row_range("0:2")
        @test !SheetCore.is_valid_sheet_cellrange("Sheet1!A0:B2")
        @test !SheetCore.is_valid_sheet_column_range("Sheet1!A:ZZZZ")
        @test !SheetCore.is_valid_sheet_row_range("Sheet1!0:2")

        @test sprint(show, SheetCore.SheetRowRange{SheetCore.ExcelStyle}("Sheet1!2:4")) == "Sheet1!2:4"
        @test_throws SheetCore.SheetCoreError SheetCore.NonContiguousRange{SheetCore.ExcelStyle}("Sheet1!A1,Sheet2!B2")
        @test_throws SheetCore.SheetCoreError SheetCore.nCR(SheetCore.ExcelStyle, "Sheet1", ["not a ref"])
        nc = SheetCore.nCR(SheetCore.ExcelStyle, "Sheet1", ["\$A\$1", "\$B\$1:\$C\$2"])
        @test nc.rng == [SheetCore.CellRef("A1"), SheetCore.CellRange("B1:C2")]
    end
end

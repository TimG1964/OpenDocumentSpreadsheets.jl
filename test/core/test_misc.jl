# SheetCore: tables, colours, text widths, errors and limits. New tests (phase 0b).

using Dates
import Tables

@testset "DataTable and Tables.jl" begin
    dt = SheetCore.DataTable(Any[[1, 2, 3], ["a", "b", "c"]], [:n, :s])
    @test Tables.istable(dt)
    @test Tables.columnnames(dt) == [:n, :s]
    @test Tables.getcolumn(dt, :s) == ["a", "b", "c"]
    @test Tables.getcolumn(dt, 1) == [1, 2, 3]
    @test Tables.schema(dt).types == (Int, String)
    @test Tables.columntable(dt) == (n = [1, 2, 3], s = ["a", "b", "c"])
    @test_throws SheetCore.SheetCoreError Tables.getcolumn(dt, :zz)
    @test_throws SheetCore.SheetCoreError SheetCore.DataTable(Any[[1]], [:a, :b])
    @test_throws SheetCore.SheetCoreError SheetCore.DataTable(Any[[1], [2]], [:a, :a])
end

@testset "column type inference" begin
    @test SheetCore.typed_column(Any[1, 2]) isa Vector{Int}
    @test SheetCore.typed_column(Any[1.0, missing]) isa Vector{Union{Missing,Float64}}
    @test SheetCore.typed_column(Any["a", 1]) isa Vector{Any}
    @test eltype(SheetCore.typed_column(Any[])) === Any
    # the builders widen one type at a time, then give the inferred type
    col = SheetCore._new_column(true)
    for x in (1.0, 2.0, missing, 3.0)
        col = SheetCore._push_column!(col, x)
    end
    @test SheetCore._finish_column(col) isa Vector{Union{Missing,Float64}}
    @test SheetCore._finish_column(col)[1:2] == [1.0, 2.0]
    @test SheetCore._new_column(false) isa Vector{Any}
    @test_throws SheetCore.SheetCoreError SheetCore.check_table_data_dimension(Any[[1, 2], [1]])
    @test_throws SheetCore.SheetCoreError SheetCore.check_table_data_dimension(Any[(1, 2)])
end

@testset "column labels" begin
    @test SheetCore.normalizename("my col") == :my_col
    @test SheetCore.normalizename("1st") == :_1st
    @test SheetCore.normalizename("end") == :_end
    @test SheetCore.normalizename("a  b") == :a_b
    v = String[]
    SheetCore.push_unique!(v, "x"); SheetCore.push_unique!(v, "x"); SheetCore.push_unique!(v, "x")
    @test v == ["x", "x_2", "x_3"]
end

@testset "writetable input" begin
    nt = (a = [1, 2], b = ["x", "y"])
    cols, names = SheetCore._table_to_arrays(nt)
    @test names == [:a, :b] && cols == Any[[1, 2], ["x", "y"]]
    @test_throws SheetCore.SheetCoreError SheetCore._table_to_arrays(42)
    specs = [("S1", [[1, 2]], ["c"]), (:S2, [[3]], [:d])]
    @test SheetCore._is_sheet_spec_vector(specs)
    @test SheetCore._normalize_sheet_specs(specs) == [("S1", Any[[1, 2]], ["c"]), ("S2", Any[[3]], ["d"])]
    @test !SheetCore._is_sheet_spec_vector([(1, [[1]], ["c"])])
    @test occursin("element 1", SheetCore._shape_hint([(1, [[1]], ["c"])]))
    @test SheetCore._check_table_shape(Any[[1, 2], [3, 4]], [:a, :b]) == 2
    @test_throws SheetCore.SheetCoreError SheetCore._check_table_shape(Any[[1, 2], [3]], [:a, :b])
    @test_throws SheetCore.SheetCoreError SheetCore._check_table_shape(Any[], Symbol[])
    @test_throws SheetCore.SheetCoreError SheetCore._sheetname_string(1)
end

@testset "colours" begin
    @test SheetCore.get_color("FF0000") == "FFFF0000"
    @test SheetCore.get_color("#ff000080") == "FF000080"
    @test SheetCore.get_color(:red) == "FFFF0000"
    @test SheetCore.get_color("grey") == SheetCore.get_color("gray")
    @test SheetCore.get_color(SheetCore.Colors.RGB(0, 0, 1)) == "FF0000FF"
    @test_throws SheetCore.SheetCoreError SheetCore.get_color("not-a-colour")
    @test SheetCore.odf_color("FFFF00") == "#ffff00"
    @test SheetCore.odf_color(:blue) == "#0000ff"
    @test SheetCore.parse_odf_color("#ffff00") == "FFFFFF00"
    @test SheetCore.parse_odf_color("transparent") === nothing
end

@testset "text widths" begin
    w = SheetCore.text_width_points("0000000000")
    @test w > 0
    @test SheetCore.text_width_points("0000000000", "Calibri", 22) ≈ 2w
    @test SheetCore.text_width_points("W") > SheetCore.text_width_points("i")
    @test SheetCore.text_width_points("ab\nabcdef") == SheetCore.text_width_points("abcdef")
    @test SheetCore.text_width_points("x"; bold = true) >= SheetCore.text_width_points("x")
    # a font without a table of its own is measured as the nearest by name, else Calibri
    @test SheetCore.text_width_points("abc", "Calibri Light") == SheetCore.text_width_points("abc", "Calibri")
    @test SheetCore.text_width_points("abc", "Liberation Sans") == SheetCore.text_width_points("abc", "Calibri")
    @test SheetCore._autofit_columns("B:D") == Set(2:4)
    @test SheetCore._autofit_columns("A,C") == Set([1, 3])
    @test SheetCore._autofit_columns(:) === nothing
    @test_throws SheetCore.SheetCoreError SheetCore._autofit_columns("1x")
end

@testset "errors and limits" begin
    @test SheetCore.MAX_ROWS == 1_048_576 && SheetCore.MAX_COLS == 16_384
    @test sprint(showerror, SheetCore.SheetCoreError("boom")) == "SheetCoreError: boom"
    @test string(SheetCore.CellRef(SheetCore.MAX_ROWS, SheetCore.MAX_COLS)) == "XFD1048576"
end

@testset "SheetCore is self-contained" begin
    # it must not depend on anything ODS-specific (D-001)
    src = joinpath(pkgdir(OpenDocumentSpreadsheets), "src", "core")
    for f in readdir(src; join = true)
        endswith(f, ".jl") || continue
        txt = read(f, String)
        @test !occursin(r"^\s*(import|using)\s+XML\b"m, txt)                 # no ODF/XML layer
        @test !occursin(r"^\s*(import|using)\s+\.\."m, txt)                   # nothing from the parent module
        @test !occursin(r"\bOpenDocumentSpreadsheets\.(?!jl\b)\w", txt)              # no qualified OpenDocumentSpreadsheets names
    end
end

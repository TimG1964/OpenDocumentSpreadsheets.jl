# Tables: eachtablerow, gettable, readtable, readto and the Tables.jl interface, on the
# lo-tables fixture. Themes ported from XLSX.jl's tests/tables/tables.jl.

using Dates
import Tables
using OpenDocumentSpreadsheets: getcell

@testset "gettable (cache=$cache)" for cache in (true, false)
    xf = openods(joinpath(DATA, "lo-tables.ods"); enable_cache = cache)
    ws = xf["Table"]
    dt = gettable(ws)
    @test dt isa OpenDocumentSpreadsheets.DataTable
    @test Tables.columnnames(dt) == [:id, :name, :value, :day, :flag]
    @test Tables.getcolumn(dt, :id) == [1, 2, 3, 4]                 # stops at the empty row 7
    @test Tables.getcolumn(dt, :id) isa Vector{Int64}
    @test isequal(Tables.getcolumn(dt, :name), ["a", "b", missing, "d"])
    @test Tables.getcolumn(dt, :name) isa Vector{Union{Missing,String}}
    @test Tables.getcolumn(dt, :value) == [1.5, 2.5, 3, 4.25]
    @test Tables.getcolumn(dt, :value) isa Vector{Float64}           # Int and Float promote, as in XLSX.jl
    @test Tables.getcolumn(dt, :day) == Date(2024, 1, 1) .+ Day.(0:3)
    @test Tables.getcolumn(dt, :flag) == [true, false, true, false]
    @test sprint(show, dt) == "DataTable with 5 columns and 4 rows."

    # rows past the empty one
    dt2 = gettable(ws; stop_in_empty_row = false)
    @test Tables.getcolumn(dt2, :id) == [1, 2, 3, 4, 6, 7]
    dt3 = gettable(ws; stop_in_empty_row = false, keep_empty_rows = true)
    @test isequal(Tables.getcolumn(dt3, :id), [1, 2, 3, 4, missing, 6, 7])
    # columns, first row, labels
    dt4 = gettable(ws, "B:C")
    @test Tables.columnnames(dt4) == [:id, :name]
    dt5 = gettable(ws, "B:C"; first_row = 3, header = false)
    @test Tables.columnnames(dt5) == [:B, :C] && Tables.getcolumn(dt5, :B) == [1, 2, 3, 4]
    dt6 = gettable(ws, "B:C"; column_labels = ["n", "s"])
    @test Tables.columnnames(dt6) == [:n, :s] && Tables.getcolumn(dt6, :n) == [1, 2, 3, 4]
    dt7 = gettable(ws; first_row = 3, header = false, stop_in_empty_row = false)
    @test Tables.getcolumn(dt7, 1) == [1, 2, 3, 4, 6, 7]
    @test_throws ODSError gettable(ws, "B:C"; column_labels = ["only one"])
    # missing_strings, normalizenames, infer_eltypes
    dt8 = gettable(ws; missing_strings = "b")
    @test isequal(Tables.getcolumn(dt8, :name), ["a", missing, missing, "d"])
    dt8b = gettable(ws; missing_strings = ["a", "d"])
    @test isequal(Tables.getcolumn(dt8b, :name), [missing, "b", missing, missing])
    dt9 = gettable(ws, "B:D"; column_labels = ["my id", "1st", "end"], normalizenames = true)
    @test Tables.columnnames(dt9) == [:my_id, :_1st, :_end]
    dt10 = gettable(ws; infer_eltypes = false)
    @test Tables.getcolumn(dt10, :id) isa Vector{Any}
    # stop_in_row_function: the row that stops is left out
    dt11 = gettable(ws; stop_in_row_function = r -> r[:id] == 3)
    @test Tables.getcolumn(dt11, :id) == [1, 2]
    # header labels from a non-string row, and an empty header cell
    dt12 = gettable(ws, "A:C"; first_row = 3)
    @test Tables.columnnames(dt12) == [Symbol("#Empty"), Symbol("1"), :a]
    # a sheet without a table
    @test_throws ODSError gettable(xf["Formulas"], "G:H")
    @test_throws ODSError gettable(ws, "B:C"; first_row = 50)
end

@testset "eachtablerow and Tables.jl rows" begin
    ws = readods(joinpath(DATA, "lo-tables.ods"))["Table"]
    rows = collect(eachtablerow(ws))
    @test length(rows) == 4
    r = rows[1]
    @test r isa OpenDocumentSpreadsheets.TableRow && row_number(r) == 1
    @test r[1] == 1 && r[:name] == "a" && r[:day] == Date(2024, 1, 1)
    @test isequal(collect(r), Any[1, "a", 1.5, Date(2024, 1, 1), true])
    @test length(r) == 5
    @test_throws ODSError r[:nope]
    @test Tables.istable(eachtablerow(ws))
    @test Tables.columnnames(r) == [:id, :name, :value, :day, :flag]
    @test Tables.getcolumn(r, 2) == "a" && Tables.getcolumn(r, Int32(2)) == "a"
    ct = Tables.columntable(eachtablerow(ws))
    @test ct.id == [1, 2, 3, 4] && ct.id isa Vector{Int64}   # D-016: Int64 on 32-bit too
    @test isequal(ct.name, ["a", "b", missing, "d"])
    @test Tables.columns(eachtablerow(ws, "B:C")).id == [1, 2, 3, 4]
    @test length(collect(eachtablerow(ws, "B:F"; stop_in_empty_row = false))) == 6
end

@testset "readtable and readto" begin
    f = joinpath(DATA, "lo-tables.ods")
    dt = readtable(f, "Table")
    @test Tables.getcolumn(dt, :id) == [1, 2, 3, 4]
    @test Tables.columnnames(readtable(f, "Table", "B:C")) == [:id, :name]
    @test Tables.columnnames(readtable(f)) == [:id, :name, :value, :day, :flag]   # the first sheet
    @test Tables.getcolumn(readtable(f, 1; stop_in_empty_row = false), :id) == [1, 2, 3, 4, 6, 7]
    @test Tables.getcolumn(readtable(f, "Table"; enable_cache = true), :id) == [1, 2, 3, 4]
    @test Tables.getcolumn(readtable(IOBuffer(read(f)), "Table"), :id) == [1, 2, 3, 4]
    @test Tables.getcolumn(readtable(joinpath(DATA, "lo-tables.fods"), "Names"; header = false), :A) == ["n1", "n2"]
    @test readto(f, "Table", Tables.columntable).id == [1, 2, 3, 4]
    @test readto(f, Tables.columntable).name[1] == "a"
    @test readto(f, "Table", "B:C", Tables.columntable) |> keys == (:id, :name)
end

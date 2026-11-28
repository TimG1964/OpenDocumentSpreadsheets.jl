# Column widths, row heights, autofit, and writetable's column keywords (phase 4, step 7).
#
# "Width and height (XLSX.jl)" and "autofitColumns (XLSX.jl)" are ported from XLSX.jl 0.13.4
# (test/test_files/formatting/styles.jl "Width and height"; formatting/autofit.jl
# "autofitColumns"), MIT License, Copyright (c) 2018-2026 Felipe Noronha Tavares and other
# contributors. Adapted: widths and heights read back as XLSX.jl's getters give them (D-034,
# D-042); whole sheets are not clipped to the used area (D-033); the template files are
# replaced by new sheets; autofit is LibreOffice's model (F-034).

using Dates
using OpenDocumentSpreadsheets: ODSError, getColumnWidth, getRowHeight, autofitColumns, setColumnWidth, setRowHeight, getText,
    EXCEL_COLUMN_WIDTH_PADDING, line_props, getprop

ltmp(name) = joinpath(mktempdir(), name)

@testset "Width and height (XLSX.jl)" begin
    f = newods()
    s = f["Sheet1"]
    s["A1"] = "Hello"; s["B1"] = "World"; s["A2"] = 2.367; s["B2"] = 200450023; s["C1"] = Date(2018, 2, 1)
    setColumnWidth(s, "A2"; width = 30)
    @test getColumnWidth(s, "A2") ≈ 30.7109375
    setColumnWidth(s, "B2:C2"; width = 10.1)
    @test getColumnWidth(s, "B3") ≈ 10.8109375 && getColumnWidth(s, "C4") ≈ 10.8109375
    setRowHeight(s, "A2"; height = 30)
    @test getRowHeight(s, "A2") ≈ 30.2109375
    setRowHeight(s, "B2:C5"; height = 10.1)
    @test getRowHeight(s, "B3") ≈ 10.3109375 && getRowHeight(s, "C4") ≈ 10.3109375
    @test getColumnWidth(s, "B3") ≈ 10.8109375                       # heights leave widths alone
    setColumnWidth(s, "B2:C2"; width = 30.5)
    @test getColumnWidth(s, "B3") ≈ 31.2109375 && getColumnWidth(f, "Sheet1!C4") ≈ 31.2109375
    @test getRowHeight(s, "B3") ≈ 10.3109375 && getRowHeight(f, "Sheet1.C4") ≈ 10.3109375

    f = newods()
    s = f[1]
    s["A1:Z26"] = ""
    setColumnWidth(s, "Sheet1!A1"; width = 60); @test getColumnWidth(s, "A1") ≈ 60.7109375
    setColumnWidth(s, "Sheet1!A1:Z1"; width = 60); @test getColumnWidth(s, "R1") ≈ 60.7109375
    setColumnWidth(s, "Sheet1!A:B"; width = 60); @test getColumnWidth(s, "B26") ≈ 60.7109375
    setColumnWidth(s, "Sheet1!2:3"; width = 60); @test getColumnWidth(s, "R26") ≈ 60.7109375
    setColumnWidth(s, "A:B"; width = 30.5); @test getColumnWidth(s, "B26") ≈ 31.2109375
    setColumnWidth(s, "Sheet1!C5:C7,Sheet1!F5:F7,Sheet1!H7"; width = 10.1); @test getColumnWidth(s, "F26") ≈ 10.8109375
    setColumnWidth(s, 5, :; width = 10.0); @test getColumnWidth(s, "Q5") ≈ 10.7109375
    setColumnWidth(s, 5:7; width = 10.2); @test getColumnWidth(s, "G22") ≈ 10.9109375
    setColumnWidth(s, :, 5:7; width = 10.3); @test getColumnWidth(s, "G22") ≈ 11.0109375
    setColumnWidth(s, :, :; width = 10.4); @test getColumnWidth(s, "G22") ≈ 11.1109375
    setColumnWidth(s, :; width = 10.5); @test getColumnWidth(s, "G22") ≈ 11.2109375
    @test getColumnWidth(s, "XFD1") ≈ 11.2109375                      # the whole sheet (D-033)
    setColumnWidth(s, 2:3:11, :; width = 10.6); @test getColumnWidth(s, "Z26") ≈ 11.3109375
    setColumnWidth(s, 2:3:11; width = 10.7); @test getColumnWidth(s, "E26") ≈ 11.4109375
    setColumnWidth(s, :, [2, 3, 11]; width = 10.8); @test getColumnWidth(s, "K15") ≈ 11.5109375
    setColumnWidth(s, 3:6, [2, 3, 11]; width = 10.9); @test getColumnWidth(s, "K15") ≈ 11.6109375
    setColumnWidth(s, 11, 7:13; width = 11.1); @test getColumnWidth(s, "K15") ≈ 11.8109375
    setRowHeight(s, 4; height = 20); @test getRowHeight(s, "Z4") ≈ 20.2109375
    setRowHeight(s, "6:8"; height = 0); @test getRowHeight(s, "A7") ≈ 0.2109375
    @test_throws ODSError setColumnWidth(s, "A1"; width = -1)
    @test_throws ODSError setRowHeight(s, "A1"; height = -1)
    @test setColumnWidth(s, "A1") == 0                                 # no width: nothing to do
end

@testset "units, and LibreOffice's own widths" begin
    f = newods(); s = f[1]
    setColumnWidth(s, "B"; width = 2.5, unit = :cm)
    @test getColumnWidth(s, "B1"; unit = :cm) ≈ 2.5 && getColumnWidth(s, "B1"; unit = :mm) ≈ 25
    @test getColumnWidth(s, "B1") ≈ 2.5 / 0.2152
    setColumnWidth(s, "C"; width = 1, unit = :in); @test getColumnWidth(s, "C1"; unit = :pt) ≈ 72
    setColumnWidth(s, "D"; width = 10)                                 # LibreOffice's width for XLSX.jl's 10 (D-034)
    @test getColumnWidth(s, "D1"; unit = :cm) ≈ 0.2152 * (10 + EXCEL_COLUMN_WIDTH_PADDING)
    @test getColumnWidth(s, "E1") === nothing && getRowHeight(s, "E1") == -1
    @test_throws ODSError setColumnWidth(s, "B"; width = 1, unit = :furlong)
    x = openods(joinpath(DATA, "lo-scenarios.ods"))                    # read-only
    w = x["S06-col-widths"]
    @test getColumnWidth(w, "A1"; unit = :cm) ≈ 3.0 && getColumnWidth(w, "D1"; unit = :cm) ≈ 2.258
    h = x["S07-row-heights"]
    @test getRowHeight(h, "A2") > getRowHeight(h, "A1") > 0
end

@testset "patched widths and heights change only the columns and rows" begin
    src = joinpath(DATA, "lo-scenarios.ods")
    xf = openods(src; mode = "rw")
    ws = xf["S01-gaps"]
    setColumnWidth(ws, "B"; width = 15)
    setRowHeight(ws, 3; height = 25)
    p = writeods(ltmp("p.ods"), xf)
    back = openods(p)
    for k in 1:sheetcount(back)
        sheetnames(back)[k] == "S01-gaps" && continue
        @test String(OpenDocumentSpreadsheets.XML.sourcetext(back[k].entry.node)) == String(OpenDocumentSpreadsheets.XML.sourcetext(openods(src)[k].entry.node))
    end
    b = back["S01-gaps"]
    @test getColumnWidth(b, "B1") ≈ 15.7109375 && getColumnWidth(b, "A1"; unit = :cm) ≈ getColumnWidth(ws, "A1"; unit = :cm)
    @test getRowHeight(b, "C3") ≈ 25.2109375 && getRowHeight(b, "C2") ≈ getRowHeight(ws, "C2")
    @test isequal(b[:], openods(src)["S01-gaps"][:])
end

@testset "autofitColumns (XLSX.jl)" begin
    f = newods()
    s = f[1]
    s["A1"] = "short"
    s["A2"] = "a much longer piece of text"
    s["B1"] = 1234567.891
    setFormat(s, "B1"; format = "#,##0.00")
    s["C1"] = Date(2026, 3, 7)
    setFormat(s, "C1"; format = "dddd, mmmm d, yyyy")
    s["D1"] = "two\nlines, the second longer"
    s["G1"] = "bold"
    setFont(s, "G1"; bold = true, size = 20)
    s["E1"] = "merged across E1:F1, so left out"
    mergeCells(s, "E1:F1")
    s["E2"] = "e"
    s["H1"] = ""                                                      # shows nothing
    setColumnWidth(s, 8; width = 30)
    widths = autofitColumns(s)
    @test sort(collect(keys(widths))) == [1, 2, 3, 4, 5, 7]
    @test widths[1] > widths[5]
    @test 9 < widths[2] < 13                                          # "1,234,567.89", as shown
    @test widths[5] < 3
    @test widths[4] < autofitColumns(s, "A")[1]
    @test widths[7] > 5
    @test getColumnWidth(s, 1, 8) ≈ 30 + EXCEL_COLUMN_WIDTH_PADDING
    @test getColumnWidth(s, 1, 1) ≈ widths[1] + EXCEL_COLUMN_WIDTH_PADDING
    @test collect(keys(autofitColumns(s, "B:C"))) |> sort == [2, 3]
    @test collect(keys(autofitColumns(s, "A,C:D"))) |> sort == [1, 3, 4]
    @test collect(keys(autofitColumns(s, 2))) == [2]
    @test collect(keys(autofitColumns(s, [1, 7]))) |> sort == [1, 7]
    @test collect(keys(autofitColumns(s, 1:2))) |> sort == [1, 2]
    @test autofitColumns(s, "A"; max_width = 10)[1] == 10
    @test autofitColumns(s, "E"; min_width = 8)[5] == 8
    @test_throws ODSError autofitColumns(s; max_width = 300)
    @test_throws ODSError autofitColumns(s; min_width = 20, max_width = 10)
    @test_throws ODSError autofitColumns(s, "B2")
    @test_throws ODSError autofitColumns(s, 1.5)
    io = IOBuffer(); writeods(io, f)
    @test_throws ODSError autofitColumns(readods(seekstart(io))[1])  # read-only
end

@testset "autofit is LibreOffice's optimal width (F-034)" begin
    f = newods(); s = f[1]
    s["A1"] = "Hello, world"                                          # Liberation Sans 10, as Arial
    w = autofitColumns(s)[1]
    pt = OpenDocumentSpreadsheets.SheetCore.text_width_points("Hello, world", "Arial", 10.0) + 7.9
    @test getColumnWidth(s, "A1"; unit = :pt) ≈ pt atol = 0.05
    @test w ≈ round(pt * 2.54 / 72 / 0.2152 - EXCEL_COLUMN_WIDTH_PADDING; digits = 2)
end

@testset "writetable: column_widths and column_formats" begin
    data = [[1.5, 2.25, 3.0], ["a", "b", "c"], [Date(2024, 1, 1), Date(2024, 1, 2), Date(2024, 1, 3)]]
    for streaming in (false, true)
        p = ltmp("t$streaming.ods")
        writetable(p, data, ["x", "name", "when"]; streaming, column_widths = [12, nothing, 20],
                   column_formats = Dict("x" => "0.000", 3 => "d mmm yyyy"))
        r = openods(p); s = r[1]
        @test getColumnWidth(s, "A1") ≈ 12.7109375 && getColumnWidth(s, "B1") === nothing && getColumnWidth(s, "C1") ≈ 20.7109375
        @test getText(s, "A1") == "x" && getText(s, "A2") == "1.500" && getText(s, "C3") == "2 Jan 2024"
        @test s["A2"] === 1.5 && s["C3"] == Date(2024, 1, 2)
    end
    p = ltmp("one.ods")
    writetable(p, data, ["x", "name", "when"]; column_widths = 9)
    @test all(c -> getColumnWidth(openods(p)[1], 1, c) ≈ 9.7109375, 1:3)
    # a number into a date-formatted streamed column: the format doesn't fit, so it isn't used
    p = ltmp("mixed.ods")
    streamods(p) do w
        sh = addsheet!(w, "S"; columns = ["d"], column_formats = Dict(1 => "yyyy"))
        writerow!(sh, [Date(2020, 5, 6)]); writerow!(sh, [7])
    end
    r = openods(p)["S"]
    @test getText(r, "A2") == "2020" && r["A3"] === Int64(7) && getText(r, "A3") == "7"
    # streamed widths are declared before the first sheet (D-042): a new width on a later sheet
    # needs `declare_widths`; writetable declares every sheet's
    @test_throws ODSError streamods(ltmp("late.ods")) do w
        addsheet!(w, "A"; columns = ["a"], column_widths = [10])
        addsheet!(w, "B"; columns = ["b"], column_widths = [20])
    end
    p = ltmp("declared.ods")
    streamods(p; declare_widths = [20]) do w
        addsheet!(w, "A"; columns = ["a"], column_widths = [10])
        addsheet!(w, "B"; columns = ["b"], column_widths = [20])
    end
    @test getColumnWidth(openods(p)["B"], "A1") ≈ 20.7109375 && getColumnWidth(openods(p)["A"], "A1") ≈ 10.7109375
    p = ltmp("two.ods")
    writetable(p, "S1" => (a = [1],), "S2" => (b = [2],); streaming = true, column_widths = 14)
    @test getColumnWidth(openods(p)["S2"], "A1") ≈ 14.7109375
    @test_throws ODSError writetable(ltmp("x.ods"), data, ["x", "name", "when"]; column_formats = Dict("nope" => "0"))
    @test_throws ODSError writetable(ltmp("y.ods"), data, ["x", "name", "when"]; column_widths = "wide")
end

@testset "LibreOffice keeps widths and heights" begin
    if lo_ok(; what = "the layout oracle")
        dir = mktempdir()
        profile = lo_profile_url(joinpath(dir, "lo-profile"))
        f = newods("L"); s = f["L"]
        s["A1"] = "text"; s["B2"] = 1
        setColumnWidth(s, "A"; width = 20); setColumnWidth(s, "C"; width = 3, unit = :cm)
        setRowHeight(s, 2; height = 40)
        f1 = writeods(joinpath(dir, "l.ods"), f)
        p2 = joinpath(dir, "s.ods")
        writetable(p2, [[1, 2]], ["n"]; streaming = true, column_widths = [25], column_formats = Dict(1 => "0.00"))
        lo_convert([f1, p2], "ods"; outdir = joinpath(dir, "lo"), profile = profile)
        r = openods(joinpath(dir, "lo", "l.ods"))["L"]
        @test getColumnWidth(r, "A1"; unit = :cm) ≈ getColumnWidth(s, "A1"; unit = :cm) atol = 0.002
        @test getColumnWidth(r, "C1"; unit = :cm) ≈ 3 atol = 0.002
        @test getRowHeight(r, "B2") ≈ 40.2109375 atol = 0.05
        r2 = openods(joinpath(dir, "lo", "s.ods"))[1]
        @test getColumnWidth(r2, "A1") ≈ 25.7109375 atol = 0.01
        @test getText(r2, "A2") == "1.00" && getText(r2, "A1") == "n"
    end
end

# The write path (phase 2): new files, editing, saving by patching (D-023), writetable,
# streaming, setFormula (D-025), and LibreOffice opening what we write.

using Dates
import Tables
using OpenDocumentSpreadsheets: getcell, getFormula, Cell, EmptyCell, ODSError, store_set!, SheetStore, CellData,
    encode_value, cell_data, ui_to_openformula, render_ui_formula, _strip_formula_prefix, isvisible,
    defined_names, get_dimension, SheetStore, CK_FLOAT, CK_STRING, F_INTLIKE

tmp(name) = joinpath(mktempdir(), name)

@testset "store_set! splits runs" begin
    d(x) = encode_value(x, Int32(0))
    s = SheetStore()
    store_set!(s, 5, 3, d(1))
    @test cell_data(s, 5, 3) !== nothing && get_dimension isa Function
    @test OpenDocumentSpreadsheets.store_dimension(s) == SheetCore.CellRange("C5:C5")
    # a repeated row and a repeated cell, split around an edit
    s = SheetStore([OpenDocumentSpreadsheets.RowData(1, 10, [OpenDocumentSpreadsheets.CellRun(1, 4, d(7))])], OpenDocumentSpreadsheets.ColRun[], SheetCore.CellRange[],
                   SheetCore.CellRange("A1:D10"))
    store_set!(s, 5, 2, d("x"))
    @test [(r.row, r.count) for r in s.rows] == [(1, 4), (5, 1), (6, 5)]
    @test [(c.col, c.count) for c in s.rows[2].runs] == [(1, 1), (2, 1), (3, 2)]
    @test cell_data(s, 5, 2).text == "x" && cell_data(s, 4, 2).kind === CK_FLOAT && cell_data(s, 6, 2).kind === CK_FLOAT
    store_set!(s, 5, 2, nothing)
    @test cell_data(s, 5, 2) === nothing && cell_data(s, 5, 3) !== nothing
    store_set!(s, 1, 1, nothing); store_set!(s, 1, 2, nothing); store_set!(s, 1, 3, nothing); store_set!(s, 1, 4, nothing)
    @test OpenDocumentSpreadsheets.store_dimension(s) == SheetCore.CellRange("A2:D10")
    # the shared runs of a split row are not changed by an edit to one part
    @test cell_data(s, 6, 2).kind === CK_FLOAT
end

@testset "encode_value" begin
    @test encode_value(missing, Int32(0)) === nothing && encode_value(nothing, Int32(0)) === nothing
    @test (encode_value(7, Int32(0)).flags & F_INTLIKE) != 0
    @test (encode_value(7.0, Int32(0)).flags & F_INTLIKE) == 0
    # ODF has no NaN or Inf: written as text, as XLSX.jl does (D-043)
    for (x, s) in ((NaN, "NaN"), (Inf, "Inf"), (-Inf, "-Inf"), (Inf32, "Inf"), (big(-Inf), "-Inf"))
        d = encode_value(x, Int32(0))
        @test d.kind === CK_STRING && d.text == s
    end
    @test_throws ODSError encode_value("a\x01b", Int32(0))
    @test_throws ODSError encode_value(Month(1), Int32(0))
    @test_throws ODSError encode_value(:sym, Int32(0))
    @test_throws ODSError encode_value([1, 2], Int32(0))
end

const VALUES = Any[42, -7, 0, 123456789012, 7.0, 0.30000000000000004, 1.0e-20, -2.5, 1.5e300, Float32(0.5), 3 // 4,
                   true, false, "text", "", "  lead  mid  ", "a\tb", "line1\nline2", "<&>\"'", "Ünï ✓",
                   Date(2024, 3, 5), Date(1899, 12, 30), Date(100, 1, 1), DateTime(2024, 3, 5, 13, 45, 30),
                   DateTime(2024, 3, 5, 13, 45, 30, 250), DateTime(2024, 3, 5), Time(13, 45, 30), Time(0, 0, 0, 500),
                   Dates.Hour(36), Dates.Minute(-90), Dates.canonicalize(Day(2) + Hour(3) + Second(1)), missing]
# what each value reads back as (D-016, D-017, D-026)
readback(v) = ismissing(v) ? missing : v isa Bool ? v : v isa Integer ? Int64(v) : v isa Rational ? Float64(v) : v isa AbstractFloat ? Float64(v) :
              v == "" ? missing : v isa Dates.Period ? OpenDocumentSpreadsheets.duration_value(OpenDocumentSpreadsheets._duration_ns(v)) :
              v isa Dates.CompoundPeriod ? OpenDocumentSpreadsheets.duration_value(OpenDocumentSpreadsheets._duration_ns(v)) : v

@testset "values round trip ($ext)" for ext in ("ods", "fods", "ots")
    xf = newods()
    ws = xf[1]
    for (i, v) in enumerate(VALUES)
        ws[i, 1] = v
    end
    p = writeods(tmp("v.$ext"), xf)
    r = readods(p)
    @test r.container.format === Symbol(ext)
    got = r[1]["A1:A$(length(VALUES))"]
    for (i, v) in enumerate(VALUES)
        @test isequal(got[i, 1], readback(v)) && typeof(got[i, 1]) == typeof(readback(v))
    end
    # types survive on the cells, with OpenDocumentSpreadsheets's ISO styles (D-024)
    @test getcell(r[1], 21, 1).style == "odsf-date" && getcell(r[1], 24, 1).style == "odsf-datetime"
    @test getcell(r[1], 27, 1).style == "odsf-time" && getcell(r[1], 12, 1).style == "odsf-boolean"
    @test getcell(r[1], 1, 1).style == "Default"
end

@testset "newods, addsheet!, writable" begin
    xf = newods()
    @test sheetnames(xf) == ["Sheet1"] && xf.writable
    @test addsheet!(xf).name == "Sheet2" && addsheet!(xf, "Data").name == "Data"
    @test_throws ODSError addsheet!(xf, "data")          # names are unique without regard to case
    @test_throws ODSError addsheet!(xf, "a/b")
    @test_throws ODSError addsheet!(xf, "'q")
    @test sheetnames(newods("First")) == ["First"]
    # read-only files can't be edited
    ro = readods(joinpath(DATA, "lo-tables.ods"))
    @test_throws ODSError ro["Table"]["A1"] = 1
    @test_throws ODSError addsheet!(ro, "X")
    @test_throws ODSError setFormula(ro["Table"], "A1"; val = "=1")
    @test_throws ODSError saveods(ro)
    @test_throws ODSError openods(joinpath(DATA, "lo-tables.ods"); mode = "rw", enable_cache = false)
    @test_throws ODSError saveods(newods())               # nowhere to save it
    @test_throws ODSError writeods(joinpath(DATA, "lo-tables.ods"), newods())   # exists
end

@testset "setdata! and setindex! forms" begin
    ws = newods()[1]
    ws["A1"] = 1
    ws[2, 1] = 2
    setdata!(ws, "A3", 3); setdata!(ws, 4, 1, 4); setdata!(ws, SheetCore.CellRef(5, 1), 5)
    ws["Sheet1.A6"] = 6; ws["Sheet1!A7"] = 7; ws["\$A\$8"] = 8
    @test ws["A1:A8"] == reshape(collect(1:8), 8, 1)
    ws["B1"] = [1, 2, 3]                       # along the row
    @test ws["B1:D1"] == [1 2 3]
    setdata!(ws, "B2", [4, 5], 1)              # down the column
    @test ws["B2:B3"] == reshape([4, 5], 2, 1)
    ws["E1:F2"] = [1 2; 3 4]
    @test ws["E1:F2"] == [1 2; 3 4]
    ws["G1:G3"] = [7, 8, 9]
    @test ws["G1:G3"] == reshape([7, 8, 9], 3, 1)
    ws["H1:I2"] = 0
    @test ws["H1:I2"] == zeros(Int, 2, 2)
    ws[1:2, 10:11] = [1 2; 3 4]
    @test ws["J1:K2"] == [1 2; 3 4]
    ws[3, 10:12] = [5, 6, 7]
    @test ws["J3:L3"] == [5 6 7]
    ws["A1"] = missing
    @test ismissing(ws["A1"]) && getcell(ws, "A1") isa EmptyCell
    @test_throws ODSError ws["A1:B2"] = [1 2 3]
    @test_throws ODSError ws["A1:B2"] = [1, 2, 3]
    @test_throws ODSError ws["Other.A1"] = 1
    @test_throws ODSError ws["A:B"] = 1
    @test_throws ODSError ws[0, 1] = 1
    @test_throws ODSError ws[1, 16385] = 1
    @test_throws ODSError ws[1, 1] = [1, 2]
end

@testset "whole rows and columns with `:`, as XLSX.jl" begin
    # a vector: along the row from column A, down the column from row 1
    ws = newods()[1]
    ws[2, :] = [1, "two", 3.5]
    @test isequal(ws["A2:C2"], Any[1 "two" 3.5]) && ismissing(ws["A1"])
    ws[:, 5] = [10, 20]
    @test ws["E1:E2"] == reshape([10, 20], 2, 1)
    setdata!(ws, 4, :, [true, false]); setdata!(ws, :, 6, [7])
    @test ws["A4:B4"] == [true false] && ws["F1"] == 7
    # any other value fills the used columns or rows (A1:F4 here)
    @test get_dimension(ws) == SheetCore.CellRange("A1:F4")
    ws[3, :] = 0
    @test ws["A3:F3"] == zeros(Int, 1, 6) && ismissing(ws["G3"])
    ws[:, 2] = "b"
    @test all(==("b"), ws["B1:B4"]) && ismissing(ws["B5"])
    ws[[1, 4], :] = -1
    @test all(==(-1), ws["A1:F1"]) && all(==(-1), ws["A4:F4"])
    ws[:, 3:4] = missing
    @test all(ismissing, ws["C1:D4"])
    ws[1:2, :] = reshape(collect(1:12), 2, 6)                    # a matrix of the rows' shape
    @test ws["A1:F2"] == reshape(collect(1:12), 2, 6)
    ws[:] = 9
    @test all(==(9), ws["A1:F4"]) && get_dimension(ws) == SheetCore.CellRange("A1:F4")
    ws[:, :] = 8
    @test all(==(8), ws[:])
    # the forms the precompile workload uses, and what doesn't fit
    xf = newods(); sh = xf[1]
    vals = Any[1, 2.5, "x", missing]
    sh[5, :] = vals
    @test isequal(sh["A5:D5"], permutedims(vals))
    @test_throws ODSError sh[[1, 2], :] = [1, 2]               # a vector across two rows
    @test_throws ODSError sh[1:2, :] = [1 2; 3 4; 5 6]         # a matrix of another shape
    ro = readods(joinpath(DATA, "lo-values.ods"))[1]
    @test_throws ODSError ro[1, :] = [1]
    @test_throws ODSError ro[:, 1] = 1
end

@testset "styles kept or chosen (D-027)" begin
    xf = openods(joinpath(DATA, "lo-values.ods"); mode = "rw")
    ws = xf["V"]
    r = findfirst(==("date 2024-03-05 D"), vec(ws["A1:A78"]))
    ws[r, 2] = Date(2000, 1, 2)                 # a date into a date cell keeps its style
    @test getcell(ws, r, 2).style == "cD"
    ws[r, 2] = 5                                # a number into a date cell: Default
    @test getcell(ws, r, 2).style == "Default" && ws[r, 2] === Int64(5)
    r2 = findfirst(==("float 7 style=N2"), vec(ws["A1:A78"]))
    ws[r2, 2] = 3                               # a number keeps its number format
    @test getcell(ws, r2, 2).style == "cN2" && ws[r2, 2] === 3.0
    ws[r2, 2] = Date(2000, 1, 1)                # a date into a number cell: our date style
    @test getcell(ws, r2, 2).style == "odsf-date"
    p = writeods(tmp("styles.ods"), xf)
    back = readods(p)["V"]
    @test back[r, 2] === Int64(5) && back[r2, 2] == Date(2000, 1, 1)
    @test getcell(back, r2, 2).style == "odsf-date"
end

# the text of one part of a zipped file
part(path, name) = String(OpenDocumentSpreadsheets.read_bytes(OpenDocumentSpreadsheets.open_container(path), name))

@testset "saving a read file patches it (D-023)" begin
    src = joinpath(DATA, "lo-tables.ods")
    # with no edits, every part comes back byte for byte
    p = tmp("same.ods")
    cp(src, p)
    xf = openods(p; mode = "rw")
    saveods(xf)
    for name in ("content.xml", "styles.xml", "settings.xml", "meta.xml")
        @test part(p, name) == part(src, name)
    end
    @test sort(OpenDocumentSpreadsheets.partnames(OpenDocumentSpreadsheets.open_container(p))) == sort(OpenDocumentSpreadsheets.partnames(OpenDocumentSpreadsheets.open_container(src)))
    # edits
    p = tmp("edit.ods")
    cp(src, p)
    openods(p; mode = "rw") do xf
        t = xf["Table"]
        t["B3"] = 100
        t["C5"] = "filled"
        t["D4"] = missing
        t["J20"] = Date(2025, 1, 1)
        xf["Merged"]["A1"] = "M!"
        setFormula(xf["Formulas"], "F1"; val = "=SUM(Table.B3:B6)")
        addsheet!(xf, "Added")["A1"] = "new"
    end
    r = readods(p)
    @test sheetnames(r) == ["Table", "Names", "Merged", "Hidden", "My sheet", "Formulas", "Added"]
    t = r["Table"]
    @test t["B3"] == 100 && t["C3"] == "a" && t["H3"] == "note" && t["C5"] == "filled" && ismissing(t["D4"])
    @test t["J20"] == Date(2025, 1, 1) && t["B9"] == 7
    @test get_dimension(t) == SheetCore.CellRange("B2:J20")
    m = getcell(r["Merged"], "A1")
    @test m.value == "M!" && m.colspan == 2 && m.rowspan == 2 && r["Merged"]["C1"] == "c1"
    @test getFormula(r["Formulas"], "F1") == "=SUM(Table.B3:B6)" && getFormula(r["Formulas"], "A1") == "=SUM(Table.D4:D10)"
    @test r["Added"]["A1"] == "new" && !isvisible(r["Hidden"])
    @test sort([n.name for n in defined_names(r)]) == ["answer", "greeting", "listnm", "myrange", "onecell"]
    @test isequal(r["Names"]["localr"], Any[10 20; 30 40])
    # untouched sheets and parts are unchanged
    original = readods(src)
    for s in ("Names", "Hidden", "My sheet")
        @test XML.sourcetext(r[s].entry.node) == XML.sourcetext(original[s].entry.node)
    end
    @test part(p, "styles.xml") == part(src, "styles.xml") && part(p, "settings.xml") == part(src, "settings.xml")
    # saving again re-applies the same edits to the original: the same result
    # (xf is gone; reopen and save without edits)
    q = tmp("again.ods"); cp(p, q)
    openods(q; mode = "rw") do xf end
    @test part(q, "content.xml") == part(p, "content.xml")
end

@testset "a patched sheet changes only where edited" begin
    # regression: an edit before untouched rows must not repeat them at the end
    for (ref, v) in (("B3", 100), ("C5", "x"), ("B9", missing), ("F6", true))
        p = tmp("one.ods")
        cp(joinpath(DATA, "lo-tables.ods"), p)
        openods(xf -> (xf["Table"][ref] = v), p; mode = "rw")
        before = readods(joinpath(DATA, "lo-tables.ods"))["Table"]["A1:J30"]
        after = readods(p)["Table"]["A1:J30"]
        cr = SheetCore.CellRef(ref)
        before[row_number(cr), column_number(cr)] = v
        @test isequal(after, before)
    end
end

@testset "patching repeats and tails" begin
    p = tmp("scen.ods")
    cp(joinpath(DATA, "lo-scenarios.ods"), p)
    xf = openods(p; mode = "rw")
    xf["S03c-col-style-allrows"]["B500000"] = 5       # inside a 1048574-row tail
    xf["S02-identical"]["C1"] = "mid"                 # inside a run of 5 equal cells
    xf["S11-far"]["A500000"] = "half"                 # inside 999998 repeated rows
    xf["S08-empty"]["C3"] = 1.5                       # an empty sheet
    xf["S01-gaps"]["Z1"] = "far right"                # beyond the defined columns
    saveods(xf)
    r = readods(p)
    @test r["S03c-col-style-allrows"]["B500000"] == 5 && r["S03c-col-style-allrows"]["A1"] == 1
    @test get_dimension(r["S03c-col-style-allrows"]) == SheetCore.CellRange("A1:B500000")
    @test r["S02-identical"]["A1:E1"] == Any[7 7 "mid" 7 7]
    @test isequal(r["S11-far"]["A499999:A500001"], Any[missing; "half"; missing;;]) && r["S11-far"]["A1000000"] == 1000000
    @test r["S08-empty"]["C3"] == 1.5
    @test r["S01-gaps"]["Z1"] == "far right" && r["S01-gaps"]["E10"] == r["S01-gaps"]["E10"]
    # the same file, flat
    pf = tmp("scen.fods")
    cp(joinpath(DATA, "lo-scenarios.fods"), pf)
    xf = openods(pf; mode = "rw")
    xf["S02-identical"]["C1"] = "mid"
    saveods(xf)
    @test readods(pf)["S02-identical"]["A1:E1"] == Any[7 7 "mid" 7 7]
    @test_throws ODSError writeods(tmp("x.ods"), openods(pf; mode = "rw"))   # no flat → zip yet
    # as a template
    pt = writeods(tmp("t.ots"), openods(joinpath(DATA, "lo-tables.ods"); mode = "rw"))
    @test readods(pt).container.format === :ots
end

@testset "save to an IO, mode \"w\"" begin
    io = IOBuffer(read(joinpath(DATA, "lo-tables.ods")); read = true, write = true)
    xf = openods(io; mode = "rw")
    xf["Names"]["B1"] = 11
    saveods(xf)
    @test readods(IOBuffer(take!(io)))["Names"]["B1"] == 11
    p = tmp("w.ods")
    openods(p; mode = "w") do xf
        xf[1]["A1"] = "fresh"
    end
    @test readods(p)[1]["A1"] == "fresh"
    buf = IOBuffer()
    @test writeods(buf, newods()) === nothing
    @test readods(IOBuffer(take!(buf))) isa ODSFile
    @test readods(writeods(tmp("v13.ods"), newods(); version = "1.3")).version == "1.3"
end

@testset "setFormula and the UI notation (D-025)" begin
    @test ui_to_openformula("=SUM(A1:B2,'My sheet'.C3)") == "of:=SUM([.A1:.B2];['My sheet'.C3])"
    @test ui_to_openformula("=IFS(A1>0,\"pos\",TRUE(),\"neg\")") == "of:=COM.MICROSOFT.IFS([.A1]>0;\"pos\";TRUE();\"neg\")"
    @test ui_to_openformula("=sum(\$A\$1:A\$3)") == "of:=SUM([.\$A\$1:.A\$3])"
    @test ui_to_openformula("=SUM(A:A)+SUM(2:3)+Sheet2.B1") == "of:=SUM([.A:.A])+SUM([.2:.3])+[Sheet2.B1]"
    @test ui_to_openformula("={1,2;3,4}") == "of:={1;2|3;4}"
    @test ui_to_openformula("=LOG10(100)+myname") == "of:=LOG10(100)+myname"
    @test ui_to_openformula("=LET(x,1,x+1)") == "of:=COM.MICROSOFT.LET(_xlpm.x;1;_xlpm.x+1)"
    @test ui_to_openformula("=\"a,b;c\"&A1") == "of:=\"a,b;c\"&[.A1]"
    @test ui_to_openformula("='file:///x.ods'#\$Sheet1.A1") == "of:=['file:///x.ods'#\$Sheet1.A1]"
    @test ui_to_openformula("=#N/A") == "of:=#N/A"
    @test_throws ODSError ui_to_openformula("SUM(1)")
    # LibreOffice's own pairs (experiments 008/010): the UI text converts to what it stored,
    # except names LibreOffice did not know as stored (it kept them lower case) and #REF!
    for f in ("lo-syntax.tsv", "lo-names.tsv", "lo-names2.tsv")
        for row in read_tsv(joinpath(DATA, "formula", f))
            stored, ui = f == "lo-syntax.tsv" ? (row[3], row[4]) : (row[2], row[3])
            startswith(stored, "of:") || continue
            m = match(r"^of:=([^(]*)\(", stored)
            (m !== nothing && any(islowercase, m[1])) && continue
            occursin("#REF!", stored) && continue
            @test ui_to_openformula(ui) == stored
            @test render_ui_formula(_strip_formula_prefix(ui_to_openformula(ui))) == ui
        end
    end
    ws = newods()[1]
    setFormula(ws, "A1"; val = "=1+1")
    @test getFormula(ws, "A1") == "=1+1" && getFormula(ws, "A1"; raw = true) == "of:=1+1"
    setFormula(ws, "B1:B2"; val = "of:=[.A1]*2", raw = true)
    @test getFormula(ws, "B2"; raw = true) == "of:=[.A1]*2"
    setFormula(ws, 3, 1; val = "=A1")
    @test getFormula(ws, "A3") == "=A1"
    @test_throws ODSError setFormula(ws, "A4"; val = "[.A1]", raw = true)
end

@testset "writetable and writetable!" begin
    cols = Any[[1, 2, 3], ["a", "b", missing], [Date(2024, 1, 1), Date(2024, 1, 2), Date(2024, 1, 3)]]
    p = writetable(tmp("t.ods"), cols, ["n", "s", "d"]; sheetname = "data")
    dt = readtable(p, "data")
    @test Tables.columnnames(dt) == [:n, :s, :d] && Tables.getcolumn(dt, :n) == [1, 2, 3]
    @test isequal(Tables.getcolumn(dt, :s), ["a", "b", missing])
    @test_throws ODSError writetable(p, cols, ["n", "s", "d"])            # exists
    writetable(p, cols, ["n", "s", "d"]; overwrite = true, anchor_cell = "C3")
    @test readods(p)[1]["C3"] == "n" && readods(p)[1]["C4"] == 1
    # Tables.jl tables, several sheets
    nt = (x = [1.5, 2.5], y = ["p", "q"])
    p2 = writetable(tmp("t2.ods"), nt; sheetname = "nt")
    @test Tables.getcolumn(readtable(p2, "nt"), :x) == [1.5, 2.5]
    p3 = writetable(tmp("t3.ods"), "A" => nt, :B => (z = [true, false],))
    @test sheetnames(readods(p3)) == ["A", "B"] && Tables.getcolumn(readtable(p3, "B"), :z) == [true, false]
    p4 = writetable(tmp("t4.ods"); S1 = (cols, ["n", "s", "d"]), S2 = (Any[[1]], ["one"]))
    @test sheetnames(readods(p4)) == ["S1", "S2"]
    p5 = writetable(tmp("t5.ods"), [("first", Any[[1, 2]], ["k"]), ("second", Any[["x"]], ["v"])])
    @test sheetnames(readods(p5)) == ["first", "second"]
    @test_throws ODSError writetable(tmp("t6.ods"); S1 = nt)
    @test_throws ODSError writetable(tmp("t7.ods"), Any[[1, 2], [1]], ["a", "b"])
    # writetable! into an opened file
    xf = newods()
    writetable!(xf[1], nt; anchor_cell = SheetCore.CellRef("B2"), write_columnnames = false)
    @test xf[1]["B2:C3"] == Any[1.5 "p"; 2.5 "q"]
    # flat output, streaming
    @test readtable(writetable(tmp("t.fods"), nt), 1) |> dt -> Tables.getcolumn(dt, :y) == ["p", "q"]
    ps = writetable(tmp("ts.ods"), nt; streaming = true, sheetname = "s")
    @test Tables.getcolumn(readtable(ps, "s"), :x) == [1.5, 2.5]
    @test_throws ODSError writetable(tmp("tx.ods"), nt; streaming = true, anchor_cell = "B2")
end

@testset "streamods" begin
    p = streamods(tmp("s.ods")) do s
        sh = addsheet!(s, "one"; columns = ["n", "sq", "when"])
        for n in 1:1000
            writerow!(sh, (n, n^2, Date(2024, 1, 1) + Day(n)))
        end
        writerow!(sh, [missing, "gap", nothing])
        sh2 = addsheet!(s, "two", (a = [1, 2], b = ["x", "y"]))
        writerows!(sh2, (a = [3], b = ["z"]))
        @test_throws ODSError writerow!(sh, (1,))              # closed
        @test_throws ODSError addsheet!(s, "ONE")              # name taken
        @test_throws ODSError writerow!(sh2, 5)
    end
    r = readods(p)
    @test sheetnames(r) == ["one", "two"]
    @test r["one"]["A1:C1"] == Any["n" "sq" "when"] && r["one"]["B1001"] == 1000^2 && r["one"]["C2"] == Date(2024, 1, 2)
    @test isequal(r["one"]["A1002:C1002"], Any[missing "gap" missing])
    @test Tables.getcolumn(readtable(p, "two"), :a) == [1, 2, 3]
    # nothing added: one empty sheet
    p2 = streamods(s -> nothing, tmp("e.ods"))
    @test sheetnames(readods(p2)) == ["Sheet1"]
    @test_throws ODSError streamods(s -> nothing, tmp("e.fods"))
    buf = IOBuffer()
    streamods(s -> writerow!(addsheet!(s), (1, 2)), buf)
    @test readods(IOBuffer(take!(buf)))[1]["B1"] == 2
end

@testset "content.xml written into the zip as it is made (D-048)" begin
    C = OpenDocumentSpreadsheets._ChunkedIO
    # the chunked writer: small writes gathered, large ones straight through, all in order
    dest = IOBuffer()
    c = C(dest; limit = 16)
    write(c, "abc"); write(c, 'é'); write(c, 0x21); print(c, 42)
    @test position(dest) == 0                                   # still gathered
    write(c, "0123456789abcdef")                                # a chunk or more: through
    write(c, SubString("xyz-tail", 1, 3)); write(c, view(Vector{UInt8}("0123456789"), 1:10))
    OpenDocumentSpreadsheets._flush!(c)
    @test String(take!(dest)) == "abcé!420123456789abcdefxyz0123456789"
    @test OpenDocumentSpreadsheets._flush!(c) === nothing                       # nothing left: nothing written
    # a content.xml of several chunks: the same bytes, and the same zip, as from a String
    n = 30_000
    xf = newods()
    writetable!(xf[1], Any[collect(1:n), [i / 3 for i in 1:n], ["t&<$i>" for i in 1:n], [Date(2024, 1, 1) + Day(i % 400) for i in 1:n]],
                ["a", "b", "c", "d"])
    io = IOBuffer(); OpenDocumentSpreadsheets._write_chunked(x -> OpenDocumentSpreadsheets.write_new_content(x, xf, "1.4"), io)
    s = String(take!(io))
    @test ncodeunits(s) > 3 * 2^20
    @test OpenDocumentSpreadsheets.package_bytes([OpenDocumentSpreadsheets.PackagePart("content.xml", s)]) ==
          OpenDocumentSpreadsheets.package_bytes([OpenDocumentSpreadsheets.PackagePart("content.xml", x -> OpenDocumentSpreadsheets.write_new_content(x, xf, "1.4"))])
    p = writeods(tmp("big.ods"), xf)
    @test readtable(p, 1).data[3][n] == "t&<$n>"
    # a patched save of it: the edit and the untouched rows around it
    rw = openods(p; mode = "rw")
    rw[1]["B2"] = -1.0; rw[1]["C$(n + 1)"] = "last"
    q = writeods(tmp("big2.ods"), rw)
    t = readtable(q, 1).data
    @test t[2][1] == -1.0 && t[3][n] == "last" && t[3][n-1] == "t&<$(n - 1)>" && t[1][n] == n
    # flat files are written the same way
    f = writeods(tmp("big.fods"), xf)
    @test isequal(readtable(f, 1).data, readtable(p, 1).data)
    # writing doesn't hold the document: far less is allocated than content.xml's size (it
    # was more than twice that). Short values in wide rows, so that what's measured is the
    # document, not the writer's per-row and long-float costs.
    wide = newods()
    writetable!(wide[1], Any[collect(j:j+9_999) for j in 1:20], ["c$j" for j in 1:20])
    io = IOBuffer(); OpenDocumentSpreadsheets._write_chunked(x -> OpenDocumentSpreadsheets.write_new_content(x, wide, "1.4"), io)
    size = position(io)
    writeods(tmp("warm.ods"), wide)
    @test (@allocated writeods(tmp("big3.ods"), wide)) < size ÷ 4
end

@testset "LibreOffice opens what we write" begin
    if isempty(SOFFICE) || !isfile(SOFFICE)
        @info "LibreOffice not found; skipping the write oracle (set ODS_SOFFICE)"
        @test_skip false
    else
        dir = mktempdir()
        profile = lo_profile_url(joinpath(dir, "lo-profile"))
        # a new file: values, typed styles, formulas computed by LibreOffice
        xf = newods("Data")
        ws = xf["Data"]
        ws["A1"] = 7; ws["B1"] = 0.5; ws["C1"] = Date(2024, 3, 5); ws["D1"] = DateTime(2024, 3, 5, 13, 45, 30)
        ws["E1"] = Time(1, 2, 3); ws["F1"] = Hour(36); ws["G1"] = true; ws["H1"] = "a  b"
        setFormula(ws, "A2"; val = "=SUM(A1:B1)*2")
        setFormula(ws, "B2"; val = "=IFS(A1>5,\"big\",TRUE(),\"small\")")
        setFormula(ws, "C2"; val = "=C1+1")
        new = writeods(joinpath(dir, "new.ods"), xf)
        # a patched file
        pat = joinpath(dir, "patched.ods")
        cp(joinpath(DATA, "lo-tables.ods"), pat)
        openods(pat; mode = "rw") do xf
            xf["Table"]["B3"] = 100
            setFormula(xf["Formulas"], "F1"; val = "=SUM(Table.B3:B6)")
        end
        for f in (new, pat)
            run(pipeline(`$SOFFICE -env:UserInstallation=$profile --headless --norestore --convert-to ods --outdir $(joinpath(dir, "lo")) $f`;
                         stdout = devnull, stderr = devnull))
        end
        r = readods(joinpath(dir, "lo", "new.ods"))["Data"]       # LibreOffice's re-save
        @test r["A1"] == 7 && r["B1"] == 0.5 && r["C1"] == Date(2024, 3, 5) && r["D1"] == DateTime(2024, 3, 5, 13, 45, 30)
        @test r["E1"] == Time(1, 2, 3) && r["F1"] == Dates.canonicalize(Day(1) + Hour(12)) && r["G1"] === true && r["H1"] == "a  b"
        @test r["A2"] == 15 && r["B2"] == "big" && r["C2"] == Date(2024, 3, 6)
        @test getFormula(r, "B2") == "=IFS(A1>5,\"big\",TRUE(),\"small\")"
        p = readods(joinpath(dir, "lo", "patched.ods"))
        @test p["Table"]["B3"] == 100 && p["Formulas"]["F1"] == 109 && p["Formulas"]["A1"] == 23.75
        @test sheetnames(p) == ["Table", "Names", "Merged", "Hidden", "My sheet", "Formulas"]
    end
end

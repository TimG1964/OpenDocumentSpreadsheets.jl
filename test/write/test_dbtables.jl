# Tables (phase 6 step 7, D-077): LibreOffice's database ranges (F-062, F-070), with XLSX.jl's table
# API. Fixtures: experiment 033 (test/data/dbranges: LibreOffice's import of XLSX.jl's tables, its own
# named and anonymous ranges) and experiment 035 (lo-tables-own.fods: a range without a header, and
# LibreOffice's save of structured references).
using Dates
import Tables, ZipArchives
const O_T = OpenDocumentSpreadsheets
using OpenDocumentSpreadsheets: ODSError, Table, tables, table
const DBD = joinpath(@__DIR__, "..", "data", "dbranges")
_dbd(f) = joinpath(DBD, f)
_tpath(xf, ext = "fods") = writeods(joinpath(mktempdir(), "t." * ext), xf)
_dbx(s) = (i = findfirst("<table:database-ranges", s); i === nothing ? "" : s[first(i):last(findnext("</table:database-ranges>", s, last(i)))])

# A sheet with a small table's cells: Name, Num, When in A1:C5.
function _tsheet(xf = newods("T"))
    ws = xf[1]
    ws[1, :] = ["Name", "Num", "When"]
    for i in 2:5
        ws[i, :] = ["n$i", i * 10, Date(2026, 1, i)]
    end
    return xf, ws
end

@testset "LibreOffice's tables, read" begin
    imp = readods(_dbd("lo-dbranges-xlsx-import.fods"))
    @test [t.name for t in tables(imp)] == ["Fruit", "Grow", "Scores", "Table1"]          # anonymous ranges aren't tables
    @test [t.id for t in tables(imp)] == 1:4
    f = table(imp, "Fruit")
    @test f.ref == O_T.CellRange("A1:D13") && f.columns == ["Name", "Num", "When", "Flag"] && f.sheet === imp["Tables"]
    @test f.has_header_row && !f.has_totals_row && f.style === nothing && f.filterButtons
    s = table(imp["Tables"], "scores")                                    # names ignore case
    @test s.has_totals_row && s.ref == O_T.CellRange("F1:G6")
    @test O_T.gettotals(s) == (Id = (setting = :label, formula = nothing, value = "Total"),
                               Score = (setting = :sum, formula = "=SUBTOTAL(109,\$Tables.\$G\$2:\$G\$5)", value = 100))
    @test O_T.gettable(s).column_labels == [:Id, :Score] && length(O_T.gettable(s).data[1]) == 4
    @test table(imp, 2).name == "Grow" && table(imp["Tables"], 3).name == "Scores"
    @test_throws KeyError table(imp, "Nope")
    @test_throws KeyError table(imp, 9)
    @test isempty(tables(imp["F01"]))
    own = readods(_dbd("lo-dbranges-own.fods"))
    @test [t.name for t in tables(own)] == ["MyRange"] && table(own, "MyRange").sheet === own["Own2"]
    lo = readods(_dbd("lo-tables-own.fods"))
    @test [t.name for t in tables(lo)] == ["NoHdr", "One"]
    n = table(lo, "NoHdr")
    @test !n.has_header_row && n.columns == ["Column F", "Column G"] && !n.filterButtons
    @test O_T.gettablerange(n) == O_T.SheetCellRange("T", O_T.CellRange("F1:G3"))
    @test O_T.gettable(n).data[1] == ["P", 1, 3]                          # no header: its first row is data
    @test O_T.getFormula(lo["T"], "E2"; raw = true) == "of:=SUBTOTAL(109;[\$T.\$B\$2:.\$B\$5])"   # LibreOffice's save of One[Num]
    # read-only files and the cache off
    @test [t.name for t in tables(openods(_dbd("lo-dbranges-xlsx-import.fods"); enable_cache = false))] == ["Fruit", "Grow", "Scores", "Table1"]
end

@testset "addtable!" begin
    xf, ws = _tsheet()
    t = O_T.addtable!(ws, "A1:C5"; name = "One")
    @test t isa Table && t.name == "One" && t.id == 1 && t.ref == O_T.CellRange("A1:C5") && t.columns == ["Name", "Num", "When"]
    @test t.has_header_row && !t.has_totals_row && t.filterButtons && t.style === nothing
    @test sprint(show, t) == "4x3 Table (id=1, \"One\", A1:C5)"
    @test occursin("columns : Name, Num, When", sprint(show, MIME("text/plain"), t))
    @test O_T.addtable!(ws, "A1:C5").name == "Table1"                       # overlapping, as LibreOffice allows
    @test O_T.addtable!(ws, "E1:F1"; name = "Hdr", has_header_row = false).columns == ["Column E", "Column F"]   # one row
    ws["H1"] = "h"
    @test O_T.addtable!(ws, "H1"; name = "Alone").ref == O_T.CellRange("H1:H1")                # its header alone
    # names: LibreOffice's, unique ignoring case, apart from defined names (F-070)
    @test_throws ODSError O_T.addtable!(ws, "A1:C5"; name = "one")
    @test_throws ODSError O_T.addtable!(ws, "A1:C5"; name = "My Table")
    @test_throws ODSError O_T.addtable!(ws, "A1:C5"; name = "T1")
    @test_throws ODSError O_T.addtable!(ws, "A1:C5"; name = "R1C1")
    @test_throws ODSError O_T.addtable!(ws, "A1:C5"; name = "1abc")
    @test_throws ODSError O_T.addtable!(ws, "A1:C5"; name = "__Anonymous_Sheet_DB__5")
    O_T.addDefinedName(xf, "NR", "T.A1")
    @test O_T.addtable!(ws, "A1:C5"; name = "NR").name == "NR"
    # headers, as XLSX.jl checks them
    ws["J1"] = "a"; ws["K1"] = "A"; ws["J2"] = 1
    @test_throws ODSError O_T.addtable!(ws, "J1:K2")                        # repeated, ignoring case
    @test_throws ODSError O_T.addtable!(ws, "J1:L2")                        # L1 empty
    @test O_T.addtable!(ws, "J1:L2"; has_header_row = false).columns == ["Column J", "Column K", "Column L"]
    @test_throws ODSError O_T.addtable!(ws, "A1:C5"; style = "TableStyleMedium2")
    @test O_T.addtable!(ws, "A1:C5"; style = "None", name = "Styled").style === nothing
    @test_throws ODSError O_T.addtable!(ws, "A1"; has_totals_row = true)    # header and totals in one row
    @test_throws ODSError O_T.addtable!(ws, "nonsense")
    @test_throws ODSError O_T.addtable!(readods(_dbd("lo-tables-own.fods"))["T"], "A1:C5")   # read-only
    # stored as LibreOffice stores them
    x = _dbx(read(_tpath(xf), String))
    @test occursin("<table:database-range table:name=\"One\" table:target-range-address=\"T.A1:T.C5\" table:display-filter-buttons=\"true\"/>", x)
    @test occursin("<table:database-range table:name=\"Hdr\" table:target-range-address=\"T.E1:T.F1\" table:contains-header=\"false\" table:display-filter-buttons=\"true\"/>", x)
    xf2, ws2 = _tsheet()
    O_T.addtable!(ws2, "A1:C5"; name = "Q", filterButtons = false, has_totals_row = true)
    x = _dbx(read(_tpath(xf2), String))
    @test occursin("<table:database-range table:name=\"Q\" table:target-range-address=\"T.A1:T.C5\" calcext:contains-footer=\"true\"/>", x)
    r = readods(_tpath(xf2))
    q = table(r, "Q")
    @test q.has_totals_row && !q.filterButtons && O_T.gettable(q).data[1] == ["n2", "n3", "n4"]
    # a sheet name that needs quotes
    xf3 = newods("My Data"); xf3[1]["A1"] = "a"; xf3[1]["A2"] = 1
    O_T.addtable!(xf3[1], "A1:A2"; name = "Qx")
    @test occursin("table:target-range-address=\"'My Data'.A1:'My Data'.A2\"", read(_tpath(xf3), String))
    @test table(readods(_tpath(xf3)), "Qx").sheet.name == "My Data"
end

@testset "deletetable!" begin
    xf, ws = _tsheet()
    O_T.addtable!(ws, "A1:C5"; name = "One"); O_T.addtable!(ws, "A1:B5"; name = "Two"); O_T.addtable!(ws, "B1:C5"; name = "Three")
    @test O_T.deletetable!(ws, "two") === nothing
    @test [t.name for t in tables(ws)] == ["One", "Three"] && ws["B3"] == 30         # the cells stay
    O_T.deletetable!(ws, 2)
    O_T.deletetable!(table(ws, "One"))
    @test isempty(tables(xf)) && _dbx(read(_tpath(xf), String)) == ""
    @test_throws KeyError O_T.deletetable!(ws, "One")
    # the file's: removed with its line, the others kept as they were (D-023)
    p = openods(_dbd("lo-dbranges-xlsx-import.fods"); mode = "rw")
    before = _dbx(p.content)
    O_T.deletetable!(p["Tables"], "Grow")
    s = read(_tpath(p), String)
    @test _dbx(s) == replace(before, r"\r?\n\s*<table:database-range table:name=\"Grow\"[^>]*/>" => "")   # CRLF in a Windows checkout
    r = readods(IOBuffer(s))
    @test [t.name for t in tables(r)] == ["Fruit", "Scores", "Table1"] && r["Tables"]["I2"] == "a"
    # totals' formulas are already ranges: unchanged
    p = openods(_dbd("lo-dbranges-xlsx-import.fods"); mode = "rw")
    f = O_T.getFormula(p["Tables"], "G6")
    O_T.deletetable!(p["Tables"], "Scores")
    @test O_T.getFormula(p["Tables"], "G6") == f
end

@testset "settotals!, gettotals, deletetotals!" begin
    xf, ws = _tsheet()
    t = O_T.addtable!(ws, "A1:C5"; name = "Sales")
    @test O_T.gettotals(t) == NamedTuple()
    t2 = O_T.settotals!(t, "Name" => "Total", "Num" => :sum)
    @test t2.has_totals_row && t2.ref == O_T.CellRange("A1:C6")             # the row after the table
    @test O_T.getFormula(ws, "B6") == "=SUBTOTAL(109,\$T.\$B\$2:\$B\$5)"
    @test O_T.getFormula(ws, "B6"; raw = true) == "of:=SUBTOTAL(109;[\$T.\$B\$2:.\$B\$5])"   # as LibreOffice's import writes it
    @test ws["A6"] == "Total"
    tot = O_T.gettotals(t)                                                     # t was before: looked up again
    @test keys(tot) == (:Name, :Num, :When)
    @test tot.Name == (setting = :label, formula = nothing, value = "Total")
    @test tot.Num.setting === :sum && tot.When.setting === :none
    for (f, code) in pairs(O_T.TOTALS_FUNCTIONS)
        O_T.settotals!(ws, "Sales", "Num" => f)
        @test O_T.gettotals(ws, "Sales").Num.setting === f
        @test O_T.getFormula(ws, "B6") == "=SUBTOTAL($code,\$T.\$B\$2:\$B\$5)"
    end
    # custom formulas: structured references to the table become ranges, as LibreOffice saves them (F-070)
    O_T.settotals!(ws, "Sales", "When" => (:custom, "SUBTOTAL(109,Sales[Num])-SUBTOTAL(101,Sales[[#All],[Num]])"))
    @test O_T.getFormula(ws, "C6") == "=SUBTOTAL(109,\$T.\$B\$2:\$B\$5)-SUBTOTAL(101,\$T.\$B\$1:\$B\$6)"
    @test O_T.gettotals(ws, "Sales").When.setting === :custom
    O_T.settotals!(ws, "Sales"; When = (:custom, "=MAX(sales[#Data])"))
    @test O_T.getFormula(ws, "C6") == "=MAX(\$T.\$A\$2:\$C\$5)"
    O_T.settotals!(ws, 1, "When" => (:custom, "SUM(Sales[Num])"))             # by id
    @test O_T.getFormula(ws, "C6") == "=SUM(\$T.\$B\$2:\$B\$5)"
    @test_throws ODSError O_T.settotals!(ws, "Sales", "When" => (:custom, "SUM(Sales[Nope])"))
    @test_throws ODSError O_T.settotals!(ws, "Sales", "Nope" => :sum)
    @test_throws ODSError O_T.settotals!(ws, "Sales", "Num" => :median)
    @test_throws ODSError O_T.settotals!(ws, "Sales", "Num" => (:sum, "x"))
    @test_throws ODSError O_T.settotals!(ws, "Sales", "Num" => 42)
    O_T.settotals!(ws, "Sales", "Name" => :none)                               # the cell cleared, the row kept
    @test ws["A6"] === missing && table(ws, "Sales").has_totals_row && O_T.gettotals(ws, "Sales").Name.setting === :none
    # a totals row needs an empty row after the table
    xf2, ws2 = _tsheet(); ws2["B6"] = 1
    O_T.addtable!(ws2, "A1:C5"; name = "Full")
    @test_throws ODSError O_T.settotals!(ws2, "Full", "Num" => :sum)
    # removed: the cells emptied, the table a row shorter
    t3 = O_T.deletetotals!(ws, "Sales")
    @test !t3.has_totals_row && t3.ref == O_T.CellRange("A1:C5") && ws["B6"] === missing && ws["C6"] === missing
    @test O_T.deletetotals!(t3).ref == t3.ref                                  # nothing to do
    O_T.settotals!(t3, "Num" => :average)
    r = readods(_tpath(xf))
    @test O_T.gettotals(r["T"], "Sales").Num.setting === :average && table(r, "Sales").ref == O_T.CellRange("A1:C6")
    @test occursin("calcext:contains-footer=\"true\"", _dbx(read(_tpath(xf), String)))
end

@testset "appendtable!, gettable, gettablerange" begin
    xf, ws = _tsheet()
    t = O_T.addtable!(ws, "A1:C5"; name = "Sales")
    O_T.settotals!(t, "Name" => "Total", "Num" => :sum, "When" => (:custom, "COUNT(Sales[When])+1"))
    t = O_T.appendtable!(t, [["n6", 60, Date(2026, 1, 6)], ("n7", 70, Date(2026, 1, 7))])
    @test t.ref == O_T.CellRange("A1:C8") && ws["A6"] == "n6" && ws["B7"] == 70
    @test ws["A8"] == "Total" && O_T.getFormula(ws, "B8") == "=SUBTOTAL(109,\$T.\$B\$2:\$B\$7)"
    @test O_T.getFormula(ws, "C8") == "=COUNT(\$T.\$C\$2:\$C\$7)+1"                   # the custom formula reaches the new rows
    t = O_T.appendtable!(ws, "Sales", (Num = [80], When = [Date(2026, 1, 8)], Name = ["n8"]))   # by name
    @test ws["A8"] == "n8" && ws["B8"] == 80 && t.ref == O_T.CellRange("A1:C9")
    t = O_T.appendtable!(ws, 1, ["n9" 90 Date(2026, 1, 9)])                    # a matrix
    @test ws["C9"] == Date(2026, 1, 9) && O_T.getFormula(ws, "B10") == "=SUBTOTAL(109,\$T.\$B\$2:\$B\$9)"
    @test_throws ODSError O_T.appendtable!(t, (Num = [1], Name = ["x"]))
    @test_throws ODSError O_T.appendtable!(t, (Num = [1], Name = ["x"], When = [1], Extra = [2]))
    @test_throws ODSError O_T.appendtable!(t, [[1, 2]])
    @test O_T.appendtable!(t, Vector{Any}[]).ref == t.ref
    ws["B11"] = "below"
    @test_throws ODSError O_T.appendtable!(t, [["x", 1, 2]])
    @test O_T.appendtable!(t, [["x", 1, 2]]; check_empty = false).ref == O_T.CellRange("A1:C11")
    # reading
    t = table(ws, "Sales")
    d = O_T.gettable(t)
    @test d.column_labels == [:Name, :Num, :When] && d.data[2] == [20, 30, 40, 50, 60, 70, 80, 90, 1]
    @test eltype(d.data[2]) == Int64 && eltype(O_T.gettable(t; infer_eltypes = false).data[2]) == Any
    @test O_T.gettable(t; missing_strings = "n3").data[1][2] === missing
    @test Tables.columntable(t).Num == d.data[2]
    @test O_T.gettablerange(t) == O_T.SheetCellRange("T", O_T.CellRange("A2:C10"))
    @test O_T.gettablerange(t, "When") == O_T.SheetCellRange("T", O_T.CellRange("C2:C10"))
    @test O_T.gettablerange(t, 1; header = true) == O_T.SheetCellRef("T", O_T.CellRef("A1"))
    @test O_T.gettablerange(t, "When", "Name") == O_T.SheetCellRange("T", O_T.CellRange("A2:C10"))
    @test_throws ODSError O_T.gettablerange(t, "Nope")
    @test_throws ODSError O_T.gettablerange(t, 4)
    h = O_T.addtable!(ws, "E1:F1"; name = "OnlyHeader", has_header_row = false)
    @test_throws ODSError O_T.gettablerange(table(ws, "OnlyHeader"), 1; header = true)
    ws["H1"] = "h"; O_T.addtable!(ws, "H1"; name = "Bare")
    @test_throws ODSError O_T.gettablerange(table(ws, "Bare"))
    @test O_T.gettable(table(ws, "Bare")).column_labels == [:h] && isempty(O_T.gettable(table(ws, "Bare")).data[1])
end

@testset "tables under inserts, deletes and sheet operations" begin
    for kind in (:new, :file)
        xf, ws = kind === :new ? _tsheet() : (p = openods(_dbd("lo-tables-own.fods"); mode = "rw"); (p, p["T"]))
        kind === :new && (O_T.addtable!(ws, "A1:C5"; name = "One"); O_T.addtable!(ws, "F1:G3"; name = "NoHdr", has_header_row = false))
        O_T.insertRows(ws, 6)                              # just after: unchanged (F-070)
        @test table(ws, "One").ref == O_T.CellRange("A1:C5")
        O_T.insertRows(ws, 3)                              # inside: grows (both)
        @test table(ws, "One").ref == O_T.CellRange("A1:C6") && table(ws, "NoHdr").ref == O_T.CellRange("F1:G4")
        O_T.insertRows(ws, 1)                              # before: moves
        @test table(ws, "One").ref == O_T.CellRange("A2:C7") && table(ws, "NoHdr").ref == O_T.CellRange("F2:G5")
        O_T.deleteRows(ws, 3:4)                            # shrinks
        @test table(ws, "One").ref == O_T.CellRange("A2:C5") && table(ws, "NoHdr").ref == O_T.CellRange("F2:G3")
        O_T.insertColumns(ws, 2)
        @test table(ws, "One").ref == O_T.CellRange("A2:D5") && table(ws, "NoHdr").ref == O_T.CellRange("G2:H3")
        O_T.deleteColumns(ws, "G:H")                       # all its cells: it goes, as in LibreOffice
        @test [t.name for t in tables(ws)] == ["One"]
        r = readods(_tpath(xf))
        @test [(t.name, t.ref) for t in tables(r)] == [("One", O_T.CellRange("A2:D5"))]
        # sheets: renamed, copied (`One_2`, F-047), deleted
        O_T.renamesheet!(ws, "Renamed")
        @test table(xf, "One").sheet.name == "Renamed"
        c = O_T.copysheet!(ws, "Copy")
        @test [(t.name, t.sheet.name) for t in tables(xf)] == [("One", "Renamed"), ("One_2", "Copy")]
        @test table(c, "One_2").ref == table(ws, "One").ref
        r = readods(_tpath(xf))
        @test [(t.name, t.sheet.name, t.ref) for t in tables(r)] == [("One", "Renamed", O_T.CellRange("A2:D5")), ("One_2", "Copy", O_T.CellRange("A2:D5"))]
        O_T.insertRows(c, 2)
        @test table(xf, "One_2").ref == O_T.CellRange("A3:D6") && table(xf, "One").ref == O_T.CellRange("A2:D5")
        O_T.deletesheet!(xf, "Copy")
        @test [t.name for t in tables(xf)] == ["One"]
        @test [t.name for t in tables(readods(_tpath(xf)))] == ["One"]
    end
    # an edited table of the file is written in its place: the order (and ids) stay
    p = openods(_dbd("lo-dbranges-xlsx-import.fods"); mode = "rw")
    O_T.appendtable!(p["Tables"], "Grow", [[9, 9]])
    @test [t.name for t in tables(p)] == [t.name for t in tables(readods(_tpath(p)))] == ["Fruit", "Grow", "Scores", "Table1"]
    @test table(readods(_tpath(p)), "Grow").ref == O_T.CellRange("I1:J5")
    # nothing changed: the file's element as it was
    p = openods(_dbd("lo-dbranges-xlsx-import.fods"); mode = "rw")
    before = _dbx(p.content)
    p["Tables"]["Z1"] = 1
    tables(p)
    @test _dbx(read(_tpath(p), String)) == before
end

@testset "writetable and readtable with tables" begin
    dir = mktempdir()
    cols = Any[[1, 2, 3], ["a", "b", "c"]]; nm = ["id", "name"]
    f = writetable(joinpath(dir, "a.ods"), cols, nm; as_table = true, table_name = "Res", totals = ["id" => :sum, "name" => "Total"],
                   freeze_header = true, sheetname = "Data")
    r = readods(f)
    t = table(r, "Res")
    @test t.ref == O_T.CellRange("A1:B5") && t.has_totals_row && O_T.gettotals(t).id.setting === :sum
    settings = ZipArchives.zip_readentry(ZipArchives.ZipReader(read(f)), "settings.xml", String)
    @test occursin(r"VerticalSplitMode\"[^>]*>2<", settings)                    # frozen
    d = readtable(f; table_name = "Res")
    @test d.column_labels == [:id, :name] && d.data[1] == [1, 2, 3]
    @test readtable(f, "Data"; table_name = "res", normalizenames = true).column_labels == [:id, :name]
    @test readtable(f, 1; table_name = "Res", missing_strings = "b").data[2][2] === missing
    @test_throws ODSError readtable(f, 1, "A:B"; table_name = "Res")
    @test_throws KeyError readtable(f; table_name = "Nope")
    @test readto(f, Tables.columntable; table_name = "Res").id == [1, 2, 3]
    # several sheets: tables named after them
    f = writetable(joinpath(dir, "b.ods"); as_table = true, A_1 = (cols, nm), B = (cols, nm))
    @test [(t.name, t.sheet.name) for t in tables(readods(f))] == [("A_1", "A_1"), ("B", "B")]
    f = (@test_logs (:warn, r"normalized name `My_Sheet`") writetable(joinpath(dir, "c.ods"), "My Sheet" => (x = [1, 2], y = [3, 4]); as_table = true))
    @test table(readods(f), 1).name == "My_Sheet"
    # streamed
    f = writetable(joinpath(dir, "d.ods"), "First" => (x = [1, 2], y = [3, 4]), "Second" => (x = [5], y = [6]); as_table = true, streaming = true)
    r = readods(f)
    @test [(t.name, t.ref) for t in tables(r)] == [("First", O_T.CellRange("A1:B3")), ("Second", O_T.CellRange("A1:B2"))]
    @test O_T.gettable(table(r, "Second")).data[2] == [6]
    f = writetable(joinpath(dir, "e.ods"), cols, nm; as_table = true, streaming = true, table_name = "St")
    @test table(readods(f), "St").ref == O_T.CellRange("A1:B4")
    f = streamods(joinpath(dir, "f.ods")) do s
        sh = O_T.addsheet!(s, "Q"; columns = ["a", "b"], as_table = true)
        writerow!(sh, [1, 2])
        @test_throws ODSError O_T.addsheet!(s, "R"; columns = ["a"], as_table = true, table_name = "table1")
        O_T.addsheet!(s, "R"; columns = ["a"], as_table = true)
    end
    @test [(t.name, t.ref) for t in tables(readods(f))] == [("Table1", O_T.CellRange("A1:B2")), ("Table2", O_T.CellRange("A1:A1"))]
    @test_throws ODSError writetable(joinpath(dir, "g.ods"), cols, nm; as_table = true, streaming = true, totals = ["id" => :sum])
    @test_throws ODSError writetable(joinpath(dir, "g.ods"), cols, nm; streaming = true, freeze_header = true)
    @test_throws ODSError writetable(joinpath(dir, "g.ods"), cols, nm; as_table = true, table_style = "TableStyleMedium2")
    @test_throws ODSError writetable(joinpath(dir, "g.ods"), cols, nm; totals = ["id" => :sum])
    @test !isfile(joinpath(dir, "g.ods"))
    # writetable! into a sheet
    xf = newods("W")
    writetable!(xf[1], cols, nm; anchor_cell = "C3", as_table = true, table_name = "In")
    @test table(xf, "In").ref == O_T.CellRange("C3:D6")
    @test_throws ODSError writetable!(xf[1], cols, nm; anchor_cell = "F3", as_table = true, table_name = "in")   # in use: nothing written
    @test xf[1]["F3"] === missing
    @test_throws ODSError writetable!(xf[1], cols, nm; as_table = true, write_columnnames = false)
end

@testset "LibreOffice reads the tables" begin
    if isempty(SOFFICE) || !isfile(SOFFICE)
        @info "LibreOffice not found; skipping the tables oracle (set ODS_SOFFICE)"
        @test_skip false
    else
        dir = mktempdir()
        profile = lo_profile_url(joinpath(dir, "lo-profile"))
        xf, ws = _tsheet()
        t = O_T.addtable!(ws, "A1:C5"; name = "Sales")
        O_T.settotals!(t, "Name" => "Total", "Num" => :sum, "When" => (:custom, "COUNT(Sales[When])"))
        O_T.appendtable!(table(ws, "Sales"), [["n6", 60, Date(2026, 1, 6)]])
        O_T.addtable!(ws, "F1:G2"; name = "Bare", has_header_row = false, filterButtons = false)
        a = writeods(joinpath(dir, "new.ods"), xf)
        b = writeods(joinpath(dir, "newflat.fods"), xf)
        p = openods(_dbd("lo-dbranges-xlsx-import.fods"); mode = "rw")
        O_T.deletetable!(p["Tables"], "Fruit")
        O_T.appendtable!(p["Tables"], "Scores", [[5, 50]])
        O_T.addtable!(p["Plain"], "A1:D13"; name = "Mine")
        c = writeods(joinpath(dir, "own.fods"), p)
        d = writetable(joinpath(dir, "stream.ods"), "S" => (x = [1, 2], y = [3, 4]); as_table = true, streaming = true)
        run(pipeline(`$SOFFICE -env:UserInstallation=$profile --headless --norestore --convert-to fods --outdir $(joinpath(dir, "lo")) $a $b $c $d`;
                     stdout = devnull, stderr = devnull))
        # LibreOffice writes its ranges sorted by name
        seen(x) = sort!([(t.name, t.sheet.name, t.ref, t.has_header_row, t.has_totals_row, t.filterButtons) for t in tables(x)])
        for (f, orig) in (("new.fods", xf), ("newflat.fods", xf), ("own.fods", p))
            lo = readods(joinpath(dir, "lo", f))
            @test seen(lo) == seen(orig)
        end
        lo = readods(joinpath(dir, "lo", "new.fods"))
        tot = O_T.gettotals(lo["T"], "Sales")
        @test tot.Num.setting === :sum && tot.Num.value == 200 && tot.When.value == 5 && tot.Name.value == "Total"   # LibreOffice computed them
        @test O_T.gettotals(readods(joinpath(dir, "lo", "own.fods"))["Tables"], "Scores").Score.value == 150
        @test seen(readods(joinpath(dir, "lo", "stream.fods"))) == [("S", "S", O_T.CellRange("A1:B3"), true, false, true)]
    end
end

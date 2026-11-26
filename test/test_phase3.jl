# Phase 3 (speed): the lazy sheet index, reading content.xml only up to one sheet, the fast
# number parser (Parsers.jl), numbers written without allocating (SheetCore, from XLSX.jl), and `display_text=false` (D-029).

using Dates
import Tables
using OpenDocumentSpreadsheets: _parse_float, content_through_sheet, open_container, read_xml, ODSError

@testset "lazy sheet index" begin
    xf = readods(joinpath(DATA, "lo-tables.ods"))
    @test length(xf.sheets) == 0 && !xf.scanner.done          # nothing indexed at open
    @test xf[1].name == "Table"
    @test length(xf.sheets) == 1                               # only as far as needed
    @test xf["Merged"]["A1"] == "m"
    @test length(xf.sheets) == 3
    @test xf["Table.B3"] == 1 && length(xf.sheets) == 3        # a reference doesn't index the rest
    @test xf["Table"]["B3"] == 1
    @test sheetcount(xf) == 6 && xf.scanner.done
    # workbook names come after the sheets: asking for one indexes everything
    xf = readods(joinpath(DATA, "lo-tables.ods"))
    @test xf["onecell"] == 10 && xf.scanner.done
    # a name without regard to case still works (needs every name)
    xf = readods(joinpath(DATA, "lo-tables.ods"))
    @test xf["my SHEET"].name == "My sheet" && xf.scanner.done
    @test_throws ODSError readods(joinpath(DATA, "lo-tables.ods"))[9]
end

@testset "content up to one sheet" begin
    c = open_container(read(joinpath(DATA, "lo-tables.ods")))
    full = read_xml(c, :content)
    for (s, last) in ((1, "Table"), ("Table", "Table"), ("Names", "Names"), (3, "Merged"), ("My sheet", "My sheet"))
        pre = content_through_sheet(c, s)
        @test startswith(full, pre) && endswith(pre, "</table:table>") && ncodeunits(pre) < ncodeunits(full)
        @test occursin("table:name=\"$last\"", pre)
    end
    # not found by its exact name (or not at all): the whole part
    @test content_through_sheet(c, "TABLE") == full
    @test content_through_sheet(c, "Nope") == full
    @test content_through_sheet(c, 99) == full
    # a flat document is whole anyway
    cf = open_container(read(joinpath(DATA, "lo-tables.fods")))
    @test content_through_sheet(cf, 1) == cf.flat
    # one-shot reads use it and give the same results
    p = joinpath(DATA, "lo-tables.ods")
    @test isequal(readtable(p, "Table").data, gettable(readods(p)["Table"]).data)
    @test readdata(p, "Names", "C2") == 40 && readdata(p, "Names.B1") == 10 && readdata(p, 2, "B1") == 10
    @test isequal(readdata(p, "Names", "localr"), Any[10 20; 30 40])          # a sheet-local name
    @test readdata(p, "Table", "onecell") == 10                               # a workbook name
    @test readdata(p, "onecell") == 10
end

@testset "number parsing (Parsers.jl)" begin
    # the same correctly rounded values as Base, on LibreOffice's forms and Julia's
    for s in ("0", "-0", "7", "7.0", "0.1", "1E-020", "1.23456789012346E+017", "3.14159265358979",
              ".5", "5.", "1e5", "-2.5e-3", "123456789012345", "0.000123456789", "1.5E+300",
              "0.30000000000000004", "12345678901234567890", "5e-324", "1.7976931348623157e308")
        @test _parse_float(s) === parse(Float64, s)
    end
    @test _parse_float(" 2.5 ") === 2.5
    @test _parse_float("junk") === 0.0 && _parse_float("") === 0.0
    for x in (0.1, 7.0, -0.0, 1e-20, 1.5e300, 0.30000000000000004, 123456.789, 5e-324, floatmax(Float64))
        @test sprint(SheetCore.write_float, zeros(UInt8, 64), x) == string(x)
        @test _parse_float(string(x)) === x
    end
end

@testset "display_text=false (D-029)" begin
    data = Any[[1, 2], [0.5, 1.5], [Date(2024, 1, 1), Date(2024, 1, 2)], [true, false], ["a", "b"], [Time(1), Time(2)]]
    names = ["i", "f", "d", "b", "s", "t"]
    dir = mktempdir()
    for streaming in (false, true), ext in (streaming ? ("ods",) : ("ods", "fods"))
        p = writetable(joinpath(dir, "t$(streaming).$ext"), data, names; display_text = false, streaming, overwrite = true)
        r = readtable(p, 1)
        @test isequal(r.data, readtable(writetable(joinpath(dir, "k.$ext"), data, names; overwrite = true), 1).data)
        xml = ext == "ods" ? String(OpenDocumentSpreadsheets.read_bytes(open_container(read(p)), "content.xml")) : read(p, String)
        @test !occursin("<text:p>0.5</text:p>", xml) && occursin("<text:p>a</text:p>", xml)   # text cells keep theirs
    end
    # writeods, and a patched file
    xf = newods(); xf[1]["A1"] = 2.5
    p = writeods(joinpath(dir, "n.ods"), xf; display_text = false)
    @test readods(p)[1]["A1"] == 2.5
    q = joinpath(dir, "p.ods"); cp(joinpath(DATA, "lo-tables.ods"), q)
    xf = openods(q; mode = "rw"); xf["Table"]["B3"] = 99
    writeods(q, xf; overwrite = true, display_text = false)
    @test readods(q)["Table"]["B3"] == 99 && readods(q)["Table"]["B4"] == 2
    if !isempty(SOFFICE) && isfile(SOFFICE)
        # LibreOffice shows values written without display text
        out = joinpath(dir, "lo")
        profile = lo_profile_url(joinpath(dir, "lo-profile"))
        src = joinpath(dir, "tfalse.ods")
        run(pipeline(`$SOFFICE -env:UserInstallation=$profile --headless --norestore --convert-to csv --outdir $out $src`;
                     stdout = devnull, stderr = devnull))
        csv = read(joinpath(out, "tfalse.csv"), String)
        @test occursin("1,0.5,", csv) && occursin("TRUE", csv) && occursin("a", csv)
    else
        @test_skip false
    end
end

@testset "SheetCore.write_float and write_integer (from XLSX.jl)" begin
    buf = zeros(UInt8, 64)
    for x in (0.0, -0.0, 1.0, -2.5, 1e-4, 9.99e-5, 123456.0, 1e6, 1.5e14, 1e15, 0.1 + 0.2, Float64(pi), 1e300, -1e-300,
              5e-324, floatmax(Float64), 1001.123456, 12345.6789012345, NaN, Inf, -Inf)
        @test sprint(SheetCore.write_float, buf, x) == string(x)
    end
    for n in (0, 7, -7, 2024, typemax(Int64), typemin(Int64))
        @test sprint(SheetCore.write_integer, buf, n) == string(n)
    end
    @test sprint((io, b, n) -> SheetCore.write_integer(io, b, n; mindigits = 4), buf, 7) == "0007"
    @test sprint((io, b, n) -> SheetCore.write_integer(io, b, n; mindigits = 2), buf, 123) == "123"
end

# Number formats and displayed text.
#
# The first two test sets are ported from XLSX.jl 0.13.4 test/test_files/formatting/
# display-text.jl (MIT License, Copyright (c) 2018-2026 Felipe Noronha Tavares and other
# contributors), with their data files test/data/number_formats_excel.tsv and
# number_format_validity_excel.tsv copied unchanged to test/data/core/. The test sets
# that use a workbook (setFormat, getText, built-in formats) belong to a back end and are
# left out. The epoch test sets are new.

using Dates

const CORE_DATA = joinpath(@__DIR__, "..", "data", "core")

function display_fixture_value(kind, v)
    kind == "number" && return parse(Float64, v)
    kind == "date" && return Float64(SheetCore.date_to_excel_value(Date(v), false))
    kind == "datetime" && return SheetCore.datetime_to_excel_value(DateTime(v), false)
    kind == "time" && return SheetCore.time_to_excel_value(Time(v))
    kind == "bool" && return v == "true"
    return String(v)
end

@testset "rendering as Excel does" begin
    # Excel's results that the engine doesn't reproduce: a fill repeats to the column's
    # width, which it has no width for; and two times exactly half-way between
    # hundredths of a second, which Excel's floating-point arithmetic rounds up.
    known = Dict(("* 0", "42") => "42",
                 ("ss.00", "2026-03-07T14:05:09.125") => "09.12",
                 ("ss.00", "2026-03-07T14:05:09.135") => "09.13")
    n = 0
    for line in readlines(joinpath(CORE_DATA, "number_formats_excel.tsv"))
        startswith(line, '#') && continue
        kind, v, fmt, text = split(line, '\t')
        excel = chop(text; head=1, tail=1)
        expected = get(known, (fmt, v), excel)
        got = SheetCore._display_text(display_fixture_value(kind, v), fmt)
        got == expected || @info "differs from Excel" kind v fmt excel got
        @test got == expected
        n += 1
    end
    @test n == 201
end

@testset "rendering as LibreOffice does (F-030)" begin
    # LibreOffice 26.8.3's texts (experiment 012) for the Excel cases and 50 General values.
    # Day numbers count from the ODF epoch. Left out: booleans (Calc shows a boolean under a
    # number format as a number; an ODS boolean cell keeps a boolean format, D-024).
    # This includes the times half-way between tenths or hundredths of a second (F-091).
    n = 0
    for line in readlines(joinpath(CORE_DATA, "number_formats_libreoffice.tsv"))
        startswith(line, '#') && continue
        kind, v, fmt, text = split(line, '\t')
        kind == "bool" && continue
        lo = chop(text; head=1, tail=1)
        x = kind == "string" ? String(v) : parse(Float64, v)       # day numbers, as LibreOffice was given them
        got = SheetCore._display_text(x, fmt; epoch=SheetCore.DEFAULT_NULL_DATE, libreoffice=true)
        got == lo || @info "differs from LibreOffice" kind v fmt lo got
        @test got == lo
        n += 1
    end
    @test n == 248
end

@testset "fractions of a second (F-091)" begin
    # LibreOffice 26.8's texts for these exact doubles (written to a file, exported as shown)
    t1, t2, t3, t4 = 0.5 + 1.23456789/86400, 0.5 + 59.99996/86400, 0.5 + 0.00049/86400, 0.5 + 1.99999949/86400
    lo(x, fmt) = SheetCore._display_text(x, fmt; libreoffice = true)
    for (fmt, want) in [
            "hh:mm:ss.0"         => ("12:00:01.2", "12:00:59.9", "12:00:00.0", "12:00:01.9"),
            "hh:mm:ss.000"       => ("12:00:01.235", "12:00:59.999", "12:00:00.000", "12:00:01.999"),
            "hh:mm:ss.0000"      => ("12:00:01.2346", "12:00:59.9999", "12:00:00.0005", "12:00:01.9999"),
            "hh:mm:ss.00000"     => ("12:00:01.23457", "12:00:59.99996", "12:00:00.00049", "12:00:01.99999"),
            "hh:mm:ss.000000"    => ("12:00:01.234568", "12:00:59.999960", "12:00:00.000490", "12:00:01.999999"),
            "hh:mm:ss.000000000" => ("12:00:01.234567890", "12:00:59.999960000", "12:00:00.000490000", "12:00:01.999999490"),
            "hh:mm:ss"           => ("12:00:01", "12:00:59", "12:00:00", "12:00:01"),
            "[ss]"               => ("43201", "43260", "43200", "43202"),     # elapsed: rounded, carried
            "[ss].0000"          => ("43201.2346", "43260.0000", "43200.0005", "43202.0000"),
            "[mm]:ss.0000"       => ("720:01.2346", "721:00.0000", "720:00.0005", "720:02.0000")]
        @test lo.((t1, t2, t3, t4), fmt) == want
    end
    @test lo(1.5 + 59.9996/86400, "[hh]:mm:ss.000000") == "36:00:59.999600"
    # Excel shows at most 3 digits; any more are zeros
    @test SheetCore._display_text(t1, "hh:mm:ss.00000") == "12:00:01.23500"
end

@testset "format codes Excel accepts" begin
    n = 0
    for line in readlines(joinpath(CORE_DATA, "number_format_validity_excel.tsv"))
        startswith(line, '#') && continue
        verdict, code = split(line, '\t'; limit=2)
        @test SheetCore.is_valid_format(code) == (verdict == "accepts")
        n += 1
    end
    @test n > 50
end

@testset "dates counted from an epoch (ODF null-date)" begin
    epoch = SheetCore.DEFAULT_NULL_DATE
    @test epoch == Date(1899, 12, 30)
    # from 1900-03-01 on, the epoch count equals Excel's 1900 system
    for d in (Date(1900, 3, 1), Date(1970, 1, 1), Date(2026, 11, 18), Date(9999, 12, 31))
        @test SheetCore.date_to_serial(d) == SheetCore.date_to_excel_value(d, false)
        @test SheetCore.serial_to_date(SheetCore.date_to_serial(d)) == d
    end
    @test SheetCore.date_to_serial(Date(2026, 11, 18)) == 46344
    # before it, Excel's leap-year bug makes them differ; the epoch count does not have it
    @test SheetCore.date_to_serial(Date(1900, 2, 28)) == 60
    # XLSX.jl's conversion (kept as is) also gives 60, though Excel itself numbers this day
    # 59: it counts a 1900-02-29 that never was. Recorded in core-migration.md.
    @test SheetCore.date_to_excel_value(Date(1900, 2, 28), false) == 60
    @test SheetCore.serial_to_date(-1) == Date(1899, 12, 29)
    @test SheetCore.date_to_serial(Date(1800, 1, 1)) < 0
    # another null date (as a document may set), e.g. 1904-01-01
    @test SheetCore.date_to_serial(Date(1904, 1, 2), Date(1904, 1, 1)) == 1
    # date and time
    dt = DateTime(2026, 11, 18, 13, 45, 30, 250)
    x = SheetCore.datetime_to_serial(dt)
    @test x ≈ 46344 + (13 * 3600 + 45 * 60 + 30.25) / 86400
    @test SheetCore.serial_to_datetime(x) == dt
    @test SheetCore.serial_to_datetime(-0.5) == DateTime(1899, 12, 29, 12)
    @test_throws SheetCore.SheetCoreError SheetCore.serial_to_datetime(NaN)
end

@testset "displayed text with an epoch" begin
    epoch = SheetCore.DEFAULT_NULL_DATE
    t(x, code) = SheetCore._display_text(x, code; epoch)
    # the same as Excel where both calendars agree
    for (x, code) in [(46344.0, "yyyy-mm-dd"), (46344.5729166667, "d mmm yyyy hh:mm"),
                      (46344.0, "dddd"), (0.75, "h:mm AM/PM")]
        @test t(x, code) == SheetCore._display_text(x, code)
    end
    @test t(46344.0, "yyyy-mm-dd") == "2026-11-18"
    @test t(46344.0, "dddd") == "Wednesday"
    # Excel shows its day 60 as 1900-02-29; the plain calendar has no such day
    @test SheetCore._display_text(60.0, "yyyy-mm-dd") == "1900-02-29"
    @test t(60.0, "yyyy-mm-dd") == "1900-02-28"
    # negative values are dates before the epoch, not ####
    @test SheetCore._display_text(-1.0, "yyyy-mm-dd") == "#"^11
    @test t(-1.0, "yyyy-mm-dd") == "1899-12-29"
    @test t(-1.25, "yyyy-mm-dd hh:mm") == "1899-12-28 18:00"
    @test t(SheetCore.date_to_serial(Date(1800, 6, 1)), "d mmmm yyyy") == "1 June 1800"
    # numbers are unaffected by the epoch
    @test t(1234.5, "#,##0.00") == "1,234.50"
    @test t(-0.25, "0%") == "-25%"
end

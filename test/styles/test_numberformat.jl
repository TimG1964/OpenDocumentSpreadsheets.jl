# Number formats (phase 4, step 5): format codes ↔ ODF data styles, setFormat/getFormat,
# and the text a cell shows (getText), as LibreOffice shows it.
#
# The "setFormat (XLSX.jl)" test set is ported from XLSX.jl 0.13.4
# (test/test_files/formatting/styles.jl, "setFormat"), MIT License, Copyright (c) 2018-2026
# Felipe Noronha Tavares and other contributors. Adapted: setters return the style name
# (D-032); custom ids are compared as "164 or more", in the order formats are added; empty
# cells and out-of-dimension targets are formatted (D-033); `getFormat` of an unformatted
# cell is General, not `nothing`.

using Dates
using OpenDocumentSpreadsheets: ODSError, getFont, getFormat, getText, numfmt_to_odf, add_number_format!, data_style_code, stylesheet, CellFormat

nftmp(name) = joinpath(mktempdir(), name)
const LO_CASES = [split(l, '\t') for l in eachline(joinpath(DATA, "core", "number_formats_libreoffice.tsv")) if !startswith(l, '#')]
# codes no ODF data style can say: LibreOffice writes them as mmm and AM/PM too (F-031)
const LOSSY = Dict("mmmmm" => "mmm", "h:mm:ss A/P" => "h:mm:ss AM/PM")
fmtcode(c::CellFormat) = c.format["numFmt"]["formatCode"]
fmtid(c::CellFormat) = c.numFmtId

@testset "codes → ODF → codes show the same" begin
    xf = newods(); st = xf.styles
    n = 0
    for (kind, v, fmt, _) in LO_CASES
        kind in ("bool", "string") && continue
        x = parse(Float64, v)
        ds = add_number_format!(st, fmt)
        back = data_style_code(stylesheet(st), ds)
        code = get(LOSSY, fmt, fmt)
        t(c) = OpenDocumentSpreadsheets.SheetCore._display_text(x, c; epoch = OpenDocumentSpreadsheets.SheetCore.DEFAULT_NULL_DATE, libreoffice = true)
        @test t(back) == t(code)
        n += 1
    end
    @test n == 240
    @test numfmt_to_odf("General") === nothing
    @test_throws ODSError numfmt_to_odf("[Purple]0")
    # LibreOffice's forms (F-031)
    xml(code) = (r = numfmt_to_odf(code); r[2])
    @test xml("#,##0.00").inner == """<number:number number:decimal-places="2" number:min-decimal-places="2" number:min-integer-digits="1" number:grouping="true"/>"""
    @test xml("0.00%").element == "number:percentage-style"
    @test xml("[\$€-x-euro2] #,##0.00").element == "number:currency-style"
    @test xml("[h]:mm").attrs == """ number:truncate-on-overflow="false\""""
    @test xml("yyyy-mm-dd hh:mm").element == "number:date-style" && xml("hh:mm").element == "number:time-style"
    @test xml("@").element == "number:text-style"
    maps, main = numfmt_to_odf("#,##0.00;[Red](#,##0.00);\"-\"")
    @test first.(maps) == ["value()>0", "value()<0"] && main.inner == "<number:text>-</number:text>"
    @test occursin("fo:color=\"#ff0000\"", maps[2][2].inner)
    @test first.(first(numfmt_to_odf("[>=100]\"big\";[<0]\"neg\";\"small\""))) == ["value()>=100", "value()<0"]
    @test first.(first(numfmt_to_odf("0;0;0;@"))) == ["value()>0", "value()<0", "value()=0"]
end

# The display text LibreOffice stored in each typed cell (`text:p`) of a sheet: (row, col) => text.
function stored_texts(ws)
    out = Dict{Tuple{Int,Int},String}()
    c = OpenDocumentSpreadsheets.XML.Cursor(ws.entry.node)
    OpenDocumentSpreadsheets.XML.next!(c)
    row = 0
    while OpenDocumentSpreadsheets.XML.next!(c) !== nothing && OpenDocumentSpreadsheets.XML.depth(c) > 1
        OpenDocumentSpreadsheets.XML.nodetype(c) === OpenDocumentSpreadsheets.XML.Element || continue
        t = OpenDocumentSpreadsheets.XML.tag(c)
        if t == "table:table-row"
            rep = 1
            for (k, v) in OpenDocumentSpreadsheets.XML.eachattribute!(c)
                k == "table:number-rows-repeated" && (rep = parse(Int, v))
            end
            row += 1
            col = 0
            OpenDocumentSpreadsheets.XML.for_each_child!(c) do ch
                OpenDocumentSpreadsheets.XML.nodetype(ch) === OpenDocumentSpreadsheets.XML.Element || return
                n = 1; typed = false
                for (k, v) in OpenDocumentSpreadsheets.XML.eachattribute!(ch)
                    k == "table:number-columns-repeated" && (n = parse(Int, v))
                    k == "office:value-type" && v != "string" && (typed = true)
                    k == "table:formula" && (typed = false)
                end
                text = IOBuffer(); np = 0
                OpenDocumentSpreadsheets.XML.for_each_child!(ch) do p
                    if OpenDocumentSpreadsheets.XML.nodetype(p) === OpenDocumentSpreadsheets.XML.Element && OpenDocumentSpreadsheets.XML.tag(p) == "text:p"
                        np += 1
                        OpenDocumentSpreadsheets.XML.for_each_child!(p) do x
                            OpenDocumentSpreadsheets.XML.nodetype(x) === OpenDocumentSpreadsheets.XML.Text && print(text, OpenDocumentSpreadsheets.XML.value(x))
                            OpenDocumentSpreadsheets.XML.nodetype(x) === OpenDocumentSpreadsheets.XML.Element && OpenDocumentSpreadsheets.XML.skip_element!(x)
                        end
                    elseif OpenDocumentSpreadsheets.XML.nodetype(p) === OpenDocumentSpreadsheets.XML.Element
                        OpenDocumentSpreadsheets.XML.skip_element!(p)
                    end
                end
                typed && np == 1 && n == 1 && rep == 1 && (out[(row, col + 1)] = String(take!(text)))
                col += n
            end
            row += rep - 1
        elseif !(t in OpenDocumentSpreadsheets._ROW_CONTAINERS) && !(t in OpenDocumentSpreadsheets._COL_CONTAINERS)
            OpenDocumentSpreadsheets.XML.skip_element!(c)
        end
    end
    return out
end

@testset "getText matches the text LibreOffice stored: $f" for f in ("lo-values.ods", "lo-scenarios.ods", "lo-tables.ods")
    xf = openods(joinpath(DATA, f))
    n = 0
    for ws in OpenDocumentSpreadsheets._sheets(xf)
        for ((r, c), text) in stored_texts(ws)
            @test getText(ws, r, c) == text
            n += 1
        end
    end
    @test n > 0
end

@testset "setFormat (XLSX.jl)" begin
    f = newods()
    s = f[1]
    s["A1"] = "Hello"; s["B1"] = "World"; s["A2"] = 2.367; s["B2"] = 200450023; s["C1"] = Date(2018, 2, 1)
    s["C2"] = 0.45; s["D1"] = 100.24; s["D2"] = Time(0, 19, 30)
    s["E1:F5"] = fill(Date(2025, 6, 23), 5, 2)
    @test setFormat(s, "B2"; format = "Scientific") isa String
    @test fmtid(getFormat(s, "B2")) == 48 && fmtcode(getFormat(s, "B2")) == "##0.0E+0"
    setFormat(s, "C2"; format = "Percentage"); @test fmtid(getFormat(s, "C2")) == 9
    setFormat(s, "C1"; format = "General"); @test fmtid(getFormat(s, "C1")) == 0
    setFormat(s, "D2"; format = "Currency"); @test fmtid(getFormat(s, "D2")) == 7
    setFormat(s, "C1"; format = "LongDate"); @test fmtid(getFormat(s, "C1")) == 15
    setFormat(s, "D2"; format = "Time"); @test getFormat(s, "D2").format == Dict("numFmt" => Dict("numFmtId" => "21", "formatCode" => "h:mm:ss"))
    @test getFormat(s, "A2").format == Dict("numFmt" => Dict("numFmtId" => "0", "formatCode" => "General"))
    @test getFormat(s, "A2").applyNumberFormat == "0"
    acc = "_-£* #,##0.00_-;-£* #,##0.00_-;_-£* \"-\"??_-;_-@_-"
    setFormat(s, "A2"; format = acc)
    @test fmtid(getFormat(s, "A2")) >= 164 && fmtcode(getFormat(s, "A2")) == acc
    id = fmtid(getFormat(s, "A2"))
    setFormat(s, "A2"; format = acc); @test fmtid(getFormat(s, "A2")) == id
    setFormat(s, "D2"; format = "h:mm AM/PM"); @test fmtid(getFormat(s, "D2")) == 18
    setFormat(s, "A2"; format = "# ??/??"); @test getFormat(s, "A2").format == Dict("numFmt" => Dict("numFmtId" => "13", "formatCode" => "# ??/??"))
    @test setFormat(s, "E1:E5"; format = "General") == -1
    @test setFormat(s, "F1:F5"; format = "Currency") == -1
    @test fmtid(getFormat(s, "E2")) == 0 && fmtid(getFormat(f, "Sheet1!F2")) == 7
    setFormat(f, "Sheet1!E1:F5"; format = "#,##0.000")
    @test fmtcode(getFormat(s, "E2")) == "#,##0.000" && fmtid(getFormat(f, "Sheet1.F2")) == fmtid(getFormat(s, "E2")) > id
    # past the used area: formatted, not refused (D-033)
    @test setFormat(s, "Z100"; format = "Currency") isa String && fmtid(getFormat(s, "Z100")) == 7
    @test_throws ODSError setFormat(s, "E2"; format = "[Purple]0")       # Excel refuses an unknown colour
    @test_throws ODSError setFormat(s, "E2"; format = "0 h")             # and date codes among digits
    for fmt in ["dd/mm/yyyy", "dd.mm.yyyy", "0!x", "[\$-409]d mmm yyyy", "[\$€-x-euro2] #,##0.00",
                "General;[Red]-General", "0^0", "0&0", "0'0", "0~0", "0{0}", "0<0>", "0=0"]
        setFormat(s, "E3"; format = fmt)
        @test fmtid(getFormat(s, "E3")) > 163 && fmtcode(getFormat(s, "E3")) == fmt
    end
    p = writeods(nftmp("formats.ods"), f)
    openods(p) do r
        rs = r["Sheet1"]
        @test getFormat(rs, "A2").format == Dict("numFmt" => Dict("numFmtId" => "13", "formatCode" => "# ??/??"))
        @test getFormat(rs, "D2").format == Dict("numFmt" => Dict("numFmtId" => "18", "formatCode" => "h:mm AM/PM"))
        @test fmtcode(getFormat(rs, "E2")) == "#,##0.000" && fmtid(getFormat(rs, "E2")) >= 164
        @test fmtcode(getFormat(rs, "D1")) == "General" && fmtcode(getFormat(rs, "B2")) == "##0.0E+0"
        @test getText(rs, "B2") == "200.5E+6" && getText(rs, "C2") == "45%" && getText(rs, "C1") == "1-Feb-18"
        @test rs["C1"] == Date(2018, 2, 1) && rs["B2"] == 200450023
    end

    f = newods()
    s = f[1]
    setFormat(s, "Sheet1!E5"; format = "Currency")
    @test getFormat(f, "Sheet1!E5").format == Dict("numFmt" => Dict("numFmtId" => "7", "formatCode" => "\$#,##0.00_);(\$#,##0.00)"))
    setFormat(s, "Sheet1!W5:X8"; format = "Currency"); @test fmtid(getFormat(f, "Sheet1!X7")) == 7
    setFormat(s, "Sheet1!F:G"; format = "Currency"); @test fmtid(getFormat(s, "F3")) == 7
    setFormat(s, "Sheet1!4:8"; format = "Currency"); @test fmtid(getFormat(s, "Q7")) == 7
    setFormat(s, "N4,M8:M15,Z25:Z26"; format = "#,##0.000"); @test fmtcode(getFormat(s, "Z26")) == "#,##0.000"
    setFormat(s, "Sheet1!4:8"; format = "39")
    @test getFormat(s, "Q7").format == Dict("numFmt" => Dict("numFmtId" => "39", "formatCode" => "#,##0.00_);(#,##0.00)"))
    setFormat(s, "Sheet1!4:8"; format = "#,##0"); @test fmtid(getFormat(s, "Q7")) == 3
    setFormat(s, :, 2:4; format = "Currency"); @test fmtid(getFormat(f, "Sheet1!B23")) == 7
    setFormat(s, 4:3:10, :; format = "percentage"); @test fmtid(getFormat(s, "Q7")) == 9    # any case
    setFormat(s, 25:26, 20:26; format = "#,##0.0000"); @test fmtcode(getFormat(s, "Z26")) == "#,##0.0000"
    setUniformFormat(s, "Sheet1!W5:X8"; format = "Currency"); @test fmtid(getFormat(f, "Sheet1!X7")) == 7
    setFormat(s, "A30"; format = "0.0%")
    setUniformFormat(s, "A30,B30:C31")
    @test fmtcode(getFormat(s, "C31")) == "0.0%"
end

@testset "formats, values and types" begin
    f = newods(); s = f[1]
    s["A1"] = 5
    @test s["A1"] === Int64(5)
    setFormat(s, "A1"; format = "0.00")                                    # decimals: read as Float64 (D-016)
    @test s["A1"] === 5.0 && getText(s, "A1") == "5.00"
    s["A2"] = Date(2024, 3, 7)
    setFormat(s, "A2"; format = "d mmm yyyy")
    @test getText(s, "A2") == "7 Mar 2024" && s["A2"] == Date(2024, 3, 7)
    s["A2"] = Date(2025, 1, 2)                                             # a date fits: the format is kept
    @test getText(s, "A2") == "2 Jan 2025"
    s["A2"] = 3                                                            # a number doesn't: only the format goes (D-037)
    @test getText(s, "A2") == "3" && fmtcode(getFormat(s, "A2")) == "General"
    setFont(s, "A3"; bold = true); s["A3"] = 1.5
    setFormat(s, "A3"; format = "0.000")
    @test haskey(getFont(s, "A3").font, "b") && getText(s, "A3") == "1.500"
    s["A4"] = true; @test getText(s, "A4") == "TRUE"
    s["A5"] = Time(1, 2, 3); @test getText(s, "A5") == "01:02:03"
    s["A6"] = DateTime(2024, 3, 7, 8, 9, 10); @test getText(s, "A6") == "2024-03-07 08:09:10"
    s["A7"] = "text"; setFormat(s, "A7"; format = "\"<\"@\">\""); @test getText(s, "A7") == "<text>"
    @test getText(s, "A99") == ""
    setFormula(s, "A8"; val = "=1+1"); @test getText(s, "A8") == ""          # no value until LibreOffice computes it
end

@testset "LibreOffice shows OpenDocumentSpreadsheets's formats as it shows the codes" begin
    if lo_ok(; what = "the number format oracle")
        dir = mktempdir()
        profile = lo_profile_url(joinpath(dir, "lo-profile"))
        xf = newods("N"); ws = xf["N"]
        cases = []
        for (kind, v, fmt, text) in LO_CASES
            kind == "bool" && continue
            r = length(cases) + 1
            ws[r, 1] = kind == "string" ? String(v) : parse(Float64, v)
            setFormat(ws, r, 1; format = fmt)
            push!(cases, (r, v, fmt, chop(text; head = 1, tail = 1)))
        end
        p = writeods(joinpath(dir, "nf.ods"), xf)
        lo = joinpath(dir, "lo")
        lo_convert(p, "csv:Text - txt - csv (StarCalc):9,34,76,1,,0,false,false,true"; outdir = lo, profile = profile)
        lo_convert(p, "ods"; outdir = lo, profile = profile)
        csv = readlines(joinpath(lo, "nf.csv"))
        back = openods(joinpath(lo, "nf.ods"))["N"]                        # LibreOffice's own data styles, read back
        # reading LibreOffice's own file back: its locale short date (`format-source="language"`
        # styles don't say their digits); and a value it saved rounded to 15 digits
        # (1.0000000000000002e15 as 1000000000000000)
        half = Set(["1.0000000000000002e15"])
        nlossy = 0
        for (r, v, fmt, expected) in cases
            shown = replace(strip(csv[r], '"'), "\"\"" => "\"")
            if haskey(LOSSY, fmt)
                nlossy += 1
                @test shown != expected                                     # no data style can say it
                continue
            end
            @test shown == expected
            (v in half || fmt == "dd/mm/yy") || @test getText(back, r, 1) == shown
        end
        @test nlossy == 2
    end
end

@testset "large numbers in data styles (32-bit safe)" begin
    O = OpenDocumentSpreadsheets
    # 1000^7 and 10^20 pass Int64 (and 1000^4 passes a 32-bit Int): written as exact digits
    @test occursin("number:display-factor=\\\"1000000000000000000000\\\"", repr(O.numfmt_to_odf("0,,,,,,,")))
    @test occursin("number:max-denominator-value=\\\"99999999999999999999\\\"", repr(O.numfmt_to_odf("# ?/" * "?"^20)))
    # a condition past 2^31 (an `Int` threw on a 32-bit build) or past 2^63 (threw anywhere)
    @test first(first(first(O.numfmt_to_odf("[>3000000000]0;0")))) == "value()>3000000000"
    @test first(first(first(O.numfmt_to_odf("[>1e20]0;0")))) == "value()>1.0e20"
    @test O.Charts._num_text(3e9) == "3000000000" && O.Charts._num_text(1e20) == "100000000000000000000"   # no exponent
    # a digit count from a file is cut at 255, and read the same on a 32-bit build
    @test O._int_attr(Dict("k" => "1000000000"), "k", 0) === 255
    @test O._int_attr(Dict("k" => "3000000000000"), "k", 0) === 255
    @test O._int_attr(Dict{String,String}(), "k", 3) === 3
    # numbers no format has digits for show as the text a file stores them as (D-043); they threw
    for lo in (false, true), (x, t) in ((Inf, "Inf"), (-Inf, "-Inf"), (NaN, "NaN")), f in ("0.00", "General", "0.0E+00", "# ?/?", "yyyy-mm-dd", "0%")
        @test O.SheetCore._display_text(x, f; libreoffice = lo) == t
    end
end

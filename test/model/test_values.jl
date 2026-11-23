# Cell values: parsing the value attributes, the value types (D-016, D-017, F-018 to F-023),
# text content, and the LibreOffice-written lo-values fixture (experiment 007's cases).

using Dates
using OpenDocumentSpreadsheets: parse_odf_date, parse_odf_duration, duration_value, _is_intlike, getcell, Cell, EmptyCell, getFormula

@testset "parse_odf_date" begin
    @test parse_odf_date("2024-03-05") === Date(2024, 3, 5)
    @test parse_odf_date("2024-03-05T13:45:30") == DateTime(2024, 3, 5, 13, 45, 30)
    @test parse_odf_date("2024-03-05T13:45:30.25") == DateTime(2024, 3, 5, 13, 45, 30, 250)
    @test parse_odf_date("2024-03-05T13:45:30.123456") == DateTime(2024, 3, 5, 13, 45, 30, 123)
    @test parse_odf_date("2024-03-05T13:45") == DateTime(2024, 3, 5, 13, 45)
    @test parse_odf_date("2024-03-05T00:00:00Z") == DateTime(2024, 3, 5)
    @test parse_odf_date("0100-01-01") == Date(100, 1, 1)
    @test parse_odf_date("12024-01-01") == Date(12024, 1, 1)
    @test parse_odf_date("-0001-01-01") == Date(-1, 1, 1)
    @test parse_odf_date("2024-02-30") === nothing
    @test parse_odf_date("2024-3-5") === nothing
    @test parse_odf_date("") === nothing
    @test parse_odf_date("tomorrow") === nothing
end

@testset "parse_odf_duration" begin
    ns(h, m = 0, s = 0) = (Int64(h) * 3600 + m * 60 + s) * 1_000_000_000   # Int64 on 32-bit too
    @test parse_odf_duration("PT13H45M30S") == ns(13, 45, 30)
    @test parse_odf_duration("PT00H00M00S") == 0
    @test parse_odf_duration("PT36H00M00S") == ns(36)
    @test parse_odf_duration("P1DT2H") == ns(26)
    @test parse_odf_duration("-PT01H00M00S") == -ns(1)
    @test parse_odf_duration("PT0.5S") == 500_000_000
    @test parse_odf_duration("PT23H59M59.999S") == ns(23, 59, 59) + 999_000_000
    @test parse_odf_duration("PT90M") == ns(1, 30)
    @test parse_odf_duration("P2W") == ns(14 * 24)
    @test parse_odf_duration("PT1,5S") == 1_500_000_000
    @test parse_odf_duration("13:45") === nothing
    @test parse_odf_duration("P") === nothing
    @test parse_odf_duration("PT5X") === nothing
    # D-017: Time under 24 hours, else a canonical CompoundPeriod
    @test duration_value(ns(13, 45, 30)) === Time(13, 45, 30)
    @test duration_value(ns(36)) == Dates.canonicalize(Day(1) + Hour(12))
    @test duration_value(ns(24)) == Dates.canonicalize(Dates.CompoundPeriod(Day(1)))
    @test duration_value(-ns(1)) == Dates.canonicalize(Dates.CompoundPeriod(Hour(-1)))
    @test string(duration_value(ns(36))) == "1 day, 12 hours"
end

@testset "_is_intlike" begin
    @test _is_intlike("7") && _is_intlike("-0") && _is_intlike("123456789012345678")
    @test !_is_intlike("7.0") && !_is_intlike("1E3") && !_is_intlike("1234567890123456789")
    @test !_is_intlike("") && !_is_intlike("-") && !_is_intlike("1.5E+300")
end

# experiment 007's cases, as LibreOffice re-saved them: label => (value, datatype)
const LO_VALUES = [
    "float 7 style=nothing" => (Int64(7), :float),
    "float 7 style=N0" => (Int64(7), :float),
    "float 7 style=N2" => (7.0, :float),              # the format shows decimals (D-016)
    "float 7.0 style=nothing" => (Int64(7), :float),
    "float 7.5 style=N0" => (7.5, :float),
    "float 0.1 style=nothing" => (0.1, :float),
    "float 1e-20 style=nothing" => (1.0e-20, :float),
    "float 1.5E+300 style=nothing" => (1.5e300, :float),
    "float 123456789012345678 style=nothing" => (1.23456789012346e17, :float),   # F-018
    "float -0 style=nothing" => (Int64(0), :float),
    "float 0.30000000000000004 style=nothing" => (0.3, :float),                  # F-018
    "float 3.141592653589793 style=nothing" => (3.14159265358979, :float),
    "float -2.5 style=N0" => (-2.5, :float),
    "float 1234567.891 style=N2" => (1234567.891, :float),
    "percentage 0.5 P0" => (0.5, :percentage),
    "percentage 0.5 P2" => (0.5, :percentage),
    "percentage 1 P0" => (Int64(1), :percentage),
    "percentage 0.125 P0" => (0.125, :percentage),
    "currency GBP 5 C2" => (5.0, :currency),
    "currency GBP 5 C0" => (Int64(5), :currency),
    "currency GBP 5.25 C2" => (5.25, :currency),
    "currency GBP 5.25 C0" => (5.25, :currency),
    "date 2024-03-05 D" => (Date(2024, 3, 5), :date),
    "date 2024-03-05T00:00:00 D" => (Date(2024, 3, 5), :date),
    "date 2024-03-05T00:00:00 DT" => (DateTime(2024, 3, 5), :date),         # F-019
    "date 2024-03-05T13:45:30 DT" => (DateTime(2024, 3, 5, 13, 45, 30), :date),
    "date 2024-03-05T13:45:30.25 DT" => (DateTime(2024, 3, 5, 13, 45, 30, 250), :date),
    "date 2024-03-05T13:45:30 D" => (DateTime(2024, 3, 5, 13, 45, 30), :date),
    "date 1899-12-30 D" => (Date(1899, 12, 30), :date),
    "date 1899-12-29 D" => (Date(1899, 12, 29), :date),
    "date 1800-01-01 D" => (Date(1800, 1, 1), :date),
    "date 1582-10-15 D" => (Date(1582, 10, 15), :date),
    "date 0100-01-01 D" => (Date(100, 1, 1), :date),
    "time PT13H45M30S" => (Time(13, 45, 30), :time),
    "time PT00H00M00S" => (Time(0), :time),
    "time PT23H59M59.999S" => (Time(23, 59, 59, 999), :time),
    "time PT24H00M00S" => (Dates.canonicalize(Dates.CompoundPeriod(Day(1))), :time),
    "time PT36H00M00S" => (Dates.canonicalize(Day(1) + Hour(12)), :time),
    "time P1DT2H" => (Dates.canonicalize(Day(1) + Hour(2)), :time),
    "time -PT01H00M00S" => (Dates.canonicalize(Dates.CompoundPeriod(Hour(-1))), :time),
    "time PT0.5S" => (Time(0, 0, 0, 500), :time),
    "time PT1H" => (Time(1), :time),
    "time PT90M" => (Time(1, 30), :time),
    "boolean true" => (true, :boolean),
    "boolean false" => (false, :boolean),
    "text 2 paragraphs" => ("one\ntwo", :string),
    "text s c=3" => ("a   b", :string),
    "text s (no c)" => ("a b", :string),
    "text leading spaces" => ("  lead", :string),
    "text literal spaces" => ("  two  spaces  ", :string),
    "text tab" => ("a\tb", :string),
    "text line-break" => ("a\nb", :string),
    "text span" => ("aboldc", :string),
    "text link" => ("see here", :string),
    "text string-value attr" => ("attr wins?", :string),     # F-021
    "text empty p" => (missing, :string),
    "text no p" => (missing, :none),                          # F-022: an empty cell
    "text entities" => ("<a> & \"q\" é", :string),
    "text with style X" => ("0123", :string),
    "no value-type, p" => ("orphan text", :string),
    "float, no value attr" => (Int64(0), :float),
    "text CR in p" => ("a\nb", :string),
    "formula num" => (Int64(2), :float),
    "formula str" => ("abc", :string),
    "formula empty str" => (missing, :empty),                 # F-022: no value type
    "formula bool" => (true, :boolean),
    "formula date" => (Date(2024, 3, 5), :date),
    "formula time" => (Time(1, 2, 3), :time),
    "err DIV0" => (missing, :error),
    "err NA" => (missing, :error),
    "err NAME" => (missing, :error),
    "err VALUE" => (missing, :error),
    "err NUM" => (missing, :error),
    "err REF" => (missing, :error),
    "err NULL" => (missing, :error),
    "err 502" => (missing, :error),
    "err 504" => (missing, :error),
]
const LO_ERRORS = Dict("err DIV0" => "#DIV/0!", "err NA" => "#N/A", "err NAME" => "#NAME?",
    "err VALUE" => "#VALUE!", "err NUM" => "Err:502", "err REF" => "#REF!", "err NULL" => "#NULL!",
    "err 502" => "#NUM!", "err 504" => "#VALUE!")
const LO_FORMULAS = Dict("formula num" => "=1+1", "formula str" => "=\"abc\"", "formula empty str" => "=\"\"",
    "formula bool" => "=1=1", "formula date" => "=DATE(2024,3,5)", "formula time" => "=TIME(1,2,3)",
    "err DIV0" => "=1/0", "err NAME" => "=nosuchfn(1)", "err REF" => "=#REF!",
    "err NULL" => "=SUM(A1:A2 ! B5:B6)", "err 504" => "=SUM(1,\"x\",)")

@testset "lo-values fixture ($ext)" for ext in ("ods", "fods")
    for cache in (true, false)
        xf = openods(joinpath(DATA, "lo-values.$ext"); enable_cache = cache)
        ws = xf["V"]
        @test OpenDocumentSpreadsheets.get_dimension(ws) == SheetCore.CellRange("A1:B78")
        labels = ws["A1:A78"]
        values = ws["B1:B78"]
        for (label, (v, dt)) in LO_VALUES
            r = findfirst(==(label), vec(labels))
            @test r !== nothing
            r === nothing && continue
            got = values[r, 1]
            @test isequal(got, v) && typeof(got) == typeof(v)
            c = getcell(ws, r, 2)
            if dt === :none
                @test c isa EmptyCell
            else
                @test c isa Cell && c.datatype === dt
                @test isequal(getdata(ws, c), v)
            end
            haskey(LO_ERRORS, label) && @test geterror(ws, r, 2) == LO_ERRORS[label] && iserror(ws, r, 2)
            haskey(LO_ERRORS, label) || @test !iserror(ws, r, 2) && geterror(ws, r, 2) == ""
            haskey(LO_FORMULAS, label) && @test getFormula(ws, r, 2) == LO_FORMULAS[label]
        end
        # currency code, style names
        r = findfirst(==("currency GBP 5 C2"), vec(labels))
        @test getcell(ws, r, 2).currency == "GBP"
        @test getcell(ws, r, 2).style == "cC2"
        @test getcell(ws, 1, 2).style == "Default"
        @test getFormula(ws, 1, 2) === nothing
        @test getFormula(ws, 200, 2) === nothing
    end
end

# A flat document written by hand, opened from memory.
const NS_ALL = join([
    "xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\"",
    "xmlns:style=\"urn:oasis:names:tc:opendocument:xmlns:style:1.0\"",
    "xmlns:text=\"urn:oasis:names:tc:opendocument:xmlns:text:1.0\"",
    "xmlns:table=\"urn:oasis:names:tc:opendocument:xmlns:table:1.0\"",
    "xmlns:number=\"urn:oasis:names:tc:opendocument:xmlns:datastyle:1.0\"",
    "xmlns:xlink=\"http://www.w3.org/1999/xlink\"",
    "xmlns:of=\"urn:oasis:names:tc:opendocument:xmlns:of:1.2\"",
    "xmlns:calcext=\"urn:org:documentfoundation:names:experimental:calc:xmlns:calcext:1.0\""], " ")
fods(body; styles = "", named = "") = """<?xml version="1.0" encoding="UTF-8"?>
<office:document $NS_ALL office:version="1.4" office:mimetype="application/vnd.oasis.opendocument.spreadsheet">
<office:styles>$styles</office:styles><office:body><office:spreadsheet>$body$named</office:spreadsheet></office:body></office:document>"""
open_fods(body; cache = true, kw...) = openods(IOBuffer(fods(body; kw...)); enable_cache = cache)

@testset "text content" begin
    cell(x) = "<table:table name=\"x\"><table:table-row><table:table-cell office:value-type=\"string\">$x</table:table-cell></table:table-row></table:table>"
    rd(x) = open_fods(replace(cell(x), "name=" => "table:name="))[1]["A1"]
    @test rd("<text:p>a<text:span>b<text:span>c</text:span></text:span>d</text:p>") == "abcd"
    @test rd("<text:p>a<text:s text:c=\"0\"/>b</text:p>") == "ab"
    @test rd("<text:p>x<office:annotation><text:p>note</text:p></office:annotation>y</text:p>") == "xy"
    @test rd("<office:annotation><text:p>note</text:p></office:annotation><text:p>v</text:p>") == "v"
    @test rd("<text:h>head</text:h><text:p>body</text:p>") == "head\nbody"
    @test rd("<text:p><![CDATA[a<b]]></text:p>") == "a<b"
    @test rd("<text:p>a\r\nb</text:p>") == "a\nb"
    @test rd("<text:p>a<text:line-break/>b<text:tab/>c</text:p>") == "a\nb\tc"
    @test rd("<text:p>one</text:p><text:p/><text:p>three</text:p>") == "one\n\nthree"
end

@testset "Int or Float by data style (D-016)" begin
    styles = """
    <number:number-style style:name="N2"><number:number number:decimal-places="2"/></number:number-style>
    <number:number-style style:name="N0"><number:number number:decimal-places="0"/></number:number-style>
    <number:number-style style:name="Npos"><number:number number:decimal-places="1"/></number:number-style>
    <number:number-style style:name="Nmap"><style:map style:condition="value()&gt;=0" style:apply-style-name="Npos"/></number:number-style>
    <number:number-style style:name="Nsci"><number:scientific-number number:decimal-places="3"/></number:number-style>
    <number:number-style style:name="Nfrac"><number:fraction/></number:number-style>
    <number:date-style style:name="DT"><number:year/><number:hours/></number:date-style>
    <style:style style:name="dec" style:family="table-cell" style:data-style-name="N2"/>
    <style:style style:name="child" style:family="table-cell" style:parent-style-name="dec"/>
    <style:style style:name="whole" style:family="table-cell" style:data-style-name="N0"/>
    <style:style style:name="mapped" style:family="table-cell" style:data-style-name="Nmap"/>
    <style:style style:name="sci" style:family="table-cell" style:data-style-name="Nsci"/>
    <style:style style:name="frac" style:family="table-cell" style:data-style-name="Nfrac"/>
    <style:style style:name="dt" style:family="table-cell" style:data-style-name="DT"/>
    <style:style style:name="loop1" style:family="table-cell" style:parent-style-name="loop2"/>
    <style:style style:name="loop2" style:family="table-cell" style:parent-style-name="loop1"/>"""
    v(style) = "<table:table-cell" * (style === nothing ? "" : " table:style-name=\"$style\"") * " office:value-type=\"float\" office:value=\"3\"/>"
    body = "<table:table table:name=\"S\"><table:table-column table:number-columns-repeated=\"2\"/>" *
        "<table:table-column table:default-cell-style-name=\"dec\"/>" *
        "<table:table-row>" * join(v.([nothing, "dec", nothing, "child", "whole", "mapped", "sci", "frac", "loop1", "nosuch"])) * "</table:table-row>" *
        "<table:table-row table:default-cell-style-name=\"dec\">" * v(nothing) * "</table:table-row>" *
        "<table:table-row><table:table-cell table:style-name=\"dt\" office:value-type=\"date\" office:date-value=\"2024-01-02\"/></table:table-row>" *
        "</table:table>"
    for cache in (true, false)
        ws = open_fods(body; styles, cache)[1]
        @test ws["A1:J1"] == Any[3 3.0 3.0 3.0 3 3.0 3.0 3.0 3 3]
        @test typeof.(ws["A1:J1"]) == [Int64 Float64 Float64 Float64 Int64 Float64 Float64 Float64 Int64 Int64]
        @test ws["A2"] === 3.0                   # the row's default style
        @test ws["A3"] == DateTime(2024, 1, 2)   # a date style showing a time
        @test getcell(ws, "C1").style == "dec"   # the column's default style (F-009)
        @test getcell(ws, "J1").style == "Default"
    end
end

@testset "odd and foreign cells" begin
    body = """<table:table table:name="S"><table:table-row>
      <table:table-cell office:value-type="float" office:value="abc"/>
      <table:table-cell office:value-type="date" office:date-value="not a date"/>
      <table:table-cell office:value-type="time" office:time-value="soon"/>
      <table:table-cell office:value-type="boolean" office:boolean-value="1"/>
      <table:table-cell office:value-type="void"/>
      <table:table-cell office:value-type="string" office:string-value=""/>
      <table:table-cell office:value-type="float" office:value=" 2.5 "/>
      <table:table-cell table:formula="of:=A1"/>
      </table:table-row></table:table>"""
    ws = open_fods(body)[1]
    @test isequal(ws["A1:H1"], Any[0.0 missing missing true missing missing 2.5 missing])
    @test getcell(ws, "B1") isa EmptyCell
    @test getcell(ws, "H1") isa Cell && getcell(ws, "H1").datatype === :empty && getFormula(ws, "H1") == "=A1"
    @test !isempty(getcell(ws, "H1"))
end

# The style model (phase 4, step 2): full cell styles parsed lazily (CellStyle, StyleSheet),
# added styles deduplicated and written as automatic styles, and the retype rule (D-037).

using Dates
using OpenDocumentSpreadsheets: CellStyle, PropSet, setprops, getprop, parse_cell_style, write_cell_style, stylesheet, cell_style,
    add_cell_style!, add_data_style!, added_styles_xml, typed_styles_xml, with_text, with_datastyle, is_plain,
    style_id, style_name, style_info, encode_value, store_set!, getcell, DataStyleInfo, DK_NUMBER, DK_DATE

stmp(name) = joinpath(mktempdir(), name)
XML_text(xf, k) = String(OpenDocumentSpreadsheets.XML.sourcetext(xf[k].entry.node))
bold(cs::CellStyle) = with_text(cs, setprops(cs.text, "fo:font-weight" => "bold"))
isbold(cs::CellStyle) = getprop(cs.text, "fo:font-weight") == "bold"

@testset "CellStyle: parse, write, compare" begin
    x = """<style:style style:name="ce9" style:family="table-cell" style:parent-style-name="Default" style:data-style-name="N2" style:display-name='a "b"'>
             <style:table-cell-properties fo:background-color="#ffff00" fo:border="0.74pt solid #000000"><style:background-image/></style:table-cell-properties>
             <style:text-properties fo:font-weight="bold" fo:color="#ff0000"/>
             <style:map style:condition="cell-content()=1" style:apply-style-name="Good" style:base-cell-address="S.A1"/>
           </style:style>"""
    cs = parse_cell_style(x)
    @test cs.parent == "Default" && cs.datastyle == "N2"
    @test cs.attrs == ["style:display-name" => "a &quot;b&quot;"]
    @test cs.cell.attrs == ["fo:background-color" => "#ffff00", "fo:border" => "0.74pt solid #000000"]
    @test cs.cell.inner == "<style:background-image/>"
    @test cs.text.attrs == ["fo:color" => "#ff0000", "fo:font-weight" => "bold"]     # sorted
    @test isempty(cs.para) && occursin("style:map", cs.extra) && !is_plain(cs)
    io = IOBuffer(); write_cell_style(io, "new", cs); out = String(take!(io))
    @test startswith(out, "<style:style style:name=\"new\" style:family=\"table-cell\" style:parent-style-name=\"Default\" style:data-style-name=\"N2\"")
    @test parse_cell_style(out) == cs && hash(parse_cell_style(out)) == hash(cs)
    @test is_plain(CellStyle("Default", "N1"))
    io = IOBuffer(); write_cell_style(io, "p", CellStyle("Default", "N1"))
    @test String(take!(io)) == """<style:style style:name="p" style:family="table-cell" style:parent-style-name="Default" style:data-style-name="N1"/>"""
    @test setprops(PropSet(), "b" => "2", "a" => "1").attrs == ["a" => "1", "b" => "2"]
    @test setprops(setprops(PropSet(), "a" => "1"), "a" => nothing) == PropSet()
end

@testset "StyleSheet: every fixture style, lazily" for f in ("lo-scenarios.ods", "lo-scenarios.fods", "lo-values.ods", "lo-tables.ods")
    xf = openods(joinpath(DATA, f))
    @test xf.styles.sheet[1] === nothing                       # reading values never builds it
    ws = xf[1]; ws[:]
    @test xf.styles.sheet[1] === nothing
    sh = stylesheet(xf.styles)
    @test length(sh.cells) == length(xf.styles.names)
    for (i, cs) in enumerate(sh.cells)                          # write → parse is the identity
        io = IOBuffer(); write_cell_style(io, "x", cs)
        @test parse_cell_style(String(take!(io))) == cs
    end
end

@testset "named and automatic styles" begin
    st = openods(joinpath(DATA, "lo-scenarios.ods")).styles
    sh = stylesheet(st)
    h = style_id(st, "Heading")
    @test !sh.automatic[h + 1] && getprop(cell_style(st, h).text, "fo:font-size") == "24pt"
    @test cell_style(st, style_id(st, "Heading_20_1")).parent == "Heading"
    c1 = style_id(st, "ce1")
    @test sh.automatic[c1 + 1] && isbold(cell_style(st, c1))
    # an equal style is the existing one; a new one is added once
    @test add_cell_style!(st, cell_style(st, c1)) == c1
    n = length(st.names)
    red = with_text(CellStyle(), setprops(PropSet(), "fo:color" => "#ff0000"))
    id = add_cell_style!(st, red)
    @test id == n && style_name(st, id) == "odsf-ce1" && add_cell_style!(st, red) == id && length(st.names) == n + 1
    @test style_info(st, id) == style_info(st, 0)
    x = added_styles_xml(st)
    @test occursin("""<style:style style:name="odsf-ce1" style:family="table-cell" style:parent-style-name="Default"><style:text-properties fo:color="#ff0000"/></style:style>""", x)
    # data styles: deduplicated by their XML
    body = """<number:number-style style:name="\$NAME"><number:number number:decimal-places="3"/></number:number-style>"""
    d1 = add_data_style!(st, body, DataStyleInfo(DK_NUMBER, 3, false))
    @test d1 == "odsf-N1" && add_data_style!(st, body, DataStyleInfo(DK_NUMBER, 3, false)) == d1
    @test occursin("""<number:number-style style:name="odsf-N1">""", added_styles_xml(st))
    three = add_cell_style!(st, with_datastyle(red, d1))
    @test style_info(st, three).decimals == 3
end

@testset "typed styles are unchanged (D-024)" begin
    xf = newods()
    ws = xf[1]
    ws["A1"] = Date(2024, 1, 2); ws["B1"] = true
    @test added_styles_xml(xf.styles) == typed_styles_xml(xf.styles)
    @test xf.styles.sheet[1] === nothing
    # typed styles added after the sheet is built are known to it
    sh = stylesheet(xf.styles)
    ws["C1"] = Time(1, 2, 3)
    t = style_id(xf.styles, "odsf-time")
    @test cell_style(xf.styles, t) == CellStyle("Default", "odsf-time-N") && sh.automatic[t + 1]
    @test added_styles_xml(xf.styles) == typed_styles_xml(xf.styles)
end

# A cell of a new or read sheet given a style by id (the setters come in step 4).
function put!(ws, ref, v, style)
    c = SheetCore.CellRef(ref)
    store_set!(OpenDocumentSpreadsheets._cached_store(ws), row_number(c), column_number(c), encode_value(v, Int32(style)))
    OpenDocumentSpreadsheets._mark_dirty!(ws, row_number(c), column_number(c))
end

@testset "retyping keeps the formatting (D-037)" begin
    xf = newods()
    ws = xf[1]; st = xf.styles
    ws["A1"] = Date(2024, 1, 2)
    bd = add_cell_style!(st, bold(cell_style(st, style_id(st, "odsf-date"))))   # bold, date format
    put!(ws, "A1", Date(2024, 1, 2), bd); put!(ws, "A2", Date(2024, 1, 3), bd); put!(ws, "A3", Date(2024, 1, 4), bd)
    ws["A1"] = 5                                   # a number into a bold date cell: bold, no format
    s5 = cell_style(st, style_id(st, getcell(ws, "A1").style))
    @test isbold(s5) && s5.datastyle == "" && ws["A1"] === Int64(5)
    ws["A2"] = true                                 # a boolean: bold, the boolean format
    sb = cell_style(st, style_id(st, getcell(ws, "A2").style))
    @test isbold(sb) && sb.datastyle == "odsf-boolean-N"
    ws["A3"] = Date(2000, 1, 1)                     # fits: the style is kept
    @test style_id(st, getcell(ws, "A3").style) == bd
    ws["A4"] = 6                                    # the same derivation is reused
    put!(ws, "A4", Date(2024, 1, 5), bd); ws["A4"] = 6
    @test getcell(ws, "A4").style == getcell(ws, "A1").style
    # a plain number-format style gives way, as before (D-027)
    ws["B1"] = Date(2024, 1, 2); ws["B1"] = 7
    @test getcell(ws, "B1").style == "Default"
    p = writeods(stmp("retyped.ods"), xf)
    r = openods(p)
    rs = r[1]
    @test rs["A1"] === Int64(5) && rs["A2"] === true && rs["A3"] == Date(2000, 1, 1) && rs["B1"] === Int64(7)
    @test isbold(cell_style(r.styles, style_id(r.styles, getcell(rs, "A1").style)))
    @test isbold(cell_style(r.styles, style_id(r.styles, getcell(rs, "A2").style)))
end

@testset "a named style with a date format: retyped on top of it" begin
    xf = openods(joinpath(DATA, "lo-scenarios.ods"); mode = "rw")
    st = xf.styles
    # a named style whose format is a date: LibreOffice's N70 on Heading's look
    h = add_cell_style!(st, CellStyle("Heading", "N70"))
    @test style_info(st, h).kind === DK_DATE
    ws = xf[1]
    put!(ws, "Z1", Date(2024, 1, 2), style_id(st, "Heading"))
    ws["Z1"] = 3                                    # Heading has no format: it fits, kept
    @test getcell(ws, "Z1").style == "Heading"
    put!(ws, "Z2", Date(2024, 1, 2), h)
    ws["Z2"] = 4                                    # an automatic style on Heading: Heading kept, format cleared
    cs = cell_style(st, style_id(st, getcell(ws, "Z2").style))
    @test cs.parent == "Heading" && cs.datastyle == ""
end

@testset "patched saves add styles and change nothing else (D-023)" begin
    src = joinpath(DATA, "lo-scenarios.ods")
    orig = OpenDocumentSpreadsheets.read_xml(OpenDocumentSpreadsheets.open_container(read(src)), :content)
    xf = openods(src; mode = "rw")
    st = xf.styles
    ws = xf[1]
    red = add_cell_style!(st, with_text(CellStyle(), setprops(PropSet(), "fo:color" => "#ff0000")))
    put!(ws, "A1", "red", red)
    p = writeods(stmp("patched.ods"), xf)
    new = OpenDocumentSpreadsheets.read_xml(OpenDocumentSpreadsheets.open_container(read(p)), :content)
    sx = added_styles_xml(st)
    @test occursin(sx, new)
    # outside the sheet and the styles, nothing changed
    i = findfirst("</office:automatic-styles>", orig)[1]
    @test replace(new, sx => ""; count = 1)[1:i-1] == orig[1:i-1]
    ws1 = OpenDocumentSpreadsheets.sheetnames(xf)
    back = openods(p)
    @test back[1]["A1"] == "red" && getprop(cell_style(back.styles, style_id(back.styles, getcell(back[1], "A1").style)).text, "fo:color") == "#ff0000"
    for k in 2:length(ws1)                          # untouched sheets: byte for byte
        @test XML_text(back, k) == XML_text(openods(src), k)
    end
end

@testset "LibreOffice keeps derived styles" begin
    if lo_ok(; what = "the style oracle")
        dir = mktempdir()
        profile = lo_profile_url(joinpath(dir, "lo-profile"))
        xf = newods("S")
        ws = xf["S"]; st = xf.styles
        ws["A1"] = Date(2024, 1, 2)
        bd = add_cell_style!(st, bold(cell_style(st, style_id(st, "odsf-date"))))
        put!(ws, "A1", Date(2024, 1, 2), bd); put!(ws, "A2", Date(2024, 1, 2), bd); put!(ws, "A3", Date(2024, 1, 2), bd)
        ws["A2"] = 5; ws["A3"] = true
        f = writeods(joinpath(dir, "derived.ods"), xf)
        lo_convert(f, "ods"; outdir = joinpath(dir, "lo"), profile = profile)
        r = openods(joinpath(dir, "lo", "derived.ods"))
        rs = r["S"]
        @test rs["A1"] == Date(2024, 1, 2) && rs["A2"] === Int64(5) && rs["A3"] === true
        for a in ("A1", "A2", "A3")
            @test isbold(cell_style(r.styles, style_id(r.styles, getcell(rs, a).style)))
        end
    end
end

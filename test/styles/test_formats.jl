# The formats layer (phase 4, step 3): formatted empty cells, column and row formats, read by
# a styles-only pass, and saved by patching (D-023) or with new sheets.

using OpenDocumentSpreadsheets: get_dimension, sheet_formats, effective_style, restyle_cells!, set_column_formats!, set_row_formats!, add_line_style!,
    line_props, PropSet, setprops, getprop, cell_style, add_cell_style!, with_text, style_id, style_name, getcell,
    _fmt_at, _cached_store, _stop, _lastrow, _lastcol, F_COVERED

ftmp(name) = joinpath(mktempdir(), name)
sty(ws) = OpenDocumentSpreadsheets.get_odsfile(ws).styles
fmt_bold(st) = add_cell_style!(st, with_text(CellStyle(), setprops(PropSet(), "fo:font-weight" => "bold")))
fmt_isbold(st, id) = getprop(cell_style(st, id).text, "fo:font-weight") == "bold"
table_xml(xf, k) = String(OpenDocumentSpreadsheets.XML.sourcetext(xf[k].entry.node))
using OpenDocumentSpreadsheets: CellStyle

# A sheet's look over rows 1:nr, columns 1:nc: the style each cell shows, the column and row
# formats (with names, so that sheets of different files compare), and the formatted empty
# cells that are covered or span.
function look(ws, nr, nc)
    st = sty(ws)
    f = sheet_formats(ws)
    name(id) = id < 0 ? "" : style_name(st, id)
    line(x) = x === nothing ? ("", "", "visible") : (x.style, name(x.default), x.visibility)
    cells = [style_name(st, effective_style(ws, r, c)) for r in 1:nr, c in 1:nc]
    cols = [line(_fmt_at(f.cols, c)) for c in 1:nc]
    rows = [line(_fmt_at(f.rows, r)) for r in 1:nr]
    # (an empty cell's explicit Default where nothing else is inherited says nothing: it may go)
    merged = [(d = OpenDocumentSpreadsheets._fmt_cell(f, r, c);
               d === nothing || (d.flags & F_COVERED == 0 && d.colspan == 1 && d.rowspan == 1) ? nothing :
               (d.flags & F_COVERED, d.colspan, d.rowspan)) for r in 1:nr, c in 1:nc]
    return (; cells, cols, rows, merged)
end
values_of(ws, nr, nc) = [ws[r, c] for r in 1:nr, c in 1:nc]

@testset "formats are read lazily" begin
    xf = openods(joinpath(DATA, "lo-scenarios.ods"))
    ws = xf["S05-styled-empty"]
    ws[:]
    @test ws.formats === nothing
    f = sheet_formats(ws)
    @test effective_style(ws, 20, 4) == style_id(xf.styles, "ce-fill")       # a styled empty cell
    @test effective_style(ws, 20, 3) == 0
    @test _fmt_at(f.cols, 2).style == "co1" && _fmt_at(f.rows, 5).style == "ro1"
    s4 = xf["S04-row-style"]
    @test effective_style(s4, 3, 9) == style_id(xf.styles, "ce-fill")
    @test effective_style(s4, 1, 2) == 0 && OpenDocumentSpreadsheets._fmt_cell(sheet_formats(s4), 1, 2).style == 0   # explicit Default
    s7 = xf["S07-row-heights"]
    @test [_fmt_at(sheet_formats(s7).rows, r).style for r in 1:4] == ["ro1", "ro2", "ro1", "ro1"]
    @test _fmt_at(sheet_formats(s7).rows, 3).visibility == "collapse"
    s9 = xf["S09-merge"]
    @test OpenDocumentSpreadsheets._fmt_cell(sheet_formats(s9), 2, 1).flags & F_COVERED != 0
    @test OpenDocumentSpreadsheets._fmt_cell(sheet_formats(s9), 1, 1) === nothing           # the anchor has a value
end

# Every row, column and cell of the grid marked as edited: the patcher writes them all from
# the model, which must give the same sheet back.
@testset "formats round trip through the patcher: $f" for f in ("lo-scenarios.ods", "lo-scenarios.fods", "lo-tables.ods", "lo-values.ods")
    src = joinpath(DATA, f)
    xf = openods(src; mode = "rw")
    nr, nc = 24, 6
    before = Dict{String,Any}()
    for ws in OpenDocumentSpreadsheets._sheets(xf)
        fm = sheet_formats(ws)
        before[ws.name] = (look(ws, nr, nc), values_of(ws, nr, nc), sort(string.(_cached_store(ws).merges)))
        fm.cols_touched = true
        push!(fm.rows_touched, 1:_stop(fm.rows[end]))
        push!(fm.rects, (1:nr, 1:nc))
    end
    p = writeods(ftmp("all" * splitext(f)[2]), xf)
    back = openods(p)
    for ws in OpenDocumentSpreadsheets._sheets(back)
        l, v, m = before[ws.name]
        @test look(ws, nr, nc) == l
        @test isequal(values_of(ws, nr, nc), v)
        @test sort(string.(_cached_store(ws).merges)) == m
    end
end

@testset "patched formats change nothing else (D-023)" begin
    src = joinpath(DATA, "lo-scenarios.ods")
    xf = openods(src; mode = "rw")
    st = xf.styles
    ws = xf["S05-styled-empty"]
    old = table_xml(xf, "S05-styled-empty")
    bd = fmt_bold(st)
    restyle_cells!(_ -> bd, ws, 2:2, 2:2)                     # an empty cell, in a repeated row
    p = writeods(ftmp("one.ods"), xf)
    back = openods(p)
    new = table_xml(back, "S05-styled-empty")
    r1 = findfirst("<table:table-row table:style-name=\"ro1\" table:number-rows-repeated=\"18\">", old)
    r3 = findlast("<table:table-row", old)
    @test style_name(st, bd) == "ce1"                         # the document's own bold style, shared
    @test new == old[1:first(r1)-1] *
        """<table:table-row table:style-name="ro1"><table:table-cell/><table:table-cell table:style-name="ce1"/><table:table-cell table:number-columns-repeated="2"/></table:table-row>""" *
        """<table:table-row table:style-name="ro1" table:number-rows-repeated="17"><table:table-cell table:number-columns-repeated="4"/></table:table-row>""" *
        old[first(r3):end]
    for k in 1:sheetcount(back)                               # the other sheets: byte for byte
        sheetnames(back)[k] == "S05-styled-empty" || @test table_xml(back, k) == table_xml(openods(src), k)
    end
    @test fmt_isbold(back.styles, effective_style(back["S05-styled-empty"], 2, 2))

    # a column style for column B, a row style for row 20
    xf = openods(src; mode = "rw")
    st = xf.styles
    ws = xf["S05-styled-empty"]
    co = add_line_style!(st, 1, PropSet(["style:column-width" => "3cm"], ""))
    ro = add_line_style!(st, 2, PropSet(["style:row-height" => "1cm", "style:use-optimal-row-height" => "false"], ""))
    @test co == "odsf-co1" && ro == "odsf-ro1" && add_line_style!(st, 1, PropSet(["style:column-width" => "3cm"], "")) == co
    @test add_line_style!(st, 1, line_props(st, 1, "co1")) == "co1"            # equal to the document's own
    set_column_formats!(ws, 2:2; style = co)
    set_row_formats!(ws, 20:20; style = ro)
    p = writeods(ftmp("lines.ods"), xf)
    back = openods(p)
    new = table_xml(back, "S05-styled-empty")
    @test occursin("""<table:table-column table:style-name="co1" table:default-cell-style-name="Default"/><table:table-column table:style-name="odsf-co1" table:default-cell-style-name="Default"/><table:table-column table:style-name="co1" table:default-cell-style-name="Default" table:number-columns-repeated="2"/>""", new)
    @test occursin("""<table:table-row table:style-name="odsf-ro1"><table:table-cell table:number-columns-repeated="3"/><table:table-cell table:style-name="ce-fill"/></table:table-row>""", new)
    @test replace(new, r"<table:table-column.*?<table:table-row"s => "", "odsf-ro1" => "ro1") ==
          replace(old, r"<table:table-column.*?<table:table-row"s => "")
    @test getprop(line_props(back.styles, 1, "odsf-co1"), "style:column-width") == "3cm"
    @test getprop(line_props(back.styles, 2, "odsf-ro1"), "style:row-height") == "1cm"
    # a row whose attributes are touched but end up the same is written as it was
    xf = openods(src; mode = "rw")
    ws = xf["S07-row-heights"]
    set_row_formats!(ws, 2:3; style = "ro2")
    set_row_formats!(ws, 3:3; style = "ro1")
    new = table_xml(openods(writeods(ftmp("same.ods"), xf)), "S07-row-heights")
    @test new == table_xml(openods(src), "S07-row-heights")
    # rows made to cover more columns, so that column defaults reach them (F-035): an
    # original row gains cells; new rows are written with them
    xf = openods(src; mode = "rw")
    s7 = xf["S07-row-heights"]
    set_row_formats!(s7, 2:2; cover = 3)
    s3 = xf["S03b-col-style-cells"]
    cd = _fmt_at(sheet_formats(s3).cols, 2).default
    @test effective_style(s3, 4, 2) == 0
    set_row_formats!(s3, 2:5; cover = 2)
    @test effective_style(s3, 4, 2) == cd
    back = openods(writeods(ftmp("cover.ods"), xf))
    b7 = back["S07-row-heights"]
    @test [_fmt_at(sheet_formats(b7).rows, r).ncells for r in 1:4] == [1, 3, 1, 1]
    @test [b7[r, 1] for r in 1:4] == [1, 2, 3, 4] && _fmt_at(sheet_formats(b7).rows, 2).style == "ro2"
    @test effective_style(back["S03b-col-style-cells"], 4, 2) == cd && effective_style(back["S03b-col-style-cells"], 6, 2) == 0
end

@testset "restyling blocks: the style each cell shows" begin
    xf = newods()
    ws = xf[1]; st = xf.styles
    ws["A1"] = 1; ws["C2"] = "x"
    X = fmt_bold(st)
    Y = add_cell_style!(st, with_text(CellStyle(), setprops(PropSet(), "fo:color" => "#ff0000")))
    set_column_formats!(ws, 3:3; default = X)
    @test effective_style(ws, 5, 3) == 0                      # no row writes column C yet (F-035)
    set_row_formats!(ws, 1:9; cover = 3)
    @test effective_style(ws, 5, 3) == X && effective_style(ws, 10, 3) == 0 && effective_style(ws, 5, 1) == 0
    restyle_cells!(_ -> Y, ws, 4:4, 1:OpenDocumentSpreadsheets.SheetCore.MAX_COLS)   # a whole row, as LibreOffice formats one
    @test effective_style(ws, 4, 3) == Y && effective_style(ws, 4, 16384) == Y
    seen = Int32[]
    Z = add_cell_style!(st, with_text(CellStyle(), setprops(PropSet(), "fo:font-style" => "italic")))
    restyle_cells!(ws, 1:5, 1:4) do s
        push!(seen, s)
        s == 0 ? Z : s
    end
    @test sort(seen) == sort([0, X, Y])                       # once per style shown
    @test effective_style(ws, 1, 1) == Z && effective_style(ws, 2, 3) == Z && effective_style(ws, 4, 2) == Y
    @test effective_style(ws, 6, 1) == 0 && effective_style(ws, 6, 3) == X
    @test ws["A1"] === Int64(1) && get_dimension(ws) == OpenDocumentSpreadsheets.CellRange("A1:C2")   # empty cells are not content
    # a value written into a formatted empty cell keeps its style (D-038)
    ws["D5"] = 2
    @test getcell(ws, "D5").style == style_name(st, Z)
    ws["E4"] = 3                                               # outside the block: row 4's own style
    @test getcell(ws, "E4").style == style_name(st, Y)
    ws["E5"] = 3
    @test getcell(ws, "E5").style == "Default"
    ws["C9"] = 4                                               # the column default
    @test getcell(ws, "C9").style == style_name(st, X)
    # a removed value keeps its style
    ws["A1"] = missing
    @test effective_style(ws, 1, 1) == Z
    p = writeods(ftmp("new.ods"), xf)
    back = openods(p)
    @test look(back[1], 9, 5) == look(ws, 9, 5)
    @test isequal(values_of(back[1], 9, 5), values_of(ws, 9, 5))
end

@testset "new sheets write column and row formats" begin
    xf = newods("F")
    ws = xf["F"]; st = xf.styles
    ws["A1"] = 1
    co = add_line_style!(st, 1, PropSet(["style:column-width" => "4cm"], ""))
    ro = add_line_style!(st, 2, PropSet(["style:row-height" => "1.5cm", "style:use-optimal-row-height" => "false"], ""))
    set_column_formats!(ws, 2:3; style = co)
    set_column_formats!(ws, 3:3; visibility = "collapse")
    set_row_formats!(ws, 3:3; style = ro)
    restyle_cells!(_ -> fmt_bold(st), ws, 5:6, 1:2)
    for fmt in ("ods", "fods")
        back = openods(writeods(ftmp("f.$fmt"), xf))
        bs = back["F"]
        bf = sheet_formats(bs)
        @test _fmt_at(bf.cols, 2).style == "odsf-co1" && _fmt_at(bf.cols, 3).visibility == "collapse"
        @test _fmt_at(bf.rows, 3).style == "odsf-ro1" && _fmt_at(bf.rows, 4) !== nothing
        @test fmt_isbold(back.styles, effective_style(bs, 6, 2)) && effective_style(bs, 6, 3) == 0
        @test bs["A1"] === Int64(1) && get_dimension(bs) == OpenDocumentSpreadsheets.CellRange("A1:A1")
        @test getprop(line_props(back.styles, 1, "odsf-co1"), "style:column-width") == "4cm"
    end
    # a new sheet without formats is written as before
    xf2 = newods(); xf2[1]["B2"] = 1
    io = IOBuffer(); OpenDocumentSpreadsheets.write_table(io, xf2[1])
    @test String(take!(io)) == """<table:table table:name="Sheet1"><table:table-column table:number-columns-repeated="2"/><table:table-row><table:table-cell/></table:table-row><table:table-row><table:table-cell/><table:table-cell office:value-type="float" office:value="1"><text:p>1</text:p></table:table-cell></table:table-row></table:table>"""
end

@testset "values and removals in read sheets keep formats" begin
    src = joinpath(DATA, "lo-scenarios.ods")
    xf = openods(src; mode = "rw")
    ws = xf["S05-styled-empty"]
    ws["D20"] = 5                                   # a styled empty cell: its style is kept (D-038)
    @test getcell(ws, "D20").style == "ce-fill"
    s3 = xf["S03c-col-style-allrows"]
    cd = _fmt_at(sheet_formats(s3).cols, 2).default
    @test cd > 0
    s3["B7"] = 1                                    # under a column default, in a row that reaches it
    @test getcell(s3, "B7").style == style_name(xf.styles, cd)
    s3b = xf["S03b-col-style-cells"]
    s3b["B7"] = 1                                   # past the table's rows: the column default doesn't reach (F-035)
    @test getcell(s3b, "B7").style == "Default"
    back = openods(writeods(ftmp("kept.ods"), xf))
    @test getcell(back["S05-styled-empty"], "D20").style == "ce-fill" && back["S05-styled-empty"]["D20"] === Int64(5)
    @test getcell(back["S03c-col-style-allrows"], "B7").style == style_name(back.styles, cd)
@test effective_style(back["S03b-col-style-cells"], 7, 2) == 0
    # a styled value removed before the formats are read keeps its style too
    xf = openods(src; mode = "rw")
    s12 = xf["S12-types"]
    c = first(OpenDocumentSpreadsheets.CellRef(r, cc) for r in 1:5, cc in 1:5 if !ismissing(s12[r, cc]) && getcell(s12, OpenDocumentSpreadsheets.CellRef(r, cc)).style != "Default")
    style = getcell(s12, c).style
    s12[c] = missing
    @test s12.formats === nothing
    back = openods(writeods(ftmp("removed.ods"), xf))
    @test ismissing(back["S12-types"][c]) && style_name(back.styles, effective_style(back["S12-types"], row_number(c), column_number(c))) == style
end

@testset "LibreOffice keeps the formats" begin
    if isempty(SOFFICE) || !isfile(SOFFICE)
        @info "LibreOffice not found; skipping the formats oracle (set ODS_SOFFICE)"
        @test_skip false
    else
        dir = mktempdir()
        profile = lo_profile_url(joinpath(dir, "lo-profile"))
        # a new file, and a patched one
        xf = newods("N")
        ws = xf["N"]; st = xf.styles
        ws["A1"] = 1
        co = add_line_style!(st, 1, PropSet(["style:column-width" => "4cm"], ""))
        ro = add_line_style!(st, 2, PropSet(["style:row-height" => "1.5cm", "style:use-optimal-row-height" => "false"], ""))
        set_column_formats!(ws, 2:2; style = co)
        set_row_formats!(ws, 3:3; style = ro)
        restyle_cells!(_ -> fmt_bold(st), ws, 2:3, 1:2)
        f1 = writeods(joinpath(dir, "new.ods"), xf)
        xf = openods(joinpath(DATA, "lo-scenarios.ods"); mode = "rw")
        ws = xf["S05-styled-empty"]; st = xf.styles
        set_column_formats!(ws, 2:2; style = add_line_style!(st, 1, PropSet(["style:column-width" => "4cm"], "")))
        restyle_cells!(_ -> fmt_bold(st), ws, 2:3, 1:2)
        ws["B3"] = "x"
        f2 = writeods(joinpath(dir, "patched.ods"), xf)
        run(pipeline(`$SOFFICE -env:UserInstallation=$profile --headless --norestore --convert-to ods --outdir $(joinpath(dir, "lo")) $f1 $f2`;
                     stdout = devnull, stderr = devnull))
        cm(s) = endswith(s, "cm") ? parse(Float64, s[1:end-2]) : endswith(s, "in") ? 2.54 * parse(Float64, s[1:end-2]) :
                endswith(s, "mm") ? parse(Float64, s[1:end-2]) / 10 : NaN
        for (file, sheet) in (("new.ods", "N"), ("patched.ods", "S05-styled-empty"))
            r = openods(joinpath(dir, "lo", file))
            rs = r[sheet]
            rf = sheet_formats(rs)
            @test all(fmt_isbold(r.styles, effective_style(rs, i, j)) for i in 2:3, j in 1:2)
            @test !fmt_isbold(r.styles, effective_style(rs, 4, 1))
            @test cm(getprop(line_props(r.styles, 1, _fmt_at(rf.cols, 2).style), "style:column-width")) ≈ 4 atol = 0.01
            file == "new.ods" &&
                @test cm(getprop(line_props(r.styles, 2, _fmt_at(rf.rows, 3).style), "style:row-height")) ≈ 1.5 atol = 0.01
            file == "patched.ods" && @test rs["B3"] == "x" && rs["A1"] === Int64(1) && rs["D20"] === missing
        end
    end
end

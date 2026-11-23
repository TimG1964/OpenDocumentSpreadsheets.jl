# The byte scanner (D-047): the same rows, columns and merges as the XML.jl cursor walk, on
# every test file and on sheets written in each shape the scanner treats specially; the
# prefix read's walk to a sheet's end; batched table columns.
# Needs `fods`/`open_fods` from model/test_values.jl.

using OpenDocumentSpreadsheets: SheetReader, next_row!, RowData, _SCAN, _SCAN_CELL_FALLBACKS, _SheetFinder, _find_sheet_end!

# (rows, cols, merges) of a sheet read with or without the scanner
function _sheet_read(ws, scan; kw...)
    r = SheetReader(ws.entry.node, OpenDocumentSpreadsheets.get_odsfile(ws).styles; scan, kw...)
    rows = RowData[]
    while (rd = next_row!(r)) !== nothing
        push!(rows, rd)
    end
    return rows, r.cols, r.merges
end
_same_rows(a::RowData, b::RowData) = a.row == b.row && a.count == b.count &&
    length(a.runs) == length(b.runs) && all(x.col == y.col && x.count == y.count && x.data == y.data for (x, y) in zip(a.runs, b.runs))
function _same_read(ws; kw...)
    a = _sheet_read(ws, true; kw...)
    b = _sheet_read(ws, false; kw...)
    return length(a[1]) == length(b[1]) && all(_same_rows.(a[1], b[1])) && a[2] == b[2] && a[3] == b[3]
end

@testset "scanner = cursor on every test file" begin
    # LibreOffice's own files (zipped and flat) and OpenDocumentSpreadsheets's; the shapes below cover the rest
    files = [joinpath(DATA, f) for f in readdir(DATA) if endswith(f, ".ods") || endswith(f, ".fods") || endswith(f, ".ots")]
    @test length(files) >= 8
    n = 0
    for f in files
        xf = openods(f; enable_cache = false)
        for i in 1:sheetcount(xf)
            ws = xf[i]
            ws.entry === nothing && continue
            @test _same_read(ws)
            @test _same_read(ws; skip_before = 3, stop_after = 7)
            n += 1
        end
    end
    @test n > 50
end

_sheet(rows; cols = "") = "<table:table table:name=\"S\">$cols$rows</table:table>"
_cell(attrs, body = "") = isempty(body) ? "<table:table-cell $attrs/>" : "<table:table-cell $attrs>$body</table:table-cell>"
_str(body) = _cell("office:value-type=\"string\"", body)

# the scanner's result, checked against the cursor walk; also returns the cell fallbacks it took
function _scan_check(body)
    ws = open_fods(body; cache = false)[1]
    before = _SCAN_CELL_FALLBACKS[]
    ok = _same_read(ws) && _same_read(ws; skip_before = 2, stop_after = 3)
    return ok, _SCAN_CELL_FALLBACKS[] - before
end

@testset "scanner shapes" begin
    row(cells...) = "<table:table-row>" * join(cells) * "</table:table-row>"
    float(x) = _cell("office:value-type=\"float\" office:value=\"$x\"", "<text:p>$x</text:p>")
    # plain shapes: no fallback
    for body in [
            _sheet(row(float(1), _str("<text:p>a</text:p>"), float(2.5))),
            _sheet(row(_str("<text:p>R&amp;D &#x41;&#66; &lt;x&gt;</text:p>"))),             # references
            _sheet(row(_str("<text:p>one</text:p><text:p/><text:h>three</text:h>"))),         # paragraphs
            _sheet(row(_str("<text:p> </text:p>"), _str("<text:p>  x  </text:p>"))),          # white space kept
            _sheet(row(_str("<text:p>a\r\nb</text:p>"), _str("<text:p>c\rd</text:p>"))),       # line ends
            _sheet(row(_cell("office:value-type='string' office:string-value='s&apos;v'"))),  # single quotes
            _sheet(row(_cell("table:formula=\"of:=IF([.A1]&lt;3;&quot;x&quot;;&quot;y&quot;)\" office:value-type=\"string\"", "<text:p>x</text:p>"))),
            _sheet(row(_str("<office:annotation><text:p>note</text:p></office:annotation><text:p>v</text:p>"))),
            _sheet(row(_str("<!-- c --><text:p>v</text:p><?pi x?>"))),                         # comment, PI in a cell
            _sheet("<table:table-header-rows>" * row(float(1)) * "</table:table-header-rows>" *
                   "<table:table-row-group><table:table-rows>" * row(float(2)) * "</table:table-rows></table:table-row-group>";
                   cols = "<table:table-column-group><table:table-header-columns><table:table-column table:number-columns-repeated=\"2\"/></table:table-header-columns></table:table-column-group>"),
            _sheet("\n  " * replace(row(float(1), "\n    ", float(2)), "<table:table-cell" => "\n   <table:table-cell") * "\n"),  # pretty-printed
            _sheet(row(_cell("table:number-columns-spanned=\"2\" table:number-rows-spanned=\"2\" office:value-type=\"float\" office:value=\"1\""),
                       "<table:covered-table-cell office:value-type=\"float\" office:value=\"9\"/>") * row("<table:covered-table-cell table:number-columns-repeated=\"2\"/>")),
            _sheet(row(float(1)) * "<table:table-row table:number-rows-repeated=\"3\">" * float(2) * "</table:table-row>" * row(float(3))),
            _sheet("<table:shapes><draw:frame><draw:text-box><text:p>x &gt; y</text:p></draw:text-box></draw:frame></table:shapes>" * row(float(1))),
            _sheet(row(_cell("office:value-type=\"boolean\" office:boolean-value=\"true\""), _cell("office:value-type=\"date\" office:date-value=\"2024-02-29T12:00:00\""),
                       _cell("office:value-type=\"time\" office:time-value=\"PT36H\""), _cell("office:value-type=\"percentage\" office:value=\"0.5\""),
                       _cell("office:value-type=\"currency\" office:currency=\"EUR\" office:value=\"3\""),
                       _cell("table:formula=\"of:=1/0\" office:value-type=\"float\" office:value=\"0\" calcext:value-type=\"error\"", "<text:p>#DIV/0!</text:p>"))),
            "<table:table table:name=\"S\"/>",
            "<table:table table:name=\"S\"></table:table>",
            _sheet(row()) * _sheet(row(float(1))),
        ]
        ok, fb = _scan_check(body)
        @test ok
        @test fb == 0
    end
    # cells read by XML.jl: markup in a paragraph, CDATA, a normalized attribute
    for body in [
            _sheet(row(_str("<text:p>a<text:s text:c=\"2\"/>b</text:p>"), float(1))),
            _sheet(row(_str("<text:p>a<text:span>b</text:span></text:p>"))),
            _sheet(row(_str("<text:p><![CDATA[a<b]]></text:p>"))),
            _sheet(row(_str("<text:p>a<!-- c -->b</text:p>"))),
            _sheet(row(_cell("office:value-type=\"string\" office:string-value=\"a\tb\nc\""))),
        ]
        ok, fb = _scan_check(body)
        @test ok
        @test fb > 0
    end
    # rows the scanner leaves to the cursor walk from where it stopped
    for body in [
            _sheet(row(float(1)) * "<table:table-row table:number-rows-repeated=\"2\n\">" * float(2) * "</table:table-row>" * row(float(3))),
            _sheet(row(float(1)) * row(float(2)); cols = "<table:table-column table:number-columns-repeated=\"\t3\"/>"),
            _sheet(row(_cell("table:number-columns-spanned=\"2\" office:value-type=\"float\" office:value=\"1\"")) *
                   "<table:table-row table:default-cell-style-name=\"a\nb\">" * float(2) * "</table:table-row>"),
        ]
        ok, _ = _scan_check(body)
        @test ok
    end
    # values as XML.jl reports them
    xf = open_fods(_sheet(row(_str("<text:p>R&amp;D &#x41;</text:p>"), _str("<text:p>a<text:s text:c=\"2\"/>b</text:p>"),
                              _cell("office:value-type=\"string\" office:string-value=\"a\tb\"")) *
                          "<table:table-row table:number-rows-repeated=\"2\n\">" * float(2) * "</table:table-row>"); cache = false)
    @test xf[1]["A1"] == "R&D A" && xf[1]["B1"] == "a  b" && xf[1]["C1"] == "a b" && xf[1]["A2"] == 2 && xf[1]["A3"] == 2
    @test _SCAN[]
end

@testset "prefix read: the walk to a sheet's end" begin
    doc(sheets) = Vector{UInt8}("<?xml version=\"1.0\"?><office:document-content><office:body><office:spreadsheet>" *
                                sheets * "<table:named-expressions/></office:spreadsheet></office:body></office:document-content>")
    t(name, inner) = "<table:table table:name=\"$name\">$inner</table:table>"
    rowc(x) = "<table:table-row><table:table-cell><text:p>$x</text:p></table:table-cell></table:table-row>"
    sub = "<table:table-row><table:table-cell><table:table table:is-sub-table=\"true\">" * rowc("in") * "</table:table></table:table-cell></table:table-row>"
    cases = [
        (t("A", rowc(1)) * t("B", rowc(2)), "A", "B"),
        (t("A", rowc(1)) * t("B", rowc(2)), 2, "named"),
        (t("A", sub * rowc(1)) * t("B", rowc(2)), "A", "B"),                          # a table in the sheet
        (t("A", "<!-- </table:table> -->" * rowc(1)) * t("B", rowc(2)), 1, "B"),      # a fake end in a comment
        (t("A", "<table:table-row><table:table-cell><text:p><![CDATA[</table:table>]]></text:p></table:table-cell></table:table-row>") * t("B", ""), "A", "B"),
        (t("A", "<?x </table:table> ?>" * rowc(1)) * t("B", rowc(2)), "A", "B"),
        ("<table:table table:name=\"A\"/>" * t("B", rowc(2)), "A", "B"),
        (t("A &amp; B", rowc(1)) * t("C", rowc(2)), "A & B", "C"),
    ]
    for (sheets, want, after) in cases
        data = doc(sheets)
        full = String(copy(data))
        endpos = nothing
        # fed whole, and fed in pieces split at every byte
        for step in (length(data), 1, 7)
            f = want isa Integer ? _SheetFinder(nothing, want, 1, 0, 0, false) : _SheetFinder(want, 0, 1, 0, 0, false)
            got = nothing
            for n in step:step:length(data)+step-1
                got = _find_sheet_end!(f, data, min(n, length(data)))
                got === nothing || break
            end
            @test got !== nothing
            endpos === nothing ? (endpos = got) : @test(got == endpos)
        end
        pre = full[1:endpos]
        @test endswith(pre, "/>") || endswith(pre, "</table:table>")
        @test !occursin(after, pre)
        @test occursin(after, full[endpos+1:end])
    end
    # a sheet not found: nothing (the whole part is read)
    f = _SheetFinder("Z", 0, 1, 0, 0, false)
    d = doc(t("A", rowc(1)))
    @test _find_sheet_end!(f, d, length(d)) === nothing
end

@testset "readtable through the prefix, with a table in the sheet" begin
    # a sheet holding a sub-table, in a zipped package so that readtable reads a prefix
    body = _sheet("<table:table-row>" * _str("<text:p>h</text:p>") * "</table:table-row>" *
                  "<table:table-row>" * _cell("office:value-type=\"float\" office:value=\"1\"",
                      "<table:table table:name=\"inner\"><table:table-row>" * _str("<text:p>x</text:p>") * "</table:table-row></table:table>") *
                  "</table:table-row><table:table-row>" * _cell("office:value-type=\"float\" office:value=\"2\"") * "</table:table-row>") *
           "<table:table table:name=\"T2\"><table:table-row>" * _str("<text:p>z</text:p>") * "</table:table-row></table:table>"
    content = replace(fods(body), "<office:document " => "<office:document-content ", "</office:document>" => "</office:document-content>")
    p = OpenDocumentSpreadsheets.write_package(joinpath(mktempdir(), "sub.ods"), [OpenDocumentSpreadsheets.PackagePart("content.xml", content)])
    @test isequal(readtable(p, "S").data, gettable(readods(p)["S"]).data)
    @test readtable(p, "S").data == [[1, 2]]
    @test readtable(p, "T2").column_labels == [:z]
end

@testset "gettable in batches = row by row" begin
    # more rows than a batch, columns that widen mid-batch and across batches
    n = 3 * OpenDocumentSpreadsheets.SheetCore._TABLE_BATCH + 17
    a = Any[i == 300 ? "s" : i for i in 1:n]
    b = Any[i % 2 == 0 ? 1.5 : (i == 600 ? missing : i) for i in 1:n]
    c = Any[i > 700 ? true : missing for i in 1:n]
    p = writetable(joinpath(mktempdir(), "b.ods"), [a, b, c], ["a", "b", "c"])
    t1 = readtable(p, 1)
    t2 = gettable(readods(p)[1])
    @test isequal(t1.data, t2.data) && eltype.(t1.data) == eltype.(t2.data)
    rows = collect(eachtablerow(readods(p)[1]))              # the row-by-row iterator
    @test all(isequal(t1.data[j][i], rows[i][j]) for i in 1:n, j in 1:3)
    @test isequal(t1.data[3][1], missing) && t1.data[3][n] === true
end

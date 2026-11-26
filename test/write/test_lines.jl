# Inserting and deleting rows and columns (phase 5 step 3; D-050 to D-052): the model, the patched
# save, and LibreOffice's results (experiment 021, test/data/shift/). Uses `load_oracle`, `cellpos`,
# `lineop` and `cf_meaning` from test/oracle_refs.jl.

using OpenDocumentSpreadsheets: IndexMap, insert_lines!, delete_lines!, current_line, line_pieces, getFormula, _sheets,
    _cached_store, sheet_formats, _fmt_at, _fmt_cell, effective_style, style_name, getMergedCells,
    open_container, read_xml, read_bytes, getFont, getColumnWidth, ODSError, sheetcount

@testset "IndexMap" begin
    m = IndexMap(20)
    insert_lines!(m, 5, 2)                 # 5,6 new; old 5 → 7
    @test current_line(m, 4) == 4 && current_line(m, 5) == 7 && current_line(m, 18) == 20 && current_line(m, 19) == 0
    delete_lines!(m, 10, 12)               # current 10:12 = old 8:10
    @test current_line(m, 8) == 0 && current_line(m, 10) == 0 && current_line(m, 11) == 10
    @test line_pieces(m, 1, 20) == [(1, 4, 1), (5, 3, 7), (11, 8, 10)]
end

# A small sheet: values 10r+c in A1:D6, a formula, a merge, a name, a bold row and a wide column.
function lines_sheet()
    xf = newods("S")
    ws = xf["S"]
    for r in 1:6, c in 1:4
        ws[r, c] = 10r + c
    end
    setFormula(ws, "F1"; val = "=SUM(A2:A5)+B3")
    setFormula(ws, "F2"; val = "=SUM(A:A)+SUM(2:2)")
    mergeCells(ws, "B5:C6")
    setFont(ws, "A3:D3"; bold = true)
    setColumnWidth(ws, "B"; width = 30)
    return xf, ws
end

@testset "insert and delete: the model" begin
    xf, ws = lines_sheet()
    insertRows(ws, 3; count = 2)
    @test ws["A3"] === missing && ws["A5"] == 31 && ws["D8"] == 64
    @test getFormula(ws, "F1") == "=SUM(A2:A7)+B5"
    @test getFormula(ws, "F2") == "=SUM(A:A)+SUM(2:2)"
    @test getMergedCells(ws) == [OpenDocumentSpreadsheets.CellRange("B7:C8")]
    # the new rows take the bold of the row above (row 2 is plain; row 3 the inserted one)
    xf2, ws2 = lines_sheet()
    insertRows(ws2, 4)
    @test haskey(getFont(ws2, "A4").font, "b") && haskey(getFont(ws2, "D4").font, "b")
    @test !haskey(getFont(ws2, "A5").font, "b")
    deleteRows(ws, "3:4")
    @test ws["A3"] == 31 && getFormula(ws, "F1") == "=SUM(A2:A5)+B3"
    insertColumns(ws, "B")
    @test ws["C1"] == 12 && ws["B1"] === missing && getFormula(ws, "G1") == "=SUM(A2:A5)+C3"
    @test getColumnWidth(ws, "B1") ≈ getColumnWidth(ws, "C1")             # the pushed column's width
    deleteColumns(ws, 2:3)
    @test ws["B1"] == 13 && getFormula(ws, "E1") == "=SUM(A2:A5)+#REF!"
    @test getMergedCells(ws) === nothing                                 # its anchor column went
    @test ws["B5"] === missing && ws["C5"] == 54 && !isMergedCell(ws, "B5")   # the covered cell is uncovered
    # argument forms
    xf, ws = lines_sheet()
    deleteRows(ws, "2,4:5")
    @test ws["A2"] == 31 && ws["A3"] == 61
    xf, ws = lines_sheet()
    deleteRows(xf, "S.1:2"); @test ws["A1"] == 31
    deleteColumns(xf, "S!A"); @test ws["A1"] == 32
    insertRows(xf, "S.1"; count = 3); @test ws["A4"] == 32
    insertColumns(ws, 1; count = 2); @test ws["C4"] == 32
    deleteColumns(ws, [1, 2]); @test ws["A4"] == 32
    deleteRows(ws, OpenDocumentSpreadsheets.CellRef("A1")); @test ws["A3"] == 32
    # errors
    @test_throws ODSError insertRows(ws, 0)
    @test_throws ODSError insertRows(ws, 1; count = 0)
    @test_throws ODSError deleteColumns(ws, "1")
    @test_throws ODSError deleteRows(ws, "nosuchname")
    @test_throws ODSError insertRows(xf, "Nope.1")
    r = readods(joinpath(DATA, "lo-tables.ods"))
    @test_throws ODSError insertRows(r[1], 1)
end

@testset "insert into a full sheet (D-052)" begin
    xf = newods(); ws = xf[1]
    ws["A1048575"] = 1
    @test_throws ODSError insertRows(ws, 1; count = 2)
    insertRows(ws, 1)                                     # 1048575 → 1048576: still on the sheet
    @test ws["A1048576"] == 1
    xf = newods(); ws = xf[1]
    ws["XFD1"] = 1
    @test_throws ODSError insertColumns(ws, "A")
    xf = newods(); ws = xf[1]
    setFill(ws, "XFD5"; pattern = "solid", fgColor = "FFFF0000")    # a fill alone: lost entirely
    @test_throws ODSError insertColumns(ws, "A")
    xf = newods(); ws = xf[1]
    setFont(ws, "5:5"; bold = true)                      # a whole row: only cut short (F-046)
    insertColumns(ws, "A")
    @test haskey(getFont(ws, "XFD5").font, "b")
end

# The references of a saved document, keyed as experiment 021 keys them (formulas by their N("key")
# marker, with the cell they are in; other elements by name or order), in every content part.
function saved_refs(path; keysheet::Bool = false)
    c = open_container(path)
    xmls = [read_xml(c, :content)]
    if c.zip !== nothing
        for n in OpenDocumentSpreadsheets.partnames(c)
            (endswith(n, "/content.xml") && n != "content.xml") && push!(xmls, String(read_bytes(c, n)))
        end
    end
    items = Dict{Tuple{String,String},String}()
    ord = Dict{String,Int}()
    for (i, x) in enumerate(xmls)
        doc = XML.read(IOBuffer(x), XML.Node)
        walk_refs!(items, ord, doc, "", Ref(0), Ref(0), i > 1; keysheet)       # embedded objects' parts
    end
    return items
end

const _KEEP = ("table:formula", "table:expression", "table:condition", "table:cell-range-address", "table:base-cell-address",
               "table:target-range-address", "table:print-ranges", "table:end-cell-address", "chart:values-cell-range-address",
               "chart:label-cell-address", "calcext:value", "calcext:base-cell-address", "calcext:target-range-address")

function walk_refs!(items, ord, n, sheet, row, col, inobj; keysheet::Bool = false)
    rec(c) = walk_refs!(items, ord, c, sheet, row, col, inobj; keysheet)
    XML.nodetype(n) === XML.Element || (foreach(rec, something(XML.children(n), [])); return)
    t = XML.tag(n)
    a = something(XML.attributes(n), Dict{String,String}())
    kids = something(XML.children(n), [])
    if t == "table:table"
        sheet = a["table:name"]; row = Ref(0)
    elseif t == "table:table-row" && !inobj
        r0 = row[] + 1; col[] = 0; row[] = r0
        foreach(rec, kids)
        row[] = r0 + parse(Int, get(a, "table:number-rows-repeated", "1")) - 1
        return
    elseif (t == "table:table-cell" || t == "table:covered-table-cell") && !inobj
        col[] += 1
        if haskey(a, "table:formula")
            m = match(r"N\(\"(\w+)\"\)", a["table:formula"])
            k = m === nothing ? "cell:$(sheet)!R$(row[])C$(col[])" : "formula:" * m.captures[1] * (keysheet ? "@" * sheet : "")
            items[(k, "table:formula")] = a["table:formula"]
            items[(k, "@cell")] = "$(sheet)!R$(row[])C$(col[])"
        end
        foreach(rec, kids)
        col[] += parse(Int, get(a, "table:number-columns-repeated", "1")) - 1
        return
    end
    hits = [(k, v) for (k, v) in a if k in _KEEP && k != "table:formula"]
    if !isempty(hits)
        name = get(a, "table:name", get(a, "draw:name", nothing))
        name === nothing && (ord[t] = get(ord, t, 0) + 1; name = "#" * string(ord[t]))
        for (k, v) in hits
            items[("$t[$name]" * (inobj ? "(in object)" : ""), k)] = v
        end
    end
    # a chart embedded in a flat file: what is inside draw:object is the object's
    t == "draw:object" ? foreach(c -> walk_refs!(items, ord, c, sheet, row, col, true; keysheet), kids) : foreach(rec, kids)
end

# Applies an operation of the oracle (its name: "ins_r5_1", "del_other_c2_3", …) through the API.
function apply_op!(xf, name)
    op = lineop(name, ["Data", "Other", "My Sheet", "Z"])
    ws = xf[op.sheet]
    n = abs(op.n)
    if op.axis == 1
        op.n > 0 ? insertRows(ws, op.at; count = n) : deleteRows(ws, op.at:op.at+n-1)
    else
        op.n > 0 ? insertColumns(ws, op.at; count = n) : deleteColumns(ws, op.at:op.at+n-1)
    end
end

# What LibreOffice does that OpenDocumentSpreadsheets doesn't (yet): it drops validations no cell uses any more
# (they stay, unused, in OpenDocumentSpreadsheets' file), and it moves shapes anchored in a deleted cell to the
# next cell (phase 6: OpenDocumentSpreadsheets deletes them with their cell).
_known_gap(k) = startswith(k, "table:content-validation") || startswith(k, "draw:rect")

const SHIFT_OPS = [String(split(l, '\t')[1]) for l in eachline(joinpath(SHIFT, "lo-shift-ops.tsv"))]

@testset "the model after LibreOffice's operations (experiment 021)" begin
    o = load_oracle(joinpath(SHIFT, "lo-shift-refs.tsv"))
    fails = String[]
    n = 0
    for name in SHIFT_OPS
        xf = openods(joinpath(SHIFT, "lo-shift-before.fods"); mode = "rw")
        apply_op!(xf, name)
        after = o[name]
        got = Dict{String,Tuple{String,String}}()
        for ws in _sheets(xf), rd in _cached_store(ws).rows, r in rd.runs
            f = r.data.formula
            f === nothing && continue
            m = match(r"N\(\"(\w+)\"\)", f)
            m === nothing || (got["formula:" * m.captures[1]] = (f, "$(ws.name)!R$(rd.row)C$(r.col)"))
        end
        for ((k, a), v) in after
            (a == "table:formula" && startswith(k, "formula:")) || continue
            n += 1
            g = get(got, k, nothing)
            g == (v, after[(k, "@cell")]) || push!(fails, "$name $k: OpenDocumentSpreadsheets $g, LibreOffice ($v, $(after[(k, "@cell")]))")
        end
        for k in keys(got)
            haskey(after, (k, "table:formula")) || push!(fails, "$name $k: kept by OpenDocumentSpreadsheets, gone in LibreOffice")
        end
        for dn in xf.names, (a, v) in (("table:cell-range-address", dn.range), ("table:expression", dn.expression),
                                       ("table:base-cell-address", dn.base))
            v === nothing && continue
            want = get(after, ((dn.range === nothing ? "table:named-expression[" : "table:named-range[") * dn.name * "]", a), nothing)
            want === nothing && continue
            n += 1
            want == v || push!(fails, "$name name $(dn.name) $a: OpenDocumentSpreadsheets $v, LibreOffice $want")
        end
    end
    isempty(fails) || foreach(println, fails)
    @test isempty(fails)
    @test n > 1500
end

@testset "patched saves after LibreOffice's operations (experiment 021)" begin
    o = load_oracle(joinpath(SHIFT, "lo-shift-refs.tsv"))
    dir = mktempdir()
    fails = String[]
    n = 0
    for name in SHIFT_OPS
        xf = openods(joinpath(SHIFT, "lo-shift-before.fods"); mode = "rw")
        apply_op!(xf, name)
        path = writeods(joinpath(dir, name * ".fods"), xf)
        got = saved_refs(path)
        want = o[name]
        for ((k, a), v) in want
            (a == "@value" || _known_gap(k) || a == "draw:notify-on-update-of-ranges" || startswith(k, "calcext:condition[") ||
             startswith(k, "style:map") || startswith(k, "chart:chart") || startswith(k, "text:a")) && continue
            n += 1
            g = get(got, (k, a), "(none)")
            g == v || push!(fails, "$name $k $a: OpenDocumentSpreadsheets `$g`, LibreOffice `$v`")
        end
        for (k, a) in keys(got)
            (_known_gap(k) || startswith(k, "calcext:condition[") || haskey(want, (k, a))) && continue
            push!(fails, "$name $k $a: only in OpenDocumentSpreadsheets' file")
        end
        # the conditional format, by meaning (LibreOffice re-bases it on every save, F-044)
        tk = ("calcext:conditional-format[#1]", "calcext:target-range-address")
        if haskey(want, tk)
            ck = "calcext:condition[#1]"
            n += 1
            cf_meaning(got[(ck, "calcext:value")], got[(ck, "calcext:base-cell-address")], got[tk]) ==
                cf_meaning(want[(ck, "calcext:value")], want[(ck, "calcext:base-cell-address")], want[tk]) ||
                push!(fails, "$name conditional format: OpenDocumentSpreadsheets $(got[(ck, "calcext:value")]) @ $(got[(ck, "calcext:base-cell-address")])")
        end
        # the file reads back with the same values as the model
        back = readods(path)
        @test isequal(back["Data"][:], xf["Data"][:])
    end
    isempty(fails) || foreach(println, fails)
    @test isempty(fails)
    @test n > 3000
end

@testset "a patched save keeps what the operation doesn't touch (D-023)" begin
    src = read(joinpath(SHIFT, "lo-shift-before.fods"), String)
    table(s, name) = (r = findfirst("<table:table table:name=\"$name\"", s); e = findnext("</table:table>", s, last(r)); s[first(r):last(e)])
    dir = mktempdir()
    # rows inserted on Z, below anything the other sheets refer to: the other sheets are byte-identical
    xf = openods(joinpath(SHIFT, "lo-shift-before.fods"); mode = "rw")
    insertRows(xf["Z"], 20)
    out = read(writeods(joinpath(dir, "z.fods"), xf), String)
    for s in ("Data", "Other", "My Sheet")
        @test table(out, s) == table(src, s)
    end
    @test out == src                                           # rows after the last one: nothing to write
    # rows inserted at row 9 of Data: its rows 1–8 are byte-identical apart from the formulas that
    # change, and every other element outside the tables too
    xf = openods(joinpath(SHIFT, "lo-shift-before.fods"); mode = "rw")
    insertRows(xf["Data"], 25)
    out = read(writeods(joinpath(dir, "d.fods"), xf), String)
    a = table(src, "Data"); b = table(out, "Data")
    i = findfirst("<table:table-row", a)
    @test a[1:first(i)] == b[1:first(i)]                       # the table's start, columns and shapes
    @test table(out, "Other") == table(src, "Other")            # Other refers to no row below 25
    @test out[1:first(findfirst("<table:table ", out))] == src[1:first(findfirst("<table:table ", src))]
end

@testset "a zipped file, with its chart" begin
    dir = mktempdir()
    o = load_oracle(joinpath(SHIFT, "lo-shift-refs.tsv"))
    for name in ("ins_r5_1", "del_c2_1", "del_r3_6")
        xf = openods(joinpath(SHIFT, "lo-shift-before.ods"); mode = "rw")
        apply_op!(xf, name)
        got = saved_refs(writeods(joinpath(dir, name * ".ods"), xf))
        for k in ("chart:series[#1](in object)", "chart:series[#2](in object)"), a in ("chart:values-cell-range-address", "chart:label-cell-address")
            @test got[(k, a)] == o[name][(k, a)]
        end
        @test get(got, ("formula:f05", "table:formula"), nothing) == get(o[name], ("formula:f05", "table:formula"), nothing)
    end
    # without structural edits, the chart part is copied byte for byte
    xf = openods(joinpath(SHIFT, "lo-shift-before.ods"); mode = "rw")
    xf["Data"]["A1"] = 1
    p = writeods(joinpath(dir, "plain.ods"), xf)
    @test read_bytes(open_container(p), "Object 1/content.xml") == read_bytes(open_container(joinpath(SHIFT, "lo-shift-before.ods")), "Object 1/content.xml")
end

@testset "LibreOffice reads the shifted references as its own" begin
    if isempty(SOFFICE) || !isfile(SOFFICE)
        @info "LibreOffice not found; skipping the shift oracle (set ODS_SOFFICE)"
        @test_skip false
    else
        dir = mktempdir()
        profile = lo_profile_url(joinpath(dir, "lo-profile"))
        o = load_oracle(joinpath(SHIFT, "lo-shift-refs.tsv"))
        names = ["ins_r6_2", "del_r5_1", "ins_c3_1", "del_c2_3"]
        files = String[]
        for name in names
            xf = openods(joinpath(SHIFT, "lo-shift-before.fods"); mode = "rw")
            apply_op!(xf, name)
            push!(files, writeods(joinpath(dir, name * ".fods"), xf))
        end
        run(pipeline(`$SOFFICE -env:UserInstallation=$profile --headless --norestore --convert-to fods --outdir $(joinpath(dir, "lo")) $files`;
                     stdout = devnull, stderr = devnull))
        for name in names
            got = saved_refs(joinpath(dir, "lo", name * ".fods"))
            want = o[name]
            for ((k, a), v) in want
                (startswith(k, "formula:") && a in ("table:formula", "@cell")) || continue
                # LibreOffice writes a #REF! it reads back bare (F-024), one it makes bracketed (F-043)
                @test replace(get(got, (k, a), "(none)"), "[#REF!]" => "#REF!") == replace(v, "[#REF!]" => "#REF!")
            end
        end
    end
end

# Sequences of operations, with cell edits and formatting between them: the saved file reads back
# as the model is (values, formulas, merges, formats), on every sheet, zipped and flat.
@testset "sequences: the saved file is the model" begin
    dir = mktempdir()
    formulas(xf) = Dict((ws.name, Int(rd.row), Int(r.col)) => r.data.formula
                        for ws in _sheets(xf) for rd in _cached_store(ws).rows for r in rd.runs if r.data.formula !== nothing)
    seqs = [
        xf -> (insertRows(xf["Data"], 5; count = 2); deleteColumns(xf["Data"], "C"); insertColumns(xf["Data"], "B"; count = 3)),
        xf -> (deleteRows(xf["Data"], "3:4"); xf["Data"]["A3"] = "edited"; insertRows(xf["Data"], 2); setFont(xf["Data"], "B2:C9"; bold = true)),
        xf -> (insertRows(xf["Other"], 1); deleteRows(xf["Data"], [1, 7, 9]); setFormula(xf["Other"], "D1"; val = "=SUM(Data.A1:A3)");
               insertColumns(xf["Data"], 1)),
        xf -> (insertColumns(xf["Data"], "D"; count = 2); deleteRows(xf["Data"], 11); deleteColumns(xf["Data"], 1:2);
               mergeCells(xf["Data"], "F15:G16"); insertRows(xf["Data"], 16)),
        xf -> (deleteRows(xf["Data"], "1:20"); insertRows(xf["Z"], 3; count = 4); xf["Data"]["B2"] = 7),
    ]
    for (i, seq) in enumerate(seqs), ext in (".fods", ".ods")
        xf = openods(joinpath(SHIFT, "lo-shift-before" * ext); mode = "rw")
        seq(xf)
        path = writeods(joinpath(dir, "seq$i$ext"), xf)
        back = openods(path)
        for ws in _sheets(xf)
            b = back[ws.name]
            @test isequal(b[:], ws[:])
            @test isequal(getMergedCells(b), getMergedCells(ws))
        end
        @test formulas(back) == formulas(xf)
        ws = xf["Data"]; b = back["Data"]
        dim = OpenDocumentSpreadsheets.get_dimension(ws)
        @test all(style_name(back.styles, effective_style(b, r, c)) == style_name(xf.styles, effective_style(ws, r, c))
                  for r in 1:OpenDocumentSpreadsheets.row_number(dim.stop) + 2, c in 1:8)
    end
end

@testset "a new file after inserts and deletes" begin
    xf, ws = lines_sheet()
    insertRows(ws, 2; count = 3); deleteColumns(ws, "A"); insertColumns(ws, "C"); deleteRows(ws, 7)
    for ext in (".ods", ".fods")
        back = readods(writeods(joinpath(mktempdir(), "new" * ext), xf))["S"]
        @test isequal(back[:], ws[:])
        @test getFormula(back, "F1") == getFormula(ws, "F1")
        @test isequal(getMergedCells(back), getMergedCells(ws))
    end
end

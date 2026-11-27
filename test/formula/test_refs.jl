# References as ODF stores them, and the operations that rewrite them (src/formula/refs.jl; D-050,
# D-053, D-054), checked against LibreOffice: experiment 021 (row and column inserts and deletes,
# test/data/shift/lo-shift-*.tsv) and experiment 022 (sheet operations, lo-sheetops-*.tsv). Every
# reference LibreOffice stored before an operation is rewritten here and compared with what it
# stored after. The oracle helpers (`load_oracle`, `lineop`, `cf_meaning`…) are in test/oracle_refs.jl.

using OpenDocumentSpreadsheets: parse_ref, parse_ref_end, render_ref, rewrite_formula, rewrite_rangelist, rewrite_address,
    rebase_condition, LineShift, SheetRename, SheetDelete, SheetCopy, RefContext, tokenize_formula, FT_REF

@testset "parsing references" begin
    e = parse_ref_end("\$'My sheet'.\$A\$1")
    @test e.sheet == "My sheet" && e.sheet_abs && e.col == 1 && e.col_abs && e.row == 1 && e.row_abs && !e.err
    e = parse_ref_end(".B2")
    @test e.sheet === nothing && e.dot && e.col == 2 && e.row == 2 && !e.col_abs
    @test parse_ref_end(".A").row == 0 && parse_ref_end(".5").col == 0 && parse_ref_end(".5").row == 5
    @test parse_ref_end(".\$5").row_abs && parse_ref_end(".\$A").col_abs
    @test parse_ref_end("#REF!").err && parse_ref_end(".#REF!").err && parse_ref_end("\$#REF!.A1").err
    @test parse_ref_end("'it''s'.XFD1048576").sheet == "it's"
    @test parse_ref_end(".XFE1") === nothing && parse_ref_end(".A1x") === nothing && parse_ref_end("") === nothing
    @test parse_ref("'file:///x.ods'#\$Sheet1.A1") === nothing         # another document: never touched
    @test length(parse_ref("\$Data.A5:\$Z.A5")) == 2
    @test parse_ref("A1:B2:C3") === nothing

    # every reference LibreOffice wrote, in experiment 008's formulas and in the oracles, comes back as written
    n = 0
    for row in read_tsv(joinpath(DATA, "formula", "lo-syntax.tsv")), t in tokenize_formula(row[2])
        t.kind === FT_REF || continue
        r = parse_ref(t.text[2:end-1])
        r === nothing && continue
        @test render_ref(r) == t.text[2:end-1]
        n += 1
    end
    @test n > 20
    for f in ("lo-shift-refs.tsv", "lo-sheetops-refs.tsv"), (_, vals) in load_oracle(joinpath(SHIFT, f)), ((k, a), v) in vals
        a == "table:formula" || continue
        for t in tokenize_formula(v)
            t.kind === FT_REF || continue
            r = parse_ref(t.text[2:end-1])
            @test r !== nothing && render_ref(r) == t.text[2:end-1]
        end
    end
end

@testset "operations, unit cases" begin
    ctx = RefContext("Data")
    ins = LineShift("Data", 1, 5, 2, ORDER)
    s = "of:=SUM([.A3:.A8])+N(\"x\")"
    @test rewrite_formula(s, LineShift("Data", 1, 20, 1, ORDER), ctx) === s      # unchanged: the same string
    @test rewrite_formula(s, ins, ctx) == "of:=SUM([.A3:.A10])+N(\"x\")"
    @test rewrite_formula("of:=[.\$A\$5]", ins, ctx) == "of:=[.\$A\$7]"            # \$ marks don't matter (F-043)
    @test rewrite_formula("of:=[.A1048575]", ins, ctx) == "of:=[#REF!]"            # pushed off the sheet
    @test rewrite_formula("of:=SUM([.A5:.A1048576])", ins, ctx) == "of:=SUM([.A7:.A1048576])"
    @test rewrite_formula("of:=SUM([.A:.A])", ins, ctx) == "of:=SUM([.A:.A])"
    @test rewrite_formula("of:=[Other.A5]", ins, ctx) == "of:=[Other.A5]"
    @test rewrite_formula("of:=['file:///x.ods'#\$Data.A5]", ins, ctx) == "of:=['file:///x.ods'#\$Data.A5]"
    @test rewrite_formula("of:=\"[.A5]\"&[.A5]", ins, ctx) == "of:=\"[.A5]\"&[.A7]"   # strings are text
    del = LineShift("Data", 1, 5, -1, ORDER)
    @test rewrite_formula("of:=[.A5]~[.B6]", del, ctx) == "of:=[#REF!]~[.B5]"
    @test rewrite_rangelist("\$Data.\$A\$5:.\$A\$8", del, ctx) == "\$Data.\$A\$5:.\$A\$7"
    @test rewrite_rangelist("\$Data.\$A\$5", del, ctx) == "#REF!"
    @test rewrite_address("Data.D5", del, RefContext("Data"; marked = false)) == "Data.D5"   # unmarked: a deleted end cell keeps its address
    @test rewrite_address("Data.D5", del, ctx) === nothing
    @test rewrite_rangelist(".A5", ins, RefContext("Data"; names = true)) == ".A5"          # a relative name: an offset
    # the end-of-sheet quirk (F-043): a delete inside a range ending at the last row
    q = LineShift("Data", 1, 11, -1, ORDER)
    @test rewrite_formula("[.A10:.A1048576]", q, RefContext("Data"; row = 40, col = 10)) == "[.A9:.A1048575]"
    @test rewrite_formula("[.A10:.A1048576]", q, RefContext("Data"; row = 1, col = 10)) == "[.A10:.A1048576]"
    @test rewrite_formula("[.\$A\$10:.\$A\$1048576]", q, RefContext("Data"; row = 40, col = 10)) == "[.\$A\$10:.\$A\$1048576]"
    # sheets
    @test rewrite_formula("[\$Data.A5]+[Data.A5]+[.A5]", SheetRename("Data", "New Name"), ctx) ==
          "[\$'New Name'.A5]+['New Name'.A5]+[.A5]"
    @test rewrite_formula("[\$Data.A5]", SheetRename("Data", "a'b"), ctx) == "[\$'a''b'.A5]"
    @test rewrite_formula("[\$Data.A5]", SheetRename("data", "DATA"), ctx) == "[\$DATA.A5]"
    @test rewrite_formula("[Data.A5]+[\$Data.A5]", SheetCopy("Data", "Data_2", false, [ORDER; "Data_2"]), ctx) == "[Data_2.A5]+[\$Data.A5]"
    # a relative sheet keeps its distance in the sheet order (F-047): Data is just before Other, so
    # in Other's copy at the end it is the sheet just before the copy
    @test rewrite_formula("[Data.A5]+[Other.A1]", SheetCopy("Other", "Other_2", false, [ORDER; "Other_2"]), ctx) ==
          "[Z.A5]+[Other_2.A1]"
    @test rewrite_formula("[Other.A5]", SheetCopy("Data", "Data_2", false, ["Data_2"; ORDER]), ctx) == "[Data.A5]"
    @test rewrite_formula("[Data.A5]", SheetCopy("Other", "Other_2", false, ["Other_2"; ORDER]), ctx) == "[#REF!]"
    # conditional-format targets grow with lines inserted just after them (F-043)
    @test rewrite_rangelist("Data.B5:Data.B8", LineShift("Data", 1, 9, 1, ORDER), RefContext("Data"; expand = true)) == "Data.B5:Data.B9"
    @test rewrite_rangelist("Data.B5", LineShift("Data", 2, 3, 2, ORDER), RefContext("Data"; expand = true)) == "Data.B5:Data.D5"
    @test rewrite_rangelist("Data.B5:Data.B8", LineShift("Data", 1, 9, 1, ORDER), RefContext("Data")) == "Data.B5:Data.B8"
    @test rewrite_rangelist("\$Data.\$C\$5", SheetCopy("Data", "Data_2", true, [ORDER; "Data_2"]), ctx) == "\$Data_2.\$C\$5"
    sd = SheetDelete("Z", ORDER)
    @test rewrite_formula("[\$Data.A5:\$Z.A5]", sd, ctx) == "[\$Data.A5:\$'My Sheet'.A5]"
    @test rewrite_formula("[\$Data.A5:\$Other.A5]", SheetDelete("Data", ORDER), ctx) == "[\$Other.A5:\$Other.A5]"
    @test rewrite_formula("[\$Z.A5]", sd, ctx) == "[#REF!]"
    @test rewrite_rangelist("Z.A1:Z.A5", sd, RefContext("Data"; marked = false)) == "'My Sheet'.A1:'My Sheet'.A5"
    @test rewrite_rangelist("Data.A1:Data.A5", SheetDelete("Data", ORDER), RefContext("Data"; marked = false)) == "Other.A1:Other.A5"
    # conditional formats: re-based on the target's top-left cell (F-044)
    @test rebase_condition("formula-is([.A5]>[.A6])", "Data.A1", "Data.B5:Data.B8", LineShift("Data", 1, 5, 1, ORDER), "Data") ==
          ("formula-is([.B10]>[.B11])", "Data.B6")
    @test rebase_condition("formula-is([.A5]>[.A6])", "Data.A1", "Data.B5:Data.B8", LineShift("Data", 1, 20, 1, ORDER), "Data") === nothing
    # whole rows and columns: their top-left cell is in column A or row 1 (a row threw; a column gave `B0`)
    @test rebase_condition("formula-is([.A5]>[.A6])", "Data.A1", "Data.5:Data.8", LineShift("Data", 1, 2, 1, ORDER), "Data") ==
          ("formula-is([.A10]>[.A11])", "Data.A6")
    @test rebase_condition("formula-is([.A5]>[.A6])", "Data.A1", "Data.B:Data.C", LineShift("Data", 1, 2, 1, ORDER), "Data") ==
          ("formula-is([.B6]>[.B7])", "Data.B1")
end

# The values of `vals` that an operation leaves, as LibreOffice stored them in `after`, compared with
# OpenDocumentSpreadsheets' rewrite. `rw(key, attr, value)` returns OpenDocumentSpreadsheets' value, or `missing` to skip.
function compare!(fails, label, before, after, rw; afterkey = identity)
    n = 0
    for ((k, a), v) in before
        startswith(a, "@") && continue
        want = get(after, (afterkey(k), a), nothing)
        want === nothing && continue                                  # gone with its cells or sheet
        got = rw(k, a, v)
        got === missing && continue
        check!(fails, "$label $k $a", got, want)
        n += 1
    end
    return n
end

@testset "row and column inserts and deletes (experiment 021)" begin
    o = load_oracle(joinpath(SHIFT, "lo-shift-refs.tsv"))
    before = o["before"]
    ops = [String(split(l, '\t')[1]) for l in eachline(joinpath(SHIFT, "lo-shift-ops.tsv"))]
    fails = String[]
    total = 0
    for name in ops
        op = lineop(name, ORDER)
        after = o[name]
        rw = function (k, a, v)
            if startswith(k, "formula:")
                sheet, r, c = cellpos(before[(k, "@cell")])
                return rewrite_formula(v, op, RefContext(sheet; row = r, col = c))
            elseif startswith(k, "table:named-range") || startswith(k, "table:named-expression")
                a == "table:base-cell-address" && return v                    # names' bases stay (F-044)
                ctx = RefContext(basesheet(before[(k, "table:base-cell-address")]); names = true)
                return a == "table:expression" ? rewrite_formula(v, op, ctx) : rewrite_rangelist(v, op, ctx)
            elseif startswith(k, "table:content-validation")
                ctx = RefContext(basesheet(before[(k, "table:base-cell-address")]))
                return a == "table:condition" ? rewrite_formula(v, op, ctx) : rewrite_rangelist(v, op, ctx)
            elseif a in ("table:target-range-address", "table:print-ranges") && !startswith(k, "calcext")
                return rewrite_rangelist(v, op, RefContext("Data"))
            elseif a in ("chart:values-cell-range-address", "chart:label-cell-address", "table:end-cell-address")
                # chart series and shapes' end cells are unmarked: wholly deleted, they keep their address
                return rewrite_rangelist(v, op, RefContext("Data"; marked = false))
            end
            return missing          # conditional formats below; notify-on-update and style:map are regenerated by LibreOffice
        end
        total += compare!(fails, name, before, after, rw)
        # conditional formats, by meaning
        tk = ("calcext:conditional-format[#1]", "calcext:target-range-address")
        target = before[tk]
        cond = before[("calcext:condition[#1]", "calcext:value")]
        base = before[("calcext:condition[#1]", "calcext:base-cell-address")]
        newtarget = rewrite_rangelist(target, op, RefContext("Data"; expand = true))
        if haskey(after, tk)
            check!(fails, "$name conditional-format target", newtarget, after[tk])
            r = something(rebase_condition(cond, base, target, op, "Data"), (cond, base))
            check!(fails, "$name conditional-format meaning",
                   cf_meaning(r[1], r[2], newtarget),
                   cf_meaning(after[("calcext:condition[#1]", "calcext:value")],
                              after[("calcext:condition[#1]", "calcext:base-cell-address")], after[tk]))
        else
            check!(fails, "$name conditional-format removed", newtarget, "#REF!")
        end
        total += 2
    end
    isempty(fails) || foreach(println, fails)
    @test isempty(fails)
    @test total > 1000
end

@testset "the end-of-sheet quirk (experiment 021 part B)" begin
    o = load_oracle(joinpath(SHIFT, "lo-shift-quirks.tsv"))
    before = o["q_before"]
    fails = String[]
    total = 0
    for name in keys(o)
        name == "q_before" && continue
        op = lineop(name, ["Q"])
        total += compare!(fails, name, before, o[name], function (k, a, v)
            sheet, r, c = cellpos(before[(k, "@cell")])
            rewrite_formula(v, op, RefContext(sheet; row = r, col = c))
        end)
    end
    isempty(fails) || foreach(println, fails)
    @test isempty(fails)
    @test total > 250
end

@testset "sheet operations (experiment 022)" begin
    o = load_oracle(joinpath(SHIFT, "lo-sheetops-refs.tsv"))
    renames = Dict("rename_data" => ("Data", "New Name"), "rename_other" => ("Other", "Oth.er"),
                   "rename_z" => ("Z", "Zed"), "rename_case" => ("Data", "DATA"))
    fails = String[]
    total = 0
    for file in keys(o)
        file in ("before", "q_before") && continue
        name = replace(file, r"^(op|q)_" => "")
        before = startswith(file, "q_") ? o["q_before"] : o["before"]
        after = o[file]
        quirk = startswith(file, "q_")
        skipobj(k) = occursin("(in object)", k) && (quirk || startswith(name, "copy"))   # chart ordinals shift
        regen(k, a) = a == "draw:notify-on-update-of-ranges" || startswith(k, "style:map") || startswith(k, "calcext") ||
                      startswith(k, "chart:chart") || startswith(k, "draw:rect")
        if haskey(renames, name)
            old, new = renames[name]
            op = SheetRename(old, new)
            afterkey(k) = replace(k, "@" * old => "@" * new, "[" * old * "]" => "[" * new * "]")
            total += compare!(fails, file, before, after, function (k, a, v)
                (regen(k, a) || skipobj(k)) && return missing
                a in ("table:formula", "table:expression", "table:condition") && return rewrite_formula(v, op, RefContext("Data"))
                return rewrite_rangelist(v, op, RefContext("Data"))
            end; afterkey)
        elseif startswith(name, "delete")
            gone = name == "delete_data" ? "Data" : name == "delete_other" ? "Other" : name == "delete_mysheet" ? "My Sheet" : "Z"
            op = SheetDelete(gone, ORDER)
            total += compare!(fails, file, before, after, function (k, a, v)
                (regen(k, a) || skipobj(k)) && return missing
                if startswith(k, "formula:")
                    sheet, r, c = cellpos(before[(k, "@cell")])
                    return rewrite_formula(v, op, RefContext(sheet; row = r, col = c))
                elseif startswith(k, "table:named-")
                    a == "table:base-cell-address" && return rewrite_rangelist(v, op, RefContext("Data"; marked = false))
                    ctx = RefContext(basesheet(before[(k, "table:base-cell-address")]); names = true)
                    return a == "table:expression" ? rewrite_formula(v, op, ctx) : rewrite_rangelist(v, op, ctx)
                elseif occursin("(in object)", k)
                    return rewrite_rangelist(v, op, RefContext("Data"; marked = false))
                elseif a in ("table:formula", "table:condition")
                    return rewrite_formula(v, op, RefContext("Data"))
                end
                return rewrite_rangelist(v, op, RefContext("Data"))
            end)
        elseif startswith(name, "copy")
            src, dst = startswith(name, "copy_other") ? ("Other", "Other_2") : ("Data", "Data_2")
            order = name == "copy_data_first" ? ["Data_2"; ORDER] :
                    name == "copy_data_mid" ? ["Data", "Other", "Data_2", "My Sheet", "Z"] : [ORDER; dst]
            op = SheetCopy(src, dst, false, order)
            # the copy's formulas, from the source's
            for ((k, a), v) in after
                (a == "table:formula" && endswith(k, "@" * dst)) || continue
                bk = replace(k, "@" * dst => "@" * src)
                check!(fails, "$file $k", rewrite_formula(before[(bk, a)], op, RefContext(dst)), v)
                total += 1
            end
        else                                    # move and insert rewrite nothing
            total += compare!(fails, file, before, after, (k, a, v) -> (regen(k, a) || skipobj(k)) ? missing : v)
        end
    end
    isempty(fails) || foreach(println, fails)
    @test isempty(fails)
    @test total > 1000
end

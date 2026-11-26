# Sheet operations (phase 5 step 4; D-053, D-054): renamesheet!, deletesheet!, copysheet!,
# movesheet!, against LibreOffice's results (experiment 022, test/data/shift/lo-sheetops-*), on the
# model, in saved files, and through LibreOffice. Uses test/oracle_refs.jl's `load_oracle`,
# `cf_meaning` and write/test_lines.jl's `saved_refs`.

using OpenDocumentSpreadsheets: renamesheet!, deletesheet!, copysheet!, movesheet!, sheetnames, patched_settings

const SHEETOPS = load_oracle(joinpath(SHIFT, "lo-sheetops-refs.tsv"))

# Experiment 022's operations through the API (a copy or an insert at a place: then moved there).
function apply_sheetop!(xf, name)
    name = replace(name, r"^(op|q)_" => "")
    if startswith(name, "rename")
        old, new = Dict("rename_data" => ("Data", "New Name"), "rename_other" => ("Other", "Oth.er"),
                        "rename_z" => ("Z", "Zed"), "rename_case" => ("Data", "DATA"))[name]
        renamesheet!(xf[old], new)
    elseif startswith(name, "delete")
        deletesheet!(xf, Dict("delete_data" => "Data", "delete_other" => "Other", "delete_mysheet" => "My Sheet", "delete_z" => "Z")[name])
    elseif startswith(name, "copy")
        src = startswith(name, "copy_other") ? "Other" : "Data"
        new = copysheet!(xf[src], src * "_2")
        name == "copy_data_first" && movesheet!(new; before = 1)
        name == "copy_data_mid" && movesheet!(new; before = "My Sheet")
    elseif startswith(name, "move")
        name == "move_data_end" && movesheet!(xf, "Data"; after = sheetcount(xf))
        name == "move_z_first" && movesheet!(xf, "Z"; before = 1)
        name == "move_mysheet_end" && movesheet!(xf, "My Sheet"; after = sheetcount(xf))
        name == "move_other_first" && movesheet!(xf, "Other"; before = 1)
    elseif startswith(name, "insert")
        new = addsheet!(xf, "New")
        name == "insert_first" && movesheet!(new; before = 1)
        name == "insert_mid" && movesheet!(new; before = "My Sheet")
    end
end

const SHEETOP_ORDERS = Dict(String(split(l, '\t')[1]) => split(split(l, '\t')[3], ',')
                            for l in eachline(joinpath(SHIFT, "lo-sheetops-ops.tsv")) if count('\t', l) >= 2)

@testset "sheet operations: the model and saved files (experiment 022)" begin
    dir = mktempdir()
    fails = String[]
    n = 0
    for file in sort(collect(keys(SHEETOPS)))
        file in ("before", "q_before") && continue
        quirk = startswith(file, "q_")
        name = replace(file, r"^(op|q)_" => "")
        haskey(SHEETOP_ORDERS, quirk ? file : name) || continue
        src = quirk ? "lo-sheetops-quirks-before.fods" : "lo-shift-before.fods"
        xf = openods(joinpath(SHIFT, src); mode = "rw")
        apply_sheetop!(xf, file)
        @test sheetnames(xf) == SHEETOP_ORDERS[quirk ? file : name]
        want = SHEETOPS[file]
        # the model's formulas, by key and sheet
        for ws in _sheets(xf), rd in _cached_store(ws).rows, r in rd.runs
            f = r.data.formula
            f === nothing && continue
            m = match(r"N\(\"(\w+)\"\)", f)
            m === nothing && continue
            k = ("formula:" * m.captures[1] * "@" * ws.name, "table:formula")
            haskey(want, k) || (push!(fails, "$file model: $(k[1]) not in LibreOffice's"); continue)
            n += 1
            want[k] == f || push!(fails, "$file model $(k[1]): OpenDocumentSpreadsheets `$f`, LibreOffice `$(want[k])`")
        end
        # the saved file
        got = saved_refs(writeods(joinpath(dir, file * ".fods"), xf); keysheet = true)
        skip(k, a) = a == "@value" || a == "draw:notify-on-update-of-ranges" || startswith(k, "style:map") ||
                     startswith(k, "calcext:condition[") || startswith(k, "chart:chart") || startswith(k, "text:a") ||
                     (occursin("(in object)", k) && (quirk || startswith(name, "copy"))) ||
                     startswith(k, "draw:rect")                            # shapes: two are named alike
        for ((k, a), v) in want
            skip(k, a) && continue
            n += 1
            g = get(got, (k, a), "(none)")
            g == v || push!(fails, "$file $k $a: OpenDocumentSpreadsheets `$g`, LibreOffice `$v`")
        end
        for (k, a) in keys(got)
            (skip(k, a) || haskey(want, (k, a))) && continue
            push!(fails, "$file $k $a: only in OpenDocumentSpreadsheets' file (`$(got[(k, a)])`)")
        end
        # conditional formats, by meaning
        for (k, a) in keys(want)
            (startswith(k, "calcext:conditional-format[") && a == "calcext:target-range-address") || continue
            ck = replace(k, "calcext:conditional-format" => "calcext:condition")
            haskey(got, (ck, "calcext:value")) || (push!(fails, "$file $k: no condition in OpenDocumentSpreadsheets' file"); continue)
            n += 1
            cf_meaning(got[(ck, "calcext:value")], got[(ck, "calcext:base-cell-address")], got[(k, a)]) ==
                cf_meaning(want[(ck, "calcext:value")], want[(ck, "calcext:base-cell-address")], want[(k, a)]) ||
                push!(fails, "$file $k: a different conditional format")
        end
    end
    isempty(fails) || foreach(println, fails)
    @test isempty(fails)
    @test n > 2000
end

@testset "sheet operations: names, settings and errors" begin
    xf = openods(joinpath(SHIFT, "lo-shift-before.fods"); mode = "rw")
    # the sheets' entries in the settings follow (F-047)
    renamesheet!(xf["Data"], "D 1")
    deletesheet!(xf, "Z")
    copysheet!(xf["Other"])
    @test sheetnames(xf) == ["D 1", "Other", "My Sheet", "Other (copy)"]
    s = patched_settings(xf, read_xml(open_container(joinpath(SHIFT, "lo-shift-before.fods")), :settings))
    s = replace(s, r">\s+<" => "><")
    @test occursin("config:name=\"D 1\"><config:config-item config:name=\"CodeName\" config:type=\"string\">Sheet1<", s)
    @test !occursin("config:name=\"Data\"", s) && !occursin("config:name=\"Z\">", s)
    @test occursin("config:name=\"Other (copy)\"><config:config-item config:name=\"CodeName\" config:type=\"string\">Other (copy)<", s)
    # the copy's own local names: the source's, and the global names its formulas use (F-047)
    ln = Dict(dn.name => dn for dn in OpenDocumentSpreadsheets._local_names(copysheet!(xf["D 1"], "D 2")))
    @test ln["LocalN"].range == "\$'D 2'.\$C\$5" && ln["NR"].range == "\$'D 2'.\$A\$5:.\$A\$8" && ln["NRel"].base == "\$'D 2'.\$J\$1"
    @test getFormula(xf["D 2"], "J28") == "='D 2'.A5+N(\"f28\")"      # a relative sheet name: the copy
    @test getFormula(xf["D 2"], "J29") == "=\$'D 1'.\$A\$5+N(\"f29\")"  # an absolute one: kept
    # names follow a rename and a delete
    xf2 = openods(joinpath(SHIFT, "lo-shift-before.fods"); mode = "rw")
    renamesheet!(xf2["Data"], "X")
    @test OpenDocumentSpreadsheets._find_name(OpenDocumentSpreadsheets._wb_names(xf2), "NR").range == "\$X.\$A\$5:.\$A\$8"
    deletesheet!(xf2, 1)
    @test OpenDocumentSpreadsheets._find_name(OpenDocumentSpreadsheets._wb_names(xf2), "NR").range == "#REF!"
    @test getFormula(xf2["Other"], "B3") == "=#REF!+N(\"o01\")"
    # errors
    @test_throws ODSError renamesheet!(xf2["Other"], "z")             # another sheet's name, in another case
    @test_throws ODSError renamesheet!(xf2["Other"], "a:b")
    @test_throws ODSError renamesheet!(xf2["Other"], "'a")
    renamesheet!(xf2["Other"], "OTHER")                                # its own name in another case
    @test sheetnames(xf2)[1] == "OTHER"
    one = newods("Only")
    @test_throws ODSError deletesheet!(one, "Only")
    @test_throws ODSError deletesheet!(one, 2)
    @test_throws ODSError movesheet!(one, "Only")
    @test_throws ODSError movesheet!(one, "Only"; before = 1, after = 1)
    @test_throws ODSError copysheet!(one[1], "Only")
    @test_throws ODSError renamesheet!(readods(joinpath(DATA, "lo-tables.ods"))[1], "x")
    # a new file: copies, renames, moves, deletes
    xf3 = newods("A")
    xf3["A"]["A1"] = 1
    setFormula(xf3["A"], "B1"; val = "=A.A1+A1")
    addsheet!(xf3, "B")
    setFormula(xf3["B"], "A1"; val = "=SUM(A.A1:A2)")
    c = copysheet!(xf3["A"])
    @test c.name == "A (copy)" && getFormula(c, "B1") == "='A (copy)'.A1+A1"
    @test copysheet!(xf3["A"]).name == "A (copy) 1"
    renamesheet!(xf3["A"], "Z")
    @test getFormula(xf3["B"], "A1") == "=SUM(Z.A1:A2)"
    movesheet!(xf3, "B"; before = "Z")
    deletesheet!(xf3, "Z")
    @test sheetnames(xf3) == ["B", "A (copy)", "A (copy) 1"]
    @test getFormula(xf3["B"], "A1") == "=SUM(#REF!)"
    back = readods(writeods(joinpath(mktempdir(), "n.ods"), xf3))
    @test sheetnames(back) == sheetnames(xf3) && getFormula(back["A (copy)"], "B1") == "='A (copy)'.A1+A1"
end

@testset "sheet operations: zipped files, charts, sequences" begin
    dir = mktempdir()
    # a copy of the sheet holding the chart gets a chart of its own (a new object part)
    xf = openods(joinpath(SHIFT, "lo-shift-before.ods"); mode = "rw")
    copysheet!(xf["Other"])
    p = writeods(joinpath(dir, "copy.ods"), xf)
    c = open_container(p)
    @test "Object 2/content.xml" in OpenDocumentSpreadsheets.partnames(c) && "ObjectReplacements/Object 2" in OpenDocumentSpreadsheets.partnames(c)
    @test any(e -> e.path == "Object 2/" && e.mediatype == "application/vnd.oasis.opendocument.chart", c.manifest)
    @test any(e -> e.path == "Object 1/" && e.mediatype == "application/vnd.oasis.opendocument.chart", c.manifest)
    @test occursin("./Object 2", read_xml(c, :content))
    # sequences of sheet and line operations, with edits, save as the model is
    formulas(xf) = Dict((ws.name, Int(rd.row), Int(r.col)) => r.data.formula
                        for ws in _sheets(xf) for rd in _cached_store(ws).rows for r in rd.runs if r.data.formula !== nothing)
    seqs = [
        xf -> (renamesheet!(xf["Data"], "Daten"); insertRows(xf["Daten"], 3); copysheet!(xf["Daten"]); deleteColumns(xf["Daten (copy)"], "A")),
        xf -> (copysheet!(xf["Other"], "O2"); deletesheet!(xf, "Data"); movesheet!(xf, "O2"; before = 1); xf["O2"]["A1"] = "x"),
        xf -> (movesheet!(xf, "Z"; before = "Data"); insertRows(xf["Data"], 1; count = 2); renamesheet!(xf["Z"], "Zz");
               setFormula(xf["Zz"], "C1"; val = "=SUM(Data.A1:A10)"); deletesheet!(xf, "My Sheet")),
        xf -> (c = copysheet!(xf["Data"]); renamesheet!(c, "C2"); copysheet!(c, "C3"); deleteRows(xf["C3"], "5:6"); deletesheet!(xf, "C2")),
    ]
    for (i, seq) in enumerate(seqs), ext in (".fods", ".ods")
        xf = openods(joinpath(SHIFT, "lo-shift-before" * ext); mode = "rw")
        seq(xf)
        back = openods(writeods(joinpath(dir, "seq$i$ext"), xf))
        @test sheetnames(back) == sheetnames(xf)
        for ws in _sheets(xf)
            @test isequal(back[ws.name][:], ws[:])
            @test isequal(getMergedCells(back[ws.name]), getMergedCells(ws))
        end
        @test formulas(back) == formulas(xf)
        @test Dict(dn.name => dn.range for dn in OpenDocumentSpreadsheets._wb_names(back)) == Dict(dn.name => dn.range for dn in OpenDocumentSpreadsheets._wb_names(xf))
    end
end

@testset "LibreOffice reads the sheet operations as its own" begin
    if isempty(SOFFICE) || !isfile(SOFFICE)
        @info "LibreOffice not found; skipping the sheet operations oracle (set ODS_SOFFICE)"
        @test_skip false
    else
        dir = mktempdir()
        profile = lo_profile_url(joinpath(dir, "lo-profile"))
        names = ["op_rename_data", "op_delete_data", "op_copy_other_end", "op_move_z_first"]
        files = String[]
        for name in names
            xf = openods(joinpath(SHIFT, "lo-shift-before.ods"); mode = "rw")
            apply_sheetop!(xf, name)
            push!(files, writeods(joinpath(dir, name * ".ods"), xf))
        end
        run(pipeline(`$SOFFICE -env:UserInstallation=$profile --headless --norestore --convert-to fods --outdir $(joinpath(dir, "lo")) $files`;
                     stdout = devnull, stderr = devnull))
        for name in names
            got = saved_refs(joinpath(dir, "lo", name * ".fods"); keysheet = true)
            want = SHEETOPS[name]
            for ((k, a), v) in want
                (startswith(k, "formula:") && a in ("table:formula", "@cell")) || continue
                # a 3-D range whose sheets are out of order after a move: LibreOffice swaps its ends
                # when it loads a file (its own file reads back the same), so it isn't compared
                startswith(name, "op_move") && occursin(r"\$[^.\]]+\.[A-Z]+\d+:\$", v) && continue
                @test replace(get(got, (k, a), "(none)"), "[#REF!]" => "#REF!") == replace(v, "[#REF!]" => "#REF!")
            end
            # the chart keeps its data (its series)
            name == "op_delete_other" || @test any(((k, a),) -> a == "chart:values-cell-range-address", keys(got))
        end
    end
end

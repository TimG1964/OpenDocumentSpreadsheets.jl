# Sparklines (phase 8 step 8, D-085, D-086, Q-029): XLSX.jl's addSparklines, getSparklines and
# deleteSparklines on LibreOffice's sparkline groups, against LibreOffice's import of the same calls
# (experiment 039 part G), through operations (Q-029 option 2), and LibreOffice reading ours.
# Uses `_ch` from the files before.

# Experiment 039's sparkline cases (build.jl), on the cells it used.
const _SPARK_CASES = [("line", (;)), ("column", (type = :column,)), ("winloss", (type = :winloss,)),
    ("markers", (markers = true,)), ("highlow", (high = true, low = true)), ("firstlast", (first = true, last = true)),
    ("negative", (negative = true,)), ("axis", (axis = true,)), ("empty_zero", (emptyCells = :zero,)),
    ("empty_span", (emptyCells = :span,)), ("showHidden", (showHidden = true,)), ("weight", (lineWeight = 2.25,)),
    ("minmax_group", (min = :group, max = :group)), ("minmax_custom", (min = -5, max = 10)), ("rtl", (rightToLeft = true,)),
    ("dateRange", (dateRange = "A30:E30",)),
    ("colors", (markers = true, high = true, low = true, first = true, last = true, negative = true, axis = true,
                seriesColor = "FF0000", negativeColor = "00FF00", axisColor = "0000FF", markersColor = "FFC000",
                firstColor = "7030A0", lastColor = "00B0F0", highColor = "92D050", lowColor = "C00000")),
    ("scheme", (seriesColor = :accent2,))]

function _spark_sheet()
    xf = newods("Data")
    xf["Data"][1, 1] = "x"
    for i in 2:7; xf["Data"][i, 2] = 10i; end
    sp = addsheet!(xf, "Spark")
    for i in 1:30, j in 1:5
        sp[i, j] = ((i * 7 + j * 13) % 11) - 3
    end
    return xf, sp
end

_spark_attrs(g::AbstractString) = Dict(m.captures[1] => m.captures[2] for m in eachmatch(r"calcext:([a-z-]+)=\"([^\"]*)\"",
                                                                                         match(r"<calcext:sparkline-group\b[^>]*>", g).match))

@testset "addSparklines: as LibreOffice's import of XLSX.jl's" begin
    xf, sp = _spark_sheet()
    E = OpenDocumentSpreadsheets.ODSError
    for (k, (nm, kw)) in enumerate(_SPARK_CASES)
        if nm == "dateRange"
            @test_throws E addSparklines(sp, "F$k", "A$k:E$k"; kw...)    # LibreOffice keeps no date range (D-086)
        else
            addSparklines(sp, "F$k", "A$k:E$k"; kw...)
        end
    end
    addSparklines(sp, "F19:F21", "A19:E21"; type = :column)
    addSparklines(sp, "H1", "Data!B2:B7")
    # LibreOffice's groups, by their first sparkline's cell
    lo = readods(_ch("lo-sparklines.ods"))
    theirs = Dict(first(g.sparklines).first => g for g in getSparklines(lo["Spark"]))
    mine = Dict(first(g.sparklines).first => g for g in getSparklines(sp))
    delete!(theirs, "F16")                                                 # dateRange: the import kept the group, without its dates
    @test length(mine) == length(theirs) == 19
    for (cell, g) in theirs
        m = mine[cell]
        if cell == "F18"                                                   # :accent2: the xlsx's theme there, the document's here
            @test m.colors.seriesColor == "FF0369A3" && g.colors.seriesColor == "FFED7D31"
            @test Base.structdiff(m, (colors = 0,)) == Base.structdiff(g, (colors = 0,))
        else
            @test (cell, m) == (cell, g)
        end
    end
    # the XML: LibreOffice's attributes and values
    ours = Dict(_spark_attrs(g)["type"] * string(i) => _spark_attrs(g) for (i, g) in enumerate(sp.sparks.list))
    loxml = String(ZipArchives.zip_readentry(ZipArchives.ZipReader(read(_ch("lo-sparklines.ods"))), "content.xml"))
    groups = [m.match for m in eachmatch(r"<calcext:sparkline-group\b.*?</calcext:sparkline-group>"s, loxml)]
    byfirst(gs) = Dict(match(r"calcext:cell-address=\"([^\"]*)\"", g).captures[1] => _spark_attrs(g) for g in gs)
    lob = byfirst(groups); ourb = byfirst(sp.sparks.list)
    for (cell, a) in lob
        cell in ("Spark.F18", "Spark.F16") && continue
        @test (cell, ourb[cell]) == (cell, a)
    end
    # XLSX.jl's refusals
    @test_throws E addSparklines(sp, "F1:G2", "A1:E2")
    @test_throws E addSparklines(sp, "F1", "A1:E2")
    @test_throws E addSparklines(sp, "F1:F3", "A1:E2")
    @test_throws E addSparklines(sp, "F1", "A1:E1"; type = :area)
    @test_throws E addSparklines(sp, "F1", "A1:E1"; colour = "red")
    @test_throws E addSparklines(sp, "F1", "A1:E1"; markers = 1)
    @test_throws E addSparklines(sp, "F1", "Nowhere!A1:E1")
    # a sparkline replaced; one deleted; a group deleted
    addSparklines(sp, "F2", "B2:E2")
    @test length(getSparklines(sp)) == 19 && first(getSparklines(sp)).sparklines == ["F2" => "Spark.B2:E2"]
    @test deleteSparklines(sp, "F20") && !deleteSparklines(sp, "K40")
    g = only(filter(g -> any(p -> p.first == "F19", g.sparklines), getSparklines(sp)))
    @test g.sparklines == ["F19" => "Spark.A19:E19", "F21" => "Spark.A21:E21"]
    @test deleteSparklines(sp, "F21"; group = true)
    @test !any(g -> any(p -> p.first == "F19", g.sparklines), getSparklines(sp))
    @test deleteSparklines(sp, "F1:F18") && length(getSparklines(sp)) == 1      # H1's is left
end

@testset "sparklines through operations (Q-029 option 2)" begin
    xf, sp = _spark_sheet()
    addSparklines(sp, "F2:F4", "A2:E4")
    addSparklines(sp, "H1", "Data!B2:B7")
    insertRows(sp, 1; count = 2)                              # above: cells and data move down
    g = getSparklines(sp)
    @test g[2].sparklines == ["F4" => "Spark.A4:E4", "F5" => "Spark.A5:E5", "F6" => "Spark.A6:E6"]
    @test g[1].sparklines == ["H3" => "Data.B2:B7"]
    deleteRows(sp, 5)                              # a sparkline's row: it goes
    @test getSparklines(sp)[2].sparklines == ["F4" => "Spark.A4:E4", "F5" => "Spark.A5:E5"]
    deleteColumns(xf["Data"], 2)                      # its data's column: kept, as a chart's (never #REF!)
    @test getSparklines(sp)[1].sparklines[1].first == "H3"
    renamesheet!(xf["Data"], "Numbers")
    cp = copysheet!(sp, "Spark 2")                        # a copy: its cells on the copy, its data where it was
    @test getSparklines(cp)[2].sparklines == ["F4" => "Spark.A4:E4", "F5" => "Spark.A5:E5"]
    @test startswith(getSparklines(cp)[1].sparklines[1].second, "Numbers.")
    mktempdir() do dir
        p = joinpath(dir, "s.ods"); f = joinpath(dir, "s.fods")
        writeods(p, xf); writeods(f, xf)
        for path in (p, f)
            b = readods(path)
            @test getSparklines(b["Spark"]) == getSparklines(sp) && getSparklines(b["Spark 2"]) == getSparklines(cp)
        end
    end
    # a file's sparklines: patched through an insert, and edited
    mktempdir() do dir
        xf2 = openods(_ch("lo-sparklines.ods"); mode = "rw")
        before = getSparklines(xf2["Spark"])
        insertRows(xf2["Spark"], 2)
        p = joinpath(dir, "f.ods"); writeods(p, xf2)
        after = getSparklines(readods(p)["Spark"])
        @test length(after) == length(before)
        @test any(g -> g.sparklines == ["F3" => "Spark.A3:E3"], after)       # F2's, moved with its row
        @test any(g -> g.sparklines == ["F1" => "Spark.A1:E1"], after)       # F1's, above, stays
        xf3 = openods(_ch("lo-sparklines.ods"); mode = "rw")
        deleteSparklines(xf3["Spark"], "F1:F21")
        addSparklines(xf3["Spark"], "J1", "A1:E1"; high = true)
        q = joinpath(dir, "g.ods"); writeods(q, xf3)
        gs = getSparklines(readods(q)["Spark"])
        @test [g.sparklines for g in gs] == [["J1" => "Spark.A1:E1"], ["H1" => "Data.B2:B7"]] && gs[1].high
    end
end

@testset "LibreOffice reads our sparklines" begin
    if lo_ok(LO_FIXTURE_MAJOR)
        xf, sp = _spark_sheet()
        for (k, (nm, kw)) in enumerate(_SPARK_CASES)
            nm == "dateRange" || addSparklines(sp, "F$k", "A$k:E$k"; kw...)
        end
        addSparklines(sp, "F19:F21", "A19:E21"; type = :column)
        addSparklines(sp, "H1", "Data!B2:B7")
        setConditionalFormat(sp, "A1:E5", :colorScale)                        # with conditional formats before them
        mine = getSparklines(sp)
        mktempdir() do dir
            p = joinpath(dir, "s.ods"); f = joinpath(dir, "sf.fods")
            writeods(p, xf); writeods(f, xf)
            out = joinpath(dir, "lo")
            lo_convert([p, f], "ods"; outdir = out, profile = lo_profile_url(joinpath(dir, "profile")))
            for path in (joinpath(out, "s.ods"), joinpath(out, "sf.ods"))
                theirs = getSparklines(readods(path)["Spark"])
                @test Set(theirs) == Set(mine)
                @test !isempty(OpenDocumentSpreadsheets.getConditionalFormats(readods(path)["Spark"]))
            end
        end
    end
end

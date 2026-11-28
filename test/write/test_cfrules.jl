# setConditionalFormat and setColoredDataBars (phase 7, D-081). The expectations are LibreOffice's
# import of the same rules written by XLSX.jl dev (experiment 038's 178 cases, `build.jl`, ported here
# call for call), and LibreOffice reading ours. Where the import loses what LibreOffice can store, or
# what it can't store is an error here, the case is checked on its own (`_CF_DIFFERENT`).
using Test, Dates
using OpenDocumentSpreadsheets
using OpenDocumentSpreadsheets: ODSError, getConditionalFormats, deleteConditionalFormats, setColoredDataBars

const _ODS = OpenDocumentSpreadsheets
_cfr(f) = joinpath(@__DIR__, "..", "data", "conditional", f)

# Experiment 038's build.jl, on an ODS file: the same sheets, data and calls (`errors`: the cases refused).
function _cf_build(today_ = Date(2026, 11, 24))
    xf = newods("CF")
    ws = xf["CF"]
    errors = Dict{String,String}()
    nums = Any[-3, 1, 2, 3, 4, 5, 6, 7, 8, 9]
    dups = Any[1, 2, 2, 3, 4, 4, 4, 5, 6, 7]
    texts = Any["Hello World", "the end", "Once upon", "America", "a \"q\" b", "Größe", "other", "th", "ONCE", "ica"]
    dates = Any[today_ + Day(d) for d in (-40, -9, -6, -1, 0, 1, 6, 9, 31, 45)]
    r = Ref(0)
    function row!(name, data)
        r[] += 1
        ws[r[], 1] = name
        for (j, v) in enumerate(data)
            v === nothing || (ws[r[], 1 + j] = v)
        end
        return r[]
    end
    function add(name, data, type; rng = nothing, kw...)
        k = row!(name, data)
        rg = replace(something(rng, "B$k:K$k"), "#" => string(k))
        kws = Dict{Symbol,Any}(a => (b isa String && a === :formula ? replace(b, "#" => string(k)) : b) for (a, b) in kw)
        try
            setConditionalFormat(ws, rg, type; kws...)
        catch e
            e isa ODSError || rethrow()
            errors[name] = sprint(showerror, e)
        end
        return k
    end
    for op in ("greaterThan", "greaterEqual", "lessThan", "lessEqual", "equal", "notEqual")
        add("cellIs_$op", nums, :cellIs; operator = op, value = "4")
    end
    add("cellIs_between", nums, :cellIs; operator = "between", value = "2", value2 = "6")
    add("cellIs_notBetween", nums, :cellIs; operator = "notBetween", value = "2", value2 = "6")
    add("cellIs_default", nums, :cellIs)
    add("cellIs_ref", nums, :cellIs; operator = "greaterThan", value = "\$M\$1")
    add("cellIs_relref", nums, :cellIs; operator = "lessThan", value = "A1")
    add("cellIs_formula", nums, :cellIs; operator = "greaterThan", value = "SUM(\$M\$1:\$M\$2)/2")
    add("cellIs_decimal", nums, :cellIs; operator = "equal", value = "2.5")
    add("cellIs_text", texts, :cellIs; operator = "equal", value = "\"other\"")
    for (op, v) in (("topN", "3"), ("bottomN", "2"), ("topN%", "20"), ("bottomN%", "10"))
        add("top10_$op", nums, :top10; operator = op, value = v)
    end
    add("top10_default", nums, :top10)
    for op in ("aboveAverage", "aboveEqAverage", "belowAverage", "belowEqAverage", "plus1StdDev", "plus2StdDev",
               "plus3StdDev", "minus1StdDev", "minus2StdDev", "minus3StdDev")
        add("aboveAverage_$op", nums, :aboveAverage; operator = op)
    end
    add("aboveAverage_default", nums, :aboveAverage)
    add("containsText", texts, :containsText; value = "th")
    add("notContainsText", texts, :notContainsText; value = "i")
    add("beginsWith", texts, :beginsWith; value = "On")
    add("endsWith", texts, :endsWith; value = "ica")
    add("containsText_quote", texts, :containsText; value = "\"q\"")
    add("containsText_ref", texts, :containsText; value = "\$M\$3")
    for op in ("yesterday", "today", "tomorrow", "last7Days", "lastWeek", "thisWeek", "nextWeek", "lastMonth",
               "thisMonth", "nextMonth")
        add("timePeriod_$op", dates, :timePeriod; operator = op)
    end
    add("timePeriod_default", dates, :timePeriod)
    mixed = Any[1, nothing, "x", 2, nothing, 3, "y", 4, 4, nothing]
    for t in (:containsBlanks, :notContainsBlanks, :containsErrors, :notContainsErrors, :uniqueValues, :duplicateValues)
        k = add(string(t), t in (:uniqueValues, :duplicateValues) ? dups : mixed, t)
        t in (:containsErrors, :notContainsErrors) && setFormula(ws, "K$k"; val = "=1/0")
    end
    add("expression_rel", nums, :expression; formula = "B# > 4")
    add("expression_abs", nums, :expression; formula = "\$B\$1 > 0")
    add("expression_mixed", nums, :expression; formula = "AND(B\$#>0, \$C#<8)")
    add("expression_fn", nums, :expression; formula = "average(B#:K#) > 2")
    add("expression_sheet", nums, :expression; formula = "B# > Other!\$A\$1")
    for dx in ("redfilltext", "yellowfilltext", "greenfilltext", "redfill", "redtext", "redborder")
        add("dx_$dx", nums, :cellIs; operator = "greaterThan", value = "5", dxStyle = dx)
    end
    add("fmt_full", nums, :cellIs; operator = "between", value = "2", value2 = "3",
        fill = ["pattern" => "none", "bgColor" => "FFFFC7CE"], format = ["format" => "0.00%"], font = ["color" => "blue", "bold" => "true"])
    add("fmt_italic", nums, :cellIs; operator = "greaterThan", value = "4",
        fill = ["pattern" => "none", "bgColor" => "green"], format = ["format" => "0.0"], font = ["color" => "red", "italic" => "true"])
    add("fmt_border", nums, :cellIs; operator = "lessThan", value = "2",
        fill = ["pattern" => "none", "bgColor" => "yellow"], format = ["format" => "0.0"], font = ["color" => "green"],
        border = ["style" => "thick", "color" => "coral"])
    add("fmt_solid", nums, :cellIs; operator = "lessThan", value = "3", fill = ["pattern" => "solid", "bgColor" => "cyan"])
    add("fmt_fg", nums, :cellIs; operator = "lessThan", value = "3", fill = ["pattern" => "solid", "fgColor" => "FF00FF00", "bgColor" => "FF0000FF"])
    add("fmt_pattern", nums, :cellIs; operator = "lessThan", value = "3", fill = ["pattern" => "darkGrid", "fgColor" => "red", "bgColor" => "yellow"])
    add("fmt_under", nums, :cellIs; operator = "lessThan", value = "3", font = ["under" => "single", "strike" => "true"])
    add("fmt_dunder", nums, :cellIs; operator = "lessThan", value = "3", font = ["under" => "double"])
    add("fmt_dashed", nums, :cellIs; operator = "lessThan", value = "3", border = ["style" => "dashed", "color" => "FF0000FF"])
    add("fmt_same1", nums, :cellIs; operator = "greaterThan", value = "1", font = ["color" => "FF7030A0", "bold" => "true"])
    add("fmt_same2", nums, :cellIs; operator = "greaterThan", value = "8", font = ["color" => "FF7030A0", "bold" => "true"])
    add("fmt_numfmt", nums, :cellIs; operator = "greaterThan", value = "0", format = ["format" => "#,##0.000"])
    add("fmt_both", nums, :cellIs; operator = "greaterThan", value = "0", dxStyle = "greenfilltext", font = ["color" => "red"])
    add("stop", nums, :cellIs; operator = "greaterThan", value = "3", stopIfTrue = "true", dxStyle = "greenfilltext")
    k = add("overlap_1", nums, :cellIs; operator = "greaterThan", value = "6", dxStyle = "redfilltext")
    for (op, v, dx) in (("greaterThan", "3", "yellowfilltext"), ("greaterThan", "0", "greenfilltext"))
        setConditionalFormat(ws, "B$k:K$k", :cellIs; operator = op, value = v, dxStyle = dx)
    end
    k = add("partial_1", nums, :cellIs; operator = "greaterThan", value = "2", dxStyle = "redfill", rng = "B#:F#")
    setConditionalFormat(ws, "D$k:K$k", :cellIs; operator = "lessThan", value = "8", dxStyle = "redtext")
    k = add("mixedkinds_1", nums, :cellIs; operator = "greaterThan", value = "5", dxStyle = "redfilltext")
    setConditionalFormat(ws, "B$k:K$k", :dataBar); setConditionalFormat(ws, "B$k:K$k", :colorScale)
    add("multirange", nums, :cellIs; operator = "greaterThan", value = "5", rng = "B#:C#,F#:G#")
    add("single_cell", nums, :cellIs; operator = "greaterThan", value = "5", rng = "D#")
    for db in ("bluegrad", "greengrad", "redgrad", "orangegrad", "lightbluegrad", "purplegrad",
               "blue", "green", "red", "orange", "lightblue", "purple")
        add("dataBar_$db", nums, :dataBar; databar = db)
    end
    add("dataBar_default", nums, :dataBar)
    add("dataBar_noval", nums, :dataBar; showVal = "false")
    add("dataBar_nograd", nums, :dataBar; gradient = "false")
    add("dataBar_borders", nums, :dataBar; borders = "true", border_col = "cyan")
    add("dataBar_sameneg", nums, :dataBar; gradient = "false", sameNegFill = "true", sameNegBorders = "true")
    add("dataBar_cols", nums, :dataBar; fill_col = "coral", border_col = "cyan", neg_fill_col = "cyan", neg_border_col = "coral")
    add("dataBar_rtl", nums, :dataBar; direction = "rightToLeft")
    add("dataBar_ltr", nums, :dataBar; direction = "leftToRight")
    add("dataBar_axisnone", nums, :dataBar; axis_pos = "none")
    add("dataBar_axismiddle", nums, :dataBar; axis_pos = "middle", axis_col = "magenta")
    add("dataBar_auto", nums, :dataBar; min_type = "automatic", max_type = "automatic")
    add("dataBar_minmax", nums, :dataBar; min_type = "min", max_type = "max")
    add("dataBar_num", nums, :dataBar; min_type = "num", max_type = "num", min_val = "-1", max_val = "6")
    add("dataBar_percent", nums, :dataBar; min_type = "percent", max_type = "percent", min_val = "20", max_val = "60")
    add("dataBar_percentile", nums, :dataBar; min_type = "percentile", max_type = "percentile", min_val = "20", max_val = "80")
    add("dataBar_formula", nums, :dataBar; min_type = "num", max_type = "formula", min_val = "\$M\$1", max_val = "\$M\$1 * \$M\$2 + 3")
    add("dataBar_least", nums, :dataBar; min_type = "least", max_type = "highest")
    k = row!("coloredBars_default", nums); setColoredDataBars(ws, "B$k:K$k")
    k = row!("coloredBars_3", nums); setColoredDataBars(ws, "B$k:K$k"; bands = 3, colors = ["green", "orange", "red"], min_val = "0", max_val = "10")
    for cs in ("redyellowgreen", "greenyellowred", "redwhitegreen", "greenwhitered", "redwhiteblue", "bluewhitered",
               "redwhite", "whitered", "whitegreen", "greenwhite", "yellowgreen", "greenyellow")
        add("colorScale_$cs", nums, :colorScale; colorscale = cs)
    end
    add("colorScale_default", nums, :colorScale)
    add("colorScale_2num", nums, :colorScale; min_type = "num", min_val = "2", min_col = "tomato", max_type = "num", max_val = "8", max_col = "cadetblue")
    add("colorScale_3num", nums, :colorScale; min_type = "num", min_val = "2", min_col = "tomato", mid_type = "num", mid_val = "6",
        mid_col = "lawngreen", max_type = "num", max_val = "10", max_col = "cadetblue")
    add("colorScale_minmax", nums, :colorScale; min_type = "min", min_col = "FFFF0000", max_type = "max", max_col = "FF00FF00")
    add("colorScale_percent", nums, :colorScale; min_type = "percent", min_val = "10", mid_type = "percent", mid_val = "50", max_type = "percent", max_val = "90")
    add("colorScale_percentile", nums, :colorScale; min_type = "percentile", min_val = "10", mid_type = "percentile", mid_val = "50", max_type = "percentile", max_val = "90")
    add("colorScale_formula", nums, :colorScale; min_type = "formula", min_val = "\$M\$1", max_type = "formula", max_val = "\$M\$1*3")
    for is in ("3Arrows", "4Arrows", "5Arrows", "3ArrowsGray", "4ArrowsGray", "5ArrowsGray", "3TrafficLights", "3TrafficLights2",
               "4TrafficLights", "3Signs", "4RedToBlack", "3Symbols", "3Symbols2", "3Flags", "5Quarters", "4Rating", "5Rating",
               "3Triangles", "3Stars", "5Boxes")
        add("iconSet_$is", nums, :iconSet; iconset = is)
    end
    add("iconSet_default", nums, :iconSet)
    add("iconSet_reverse", nums, :iconSet; iconset = "3Arrows", reverse = "true")
    add("iconSet_noval", nums, :iconSet; iconset = "3Arrows", showVal = "false")
    add("iconSet_thresholds", nums, :iconSet; iconset = "5Boxes", reverse = "true", showVal = "false",
        min_type = "num", mid_type = "percentile", mid2_type = "percentile", max_type = "num",
        min_val = "3", mid_val = "45", mid2_val = "65", max_val = "8",
        min_gte = "false", mid_gte = "false", mid2_gte = "false", max_gte = "false")
    add("iconSet_4thresholds", nums, :iconSet; iconset = "4Arrows", min_type = "num", mid_type = "formula", max_type = "percent",
        min_val = "2", mid_val = "\$M\$1+1", max_val = "70")
    add("iconSet_custom3", nums, :iconSet; iconset = "Custom", icon_list = [31, 24, 1], min_type = "num", max_type = "num",
        min_val = "3", max_val = "7")
    add("iconSet_custom2", nums, :iconSet; iconset = "Custom", icon_list = [31, 24], min_type = "num", max_type = "formula",
        min_val = "3", max_val = "if(\$M\$4=\"y\", \$M\$1+5, 10)")
    add("iconSet_custom5", nums, :iconSet; iconset = "Custom", icon_list = [1, 10, 20, 30, 40],
        min_type = "num", mid_type = "num", mid2_type = "num", max_type = "num", min_val = "1", mid_val = "3", mid2_val = "5", max_val = "7")
    k = row!("rows_cols_form", nums)
    setConditionalFormat(ws, k:k, 2:6, :cellIs; operator = "greaterThan", value = "1")
    ws["M1"] = 4; ws["M2"] = 2; ws["M3"] = "the"; ws["M4"] = "y"
    for i in 1:10; ws[i, 15] = i; end
    setConditionalFormat(ws, "O:O", :dataBar; databar = "green")
    o = addsheet!(xf, "Other")
    o["A1"] = 3
    for i in 1:5; o[i + 1, 1] = i; end
    for (name, kw) in (("other_ref_first", (; type = :cellIs, operator = "greaterThan", value = "CF!\$M\$1", dxStyle = "greenfilltext")),
                       ("other_expr_first", (; type = :expression, formula = "A2>CF!\$M\$2", dxStyle = "redtext")),
                       ("other_cellIs", (; type = :cellIs, operator = "lessThan", value = "\$A\$1", dxStyle = "redfill")),
                       ("other_iconset", (; type = :iconSet, iconset = "3Flags")))
        setConditionalFormat(o, "A2:A6", kw.type; (k => v for (k, v) in pairs(kw) if k !== :type)...)
    end
    return xf, errors
end

# A file's rules by sheet and target: each entry as its tag and attributes, the style a highlight rule
# applies given by its properties (`props`), and the import's extra parentheses around a formula dropped.
function _cf_entries_of(r)
    st = r.styles
    sh = _ODS.stylesheet(st)
    function props(display)
        id = _ODS._find_named_style(st, display)
        id === nothing && return "missing:" * display
        cs = sh.cells[id + 1]
        p = sort!(vcat(cs.cell.attrs, cs.text.attrs))
        code = isempty(cs.datastyle) ? "" : _ODS._code_of_style(sh, cs.datastyle)
        return string(p, " ", code)
    end
    out = Dict{Tuple{String,String},Vector{Any}}()
    for m in eachmatch(r"<table:table table:name=\"([^\"]*)\".*?</table:table>"s, r.content)
        for f in eachmatch(r"<calcext:conditional-format calcext:target-range-address=\"([^\"]*)\">(.*?)</calcext:conditional-format>"s, m.match)
            es = Any[]
            for e in eachmatch(r"<calcext:([a-z-]+)((?:\s+[a-z:_-]+=\"[^\"]*\")*)\s*/?>", f.captures[2])
                attrs = Dict(String(a.captures[1]) => _ODS.XML.unescape(a.captures[2]) for a in eachmatch(r"calcext:([a-z_-]+)=\"([^\"]*)\"", e.captures[2]))
                for k in ("apply-style-name", "style")
                    haskey(attrs, k) && (attrs[k] = props(attrs[k]))
                end
                haskey(attrs, "value") && (attrs["value"] = replace(attrs["value"], r"^formula-is\(\((.*)\)\)$"s => s"formula-is(\1)"))
                push!(es, (e.captures[1], attrs))
            end
            out[(m.captures[1], _ODS.XML.unescape(f.captures[1]))] = vcat(get(out, (m.captures[1], _ODS.XML.unescape(f.captures[1])), Any[]), es)
        end
    end
    return out
end

# The cases whose rules differ from the import's (D-081, F-074), by target: what ours holds instead.
const _CF_DIFFERENT = Set(["CF.B2:CF.K2", "CF.B4:CF.K4",                        # greaterEqual, lessEqual: dropped by the import
                           "CF.B12:CF.K12", "CF.B14:CF.K14",                    # a formula, a text value: refused by XLSX.jl
                           "CF.B24:CF.K24", "CF.B25:CF.K25", "CF.B26:CF.K26", "CF.B27:CF.K27", "CF.B28:CF.K28", "CF.B29:CF.K29",  # standard deviations
                           "CF.B36:CF.K36",                                     # a reference kept
                           "CF.B78:CF.K78",                                     # stopIfTrue (D-084)
                           "CF.B99:CF.K99", "CF.B100:CF.K100", "CF.B101:CF.K101", "CF.B102:CF.K102",   # borders; sameNegBorders; border colours; direction
                           "CF.B111:CF.K111",                                   # a reference with `num`
                           "CF.B142:CF.K142",                                   # 4TrafficLights
                           "CF.B155:CF.K155", "CF.B156:CF.K156", "CF.B157:CF.K157",   # reverse (D-084); showVal
                           "CF.B159:CF.K159", "CF.B161:CF.K161",               # custom icons (F-077, D-084)
                           "CF.O1:CF.O162", "CF.O1:CF.O1048576",               # a whole column
                           "Other.A2:Other.A6"])                                # another sheet's cell as a value: refused by XLSX.jl
_cf_is_band(t) = occursin(r"^CF\.[B-K]11[34]:CF\.[B-K]11[34]$", t)     # setColoredDataBars' bands: sameNegFill

@testset "setConditionalFormat" begin
    xf, errors = _cf_build()
    dir = mktempdir()
    ours = readods(writeods(joinpath(dir, "ours.ods"), xf))
    imp = readods(_cfr("lo-cf-import.ods"))
    a = _cf_entries_of(ours); b = _cf_entries_of(imp)

    @testset "as LibreOffice's import writes XLSX.jl's rules" begin
        for (key, es) in b
            (key[2] in _CF_DIFFERENT || _cf_is_band(key[2])) && continue
            @test get(a, key, nothing) == es
        end
        @test count(k -> !(k[2] in _CF_DIFFERENT) && !_cf_is_band(k[2]), keys(b)) >= 135
        # the getter's view matches the oracle (types and order), but for the cases that differ
        @test length(getConditionalFormats(ours["CF"])) == length(getConditionalFormats(xf["CF"]))
    end

    @testset "where LibreOffice's own form is written instead of the import's (D-081)" begin
        v(t) = [e[2]["value"] for e in a[("CF", t)] if haskey(e[2], "value")]
        @test v("CF.B2:CF.K2") == [">=4"] && v("CF.B4:CF.K4") == ["<=4"]
        @test v("CF.B12:CF.K12") == [">SUM([.\$M\$1:.\$M\$2])/2"]     # a formula (XLSX.jl refuses it)
        @test v("CF.B14:CF.K14") == ["=\"other\""]
        @test v("CF.B35:CF.K35") == ["contains-text(\"\"q\"\")"]                # quotes not doubled: LibreOffice's form
        @test v("CF.B36:CF.K36") == ["contains-text([.\$M\$3])"]
        @test a[("CF", "CF.B111:CF.K111")][2] == ("formatting-entry", Dict("value" => "=[.\$M\$1]", "type" => "formula"))
        @test a[("CF", "CF.B142:CF.K142")][1][2]["icon-set-type"] == "4TrafficLights"
        @test a[("CF", "CF.B156:CF.K156")][1][2]["show-value"] == "true"          # read inverted (F-075)
        @test !any(e -> haskey(e[2], "show-value") && e[1] == "formatting-entry", a[("CF", "CF.B156:CF.K156")])
        @test haskey(a, ("CF", "CF.O1:CF.O1048576"))
        @test [e[2]["value"] for e in a[("Other", "Other.A2:Other.A6")] if haskey(e[2], "value")][1] == ">[\$CF.\$M\$1]"
        # the thresholds of the case refused for `reverse`, without it: the import's entries
        x157 = newods("S")
        for i in 1:10; x157["S"][i, 1] = i; end
        setConditionalFormat(x157["S"], "A1:A10", :iconSet; iconset = "5Boxes", showVal = "false",
            min_type = "num", mid_type = "percentile", mid2_type = "percentile", max_type = "num",
            min_val = "3", mid_val = "45", mid2_val = "65", max_val = "8",
            min_gte = "false", mid_gte = "false", mid2_gte = "false", max_gte = "false")
        e157 = _cf_entries_of(readods(writeods(joinpath(dir, "t157.ods"), x157)))[("S", "S.A1:S.A10")]
        @test [e[2] for e in e157 if e[1] == "formatting-entry"] == [e[2] for e in b[("CF", "CF.B157:CF.K157")] if e[1] == "formatting-entry"]
        @test all(t -> !haskey(a[("CF", t)][1][2], "negative-color"), filter(_cf_is_band, [k[2] for k in keys(a)]))
        @test length(filter(_cf_is_band, [k[2] for k in keys(a)])) == length(filter(_cf_is_band, [k[2] for k in keys(b)]))
        for t in ("CF.B99:CF.K99", "CF.B100:CF.K100", "CF.B101:CF.K101", "CF.B102:CF.K102", "CF.B24:CF.K24",
                  "CF.B78:CF.K78", "CF.B155:CF.K155", "CF.B157:CF.K157", "CF.B159:CF.K159", "CF.B161:CF.K161")
            @test !haskey(a, ("CF", t))
        end
    end

    @testset "what LibreOffice can't store is an error" begin
        @test Set(keys(errors)) == Set(["aboveAverage_plus1StdDev", "aboveAverage_plus2StdDev", "aboveAverage_plus3StdDev",
                                        "aboveAverage_minus1StdDev", "aboveAverage_minus2StdDev", "aboveAverage_minus3StdDev",
                                        "dataBar_borders", "dataBar_sameneg", "dataBar_cols", "dataBar_rtl", "dataBar_minmax", "stop",
                                        "iconSet_reverse", "iconSet_thresholds", "iconSet_custom3", "iconSet_custom2", "iconSet_custom5"])
        @test occursin("standard deviations", errors["aboveAverage_plus1StdDev"])
        @test occursin("no borders", errors["dataBar_borders"]) && occursin("no borders", errors["dataBar_cols"])
        @test occursin("left to right", errors["dataBar_rtl"])
        @test occursin("Invalid min_type: min", errors["dataBar_minmax"])
        @test occursin("`stopIfTrue` is not supported", errors["stop"])
        @test occursin("Custom icon sets", errors["iconSet_custom3"]) && occursin("Custom icon sets", errors["iconSet_custom2"])
        @test occursin("reversed icon set", errors["iconSet_reverse"])
        ws = newods()[1]
        @test_throws ODSError setConditionalFormat(ws, "A1", :cellIs; priority = 1)
        @test_throws ODSError setConditionalFormat(ws, "A1", :nope)
        @test_throws ODSError setConditionalFormat(ws, "A1", :cellIs; operator = "gt", value = "1")
        @test_throws ODSError setConditionalFormat(ws, "A1:B2", :cellIs)          # no numbers for the default value
        @test_throws ODSError setConditionalFormat(ws, "A1", :cellIs; operator = "between", value = "1")
        @test_throws ODSError setConditionalFormat(ws, "A1", :cellIs; value = "1", bogus = 1)
        @test_throws ODSError setConditionalFormat(ws, "A1", :cellIs; value = "1", dxStyle = "bluefill")
        @test_throws ODSError setConditionalFormat(ws, "A1", :cellIs; value = "1", font = ["colour" => "red"])
        @test_throws ODSError setConditionalFormat(ws, "A1", :cellIs; value = "1", style = "Good", dxStyle = "redfill")
        @test_throws ODSError setConditionalFormat(ws, "A1", :cellIs; value = "1", style = "No Such Style")
        @test_throws ODSError setConditionalFormat(ws, "A1", :containsText)
        @test_throws ODSError setConditionalFormat(ws, "A1", :beginsWith; value = "a", operator = "endsWith")
        @test_throws ODSError setConditionalFormat(ws, "A1", :timePeriod; operator = "someday")
        @test_throws ODSError setConditionalFormat(ws, "A1", :expression)
        @test_throws ODSError setConditionalFormat(ws, "A1", :iconSet; iconset = "9Arrows")
        @test_throws ODSError setConditionalFormat(ws, "A1", :iconSet; iconset = "3Arrows", icon_list = [1, 2, 3])
        @test_throws ODSError setConditionalFormat(ws, "A1", :cellIs; value = "1", stopIfTrue = "false")
        @test setConditionalFormat(ws, "A1", :iconSet; reverse = "false") === 0
        deleteConditionalFormats(ws, "A1")
        @test_throws ODSError setConditionalFormat(ws, "A1", :colorScale; colorscale = "rainbow")
        @test_throws ODSError setConditionalFormat(ws, "A1", :colorScale; min_type = "percent")
        @test_throws ODSError setConditionalFormat(ws, "A1", :dataBar; min_type = "percent", min_val = "\$A\$1")
        @test_throws ODSError setConditionalFormat(ws, "A1", :dataBar; minLength = 50, maxLength = 20)
        @test_throws ODSError setConditionalFormat(readods(_cfr("lo-cf-own.ods"))[1], "A1", :cellIs; value = "1")
        @test isempty(getConditionalFormats(ws))
    end

    @testset "the forms of the range and of the call" begin
        xs = newods("S")
        ws = xs["S"]
        @test setConditionalFormat(ws, "A1:B2", :cellIs; value = "1") === 0
        @test setConditionalFormat(xs, "S!C1:C5", :cellIs; value = "1") === 0
        @test setConditionalFormat(xs, "S.D1", :cellIs; value = "1") === 0
        @test setConditionalFormat(ws, 1:2, 5, :cellIs; value = "1") === 0
        @test setConditionalFormat(ws, "F:F", :dataBar) === 0
        @test setConditionalFormat(ws, 7, :, :colorScale) === 0
        @test setConditionalFormat(ws, SheetCore.CellRange("A10:B11"), :uniqueValues) === 0
        cf = getConditionalFormats(ws)
        @test [string(p.first) for p in cf] == ["A1:B2", "C1:C5", "D1:D1", "E1:E2", "F1:F1048576", "A7:XFD7", "A10:B11"]
        @test [p.second.type for p in cf] == ["cellIs", "cellIs", "cellIs", "cellIs", "dataBar", "colorScale", "uniqueValues"]
        # the same range again: the format's next entry; its priority is its order
        setConditionalFormat(ws, "C1:C5", :top10)
        cf = getConditionalFormats(ws)
        @test [(string(p.first), p.second.priority) for p in cf][2:3] == [("C1:C5", 2), ("C1:C5", 3)]
        # LibreOffice's options (D-076): any named style, LibreOffice's periods and icon sets, bar lengths
        setConditionalFormat(ws, "H1:H5", :timePeriod; operator = "nextYear", style = "Good")
        setConditionalFormat(ws, "I1:I5", :iconSet; iconset = "3ColorSmilies")
        setConditionalFormat(ws, "J1:J5", :dataBar; minLength = 0, maxLength = 100)
        addCellStyle(xs, "My Rule"; font = (bold = true,))
        setConditionalFormat(ws, "K1:K5", :cellIs; value = "1", style = "My Rule")
        setConditionalFormat(ws, "L1:L5", :cellIs; value = "1", font = ["name" => "Liberation Serif", "size" => "14", "color" => "red"])
        r = readods(writeods(joinpath(mktempdir(), "opts.ods"), xs))
        e = _cf_entries_of(r)
        @test e[("S", "S.H1:S.H5")][1][2]["date"] == "next-year"
        @test occursin("#ccffcc", e[("S", "S.H1:S.H5")][1][2]["style"])          # Good, added to the file
        @test e[("S", "S.I1:S.I5")][1][2]["icon-set-type"] == "3ColorSmilies"
        @test !haskey(e[("S", "S.J1:S.J5")][1][2], "min-length") && e[("S", "S.J1:S.J5")][1][2]["max-length"] == "100"
        @test occursin("\"bold\"", e[("S", "S.K1:S.K5")][1][2]["apply-style-name"])
        @test occursin("14pt", e[("S", "S.L1:S.L5")][1][2]["apply-style-name"]) && occursin("Liberation Serif", e[("S", "S.L1:S.L5")][1][2]["apply-style-name"])
        @test occursin("calcext:apply-style-name=\"My Rule\"", r.content)          # by display name (F-075)
        @test _ODS.getCellStyle(r["S"], "K1") == "Default"                              # cells keep their own style
    end

    @testset "LibreOffice reads our rules as we wrote them" begin
        if lo_ok(; what = "the conditional formats oracle")
            d = mktempdir()
            profile = lo_profile_url(joinpath(d, "lo-profile"))
            # a new file (zipped and flat), and a patched one with rules added, cleared and moved
            n = writeods(joinpath(d, "new.ods"), xf)
            nf = writeods(joinpath(d, "newflat.fods"), xf)
            p = openods(_cfr("lo-cf-own.ods"); mode = "rw")
            setConditionalFormat(p["Own"], "M1:M10", :dataBar; databar = "orange")
            setConditionalFormat(p["Own"], "B1:K1", :cellIs; operator = "lessThan", value = "0", dxStyle = "greenfilltext")
            deleteConditionalFormats(p["Own"], "B2:K10"); insertRows(p["Own"], 3)
            setConditionalFormat(p["Second"], "A5:A9", :timePeriod; operator = "lastYear", style = "Accent 1")
            pf = writeods(joinpath(d, "patched.ods"), p)
            lo_convert([n, nf, pf], "fods"; outdir = joinpath(d, "lo"), profile = profile)
            # every LibreOffice reads the rules (their ranges and kinds)
            rset(f) = Set((string(p.first), p.second.type) for ws in (readods(f)["CF"], readods(f)["Other"]) for p in getConditionalFormats(ws))
            @test rset(joinpath(d, "lo", "new.fods")) == rset(joinpath(d, "lo", "newflat.fods")) == rset(n)
            # the forms, as the fixtures' LibreOffice writes them (CI's distribution one is older)
            if lo_major(SOFFICE) < LO_FIXTURE_MAJOR
                @info "LibreOffice $(lo_major(SOFFICE)) is older than the fixtures' $LO_FIXTURE_MAJOR: its forms of the rules are not compared"
                @test_skip false
            else
            ln = _cf_entries_of(readods(joinpath(d, "lo", "new.fods")))
            lf = _cf_entries_of(readods(joinpath(d, "lo", "newflat.fods")))
            # what LibreOffice's reader or writer changes (F-075): `show-value` moved
            quirky = Set(["CF.B156:CF.K156"])
            for (key, es) in a
                key[2] in quirky && continue
                @test get(ln, key, nothing) == es
                @test get(lf, key, nothing) == es
            end
            @test keys(ln) == keys(a)
            @test ln[("CF", "CF.B156:CF.K156")][2][2]["show-value"] == "false"     # read as hidden, written its way
            lp = readods(joinpath(d, "lo", "patched.fods"))
            # (but for two of LibreOffice's own empty formula entries, which it saved as `Err:520` and writes
            # again as `=err:520`)
            noerr(d) = filter(kv -> !any(e -> occursin(r"(?i)err:520", get(e[2], "value", "")), kv.second), d)
            @test noerr(_cf_entries_of(lp)) == noerr(_cf_entries_of(readods(pf)))
            @test length(noerr(_cf_entries_of(lp))) == length(_cf_entries_of(lp)) - 2
            end
        end
    end

    @testset "new rules through edits, copies and saves" begin
        # a new file: no operations logged, the rules rewritten as the edits happen
        xn = newods("A")
        a1 = xn["A"]
        for i in 1:10; a1[i, 1] = i; a1[i, 2] = 11 - i; end
        setConditionalFormat(a1, "A1:A10", :expression; formula = "A1>B1")
        setConditionalFormat(a1, "B2:B5", :cellIs; operator = "greaterThan", value = "\$A\$1")
        insertRows(a1, 1); deleteColumns(a1, "A")
        c = copysheet!(a1, "Copy")
        e = _cf_entries_of(readods(writeods(joinpath(mktempdir(), "n.ods"), xn)))
        @test haskey(e, ("A", "A.A3:A.A6")) && e[("A", "A.A3:A.A6")][1][2]["value"] == ">#REF!" ||
              e[("A", "A.A3:A.A6")][1][2]["value"] == ">[#REF!]"
        @test !any(k -> k[1] == "A" && occursin("A.A2:A.A11", k[2]), keys(e))   # the expression's column is gone
        @test haskey(e, ("Copy", "Copy.A3:Copy.A6"))
        @test [p.second.type for p in getConditionalFormats(c)] == ["cellIs"]
        # a file's sheet: rules added, then the lines move
        p = openods(_cfr("lo-cf-ops-base.ods"); mode = "rw")
        s = p["S"]
        setConditionalFormat(s, "G2:G4", :expression; formula = "G2>\$A\$1")
        insertRows(s, 1; count = 2); insertColumns(s, "A")
        e = _cf_entries_of(readods(writeods(joinpath(mktempdir(), "p.ods"), p)))
        @test e[("S", "S.H4:S.H6")][1][2]["value"] == "formula-is([.H4]>[.\$B\$3])"
        @test e[("S", "S.H4:S.H6")][1][2]["base-cell-address"] == "S.H4"
        @test haskey(e, ("S", "S.C3:S.C12"))                    # a file rule, moved by the save
        # a sheet copy after rules were set: the copy's text has them
        q = openods(_cfr("lo-cf-ops-base.ods"); mode = "rw")
        setConditionalFormat(q["S"], "G1", :uniqueValues)
        cq = copysheet!(q["S"], "Q")
        @test count(x -> x.second.type == "uniqueValues", getConditionalFormats(cq)) == 1
        e = _cf_entries_of(readods(writeods(joinpath(mktempdir(), "q.ods"), q)))
        @test haskey(e, ("Q", "Q.G1:Q.G1")) && haskey(e, ("S", "S.G1:S.G1"))
    end

    @testset "setColoredDataBars, as XLSX.jl bands the values" begin
        xc = newods("C")
        w = xc["C"]
        for (j, v) in enumerate([-3, 1, 2, 3, 4, 5, 6, 7, 8, 9]); w[1, j] = v; end
        w[2, 1] = "text"; w[2, 2] = true
        setConditionalFormat(w, "A1:J1", :cellIs; value = "1")
        p5 = setColoredDataBars(w, "A1:J2")
        @test [first(x) for x in p5] == [1, 2, 3, 4, 5]
        @test [string(last(x)) for x in p5] == ["'C'.A1:A1", "'C'.B1:B1", "'C'.C1:E1", "'C'.F1:G1", "'C'.H1:J1"]   # 'C' quoted, as LibreOffice quotes it
        cf = getConditionalFormats(w)
        @test all(x -> x.second.type == "dataBar", cf) && length(cf) == 5     # the cellIs within the range was cleared
        p2 = setColoredDataBars(w, "A1:J1"; breaks = [4], gte = false, colors = ["blue", "red"], clear = false)
        @test [string(last(x)) for x in p2] == ["'C'.A1:E1", "'C'.F1:J1"]
        @test length(getConditionalFormats(w)) == 7
        @test setColoredDataBars(w, "A1:J1"; bands = 1) == [1 => SheetCore.CellRange("A1:J1")]
        @test length(getConditionalFormats(w)) == 1
        @test_throws ODSError setColoredDataBars(w, "A1:J1"; min_type = "percent")
        @test_throws ODSError setColoredDataBars(w, "A1:J1"; colors = ["red", "green", "blue"], bands = 5)
        @test_throws ODSError setColoredDataBars(w, "A2:B2")
        @test_throws ODSError setColoredDataBars(w, "A1:J1"; direction = "rightToLeft")
        e = _cf_entries_of(readods(writeods(joinpath(mktempdir(), "c.ods"), xc)))
        bar = e[("C", "'C'.A1:'C'.J1")]
        @test bar[1][2]["gradient"] == "false" && !haskey(bar[1][2], "negative-color")
        @test bar[2][2] == Dict("value" => "-3", "type" => "number") && bar[3][2] == Dict("value" => "9", "type" => "number")
    end
end

@testset "setColoredDataBars: a refused call keeps the range's formats" begin
    xf = newods(); ws = xf[1]
    for r in 1:4; ws[r, 2] = r; end
    setConditionalFormat(ws, "B1:B4", :cellIs; operator = "greaterThan", value = "2")
    # `gte` of the wrong length was checked after the range was cleared
    @test_throws ODSError setColoredDataBars(ws, "B1:B4"; bands = 3, gte = [true])
    @test length(getConditionalFormats(ws)) == 1
    @test_throws ODSError setColoredDataBars(ws, "B1:B4"; bands = 3, max_type = "percent")
    @test_throws ODSError setColoredDataBars(ws, "B1:B4"; bands = 1, colors = ["nocolour"])
    @test length(getConditionalFormats(ws)) == 1
    @test length(setColoredDataBars(ws, "B1:B4"; bands = 2)) == 2            # and a good call still clears it
    @test length(getConditionalFormats(ws)) == 2
end

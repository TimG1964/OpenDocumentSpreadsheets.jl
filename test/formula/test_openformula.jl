# OpenFormula: the tokenizer, and the renderer to LibreOffice's UI notation (D-018), checked
# against LibreOffice's own =FORMULA() output (experiment 008: test/data/formula/*.tsv).

using OpenDocumentSpreadsheets: tokenize_formula, render_ui_formula, ui_function_name, _strip_formula_prefix,
    FT_REF, FT_FUNC, FT_NAME, FT_NUMBER, FT_STRING, FT_ERROR, FT_OP, FT_SEP, FT_ROWSEP, FT_SPACE

@testset "tokenizer" begin
    s = "=SUM([.A1:.B2];'x'&\"a\"\"b\";{1;2|3;4}) <> -1.5E+3% ~ #N/A ! name_1"
    toks = tokenize_formula(s)
    @test join(t.text for t in toks) == s                 # lossless
    kinds = [t.kind for t in toks if t.kind !== FT_SPACE]
    @test FT_REF in kinds && FT_FUNC in kinds && FT_STRING in kinds && FT_ERROR in kinds && FT_ROWSEP in kinds
    @test [t.text for t in toks if t.kind === FT_NUMBER] == ["1", "2", "3", "4", "1.5E+3"]
    @test [t.text for t in toks if t.kind === FT_REF] == ["[.A1:.B2]"]
    @test [t.text for t in toks if t.kind === FT_STRING] == ["\"a\"\"b\""]
    @test [t.text for t in toks if t.kind === FT_NAME] == ["x", "name_1"]   # a stray quote is kept as it is
    @test [t.text for t in tokenize_formula("['it''s ]'.A1]+1") if t.kind === FT_REF] == ["['it''s ]'.A1]"]
    @test join(t.text for t in tokenize_formula("Ünï(1)+[.A1")) == "Ünï(1)+[.A1"   # unterminated: kept
    @test tokenize_formula("Ünï(1)")[1].kind === FT_FUNC
    @test isempty(tokenize_formula(""))
end

@testset "function names (F-025)" begin
    @test ui_function_name("COM.MICROSOFT.IFS") == "IFS"
    @test ui_function_name("ORG.OPENOFFICE.WEEKS") == "WEEKS"
    @test ui_function_name("LEGACY.NORMSDIST") == "NORMSDIST"
    @test ui_function_name("COM.MICROSOFT.CEILING") == "CEILING.XCL"
    @test ui_function_name("FDIST") == "F.DIST"
    @test ui_function_name("com.microsoft.weeknum") == "com.microsoft.weeknum"
    @test ui_function_name("SUM") == "SUM"
end

@testset "prefixes" begin
    @test _strip_formula_prefix("of:=1+1") == "=1+1"
    @test _strip_formula_prefix("oooc:=[.A1]") == "=[.A1]"
    @test _strip_formula_prefix("=1+2") == "=1+2"
    @test _strip_formula_prefix("msoxl:=A1") == "=A1"
end

@testset "LibreOffice oracle: $f" for f in ("lo-syntax.tsv", "lo-names.tsv", "lo-names2.tsv")
    rows = read_tsv(joinpath(DATA, "formula", f))
    @test length(rows) > 40
    for row in rows
        stored, ui = f == "lo-syntax.tsv" ? (row[3], row[4]) : (row[2], row[3])
        startswith(stored, "of:") || continue
        got = render_ui_formula(_strip_formula_prefix(stored))
        got == ui || @info "renderer differs from LibreOffice" stored ui got
        @test got == ui
    end
end

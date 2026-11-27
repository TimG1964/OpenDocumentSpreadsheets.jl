# OpenDocumentSpreadsheets uses only the public API of Julia and of its dependencies (the user's rule,
# 2026-11-18), and its imports are explicit and current: ExplicitImports.jl checks the names,
# and a scan below checks field access on library types, which ExplicitImports does not.
import ExplicitImports as EI

# Documented API that its owner does not mark with `public` (checked on Julia 1.11+):
const DOCUMENTED_NOT_MARKED = (
    :HasLength, :SizeUnknown,               # Base: the iteration interface (manual: Interfaces, IteratorSize)
    :CompoundPeriod, :value,                # Dates: in the Dates manual and API reference
    # Tables.jl does not use `public`; these are its documented interface:
    :istable, :rows, :columns, :getcolumn, :columnnames, :schema, :Schema, :rowaccess,
    :columnaccess, :columntable, :Columns, :CopiedColumns, :AbstractColumns,
    # Parsers.jl 2 (allowed by compat; CI has a job for it) documents `Parsers.tryparse` in
    # its README but marks nothing `public`; Parsers.jl 3 marks it public:
    (pkgversion(OpenDocumentSpreadsheets.Parsers) < v"3" ? (:tryparse,) : ())...,
    # XML.jl 0.4 documents `XML.write` and its `pretty` keyword in its README (*Writing*) but doesn't
    # mark it public. Its public writer, `show`, indents, which changes LibreOffice's text (F-094, D-102):
    :write,
)
# Imported only to be re-exported (declared `public` in OpenDocumentSpreadsheets on Julia 1.11+; on 1.10
# nothing marks them as used):
const REEXPORTED = (
    # the chart names XLSX.jl also binds at its top level (phase 8)
    :AbstractChart, :Chart, :ChartEx, :ChartRef, :ChartSeries, :getChart, :getChartData, :getChartRanges, :getChartSchema,
    :getChartType, :getCharts, :addSparklines, :getSparklines, :deleteSparklines)

@testset "explicit imports" begin
    @test EI.check_no_implicit_imports(OpenDocumentSpreadsheets) === nothing
    @test EI.check_no_stale_explicit_imports(OpenDocumentSpreadsheets; ignore = REEXPORTED) === nothing
    @test EI.check_all_explicit_imports_via_owners(OpenDocumentSpreadsheets) === nothing
    @test EI.check_all_qualified_accesses_via_owners(OpenDocumentSpreadsheets) === nothing
    @test EI.check_no_self_qualified_accesses(OpenDocumentSpreadsheets) === nothing
    if VERSION >= v"1.11"
        @test EI.check_all_explicit_imports_are_public(OpenDocumentSpreadsheets) === nothing
        @test EI.check_all_qualified_accesses_are_public(OpenDocumentSpreadsheets; ignore = DOCUMENTED_NOT_MARKED) === nothing
    end
end

@testset "no field access on library types" begin
    # XML.jl's Cursor (use XML.nodetype / XML.depth), IOBuffer and SubString internals
    src = joinpath(dirname(@__DIR__), "src")
    for (dir, _, files) in walkdir(src), f in files
        endswith(f, ".jl") || continue
        text = read(joinpath(dir, f), String)
        for pat in (r"\b(c|ch|el)\.(nodetype|depth|held|token|st)\b", r"\.(offset|ncodeunits)\b(?!\()",
                    r"\bbuf\.(data|size|ptr)\b", r"\bio\.(data|size|ptr)\b", r"\bsourcetext\([^)]*\)\.string\b")
            hits = [m.match for m in eachmatch(pat, text)]
            isempty(hits) || @info "field access" f hits
            @test isempty(hits)
        end
    end
end

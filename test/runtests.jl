using OpenDocumentSpreadsheets
using Test

const SheetCore = OpenDocumentSpreadsheets.SheetCore
const DATA = joinpath(@__DIR__, "data")

# A LibreOffice profile folder as the file URL `-env:UserInstallation` takes: file:///C:/… on
# Windows, file:///tmp/… elsewhere.
lo_profile_url(path) = "file://" * (startswith(path, "/") ? "" : "/") * replace(path, "\\" => "/")

# The major version of a LibreOffice (`soffice --version`: "LibreOffice 24.2.7.2 …"), or 0 if unknown.
# Features newer than a distribution's LibreOffice (threaded comments in notes) are checked only
# with the version the fixtures were made with (`data/lo-version.txt`) or later.
const _LO_MAJOR = Dict{String,Int}()
lo_major(soffice) = get!(_LO_MAJOR, soffice) do
    m = match(r"LibreOffice\s+(\d+)\.", try read(`$soffice --version`, String) catch; "" end)
    m === nothing ? 0 : parse(Int, m.captures[1])
end
const LO_FIXTURE_MAJOR = parse(Int, match(r"LibreOffice\s+(\d+)\.", read(joinpath(DATA, "lo-version.txt"), String)).captures[1])
# The major and minor version: a distribution's LibreOffice can share the fixtures' major version and
# still lack a feature of its minor one (CI's 26.x: threaded comments, the histogram; phase 9).
_lo_vnum(s) = (m = match(r"LibreOffice\s+(\d+)\.(\d+)", s); m === nothing ? v"0" : VersionNumber(parse(Int, m.captures[1]), parse(Int, m.captures[2])))
const _LO_VERSION = Dict{String,VersionNumber}()
lo_version(soffice) = get!(() -> _lo_vnum(try read(`$soffice --version`, String) catch; "" end), _LO_VERSION, soffice)
const LO_FIXTURE_VERSION = _lo_vnum(read(joinpath(DATA, "lo-version.txt"), String))

# The suite, in groups by function (issue #2). A passing run lists each group and each file in it; a
# file's own testsets show only when something in them fails.
#
# To run some groups only, name them (their keys below):
#     julia --project -e 'using Pkg; Pkg.test(test_args = ["charts", "styles"])'
#     julia --project test/runtests.jl charts styles
const _GROUPS = ("core", "container", "read", "formulas", "write", "charts", "styles", "display", "speed", "docs", "api", "aqua")
for g in ARGS
    g in _GROUPS || error("Unknown test group `$g`: use one of " * join(_GROUPS, ", ") * ".")
end
_rungroup(g) = isempty(ARGS) || g in ARGS

# Each file in a testset of its own, named for what it tests.
macro testfile(name, file)
    esc(:(@testset $name begin include($file) end))
end

@testset verbose = true "OpenDocumentSpreadsheets" begin
    _rungroup("core") && @testset verbose = true "SheetCore" begin
        @testfile "references" "core/test_references.jl"
        @testfile "ranges" "core/test_ranges.jl"
        @testfile "reference styles" "core/test_refstyles.jl"
        @testfile "number formats" "core/test_numfmt.jl"
        @testfile "tables, colours, widths" "core/test_misc.jl"
    end
    _rungroup("container") && @testset verbose = true "container" begin
        @testfile "reading and writing packages" "test_container.jl"
        @testfile "namespace prefixes" "test_namespaces.jl"
    end
    _rungroup("read") && @testset verbose = true "read model" begin
        @testfile "values" "model/test_values.jl"
        @testfile "workbook" "model/test_workbook.jl"
        @testfile "tables" "model/test_tables.jl"
        @testfile "byte scanner" "model/test_sheetscan.jl"
    end
    _rungroup("formulas") && @testset verbose = true "formulas" begin
        @testfile "OpenFormula" "formula/test_openformula.jl"
        @testfile "references" "formula/test_refs.jl"
    end
    _rungroup("write") && @testset verbose = true "write" begin
        @testfile "writing" "write/test_write.jl"
        @testfile "row and column edits" "write/test_lines.jl"
        @testfile "sheet operations" "write/test_sheetops.jl"
        @testfile "defined names" "write/test_names.jl"
        @testfile "hidden lines, sheets, tab colours" "write/test_sheetprops.jl"
        @testfile "groups" "write/test_groups.jl"
        @testfile "panes and views" "write/test_views.jl"
        @testfile "protection" "write/test_protection.jl"
        @testfile "printing" "write/test_printing.jl"
        @testfile "document properties" "write/test_docprops.jl"
        @testfile "cell extras" "write/test_extras.jl"
        @testfile "hyperlinks" "write/test_hyperlinks.jl"
        @testfile "rich text" "write/test_richtext.jl"
        @testfile "comments" "write/test_notes.jl"
        @testfile "pictures" "write/test_images.jl"
        @testfile "data validation" "write/test_validation.jl"
        @testfile "LibreOffice's options" "write/test_lo_options.jl"
        @testfile "tables (database ranges)" "write/test_dbtables.jl"
        @testfile "AutoFilter" "write/test_autofilter.jl"
        @testfile "sort" "write/test_sort.jl"
        @testfile "conditional formats" "write/test_conditional.jl"
        @testfile "conditional format rules" "write/test_cfrules.jl"
        @testfile "chart objects" "write/test_chartobjects.jl"
    end
    _rungroup("charts") && @testset verbose = true "charts" begin
        @testfile "reading" "charts/test_reading.jl"
        @testfile "formatting getters" "charts/test_format.jl"
        @testfile "creating" "charts/test_create.jl"
        @testfile "formatting setters" "charts/test_setters.jl"
        @testfile "histograms and chart sheets" "charts/test_chartex.jl"
        @testfile "sparklines" "charts/test_sparklines.jl"
    end
    _rungroup("styles") && @testset verbose = true "styles" begin
        @testfile "style sheet" "styles/test_stylesheet.jl"
        @testfile "row and column formats" "styles/test_formats.jl"
        @testfile "fonts, fills, borders, alignment" "styles/test_cellformat.jl"
        @testfile "number formats" "styles/test_numberformat.jl"
        @testfile "merged cells" "styles/test_merge.jl"
        @testfile "widths and heights" "styles/test_layout.jl"
        @testfile "named styles" "styles/test_namedstyles.jl"
    end
    _rungroup("display") && @testset verbose = true "REPL display" begin
        @testfile "sizes, rows, formats, charts" "test_display.jl"
    end
    _rungroup("speed") && @testset verbose = true "speed paths" begin
        @testfile "lazy reading, parsing, writing" "test_phase3.jl"
    end
    _rungroup("docs") && @testset verbose = true "docs" begin
        @testfile "examples, wording, pictures" "test_docs.jl"
    end
    _rungroup("api") && @testset verbose = true "public API only" begin
        @testfile "no internals used" "test_public_api.jl"
    end
    _rungroup("aqua") && @testset verbose = true "Aqua" begin
        @testfile "package quality" "test_aqua.jl"
    end
end

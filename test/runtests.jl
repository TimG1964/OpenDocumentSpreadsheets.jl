using OpenDocumentSpreadsheets
using Test

const SheetCore = OpenDocumentSpreadsheets.SheetCore
const DATA = joinpath(@__DIR__, "data")

# What several files use, here so that any group can run on its own (`test_args`).
using Dates
import Tables, ZipArchives, XML
const SHIFT = joinpath(DATA, "shift")
# LibreOffice as the oracle (Q-005). Skipped when it is not installed, as on CI.
const SOFFICE = get(ENV, "ODS_SOFFICE",
    Sys.iswindows() ? raw"C:\Program Files\LibreOffice\program\soffice.com" : something(Sys.which("soffice"), ""))

# A LibreOffice profile folder as the file URL `-env:UserInstallation` takes: file:///C:/… on
# Windows, file:///tmp/… elsewhere.
lo_profile_url(path) = "file://" * (startswith(path, "/") ? "" : "/") * replace(path, "\\" => "/")

# The version of a LibreOffice (`soffice --version`: "LibreOffice 24.2.7.2 …"), major and minor, or
# v"0" if unknown; read once. Features newer than a distribution's LibreOffice (threaded comments in
# notes) are checked only with the version the fixtures were made with (`data/lo-version.txt`) or
# later: by major version, or by major and minor where a distribution's LibreOffice can share the
# fixtures' major version and still lack a feature of its minor one (CI's 26.x: threaded comments,
# the histogram; phase 9).
_lo_vnum(s) = (m = match(r"LibreOffice\s+(\d+)\.(\d+)", s); m === nothing ? v"0" : VersionNumber(parse(Int, m.captures[1]), parse(Int, m.captures[2])))
const _LO_VERSION = Dict{String,VersionNumber}()
lo_version(soffice) = get!(() -> _lo_vnum(try read(`$soffice --version`, String) catch; "" end), _LO_VERSION, soffice)
lo_major(soffice) = Int(lo_version(soffice).major)
const LO_FIXTURE_VERSION = _lo_vnum(read(joinpath(DATA, "lo-version.txt"), String))
const LO_FIXTURE_MAJOR = Int(LO_FIXTURE_VERSION.major)

# Whether a LibreOffice oracle runs here: LibreOffice is installed and, given `min`, at least that
# version (an `Int`: the major version; a `VersionNumber`: major and minor). When it doesn't run, a
# skipped test is recorded, so the summary shows it, and the reason is logged, naming `what`.
function lo_ok(min::Union{Nothing,Int,VersionNumber} = nothing; what::AbstractString = "a LibreOffice oracle")
    if isempty(SOFFICE) || !isfile(SOFFICE)
        @info "LibreOffice not found; skipping $what (set ODS_SOFFICE)"
    elseif min isa Int && lo_major(SOFFICE) < min || min isa VersionNumber && lo_version(SOFFICE) < min
        @info "LibreOffice $(lo_version(SOFFICE)) is older than $min; skipping $what"
    else
        return true
    end
    @test_skip false
    return false
end

# Converts `files` (a path, or several) with LibreOffice to `fmt` (`"ods"`, `"fods"`, `"csv"`, or a
# filter with its options) in `outdir`, with the profile `profile` (a file URL: `lo_profile_url`).
# LibreOffice's messages are kept: a conversion that fails is an error that shows them.
function lo_convert(files, fmt::AbstractString; outdir::AbstractString, profile::AbstractString)
    paths = files isa AbstractString ? [files] : collect(files)
    err = IOBuffer()
    cmd = `$SOFFICE -env:UserInstallation=$profile --headless --norestore --convert-to $fmt --outdir $outdir $paths`
    success(pipeline(cmd; stdout = devnull, stderr = err)) ||
        error("LibreOffice could not convert $(join(basename.(paths), ", ")) to $fmt:\n" * String(take!(err)))
    return outdir
end

include("oracle_refs.jl")      # the oracle helpers several files share

# The suite, in groups by function (issue #2). Each group is a top-level testset, so its summary (with a
# line per file) prints as soon as it finishes; a file's own testsets show only when something in them
# fails. A group that fails doesn't stop the others: the run fails at the end, naming them.
#
# To run some groups only, name them (their keys below; "write" runs all four write groups). Every group
# runs on its own: what files share is defined above.
#     julia --project -e 'using Pkg; Pkg.test(test_args = ["charts", "styles"])'
const _GROUPS = ("core", "container", "read", "formulas", "write", "write-cells", "write-settings", "write-objects", "write-data", "charts", "styles", "display", "speed", "docs", "api", "aqua")
for g in ARGS
    g in _GROUPS || error("Unknown test group `$g`: use one of " * join(_GROUPS, ", ") * ".")
end
# A group runs when no group is named, or one of its keys is (`"write"` names all four write groups).
_rungroup(keys) = isempty(ARGS) || any(in(ARGS), keys)

# The width of the name column in every group's summary. Test pads it to the longest name in each
# top-level testset, so each group's name is padded to this width and all the tables line up: the
# longest file name ("hidden lines, sheets, tab colours", 33) and its two-space indent.
const _NAME_WIDTH = 35

# Each file in a testset of its own, named for what it tests.
macro testfile(name, file)
    textwidth(name) <= _NAME_WIDTH - 2 ||
        error("Test file name `$name` is longer than $(_NAME_WIDTH - 2) characters: widen `_NAME_WIDTH`.")
    esc(:(@testset $name begin include($file) end))
end

# A group: a top-level testset, printed when it ends. Its failures are kept for the end of the run, as a
# top-level testset throws when it ends with failures, which would skip the groups after it.
const _FAILED = String[]
function _group(body, keys, name::String)
    _rungroup(keys isa String ? (keys,) : keys) || return
    try
        @testset verbose = true "$(rpad(name, _NAME_WIDTH))" begin
            body()
        end
    catch e
        e isa Test.TestSetException || rethrow()
        push!(_FAILED, name)
    end
    return
end

_group("core", "SheetCore") do
    @testfile "references" "core/test_references.jl"
    @testfile "ranges" "core/test_ranges.jl"
    @testfile "reference styles" "core/test_refstyles.jl"
    @testfile "number formats" "core/test_numfmt.jl"
    @testfile "tables, colours, widths" "core/test_misc.jl"
end
_group("container", "container") do
    @testfile "reading and writing packages" "test_container.jl"
    @testfile "namespace prefixes" "test_namespaces.jl"
end
_group("read", "read model") do
    @testfile "values" "model/test_values.jl"
    @testfile "workbook" "model/test_workbook.jl"
    @testfile "tables" "model/test_tables.jl"
    @testfile "byte scanner" "model/test_sheetscan.jl"
end
_group("formulas", "formulas") do
    @testfile "OpenFormula" "formula/test_openformula.jl"
    @testfile "references" "formula/test_refs.jl"
end
_group(("write", "write-cells"), "write: cells and sheets") do
    @testfile "writing" "write/test_write.jl"
    @testfile "row and column edits" "write/test_lines.jl"
    @testfile "sheet operations" "write/test_sheetops.jl"
    @testfile "defined names" "write/test_names.jl"
    @testfile "read-only files" "test_readonly.jl"
end
_group(("write", "write-settings"), "write: sheet settings") do
    @testfile "hidden lines, sheets, tab colours" "write/test_sheetprops.jl"
    @testfile "groups" "write/test_groups.jl"
    @testfile "panes and views" "write/test_views.jl"
    @testfile "protection" "write/test_protection.jl"
    @testfile "printing" "write/test_printing.jl"
    @testfile "document properties" "write/test_docprops.jl"
end
_group(("write", "write-objects"), "write: notes, links, objects") do
    @testfile "cell extras" "write/test_extras.jl"
    @testfile "hyperlinks" "write/test_hyperlinks.jl"
    @testfile "rich text" "write/test_richtext.jl"
    @testfile "comments" "write/test_notes.jl"
    @testfile "pictures" "write/test_images.jl"
    @testfile "data validation" "write/test_validation.jl"
    @testfile "LibreOffice's options" "write/test_lo_options.jl"
end
_group(("write", "write-data"), "write: data tools") do
    @testfile "tables (database ranges)" "write/test_dbtables.jl"
    @testfile "AutoFilter" "write/test_autofilter.jl"
    @testfile "sort" "write/test_sort.jl"
    @testfile "conditional formats" "write/test_conditional.jl"
    @testfile "conditional format rules" "write/test_cfrules.jl"
end
_group("charts", "charts") do
    @testfile "chart objects through edits" "write/test_chartobjects.jl"
    @testfile "reading" "charts/test_reading.jl"
    @testfile "formatting getters" "charts/test_format.jl"
    @testfile "creating" "charts/test_create.jl"
    @testfile "formatting setters" "charts/test_setters.jl"
    @testfile "histograms and chart sheets" "charts/test_chartex.jl"
    @testfile "sparklines" "charts/test_sparklines.jl"
end
_group("styles", "styles") do
    @testfile "style sheet" "styles/test_stylesheet.jl"
    @testfile "row and column formats" "styles/test_formats.jl"
    @testfile "fonts, fills, borders, alignment" "styles/test_cellformat.jl"
    @testfile "number formats" "styles/test_numberformat.jl"
    @testfile "merged cells" "styles/test_merge.jl"
    @testfile "widths and heights" "styles/test_layout.jl"
    @testfile "named styles" "styles/test_namedstyles.jl"
end
_group("display", "REPL display") do
    @testfile "sizes, rows, formats, charts" "test_display.jl"
end
_group("speed", "speed paths") do
    @testfile "lazy reading, parsing, writing" "test_phase3.jl"
end
_group("docs", "docs") do
    @testfile "examples, wording, pictures" "test_docs.jl"
end
_group("api", "public API only") do
    @testfile "no internals used" "test_public_api.jl"
end
_group("aqua", "Aqua") do
    @testfile "package quality" "test_aqua.jl"
end

# The shared empty run list (`_runs_of`) is read, never changed, by every group that ran.
isempty(OpenDocumentSpreadsheets._NO_RUNS) || push!(_FAILED, "the shared `_NO_RUNS` was changed")

isempty(_FAILED) || error("Test groups with failures or errors: " * join(_FAILED, ", ") * ".")
println("All test groups passed.")

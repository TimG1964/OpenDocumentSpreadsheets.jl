# The docs' examples, as a harness shared by `test_docs.jl` (which runs them) and
# `docs/screenshots/make_screenshots.jl` (which runs them and captures LibreOffice showing the results).
#
# Every ```julia block of every page runs, in order, one module per page, as a reader would run them.
# A page that reads `budget.ods` without making it first (the home page) gets the one the Tutorial's
# first example makes; a file a page wrote itself is never replaced, so the Tutorial's examples run on
# the file as its earlier examples left it. Two pictures are there too. The variables some reference
# pages' prose describes are defined (`sh`, a sheet with values and an error; `xf`, its file). A block
# that needs a package the tests don't have (DataFrames) is skipped, and a million rows become a
# thousand. Outputs in comments aren't checked: the point is that what the docs show works.
#
# A screenshot marker after a block, `<!-- shot: NAME key=value … flag … -->`, names the image of what the
# block made (see `docs/screenshots/README.md`). It sits in a "```@raw html" block, which the pattern
# for julia blocks doesn't match.

using OpenDocumentSpreadsheets
import Dates

const DOCS = joinpath(dirname(@__DIR__), "docs", "src")

# The files the docs read without making them: only `budget.ods`, made by the Tutorial's first example.
# It is made before a block that reads it, unless the page wrote it itself (`written`), and a file a
# block writes is removed first. Other files (one an earlier example wrote, `sales.ods`) stay.
const _DOCS_INPUTS = ("budget.ods",)
const _DOCS_READ = r"(?:readods|openods|readtable|readdata)\(\"([^\"]+)\""
const _DOCS_WRITE = r"(?:writeods|writetable|streamods)\(\"([^\"]+)\""
function _docs_files(dir, block::AbstractString, written::Set{String})
    reads = Set(String(m.captures[1]) for m in eachmatch(_DOCS_READ, block))
    writes = Set(String(m.captures[1]) for m in eachmatch(_DOCS_WRITE, block))
    need = setdiff(intersect(reads, _DOCS_INPUTS), written)
    cd(dir) do
        for f in union(setdiff(writes, reads), need)
            isfile(f) && rm(f)
        end
        isempty(need) || _docs_budget()
    end
    union!(written, writes)
    return nothing
end

# budget.ods, made by the Tutorial's first example itself, so that the two can't drift apart.
function _docs_budget()
    first_block = docs_blocks(read(joinpath(DOCS, "tutorial", "tutorial.md"), String))[1][1]
    occursin("writeods(\"budget.ods\"", first_block) ||
        error("the Tutorial's first example no longer makes budget.ods")
    Base.include_string(Module(:budget), first_block, "tutorial.md example 1")
    return nothing
end

# The variables the prose of some reference pages describes (`xf`, `sh`, the names on the Addressing
# page, and an error result in C2 as if LibreOffice had saved it).
const _DOCS_PRELUDE = """
using OpenDocumentSpreadsheets, Dates
xf = newods("Sheet1")
sh = xf["Sheet1"]
sh["A1"] = 1; sh["B1"] = 2; sh["A2"] = 3; sh["B2"] = 4.5; sh["A3"] = 5; sh["A4"] = 6
setFormula(sh, "C1"; val = "=SUM(A1:B2,1)")
setFormula(sh, "C2"; val = "=1/0")
addsheet!(xf, "My sheet")["A1"] = "x"
addsheet!(xf, "Data")["B2"] = 1
addDefinedName(xf, "Totals", "Sheet1.A1:A4")
addDefinedName(sh, "LocalRange", "Sheet1.B1:B2")
df = (Month = ["Jan", "Feb"], Amount = [1025.0, 1050.0], Source = ["Sales", "Grants"])   # as the Tutorial reads it
"""


# Every page of the docs, in a fixed order.
docs_pages() = sort([joinpath(r, f) for (r, _, fs) in walkdir(DOCS) for f in fs if endswith(f, ".md")])

# A page's julia blocks, each with the screenshot markers that follow it (before the next block).
struct DocsShot
    name::String
    opts::Dict{String,String}          # key=value options; a bare flag has the value ""
end
function docs_blocks(text::AbstractString)
    out = Tuple{String,Vector{DocsShot}}[]
    for m in eachmatch(r"```julia\r?\n(.*?)```|<!--\s*shot:\s*(.*?)-->"s, text)
        if m.captures[1] !== nothing
            push!(out, (String(m.captures[1]), DocsShot[]))
        elseif !isempty(out)
            words = split(strip(m.captures[2]))
            opts = Dict{String,String}()
            for w in words[2:end]
                k, v = occursin('=', w) ? split(w, '='; limit = 2) : (w, "")
                opts[String(k)] = String(v)
            end
            push!(out[end][2], DocsShot(String(words[1]), opts))
        end
    end
    return out
end

# Runs a page's blocks in `dir`, in a module of their own. `after(m, k, shots)` is called after block `k`
# runs, with the module and the block's screenshot markers. Returns `(block number, ok, exception)` for
# each block that runs.
function run_docs_page(p::AbstractString, dir::AbstractString; after = (m, k, shots) -> nothing)
    blocks = docs_blocks(read(p, String))
    results = Tuple{Int,Bool,Any}[]
    isempty(blocks) && return results
    m = Module(Symbol(basename(p)))
    written = Set{String}()                    # the files this page's examples wrote
    for f in readdir(dir)                      # a page starts without another page's files
        f in ("logo.png", "chart.jpg") || rm(joinpath(dir, f); recursive = true)
    end
    cd(dir) do
        Core.eval(m, :(using OpenDocumentSpreadsheets))
        Base.include_string(m, _DOCS_PRELUDE, "prelude")
    end
    for (k, (b, shots)) in enumerate(blocks)
        (occursin("Pkg.add", b) || occursin("using DataFrames", b)) && continue
        b = replace(b, "1_000_000" => "1_000")      # the streaming example, scaled down
        _docs_files(dir, b, written)
        err = nothing
        try
            # what an example prints (the tutorial's rows) stays out of the test output (issue #2)
            redirect_stdout(devnull) do
                cd(() -> Base.include_string(m, b, "$(basename(p)) example $k"), dir)
            end
        catch e
            err = (e, catch_backtrace())
        end
        push!(results, (k, err === nothing, err))
        err === nothing && after(m, k, shots)
    end
    return results
end

# A directory with the pictures the docs use.
function docs_dir(testdir::AbstractString = @__DIR__)
    dir = mktempdir()
    cp(joinpath(testdir, "data", "images", "red.png"), joinpath(dir, "logo.png"))
    cp(joinpath(testdir, "data", "images", "photo.jpg"), joinpath(dir, "chart.jpg"))
    return dir
end

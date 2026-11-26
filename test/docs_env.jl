# The docs' examples, as a harness shared by `test_docs.jl` (which runs them) and
# `docs/screenshots/make_screenshots.jl` (which runs them and captures LibreOffice showing the results).
#
# Every ```julia block of every page runs, in order, one module per page, against freshly made versions
# of the files the docs talk about (`budget.ods`, `data.ods`, `report.ods`, `big.ods`, two pictures), with
# the variables the prose describes (`sh`, a sheet with values and an error; `df` and `notes`, tables; `f`,
# a function for `streamods`). A block that needs a package the tests don't have (DataFrames) is skipped,
# and a million rows become a thousand. Outputs in comments aren't checked: the point is that what the
# docs show works.
#
# A screenshot marker after a block, `<!-- shot: NAME key=value … flag … -->`, names the image of what the
# block made (see `docs/screenshots/README.md`).

using OpenDocumentSpreadsheets
import Dates

const DOCS = joinpath(dirname(@__DIR__), "docs", "src")

# The files the docs open (budget, data, report, big): made again before each block that reads one;
# a file a block writes is removed first. Other files (one an earlier example wrote, `sales.ods`) stay.
const _DOCS_INPUTS = ("budget.ods", "data.ods", "report.ods", "big.ods")
const _DOCS_READ = r"(?:readods|openods|readtable|readdata)\(\"([^\"]+)\""
const _DOCS_WRITE = r"(?:writeods|writetable|streamods)\((?:f, )?\"([^\"]+)\""
function _docs_files(dir, block::AbstractString)
    reads = Set(String(m.captures[1]) for m in eachmatch(_DOCS_READ, block))
    writes = Set(String(m.captures[1]) for m in eachmatch(_DOCS_WRITE, block))
    need = intersect(reads, _DOCS_INPUTS)
    cd(dir) do
        for f in union(setdiff(writes, reads), need)
            isfile(f) && rm(f)
        end
        isempty(need) || _docs_inputs(need)
    end
end

function _docs_inputs(need)
    begin
        months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        # budget.ods: Income and Costs (a month, an amount, a status), a Sheet1 and hidden-to-be Notes
        xf = newods("Income")
        inc = xf["Income"]
        inc[1, 1] = "Month"; inc[1, 2] = "Amount"; inc[1, 3] = "Source"; inc[1, 4] = "Note"
        for i in 1:79
            inc[i+1, 1] = months[mod1(i, 12)]; inc[i+1, 2] = 100.0 * i; inc[i+1, 3] = "Sales"; inc[i+1, 4] = ""
        end
        costs = addsheet!(xf, "Costs")
        costs[1, 1] = "Month"; costs[1, 2] = "Amount"; costs[1, 3] = "Status"
        for i in 1:12
            costs[i+1, 1] = months[i]; costs[i+1, 2] = 50.0 * i; costs[i+1, 3] = "Open"; costs[i+1, 4] = 10i
        end
        setFormula(costs, "B14"; val = "=SUM(B2:B13)")
        s1 = addsheet!(xf, "Sheet1")
        for i in 1:13, j in 1:3
            s1[i, j] = i * j
        end
        addsheet!(xf, "Notes")["A1"] = "notes"
        "budget.ods" in need && writeods("budget.ods", xf)
        # data.ods: a table on Sheet1
        xf = newods("Sheet1")
        d = xf["Sheet1"]
        d[1, 1] = "Name"; d[1, 2] = "Score"; d[1, 3] = "When"; d[1, 4] = "Value"
        for i in 2:6
            d[i, 1] = "P$i"; d[i, 2] = 1.5i; d[i, 3] = Dates.Date(2026, 1, i); d[i, 4] = i^2
        end
        "data.ods" in need && writeods("data.ods", xf)
        # report.ods: a Summary with a Region/Revenue table, its Data and Lists
        xf = newods("Summary")
        s = xf["Summary"]
        s[1, 1] = "Region"; s[1, 2] = "Revenue"; s[1, 3] = "Checked"; s[1, 4] = "Owner"
        for i in 2:50
            s[i, 1] = ["North", "South", "East", "West"][mod1(i, 4)]; s[i, 2] = 100i; s[i, 3] = "yes"; s[i, 4] = "Ann"
        end
        dd = addsheet!(xf, "Data"); dd["B10"] = 1
        l = addsheet!(xf, "Lists")
        for i in 1:9; l[i, 1] = "item $i"; end
        "report.ods" in need && writeods("report.ods", xf)
        # big.ods: one sheet of rows
        xf = newods("data")
        for i in 1:100; xf["data"][i, 1] = i; end
        "big.ods" in need && writeods("big.ods", xf)
    end
end

# The variables the guide's prose assumes.
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
df = (name = ["Ann", "Bob"], price = [9.5, 7.0])
notes = (note = ["checked"],)
f = s -> (t = addsheet!(s, "rows"); writerow!(t, (1, 2)))
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
        _docs_files(dir, b)
        err = nothing
        try
            cd(() -> Base.include_string(m, b, "$(basename(p)) example $k"), dir)
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

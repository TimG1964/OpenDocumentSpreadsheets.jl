# The docs' examples run (phase 9): every ```julia block of every page, in order, one module per page.
# Each block runs against freshly made versions of the files the docs talk about (`budget.ods`,
# `data.ods`, `report.ods`, `big.ods`, two pictures), with the variables the prose describes (`sh`, a
# sheet with values and an error; `df` and `notes`, tables; `f`, a function for `streamods`). A block
# that needs a package the tests don't have (DataFrames) is skipped, and a million rows become a thousand. Outputs in comments aren't
# checked: the point is that what the docs show works.

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

@testset "the docs' examples run" begin
    dir = mktempdir()
    cp(joinpath(@__DIR__, "data", "images", "red.png"), joinpath(dir, "logo.png"))
    cp(joinpath(@__DIR__, "data", "images", "photo.jpg"), joinpath(dir, "chart.jpg"))
    pages = vcat(sort([joinpath(DOCS, f) for f in readdir(DOCS) if endswith(f, ".md")]),
                 sort([joinpath(DOCS, "guide", f) for f in readdir(joinpath(DOCS, "guide")) if endswith(f, ".md")]))
    nblocks = 0
    for p in pages
        blocks = [m.captures[1] for m in eachmatch(r"```julia\r?\n(.*?)```"s, read(p, String))]
        isempty(blocks) && continue
        m = Module(Symbol(basename(p)))
        for f in readdir(dir)                      # a page starts without another page's files
            f in ("logo.png", "chart.jpg") || rm(joinpath(dir, f); recursive = true)
        end
        cd(dir) do
            Core.eval(m, :(using OpenDocumentSpreadsheets))
            Base.include_string(m, _DOCS_PRELUDE, "prelude")
        end
        for (k, b) in enumerate(blocks)
            (occursin("Pkg.add", b) || occursin("using DataFrames", b)) && continue
            b = replace(b, "1_000_000" => "1_000")      # the streaming example, scaled down
            _docs_files(dir, b)
            ok = try
                cd(() -> Base.include_string(m, b, "$(basename(p)) example $k"), dir)
                true
            catch e
                @error "a docs example fails" page = basename(p) example = k exception = (e, catch_backtrace())
                false
            end
            @test (basename(p), k, ok) == (basename(p), k, true)
            nblocks += 1
        end
    end
    @test nblocks > 50
end

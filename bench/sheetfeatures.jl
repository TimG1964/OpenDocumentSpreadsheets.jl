# Sheet features (phase 5): inserting and deleting rows and columns, then saving, in OpenDocumentSpreadsheets and
# XLSX.jl, on XLSX.jl's benchmark fixtures (bench/fixtures: run make_fixtures.sh first).
#
#   julia --project=<env with XLSX and OpenDocumentSpreadsheets> bench/sheetfeatures.jl [results.tsv]
#
# Cases: 10 rows inserted at row 2, rows 2–11 deleted, a column inserted and deleted at B, and
# the sheet renamed (phase 5 step 4).
#
# Each case times opening the fixture with mode "rw", the operation, and a save to an IOBuffer (as
# run.jl's edit_one_cell does). The median of 3 runs (after a warm-up) is kept, with its allocation. Ratio =
# OpenDocumentSpreadsheets / XLSX.jl time. BENCH_FIXTURES (comma-separated) chooses the fixtures.
using XLSX, OpenDocumentSpreadsheets, Printf
const ODS = OpenDocumentSpreadsheets
const FIXTURES = joinpath(@__DIR__, "fixtures")
const OUT = isempty(ARGS) ? joinpath(@__DIR__, "results", "sheetfeatures-latest.tsv") : ARGS[1]
const ONLY = haskey(ENV, "BENCH_FIXTURES") ? split(ENV["BENCH_FIXTURES"], ',') : nothing
const NAMES = ["small", "medium", "large", "numeric_only", "multi_sheet", "tall_few", "wide_few", "xl_medium"]

sheetname(f) = startswith(f, "xl_") ? "Data" : "Sheet1"

const CASES = [
    "insert_rows_save" => ((s) -> XLSX.insertRows(s, 2; count = 10), (s) -> ODS.insertRows(s, 2; count = 10)),
    "delete_rows_save" => ((s) -> XLSX.deleteRows(s, 2:11), (s) -> ODS.deleteRows(s, 2:11)),
    "insert_cols_save" => ((s) -> XLSX.insertColumns(s, 2), (s) -> ODS.insertColumns(s, 2)),
    "delete_cols_save" => ((s) -> XLSX.deleteColumns(s, 2), (s) -> ODS.deleteColumns(s, 2)),
    "rename_save"      => ((s) -> XLSX.renamesheet!(s, "Renamed sheet"), (s) -> ODS.renamesheet!(s, "Renamed sheet")),
]

function measure(setup, f, k = 3)
    f(setup())
    ts = Float64[]; bs = Int[]
    for _ in 1:k
        x = setup(); GC.gc()
        st = @timed f(x)
        push!(ts, st.time); push!(bs, st.bytes)
    end
    i = sortperm(ts)[(k + 1) ÷ 2]
    return ts[i], bs[i]
end

function main()
    rows = String[]
    for f in NAMES
        ONLY === nothing || f in ONLY || continue
        px = joinpath(FIXTURES, "xlsx", f * (startswith(f, "xl_") ? ".xlsm" : ".xlsx"))
        po = joinpath(FIXTURES, f * ".ods")
        (isfile(px) && isfile(po)) || (println("missing fixture $f"); continue)
        sh = sheetname(f)
        for (case, (gx, go)) in CASES
            tx, bx = measure(() -> nothing,
                             _ -> (xf = XLSX.openxlsx(px; mode = "rw"); gx(xf[sh]); io = IOBuffer(); XLSX.writexlsx(io, xf); take!(io)))
            to, bo = measure(() -> nothing,
                             _ -> (xf = ODS.openods(po; mode = "rw"); go(xf[sh]); io = IOBuffer(); ODS.writeods(io, xf); take!(io)))
            @printf("%-14s %-18s xlsx %9.1f ms  ods %9.1f ms  ratio %5.2f   (%8.1f / %8.1f MiB)\n",
                    f, case, tx * 1e3, to * 1e3, to / tx, bx / 2^20, bo / 2^20)
            push!(rows, join((f, case, @sprintf("%.2f", tx * 1e3), @sprintf("%.2f", to * 1e3), @sprintf("%.3f", to / tx),
                              @sprintf("%.1f", bx / 2^20), @sprintf("%.1f", bo / 2^20)), '\t'))
        end
    end
    mkpath(dirname(OUT))
    open(OUT, "w") do io
        println(io, "fixture\tcase\txlsx_ms\tods_ms\tratio\txlsx_mib\tods_mib")
        foreach(r -> println(io, r), rows)
    end
    println("written ", OUT)
end

main()

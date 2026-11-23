# OpenDocumentSpreadsheets against XLSX.jl 0.13.4, on XLSX.jl's own benchmark fixtures and cases
# (XLSX.jl bench/bench_worker.jl), the .xlsx read by XLSX.jl and LibreOffice's .ods
# conversion read by OpenDocumentSpreadsheets (make_fixtures.sh).
#
#   julia --project=bench bench/run.jl [results.tsv]
#
# Each case is run once to warm up, then repeated until 5 runs or a time budget, and the
# minimum time and its allocation are kept. Setup that XLSX.jl's worker excludes from the
# timing is excluded here too (a warm cache for `eachrow`/`single_cell`, the table read for
# `writetable_only`). Optional filters: BENCH_FIXTURES, BENCH_CASES (comma-separated),
# BENCH_SECONDS (budget per case and package, default 10).
using XLSX, OpenDocumentSpreadsheets, Printf
import OpenDocumentSpreadsheets: getdata
const ODS = OpenDocumentSpreadsheets

_list(k) = (v = get(ENV, k, ""); isempty(v) ? nothing : Set(split(v, ',')))
const ONLY_FIXTURES = _list("BENCH_FIXTURES")
const ONLY_CASES = _list("BENCH_CASES")
const SECONDS = parse(Float64, get(ENV, "BENCH_SECONDS", "10"))
const FIXTURES = joinpath(@__DIR__, "fixtures")
const OUT = isempty(ARGS) ? joinpath(@__DIR__, "results", "latest.tsv") : ARGS[1]

table_sheet(f) = startswith(f, "xl_") ? "Data" : "Sheet1"
table_kwargs(f) = f == "xl_gaps" ? (; first_row = 5, stop_in_empty_row = false, keep_empty_rows = true) :
                  startswith(f, "xl_") ? (; first_row = 5) : (;)

# (minimum seconds, bytes allocated in that run)
function measure(f, setup = () -> nothing)
    x = setup(); f(x)                              # warm-up
    best = Inf; bytes = 0; t0 = time(); n = 0
    while n < 5 && (n == 0 || time() - t0 < SECONDS)
        x = setup(); GC.gc(false)
        st = @timed f(x)
        st.time < best && (best = st.time; bytes = st.bytes)
        n += 1
    end
    return best, bytes
end

function warm_x(path, sheet)
    xf = XLSX.openxlsx(path); sh = xf[sheet]
    for _ in XLSX.eachrow(sh) end
    dim = XLSX.get_dimension(sh)
    (sh, dim, XLSX.column_number(dim.start):XLSX.column_number(dim.stop))
end
function warm_o(path, sheet)
    xf = readods(path); sh = xf[sheet]
    for _ in eachrow(sh) end
    dim = ODS.get_dimension(sh)
    (sh, dim, ODS.column_number(dim.start):ODS.column_number(dim.stop))
end

# case => (xlsx (f, setup), ods (f, setup)); paths px/po, temp outputs tx/to
function cases(fixture, px, po)
    sheet, kw = table_sheet(fixture), table_kwargs(fixture)
    tx, to = tempname() * ".xlsx", tempname() * ".ods"
    ext = splitext(px)[2]
    c = Pair{String,Any}[
        "open" => ((_ -> XLSX.openxlsx(xf -> nothing, px), nothing), (_ -> openods(xf -> nothing, po), nothing)),
        "readtable" => ((_ -> XLSX.readtable(px, sheet; kw...), nothing), (_ -> ODS.readtable(po, sheet; kw...), nothing)),
        "readfile" => ((_ -> XLSX.readxlsx(px), nothing), (_ -> readods(po), nothing)),
        "eachrow" => ((w -> (for r in XLSX.eachrow(w[1]); for c in w[3]; XLSX.getdata(r, c); end; end), () -> warm_x(px, sheet)),
                      (w -> (for r in eachrow(w[1]); for c in w[3]; getdata(r, c); end; end), () -> warm_o(po, sheet))),
        "single_cell" => ((w -> (XLSX.getdata(w[1], w[2].start); XLSX.getdata(w[1], w[2].stop)), () -> warm_x(px, sheet)),
                          (w -> (getdata(w[1], w[2].start); getdata(w[1], w[2].stop)), () -> warm_o(po, sheet))),
        "writetable" => ((_ -> XLSX.writetable(tx, XLSX.readtable(px, sheet; kw...); overwrite = true), nothing),
                         (_ -> ODS.writetable(to, ODS.readtable(po, sheet; kw...); overwrite = true), nothing)),
        "writetable_only" => ((t -> XLSX.writetable(tx, t; overwrite = true), () -> XLSX.readtable(px, sheet; kw...)),
                              (t -> ODS.writetable(to, t; overwrite = true), () -> ODS.readtable(po, sheet; kw...))),
        "writetable_streaming" => ((t -> XLSX.writetable(tx, t; overwrite = true, streaming = true), () -> XLSX.readtable(px, sheet; kw...)),
                                   (t -> ODS.writetable(to, t; overwrite = true, streaming = true), () -> ODS.readtable(po, sheet; kw...))),
        "open_readwrite" => ((p -> XLSX.openxlsx(xf -> nothing, p; mode = "rw"), () -> (p = tempname() * ext; cp(px, p); p)),
                             (p -> openods(xf -> nothing, p; mode = "rw"), () -> (p = tempname() * ".ods"; cp(po, p); p))),
        "edit_one_cell" => ((p -> XLSX.openxlsx(p; mode = "rw") do xf; xf[sheet][3, 2] = 1.5; end, () -> (p = tempname() * ext; cp(px, p); p)),
                            (p -> openods(p; mode = "rw") do xf; xf[sheet][3, 2] = 1.5; end, () -> (p = tempname() * ".ods"; cp(po, p); p))),
    ]
    if fixture in ("xl_medium", "xl_issue462")
        push!(c, "readtable_subset" => ((_ -> XLSX.readtable(px, "Data", "A:CF"; first_row = 5), nothing),
                                        (_ -> ODS.readtable(po, "Data", "A:CF"; first_row = 5), nothing)))
    end
    if fixture == "multi_sheet"
        allx(_) = XLSX.openxlsx(px) do xf
            for i in 1:5
                sh = xf[i]; d = XLSX.get_dimension(sh)
                for r in XLSX.eachrow(sh), col in XLSX.column_number(d.start):XLSX.column_number(d.stop)
                    XLSX.getdata(r, col)
                end
            end
        end
        allo(_) = openods(po) do xf
            for i in 1:5
                sh = xf[i]; d = ODS.get_dimension(sh)
                for r in eachrow(sh), col in ODS.column_number(d.start):ODS.column_number(d.stop)
                    getdata(r, col)
                end
            end
        end
        push!(c, "readtable_all_sheets" => ((allx, nothing), (allo, nothing)))
    end
    return c
end

mkpath(dirname(OUT))
println("OpenDocumentSpreadsheets ", pkgversion(OpenDocumentSpreadsheets), " | XLSX.jl ", pkgversion(XLSX), " | Julia ", VERSION, " | ", Sys.CPU_NAME,
        " | threads ", Threads.nthreads(), " | budget ", SECONDS, " s")
open(OUT, "w") do io
    println(io, "fixture\tcase\txlsx_ms\tods_ms\tratio\txlsx_mib\tods_mib")
    for f in ["small", "medium", "large", "wide_few", "tall_few", "sst_unique", "sst_repeated", "sst_mixed",
              "numeric_only", "dates_heavy", "multi_sheet", "xl_medium", "xl_issue462", "xl_gaps"]
        ONLY_FIXTURES === nothing || f in ONLY_FIXTURES || continue
        px = joinpath(FIXTURES, "xlsx", f * (startswith(f, "xl_") ? ".xlsm" : ".xlsx"))
        po = joinpath(FIXTURES, f * ".ods")
        (isfile(px) && isfile(po)) || (println("skipping $f: no fixture"); continue)
        for (name, ((fx, sx), (fo, so))) in cases(f, px, po)
            ONLY_CASES === nothing || name in ONLY_CASES || continue
            tx, bx = try measure(fx, something(sx, () -> nothing)) catch e; (NaN, 0) end
            to_, bo = try measure(fo, something(so, () -> nothing)) catch e; @warn "$f/$name failed" exception = e; (NaN, 0) end
            @printf("%-13s %-22s xlsx %9.1f ms  ods %9.1f ms  ratio %5.2f   (%7.1f / %7.1f MiB)\n",
                    f, name, 1000tx, 1000to_, to_ / tx, bx / 2^20, bo / 2^20)
            @printf(io, "%s\t%s\t%.2f\t%.2f\t%.3f\t%.1f\t%.1f\n", f, name, 1000tx, 1000to_, to_ / tx, bx / 2^20, bo / 2^20)
            flush(io); flush(stdout)
        end
    end
end
println("results: ", OUT)

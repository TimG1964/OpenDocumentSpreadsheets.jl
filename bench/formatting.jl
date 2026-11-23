# Formatting: OpenDocumentSpreadsheets against XLSX.jl 0.13.4 (phase 4 step 9).
#
#   julia --project=bench bench/formatting.jl [results.tsv]
#
# Fixture-free, like XLSX.jl's bench/worksheet_write.jl:
#   format_cells   XLSX.jl's own case: a new 2,000 x 8 block of numbers, `setFont` and
#                  `setFill` on all of it, then written to an IOBuffer (all timed)
#   set*_1M        one setter over 125,000 x 8 = 1M cells of a new file holding numbers
#                  (building the file is not timed)
#   *_1M_mixed     `setFont` / `setUniformFont` over the same 1M cells, which start with 100
#                  distinct fonts (bands of 1,250 rows: sizes and colours), so that `setFont`
#                  must keep each cell's own size and colour, while `setUniformFont` gives all
#                  cells the first cell's font (1,000 fonts take XLSX.jl minutes per run)
#   write_1M       writing that file to an IOBuffer after `setFont` over all of it
#   getFont_10k    `getFont` on 10,000 single cells of the formatted file
#   autofit_20k    `autofitColumns` on a 20,000 x 8 block
# Each case runs once to warm up; the median of 3 (1M cases) or 5 timed runs is kept, with
# its allocation. Ratio = OpenDocumentSpreadsheets / XLSX.jl time.
using XLSX, OpenDocumentSpreadsheets, Printf
const ODS = OpenDocumentSpreadsheets
const NC = 8
const OUT = isempty(ARGS) ? joinpath(@__DIR__, "results", "formatting-latest.tsv") : ARGS[1]

block(n) = [r * 10 + c for r in 1:n, c in 1:NC]
const lastcol = "H"

# (new workbook, its first sheet) for each package
newx(n) = (xf = XLSX.newxlsx(); xf[1][1:n, 1:NC] = block(n); (xf, xf[1]))
newo(n) = (xf = ODS.newods(); xf[1][1:n, 1:NC] = block(n); (xf, xf[1]))

function format_cells_x(n = 2_000)
    xf, s = newx(n)
    XLSX.setFont(s, "A1:$lastcol$n"; bold = true, color = "FF0000")
    XLSX.setFill(s, "A1:$lastcol$n"; pattern = "solid", fgColor = "FFFF00")
    io = IOBuffer(); XLSX.writexlsx(io, xf); take!(io)
end
function format_cells_o(n = 2_000)
    xf, s = newo(n)
    ODS.setFont(s, "A1:$lastcol$n"; bold = true, color = "FF0000")
    ODS.setFill(s, "A1:$lastcol$n"; pattern = "solid", fgColor = "FFFF00")
    io = IOBuffer(); ODS.writeods(io, xf); take!(io)
end

const M = 125_000
const RNG = "A1:$lastcol$M"
const SETTERS = [
    "setFont_1M"      => ((M, s) -> XLSX.setFont(s, RNG; bold = true, color = "FF0000"),
                          (M, s) -> ODS.setFont(s, RNG; bold = true, color = "FF0000")),
    "setFill_1M"      => ((M, s) -> XLSX.setFill(s, RNG; pattern = "solid", fgColor = "FFFF00"),
                          (M, s) -> ODS.setFill(s, RNG; pattern = "solid", fgColor = "FFFF00")),
    "setBorder_1M"    => ((M, s) -> XLSX.setBorder(s, RNG; allsides = ["style" => "thin", "color" => "black"]),
                          (M, s) -> ODS.setBorder(s, RNG; allsides = ["style" => "thin", "color" => "black"])),
    "setAlignment_1M" => ((M, s) -> XLSX.setAlignment(s, RNG; horizontal = "center", wrapText = true),
                          (M, s) -> ODS.setAlignment(s, RNG; horizontal = "center", wrapText = true)),
    "setFormat_1M"    => ((M, s) -> XLSX.setFormat(s, RNG; format = "0.00"),
                          (M, s) -> ODS.setFormat(s, RNG; format = "0.00")),
    "setUniformFont_1M" => ((M, s) -> XLSX.setUniformFont(s, RNG; bold = true),
                            (M, s) -> ODS.setUniformFont(s, RNG; bold = true)),
]

# times f(setup()) `k` times after a warm-up; the median time and its allocation
function measure(f, setup, k)
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
    rows = Tuple{String,Float64,Float64,Float64,Float64}[]
    report(case, (tx, bx), (to, bo)) = begin
        push!(rows, (case, tx * 1e3, to * 1e3, bx / 2^20, bo / 2^20))
        @printf("%-18s xlsx %9.1f ms  ods %9.1f ms  ratio %5.2f   (%8.1f / %8.1f MiB)\n", case, tx * 1e3, to * 1e3, to / tx, bx / 2^20, bo / 2^20)
    end
    report("format_cells", measure(_ -> format_cells_x(), () -> nothing, 5), measure(_ -> format_cells_o(), () -> nothing, 5))
    for (case, (fx, fo)) in SETTERS
        report(case, measure(t -> fx(M, t[2]), () -> newx(M), 3), measure(t -> fo(M, t[2]), () -> newo(M), 3))
    end
    # 100 distinct fonts, in bands of 1,250 rows (not timed)
    band(k) = "A$(k * 1250 + 1):$lastcol$((k + 1) * 1250)"
    fkw(k) = (size = 6 + k * 0.25, color = string(k * 130_001 % 0xffffff; base = 16, pad = 6))
    mixx() = (t = newx(M); for k in 0:99; XLSX.setFont(t[2], band(k); fkw(k)...); end; t)
    mixo() = (t = newo(M); for k in 0:99; ODS.setFont(t[2], band(k); fkw(k)...); end; t)
    report("setFont_1M_mixed", measure(t -> XLSX.setFont(t[2], RNG; bold = true), mixx, 3),
                               measure(t -> ODS.setFont(t[2], RNG; bold = true), mixo, 3))
    report("setUniformFont_1M_mixed", measure(t -> XLSX.setUniformFont(t[2], RNG; bold = true), mixx, 3),
                                      measure(t -> ODS.setUniformFont(t[2], RNG; bold = true), mixo, 3))
fmtx() = (t = newx(M); XLSX.setFont(t[2], RNG; bold = true); t)
    fmto() = (t = newo(M); ODS.setFont(t[2], RNG; bold = true); t)
    report("write_1M", measure(t -> (io = IOBuffer(); XLSX.writexlsx(io, t[1]); take!(io)), fmtx, 3),
                       measure(t -> (io = IOBuffer(); ODS.writeods(io, t[1]); take!(io)), fmto, 3))
    cells = [(r, c) for r in 1:1250, c in 1:NC]
    report("getFont_10k", measure(t -> foreach(rc -> XLSX.getFont(t[2], rc...), cells), fmtx, 5),
                          measure(t -> foreach(rc -> ODS.getFont(t[2], rc...), cells), fmto, 5))
    report("autofit_20k", measure(t -> XLSX.autofitColumns(t[2]), () -> newx(20_000), 5),
                          measure(t -> ODS.autofitColumns(t[2]), () -> newo(20_000), 5))
    open(OUT, "w") do io
        println(io, "case\txlsx_ms\tods_ms\tratio\txlsx_mib\tods_mib")
        for (c, tx, to, bx, bo) in rows
            @printf(io, "%s\t%.2f\t%.2f\t%.3f\t%.1f\t%.1f\n", c, tx, to, to / tx, bx, bo)
        end
    end
end
main()

# Embedded chart objects through edits and operations (phase 8 step 2, D-085): chart frames are not
# pictures, the objects' references follow line and sheet operations as LibreOffice moves them, copies
# keep pointing at their source (F-083), and objects whose frames are gone are not written. Fixtures:
# experiment 039 (test/data/charts).
import ZipArchives
const O_C = OpenDocumentSpreadsheets
const CH = joinpath(@__DIR__, "..", "data", "charts")
_ch(f) = joinpath(CH, f)

# The oracle files of experiment 039 (lo-charts-oracle.zip).
_chart_oracle(name) = String(ZipArchives.zip_readentry(ZipArchives.ZipReader(read(_ch("lo-charts-oracle.zip"))), name))

_colname(c) = c <= 26 ? string(Char('A' + c - 1)) : _colname((c - 1) ÷ 26) * string(Char('A' + (c - 1) % 26))
const _OBJ_ADDR_RX = r"(table:cell-range-address|chart:values-cell-range-address|chart:label-cell-address|chart:error-upper-range|chart:error-lower-range)=\"([^\"]*)\""

# Every chart frame of a zipped file: object, sheet, anchor cell ("page" for a page frame), end cell,
# notify list, the object's addresses ("attribute=value", in document order), whether its parts and
# manifest entry are there; and the object directories no frame uses.
function chart_frames(path)
    z = ZipArchives.ZipReader(read(path))
    names = ZipArchives.zip_names(z)
    content = String(ZipArchives.zip_readentry(z, "content.xml"))
    manifest = String(ZipArchives.zip_readentry(z, "META-INF/manifest.xml"))
    out = NamedTuple[]
    sheet = ""; row = 0; rowrep = 1; col = 0; cellcol = 0; incell = false; inshapes = false; frameattrs = ""
    rx = r"<(/?)(table:table|table:table-row|table:table-cell|table:covered-table-cell|table:shapes|draw:frame|draw:object)(?=[\s/>])([^>]*?)(/?)>"
    rep(a, k) = (m = match(Regex(k * "=\"(\\d+)\""), a); m === nothing ? 1 : parse(Int, m.captures[1]))
    for m in eachmatch(rx, content)
        close, tag, attrs, selfc = m.captures[1] == "/", m.captures[2], m.captures[3], m.captures[4] == "/"
        if tag == "table:table"
            close || (sheet = O_C.XML.unescape(match(r"table:name=\"([^\"]*)\"", attrs).captures[1]); row = 0)
        elseif tag == "table:table-row"
            if close
                row += rowrep - 1
            else
                row += 1; col = 0; rowrep = rep(attrs, "table:number-rows-repeated")
                selfc && (row += rowrep - 1)
            end
        elseif tag in ("table:table-cell", "table:covered-table-cell")
            if close
                incell = false
            else
                n = rep(attrs, "table:number-columns-repeated")
                cellcol = col + 1; col += n
                incell = !selfc
            end
        elseif tag == "table:shapes"
            inshapes = !close
        elseif tag == "draw:frame"
            close || (frameattrs = attrs)
        elseif tag == "draw:object" && !close
            h = match(r"xlink:href=\"\./([^\"]*)\"", attrs)
            h === nothing && continue
            obj = O_C.XML.unescape(h.captures[1])
            e = match(r"table:end-cell-address=\"([^\"]*)\"", frameattrs)
            nt = match(r"draw:notify-on-update-of-ranges=\"([^\"]*)\"", attrs)
            addrs = String[]
            if obj * "/content.xml" in names
                oc = String(ZipArchives.zip_readentry(z, obj * "/content.xml"))
                for a in eachmatch(_OBJ_ADDR_RX, oc)
                    push!(addrs, replace(a.captures[1], r"^[a-z]+:" => "") * "=" * O_C.XML.unescape(a.captures[2]))
                end
            end
            push!(out, (object = obj, sheet = sheet, anchor = inshapes || !incell ? "page" : _colname(cellcol) * string(row),
                        endcell = e === nothing ? "-" : O_C.XML.unescape(e.captures[1]),
                        notify = nt === nothing ? "" : O_C.XML.unescape(nt.captures[1]), addrs = addrs,
                        parts = obj * "/content.xml" in names,
                        manifest = occursin("manifest:full-path=\"$(replace(obj, "&" => "&amp;"))/\"", manifest)))
        end
    end
    framed = Set(f.object for f in out)
    dirs = Set(first(split(n, '/')) for n in names if occursin('/', n))
    orphans = [d for d in dirs if !(d in framed) && !(d in ("META-INF", "Thumbnails", "Configurations2", "ObjectReplacements"))]
    for m in eachmatch(r"manifest:full-path=\"([^\"/]+)/\" manifest:media-type=\"application/vnd.oasis.opendocument.chart\"", manifest)
        d = O_C.XML.unescape(m.captures[1])
        d in framed || d in orphans || push!(orphans, d * " (manifest)")
    end
    return out, orphans
end

# experiment 039 part D's operations, as this package's calls
const _CHART_OPS = Dict(
    "ins_row_5" => xf -> insertRows(xf["Data"], 5), "ins_row_1" => xf -> insertRows(xf["Data"], 1),
    "ins_row_8" => xf -> insertRows(xf["Data"], 8), "del_row_3" => xf -> deleteRows(xf["Data"], 3),
    "del_rows_2_7" => xf -> deleteRows(xf["Data"], 2:7), "del_row_1" => xf -> deleteRows(xf["Data"], 1),
    "ins_col_B" => xf -> insertColumns(xf["Data"], 2), "del_col_B" => xf -> deleteColumns(xf["Data"], 2),
    "del_col_A" => xf -> deleteColumns(xf["Data"], 1), "del_col_E" => xf -> deleteColumns(xf["Data"], 5),
    "del_rows_frame" => xf -> deleteRows(xf["Data"], 45:59), "del_row_46" => xf -> deleteRows(xf["Data"], 46),
    "ins_row_50" => xf -> insertRows(xf["Data"], 50; count = 2), "del_cols_K_Q" => xf -> deleteColumns(xf["Data"], 11:17),
    "rename" => xf -> renamesheet!(xf["Data"], "My Data"), "copy_data" => xf -> copysheet!(xf["Data"], "Data_2"),
    "copy_other" => xf -> copysheet!(xf["Other"], "Other_2"), "del_other" => xf -> deletesheet!(xf["Other"]),
    "del_data" => xf -> deletesheet!(xf["Data"]), "move_data" => xf -> movesheet!(xf, "Data"; after = 2),
    "edit" => xf -> (xf["Data"]["B3"] = 99))

# LibreOffice's frames after each operation (ops.tsv): op => [(sheet, anchor, end, addresses)]
function _lo_chart_ops()
    d = Dict{String,Vector{Tuple{String,String,String,Vector{String}}}}()
    for l in eachline(IOBuffer(_chart_oracle("ops.tsv")))
        f = split(l, '\t')
        (length(f) < 9 || f[3] == "ORPHAN") && continue
        a = f[4] == "page" ? "page" : replace(f[4], r".*\.\$?([A-Z]+)\$?(\d+)" => s"\1\2")
        push!(get!(d, f[1], Tuple{String,String,String,Vector{String}}[]),
              (f[3], a, f[5], isempty(f[8]) ? String[] : String.(split(f[8], " | "))))
    end
    return d
end

_frame_key(f) = (f.sheet, f.anchor, f.endcell, f.addrs)

@testset "chart frames are not pictures" begin
    own = readods(_ch("lo-charts-own.ods"))
    @test isempty(O_C.getImages(own))
    flat = readods(joinpath(@__DIR__, "..", "data", "shift", "lo-shift-before.fods"))
    @test isempty(O_C.getImages(flat))
    xf = openods(_ch("lo-charts-ops-base.ods"); mode = "rw")
    @test O_C.deleteImage(xf["Data"], "K46") == 0          # a cell-anchored chart's cell
    p = tempname() * ".ods"
    writeods(p, xf)
    frames, orphans = chart_frames(p)
    @test length(frames) == 9 && isempty(orphans) && all(f -> f.parts && f.manifest, frames)
    rm(p)
end

@testset "LibreOffice's operations on charts (experiment 039 part D)" begin
    lo = _lo_chart_ops()
    base, _ = chart_frames(_ch("lo-charts-ops-base.ods"))
    @test sort(_frame_key.(base)) == sort(lo["base"])
    for (op, f!) in sort(collect(_CHART_OPS); by = first)
        xf = openods(_ch("lo-charts-ops-base.ods"); mode = "rw")
        f!(xf)
        p = tempname() * ".ods"
        writeods(p, xf)
        frames, orphans = chart_frames(p)
        @test (op, sort(_frame_key.(frames))) == (op, sort(lo[op]))
        @test (op, orphans) == (op, String[])
        @test (op, all(f -> f.parts && f.manifest, frames)) == (op, true)
        if startswith(op, "copy_")              # a copy's charts keep their source's notify lists (F-083)
            new = filter(f -> endswith(f.sheet, "_2"), frames)
            @test !isempty(new) && all(f -> !occursin("_2.", f.notify), new)
        end
        rm(p)
    end
end

@testset "copies of copies, and deleted copies" begin
    xf = openods(_ch("lo-charts-ops-base.ods"); mode = "rw")
    copysheet!(xf["Data"], "CopyA")
    copysheet!(xf["CopyA"], "CopyB")
    copysheet!(xf["Other"], "O1")
    deletesheet!(xf["O1"])
    p = tempname() * ".ods"
    writeods(p, xf)
    frames, orphans = chart_frames(p)
    @test isempty(orphans)
    @test length(frames) == 9 + 8 + 8
    @test all(f -> f.parts && f.manifest, frames)
    @test length(unique(f.object for f in frames)) == length(frames)       # each frame its own object
    @test sort(_frame_key.(filter(f -> f.sheet == "CopyB", frames))) ==
          sort([(s == "Data" ? "CopyB" : s, a, replace(e, "Data." => "CopyB."), ad) for (s, a, e, ad) in _lo_chart_ops()["base"] if s == "Data"])
    rm(p)
end

@testset "a flat file: inline charts before a sheet's conditional formats" begin
    xf = openods(_ch("lo-charts-flat-cf.fods"); mode = "rw")
    insertRows(xf["Data"], 1)
    p = tempname() * ".fods"
    writeods(p, xf)
    s = read(p, String)
    cond = match(r"<calcext:condition [^>]*calcext:value=\"formula-is\(([^\"]*)\)\"[^>]*calcext:base-cell-address=\"([^\"]*)\"", s)
    smap = match(r"<style:map style:condition=\"is-true-formula\(([^\"]*)\)\"[^>]*style:base-cell-address=\"([^\"]*)\"", s)
    @test cond !== nothing && smap !== nothing
    @test cond.captures[2] == "Data.B3"
    @test (smap.captures[1], smap.captures[2]) == (cond.captures[1], cond.captures[2])
    # the inline charts' references moved, and copies keep theirs (F-083)
    @test occursin("chart:values-cell-range-address=\"Data.B3:Data.B8\"", s)
    copysheet!(xf["Data"], "Data_2")
    writeods(p, xf; overwrite = true)
    s = read(p, String)
    @test !occursin("chart:values-cell-range-address=\"Data_2.", s)
    rm(p)
end

if lo_ok(LO_FIXTURE_MAJOR)
    @testset "LibreOffice reads the charts after operations" begin
        mktempdir() do dir
            files = String[]
            for op in ("del_rows_frame", "copy_data", "del_data", "rename")
                xf = openods(_ch("lo-charts-ops-base.ods"); mode = "rw")
                _CHART_OPS[op](xf)
                p = joinpath(dir, "op-$op.ods")
                writeods(p, xf)
                push!(files, p)
            end
            profile = joinpath(dir, "profile")
            out = joinpath(dir, "out")
            lo_convert(files, "fods"; outdir = out, profile = lo_profile_url(profile))
            lo = _lo_chart_ops()
            for p in files
                op = replace(basename(p), "op-" => "", ".ods" => "")
                s = read(joinpath(out, "op-$op.fods"), String)
                # every chart LibreOffice expects is there, with its series
                @test (op, count("<draw:object ", s)) == (op, length(lo[op]))
                @test (op, count("<chart:series ", s)) == (op, sum(length(filter(a -> startswith(a, "values-cell-range-address="), x[4])) for x in lo[op]))
            end
        end
    end
end

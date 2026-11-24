# Pictures (phase 6 step 5, D-074): LibreOffice's frames (F-060), with XLSX.jl's API. Fixtures:
# experiment 031 (test/data/images; red.png, blue.png and dot.gif made by its images.jl, photo.jpg
# XLSX.jl's test/data/track_start.jpg).
import ZipArchives
const O_I = OpenDocumentSpreadsheets
using OpenDocumentSpreadsheets: ODSError
const IM = joinpath(@__DIR__, "..", "data", "images")
_im(f) = joinpath(IM, f)
_fromto(v) = [(i.from, i.to) for i in v]

@testset "LibreOffice's own pictures" begin
    z = readods(_im("lo-images-own.ods"))["Own"]
    f = readods(_im("lo-images-own.fods"))["Own"]
    @test _fromto(O_I.getImages(z)) == _fromto(O_I.getImages(f)) ==
          [("B2", "C4"), ("D2", "E4"), ("F2", "F8"), ("B10", "B16"), ("D10", "G22"), ("B20", "B21"), ("D20", "E22")]
    @test O_I.getImages(z)[1].media_name == "100000000000006000000030584B4A5B.png"   # anchored to the page
    @test all(i -> i.media_name == "", O_I.getImages(f))                           # a flat file holds the bytes
    @test length(O_I.getImages(readods(_im("lo-images-own.ods")))) == 7
end

@testset "LibreOffice's import of XLSX.jl's pictures: XLSX.jl's cells" begin
    xf = readods(_im("lo-images-xlsx-import.ods"))
    expected = [(split(l, '\t')[1], split(l, '\t')[5], split(l, '\t')[6]) for l in eachline(_im("lo-images-xlsx-cases.txt"))
                if !occursin("in_cell", l)]
    @test [(i.sheet, i.from, i.to) for i in O_I.getImages(xf)] == expected
end

@testset "addImage: XLSX.jl's cells and checks" begin
    xf = newods("Img"); ws = xf["Img"]
    cases = [(("B2", _im("red.png")), (;), ("B2", "C3")),
             (("F2", _im("red.png")), (; size = (200, 100)), ("F2", "H6")),
             (("B10:D16", _im("blue.png")), (;), ("B10", "D16")),
             ((10, 6, _im("photo.jpg")), (;), ("F10", "I20")),
             (("B20", _im("dot.gif")), (;), ("B20", "B20")),
             (("D20", IOBuffer(read(_im("blue.png")))), (;), ("D20", "D25")),
             ((CellRef("F20"), _im("red.png")), (;), ("F20", "G21"))]
    for (args, kw, ft) in cases
        info = addImage(ws, args...; kw...)
        @test (info.from, info.to) == ft && info.sheet == "Img"
    end
    @test length(xf.media) == 4                                  # each picture stored once
    @test O_I.getImages(ws)[1].media_name == O_I.getImages(ws)[end].media_name   # red.png
    buf = IOBuffer(read(_im("red.png"))); addImage(ws, "J1", buf); @test position(buf) == 0 && bytesavailable(buf) == 13940
    @test_throws ODSError addImage(ws, "A1", _im("red.png"); inCell = true)         # LibreOffice has none
    @test_throws ODSError addImage(ws, "A1", IOBuffer(UInt8[1, 2, 3, 4, 5, 6, 7, 8]))
    @test_throws ODSError addImage(ws, "nocell", _im("red.png"))
    @test_throws ODSError deleteImage(ws, "B2:C3")
    @test_throws ODSError deleteImage(ws, (sheet = "Other", media_name = "x", from = "A1", to = "A1"))
    @test_throws ODSError addImage(readods(_im("lo-images-own.ods"))["Own"], "A1", _im("red.png"))
    # deleting
    @test deleteImage(ws, "B20") == 1 && deleteImage(ws, "B20") == 0
    @test deleteImage(ws, only(filter(i -> i.from == "B2", O_I.getImages(ws)))) == 1
    @test _fromto(O_I.getImages(ws)) == [("J1", "K2"), ("F2", "H6"), ("B10", "D16"), ("F10", "I20"), ("D20", "D25"), ("F20", "G21")]
    # saved and read back
    dir = mktempdir()
    for ext in ("ods", "fods")
        r = readods(writeods(joinpath(dir, "img.$ext"), xf))
        @test _fromto(O_I.getImages(r)) == _fromto(O_I.getImages(ws))
    end
    zr = ZipArchives.ZipReader(read(joinpath(dir, "img.ods")))
    pics = [n for n in ZipArchives.zip_names(zr) if startswith(n, "Pictures/")]
    @test length(pics) == 3                                      # the GIF is no longer used
    man = ZipArchives.zip_readentry(zr, "META-INF/manifest.xml", String)
    @test all(p -> occursin("manifest:full-path=\"$p\"", man), pics)
    @test count("<office:binary-data>", read(joinpath(dir, "img.fods"), String)) == 6
end

@testset "a patched save: pictures added and removed in LibreOffice's file" begin
    dir = mktempdir()
    for ext in ("ods", "fods")
        xf = openods(_im("lo-images-own.$ext"); mode = "rw"); ws = xf["Own"]
        addImage(ws, "H3", _im("red.png"))
        @test deleteImage(ws, "D2") == 1                         # LibreOffice's own picture
        before = _fromto(O_I.getImages(ws))
        @test before == [("B2", "C4"), ("F2", "F8"), ("H3", "I4"), ("B10", "B16"), ("D10", "G22"), ("B20", "B21"), ("D20", "E22")]
        r = readods(writeods(joinpath(dir, "own.$ext"), xf))["Own"]
        @test _fromto(O_I.getImages(r)) == before
        @test r["A5"] == 4                                       # the values, untouched
    end
    zr = ZipArchives.ZipReader(read(joinpath(dir, "own.ods")))
    @test count(n -> startswith(n, "Pictures/"), ZipArchives.zip_names(zr)) == 4    # red.png was already there: used again
end

@testset "deletes: LibreOffice's rules (its own result, experiment 031)" begin
    lo = readods(_im("lo-images-own-shifted.ods"))["Own"]
    for ext in ("ods", "fods")
        xf = openods(_im("lo-images-own.$ext"); mode = "rw"); ws = xf["Own"]
        insertRows(ws, 1; count = 2); deleteRows(ws, 12); deleteColumns(ws, "B")
        @test _fromto(O_I.getImages(ws)) == _fromto(O_I.getImages(lo))
        r = readods(writeods(joinpath(mktempdir(), "shifted.$ext"), xf))["Own"]
        @test _fromto(O_I.getImages(r)) == _fromto(O_I.getImages(lo))
    end
    # pictures added: one wholly in the deleted rows goes, one reaching beyond stays at its place
    xf = newods("S"); ws = xf["S"]
    addImage(ws, "B5", _im("red.png"); size = (128, 80))         # B5:C8
    addImage(ws, "E5", _im("dot.gif"))                           # E5:E5
    deleteRows(ws, 5)
    @test _fromto(O_I.getImages(ws)) == [("B5", "C7")]
    insertColumns(ws, "A")
    @test _fromto(O_I.getImages(ws)) == [("C5", "D7")]
    @test _fromto(O_I.getImages(readods(writeods(joinpath(mktempdir(), "s.ods"), xf)))) == [("C5", "D7")]
end

@testset "LibreOffice reads the pictures" begin
    if isempty(SOFFICE) || !isfile(SOFFICE)
        @info "LibreOffice not found; skipping the pictures oracle (set ODS_SOFFICE)"
        @test_skip false
    else
        dir = mktempdir()
        profile = lo_profile_url(joinpath(dir, "lo-profile"))
        xf = newods("Img"); ws = xf["Img"]
        addImage(ws, "B2", _im("red.png")); addImage(ws, "B10:D16", _im("blue.png")); addImage(ws, "F10", _im("photo.jpg"))
        a = writeods(joinpath(dir, "new.ods"), xf)
        b = writeods(joinpath(dir, "newflat.fods"), xf)
        p = openods(_im("lo-images-own.ods"); mode = "rw")
        addImage(p["Own"], "H3", _im("red.png")); deleteImage(p["Own"], "D2")
        insertRows(p["Own"], 1; count = 2); deleteRows(p["Own"], 12)
        c = writeods(joinpath(dir, "own.ods"), p)
        run(pipeline(`$SOFFICE -env:UserInstallation=$profile --headless --norestore --convert-to fods --outdir $(joinpath(dir, "lo")) $a $b $c`;
                     stdout = devnull, stderr = devnull))
        @test _fromto(O_I.getImages(readods(joinpath(dir, "lo", "new.fods")))) == _fromto(O_I.getImages(xf))
        @test _fromto(O_I.getImages(readods(joinpath(dir, "lo", "newflat.fods")))) == _fromto(O_I.getImages(xf))
        @test _fromto(O_I.getImages(readods(joinpath(dir, "lo", "own.fods"))["Own"])) == _fromto(O_I.getImages(p["Own"]))
    end
end

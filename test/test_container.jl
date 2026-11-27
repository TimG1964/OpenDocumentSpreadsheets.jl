# Container layer: zip/flat detection, media types, manifest, part access, the sheet index,
# and the package writer.

using OpenDocumentSpreadsheets: open_container, ODFContainer, PackagePart, write_package, package_bytes,
    write_flat, read_xml, read_bytes, partnames, haspart, odf_version, index_sheets,
    parse_manifest, readentry_string, guess_mediatype, MEDIATYPE_ODS, MEDIATYPE_OTS, NS_MANIFEST
import ZipArchives
import XML

# DATA (the fixtures folder) is defined in runtests.jl
const SCENARIO_SHEETS = ["S01-gaps", "S02-identical", "S03-col-style", "S03b-col-style-cells",
    "S03c-col-style-allrows", "S03d-cell-style", "S04-row-style", "S05-styled-empty",
    "S06-col-widths", "S07-row-heights", "S08-empty", "S09-merge", "S10-formula", "S11-far",
    "S12-types"]

const NS_DECL = """xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" """

function content_xml(sheets::Vector{Pair{String,String}}; version = "1.4")
    body = join(["""<table:table table:name="$n"><table:table-row><table:table-cell office:value-type="string"><text:p>$v</text:p></table:table-cell></table:table-row></table:table>""" for (n, v) in sheets])
    """<?xml version="1.0" encoding="UTF-8"?>\n<office:document-content $NS_DECL office:version="$version"><office:automatic-styles/><office:body><office:spreadsheet>$body<table:named-expressions/></office:spreadsheet></office:body></office:document-content>"""
end

# Walk one sheet from its snapshot and collect the text of its first cells, one per row.
function first_cells(entry)
    c = XML.Cursor(entry.node)
    XML.next!(c)
    out = String[]
    XML.for_each_child!(c) do row
        row.nodetype === XML.Element && XML.tag(row) == "table:table-row" || return
        txt = ""
        n = XML.LazyNode(row)
        for cell in XML.children(n)
            XML.nodetype(cell) === XML.Element || continue
            for p in XML.children(cell)
                XML.nodetype(p) === XML.Element && (txt = XML.simple_value(p) === nothing ? "" : String(XML.simple_value(p)))
            end
            break
        end
        push!(out, txt)
        XML.skip_element!(row)
    end
    out
end

@testset "writer: zip layout (D-005)" begin
    parts = [PackagePart("content.xml", content_xml(["A" => "x"]))]
    b = package_bytes(parts)
    le16(i) = Int(b[i+1]) | Int(b[i+2]) << 8
    @test b[1:4] == UInt8[0x50, 0x4b, 0x03, 0x04]
    @test le16(8) == 0                       # stored
    @test le16(28) == 0                      # no extra field
    @test String(b[31:38]) == "mimetype"
    @test String(b[39:38+length(MEDIATYPE_ODS)]) == MEDIATYPE_ODS
    zr = ZipArchives.ZipReader(b)
    @test ZipArchives.zip_names(zr) == ["mimetype", "content.xml", "META-INF/manifest.xml"]
    m = parse_manifest(readentry_string(zr, "META-INF/manifest.xml"))
    @test m[1].path == "/" && m[1].mediatype == MEDIATYPE_ODS && m[1].version == "1.4"
    @test m[2].path == "content.xml" && m[2].mediatype == "text/xml"
end

@testset "writer: versions, media types and argument checks" begin
    c = [PackagePart("content.xml", content_xml(["A" => "x"]; version = "1.3"))]
    zr = ZipArchives.ZipReader(package_bytes(c; version = "1.3"))
    @test parse_manifest(readentry_string(zr, "META-INF/manifest.xml"))[1].version == "1.3"
    @test_throws ArgumentError package_bytes(c; version = "1.2")
    @test_throws ArgumentError package_bytes(c; mediatype = "application/vnd.oasis.opendocument.text")
    @test_throws ArgumentError package_bytes([PackagePart("styles.xml", "<x/>")])           # no content.xml
    @test_throws ArgumentError package_bytes([c[1], PackagePart("mimetype", "x")])
    @test_throws ArgumentError package_bytes([c[1], PackagePart("META-INF/manifest.xml", "x")])
    @test_throws ArgumentError package_bytes([c[1], c[1]])
    @test_throws ArgumentError package_bytes([c[1], PackagePart("/abs.xml", "x")])
    ots = open_container(package_bytes(c; mediatype = MEDIATYPE_OTS))
    @test ots.format === :ots
    @test guess_mediatype("Pictures/a.PNG") == "image/png"
    @test guess_mediatype("x.bin") == "application/octet-stream"
    @test PackagePart("Pictures/a.png", UInt8[1, 2, 3]).compress == false
    @test PackagePart("content.xml", "x").compress == true
end

@testset "writer: destinations (F-016)" begin
    parts = [PackagePart("content.xml", content_xml(["A" => "x"])),
             PackagePart("Pictures/p.png", UInt8[0x89, 0x50, 0x4e, 0x47])]
    mktempdir() do dir
        p = joinpath(dir, "t.ods")
        @test write_package(p, parts) == p
        c = open_container(p)
        @test c.format === :ods
        @test read_bytes(c, "Pictures/p.png") == UInt8[0x89, 0x50, 0x4e, 0x47]
        @test any(e -> e.path == "Pictures/p.png" && e.mediatype == "image/png", c.manifest)
        # writing again replaces the file
        write_package(p, [parts[1]])
        @test !haspart(open_container(p), "Pictures/p.png")
    end
    # an IO that already holds data: the package is built in memory and appended as is
    io = IOBuffer(); write(io, "PREFIX")
    write_package(io, parts)
    @test isopen(io)
    b = take!(io)
    @test String(b[1:6]) == "PREFIX"
    @test open_container(b[7:end]).format === :ods
    # a non-seekable stream
    bs = Base.BufferStream()
    write_package(bs, parts); close(bs)
    @test open_container(read(bs)).format === :ods
end

@testset "reader: LibreOffice fixtures" begin
    for (file, fmt) in [("lo-scenarios.ods", :ods), ("lo-scenarios.fods", :fods), ("lo-scenarios.ots", :ots)]
        c = open_container(joinpath(DATA, file))
        @test c.format === fmt
        xml = read_xml(c, :content)
        @test odf_version(xml) == "1.4"
        sheets = index_sheets(xml)
        @test [s.name for s in sheets] == SCENARIO_SHEETS
        @test [s.index for s in sheets] == 1:length(SCENARIO_SHEETS)
        # S01-gaps: rows 1, 2-4 (repeated), 5, 6-9 (repeated), 10
        s01 = sheets[1]
        cnt = Ref(0)
        cur = XML.Cursor(s01.node); XML.next!(cur)
        @test XML.tag(cur) == "table:table"
        XML.for_each_child!(cur) do ch
            ch.nodetype === XML.Element && XML.tag(ch) == "table:table-row" && (cnt[] += 1)
            ch.nodetype === XML.Element && XML.skip_element!(ch)
        end
        @test cnt[] == 5
        if fmt === :fods
            @test read_xml(c, :styles) === xml          # one document holds every part
            @test partnames(c) == ["content.xml"]
            @test_throws ArgumentError read_bytes(c, "content.xml")
        else
            @test read_xml(c, :styles) isa String
            @test read_xml(c, :meta) isa String
            @test any(e -> e.path == "/" && e.version == "1.4", c.manifest)
        end
    end
    @test_throws ArgumentError read_xml(open_container(joinpath(DATA, "lo-scenarios.ods")), :bogus)
end

@testset "round trip through our writer" begin
    xml = content_xml(["First" => "a", "Second" => "b", "Third & last" => "c"])
    xml = replace(xml, "Third & last" => "Third &amp; last")
    c = open_container(package_bytes([PackagePart("content.xml", xml)]))
    s = index_sheets(read_xml(c, :content))
    @test [x.name for x in s] == ["First", "Second", "Third & last"]
    @test first_cells(s[2]) == ["b"]
    @test first_cells(s[3]) == ["c"]
end

@testset "reader: tolerance and errors" begin
    xml = content_xml(["A" => "x"])
    # no mimetype entry, but a manifest root entry (LibreOffice opens these, F-002)
    buf = IOBuffer()
    ZipArchives.ZipWriter(buf) do w
        ZipArchives.zip_writefile(w, "content.xml", codeunits(xml))
        ZipArchives.zip_writefile(w, "META-INF/manifest.xml", codeunits(
            OpenDocumentSpreadsheets.manifest_xml([PackagePart("content.xml", xml)], MEDIATYPE_ODS, "1.4")))
    end
    @test open_container(take!(buf)).format === :ods
    # neither mimetype nor manifest
    buf = IOBuffer()
    ZipArchives.ZipWriter(w -> ZipArchives.zip_writefile(w, "content.xml", codeunits(xml)), buf)
    @test_throws ArgumentError open_container(take!(buf))
    # a different ODF document type
    buf = IOBuffer()
    ZipArchives.ZipWriter(buf) do w
        ZipArchives.zip_writefile(w, "mimetype", codeunits("application/vnd.oasis.opendocument.text"))
        ZipArchives.zip_writefile(w, "content.xml", codeunits(xml))
    end
    @test_throws ArgumentError open_container(take!(buf))
    # not a package at all
    @test_throws ArgumentError open_container(UInt8[1, 2, 3, 4, 5])
    @test_throws ArgumentError open_container(Vector{UInt8}("<html/>"))
    # a flat document of another type
    @test_throws ArgumentError open_container(Vector{UInt8}(
        """<office:document $NS_DECL office:mimetype="application/vnd.oasis.opendocument.text"/>"""))
    # a damaged part (stored, so a flipped byte reaches the CRC check)
    b = package_bytes([PackagePart("content.xml", xml; compress = false)])
    i = findfirst(codeunits("office:spreadsheet"), b)
    b[first(i)] = UInt8('O')
    @test_throws ArgumentError read_xml(open_container(b), :content)
end

@testset "reader: flat document with BOM and CRLF line ends" begin
    flat = "\ufeff<?xml version=\"1.0\" encoding=\"UTF-8\"?>\r\n<office:document $NS_DECL office:version=\"1.3\" office:mimetype=\"$MEDIATYPE_ODS\">\r\n<office:body>\r\n<office:spreadsheet>\r\n" *
           "<table:table table:name=\"One\">\r\n<table:table-row><table:table-cell office:value-type=\"string\"><text:p>r1</text:p></table:table-cell></table:table-row>\r\n</table:table>\r\n" *
           "<table:table table:name=\"Two\">\r\n<table:table-row><table:table-cell office:value-type=\"string\"><text:p>r2</text:p></table:table-cell></table:table-row>\r\n</table:table>\r\n" *
           "</office:spreadsheet>\r\n</office:body>\r\n</office:document>\r\n"
    c = open_container(Vector{UInt8}(flat))
    @test c.format === :fods
    xml = read_xml(c, :content)
    @test odf_version(xml) == "1.3"
    s = index_sheets(xml)
    @test [x.name for x in s] == ["One", "Two"]
    @test first_cells(s[2]) == ["r2"]
    mktempdir() do dir
        p = joinpath(dir, "f.fods")
        write_flat(p, flat)
        @test [x.name for x in index_sheets(read_xml(open_container(p), :content))] == ["One", "Two"]
    end
end

# LibreOffice as the oracle (Q-005): `SOFFICE`, from runtests.jl.

@testset "LibreOffice opens what we write" begin
    if isempty(SOFFICE) || !isfile(SOFFICE)
        @info "LibreOffice not found; skipping the oracle round trip (set ODS_SOFFICE)"
        @test_skip false
    else
        mktempdir() do dir
            xml = replace(content_xml(["Data" => "hello"]), "<text:p>hello</text:p>" => "<text:p>hello</text:p>")
            for (v, fmt, mt) in [("1.4", "ods", MEDIATYPE_ODS), ("1.3", "ods", MEDIATYPE_ODS), ("1.4", "ots", MEDIATYPE_OTS)]
                p = joinpath(dir, "w$(replace(v, "." => ""))." * fmt)
                write_package(p, [PackagePart("content.xml", replace(xml, "office:version=\"1.4\"" => "office:version=\"$v\""))];
                              mediatype = mt, version = v)
                profile = lo_profile_url(joinpath(dir, "lo-profile"))
                outdir = joinpath(dir, "csv")
                run(pipeline(`$SOFFICE -env:UserInstallation=$profile --headless --norestore --convert-to csv --outdir $outdir $p`;
                             stdout = devnull, stderr = devnull))
                csv = joinpath(outdir, splitext(basename(p))[1] * ".csv")
                @test isfile(csv) && strip(read(csv, String)) == "hello"
            end
        end
    end
end

# A file another program wrote: ODF 1.2, content.xml and the manifest only (no styles, meta or
# settings). An edit keeps its version, and the manifest says the same, since LibreOffice refuses
# a package whose two versions differ (F-067). It said 1.4 before D-094.
@testset "an edited ODF 1.2 file from another program (D-094)" begin
    content = """<?xml version="1.0" encoding="UTF-8"?>
    <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" xmlns:of="urn:oasis:names:tc:opendocument:xmlns:of:1.2" office:version="1.2"><office:body><office:spreadsheet><table:table table:name="Data"><table:table-row><table:table-cell office:value-type="string"><text:p>Name</text:p></table:table-cell><table:table-cell office:value-type="string"><text:p>Qty</text:p></table:table-cell></table:table-row><table:table-row><table:table-cell office:value-type="string"><text:p>apples</text:p></table:table-cell><table:table-cell table:formula="of:=1+2" office:value-type="float" office:value="3"><text:p>3</text:p></table:table-cell></table:table-row></table:table></office:spreadsheet></office:body></office:document-content>"""
    manifest = """<?xml version="1.0" encoding="UTF-8"?>
    <manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.2"><manifest:file-entry manifest:full-path="/" manifest:media-type="application/vnd.oasis.opendocument.spreadsheet"/><manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/></manifest:manifest>"""
    edits = ["value" => xf -> (xf["Data"]["A3"] = "pears"),
             "font" => xf -> setFont(xf["Data"], "A1:B1"; bold = true),
             "width" => xf -> setColumnWidth(xf["Data"], "A"; width = 15),
             "sheet" => xf -> addsheet!(xf, "More")]
    mktempdir() do dir
        paths = String[]
        for (name, edit) in edits
            p = joinpath(dir, "other-$name.ods")
            ZipArchives.ZipWriter(p) do w
                ZipArchives.zip_writefile(w, "mimetype", codeunits(MEDIATYPE_ODS))
                ZipArchives.zip_writefile(w, "META-INF/manifest.xml", codeunits(manifest))
                ZipArchives.zip_writefile(w, "content.xml", codeunits(content))
            end
            @test readods(p)["Data"]["A1:B2"] == Any["Name" "Qty"; "apples" 3]
            openods(edit, p; mode = "rw")
            zr = ZipArchives.ZipReader(read(p))
            @test odf_version(String(ZipArchives.zip_readentry(zr, "content.xml"))) == "1.2"
            m = String(ZipArchives.zip_readentry(zr, "META-INF/manifest.xml"))
            @test occursin("<manifest:manifest xmlns:manifest=\"$NS_MANIFEST\" manifest:version=\"1.2\"", m)
            @test occursin("manifest:full-path=\"/\" manifest:version=\"1.2\"", m)
            push!(paths, p)
        end
        if isempty(SOFFICE) || !isfile(SOFFICE)
            @info "LibreOffice not found; skipping the edited ODF 1.2 oracle (set ODS_SOFFICE)"
            @test_skip false
        else
            out = joinpath(dir, "lo")
            run(pipeline(`$SOFFICE -env:UserInstallation=$(lo_profile_url(joinpath(dir, "lo-profile"))) --headless --norestore --convert-to fods --outdir $out $paths`;
                         stdout = devnull, stderr = devnull))
            for (p, (name, _)) in zip(paths, edits)
                f = joinpath(out, splitext(basename(p))[1] * ".fods")
                @test isfile(f)                                   # LibreOffice opened it
                isfile(f) || continue
                lo = readods(f)
                @test lo["Data"]["A2"] == "apples"
                name == "value" && @test lo["Data"]["A3"] == "pears"
                name == "font" && @test haskey(OpenDocumentSpreadsheets.getFont(lo["Data"], "A1").font, "b")
                name == "width" && @test OpenDocumentSpreadsheets.getColumnWidth(lo["Data"], "A1") ≈ 15 atol = 1
                name == "sheet" && @test sheetnames(lo) == ["Data", "More"]
            end
        end
    end
end

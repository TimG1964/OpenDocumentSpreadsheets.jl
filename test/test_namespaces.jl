# Namespace prefixes other than the usual ones (D-067; experiment 029, F-057). The fixtures
# are LibreOffice's lo-tables and lo-values with only their prefixes changed, and
# lo-verdict.tsv is what LibreOffice made of each: the same sheets and values as the
# original, or not a spreadsheet at all.

using OpenDocumentSpreadsheets: _ns_usual, _ns_canonical, _ns_rewrite, open_container, read_xml, read_part_text,
    getFormula, getAllDefinedNames, getSheetVisibility, get_dimension, ODSError,
    getDocumentProperties, setDocumentProperties, setPageMargins, freezePanes
import ZipArchives
import XML

# DATA (the fixtures folder) is defined in runtests.jl
const NSDIR = joinpath(DATA, "namespaces")
const NS_VERDICT = Dict(split(l, '\t')[1] => split(l, '\t')[2]
                        for l in readlines(joinpath(NSDIR, "lo-verdict.tsv"))[2:end])

# lo-tables-root.ods => test/data/lo-tables.ods
ns_base(f) = joinpath(DATA, replace(f, r"-[a-z]+\.(f?ods)$" => s".\1"))

# What a file holds, as the API reads it.
function ns_snapshot(xf)
    ws = [xf[n] for n in sheetnames(xf)]
    formulas = map(ws) do w
        d = get_dimension(w)
        [getFormula(w, r, c; raw = true) for r in row_number(d.start):row_number(d.stop),
                                             c in column_number(d.start):column_number(d.stop)]
    end
    return (names = sheetnames(xf), data = [getdata(w) for w in ws], formulas = formulas,
            visibility = getSheetVisibility.(ws),
            defined = sort!([(d.name, something(d.scope, ""), string(d.value)) for d in getAllDefinedNames(xf)]))
end
ns_snapshot(path::AbstractString) = ns_snapshot(readods(path))

@testset "the fast check" begin
    usual = """<r xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:x="http://example.com/x"><a/></r>"""
    @test _ns_usual(usual)
    @test _ns_canonical(usual) === usual                       # the same object: no copy
    # a declaration that isn't one: in a URI, in text
    @test _ns_usual("""<r xmlns:o="urn:x:xmlns:y">xmlns</r>""")
    # a known URI under another prefix; a usual prefix for another URI; a default namespace
    @test !_ns_usual("""<r xmlns:t="urn:oasis:names:tc:opendocument:xmlns:table:1.0"/>""")
    @test !_ns_usual("""<r xmlns:table="http://example.com/t"/>""")
    @test !_ns_usual("""<r xmlns="urn:oasis:names:tc:opendocument:xmlns:table:1.0"/>""")
    @test !_ns_usual("""<r xmlns = 'http://example.com/t'/>""")
    # on an inner element
    @test !_ns_usual("""<r><a xmlns:t='urn:oasis:names:tc:opendocument:xmlns:table:1.0'/></r>""")
    # LibreOffice's own inner declarations (office:scripts, embedded objects) are usual
    @test _ns_usual("""<r><ooo:libraries xmlns:ooo="http://openoffice.org/2004/office"/></r>""")
    # the vectorised search finds `xmlns` at every position, across 64-byte blocks, and
    # steps over near misses (`xml`, `xmln`)
    for len in (5, 63, 64, 65, 130, 200), at in 1:len-4
        s = fill(UInt8('a'), len); s[at:at+4] .= codeunits("xmlns")
        @test OpenDocumentSpreadsheets._next_xmlns(s, 1) == at
        @test OpenDocumentSpreadsheets._next_xmlns(s, at + 1) === nothing
    end
    near = Vector{UInt8}(repeat("a", 60) * "xml xmln " * repeat("b", 70) * "xmlns")
    @test OpenDocumentSpreadsheets._next_xmlns(near, 1) == length(near) - 4
    # every fixture of the corpus is read as it is
    for f in readdir(DATA; join = true)
        endswith(f, ".fods") && @test _ns_usual(read(f, String))
    end
end

@testset "the rewrite" begin
    T = "urn:oasis:names:tc:opendocument:xmlns:table:1.0"
    X = "urn:oasis:names:tc:opendocument:xmlns:text:1.0"
    OF = "urn:oasis:names:tc:opendocument:xmlns:of:1.2"
    # renamed prefixes, a default namespace, swapped prefixes, a formula's prefix, scope
    src = """<?xml version="1.0"?>\n<!-- a <comment> --><r xmlns:t="$T" xmlns:fm="$OF" a="1">""" *
          """<t:x t:formula="fm:=1+1" t:condition='fm:cell-content()&gt;1'>a &lt; b<![CDATA[<t:no/>]]></t:x>""" *
          """<s xmlns="$T" t:n="v"><y/></s><y/>""" *
          """<q xmlns:table="$X" xmlns:text="$T"><table:p text:name="n"/></q>""" *
          """<f xmlns:table="http://example.com/f"><table:z table:k="1"/></f><?pi <x>?></r>"""
    out = _ns_rewrite(src)
    @test _ns_usual(out)
    # every known namespace declared anywhere is declared on the root, in the usual order
    @test startswith(out, """<?xml version="1.0"?>\n<!-- a <comment> --><r xmlns:text="$X" xmlns:table="$T" xmlns:of="$OF" a="1">""")
    @test occursin("""<table:x table:formula="of:=1+1" table:condition='of:cell-content()&gt;1'>a &lt; b<![CDATA[<t:no/>]]></table:x>""", out)
    @test occursin("""<table:s table:n="v"><table:y/></table:s><y/>""", out)     # the default stops with its element
    @test occursin("""<q><text:p table:name="n"/></q>""", out)
    # an unknown namespace whose prefix is a usual one is given another prefix
    @test occursin("""<f xmlns:ns1="http://example.com/f"><ns1:z ns1:k="1"/></f><?pi <x>?></r>""", out)
    # a value prefix that isn't declared, an unknown element, the xml prefix: as written
    @test _ns_rewrite("""<r xmlns:t="$T"><t:c t:formula="msoxl:=A1" xml:lang="en"><u:v/></t:c></r>""") ==
          """<r xmlns:table="$T"><table:c table:formula="msoxl:=A1" xml:lang="en"><u:v/></table:c></r>"""
    # well-formed, and XML.jl reads the same tree shape
    @test XML.tag(XML.parse(out, XML.Node)[end]) == "r"
    @test_throws ArgumentError _ns_rewrite("""<r xmlns:t="$T"><t:a b="1></r>""")
end

@testset "LibreOffice's variants (experiment 029)" begin
    @test Set(keys(NS_VERDICT)) == Set(f for f in readdir(NSDIR) if !endswith(f, ".tsv"))   # a verdict for every variant
    for (f, verdict) in sort!(collect(NS_VERDICT))
        path = joinpath(NSDIR, f)
        if verdict == "not a spreadsheet"
            # LibreOffice's type detection keys on `office:mimetype` as written (F-057)
            @test_throws ODSError readods(path)
            @test occursin("office:mimetype is nothing", sprint(showerror, try readods(path) catch e; e end))
            continue
        end
        @test verdict == "same as base"
        base = ns_snapshot(ns_base(f))
        got = ns_snapshot(path)
        @test got.names == base.names
        @test isequal(got.data, base.data)
        @test got.formulas == base.formulas
        @test got.visibility == base.visibility
        @test got.defined == base.defined
        # the parts OpenDocumentSpreadsheets reads have the usual prefixes
        c = open_container(path)
        @test _ns_usual(read_xml(c, :content))
        @test _ns_usual(something(read_xml(c, :styles), ""))
        # one-shot reads (zipped: the prefix read; it falls back to the whole part)
        for n in base.names
            @test isequal(readdata(path, n, "A1:D6"), readdata(ns_base(f), n, "A1:D6"))
        end
    end
    # the variants' parts were not usual to start with
    z = ZipArchives.ZipReader(read(joinpath(NSDIR, "lo-tables-swap.ods")))
    @test !_ns_usual(ZipArchives.zip_readentry(z, "content.xml", String))
    @test !_ns_usual(ZipArchives.zip_readentry(z, "styles.xml", String))
end

@testset "saving a file with other prefixes" begin
    mktempdir() do dir
        for f in ("lo-tables-swap.ods", "lo-tables-inner.fods", "lo-values-of.ods")
            out = joinpath(dir, "saved-" * f)
            ref = joinpath(dir, "ref-" * f)
            for (src, dst) in ((joinpath(NSDIR, f), out), (ns_base(f), ref))
                xf = openods(src; mode = "rw")
                ws = xf[1]
                setdata!(ws, "H20", "edited")                     # content.xml
                freezePanes(ws; nrows = 1)                        # settings.xml
                setPageMargins(ws; left = 1.0)                    # styles.xml
                setDocumentProperties(xf; title = "T")            # meta.xml
                writeods(dst, xf; overwrite = true)
            end
            @test isequal(ns_snapshot(out), ns_snapshot(ref))
            @test getdata(readods(out)[1], "H20") == "edited"
            @test getDocumentProperties(readods(out)).title == "T"
            # every part written again has the usual prefixes; LibreOffice's are untouched elsewhere
            c = open_container(out)
            for p in (:content, :styles, :settings, :meta)
                t = c.zip === nothing ? c.flat : OpenDocumentSpreadsheets.readentry_string(c.zip, string(p) * ".xml")
                @test _ns_usual(t)
            end
        end
        # a part not edited keeps its bytes, prefixes and all
        out = joinpath(dir, "content-only.ods")
        xf = openods(joinpath(NSDIR, "lo-tables-swap.ods"); mode = "rw")
        setdata!(xf[1], "H20", 1)
        writeods(out, xf; overwrite = true)
        z0 = ZipArchives.ZipReader(read(joinpath(NSDIR, "lo-tables-swap.ods")))
        z1 = ZipArchives.ZipReader(read(out))
        @test ZipArchives.zip_readentry(z1, "styles.xml") == ZipArchives.zip_readentry(z0, "styles.xml")
        @test isequal(ns_snapshot(out).data[2:end], ns_snapshot(ns_base("lo-tables-swap.ods")).data[2:end])
    end
end

@testset "LibreOffice reads what OpenDocumentSpreadsheets saves from them" begin
    if lo_ok()
        mktempdir() do dir
            for f in ("lo-tables-swap.ods", "lo-tables-default.fods")
                out = joinpath(dir, "saved-" * f)
                xf = openods(joinpath(NSDIR, f); mode = "rw")
                setdata!(xf["Table"], "H20", "edited")
                writeods(out, xf; overwrite = true)
                profile = lo_profile_url(joinpath(dir, "lo-profile"))
                csvdir = joinpath(dir, "csv-" * f)
                lo_convert(out, "csv"; outdir = csvdir, profile = profile)
                csv = joinpath(csvdir, splitext(basename(out))[1] * ".csv")
                @test isfile(csv) && occursin("edited", read(csv, String))
            end
        end
    end
end

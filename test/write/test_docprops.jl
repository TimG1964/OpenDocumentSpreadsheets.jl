# Document properties (phase 5 step 11; D-064, F-056): against LibreOffice's import of XLSX.jl's
# properties and its own file (experiment 027, test/data/docprops/), in saved files and through
# LibreOffice. Part B of the experiment showed LibreOffice reading every property of a patched and a
# new file (lo-props.tsv's `odsf` rows). XLSX.jl's docprops cases are ported where they apply.

using OpenDocumentSpreadsheets: getDocumentProperties, getCustomProperty, getCustomProperties, ODSError

const DOCP = joinpath(DATA, "docprops")
const DOCP_IMPORT = joinpath(DOCP, "lo-import.fods")
const DOCP_OWN = joinpath(DOCP, "lo-own.fods")

_meta_of(s::AbstractString) = match(r"<office:meta>.*</office:meta>"s, s).match
_meta_kids(s) = [m.match for m in eachmatch(r"<(?:dc|meta):[a-z-]+(?:\s[^>]*)?(?:/>|>[^<]*</[^>]+>)", _meta_of(s))]
_no_lo_only(k) = filter(x -> !occursin(r"^<meta:(generator|document-statistic)|meta:name=\"AppVersion\"", x), k)

# build.jl's calls in experiment 027
function _all_props!(xf)
    setDocumentProperties(xf; title = "The title", subject = "The subject", creator = "The creator",
        keywords = "kw1; kw2, kw3", description = "The description", lastModifiedBy = "The modifier",
        category = "The category", contentStatus = "The status", created = DateTime(2026, 1, 15, 9, 30),
        modified = DateTime(2026, 2, 20, 14, 45, 10), company = "The company", manager = "The manager")
    for (k, v) in ("Text" => "hello", "Int" => 42, "Big" => 5_000_000_000, "Real" => 2.5, "Yes" => true,
                   "When" => DateTime(2026, 3, 4, 5, 6, 7), "Day" => Date(2026, 3, 4))
        setCustomProperty(xf, k, v)
    end
    return xf
end

const DOCP_EXPECTED = (title = "The title", subject = "The subject", creator = "The creator", keywords = "kw1, kw2, kw3",
    description = "The description", lastModifiedBy = "The modifier", category = "The category", contentStatus = "The status",
    created = DateTime(2026, 1, 15, 9, 30), modified = DateTime(2026, 2, 20, 14, 45, 10), company = "The company",
    manager = "The manager")
const DOCP_CUSTOM = ["Big" => 5_000_000_000, "Day" => DateTime(2026, 3, 4), "Int" => 42, "Real" => 2.5, "Text" => "hello",
                     "When" => DateTime(2026, 3, 4, 5, 6, 7), "Yes" => true]

@testset "LibreOffice's properties, read (experiment 027)" begin
    im = readods(DOCP_IMPORT)
    @test getDocumentProperties(im) == DOCP_EXPECTED
    @test getCustomProperties(im) == vcat(["AppVersion" => "16.0300"], DOCP_CUSTOM)   # the import's AppVersion is kept
    @test getCustomProperty(im, "int") === Int64(42) && getCustomProperty(im, "BIG") === Int64(5_000_000_000)   # names ignore case
    @test getCustomProperty(im, "Real") === 2.5 && getCustomProperty(im, "Missing") === nothing
    @test getCustomProperty(im, "Company") === nothing                    # a document property here
    own = readods(DOCP_OWN)
    p = getDocumentProperties(own)
    @test (p.title, p.subject, p.creator, p.keywords, p.description) == ("Own title", "Own subject", "Own author", "k1, k2", "Own description")
    @test p.created == DateTime(2026, 1, 15, 9, 30) && p.modified isa DateTime            # LibreOffice's save time, with ns
    @test p.lastModifiedBy === nothing && p.category === nothing && p.company === nothing
    @test getCustomProperties(own) == ["Real" => 2.5, "Text" => "hello", "Yes" => true]    # a string without a type
    # the other fixtures have none set
    q = getDocumentProperties(readods(joinpath(DATA, "lo-values.ods")))
    @test q.title === nothing && q.company === nothing
end

@testset "properties written as LibreOffice's import writes them (experiment 027)" begin
    lo = _no_lo_only(_meta_kids(read(DOCP_IMPORT, String)))
    # a new file: the import's elements, in its order
    nf = _all_props!(newods())
    for ext in (".ods", ".fods")
        f = writeods(joinpath(mktempdir(), "n" * ext), nf)
        s = ext == ".fods" ? read(f, String) : String(OpenDocumentSpreadsheets.read_xml(openods(f).container, :meta))
        @test _no_lo_only(_meta_kids(s)) == lo
        @test occursin("<meta:generator>OpenDocumentSpreadsheets.jl/", s)
        r = readods(f)
        @test getDocumentProperties(r) == DOCP_EXPECTED && getCustomProperties(r) == DOCP_CUSTOM
    end
    # LibreOffice's own file, patched: the same, with its generator, statistics and editing items kept
    xf = _all_props!(openods(DOCP_OWN; mode = "rw"))
    s = read(writeods(joinpath(mktempdir(), "p.fods"), xf), String)
    k = _meta_kids(s)
    @test count(x -> startswith(x, "<meta:generator>LibreOffice"), k) == 1
    @test any(startswith("<meta:editing-cycles>"), k) && any(startswith("<meta:document-statistic"), k)
    kept = filter(x -> !occursin(r"^<meta:(editing|generator|document-statistic)", x), k)
    @test sort(kept) == sort(lo)                     # the file's own order kept: its description before its keywords
    @test findfirst(startswith("<dc:description"), kept) < findfirst(startswith("<meta:keyword"), kept)
    # everything else in the file is as it was (D-023)
    orig = read(DOCP_OWN, String)
    @test replace(s, _meta_of(s) => "") == replace(orig, _meta_of(orig) => "")
end

@testset "changing a file's properties" begin
    xf = openods(DOCP_IMPORT; mode = "rw")
    setDocumentProperties(xf; subject = "", title = "New title", modified = DateTime(2026, 3, 1))
    p = getDocumentProperties(xf)
    @test p.subject === nothing && p.title == "New title" && p.modified == DateTime(2026, 3, 1)
    setDocumentProperties(xf; keywords = "only")
    @test getDocumentProperties(xf).keywords == "only"
    setDocumentProperties(xf; keywords = "")
    @test getDocumentProperties(xf).keywords === nothing
    setDocumentProperties(xf; keywords = "a,b")                       # back where LibreOffice keeps them
    kids = first.(OpenDocumentSpreadsheets._meta(xf).children)
    @test findfirst(==("meta:keyword"), kids) == findfirst(==("meta:initial-creator"), kids) + 1
    setDocumentProperties(xf; company = "", manager = "M2")
    @test getDocumentProperties(xf).company === nothing && getDocumentProperties(xf).manager == "M2"
    setCustomProperty(xf, "int", 7)                                    # replaces Int, keeping its name
    @test getCustomProperty(xf, "Int") == 7 && count(p -> lowercase(p.first) == "int", getCustomProperties(xf)) == 1
    setCustomProperty(xf, "Float", 3.0)
    @test getCustomProperty(xf, "Float") === 3.0
    setCustomProperty(xf, "Aardvark", "first")                          # LibreOffice keeps them by name
    @test first(getCustomProperties(xf)).first == "Aardvark"
    @test deleteCustomProperty(xf, "real") && !deleteCustomProperty(xf, "real")
    @test !deleteCustomProperty(xf, "Company")
    setCustomProperty(xf, "Esc", "a < b & \"c\"")
    setCustomProperty(xf, "n"^255, 1)
    names = first.(getCustomProperties(xf))
    @test names == sort(names)
    r = readods(writeods(joinpath(mktempdir(), "c.fods"), xf))
    @test getDocumentProperties(r) == getDocumentProperties(xf)
    @test getCustomProperties(r) == getCustomProperties(xf)
    @test getCustomProperty(r, "Esc") == "a < b & \"c\""
    # set and read back on a file without properties, zipped and flat; others' items kept
    for f in (joinpath(DATA, "lo-values.ods"), joinpath(DATA, "lo-values.fods"))
        yf = openods(f; mode = "rw")
        before = _meta_kids(String(OpenDocumentSpreadsheets.read_xml(yf.container, :meta)))
        setDocumentProperties(yf; title = "T", company = "C")
        r = openods(writeods(joinpath(mktempdir(), "t" * splitext(f)[2]), yf))
        after = _meta_kids(String(OpenDocumentSpreadsheets.read_xml(r.container, :meta)))
        @test getDocumentProperties(r).title == "T" && getDocumentProperties(r).company == "C"
        @test filter(x -> !occursin(r"dc:title|\"Company\"", x), after) == before
        @test after[1] == "<dc:title>T</dc:title>"
    end
    # a save without property calls keeps meta.xml's bytes; reading properties changes nothing
    zf = openods(joinpath(DATA, "lo-values.ods"); mode = "rw")
    getDocumentProperties(zf); getCustomProperties(zf); deleteCustomProperty(zf, "none"); setDocumentProperties(zf; title = "", keywords = "")
    f = writeods(joinpath(mktempdir(), "u.ods"), zf)
    @test OpenDocumentSpreadsheets.read_bytes(openods(f).container, "meta.xml") == OpenDocumentSpreadsheets.read_bytes(openods(joinpath(DATA, "lo-values.ods")).container, "meta.xml")
end

@testset "dates" begin
    pd = OpenDocumentSpreadsheets._parse_meta_datetime
    @test pd("2024-01-02T03:04:05Z") == DateTime(2024, 1, 2, 3, 4, 5)
    @test pd("2024-01-02T03:04:05.25Z") == DateTime(2024, 1, 2, 3, 4, 5, 250)
    @test pd("2026-11-21T00:19:18.576367300") == DateTime(2026, 11, 21, 0, 19, 18, 576)     # LibreOffice's
    @test pd("2024-01-02T03:04:05+01:30") == DateTime(2024, 1, 2, 1, 34, 5)
    @test pd("2024-01-02T03:04-02:00") == DateTime(2024, 1, 2, 5, 4)
    @test pd("2024-01-02") == DateTime(2024, 1, 2)
    @test pd("2024-13-02") === nothing && pd("yesterday") === nothing
    @test OpenDocumentSpreadsheets._odf_datetime(DateTime(2024, 1, 2, 3, 4, 5, 999)) == "2024-01-02T03:04:05"
    xf = newods()
    setDocumentProperties(xf; created = Date(2024, 5, 6))
    @test getDocumentProperties(xf).created == DateTime(2024, 5, 6)
    OpenDocumentSpreadsheets._meta_set!(OpenDocumentSpreadsheets._meta(xf), "meta:creation-date", "<meta:creation-date>not a date</meta:creation-date>")
    @test getDocumentProperties(xf).created == "not a date"            # kept as written
    # a new file's creation date is set when it is made; the generator is OpenDocumentSpreadsheets'
    nf = newods()
    @test getDocumentProperties(nf).created isa DateTime && getDocumentProperties(nf).title === nothing
end

@testset "errors" begin
    xf = newods()
    @test_throws ODSError setDocumentProperties(xf)
    @test_throws ODSError setDocumentProperties(xf; author = "A")
    @test_throws ODSError setDocumentProperties(xf; title = 1)
    @test_throws ODSError setDocumentProperties(xf; created = "2024-01-01")
    @test_throws ODSError setDocumentProperties(xf; title = "bad\x01")
    @test_throws ODSError setCustomProperty(xf, "", 1)
    @test_throws ODSError setCustomProperty(xf, "n"^256, 1)
    @test_throws ODSError setCustomProperty(xf, "x", NaN)
    @test_throws ODSError setCustomProperty(xf, "x", [1, 2])
    @test_throws ODSError setCustomProperty(xf, "company", "C")          # setDocumentProperties' own
    @test_throws ODSError setCustomProperty(xf, "OOXMLCorePropertyCategory", "C")
    @test isempty(getCustomProperties(xf))                               # nothing was added
    r = openods(DOCP_IMPORT)
    @test_throws ODSError setDocumentProperties(r; title = "T")
    @test_throws ODSError setCustomProperty(r, "x", 1)
    @test_throws ODSError deleteCustomProperty(r, "x")
end

@testset "LibreOffice reads the properties" begin
    if isempty(SOFFICE) || !isfile(SOFFICE)
        @info "LibreOffice not found; skipping the document properties oracle (set ODS_SOFFICE)"
        @test_skip false
    else
        dir = mktempdir()
        profile = lo_profile_url(joinpath(dir, "lo-profile"))
        files = [writeods(joinpath(dir, "new.ods"), _all_props!(newods())),
                 writeods(joinpath(dir, "patched.fods"), _all_props!(openods(DOCP_OWN; mode = "rw")))]
        run(pipeline(`$SOFFICE -env:UserInstallation=$profile --headless --norestore --convert-to fods --outdir $(joinpath(dir, "lo")) $files`;
                     stdout = devnull, stderr = devnull))
        for n in ("new", "patched")
            lo = readods(joinpath(dir, "lo", n * ".fods"))
            p = getDocumentProperties(lo)
            # LibreOffice's save sets the modification date and modifier (the profile has no user name)
            @test all(getfield(p, k) == getfield(DOCP_EXPECTED, k) for k in keys(p) if k ∉ (:lastModifiedBy, :modified))
            @test getCustomProperties(lo) == DOCP_CUSTOM
        end
    end
end

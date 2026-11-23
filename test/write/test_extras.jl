# What an edited cell keeps of the original (D-071): its annotation, anchored shapes and validation,
# and its paragraphs as written while its text is the same. LibreOffice's fixtures from experiments
# 030–032 (test/data/links, images, validation).
import XML
const O_X = OpenDocumentSpreadsheets

const LINKS_OWN = joinpath(@__DIR__, "..", "data", "links", "lo-links-own.fods")
const IMAGES_OWN = joinpath(@__DIR__, "..", "data", "images", "lo-images-own.fods")
const VALID_OWN = joinpath(@__DIR__, "..", "data", "validation", "lo-validation-own.fods")

# The cells of sheet `sheet` in a flat file's text, as "A1" => the cell's XML.Node (repeats expanded
# up to `maxcol` columns and `maxrow` rows).
function sheet_cells(text::AbstractString, sheet::AbstractString; maxrow = 60, maxcol = 12)
    doc = XML.parse(String(text), XML.Node)
    cells = Dict{String,XML.Node}()
    function find_table(n)
        XML.tag(n) == "table:table" && get(XML.attributes(n), "table:name", "") == sheet && return n
        for c in XML.children(n)
            XML.nodetype(c) === XML.Element || continue
            t = find_table(c)
            t === nothing || return t
        end
        return nothing
    end
    t = find_table(doc)
    t === nothing && error("no sheet $sheet")
    row = 0
    function rows(n)
        for c in XML.children(n)
            XML.nodetype(c) === XML.Element || continue
            tag = XML.tag(c)
            if tag == "table:table-row"
                rep = parse(Int, get(something(XML.attributes(c), Dict{String,String}()), "table:number-rows-repeated", "1"))
                for _ in 1:min(rep, maxrow)
                    row += 1
                    row > maxrow && return
                    col = 0
                    for cc in XML.children(c)
                        XML.nodetype(cc) === XML.Element || continue
                        XML.tag(cc) in ("table:table-cell", "table:covered-table-cell") || continue
                        a = something(XML.attributes(cc), Dict{String,String}())
                        for _ in 1:min(parse(Int, get(a, "table:number-columns-repeated", "1")), maxcol)
                            col += 1
                            col <= maxcol && (cells[string(O_X.SheetCore.encode_column_number(col), row)] = cc)
                        end
                    end
                end
            elseif tag in ("table:table-rows", "table:table-row-group", "table:table-header-rows")
                rows(c)
            end
        end
    end
    rows(t)
    return cells
end

_attrs(n) = something(XML.attributes(n), Dict{String,String}())
_kids(n) = [c for c in XML.children(n) if XML.nodetype(c) === XML.Element]
_kidtags(n) = [XML.tag(c) for c in _kids(n)]
function _alltext(n)
    io = IOBuffer()
    f(x) = XML.nodetype(x) === XML.Text ? print(io, XML.value(x)) : foreach(f, XML.children(x))
    f(n)
    return String(take!(io))
end
_hrefs(n) = (v = String[]; f(x) = (XML.nodetype(x) === XML.Element && (XML.tag(x) == "text:a" && push!(v, _attrs(x)["xlink:href"]); foreach(f, XML.children(x)))); f(n); v)
# the text of a cell's annotation: its paragraphs, one per line
function _note(n)
    k = findfirst(c -> XML.tag(c) == "office:annotation", _kids(n))
    k === nothing && return nothing
    return join([_alltext(p) for p in _kids(_kids(n)[k]) if XML.tag(p) == "text:p"], "
")
end
_validation(n) = get(_attrs(n), "table:content-validation-name", nothing)

@testset "the quick test for extras" begin
    m = O_X._maybe_extras
    @test !m("<table:table-cell/>")
    @test !m("<table:table-cell table:number-columns-repeated=\"3\"/>")
    @test !m("<table:table-cell office:value-type=\"float\" office:value=\"1\"><text:p>1</text:p></table:table-cell>")
    @test !m("<table:table-cell office:value-type=\"string\"><text:p>a<text:s text:c=\"2\"/>b<text:tab/>c<text:line-break/></text:p><text:p/><text:h>x</text:h></table:table-cell>")
    @test m("<table:table-cell table:content-validation-name=\"val1\"/>")
    @test m("<table:table-cell table:style-name=\"ce1\" table:content-validation-name=\"val1\" office:value-type=\"float\" office:value=\"1\"><text:p>1</text:p></table:table-cell>")
    @test m("<table:table-cell><office:annotation><text:p>n</text:p></office:annotation></table:table-cell>")
    @test m("<table:table-cell office:value-type=\"string\"><text:p><text:a xlink:href=\"x\">a</text:a></text:p></table:table-cell>")
    @test m("<table:table-cell office:value-type=\"string\"><text:p><text:span text:style-name=\"T1\">a</text:span></text:p></table:table-cell>")
    @test m("<table:table-cell office:value-type=\"string\"><text:p><text:page-number/></text:p></table:table-cell>")
    @test m("<table:table-cell><draw:frame/></table:table-cell>")
end

function _edit_links(xf)
    ws = xf["Own"]
    ws["B14"] = 8              # a note on a number
    ws["B16"] = "plain"        # a note and a URL field: new text
    ws["B21"] = 50             # a validation, a note and a URL field
    ws["B17"] = 3              # a note on an empty cell
    ws["B31"] = 13             # a cell link (in the style) on a number
    ws["B2"] = ws["B2"]        # a URL field inside text, the same text
    ws["B6"] = ws["B6"]        # two paragraphs, a field in the second, the same text
    setFont(ws, "B3"; bold = true)          # two URL fields, restyled
    setFont(ws, "B12"; italic = true)       # a visible note on an empty cell, restyled
    return xf
end

function _check_links(cells; lo::Bool = false)
    c = cells["B14"]
    @test _note(c) == "On seven"
    @test _kidtags(c) == ["office:annotation", "text:p"]           # LibreOffice's order (F-059)
    @test _alltext(_kids(c)[2]) == "8"
    c = cells["B16"]
    @test _note(c) == "Both" && isempty(_hrefs(c))                 # the field went with the old text
    @test _alltext(_kids(c)[end]) == "plain"
    c = cells["B21"]
    @test _validation(c) == "val1" && _note(c) == "Validated" && isempty(_hrefs(c))
    @test _attrs(c)["office:value"] == "50"
    c = cells["B17"]
    @test _note(c) == "On an empty cell" && _attrs(c)["office:value"] == "3"
    @test _attrs(cells["B31"])["office:value"] == "13"
    @test startswith(_attrs(cells["B31"])["table:style-name"], "ce")  # the cell link's style
    @test _hrefs(cells["B2"]) == ["https://example.org/mid"]
    @test strip(_alltext(cells["B2"])) == "Before link after"
    @test _hrefs(cells["B6"]) == ["https://example.org/p2"]
    @test count(==("text:p"), _kidtags(cells["B6"])) == 2
    @test _hrefs(cells["B3"]) == ["https://example.org/one", "https://example.org/two"]
    @test _note(cells["B12"]) == "Visible"
    lo || @test get(_attrs(_kids(cells["B12"])[1]), "office:display", "") == "true"
end

@testset "an edited cell keeps its note, validation and links (D-071)" begin
    dir = mktempdir()
    out = writeods(joinpath(dir, "links.fods"), _edit_links(openods(LINKS_OWN; mode = "rw")))
    text = read(out, String)
    cells = sheet_cells(text, "Own")
    _check_links(cells)
    @test occursin("table:style-name=\"Default\" table:content-validation-name=\"val1\" office:value-type=\"float\"", text)
    r = readods(out)["Own"]
    @test r["B14"] == 8 && r["B16"] == "plain" && r["B21"] == 50 && r["B2"] == "Before link after"
    @test r["B17"] == 3 && r["B31"] == 13
    # the validation still lists the cell
    @test occursin("<table:content-validation table:name=\"val1\"", text)
end

@testset "an edited cell keeps the shapes anchored in it" begin
    dir = mktempdir()
    xf = openods(IMAGES_OWN; mode = "rw")
    ws = xf["Own"]
    ws["D2"] = "here"                 # a picture anchored in an empty cell
    setFont(ws, "D10"; bold = true)   # the JPEG's cell, restyled
    ws["B10"] = 1.5                   # the named picture with alt text
    text = read(writeods(joinpath(dir, "img.fods"), xf), String)
    cells = sheet_cells(text, "Own")
    @test _kidtags(cells["D2"]) == ["text:p", "draw:frame"]          # the paragraphs before the shapes
    @test _alltext(_kids(cells["D2"])[1]) == "here"
    @test _kidtags(cells["D10"]) == ["draw:frame"]
    f = _kids(cells["B10"])[end]
    @test XML.tag(f) == "draw:frame" && _attrs(f)["draw:name"] == "MyPicture"
    @test "svg:title" in _kidtags(f) && "svg:desc" in _kidtags(f)
    @test _attrs(cells["B10"])["office:value"] == "1.5"
    @test count("<draw:frame", text) == count("<draw:frame", read(IMAGES_OWN, String))
end

@testset "a validation on repeated cells stays on every column" begin
    dir = mktempdir()
    xf = openods(VALID_OWN; mode = "rw")
    ws = xf["Own"]
    ws["C21"] = 4                     # inside B20:C22 (val18, a repeated cell)
    ws["B24"] = 7                     # a shared rule (val1)
    text = read(writeods(joinpath(dir, "v.fods"), xf), String)
    cells = sheet_cells(text, "Own")
    @test _validation(cells["B21"]) == "val18" && _validation(cells["C21"]) == "val18"
    @test _attrs(cells["C21"])["office:value"] == "4"
    @test _validation(cells["B24"]) == "val1" && _validation(cells["B26"]) == "val1"
    @test readods(joinpath(dir, "v.fods"))["Own"]["C21"] == 4
end

@testset "extras survive edits after inserts and deletes" begin
    dir = mktempdir()
    xf = openods(LINKS_OWN; mode = "rw")
    ws = xf["Own"]
    insertRows(ws, 1; count = 2)
    insertColumns(ws, "A"; count = 1)
    ws["C16"] = 8                     # B14 before the inserts
    ws["C23"] = 50                    # B21
    text = read(writeods(joinpath(dir, "m.fods"), xf), String)
    cells = sheet_cells(text, "Own")
    @test _note(cells["C16"]) == "On seven" && _attrs(cells["C16"])["office:value"] == "8"
    @test _validation(cells["C23"]) == "val1" && _note(cells["C23"]) == "Validated"
    @test _hrefs(cells["C4"]) == ["https://example.org/mid"]            # untouched: copied
end

@testset "LibreOffice reads the extras of edited cells" begin
    if isempty(SOFFICE) || !isfile(SOFFICE)
        @info "LibreOffice not found; skipping the cell extras oracle (set ODS_SOFFICE)"
        @test_skip false
    else
        dir = mktempdir()
        profile = lo_profile_url(joinpath(dir, "lo-profile"))
        a = writeods(joinpath(dir, "links.fods"), _edit_links(openods(LINKS_OWN; mode = "rw")))
        xf = openods(IMAGES_OWN; mode = "rw")
        xf["Own"]["D2"] = "here"
        b = writeods(joinpath(dir, "img.fods"), xf)
        run(pipeline(`$SOFFICE -env:UserInstallation=$profile --headless --norestore --convert-to fods --outdir $(joinpath(dir, "lo")) $a $b`;
                     stdout = devnull, stderr = devnull))
        _check_links(sheet_cells(read(joinpath(dir, "lo", "links.fods"), String), "Own"); lo = true)
        cells = sheet_cells(read(joinpath(dir, "lo", "img.fods"), String), "Own")
        @test _kidtags(cells["D2"]) == ["text:p", "draw:frame"]
        @test _alltext(_kids(cells["D2"])[1]) == "here"
    end
end

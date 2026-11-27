# Panes and the sheet view (phase 5 step 8; D-061, F-053), against LibreOffice's own settings
# (experiment 024, test/data/views/): what OpenDocumentSpreadsheets reads of them, what it writes (the items
# LibreOffice's xlsx import writes for the same XLSX.jl calls), and patched saves. That LibreOffice
# honours what OpenDocumentSpreadsheets writes needs a view, which a conversion has not: experiment 024 part D checks
# it (`run_verify.sh`, out/verify.tsv, copied as lo-views-verify.tsv). XLSX.jl's panes.jl and
# sheet-view.jl cases are ported where they apply.

using OpenDocumentSpreadsheets: getSheetView, ODSError, renamesheet!, copysheet!, deletesheet!, insertRows, CellRef

const VIEWS = joinpath(DATA, "views")

# A sheet's items in a saved file's first view (as `name => value`), read without OpenDocumentSpreadsheets.
function view_items(path, sheet)
    s = endswith(path, ".fods") ? read(path, String) : String(OpenDocumentSpreadsheets.read_xml(OpenDocumentSpreadsheets.open_container(path), :settings))
    m = match(Regex("<config:config-item-map-entry config:name=\"" * sheet * "\">(.*?)</config:config-item-map-entry>", "s"), s)
    m === nothing && return Dict{String,String}()
    return Dict(String(x.captures[1]) => String(x.captures[2])
                for x in eachmatch(r"<config:config-item config:name=\"([^\"]*)\" config:type=\"[^\"]*\">([^<]*)</config:config-item>", m.captures[1]))
end

@testset "LibreOffice's views, read (experiment 024)" begin
    im = readods(joinpath(VIEWS, "lo-views-import.fods"))      # its import of XLSX.jl's file
    @test getSheetView(im["Zoom"]).zoom == 150 && getSheetView(im["Plain"]).zoom == 100
    @test getSheetView(im["Flags"]).showGridLines == false && getSheetView(im["Plain"]).showGridLines
    v = getSheetView(im["Sel"])
    @test v.activeCell == CellRef("C3") && v.topLeftCell == CellRef("C10") && v.selection == "C3"
    @test getSheetView(im["RTL"]).rightToLeft && !getSheetView(im["Plain"]).rightToLeft
    @test getSheetView(im["Freeze"]).topLeftCell == CellRef("B3") && getSheetView(im["Freeze"]).activeCell == CellRef("B3")
    own = readods(joinpath(VIEWS, "lo-views-own.fods"))         # its own settings: view-wide flags off
    v = getSheetView(own["Plain"])
    @test v.view === :pageBreakPreview && v.zoom == 60 && !v.showGridLines && !v.showRowColHeaders && !v.showZeros
    @test getSheetView(own["Sel"]).topLeftCell == CellRef("C10")
    # a file without view settings: LibreOffice's defaults
    v = getSheetView(readods(joinpath(DATA, "lo-values.fods"))[1])
    @test v == (zoom = 100, view = :normal, showGridLines = true, showRowColHeaders = true, showZeros = true,
                rightToLeft = false, topLeftCell = CellRef("A1"), activeCell = CellRef("A1"), selection = "A1")
end

@testset "panes and views written as LibreOffice's import writes them" begin
    lo(sheet) = view_items(joinpath(VIEWS, "lo-views-import.fods"), sheet)
    dir = mktempdir()
    for ext in ("ods", "fods")
        xf = newods("Freeze")
        foreach(n -> addsheet!(xf, n), ["Split", "Zoom", "Flags", "Sel"])
        freezePanes(xf["Freeze"]; nrows = 2, ncols = 1)
        splitPanes(xf["Split"]; nrows = 3, ncols = 2)
        setSheetView(xf["Zoom"]; zoom = 150)
        setSheetView(xf["Flags"]; showGridLines = false)
        setSheetView(xf["Sel"]; selection = "B2:D5", activeCell = "C3", topLeftCell = "C10")
        p = writeods(joinpath(dir, "w.$ext"), xf)
        # the items, as LibreOffice wrote them for XLSX.jl's file (split positions are pixels: F-053)
        for (s, keys) in (("Freeze", ["CursorPositionX", "CursorPositionY", "HorizontalSplitMode", "VerticalSplitMode",
                                      "HorizontalSplitPosition", "VerticalSplitPosition", "ActiveSplitRange",
                                      "PositionLeft", "PositionRight", "PositionTop", "PositionBottom"]),
                          ("Split", ["CursorPositionX", "CursorPositionY", "HorizontalSplitMode", "VerticalSplitMode",
                                     "ActiveSplitRange", "PositionRight", "PositionBottom"]),
                          ("Zoom", ["ZoomValue"]), ("Flags", ["ShowGrid"]),
                          ("Sel", ["CursorPositionX", "CursorPositionY", "PositionLeft", "PositionTop", "PositionBottom"]))
            got = view_items(p, s); want = lo(s)
            @test all(k -> get(got, k, "(none)") == want[k], keys) || (@info "items" s got want; false)
        end
        # in LibreOffice's order: it reads them in turn (F-053)
        t = endswith(p, ".fods") ? read(p, String) : String(OpenDocumentSpreadsheets.read_xml(OpenDocumentSpreadsheets.open_container(p), :settings))
        e = match(r"<config:config-item-map-entry config:name=\"Freeze\">(.*?)</config:config-item-map-entry>"s, t).captures[1]
        names = [m.captures[1] for m in eachmatch(r"config:name=\"([^\"]*)\"", e)]
        @test issorted(names; by = OpenDocumentSpreadsheets._item_rank)
        # the namespaces LibreOffice needs to read them (F-053)
        root = match(r"<office:document(-settings)?\s[^>]*>", t).match
        @test occursin("xmlns:ooo=\"http://openoffice.org/2004/office\"", root) && occursin("xmlns:config=", root)
        r = readods(p)
        @test getSheetView(r["Zoom"]).zoom == 150 && !getSheetView(r["Flags"]).showGridLines
        @test getSheetView(r["Sel"]).activeCell == CellRef("C3") && getSheetView(r["Sel"]).topLeftCell == CellRef("C10")
        @test getSheetView(r["Freeze"]).topLeftCell == CellRef("B3")
    end
    # LibreOffice showed these files as set (experiment 024 part D)
    ver = Dict((split(l, '\t')[1], split(l, '\t')[2]) => l for l in eachline(joinpath(VIEWS, "lo-views-verify.tsv")))
    @test occursin("frozen=True\tsplitCol=1", ver[("odsf-a.ods", "Freeze")]) && occursin("zoom=150", ver[("odsf-a.fods", "Zoom")])
    @test occursin("firstRow=9\tfirstCol=2\tselection=\$Sel.\$C\$3", ver[("odsf-a.ods", "Sel")])
    @test occursin("layout=1", ver[("odsf-a.ods", "RTL")]) && occursin("headers=False\tzeros=False", ver[("odsf-b.ods", "One")])
    @test occursin("frozen=True\tsplitCol=3\tsplitRow=1", ver[("odsf-p.fods", "Plain")]) && occursin("frozen=False", ver[("odsf-p.fods", "Freeze")])
end

@testset "panes and views: XLSX.jl's cases and errors" begin
    xf = newods("S")
    s = xf[1]
    s["A1:F20"] = 1
    freezePanes(s)                                           # row 1 (the default)
    @test getSheetView(s).topLeftCell == CellRef("A2")
    freezePanes(s, "C4")
    @test getSheetView(s).topLeftCell == CellRef("C4") && getSheetView(s).activeCell == CellRef("C4")
    @test_throws ODSError setSheetView(s; topLeftCell = "B2")   # in the frozen part
    setSheetView(s; topLeftCell = "D10")
    @test getSheetView(s).topLeftCell == CellRef("D10")
    splitFreeze(s; nrows = 1, ncols = 1)                     # LibreOffice has no frozen split: frozen
    @test OpenDocumentSpreadsheets._view_items_now(s)[1]["HorizontalSplitMode"] == ("short", "2")
    deletePanes(s)
    items = OpenDocumentSpreadsheets._view_items_now(s)[1]
    @test !haskey(items, "HorizontalSplitMode") && getSheetView(s).topLeftCell == CellRef("A1")
    setSheetView(s; zoom = 80, showGridLines = false, rightToLeft = true)
    v = getSheetView(s)
    @test v.zoom == 80 && !v.showGridLines && v.rightToLeft
    setSheetView(s; activeCell = "E5")
    @test getSheetView(s).selection == "E5"
    setSheetView(s; selection = "B2:C3,F7")
    @test getSheetView(s).activeCell == CellRef("B2")
    @test_throws ODSError setSheetView(s; selection = "B2:C3", activeCell = "D4")
    @test_throws ODSError setSheetView(s; zoom = 10)          # LibreOffice's range: 20 to 600
    @test_throws ODSError setSheetView(s; zoom = 150.5)
    @test_throws ODSError setSheetView(s; view = :pageLayout)
    @test_throws ODSError setSheetView(s; view = :bogus)
    @test_throws ODSError setSheetView(s; showGridLines = 1)
    @test_throws ODSError setSheetView(s; bogus = 1)
    @test_throws ODSError setSheetView(s)
    @test_throws ODSError freezePanes(s; nrows = -1)
    @test_throws ODSError freezePanes(s, "A1:B2")
    @test_throws ODSError freezePanes(readods(joinpath(VIEWS, "lo-views-import.fods"))[1]; nrows = 1)
    # the page-break view, headers and zeros are the whole file's (F-053)
    addsheet!(xf, "T")
    setSheetView(xf["T"]; view = :pageBreakPreview, showZeros = false, showRowColHeaders = false)
    @test getSheetView(s).view === :pageBreakPreview && !getSheetView(s).showZeros && !getSheetView(s).showRowColHeaders
    setSheetView(xf["T"]; zoom = 70)                         # the page-break view's zoom
    @test getSheetView(xf["T"]).zoom == 70
    setSheetView(xf["T"]; view = :normal)
    @test getSheetView(xf["T"]).zoom == 100 && getSheetView(s).zoom == 80
    # gridlines shown under a view without them: the view's are turned on, the other sheets' off
    own = openods(joinpath(VIEWS, "lo-views-own.fods"); mode = "rw")
    setSheetView(own["Plain"]; showGridLines = true)
    @test getSheetView(own["Plain"]).showGridLines && !getSheetView(own["Freeze"]).showGridLines
    # views follow renames and copies, and a new file gets settings.xml
    r = readods(writeods(joinpath(mktempdir(), "v.ods"), xf))
    @test getSheetView(r["S"]).zoom == 80 && getSheetView(r["T"]).view === :normal && getSheetView(r["S"]).rightToLeft
end

@testset "a patched save changes only the view items set (D-023)" begin
    src = joinpath(VIEWS, "lo-views-own.fods")
    orig = read(src, String)
    dir = mktempdir()
    item(n, t, v) = "<config:config-item config:name=\"$n\" config:type=\"$t\">$v</config:config-item>"
    entry(s, o) = match(Regex("<config:config-item-map-entry config:name=\"" * s * "\">.*?</config:config-item-map-entry>", "s"), o).match
    # one item changed: the file is the same but for it (the file is in the page-break view: its zoom)
    xf = openods(src; mode = "rw")
    setSheetView(xf["Zoom"]; zoom = 75)
    out = read(writeods(joinpath(dir, "a.fods"), xf), String)
    ez = entry("Zoom", orig)
    @test out == replace(orig, ez => replace(ez, item("PageViewZoomValue", "int", "60") => item("PageViewZoomValue", "int", "75")))
    # panes on a sheet without them: the items go in LibreOffice's order, the rest is kept
    xf = openods(src; mode = "rw")
    freezePanes(xf["Plain"]; nrows = 1, ncols = 3)
    out = read(writeods(joinpath(dir, "b.fods"), xf), String)
    @test replace(out, entry("Plain", out) => "") == replace(orig, entry("Plain", orig) => "")
    got = view_items(joinpath(dir, "b.fods"), "Plain")
    @test got["HorizontalSplitMode"] == "2" && got["HorizontalSplitPosition"] == "3" && got["VerticalSplitPosition"] == "1" &&
          got["ShowGrid"] == "true" && got["ZoomValue"] == "150"
    # a file whose settings have no views (a headless save): a Views map is added, nothing else changes
    src2 = joinpath(DATA, "visibility", "lo-vis.fods")
    orig2 = read(src2, String)
    xf = openods(src2; mode = "rw")
    freezePanes(xf["S1"])
    out = read(writeods(joinpath(dir, "c.fods"), xf), String)
    setx(o) = match(r"<office:settings>.*?</office:settings>"s, o).match
    @test replace(out, setx(out) => "") == replace(orig2, setx(orig2) => "")
    so = setx(orig2); k = findfirst("</config:config-item-set>", so)          # the Views map after the set's items
    @test startswith(setx(out), so[1:prevind(so, first(k))]) && endswith(setx(out), so[first(k):end])
    @test getSheetView(readods(joinpath(dir, "c.fods"))["S1"]).topLeftCell == CellRef("A2")
    # a zipped file without settings.xml gets one, listed in the manifest
    nf = newods("A"); nf["A"]["A1"] = 1
    xf = openods(writeods(joinpath(dir, "n.ods"), nf); mode = "rw")
    @test !OpenDocumentSpreadsheets.haspart(xf.container, "settings.xml")
    freezePanes(xf["A"])
    p = writeods(joinpath(dir, "n2.ods"), xf)
    c = OpenDocumentSpreadsheets.open_container(p)
    @test OpenDocumentSpreadsheets.haspart(c, "settings.xml") && any(e -> e.path == "settings.xml", c.manifest)
    @test getSheetView(readods(p)["A"]).topLeftCell == CellRef("A2")
    # with sheet operations: an entry follows a rename, a copy gets the source's, inserts move nothing
    xf = openods(src; mode = "rw")
    freezePanes(xf["Plain"]; nrows = 2)
    renamesheet!(xf["Plain"], "Plain 2")
    c = copysheet!(xf["Plain 2"], "Copy")
    insertRows(xf["Plain 2"], 1; count = 3)                   # LibreOffice keeps panes where they are (F-053)
    deletesheet!(xf, "Break")
    p = writeods(joinpath(dir, "o.fods"), xf)
    @test view_items(p, "Plain 2")["VerticalSplitPosition"] == "2" && view_items(p, "Copy")["VerticalSplitPosition"] == "2"
    @test isempty(view_items(p, "Plain")) && isempty(view_items(p, "Break"))
    # an unedited file is unchanged
    @test read(writeods(joinpath(dir, "u.fods"), openods(src; mode = "rw")), String) == orig
end

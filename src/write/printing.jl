# Printing (phase 5 step 10; D-063): page setup, margins, print options, print areas, print titles and
# headers and footers, with XLSX.jl's API and LibreOffice's forms (experiment 026, F-055).
#
# Adapted from XLSX.jl 0.13.4 (src/sheetsettings.jl `setPageSetup`, `getPageSetup`, `setPageMargins`,
# `getPageMargins`, `setPrintOptions`, `getPrintOptions`, `setPrintArea`, `getPrintArea`,
# `removePrintArea`, `setPrintTitles`, `getPrintTitles`, `removePrintTitles`, `setHeaderFooter`,
# `getHeaderFooter`, `removeHeaderFooter`, `headerFooterField`, `headerFooterFont`, `PAPER_SIZES` and
# the header code parsing), MIT License, Copyright (c) 2018-2026 Felipe Noronha Tavares and other
# contributors. Changes: the settings are a sheet's page style (a master page and its page layout, in
# styles.xml) and its table's print ranges and title containers; Excel's header codes are converted
# to and from ODF's fields and text styles, as LibreOffice's xlsx import converts them.
#
# A sheet's page style is copied on write (the plan's choice): its first change gives it a page style
# of its own, `PageStyle_<sheet>` as LibreOffice names the ones its import makes, made from the one it
# had (or LibreOffice's default), and its table style names it (D-059's derived table styles).

const PAPER_SIZES = (letter = 1, tabloid = 3, ledger = 4, legal = 5, executive = 7,
                     A3 = 8, A4 = 9, A5 = 11, B4 = 12, B5 = 13)

# Excel's paper numbers and the sizes (cm, portrait) LibreOffice's import gives them (F-055).
const _EXCEL_PAPER = Dict(1 => (21.59, 27.94), 3 => (27.94, 43.18), 4 => (43.18, 27.94), 5 => (21.59, 35.56),   # ledger: wide, as the import gives it
                          7 => (18.415, 26.67), 8 => (29.7, 42.0), 9 => (21.001, 29.7), 11 => (14.801, 21.001),
                          12 => (25.7, 36.4), 13 => (18.2, 25.7), 70 => (10.5, 14.801))

const _IN = 2.54
const _HF_GAP_CM = 0.423                        # LibreOffice's import: the header's height less its spacing

# LibreOffice's default page style (a new document's `Default`), used for a sheet that names none.
const _LO_DEFAULT_MASTER = "<style:master-page style:name=\"Default\" style:page-layout-name=\"pm1\">" *
    "<style:header><text:p><text:sheet-name>???</text:sheet-name></text:p></style:header>" *
    "<style:header-left style:display=\"false\"/><style:header-first style:display=\"false\"/>" *
    "<style:footer><text:p>Page <text:page-number>1</text:page-number></text:p></style:footer>" *
    "<style:footer-left style:display=\"false\"/><style:footer-first style:display=\"false\"/></style:master-page>"
const _LO_DEFAULT_LAYOUT = "<style:page-layout style:name=\"pm1\"><style:page-layout-properties style:writing-mode=\"lr-tb\"/>" *
    "<style:header-style><style:header-footer-properties fo:min-height=\"0.75cm\" fo:margin-left=\"0cm\" fo:margin-right=\"0cm\" fo:margin-bottom=\"0.25cm\"/></style:header-style>" *
    "<style:footer-style><style:header-footer-properties fo:min-height=\"0.75cm\" fo:margin-left=\"0cm\" fo:margin-right=\"0cm\" fo:margin-top=\"0.25cm\"/></style:footer-style></style:page-layout>"
const _LO_MARGIN_CM = 2.0                       # LibreOffice's page margins when the layout gives none

const _REGION_TAGS = ("style:header", "style:header-left", "style:header-first",
                      "style:footer", "style:footer-left", "style:footer-first")

#
# The styles document
#

# The text that holds a file's page styles: styles.xml, or a flat file's whole document.
function _styles_doc(xf::ODSFile)
    isnewfile(xf) && return ""
    xf.container.format === :fods && return xf.content
    return something(read_xml(xf.container, :styles), "")
end

_attr_pairs(tag::AbstractString) = Pair{String,String}[String(k) => XML.unescape(String(SubString(v, 2, lastindex(v) - 1)))
                                                       for (k, v) in _raw_attrs(tag)]
_get(v::Vector{Pair{String,String}}, k, default = nothing) = (i = findfirst(p -> p.first == k, v); i === nothing ? default : v[i].second)
function _put!(v::Vector{Pair{String,String}}, k, x)
    i = findfirst(p -> p.first == k, v)
    if x === nothing
        i === nothing || deleteat!(v, i)
    else
        i === nothing ? push!(v, k => x) : (v[i] = k => x)
    end
    return v
end

# The element `<tag … name="name"…>…</tag>` in a document, or nothing.
function _named_element(doc::AbstractString, tag::AbstractString, name::AbstractString)
    for m in eachmatch(Regex("<" * tag * "\\b[^>]*?(?:/>|>.*?</" * tag * ">)", "s"), doc)
        st = SubString(m.match, 1, _start_tag_end(m.match))
        _start_tag_attr(st, "style:name") == name && return String(m.match)
    end
    return nothing
end

# The children of an element's text, as (tag => XML) in order.
function _children(x::AbstractString)
    out = Pair{String,String}[]
    endswith(x, "/>") && return out
    c = XML.Cursor(String(x))
    while XML.next!(c) !== nothing
        XML.nodetype(c) === XML.Element && break
    end
    XML.for_each_child!(c) do ch
        XML.nodetype(ch) === XML.Element || return
        ln = XML.LazyNode(ch)
        push!(out, String(XML.tag(ch)) => String(XML.sourcetext(ln)))
        XML.skip_element!(ch)
    end
    return out
end

#
# Reading a sheet's page style
#

_cm_attr(v::Vector{Pair{String,String}}, k, default) = something(_length_cm(_get(v, k)), default)
_shown(regions, tag) = (i = findfirst(p -> p.first == tag, regions); i !== nothing && !occursin("style:display=\"false\"", regions[i].second[1:_start_tag_end(regions[i].second)]))

function _print_state(ws::Worksheet)
    ws.print === nothing || return ws.print
    xf = get_odsfile(ws)
    doc = _styles_doc(xf)
    mname = something(_sheet_props(ws).master, "Default")
    mx = haskey(xf.pageedits.pages, mname) ? xf.pageedits.pages[mname][1] : _named_element(doc, "style:master-page", mname)
    mx === nothing && (mx = _LO_DEFAULT_MASTER)
    mtag = _attr_pairs(SubString(mx, 1, _start_tag_end(mx)))
    lname = _get(mtag, "style:page-layout-name", "")
    lx = haskey(xf.pageedits.pages, mname) ? xf.pageedits.pages[mname][2] : _named_element(doc, "style:page-layout", lname)
    lx === nothing && (lx = _LO_DEFAULT_LAYOUT)
    regions = _children(mx)
    lattrs = filter(p -> p.first != "style:name", _attr_pairs(SubString(lx, 1, _start_tag_end(lx))))
    lprops = Pair{String,String}[]; linner = ""; hprops = Pair{String,String}[]; fprops = Pair{String,String}[]
    for (tag, x) in _children(lx)
        if tag == "style:page-layout-properties"
            lprops = _attr_pairs(SubString(x, 1, _start_tag_end(x)))
            linner = endswith(x, "/>") ? "" : x[nextind(x, _start_tag_end(x)):prevind(x, first(findlast("</", x)))]
        elseif tag in ("style:header-style", "style:footer-style")
            m = match(r"<style:header-footer-properties\b[^>]*>", x)
            pr = m === nothing ? Pair{String,String}[] : _attr_pairs(m.match)
            tag == "style:header-style" ? (hprops = pr) : (fprops = pr)
        end
    end
    # Excel's margins, as LibreOffice's import maps them (F-055): with a header shown, the page's top
    # margin is the header's distance and the header's height the rest of Excel's top margin
    L = _cm_attr(lprops, "fo:margin-left", _LO_MARGIN_CM); R = _cm_attr(lprops, "fo:margin-right", _LO_MARGIN_CM)
    T = _cm_attr(lprops, "fo:margin-top", _LO_MARGIN_CM); B = _cm_attr(lprops, "fo:margin-bottom", _LO_MARGIN_CM)
    H = 0.3 * _IN; F = 0.3 * _IN
    if _shown(regions, "style:header")
        H = T; T += _cm_attr(hprops, "fo:min-height", 0.0)
    end
    if _shown(regions, "style:footer")
        F = B; B += _cm_attr(fprops, "fo:min-height", 0.0)
    end
    keep = filter(p -> !(p.first in ("style:name", "style:display-name", "style:page-layout-name")), mtag)
    ws.print = PrintState(mname, keep, regions, lattrs, lprops, linner, hprops, fprops,
                          [L, R, T, B, H, F] ./ _IN, false, false, _print_area_now(ws), false)
    return ws.print
end

function _print_area_now(ws::Worksheet)
    ws.entry === nothing && return nothing
    v = get(ws.entry.node, "table:print-ranges", nothing)     # the start tag only
    return v === nothing ? nothing : String(v)
end

#
# Writing a sheet's page style
#

_cm_text(x::Real) = _length_text(round(Float64(x); digits = 3))

# LibreOffice's margins from Excel's (F-055).
function _apply_margins!(p::PrintState)
    L, R, T, B, H, F = p.margins .* _IN
    _put!(p.lprops, "fo:margin-left", _cm_text(L)); _put!(p.lprops, "fo:margin-right", _cm_text(R))
    if _shown(p.regions, "style:header")
        _put!(p.lprops, "fo:margin-top", _cm_text(H))
        _put!(p.hprops, "fo:min-height", _cm_text(max(0.0, T - H)))
        _put!(p.hprops, "fo:margin-bottom", _cm_text(max(0.0, T - H - _HF_GAP_CM)))
    else
        _put!(p.lprops, "fo:margin-top", _cm_text(T))
    end
    if _shown(p.regions, "style:footer")
        _put!(p.lprops, "fo:margin-bottom", _cm_text(F))
        _put!(p.fprops, "fo:min-height", _cm_text(max(0.0, B - F)))
        _put!(p.fprops, "fo:margin-top", _cm_text(max(0.0, B - F - _HF_GAP_CM)))
    else
        _put!(p.lprops, "fo:margin-bottom", _cm_text(B))
    end
    return
end

_attrs_xml(v) = join(" " * k * "=\"" * _escape_attr(x) * "\"" for (k, x) in v)

# A page style of the sheet's own: named on its first change, written into the registry on each.
function _page_changed!(ws::Worksheet)
    xf = get_odsfile(ws)
    p = _print_state(ws)
    p.margins_changed && _apply_margins!(p)
    if !p.page_changed
        doc = _styles_doc(xf)
        k = 1
        name(k) = "PageStyle_odsf$k"
        while haskey(xf.pageedits.pages, name(k)) || occursin("style:name=\"$(name(k))\"", doc)
            k += 1
        end
        p.master = name(k)
        p.page_changed = true
    end
    lname = "pm_" * p.master
    master = "<style:master-page style:name=\"" * p.master * "\" style:display-name=\"" * _escape_attr("PageStyle_" * ws.name) *
             "\" style:page-layout-name=\"" * lname * "\"" * _attrs_xml(p.mattrs) * ">" * join(last.(p.regions)) * "</style:master-page>"
    layout = "<style:page-layout style:name=\"" * lname * "\"" * _attrs_xml(p.lattrs) * ">" *
             "<style:page-layout-properties" * _attrs_xml(p.lprops) * (isempty(p.linner) ? "/>" : ">" * p.linner * "</style:page-layout-properties>") *
             "<style:header-style><style:header-footer-properties" * _attrs_xml(p.hprops) * "/></style:header-style>" *
             "<style:footer-style><style:header-footer-properties" * _attrs_xml(p.fprops) * "/></style:footer-style></style:page-layout>"
    xf.pageedits.pages[p.master] = (master, layout)
    sp = _sheet_props(ws)
    sp.master == p.master || _restyle_table!(ws, sp.display, sp.tabcolor; master = p.master)
    return
end

# The page styles and text styles to write: those a sheet names now.
function _page_styles_xml(xf::ODSFile)
    isempty(xf.pageedits.pages) && return "", ""
    used = Set{String}()
    for ws in xf.sheets
        p = ws.props
        m = p === nothing ? (ws.entry === nothing ? nothing : _table_style_master(_table_style_xml(xf, something(_table_style_name(ws), "")))) : p.master
        m === nothing || push!(used, m)
    end
    masters = IOBuffer(); autos = IOBuffer()
    for (n, (m, l)) in sort!(collect(xf.pageedits.pages); by = first)
        n in used || continue
        print(masters, m); print(autos, l)
    end
    foreach(t -> print(autos, t.second), xf.pageedits.text)
    return String(take!(autos)), String(take!(masters))
end

_pages_edited(xf::ODSFile) = !isempty(xf.pageedits.pages)

#
# Page setup
#

"""
    setPageSetup(sheet; orientation, paperSize, scale, fitToWidth, fitToHeight)

Set how a sheet is printed, as LibreOffice keeps it in the sheet's page style. Only the
keywords given change.
- `orientation`: `:portrait` or `:landscape` (the page's width and height swap)
- `paperSize`: one of $(join((":$k" for k in keys(PAPER_SIZES)), ", ")), or a paper's number
  (`70` is A6); the page gets that paper's size
- `scale`: a percentage, 10 to 400
- `fitToWidth`, `fitToHeight`: the pages to fit the sheet on, across and down (0: as many as
  needed). `scale` and fitting are alternatives: giving one turns the other off.

Also:
- `paperWidth`, `paperHeight`: any paper size, in `unit`s (`:cm`, the default, `:mm`, `:in` or
  `:pt`), instead of `paperSize`. Without `orientation`, the page is landscape when it is wider
  than high, as LibreOffice's page dialog makes it; with it, the two are swapped to suit.
- `scaleToPages`: fit the sheet on this many pages in all (`style:scale-to-pages`), a third
  alternative to `scale` and fitting.

A sheet gets a page style of its own on its first change (`PageStyle_<sheet>`), made from the one
it had.
"""
function setPageSetup(ws::Worksheet; orientation::Union{Nothing,Symbol} = nothing, paperSize::Union{Nothing,Symbol,Integer} = nothing,
                      scale::Union{Nothing,Integer} = nothing, fitToWidth::Union{Nothing,Integer} = nothing,
                      fitToHeight::Union{Nothing,Integer} = nothing, paperWidth::Union{Nothing,Real} = nothing,
                      paperHeight::Union{Nothing,Real} = nothing, unit::Symbol = :cm, scaleToPages::Union{Nothing,Integer} = nothing)
    _require_writable(ws, "set up the page")
    haskey(_CM_PER, unit) || throw(ODSError("Invalid unit `:$unit`: give :cm, :mm, :in or :pt."))
    custom = paperWidth !== nothing || paperHeight !== nothing
    custom && paperSize !== nothing && throw(ODSError("Give `paperSize` or `paperWidth`/`paperHeight`, not both."))
    for (k, v) in (("paperWidth", paperWidth), ("paperHeight", paperHeight))
        v === nothing || (isfinite(v) && v > 0) || throw(ODSError("`$k` must be a positive length. Found `$v`."))
    end
    fit = fitToWidth !== nothing || fitToHeight !== nothing
    if scaleToPages !== nothing
        (fit || scale !== nothing) && throw(ODSError("Give one of `scale`, `fitToWidth`/`fitToHeight` and `scaleToPages`: LibreOffice uses one of them."))
        1 <= scaleToPages <= 1000 || throw(ODSError("Invalid `scaleToPages` $scaleToPages. Must be from 1 to 1000."))
    end
    orientation === nothing || orientation in (:portrait, :landscape) ||
        throw(ODSError("Invalid `orientation` `:$orientation`. Must be `:portrait` or `:landscape`."))
    size = nothing
    if paperSize !== nothing
        n = paperSize isa Symbol ? (haskey(PAPER_SIZES, paperSize) ? PAPER_SIZES[paperSize] :
             throw(ODSError("Unknown `paperSize` `:$paperSize`. Must be one of $(join(keys(PAPER_SIZES), ", ")), or Excel's number for the size."))) : Int(paperSize)
        haskey(_EXCEL_PAPER, n) || throw(ODSError("Excel's paper size $n has no size in OpenDocumentSpreadsheets: give one of $(join(sort!(collect(keys(_EXCEL_PAPER))), ", "))."))
        size = _EXCEL_PAPER[n]
    end
    if scale !== nothing
        fit && throw(ODSError("Give `scale` or `fitToWidth`/`fitToHeight`, not both: LibreOffice uses one or the other."))
        10 <= scale <= 400 || throw(ODSError("Invalid `scale` $scale. Must be from 10 to 400 (percent)."))
    end
    for (k, v) in (("fitToWidth", fitToWidth), ("fitToHeight", fitToHeight))
        v === nothing || 0 <= v <= 32767 || throw(ODSError("Invalid `$k` $v. Must be from 0 (as many pages as needed) to 32767."))
    end
    p = _print_state(ws)
    land = something(orientation, Symbol(_get(p.lprops, "style:print-orientation", "portrait"))) === :landscape
    if custom
        w = paperWidth === nothing ? something(_length_cm(_get(p.lprops, "fo:page-width")), _EXCEL_PAPER[1][1]) : paperWidth * _CM_PER[unit]
        h = paperHeight === nothing ? something(_length_cm(_get(p.lprops, "fo:page-height")), _EXCEL_PAPER[1][2]) : paperHeight * _CM_PER[unit]
        if orientation === nothing
            land = w > h
        elseif land != (w > h) && w != h
            (w, h) = (h, w)
        end
        _put!(p.lprops, "fo:page-width", _cm_text(w)); _put!(p.lprops, "fo:page-height", _cm_text(h))
        _put!(p.lprops, "style:print-orientation", land ? "landscape" : "portrait")
    elseif orientation !== nothing || size !== nothing
        w, h = something(size, Some(nothing)) === nothing ?
            (something(_length_cm(_get(p.lprops, "fo:page-width")), _EXCEL_PAPER[1][1]),
             something(_length_cm(_get(p.lprops, "fo:page-height")), _EXCEL_PAPER[1][2])) : size
        # the size as given is portrait; a page read from the file is as it is
        size === nothing && (w > h) && ((w, h) = (h, w))
        land && ((w, h) = (h, w))
        _put!(p.lprops, "fo:page-width", _cm_text(w)); _put!(p.lprops, "fo:page-height", _cm_text(h))
        _put!(p.lprops, "style:print-orientation", land ? "landscape" : "portrait")
    end
    if scale !== nothing
        _put!(p.lprops, "style:scale-to", string(scale, "%"))
        _put!(p.lprops, "style:scale-to-X", nothing); _put!(p.lprops, "style:scale-to-Y", nothing); _put!(p.lprops, "style:scale-to-pages", nothing)
    elseif fit
        _put!(p.lprops, "style:scale-to", nothing); _put!(p.lprops, "style:scale-to-pages", nothing)
        _put!(p.lprops, "style:scale-to-X", something(fitToWidth, 0) == 0 ? nothing : string(fitToWidth))
        _put!(p.lprops, "style:scale-to-Y", something(fitToHeight, 0) == 0 ? nothing : string(fitToHeight))
    elseif scaleToPages !== nothing
        _put!(p.lprops, "style:scale-to", nothing); _put!(p.lprops, "style:scale-to-X", nothing); _put!(p.lprops, "style:scale-to-Y", nothing)
        _put!(p.lprops, "style:scale-to-pages", string(scaleToPages))
    end
    _page_changed!(ws)
    return nothing
end

"""
    getPageSetup(sheet; unit=:cm) -> NamedTuple

`(orientation, paperSize, scale, fitToWidth, fitToHeight, paperWidth, paperHeight, scaleToPages)`,
each `nothing` where the page style doesn't say. `paperSize` is the paper's number (9 for A4,
1 for letter, …) when the page's size is one of [`setPageSetup`](@ref)'s papers; `scale` is given
only when it isn't 100% and the sheet isn't fitted to pages; `paperWidth` and `paperHeight` are
the page's size as it is printed (turned when landscape), in `unit`s; `scaleToPages` is the number
of pages to fit the sheet on in all.
Works on read-only files.
"""
function getPageSetup(ws::Worksheet; unit::Symbol = :cm)
    haskey(_CM_PER, unit) || throw(ODSError("Invalid unit `:$unit`: give :cm, :mm, :in or :pt."))
    p = _print_state(ws)
    o = _get(p.lprops, "style:print-orientation")
    w = _length_cm(_get(p.lprops, "fo:page-width")); h = _length_cm(_get(p.lprops, "fo:page-height"))
    paper = nothing
    if w !== nothing && h !== nothing
        # the size as it is first (ledger is tabloid turned), then turned
        near(pw, ph, x, y) = abs(pw - x) < 0.05 && abs(ph - y) < 0.05
        ns = sort!(collect(keys(_EXCEL_PAPER)))
        i = findfirst(n -> near(_EXCEL_PAPER[n]..., w, h), ns)
        i === nothing && (i = findfirst(n -> near(_EXCEL_PAPER[n]..., h, w), ns))
        i === nothing || (paper = ns[i])
    end
    x = _get(p.lprops, "style:scale-to-X"); y = _get(p.lprops, "style:scale-to-Y")
    pages = _get(p.lprops, "style:scale-to-pages")
    fit = x !== nothing || y !== nothing
    s = _get(p.lprops, "style:scale-to")
    sc = (fit || pages !== nothing || s === nothing) ? nothing : round(Int, something(tryparse(Float64, rstrip(s, '%')), 100.0))
    len(v) = v === nothing ? nothing : round(v / _CM_PER[unit]; digits = 4)
    return (orientation = o === nothing ? nothing : Symbol(o), paperSize = paper, scale = sc == 100 ? nothing : sc,
            fitToWidth = fit ? something(tryparse(Int, something(x, "0")), 0) : nothing,
            fitToHeight = fit ? something(tryparse(Int, something(y, "0")), 0) : nothing,
            paperWidth = len(w), paperHeight = len(h),
            scaleToPages = pages === nothing ? nothing : tryparse(Int64, pages))
end

#
# Margins
#

const _PAGE_MARGINS = (left = 0.7, right = 0.7, top = 0.75, bottom = 0.75, header = 0.3, footer = 0.3)

"""
    setPageMargins(sheet; left, right, top, bottom, header, footer)

Set the printed margins, in inches, each measured from the edge of the page: `top` and `bottom`
to the sheet's cells, `header` and `footer` to the header and footer. Only the keywords given
change.

LibreOffice's page style measures the top from the edge to the header, which has a height of its
own, so the margins are converted: with a header shown, the page style's top margin is `header`, and
the header's height the rest of `top` (less 1/6 inch of spacing). The bottom is converted in the
same way.
"""
function setPageMargins(ws::Worksheet; kw...)
    _require_writable(ws, "set page margins")
    for (k, v) in kw
        haskey(_PAGE_MARGINS, k) || throw(ODSError("Unknown keyword `$k`. Must be one of $(join(keys(_PAGE_MARGINS), ", "))."))
        (v isa Real && isfinite(v) && v >= 0) || throw(ODSError("`$k` must be a number of inches, 0 or more. Found `$(repr(v))`."))
    end
    p = _print_state(ws)
    for (i, k) in enumerate(keys(_PAGE_MARGINS))
        haskey(kw, k) && (p.margins[i] = Float64(kw[k]))
    end
    p.margins_changed = true
    _page_changed!(ws)
    return nothing
end

"""
    getPageMargins(sheet) -> NamedTuple

The printed margins in inches, `(left, right, top, bottom, header, footer)`, measured as
[`setPageMargins`](@ref) takes them. Where the page style gives none, LibreOffice's 2 cm. Works on read-only
files.
"""
getPageMargins(ws::Worksheet) = NamedTuple{keys(_PAGE_MARGINS)}(Tuple(round.(_print_state(ws).margins; digits = 4)))

#
# Print options
#

# XLSX.jl's, then LibreOffice's own (D-076): the `style:print` tokens Excel has no option for.
const _LO_PRINT_TOKENS = (comments = "annotations", formulas = "formulas", zeroValues = "zero-values",
                          charts = "charts", drawings = "drawings", objects = "objects")
const _PRINT_OPTIONS = (:gridLines, :headings, :horizontalCentered, :verticalCentered, keys(_LO_PRINT_TOKENS)...)
const _LO_PRINT_DEFAULT = "charts drawings objects zero-values"

"""
    setPrintOptions(sheet; gridLines, headings, horizontalCentered, verticalCentered,
                    comments, formulas, zeroValues, charts, drawings, objects)

Choose what is printed with a sheet, as LibreOffice keeps it in the page style: `gridLines` and
`headings` (row and column headers) join `style:print`, the centring is `style:table-centering`.
Each keyword is a `Bool`; only those given change.

The rest are the other settings of the page style's *Sheet* tab in LibreOffice:
`comments`, `formulas` (formulas instead of their results), `zeroValues`, `charts`, `drawings`
(drawing objects) and `objects` (pictures and other objects). LibreOffice prints charts, drawings,
objects and zero values unless told not to.
"""
function setPrintOptions(ws::Worksheet; kw...)
    _require_writable(ws, "set print options")
    for (k, v) in kw
        k in _PRINT_OPTIONS || throw(ODSError("Unknown keyword `$k`. Must be one of $(join(_PRINT_OPTIONS, ", "))."))
        v isa Bool || throw(ODSError("`$k` must be `true` or `false`. Found `$(repr(v))`."))
    end
    p = _print_state(ws)
    toks = Set(split(_get(p.lprops, "style:print", _LO_PRINT_DEFAULT)))
    for (k, tok) in ((:gridLines, "grid"), (:headings, "headers"), pairs(_LO_PRINT_TOKENS)...)
        haskey(kw, k) && (kw[k] ? push!(toks, tok) : delete!(toks, tok))
    end
    _put!(p.lprops, "style:print", join(sort!(collect(toks)), ' '))
    if haskey(kw, :horizontalCentered) || haskey(kw, :verticalCentered)
        c = _get(p.lprops, "style:table-centering", "none")
        h = get(kw, :horizontalCentered, c in ("horizontal", "both"))
        v = get(kw, :verticalCentered, c in ("vertical", "both"))
        _put!(p.lprops, "style:table-centering", h && v ? "both" : h ? "horizontal" : v ? "vertical" : nothing)
    end
    _page_changed!(ws)
    return nothing
end

"""
    getPrintOptions(sheet) -> NamedTuple

`(gridLines, headings, horizontalCentered, verticalCentered, comments, formulas, zeroValues, charts,
drawings, objects)`, `Bool`s (the last six LibreOffice's, see [`setPrintOptions`](@ref)). Works on
read-only files.
"""
function getPrintOptions(ws::Worksheet)
    p = _print_state(ws)
    toks = split(_get(p.lprops, "style:print", _LO_PRINT_DEFAULT))
    c = _get(p.lprops, "style:table-centering", "none")
    return (gridLines = "grid" in toks, headings = "headers" in toks,
            horizontalCentered = c in ("horizontal", "both"), verticalCentered = c in ("vertical", "both")) |>
        x -> merge(x, NamedTuple{keys(_LO_PRINT_TOKENS)}(Tuple(t in toks for t in values(_LO_PRINT_TOKENS))))
end

#
# Print areas
#

_odf_print_area(sheet, x::CellRef) = (q = SheetCore.quoteit(sheet); q * "." * string(x) * ":" * q * "." * string(x))
_odf_print_area(sheet, x::CellRange) = (q = SheetCore.quoteit(sheet); q * "." * string(x.start) * ":" * q * "." * string(x.stop))

"""
    setPrintArea(sheet, rng)

Print only the cells in `rng`: a cell range (`"A1:F40"`), several separated by commas or `~`
(`"A1:F40,H1:K10"`), or a defined name. Stored as LibreOffice stores it, in the table's
`table:print-ranges` (`Sheet1.A1:Sheet1.F40`). Replaces any print area the sheet has.
"""
function setPrintArea(ws::Worksheet, rng::Union{AbstractString,CellRange})
    _require_writable(ws, "set a print area")
    parts = rng isa CellRange ? Any[rng] : Any[]
    if rng isa AbstractString
        dn = something(_find_name(_local_names(ws), rng), _find_name(_wb_names(get_odsfile(ws)), rng), Some(nothing))
        if dn !== nothing
            v = get_defined_name_value(dn)
            for r in (v isa NonContiguousRange ? v.rng : [v])
                push!(parts, r isa SheetCellRef ? r.cellref : r isa SheetCellRange ? r.rng : r)
            end
        else
            for it in SheetCore._split_unquoted(String(rng), (',', '~'))
                q = replace(strip(it), "\$" => "")
                is_valid_cellname(q) ? push!(parts, CellRef(q)) : is_valid_cellrange(q) ? push!(parts, CellRange(q)) :
                    throw(ODSError("A print area is made of cells, such as `A1:F40`. Found `$it`."))
            end
        end
    end
    for x in parts
        x isa Union{CellRef,CellRange} || throw(ODSError("A print area is made of cells, such as `A1:F40`. Found `$x`."))
    end
    p = _print_state(ws)
    p.area = join((_odf_print_area(ws.name, x) for x in parts), ' ')
    p.area_changed = true
    return nothing
end

"""
    getPrintArea(sheet) -> Union{Nothing, CellRange, NonContiguousRange, String}

The print area: a `CellRange`, a `NonContiguousRange` of several, `nothing` if none, or its text
when it isn't cells of the sheet. Works on read-only files.
"""
function getPrintArea(ws::Worksheet)
    a = _print_state(ws).area
    (a === nothing || isempty(a)) && return nothing
    rngs = CellRange[]
    for (x, y) in _areas(String(a))
        ends = parse_ref(SubString(a, x, y))
        (ends === nothing || any(e -> e.err || e.col == 0 || e.row == 0, ends)) && return String(a)
        c1 = CellRef(ends[1].row, ends[1].col); c2 = CellRef(ends[end].row, ends[end].col)
        push!(rngs, CellRange(c1, c2))
    end
    length(rngs) == 1 && return rngs[1]
    return NonContiguousRange(ws.name, Union{CellRef,CellRange}[r for r in rngs])
end

"""
    removePrintArea(sheet) -> Bool

Print the whole sheet again. `false` if it had no print area.
"""
function removePrintArea(ws::Worksheet)
    _require_writable(ws, "remove a print area")
    p = _print_state(ws)
    (p.area === nothing || isempty(p.area)) && return false
    p.area = nothing; p.area_changed = true
    return true
end

_area_changed(ws::Worksheet) = ws.print !== nothing && ws.print.area_changed

#
# Print titles: the table's header rows and columns (F-055), rebuilt as the groups are (groups.jl)
#

"""
    setPrintTitles(sheet; rows=nothing, cols=nothing)

Repeat rows at the top of every printed page, and columns at the left. `rows` is a row number, a
range (`1:2`) or a string (`"1:2"`); `cols` a column number, a range or a string (`"A:B"`). They
are the table's `table:table-header-rows` and `-columns`, as LibreOffice stores them. They replace
any titles the sheet has; the one not given is kept.
"""
function setPrintTitles(ws::Worksheet; rows = nothing, cols = nothing)
    _require_writable(ws, "set print titles")
    rows === nothing && cols === nothing &&
        throw(ODSError("Give the rows or columns to repeat as `rows`, `cols` or both. To remove the titles, use `removePrintTitles`."))
    f = sheet_formats(ws)
    for (axis, x) in ((1, rows), (2, cols))
        x === nothing && continue
        spans = _hidden_lines(ws, axis, x)
        length(spans) == 1 || throw(ODSError("Print titles must be adjacent $(axis == 1 ? "rows" : "columns"). Found $(join(spans, ", "))."))
        axis == 1 ? (f.title_rows = only(spans)) : (f.title_cols = only(spans))
    end
    f.groups_touched = true
    return nothing
end

"""
    getPrintTitles(sheet) -> Union{Nothing, NamedTuple}

`(rows, cols)`, each a range or `nothing`; `nothing` if the sheet has no titles. Works on
read-only files.
"""
function getPrintTitles(ws::Worksheet)
    f = sheet_formats(ws)
    (f.title_rows === nothing && f.title_cols === nothing) && return nothing
    return (rows = f.title_rows, cols = f.title_cols)
end

"""
    removePrintTitles(sheet) -> Bool

Stop repeating rows and columns. `false` if the sheet had no titles.
"""
function removePrintTitles(ws::Worksheet)
    _require_writable(ws, "remove print titles")
    f = sheet_formats(ws)
    (f.title_rows === nothing && f.title_cols === nothing) && return false
    f.title_rows = nothing; f.title_cols = nothing; f.groups_touched = true
    return true
end

#
# Headers and footers: Excel's codes ↔ ODF's fields and text styles (F-055)
#

const _HEADER_FOOTER_PARTS = (header = "style:header", footer = "style:footer", evenHeader = "style:header-left",
                              evenFooter = "style:footer-left", firstHeader = "style:header-first", firstFooter = "style:footer-first")
const _HEADER_FOOTER_FLAGS = (differentOddEven = false, differentFirst = false, scaleWithDoc = true, alignWithMargins = true)
const _HEADER_FOOTER_SECTIONS = (left = 'L', center = 'C', right = 'R')
const _HEADER_FOOTER_FIELDS = (page = "&P", pages = "&N", date = "&D", time = "&T", file = "&F", path = "&Z", sheet = "&A")
const _HEADER_FOOTER_MAX = 255

"""
    headerFooterField(field::Symbol) -> String

The code for `field` in a header or footer: `:page` `&P`, `:pages` `&N`, `:date` `&D`, `:time`
`&T`, `:file` `&F`, `:path` `&Z`, `:sheet` `&A`. Each is written as the field LibreOffice's
Header/Footer dialog inserts for it.
"""
function headerFooterField(field::Symbol)
    haskey(_HEADER_FOOTER_FIELDS, field) ||
        throw(ODSError("Unknown header or footer field `:$field`. Must be one of $(join((":$k" for k in keys(_HEADER_FOOTER_FIELDS)), ", "))."))
    return _HEADER_FOOTER_FIELDS[field]
end

"""
    headerFooterFont(; name, bold, italic, under, strike, size, color, vertAlign) -> String

The codes that change the font of the text that follows them in a header or footer
(`&"Arial,Bold"&14`). OpenDocumentSpreadsheets writes the text after them in a text style with that
font. `color` takes OpenDocumentSpreadsheets' colour forms (not theme colours).
"""
function headerFooterFont(; name::Union{Nothing,AbstractString} = nothing, bold::Bool = false, italic::Bool = false,
                          under::Union{Nothing,AbstractString} = nothing, strike::Bool = false,
                          size::Union{Nothing,Integer} = nothing, color = nothing, vertAlign::Union{Nothing,AbstractString} = nothing)
    io = IOBuffer()
    if name !== nothing || bold || italic
        name === nothing || (!isempty(name) && !any(in(",\""), name)) ||
            throw(ODSError("Invalid font name `$(repr(name))`: a header's font name can't be empty or contain a comma or a quote."))
        style = bold && italic ? "Bold Italic" : bold ? "Bold" : italic ? "Italic" : "Regular"
        print(io, "&\"", something(name, "-"), ',', style, '"')
    end
    if size !== nothing
        1 <= size <= 409 || throw(ODSError("Invalid font `size` $size. Must be from 1 to 409."))
        print(io, '&', size)
    end
    if under !== nothing
        under in ("single", "double", "none") || throw(ODSError("Invalid `under` `$(repr(under))`. Must be \"single\", \"double\" or \"none\"."))
        under == "none" || print(io, under == "single" ? "&U" : "&E")
    end
    strike && print(io, "&S")
    if vertAlign !== nothing
        vertAlign in ("superscript", "subscript", "baseline") ||
            throw(ODSError("Invalid `vertAlign` `$(repr(vertAlign))`. Must be \"superscript\", \"subscript\" or \"baseline\"."))
        vertAlign == "baseline" || print(io, vertAlign == "superscript" ? "&X" : "&Y")
    end
    color === nothing || print(io, "&K", SheetCore.get_color(color)[3:end])
    return String(take!(io))
end

# The font state while reading Excel's codes, and an ODF text style's.
mutable struct _HFFont
    name::Union{Nothing,String}; bold::Bool; italic::Bool; size::Union{Nothing,Int}; color::Union{Nothing,String}
    under::Symbol; strike::Bool; pos::Symbol      # under :none/:single/:double; pos :none/:super/:sub
end
_HFFont() = _HFFont(nothing, false, false, nothing, nothing, :none, false, :none)
_copyfont(f::_HFFont) = _HFFont(f.name, f.bold, f.italic, f.size, f.color, f.under, f.strike, f.pos)
_isplain(f::_HFFont) = f.name === nothing && !f.bold && !f.italic && f.size === nothing && f.color === nothing &&
                        f.under === :none && !f.strike && f.pos === :none
_samefont(a::_HFFont, b::_HFFont) = a.name == b.name && a.bold == b.bold && a.italic == b.italic && a.size == b.size &&
    a.color == b.color && a.under == b.under && a.strike == b.strike && a.pos == b.pos

function _font_props_xml(f::_HFFont)
    io = IOBuffer()
    f.name === nothing || (print(io, " fo:font-family=\""); _escape_attr(io, f.name); print(io, '"'))
    f.bold && print(io, " fo:font-weight=\"bold\"")
    f.italic && print(io, " fo:font-style=\"italic\"")
    f.size === nothing || print(io, " fo:font-size=\"", f.size, "pt\"")
    f.color === nothing || print(io, " fo:color=\"#", lowercase(f.color), '"')
    f.under === :none || print(io, " style:text-underline-style=\"solid\" style:text-underline-width=\"auto\" style:text-underline-color=\"font-color\"",
                               f.under === :double ? " style:text-underline-type=\"double\"" : "")
    f.strike && print(io, " style:text-line-through-style=\"solid\" style:text-line-through-type=\"single\"")
    f.pos === :none || print(io, " style:text-position=\"", f.pos === :super ? "super" : "sub", " 58%\"")
    return String(take!(io))
end

# The text style for a font: an existing one with the same properties, or a new one.
function _font_style!(xf::ODSFile, f::_HFFont)
    props = _font_props_xml(f)
    for (n, x) in xf.pageedits.text
        occursin("<style:text-properties" * props * "/>", x) && return n
    end
    doc = _styles_doc(xf)
    k = length(xf.pageedits.text) + 1
    while occursin("style:name=\"T_odsf$k\"", doc)
        k += 1
    end
    n = "T_odsf$k"
    push!(xf.pageedits.text, n => "<style:style style:name=\"$n\" style:family=\"text\"><style:text-properties$props/></style:style>")
    return n
end

const _FIELD_XML = Dict('P' => "<text:page-number>1</text:page-number>", 'N' => "<text:page-count>99</text:page-count>",
                        'D' => "<text:date>00/00/0000</text:date>", 'T' => "<text:time>00:00:00</text:time>",
                        'F' => "<text:file-name text:display=\"name-and-extension\">???</text:file-name>",
                        'Z' => "<text:file-name text:display=\"path\">???</text:file-name>",
                        'A' => "<text:sheet-name>???</text:sheet-name>",
                        'Q' => "<text:file-name text:display=\"full\">???</text:file-name>")   # Q: &Z&F, the whole path

# Text with its spaces as ODF keeps them: a run of several, or one at the start or end of a
# paragraph, as <text:s/>.
function _odf_text(io::IO, s::AbstractString, atstart::Bool, atend::Bool)
    i = firstindex(s)
    while i <= lastindex(s)
        c = s[i]
        if c == ' '
            j = i
            while j <= lastindex(s) && s[j] == ' '
                j = nextind(s, j)
            end
            n = length(SubString(s, i, prevind(s, j)))
            if n == 1 && !(atstart && i == firstindex(s)) && !(atend && j > lastindex(s))
                print(io, ' ')
            else
                print(io, n == 1 ? "<text:s/>" : "<text:s text:c=\"$n\"/>")
            end
            i = j
        else
            _escape_text(io, string(c))
            i = nextind(s, i)
        end
    end
end

# One section's codes as ODF paragraphs (`\n` starts a new one).
function _section_xml(xf::ODSFile, text::AbstractString)
    io = IOBuffer()
    font = _HFFont()
    runs = Tuple{_HFFont,Union{String,Char}}[]          # (font, text or field)
    flush_para() = begin
        print(io, "<text:p>")
        k = 1
        while k <= length(runs)
            f = runs[k][1]
            j = k
            while j < length(runs) && _samefont(runs[j+1][1], f)
                j += 1
            end
            _isplain(f) || print(io, "<text:span text:style-name=\"", _font_style!(xf, f), "\">")
            for m in k:j
                x = runs[m][2]
                x isa Char ? print(io, _FIELD_XML[x]) : _odf_text(io, x, m == 1, m == length(runs))
            end
            _isplain(f) || print(io, "</text:span>")
            k = j + 1
        end
        print(io, "</text:p>")
        empty!(runs)
    end
    buf = IOBuffer()
    pushtext() = (s = String(take!(buf)); isempty(s) || push!(runs, (_copyfont(font), s)))
    i = firstindex(text)
    while i <= lastindex(text)
        c = text[i]
        j = nextind(text, i)
        if c == '\n'
            pushtext(); flush_para(); i = j; continue
        end
        if c != '&' || j > lastindex(text)
            print(buf, c); i = j; continue
        end
        d = text[j]
        k = nextind(text, j)
        if d == '&'
            print(buf, '&')
        elseif haskey(_FIELD_XML, d)
            pushtext()
            if d == 'Z' && k <= lastindex(text) && text[k] == '&' && nextind(text, k) <= lastindex(text) && text[nextind(text, k)] == 'F'
                push!(runs, (_copyfont(font), 'Q'))           # &Z&F: the whole path, as LibreOffice's import makes it
                k = nextind(text, nextind(text, k))
            else
                push!(runs, (_copyfont(font), d))
            end
        elseif d == '"'
            pushtext()
            e = something(findnext('"', text, k), lastindex(text) + 1)
            spec = SubString(text, k, prevind(text, e))
            nm, st = occursin(',', spec) ? split(spec, ','; limit = 2) : (spec, "Regular")
            nm == "-" || (font.name = String(nm))
            st = lowercase(st)
            font.bold = occursin("bold", st); font.italic = occursin("italic", st)
            k = nextind(text, e)
        elseif isdigit(d)
            pushtext()
            e = j
            while e <= lastindex(text) && isdigit(text[e])
                e = nextind(text, e)
            end
            font.size = parse(Int, SubString(text, j, prevind(text, e)))
            k = e
        elseif d == 'K'
            pushtext()
            hex = SubString(text, k, min(lastindex(text), prevind(text, k + 6)))
            if occursin(r"^[0-9A-Fa-f]{6}$", hex)
                font.color = uppercase(hex)
                k = k + 6
            else
                k = min(lastindex(text) + 1, k + 6)          # a theme colour: Excel's, not kept
            end
        elseif d in ('U', 'E')
            pushtext(); font.under = font.under === :none ? (d == 'U' ? :single : :double) : :none
        elseif d == 'S'
            pushtext(); font.strike = !font.strike
        elseif d == 'X'
            pushtext(); font.pos = font.pos === :super ? :none : :super
        elseif d == 'Y'
            pushtext(); font.pos = font.pos === :sub ? :none : :sub
        elseif d == 'B'
            pushtext(); font.bold = !font.bold
        elseif d == 'I'
            pushtext(); font.italic = !font.italic
        else
            print(buf, c, d)                                  # a code OpenDocumentSpreadsheets doesn't know: kept as text
        end
        i = k
    end
    pushtext(); flush_para()
    return String(take!(io))
end

# A header's or footer's element from Excel's codes ("" or nothing: not shown).
function _region_xml(xf::ODSFile, tag::String, text::Union{Nothing,AbstractString})
    (text === nothing || isempty(text)) && return "<$tag style:display=\"false\"/>"
    secs, coded = _header_footer_sections(text)
    body = if !coded
        _section_xml(xf, text)
    else
        join(("<style:region-$(k)>" * _section_xml(xf, v) * "</style:region-$(k)>" for (k, v) in pairs(secs) if v !== nothing))
    end
    return "<$tag>" * body * "</$tag>"
end

# A header's left, centre and right sections, and whether it has section codes (XLSX.jl's rule:
# text before the first section code is centred).
function _header_footer_sections(text::AbstractString)
    secs = Dict(c => IOBuffer() for c in values(_HEADER_FOOTER_SECTIONS))
    cur, coded = 'C', false
    i = firstindex(text)
    while i <= lastindex(text)
        c = text[i]
        j = nextind(text, i)
        stop = i
        if c == '&' && j <= lastindex(text)
            d = text[j]
            if d in values(_HEADER_FOOTER_SECTIONS)
                cur, coded = d, true
                i = nextind(text, j)
                continue
            end
            stop = d == '"' ? something(findnext('"', text, nextind(text, j)), lastindex(text)) : j
        end
        print(secs[cur], SubString(text, i, stop))
        i = nextind(text, stop)
    end
    section(c) = (s = String(take!(secs[c])); isempty(s) ? nothing : s)
    return NamedTuple{keys(_HEADER_FOOTER_SECTIONS)}(map(section, values(_HEADER_FOOTER_SECTIONS))), coded
end

# Reading: an ODF header's text style's font.
function _text_style_font(xf::ODSFile, doc::AbstractString, name::AbstractString)
    x = nothing
    for (n, y) in xf.pageedits.text
        n == name && (x = y)
    end
    x === nothing && (x = _named_element(doc, "style:style", name))
    f = _HFFont()
    x === nothing && return f
    m = match(r"<style:text-properties\b[^>]*>", x)
    m === nothing && return f
    a = _attr_pairs(m.match)
    fn = _get(a, "fo:font-family")
    if fn === nothing && (sn = _get(a, "style:font-name")) !== nothing
        face = match(Regex("<style:font-face style:name=\"" * sn * "\"[^>]*svg:font-family=\"([^\"]*)\""), doc)
        fn = face === nothing ? sn : replace(XML.unescape(face.captures[1]), "'" => "")
    end
    f.name = fn
    f.bold = _get(a, "fo:font-weight", "normal") in ("bold", "700", "800", "900")
    f.italic = _get(a, "fo:font-style", "normal") == "italic"
    sz = _get(a, "fo:font-size")
    sz === nothing || (p = _length_pt(sz); p === nothing || (f.size = round(Int, p)))
    col = _get(a, "fo:color")
    col === nothing || (f.color = uppercase(lstrip(col, '#')))
    u = _get(a, "style:text-underline-style", "none")
    f.under = u == "none" ? :none : _get(a, "style:text-underline-type", "single") == "double" ? :double : :single
    f.strike = _get(a, "style:text-line-through-style", "none") != "none"
    pos = split(_get(a, "style:text-position", "0%"))
    p1 = isempty(pos) ? "0%" : pos[1]
    f.pos = p1 == "super" ? :super : p1 == "sub" ? :sub :
            (v = tryparse(Float64, rstrip(p1, '%')); v === nothing || v == 0 ? :none : v > 0 ? :super : :sub)
    return f
end

# The codes that take font `a` to font `b`.
function _font_codes(a::_HFFont, b::_HFFont)
    io = IOBuffer()
    if a.name != b.name || a.bold != b.bold || a.italic != b.italic
        st = b.bold && b.italic ? "Bold Italic" : b.bold ? "Bold" : b.italic ? "Italic" : "Regular"
        print(io, "&\"", a.name == b.name ? "-" : something(b.name, "-"), ',', st, '"')
    end
    a.size == b.size || b.size === nothing || print(io, '&', b.size)
    if a.under != b.under
        a.under === :single && print(io, "&U"); a.under === :double && print(io, "&E")
        b.under === :single && print(io, "&U"); b.under === :double && print(io, "&E")
    end
    a.strike == b.strike || print(io, "&S")
    if a.pos != b.pos
        a.pos === :super && print(io, "&X"); a.pos === :sub && print(io, "&Y")
        b.pos === :super && print(io, "&X"); b.pos === :sub && print(io, "&Y")
    end
    a.color == b.color || print(io, "&K", something(b.color, "000000"))
    return String(take!(io))
end

const _ODF_FIELD_CODES = Dict("text:page-number" => "&P", "text:page-count" => "&N", "text:date" => "&D", "text:time" => "&T",
                              "text:sheet-name" => "&A")

# A region's (or a section's) ODF paragraphs as Excel's codes. `base`: the font plain text has.
function _odf_section_codes(xf::ODSFile, doc::AbstractString, x::AbstractString, base::_HFFont)
    io = IOBuffer()
    cur = _copyfont(base)
    paras = [m.match for m in eachmatch(r"<text:p\b[^>]*?(?:/>|>.*?</text:p>)"s, x)]
    for (pi, p) in enumerate(paras)
        pi > 1 && print(io, '\n')
        endswith(p, "/>") && continue
        inner = p[nextind(p, _start_tag_end(p)):prevind(p, first(findlast("</text:p>", p)))]
        fonts = [base]
        pos = 1
        while pos <= ncodeunits(inner)
            lt = findnext('<', inner, pos)
            if lt === nothing || lt > pos
                t = XML.unescape(SubString(inner, pos, lt === nothing ? lastindex(inner) : prevind(inner, lt)))
                if !isempty(t)
                    f = fonts[end]
                    print(io, _font_codes(cur, f)); cur = _copyfont(f)
                    print(io, replace(t, "&" => "&&"))
                end
                lt === nothing && break
                pos = lt
                continue
            end
            gt = findnext('>', inner, lt)
            tag = inner[lt:gt]
            name = match(r"^</?([\w:-]+)", tag).captures[1]
            if startswith(tag, "</")
                name == "text:span" && length(fonts) > 1 && pop!(fonts)
                pos = gt + 1
            elseif name == "text:span"
                sn = _start_tag_attr(tag, "text:style-name")
                push!(fonts, sn === nothing ? fonts[end] : _text_style_font(xf, doc, sn))
                endswith(tag, "/>") && pop!(fonts)
                pos = gt + 1
            elseif name == "text:s"
                n = something(tryparse(Int, something(_start_tag_attr(tag, "text:c"), "1")), 1)
                f = fonts[end]; print(io, _font_codes(cur, f)); cur = _copyfont(f)
                print(io, " "^n)
                pos = gt + 1
            elseif name in ("text:tab", "text:line-break")
                print(io, name == "text:tab" ? "\t" : "\n"); pos = gt + 1
            else
                # a field: its code, its displayed text skipped
                close = endswith(tag, "/>") ? gt : last(something(findnext("</" * name * ">", inner, gt), gt:gt))
                code = get(_ODF_FIELD_CODES, name, nothing)
                if name == "text:file-name"
                    d = something(_start_tag_attr(tag, "text:display"), "full")
                    code = d == "path" ? "&Z" : d == "full" ? "&Z&F" : "&F"
                end
                if code !== nothing
                    f = fonts[end]; print(io, _font_codes(cur, f)); cur = _copyfont(f)
                    print(io, code)
                else
                    t = XML.unescape(replace(SubString(inner, gt + 1, max(gt, prevind(inner, close - ncodeunits(name) - 2))), r"<[^>]*>" => ""))
                    print(io, replace(t, "&" => "&&"))
                end
                pos = close + 1
            end
        end
    end
    s = String(take!(io))
    return isempty(s) ? nothing : s
end

# The fonts a page style's headers use most: the baseline whose codes aren't written (LibreOffice's
# import gives every run a text style).
function _base_font(xf::ODSFile, doc::AbstractString, regions)
    counts = Dict{String,Int}()
    plain = 0                                       # paragraphs with text outside any span
    for (_, x) in regions
        for m in eachmatch(r"<text:span text:style-name=\"([^\"]*)\"", x)
            counts[m.captures[1]] = get(counts, m.captures[1], 0) + 1
        end
        for p in eachmatch(r"<text:p\b[^>]*>(.*?)</text:p>"s, x)
            rest = replace(p.captures[1], r"<text:span\b[^>]*>.*?</text:span>"s => "")
            occursin(r"[^\s<>]|<text:(?!s\b)", replace(rest, r"<text:s\b[^>]*/>" => "")) && (plain += 1)
        end
    end
    isempty(counts) && return _HFFont()
    best = first(sort!(collect(counts); by = p -> (-p.second, p.first)))
    best.second > plain || return _HFFont()         # unstyled text is the commonest (or ties): plain
    return _text_style_font(xf, doc, best.first)
end

"""
    setHeaderFooter(sheet; header, footer, firstHeader, firstFooter, evenHeader, evenFooter,
                    differentFirst, differentOddEven)

Set the headers and footers printed on a sheet's pages: a string (centred) or a `NamedTuple` of
`left`, `center` and `right` sections, with codes (`&P` page, `&N`
pages, `&D`, `&T`, `&F`, `&Z`, `&A`, fonts from [`headerFooterFont`](@ref), `&&` for `&`). They
are written as ODF fields, sections as regions, fonts
as text styles; first-page and even-page headers are `style:header-first` and `style:header-left`.
`""` removes one. Giving `firstHeader`/`firstFooter` turns `differentFirst` on, and
`evenHeader`/`evenFooter` `differentOddEven`.

Showing or hiding a header or footer keeps the margins as [`setPageMargins`](@ref) measures them:
the page style's are worked out from them again. `scaleWithDoc` and `alignWithMargins` have no LibreOffice counterpart:
only their defaults (`true`) are accepted.
"""
function setHeaderFooter(ws::Worksheet; kw...)
    _require_writable(ws, "set headers and footers")
    isempty(kw) && throw(ODSError("Give the headers, footers or options to set as keywords, such as `header=\"Report\"`. To remove them all, use `removeHeaderFooter`."))
    texts = Dict{String,String}()
    flags = Dict{Symbol,Bool}()
    for (k, v) in kw
        if haskey(_HEADER_FOOTER_PARTS, k)
            v === nothing && continue
            texts[_HEADER_FOOTER_PARTS[k]] = _header_footer_text(v, k)
        elseif haskey(_HEADER_FOOTER_FLAGS, k)
            v isa Bool || throw(ODSError("`$k` must be `true` or `false`. Found `$(repr(v))`."))
            k in (:scaleWithDoc, :alignWithMargins) && !v &&
                throw(ODSError("LibreOffice has no `$k=false`: its headers and footers always scale and align so."))
            flags[k] = v
        else
            throw(ODSError("Unknown keyword `$k`. Must be one of $(join((keys(_HEADER_FOOTER_PARTS)..., keys(_HEADER_FOOTER_FLAGS)...), ", "))."))
        end
    end
    any(t -> haskey(texts, t), ("style:header-first", "style:footer-first")) && get!(flags, :differentFirst, true)
    any(t -> haskey(texts, t), ("style:header-left", "style:footer-left")) && get!(flags, :differentOddEven, true)
    xf = get_odsfile(ws)
    p = _print_state(ws)
    before = (_shown(p.regions, "style:header"), _shown(p.regions, "style:footer"))
    regions = Dict(p.regions)
    for (tag, t) in texts
        regions[tag] = _region_xml(xf, tag, t)
    end
    for (flag, tags) in ((:differentFirst, ("style:header-first", "style:footer-first")),
                         (:differentOddEven, ("style:header-left", "style:footer-left")))
        haskey(flags, flag) || continue
        for tag in tags
            if !flags[flag]
                regions[tag] = "<$tag style:display=\"false\"/>"
            elseif !haskey(texts, tag) && !(haskey(regions, tag) && _shown(collect(regions), tag))
                regions[tag] = "<$tag><text:p/></$tag>"           # on, blank where none is given
            end
        end
    end
    p.regions = [t => get(regions, t, "<$t style:display=\"false\"/>") for t in _REGION_TAGS]
    (_shown(p.regions, "style:header"), _shown(p.regions, "style:footer")) == before || (p.margins_changed = true)
    _page_changed!(ws)
    return nothing
end

_header_footer_text(v, k::Symbol) = throw(ODSError("`$k` must be a string, or a `NamedTuple` of `left`, `center` and `right` sections. Found `$(repr(v))`."))
function _header_footer_text(v::AbstractString, k::Symbol)
    length(v) <= _HEADER_FOOTER_MAX ||
        throw(ODSError("`$k` is $(length(v)) characters long. At most $_HEADER_FOOTER_MAX are allowed, codes included (Excel's limit)."))
    _check_xml_text(v)
    return String(v)
end
function _header_footer_text(v::NamedTuple, k::Symbol)
    for s in keys(v)
        haskey(_HEADER_FOOTER_SECTIONS, s) || throw(ODSError("Unknown section `$s` in `$k`. Must be one of $(join(keys(_HEADER_FOOTER_SECTIONS), ", "))."))
    end
    io = IOBuffer()
    for (s, code) in pairs(_HEADER_FOOTER_SECTIONS)
        text = get(v, s, nothing)
        (text === nothing || text == "") && continue
        text isa AbstractString || throw(ODSError("The `$s` section of `$k` must be a string. Found `$(repr(text))`."))
        last(_header_footer_sections(text)) && throw(ODSError("The `$s` section of `$k` contains a section code (`&L`, `&C` or `&R`). Give each section by name instead."))
        print(io, '&', code, text)
    end
    return _header_footer_text(String(take!(io)), k)
end

"""
    getHeaderFooter(sheet) -> Union{Nothing, NamedTuple}

The headers and footers, or `nothing` if none is shown: `header`, `footer`, `evenHeader`,
`evenFooter`, `firstHeader`, `firstFooter` (each `(left, center, right)` with the codes
[`setHeaderFooter`](@ref) takes, or `nothing`), `differentOddEven`, `differentFirst`, and
`scaleWithDoc`, `alignWithMargins` (always `true`). The file's fields become those codes, and fonts
that differ from the headers' commonest one become font codes. A sheet without a page style of its own shows LibreOffice's default (the
sheet's name, and "Page &P"). Works on read-only files.
"""
function getHeaderFooter(ws::Worksheet)
    xf = get_odsfile(ws)
    p = _print_state(ws)
    any(t -> _shown(p.regions, t), _REGION_TAGS) || return nothing
    doc = _styles_doc(xf)
    base = _base_font(xf, doc, p.regions)
    function part(tag)
        _shown(p.regions, tag) || return nothing
        x = p.regions[findfirst(q -> q.first == tag, p.regions)].second
        if occursin("<style:region-", x)
            sec(n) = (m = match(Regex("<style:region-" * n * ">(.*?)</style:region-" * n * ">", "s"), x);
                      m === nothing ? nothing : _odf_section_codes(xf, doc, m.captures[1], base))
            return (left = sec("left"), center = sec("center"), right = sec("right"))
        end
        return (left = nothing, center = _odf_section_codes(xf, doc, x, base), right = nothing)
    end
    parts = map(part, values(_HEADER_FOOTER_PARTS))
    return merge(NamedTuple{keys(_HEADER_FOOTER_PARTS)}(parts),
                 (differentOddEven = _shown(p.regions, "style:header-left") || _shown(p.regions, "style:footer-left"),
                  differentFirst = _shown(p.regions, "style:header-first") || _shown(p.regions, "style:footer-first"),
                  scaleWithDoc = true, alignWithMargins = true))
end

"""
    removeHeaderFooter(sheet) -> Bool

Hide all of a sheet's headers and footers, keeping the margins as [`setPageMargins`](@ref) measures
them. `false` if none was shown.
"""
function removeHeaderFooter(ws::Worksheet)
    _require_writable(ws, "remove headers and footers")
    p = _print_state(ws)
    any(t -> _shown(p.regions, t), _REGION_TAGS) || return false
    before = (_shown(p.regions, "style:header"), _shown(p.regions, "style:footer"))
    p.regions = [t => "<$t style:display=\"false\"/>" for t in _REGION_TAGS]
    before == (false, false) || (p.margins_changed = true)
    _page_changed!(ws)
    return true
end

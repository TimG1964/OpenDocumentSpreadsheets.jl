# Creating charts (phase 8 step 5, D-085, D-086): XLSX.jl's `addChart`, `addSeries`, `makeCombo` and
# `deleteChart`, writing LibreOffice's chart objects in LibreOffice's own look (the user's choice,
# F-082). A chart added here is a frame in its first cell (resizing with its cells to the last, as
# pictures are) and an object whose text the workbook keeps (`ODSFile.chartobjs`) until it is saved. A
# chart's object is changed as text: its styles are added before `</office:automatic-styles>`, its
# series before `<chart:wall`, its categories into the x axis.

#
# LibreOffice's look
#

const _PALETTE = ["#004586", "#ff420e", "#ffd320", "#579d1c", "#7e0021", "#83caff", "#314004", "#aecf00",
                  "#4b1f6f", "#ff950e", "#c5000b", "#0084d1"]
# LibreOffice's automatic symbols, in order (F-082)
const _AUTO_SYMBOLS = ["square", "diamond", "arrow-down", "arrow-up", "arrow-right", "arrow-left", "bow-tie",
                       "hourglass", "circle", "star", "x", "plus", "asterisk", "horizontal-bar", "vertical-bar"]
# a new Calc document's theme (F-082)
const _LO_THEME = Dict("accent1" => "#18a303", "accent2" => "#0369a3", "accent3" => "#a33e03", "accent4" => "#8e03a3",
    "accent5" => "#c99c00", "accent6" => "#c9211e", "dark1" => "#000000", "light1" => "#ffffff", "dark2" => "#000000",
    "light2" => "#ffffff", "hyperlink" => "#0000ee", "followed-hyperlink" => "#551a8b")
const _THEME_TOKENS = Dict(:accent1 => "accent1", :accent2 => "accent2", :accent3 => "accent3", :accent4 => "accent4",
    :accent5 => "accent5", :accent6 => "accent6", :tx1 => "dark1", :dk1 => "dark1", :bg1 => "light1", :lt1 => "light1",
    :tx2 => "dark2", :dk2 => "dark2", :bg2 => "light2", :lt2 => "light2", :hlink => "hyperlink", :folHlink => "followed-hyperlink")

const _CHART_ROOT = """<?xml version="1.0" encoding="UTF-8"?>
<office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:ooo="http://openoffice.org/2004/office" xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0" xmlns:xlink="http://www.w3.org/1999/xlink" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:meta="urn:oasis:names:tc:opendocument:xmlns:meta:1.0" xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0" xmlns:dr3d="urn:oasis:names:tc:opendocument:xmlns:dr3d:1.0" xmlns:svg="urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0" xmlns:chart="urn:oasis:names:tc:opendocument:xmlns:chart:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:number="urn:oasis:names:tc:opendocument:xmlns:datastyle:1.0" xmlns:of="urn:oasis:names:tc:opendocument:xmlns:of:1.2" xmlns:loext="urn:org:documentfoundation:names:experimental:office:xmlns:loext:1.0" xmlns:chartooo="http://openoffice.org/2010/chart" office:version="VERSION">"""

const _TEXT10 = """<style:text-properties fo:font-size="10pt" style:font-size-asian="10pt" style:font-size-complex="10pt"/>"""
_text_pt(pt) = """<style:text-properties fo:font-size="$(pt)pt" style:font-size-asian="$(pt)pt" style:font-size-complex="$(pt)pt"/>"""

# XLSX.jl's kinds: (chart:class, the plot area's chart properties, the series' kind, sub-pie)
const _KINDS = Dict(
    :column => ("chart:bar", "", :bar), :bar => ("chart:bar", " chart:vertical=\"true\"", :bar),
    :stackedColumn => ("chart:bar", " chart:stacked=\"true\"", :bar),
    :stackedBar => ("chart:bar", " chart:vertical=\"true\" chart:stacked=\"true\"", :bar),
    :percentStackedColumn => ("chart:bar", " chart:percentage=\"true\"", :bar),
    :percentStackedBar => ("chart:bar", " chart:vertical=\"true\" chart:percentage=\"true\"", :bar),
    :line => ("chart:line", "", :line), :lineMarkers => ("chart:line", " chart:symbol-type=\"automatic\"", :line),
    :stackedLine => ("chart:line", " chart:stacked=\"true\"", :line),
    :percentStackedLine => ("chart:line", " chart:percentage=\"true\"", :line),
    :stackedLineMarkers => ("chart:line", " chart:symbol-type=\"automatic\" chart:stacked=\"true\"", :line),
    :percentStackedLineMarkers => ("chart:line", " chart:symbol-type=\"automatic\" chart:percentage=\"true\"", :line),
    :area => ("chart:area", "", :bar), :stackedArea => ("chart:area", " chart:stacked=\"true\"", :bar),
    :percentStackedArea => ("chart:area", " chart:percentage=\"true\"", :bar),
    :pie => ("chart:circle", "", :pie), :doughnut => ("chart:ring", "", :pie),
    :pieOfPie => ("chart:circle", "", :pie), :barOfPie => ("chart:circle", "", :pie),   # LibreOffice's (D-086)
    :scatter => ("chart:scatter", " chart:symbol-type=\"automatic\"", :scatter),
    :bubble => ("chart:bubble", "", :bubble),
    :radar => ("chart:radar", "", :line), :filledRadar => ("chart:filled-radar", "", :bar),
    :combo => ("chart:bar", "", :bar),
    # LibreOffice's stock charts (D-076, D-086): low-high-close, open-low-high-close, and both with volume
    :stock => ("chart:stock", "", :stock), :stockOHLC => ("chart:stock", " chart:japanese-candle-stick=\"true\"", :stock),
    :stockVolume => ("chart:stock", "", :stock), :stockVolumeOHLC => ("chart:stock", " chart:japanese-candle-stick=\"true\"", :stock))

# LibreOffice's line interpolations (D-076)
const _INTERPOLATIONS = Dict(:straight => nothing, :smooth => "cubic-spline", :bspline => "b-spline", :stepStart => "step-start",
    :stepEnd => "step-end", :stepCenterX => "step-center-x", :stepCenterY => "step-center-y")
const _EMPTY_CELLS = Dict(:gap => "leave-gap", :zero => "use-zero", :span => "ignore")

const C_KINDS = Tuple(k for k in (:column, :bar, :stackedColumn, :stackedBar, :percentStackedColumn, :percentStackedBar,
    :line, :lineMarkers, :stackedLine, :percentStackedLine, :stackedLineMarkers, :percentStackedLineMarkers, :area,
    :stackedArea, :percentStackedArea, :pie, :doughnut, :scatter, :bubble, :radar, :filledRadar, :combo))

# Every user text a chart gets is escaped here as the setter runs, so the XML check is made
# here too, and fails the call that gave it (F-090).
_esc(s) = (t = String(s); _check_xml_text(t); sprint(_escape_attr, t))
_esct(s) = (t = String(s); _check_xml_text(t); sprint(_escape_text, t))

# A title's paragraphs: a string (a line break starts a new paragraph, as XLSX.jl's do), or rich text.
function _title_paras(t)
    t isa AbstractString && return join(("<text:p>" * _esct(l) * "</text:p>" for l in split(t, '\n')), "")
    throw(ODSError("A title is text: a string."))
end

function _check_title(t, what::String)
    t === nothing || t === false || t isa AbstractString ||
        throw(ODSError("LibreOffice's $what can't follow a cell (F-081, D-086): give the text instead."))
end

# A new chart's object: LibreOffice's chart of `kind`, with its titles and legend, and no series.
function _new_chart_text(kind::Symbol; title, subtitle, xtitle, ytitle, threeD::Bool, deep::Bool, version::String)
    class, plotprops, _ = _KINDS[kind]
    pie = class in ("chart:circle", "chart:ring")
    io = IOBuffer()
    print(io, replace(_CHART_ROOT, "VERSION" => version), "<office:automatic-styles>",
          """<number:number-style style:name="N0"><number:number number:min-integer-digits="1"/></number:number-style>""",
          """<style:style style:name="ch1" style:family="chart"><style:graphic-properties draw:stroke="none"/></style:style>""",
          """<style:style style:name="ch2" style:family="chart"><style:chart-properties chart:auto-position="true"/>""", _text_pt(13), "</style:style>",
          """<style:style style:name="ch3" style:family="chart"><style:chart-properties chart:auto-position="true"/>""", _text_pt(11), "</style:style>",
          """<style:style style:name="ch4" style:family="chart"><style:chart-properties chart:auto-position="true"/>""", _TEXT10, "</style:style>",
          """<style:style style:name="ch5" style:family="chart"><style:chart-properties""", plotprops,
          threeD ? " chart:three-dimensional=\"true\"" : "", deep ? " chart:deep=\"true\"" : "",
          """ chart:auto-position="true" chart:auto-size="true"/></style:style>""")
    for k in ("ch6", "ch7")
        print(io, """<style:style style:name="$k" style:family="chart" style:data-style-name="N0"><style:chart-properties chart:display-label="true" chart:logarithmic="false" chart:reverse-direction="false" text:line-break="false" chart:link-data-style-to-source="true" chart:axis-position="0"/><style:graphic-properties svg:stroke-color="#b3b3b3"/>""", _TEXT10, "</style:style>")
    end
    print(io, """<style:style style:name="ch8" style:family="chart"><style:graphic-properties svg:stroke-color="#b3b3b3"/></style:style>""",
          """<style:style style:name="ch9" style:family="chart"><style:graphic-properties draw:fill="solid" draw:fill-color="#d9d9d9"/></style:style>""",
          """<style:style style:name="ch10" style:family="chart"><style:graphic-properties draw:fill-color="#d9d9d9"/></style:style>""",
          """<style:style style:name="ch11" style:family="chart"><style:chart-properties chart:auto-position="true"/>""", _text_pt(11), "</style:style>",
          """<style:style style:name="ch12" style:family="chart"><style:chart-properties chart:auto-position="true" style:rotation-angle="90"/>""", _text_pt(11), "</style:style>",
          "</office:automatic-styles><office:body><office:chart>",
          """<chart:chart svg:width="16cm" svg:height="9cm" xlink:href=".." xlink:type="simple" chart:class="$class\"""",
          kind === :pieOfPie ? " loext:sub-pie=\"true\" loext:split-position=\"2\"" : kind === :barOfPie ? " loext:sub-bar=\"true\" loext:split-position=\"2\"" : "",
          """ chart:style-name="ch1">""")
    title isa AbstractString && print(io, """<chart:title chart:style-name="ch2">""", _title_paras(title), "</chart:title>")
    subtitle === nothing || print(io, """<chart:subtitle chart:style-name="ch3">""", _title_paras(subtitle), "</chart:subtitle>")
    print(io, """<chart:legend chart:legend-position="end" style:legend-expansion="high" chart:style-name="ch4"/>""",
          """<chart:plot-area chart:style-name="ch5">""")
    if !pie
        print(io, """<chart:axis chart:dimension="x" chart:name="primary-x" chart:style-name="ch6">""")
        xtitle === nothing || print(io, """<chart:title chart:style-name="ch11">""", _title_paras(xtitle), "</chart:title>")
        print(io, "</chart:axis>", """<chart:axis chart:dimension="y" chart:name="primary-y" chart:style-name="ch7">""")
        ytitle === nothing || print(io, """<chart:title chart:style-name="ch12">""", _title_paras(ytitle), "</chart:title>")
        print(io, """<chart:grid chart:style-name="ch8" chart:class="major"/></chart:axis>""")
        threeD && print(io, """<chart:axis chart:dimension="z" chart:name="primary-z" chart:style-name="ch6"/>""")
    end
    print(io, """<chart:wall chart:style-name="ch9"/><chart:floor chart:style-name="ch10"/></chart:plot-area>""",
          "</chart:chart></office:chart></office:body></office:document-content>")
    return String(take!(io))
end

#
# Editing an object's text
#

# The object's text and model entry, made an entry when it is a file's chart (its text now).
function _editable(c::AbstractChart)
    xf = c.package
    _require_writable(xf, "change a chart")
    f = _frame(c)
    if !haskey(xf.chartobjs, c.name)
        if xf.container !== nothing && xf.container.zip === nothing
            # a flat file's own chart (phase 8 step 9): its inline object, which the save replaces
            t = _object_text(f)
            xf.chartobjs[c.name] = ChartObj(t, length(xf.ops), "", t, length(xf.ops))
            return xf.chartobjs[c.name]
        end
        # its styles.xml (line dashes) kept with it, for copies and new dashes
        sp = xf.container === nothing ? "" : _object_source(xf, c.name) * "/styles.xml"
        styles = !isempty(sp) && sp in partnames(xf.container) ? read_part_text(xf.container, sp) : ""
        xf.chartobjs[c.name] = ChartObj(_object_text(f), length(xf.ops), styles)
    end
    o = xf.chartobjs[c.name]
    o.nops < length(xf.ops) && (o.text = _chart_text_now(xf, c.name); o.nops = length(xf.ops))
    return o
end

function _next_style_name(t::AbstractString)
    k = 0
    for m in eachmatch(r"style:name=\"ch(\d+)\"", t)
        k = max(k, parse(Int, m.captures[1]))
    end
    return "ch$(k + 1)"
end

# A new automatic style (its property elements' XML), returning its name.
function _add_style!(o, props::AbstractString; datastyle::Bool = false)
    name = _next_style_name(o.text)
    st = "<style:style style:name=\"$name\" style:family=\"chart\"" * (datastyle ? " style:data-style-name=\"N0\"" : "") * ">" * props * "</style:style>"
    i = findfirst("</office:automatic-styles>", o.text)
    i === nothing && throw(ODSError("The chart's object has no automatic styles."))
    o.text = o.text[1:prevind(o.text, first(i))] * st * o.text[first(i):end]
    return name
end

# Inserts XML before the first match of `before` (a string) inside the plot area.
function _insert_before!(o, before::AbstractString, xml::AbstractString)
    i = findfirst(before, o.text)
    i === nothing && throw(ODSError("The chart's object has no `$before`."))
    o.text = o.text[1:prevind(o.text, first(i))] * xml * o.text[first(i):end]
end

# Sets attributes on an automatic style's `style:chart-properties` (made if absent).
function _set_style_attrs!(o, style::AbstractString, attrs::Vector{Pair{String,String}}; element = "style:chart-properties")
    m = match(Regex("<style:style style:name=\"" * style * "\"[^>]*>.*?</style:style>", "s"), o.text)
    m === nothing && throw(ODSError("The chart has no style `$style`."))
    st = m.match
    e = match(Regex("<" * element * "\\b[^>]*?/?>"), st)
    if e === nothing
        new = "<" * element * join(" $k=\"$(_esc(v))\"" for (k, v) in attrs) * "/>"
        st2 = replace(st, r"(<style:style[^>]*>)" => SubstitutionString("\\1" * replace(new, "\\" => "\\\\")); count = 1)
    else
        tag = e.match
        for (k, v) in attrs
            a = "$k=\"$(_esc(v))\""
            if occursin(Regex("\\b" * k * "=\""), tag)
                tag = replace(tag, Regex("\\b" * k * "=\"[^\"]*\"") => a)
            else
                close = endswith(tag, "/>") ? "/>" : ">"
                tag = tag[1:end-ncodeunits(close)] * " " * a * close
            end
        end
        st2 = replace(st, e.match => tag; count = 1)
    end
    o.text = replace(o.text, st => st2; count = 1)
end

_plot_style(o) = match(r"<chart:plot-area\b[^>]*chart:style-name=\"([^\"]*)\"", o.text).captures[1]

#
# Addresses
#

# A reference as XLSX.jl takes it (`"Data!B2:B5"`, `"'My Data'!\$B\$2:\$B\$3"`, `"Data.B2:B5"`, `"B2:B5"` on the
# chart's sheet, a range object) as an ODF range list (`Data.B2:Data.B5`).
function _odf_range(x, sheet::AbstractString)
    s = x isa AbstractString ? String(x) : string(x)
    s = replace(s, '$' => "")
    k = findlast('!', s)
    k === nothing || (s = s[1:prevind(s, k)] * "." * s[nextind(s, k):end])
    areas = _range_areas(occursin('.', s) && !startswith(s, '.') ? s : SheetCore.quoteit(sheet) * "." * s)
    (isempty(areas) || any(a -> a[1] === nothing, areas)) && throw(ODSError("`$x` is not a reference to cells."))
    out = String[]
    for (sh, r, c) in areas
        q = SheetCore.quoteit(sh)
        push!(out, q * "." * _cellname(first(r), first(c)) * ":" * q * "." * _cellname(last(r), last(c)))
    end
    return join(out, " ")
end
_points_of(addr::AbstractString) = sum(length(r) * length(c) for (_, r, c) in _range_areas(addr))

#
# The API
#

"""
    addChart(ws::Worksheet, kind::Symbol; anchor, title = nothing, xtitle = nothing, ytitle = nothing,
             subtitle = nothing, threeD = false, deep = false) -> Chart (a ChartEx for :histogram)

A new chart of `kind` over the cells of `anchor` (`"F2:M18"`), with no series yet (add them with
[`addSeries`](@ref)): a frame in the first cell, resizing with its cells up to the last, and an object in
LibreOffice's default look.

`kind = :histogram` makes LibreOffice's histogram, which counts the values of its one series in bins:
it returns a [`ChartEx`](@ref), and takes only `anchor`, `title`, `subtitle`, `xtitle` and `ytitle`.
See [`addSeries`](@ref addSeries(::ChartEx, ::Any)) and `setSeriesBinning`.

`kind` is one of `:column`, `:bar`, `:stackedColumn`, `:stackedBar`, `:percentStackedColumn`,
`:percentStackedBar`, `:line`, `:lineMarkers`, `:stackedLine`, `:percentStackedLine`,
`:stackedLineMarkers`, `:percentStackedLineMarkers`, `:area`, `:stackedArea`, `:percentStackedArea`,
`:pie`, `:doughnut`, `:scatter`, `:bubble`, `:radar`, `:filledRadar`, `:combo` (LibreOffice's column and
line chart), `:pieOfPie`, `:barOfPie`, and the stock charts `:stock` (low,
high, close), `:stockOHLC` (open, low, high, close, as candlesticks), `:stockVolume` and
`:stockVolumeOHLC` (a volume series first, in columns on the left axis). A stock chart's series are
added in that order.

`title` is text (`nothing` or `false`: none; LibreOffice has no automatic title). `xtitle` and `ytitle`
title the axes (not on a pie or doughnut). LibreOffice's titles can't follow a cell: a `CellRef` is an
error.

More options:
- `subtitle`; `threeD` and `deep` for a 3-D chart; `dataTable = true` for a data table under the plot;
- `interpolation` of line, XY and radar lines: `:straight`, `:smooth`, `:bspline`, `:stepStart`,
  `:stepEnd`, `:stepCenterX`, `:stepCenterY`;
- `emptyCells`: `:gap`, `:zero` or `:span` (joined over); `includeHidden`: whether hidden cells are
  drawn; `sortByX`: an XY chart's points sorted by x;
- `startAngle` of a pie or doughnut: degrees anticlockwise from three o'clock (LibreOffice's; 90 starts
  at twelve);
- `data`, LibreOffice's chart wizard: a range whose series are made at once, in columns or rows
  (`seriesIn = :columns` or `:rows`), the first row and column holding names and categories
  (`firstRowLabels`, `firstColumnLabels`, both `true` by default).

```julia
using OpenDocumentSpreadsheets.Charts

xf = openods("budget.ods"; mode = "rw")
sh = xf["Costs"]
c = addChart(sh, :column; anchor = "E2:L18", title = "Costs by month", ytitle = "Amount")
addSeries(c, "B2:B13"; categories = "A2:A13", name_ref = "B1")

addChart(xf["Income"], :line; anchor = "E2:L18", data = "A1:B13")   # its series from a range
saveods(xf)
```
"""
function addChart(ws::Worksheet, kind::Symbol; anchor::Union{AbstractString,CellRange}, title = nothing, xtitle = nothing,
                  ytitle = nothing, subtitle = nothing, threeD::Bool = false, deep::Bool = false, dataTable::Bool = false,
                  interpolation::Symbol = :straight, emptyCells = nothing, includeHidden = nothing, sortByX = nothing,
                  startAngle = nothing, data = nothing, seriesIn::Symbol = :columns, firstRowLabels::Bool = true,
                  firstColumnLabels::Bool = true)
    if kind === :histogram      # D-092: a column chart, made LibreOffice's histogram
        given = (threeD, deep, dataTable, interpolation !== :straight, emptyCells !== nothing, includeHidden !== nothing,
                 sortByX !== nothing, startAngle !== nothing, data !== nothing)
        names = (:threeD, :deep, :dataTable, :interpolation, :emptyCells, :includeHidden, :sortByX, :startAngle, :data)
        for (g, k) in zip(given, names)
            g && throw(ODSError("A histogram takes `anchor`, `title`, `subtitle`, `xtitle` and `ytitle`; `$k` is for other charts." *
                                (k === :data ? " Add its series with `addSeries`." : "")))
        end
        return _make_histogram!(addChart(ws, :column; anchor, title, subtitle, xtitle, ytitle))
    end
    haskey(_KINDS, kind) || throw(ODSError("Unknown chart kind `:$kind`. The kinds are $(join(string.(":", sort!([collect(keys(_KINDS)); :histogram])), ", "))."))
    _class0 = _KINDS[kind][1]
    haskey(_INTERPOLATIONS, interpolation) ||
        throw(ODSError("Unknown interpolation `:$interpolation`: use $(join(string.(":", sort!(collect(keys(_INTERPOLATIONS)))), ", "))."))
    interpolation === :straight || _class0 in ("chart:line", "chart:scatter", "chart:radar") ||
        throw(ODSError("`interpolation` is for line, XY and radar charts."))
    emptyCells === nothing || haskey(_EMPTY_CELLS, emptyCells) || throw(ODSError("`emptyCells` is :gap, :zero or :span."))
    includeHidden === nothing || includeHidden isa Bool || throw(ODSError("`includeHidden` is true or false."))
    sortByX === nothing || (sortByX isa Bool && _class0 == "chart:scatter") || throw(ODSError("`sortByX` (true or false) is for XY charts."))
    startAngle === nothing || (startAngle isa Integer && 0 <= startAngle < 360 && _class0 in ("chart:circle", "chart:ring")) ||
        throw(ODSError("`startAngle` (0 to 359 degrees) is for pie and doughnut charts."))
    dataTable && _class0 in ("chart:circle", "chart:ring") && throw(ODSError("A pie or doughnut has no data table."))
    seriesIn in (:columns, :rows) || throw(ODSError("`seriesIn` is :columns or :rows."))
    data !== nothing && _class0 == "chart:bubble" && throw(ODSError("A bubble chart's series need their sizes: add them with `addSeries`."))
    (threeD && _class0 == "chart:stock") && throw(ODSError("LibreOffice has no 3-D stock chart."))
    title === true && throw(ODSError("`title = true` has no text: give the title's text."))
    _check_title(title, "titles"); _check_title(xtitle, "axis titles"); _check_title(ytitle, "axis titles")
    _check_title(subtitle, "subtitles")
    class = _KINDS[kind][1]
    class in ("chart:circle", "chart:ring") && (xtitle !== nothing || ytitle !== nothing) &&
        throw(ODSError("A $(kind) chart has no axes to title."))
    deep && !threeD && throw(ODSError("`deep` is for a 3-D chart: add `threeD = true`."))
    xf = get_odsfile(ws)
    _require_writable(xf, "add a chart")
    rng = anchor isa CellRange ? anchor : CellRange(String(anchor))
    r, c = row_number(rng.start), column_number(rng.start)
    tr, tc = row_number(rng.stop), column_number(rng.stop)
    version = something(xf.version, "1.4")
    name = _new_object_name(xf)
    text = _new_chart_text(kind; title = title === false ? nothing : title, subtitle, xtitle, ytitle, threeD, deep,
                           version = version in ("1.3", "1.4") ? version : "1.4")
    width = sum(_col_cm(ws, x) for x in c:tc); height = sum(_row_cm(ws, x) for x in r:tr)
    # the object's page is the frame's size, as LibreOffice's (its custom positions are on it)
    text = replace(text, "svg:width=\"16cm\" svg:height=\"9cm\"" => "svg:width=\"$(_fmt_cm(width))\" svg:height=\"$(_fmt_cm(height))\""; count = 1)
    xf.chartobjs[name] = o = ChartObj(text, length(xf.ops))
    kind === :combo && _secondary_y!(o)
    # LibreOffice's own options (D-076)
    plot = _plot_style(o)
    opts = Pair{String,String}[]
    interpolation === :straight || push!(opts, "chart:interpolation" => _INTERPOLATIONS[interpolation])
    emptyCells === nothing || push!(opts, "chart:treat-empty-cells" => _EMPTY_CELLS[emptyCells])
    includeHidden === nothing || push!(opts, "chart:include-hidden-cells" => string(includeHidden))
    sortByX === nothing || push!(opts, "chart:sort-by-x-values" => string(sortByX))
    startAngle === nothing || push!(opts, "chart:angle-offset" => string(startAngle))
    isempty(opts) || _set_style_attrs!(o, plot, opts)
    dataTable && _insert_before!(o, "<chart:plot-area", "<loext:data-table/>")
    _class0 == "chart:stock" && _stock_parts!(o, kind in (:stockVolume, :stockVolumeOHLC))
    img = ImageData("", "", tr, tc, width, height, _col_cm(ws, tc), _row_cm(ws, tr), "", "", name)
    push!(_frame_edit!(ws, r, c).added, img)
    _touch_cell!(ws, r, c)
    ch = Chart(xf, name * "/content.xml", name, nothing, ws.name, _cellname(r, c), _cellname(tr, tc))
    # rich titles (D-088): their runs in place of the plain text written with the object
    for (t, st) in ((title, "ch2"), (subtitle, "ch3"), (xtitle, "ch11"), (ytitle, "ch12"))
        t isa RichTextString || continue
        m = match(Regex("(<chart:(?:sub)?title chart:style-name=\"" * st * "\">).*?(</chart:(?:sub)?title>)", "s"), o.text)
        m === nothing && continue
        o.text = replace(o.text, m.match => m.captures[1] * _rich_title_paras(o, t) * m.captures[2]; count = 1)
    end
    data === nothing || _add_data_series!(ch, o, data, seriesIn, firstRowLabels, firstColumnLabels)
    return ch
end

# A stock chart's own parts, as LibreOffice's (experiment 039 part A): with volume, a secondary y axis
# for the prices; the gain and loss markers and the range line.
function _stock_parts!(o, volume::Bool)
    volume && _secondary_y!(o)
    gain = _add_style!(o, """<style:graphic-properties draw:fill-color="#ffffff"/>""")
    loss = _add_style!(o, """<style:graphic-properties svg:stroke-color="#b3b3b3" draw:fill-color="#000000"/>""")
    range = _add_style!(o, """<style:graphic-properties svg:stroke-color="$(volume ? "#ff420e" : "#004586")"/>""")
    _insert_before!(o, "<chart:wall", "<chart:stock-gain-marker chart:style-name=\"$gain\"/><chart:stock-loss-marker chart:style-name=\"$loss\"/>" *
                                      "<chart:stock-range-line chart:style-name=\"$range\"/>")
end

# LibreOffice's chart wizard (D-076): the series of a range, in its columns or rows, the first row and
# column holding the names and the categories (XY: the x values).
function _add_data_series!(c::Chart, o, data, seriesIn::Symbol, firstRow::Bool, firstCol::Bool)
    areas = _range_areas(_odf_range(data, c.sheet))
    length(areas) == 1 || throw(ODSError("`data` is one range of cells."))
    sh, rows, cols = only(areas)
    q = SheetCore.quoteit(sh)
    ref(r1, c1, r2, c2) = q * "." * _cellname(r1, c1) * ":" * q * "." * _cellname(r2, c2)
    r0, c0 = first(rows), first(cols)
    r1, c1 = r0 + firstRow, c0 + firstCol
    (r1 > last(rows) || c1 > last(cols)) && throw(ODSError("`data` holds no values beside its labels."))
    if seriesIn === :columns
        cats = firstCol ? ref(r1, c0, last(rows), c0) : nothing
        for j in c1:last(cols)
            addSeries(c, ref(r1, j, last(rows), j); categories = cats, name_ref = firstRow ? ref(r0, j, r0, j) : nothing)
        end
    else
        cats = firstRow ? ref(r0, c1, r0, last(cols)) : nothing
        for i in r1:last(rows)
            addSeries(c, ref(i, c1, i, last(cols)); categories = cats, name_ref = firstCol ? ref(i, c0, i, c0) : nothing)
        end
    end
    # the range and its layout, as the wizard writes them on the plot area
    labels = firstRow && firstCol ? "both" : firstRow ? "row" : firstCol ? "column" : "none"
    m = match(r"<chart:plot-area\b[^>]*>", o.text)
    o.text = replace(o.text, m.match => m.match[1:end-1] * " table:cell-range-address=\"" * _esc(ref(r0, c0, last(rows), last(cols))) *
                                        "\" chart:data-source-has-labels=\"$labels\">"; count = 1)
    seriesIn === :rows && _set_style_attrs!(o, _plot_style(o), ["chart:series-source" => "rows"])
    return c
end

# A secondary y axis, at the plot's right (a combo chart's line group, F-081; a stock chart's prices),
# in a style of its own: the primary axis' crosses at 0, which would draw it over the primary. ODF's
# order is axes, then series: LibreOffice ignores an axis after the series.
function _secondary_y!(o)
    ax = _add_style!(o, """<style:chart-properties chart:display-label="true" chart:logarithmic="false" chart:reverse-direction="false" text:line-break="false" chart:link-data-style-to-source="true" chart:axis-position="end"/><style:graphic-properties svg:stroke-color="#b3b3b3"/>""" * _TEXT10;
                     datastyle = true)
    _insert_before!(o, occursin("<chart:series ", o.text) ? "<chart:series " : "<chart:wall",
                    "<chart:axis chart:dimension=\"y\" chart:name=\"secondary-y\" chart:style-name=\"$ax\"/>")
end

# The class of the chart and whether it is an XY, bubble, pie, line-like or combo chart.
_chart_class(o) = match(r"<chart:chart\b[^>]*chart:class=\"([^\"]*)\"", o.text).captures[1]
# A column and line chart: a bar chart with a secondary y axis or line series (F-081).
_is_combo(o) = _chart_class(o) == "chart:bar" &&
    (occursin("chart:name=\"secondary-y\"", o.text) || occursin(r"<chart:series[^>]*chart:class=\"chart:line\"", o.text))

const _MARKERS = Dict(:circle => "circle", :square => "square", :diamond => "diamond", :triangle => "arrow-up", :x => "x",
    :plus => "plus", :star => "asterisk", :dash => "horizontal-bar", :dot => "arrow-right",
    # LibreOffice's own (D-076)
    :arrowDown => "arrow-down", :arrowLeft => "arrow-left", :arrowUp => "arrow-up", :arrowRight => "arrow-right",
    :bowTie => "bow-tie", :hourglass => "hourglass", :loStar => "star", :asterisk => "asterisk", :hBar => "horizontal-bar",
    :vBar => "vertical-bar")

# A colour given as XLSX.jl takes it: hex, a Colors.jl name, a theme token (`"accent1"`, `:tx1`) or a
# SchemeColor — the document's theme colour, resolved: LibreOffice keeps no theme reference in a chart
# (experiment 039 B2).
function _color_spec(xf, c)
    c === nothing && return nothing
    c isa SchemeColor && return (_color_value(xf, c)[1], nothing)
    tok = c isa Symbol ? c : Symbol(c)
    if haskey(_THEME_TOKENS, tok)
        slot = _THEME_TOKENS[tok]
        return (_theme_colors(xf)[slot], slot)
    end
    c isa Symbol && throw(ODSError("`:$c` is not a colour: give a hex value (\"FF0000\"), a colour name or a theme colour (:accent1)."))
    return (try SheetCore.odf_color(String(c)) catch; throw(ODSError("`$c` is not a colour: give a hex value (\"FF0000\"), a colour name or a theme colour (:accent1).")) end, nothing)
end

# The document's theme colours (styles.xml's `loext:theme`), else LibreOffice's for a new document.
function _theme_colors(xf)
    d = copy(_LO_THEME)
    xf.container === nothing && return d
    s = try (xf.container.zip === nothing ? xf.content : read_part_text(xf.container, "styles.xml")) catch; "" end
    for m in eachmatch(r"<loext:color loext:name=\"([^\"]*)\" loext:color=\"([^\"]*)\"/>", s)
        d[m.captures[1]] = m.captures[2]
    end
    return d
end

"""
    addSeries(c::Chart, values; categories = nothing, name = nothing, name_ref = nothing, bubble_sizes = nothing,
              markers = nothing, smooth = nothing, line = nothing, color = nothing, group = nothing) -> Chart

Adds a series to a chart, in LibreOffice's form:
- `values` (and `categories`, `name_ref`, `bubble_sizes`) are references: `"Data.B2:B7"`, `"Data!B2:B7"`,
  `"B2:B7"` (on the chart's sheet), or a range object.
- `categories` are the x axis's (a chart's, not a series': a different range later is an error),
  or an XY or bubble series' x values. `bubble_sizes` is required on a bubble chart.
- `name` is the series' name as text (`loext:label-string`), `name_ref` a cell holding it.
- `markers` (`true`, `false` or a symbol: `:circle`, `:square`, `:diamond`, `:triangle`, `:x`, `:plus`,
  `:star`, `:dash`, `:dot`, `:none`, `:auto`, and LibreOffice's `:arrowDown`, `:arrowLeft`, `:bowTie`,
  `:hourglass`, `:loStar`, `:vBar`) on line, radar and XY series; `:picture` is an error (no picture).
- `smooth` on line and XY series: LibreOffice smooths a chart's lines all or none, so a series that
  differs from those before is an error.
- `line` joins an XY series' points.
- `color` (hex, a colour name, or a theme colour such as `:accent1`) is the series' colour (not on a pie
  or doughnut, whose points are coloured one by one).
- `group` (`:column` or `:line`) is required on a `:combo` chart and refused elsewhere.

```julia
using OpenDocumentSpreadsheets.Charts

xf = openods("budget.ods"; mode = "rw")
sh = xf["Income"]
sh["D1"] = "Target"
for r in 2:13; sh[r, 4] = 1100.0; end
c = addChart(sh, :lineMarkers; anchor = "F2:M18")
addSeries(c, "B2:B13"; categories = "A2:A13", name_ref = "B1", color = "1F4E79")
addSeries(c, "D2:D13"; name = "Target", markers = false)
saveods(xf)
```
"""
function addSeries(c::Chart, values; categories = nothing, name = nothing, name_ref = nothing, bubble_sizes = nothing,
                   markers = nothing, smooth = nothing, line = nothing, color = nothing, group = nothing)
    xf = c.package
    o = _editable(c)
    class = _chart_class(o)
    combo = _is_combo(o)
    pie = class in ("chart:circle", "chart:ring")
    xy = class == "chart:scatter"; bubble = class == "chart:bubble"
    linelike = class in ("chart:line", "chart:radar")
    name !== nothing && name_ref !== nothing && throw(ODSError("Give the series' `name` or its `name_ref`, not both."))
    (bubble && bubble_sizes === nothing) && throw(ODSError("A bubble series needs `bubble_sizes`."))
    (!bubble && bubble_sizes !== nothing) && throw(ODSError("`bubble_sizes` is for bubble charts."))
    (bubble && categories === nothing) && throw(ODSError("A bubble series needs `categories` (its x values)."))
    if combo
        group in (:column, :line) || throw(ODSError("A combo chart's series needs `group = :column` or `group = :line`."))
    else
        group === nothing || throw(ODSError("`group` is for combo charts."))
    end
    isline = linelike || xy || (combo && group === :line)
    if markers !== nothing
        (isline || xy) || throw(ODSError("Markers are for line, radar and XY series."))
        markers === :picture && throw(ODSError("A picture marker needs a picture, which LibreOffice can't take from here (D-086)."))
        markers isa Bool || haskey(_MARKERS, markers) || markers in (:none, :auto) ||
            throw(ODSError("Unknown marker `$markers`: use $(join(string.(":", sort!(collect(keys(_MARKERS)))), ", ")), :none or :auto."))
    end
    smooth === nothing || smooth isa Bool || throw(ODSError("`smooth` is true or false."))
    smooth === nothing || isline || throw(ODSError("`smooth` is for line and XY series."))
    line === nothing || line isa Bool || throw(ODSError("`line` is true or false."))
    line === nothing || xy || throw(ODSError("`line` is for XY (scatter) series."))
    xy && markers === false && line !== true && throw(ODSError("An XY series without markers needs `line = true`."))
    (pie && color !== nothing) && throw(ODSError("A $(class == "chart:ring" ? "doughnut" : "pie")'s points are coloured one by one: `color` is for other charts."))
    pie && occursin("<chart:series", o.text) && throw(ODSError("A pie or doughnut chart has one series."))
    vals = _odf_range(values, c.sheet)
    cats = categories === nothing ? nothing : _odf_range(categories, c.sheet)
    # categories belong to the x axis (D-086)
    if cats !== nothing && !xy && !bubble
        m = match(r"<chart:categories table:cell-range-address=\"([^\"]*)\"", o.text)
        if m === nothing
            _add_categories!(o, cats)
        elseif XML.unescape(m.captures[1]) != cats
            throw(ODSError("LibreOffice's categories are the chart's, not a series': this chart's are `$(XML.unescape(m.captures[1]))` (D-086)."))
        end
    end
    class == "chart:stock" && return _add_stock_series!(c, o, vals, name, name_ref, color)
    # smoothing is the chart's (D-086)
    plot = _plot_style(o)
    cur = match(Regex("<style:style style:name=\"" * plot * "\"[^>]*>.*?</style:style>", "s"), o.text).match
    smoothed = occursin("chart:interpolation=\"cubic-spline\"", cur)
    nseries = count("<chart:series ", o.text)
    if smooth !== nothing && nseries > 0 && smooth != smoothed
        throw(ODSError("LibreOffice smooths a chart's lines all or none (D-086): this chart's are $(smoothed ? "" : "not ")smooth."))
    end
    smooth === true && !smoothed && _set_style_attrs!(o, plot, ["chart:interpolation" => "cubic-spline"])
    k = nseries + 1
    col, slot = something(_color_spec(xf, color), (_PALETTE[mod1(k, length(_PALETTE))], nothing))
    # the series' style
    chartprops = Pair{String,String}[]
    autosym = occursin("chart:symbol-type=\"automatic\"", cur)
    if isline || xy
        sym = markers === nothing ? (autosym ? "auto" : "none") : markers === false || markers === :none ? "none" :
              markers === true ? "circle" : markers === :auto ? "auto" : _MARKERS[markers]
        if sym == "none"
            push!(chartprops, "chart:symbol-type" => "none")
        else
            symname = sym == "auto" ? _AUTO_SYMBOLS[mod1(k, length(_AUTO_SYMBOLS))] : sym
            append!(chartprops, ["chart:symbol-type" => "named-symbol", "chart:symbol-name" => symname,
                                 "chart:symbol-width" => "0.25cm", "chart:symbol-height" => "0.25cm"])
        end
    end
    push!(chartprops, "chart:link-data-style-to-source" => "true")
    cp = "<style:chart-properties" * join(" $a=\"$(_esc(b))\"" for (a, b) in chartprops) * "/>"
    gp = if (isline && !(xy && line !== true)) || (xy && line === true)
        """<style:graphic-properties svg:stroke-width="0.08cm" svg:stroke-color="$col" draw:fill-color="$col">""" *
        "</style:graphic-properties>"
    elseif xy
        """<style:graphic-properties draw:stroke="none" svg:stroke-color="$col" draw:fill-color="$col">""" *
        "</style:graphic-properties>"
    else
        """<style:graphic-properties draw:stroke="none" draw:fill-color="$col"/>"""
    end
    st = _add_style!(o, cp * gp * _TEXT10; datastyle = true)
    # the series
    io = IOBuffer()
    serclass = combo ? (group === :line ? "chart:line" : "chart:bar") : class == "chart:ring" ? "chart:circle" : class
    if bubble
        print(io, "<chart:series chart:style-name=\"$st\" chart:values-cell-range-address=\"", _esc(_odf_range(bubble_sizes, c.sheet)), "\"")
    else
        print(io, "<chart:series chart:style-name=\"$st\" chart:values-cell-range-address=\"", _esc(vals), "\"")
    end
    name_ref === nothing || print(io, " chart:label-cell-address=\"", _esc(_odf_range(name_ref, c.sheet)), "\"")
    name === nothing || print(io, " loext:label-string=\"", _esc("\"" * replace(String(name), "\"" => "\"\"") * "\""), "\"")
    combo && group === :line && print(io, " chart:attached-axis=\"secondary-y\"")
    print(io, " chart:class=\"$serclass\">")
    bubble && print(io, "<chart:domain table:cell-range-address=\"", _esc(vals), "\"/>")
    (xy || bubble) && cats !== nothing && print(io, "<chart:domain table:cell-range-address=\"", _esc(cats), "\"/>")
    if pie                                      # each point its own colour, as LibreOffice writes a pie (F-082)
        for p in 1:_points_of(vals)
            ps = _add_style!(o, """<style:graphic-properties draw:fill-color="$(_PALETTE[mod1(p, length(_PALETTE))])"/>""")
            print(io, "<chart:data-point chart:style-name=\"$ps\"/>")
        end
    end
    print(io, "</chart:series>")
    _insert_before!(o, occursin("<chart:stock-gain-marker", o.text) ? "<chart:stock-gain-marker" : "<chart:wall", String(take!(io)))
    return c
end

# A stock chart's series, by position (LibreOffice's, experiment 039 part A): with volume, the first is
# the volume, columns on the primary y axis; the prices (open, low, high, close) follow on the secondary.
function _add_stock_series!(c::Chart, o, vals, name, name_ref, color)
    color === nothing || throw(ODSError("A stock chart's prices are drawn as LibreOffice's candlesticks and range line: `color` is for other charts."))
    volume = occursin("chart:name=\"secondary-y\"", o.text)
    ohlc = occursin("chart:japanese-candle-stick=\"true\"", o.text)
    n = count("<chart:series ", o.text)
    nmax = 3 + ohlc + volume
    n < nmax || throw(ODSError("This stock chart has its $nmax series: " *
                               (volume ? "volume, " : "") * (ohlc ? "open, " : "") * "low, high, close."))
    io = IOBuffer()
    print(io, "<chart:series")
    if volume && n == 0
        st = _add_style!(o, """<style:chart-properties chart:link-data-style-to-source="true"/><style:graphic-properties draw:stroke="none" draw:fill-color="$(_PALETTE[1])"/>""" * _TEXT10;
                         datastyle = true)
        print(io, " chart:attached-axis=\"primary-y\" chart:style-name=\"$st\"")
    end
    print(io, " chart:values-cell-range-address=\"", _esc(vals), "\"")
    name_ref === nothing || print(io, " chart:label-cell-address=\"", _esc(_odf_range(name_ref, c.sheet)), "\"")
    name === nothing || print(io, " loext:label-string=\"", _esc("\"" * replace(String(name), "\"" => "\"\"") * "\""), "\"")
    if volume && n == 0
        print(io, " chart:class=\"chart:bar\"")
    else
        print(io, " chart:attached-axis=\"", volume ? "secondary-y" : "primary-y", "\"")
    end
    print(io, "></chart:series>")
    _insert_before!(o, "<chart:stock-gain-marker", String(take!(io)))
    return c
end

function _add_categories!(o, cats::AbstractString)
    m = match(r"<chart:axis\b[^>]*chart:name=\"primary-x\"[^>]*?(/?)>", o.text)
    m === nothing && return                    # a pie: no axes; its categories are the chart's
    cat = "<chart:categories table:cell-range-address=\"" * _esc(cats) * "\"/>"
    if m.captures[1] == "/"
        o.text = replace(o.text, m.match => m.match[1:end-2] * ">" * cat * "</chart:axis>"; count = 1)
    else
        # after the axis' title: ODF's order is title, categories, grids
        i = first(findfirst(m.match, o.text)) + ncodeunits(m.match)
        t = findnext(r"^<chart:title\b.*?</chart:title>"s, o.text[i:end], 1)
        t === nothing || (i += last(t))
        o.text = o.text[1:i-1] * cat * o.text[i:end]
    end
end

"""
    makeCombo(c::Chart) -> Chart

Makes a `:column`, `:stackedColumn` or `:line` chart of two or more series LibreOffice's column and
line chart: its last series becomes a line on a secondary y axis, the
others clustered columns.
"""
function makeCombo(c::Chart)
    o = _editable(c)
    class = _chart_class(o)
    class in ("chart:bar", "chart:line") || throw(ODSError("`makeCombo` makes a column or line chart a combo chart."))
    occursin("chart:name=\"secondary-y\"", o.text) && throw(ODSError("The chart is already a combo chart."))
    plot = _plot_style(o)
    cur = match(Regex("<style:style style:name=\"" * plot * "\"[^>]*>.*?</style:style>", "s"), o.text).match
    (occursin("chart:vertical=\"true\"", cur) || occursin("chart:percentage=\"true\"", cur)) &&
        throw(ODSError("`makeCombo` makes a column, stacked column or line chart a combo chart."))
    n = count("<chart:series ", o.text)
    n >= 2 || throw(ODSError("A combo chart needs two series or more."))
    # columns, unstacked; the last series a line on the secondary axis
    o.text = replace(o.text, r"(<chart:chart\b[^>]*chart:class=\")chart:line\"" => s"\1chart:bar\""; count = 1)
    _set_style_attrs!(o, plot, ["chart:stacked" => "false"])
    o.text = replace(o.text, r"(<chart:series\b[^>]*chart:class=\")chart:line\"" => s"\1chart:bar\"")
    k = 0
    o.text = replace(o.text, r"<chart:series\b[^>]*>" => m -> (k += 1; k == n ?
        replace(replace(m, r" chart:attached-axis=\"[^\"]*\"" => ""), r"chart:class=\"[^\"]*\"" => "chart:attached-axis=\"secondary-y\" chart:class=\"chart:line\"") : m))
    # each series drawn as its group is, in its own colour, as addSeries draws them: the columns
    # filled without an outline, the line stroked (a column's style has no stroke, which hides a line)
    styles = [m.captures[1] for m in eachmatch(r"<chart:series\b[^>]*chart:style-name=\"([^\"]*)\"", o.text)]
    for (j, st) in enumerate(styles)
        sm = match(Regex("<style:style style:name=\"" * st * "\"[^>]*>.*?</style:style>", "s"), o.text)
        sm === nothing && continue
        g = match(r"<style:graphic-properties\b[^>]*?(?:/>|>.*?</style:graphic-properties>)"s, sm.match)
        cm = g === nothing ? nothing : match(r"draw:fill-color=\"([^\"]*)\"", g.match)
        col = cm === nothing ? _PALETTE[mod1(j, length(_PALETTE))] : cm.captures[1]
        gp = j == n ? """<style:graphic-properties svg:stroke-width="0.08cm" svg:stroke-color="$col" draw:fill-color="$col"/>""" :
                      """<style:graphic-properties draw:stroke="none" draw:fill-color="$col"/>"""
        new = g === nothing ? replace(sm.match, r"(</style:style>)$" => SubstitutionString(gp * "\\1")) : replace(sm.match, g.match => gp)
        o.text = replace(o.text, sm.match => new; count = 1)
    end
    _secondary_y!(o)
    return c
end

"""
    deleteChart(c::AbstractChart) -> Nothing

Removes a chart: its frame and, at the next save, its object. A chart anchored to the page (not
to a cell) can't be removed, as pictures on the page can't.
"""
function deleteChart(c::AbstractChart)
    xf = c.package
    _require_writable(xf, "delete a chart")
    f = _frame(c)
    ws = f.ws
    # a chart sheet's chart (phase 8 step 7): its sheet, an ordinary sheet, stays
    if ws.pagecharts !== nothing && (k = findfirst(img -> img.object == c.name, ws.pagecharts)) !== nothing
        deleteat!(ws.pagecharts, k)
        delete!(xf.chartobjs, c.name)
        return nothing
    end
    rc = (row_number(CellRef(f.from)), column_number(CellRef(f.from)))
    # a flat file's own chart (phase 8 step 9): its frame goes at the save (its inline object found there)
    added = ws.frames !== nothing && haskey(ws.frames, rc) && any(img -> img.object == c.name, ws.frames[rc].added)
    if !added && xf.container !== nothing && xf.container.zip === nothing
        _editable(c).text = ""
        return nothing
    end
    if ws.frames !== nothing && haskey(ws.frames, rc)
        fe = ws.frames[rc]
        k = findfirst(img -> img.object == c.name, fe.added)
        if k !== nothing
            deleteat!(fe.added, k)
            delete!(xf.chartobjs, c.name)
            _touch_cell!(ws, rc...)
            return nothing
        end
    end
    _is_page_frame(ws, c.name) &&
        throw(ODSError("The chart `$(c.name)` is anchored to the page, and can't be removed here (as pictures on the page can't)."))
    fe = _frame_edit!(ws, rc...)
    k = findfirst(m -> _href_object(m.first) == c.name, fe.moved)   # a frame a delete moved here
    k === nothing ? push!(fe.objremoved, c.name) : deleteat!(fe.moved, k)
    delete!(xf.chartobjs, c.name)
    _touch_cell!(ws, rc...)
    return nothing
end

_is_page_frame(ws, name) = any(ff -> ff.row == 0 && _href_object(ff.xml) == name, _file_frames(ws))

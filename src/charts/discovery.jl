# Finding a workbook's charts as they are now, and reading their objects (phase 8 step 3). A chart is a
# frame holding a `draw:object` (F-079): in a zipped file the object is a directory of parts
# (`Object 1/content.xml`), in a flat file it is inline. The frames are the sheets' file frames (their
# own or a copy's text, with their cells mapped through the operations since) and the frames a delete
# or a sort moved (phase 6). An object's references are replayed through the structural operations, as
# a patched save replays them.

# One chart frame: its sheet, its object's name, where it is, its XML now, and its frame's draw:name.
struct _ChartFrame
    ws::Worksheet
    name::String
    from::String
    to::String
    xml::String
    framename::String
end

_cellname(r::Int, c::Int) = string(SheetCore.encode_column_number(c), r)
_attr(x::AbstractString, name::AbstractString) =
    (m = match(Regex("\\b" * name * "=\"([^\"]*)\""), SubString(x, 1, something(findfirst('>', x), ncodeunits(x))));
     m === nothing ? nothing : XML.unescape(String(m.captures[1])))

const _OBJ_HREF = r"<draw:object\b[^>]*?\bxlink:href=\"\./([^\"/]+)\""
_href_object(x::AbstractString) = (m = match(_OBJ_HREF, x); m === nothing ? nothing : XML.unescape(String(m.captures[1])))
_is_chart_frame(x::AbstractString) = startswith(x, "<draw:frame") && occursin("<draw:object", x)

# The workbook's chart frames, sheet by sheet in order, each sheet's in the file's order (the page's
# first), then those moved to cells. A flat file's objects have no names: they are named as a zipped
# file would name them, `Object 1`, `Object 2`… in this order.
function _chart_frames(xf::ODSFile; positions::Bool = true)
    out = _ChartFrame[]
    flat = xf.container !== nothing && xf.container.zip === nothing
    ops = xf.ops
    k = 0
    for ws in _sheets(xf)
        now(x) = ws.opstart >= length(ops) ? x : _rewritten(x, ops[ws.opstart+1:end])
        found = Tuple{Int,Int,_ChartFrame}[]
        for ff in (ws.entry === nothing ? FileFrame[] : _file_frames(ws))
            _is_chart_frame(ff.xml) || continue
            if ff.row == 0 && !positions
                r = c = er = ec = 1
            elseif ff.row == 0                           # the page: from where its position takes it
                x = something(_attr_cm(ff.xml, "svg:x"), 0.0); y = something(_attr_cm(ff.xml, "svg:y"), 0.0)
                r = _line_at(ws, 2, 1, y); c = _line_at(ws, 1, 1, x)
                er, ec = _frame_end(ws, replace(ff.xml, r"\bsvg:[xy]=\"[^\"]*\"" => ""), r, c, false)
            else
                r = _current_line(ws.rowmap, ff.row); c = _current_line(ws.colmap, ff.col)
                (r == 0 || c == 0 || _sort_cleared(ws, r, c)) && continue
                er, ec = _frame_end(ws, ff.xml, r, c, true)
                # a chart deleted (phase 8 step 5)
                fe = ws.frames === nothing ? nothing : get(ws.frames, (r, c), nothing)
                fe !== nothing && something(_href_object(ff.xml), "") in fe.objremoved && continue
            end
            x = flat ? now(ff.xml) : ff.xml
            push!(found, (0, 0, _ChartFrame(ws, flat ? "" : something(_href_object(ff.xml), ""), _cellname(r, c),
                                            _cellname(er, ec), x, something(_attr(ff.xml, "draw:name"), ""))))
        end
        if ws.frames !== nothing
            for ((r, c), fe) in sort!(collect(ws.frames); by = first)
                for mv in fe.moved
                    _is_chart_frame(mv.first) || continue
                    x = _moved_now(ws, mv)
                    er, ec = _frame_end(ws, x, r, c, false)
                    push!(found, (r, c, _ChartFrame(ws, flat ? "" : something(_href_object(x), ""), _cellname(r, c),
                                                    _cellname(er, ec), flat ? x : mv.first, something(_attr(x, "draw:name"), ""))))
                end
            end
        end
        # charts added here (phase 8 step 5): their frames are the cells', their objects named
        added = _ChartFrame[]
        if ws.frames !== nothing
            for ((r, c), fe) in sort!(collect(ws.frames); by = first), img in fe.added
                isempty(img.object) && continue
                push!(added, _ChartFrame(ws, img.object, _cellname(r, c), _cellname(img.torow, img.tocol), "", ""))
            end
        end
        # a chart sheet's chart (phase 8 step 7): on the page, from A1 to the cell its size reaches
        if ws.pagecharts !== nothing
            for img in ws.pagecharts
                er, ec = _page_end_cell(ws, img.width, img.height)
                push!(added, _ChartFrame(ws, img.object, "A1", _cellname(er, ec), "", ""))
            end
        end
        for (_, _, f) in found
            k += 1
            # a flat file's own chart deleted (phase 8 step 9): skipped, the others keep their names
            flat && (o = get(xf.chartobjs, "Object $k", nothing); o !== nothing && !isempty(o.flatorig) && isempty(o.text)) && continue
            push!(out, flat ? _ChartFrame(f.ws, "Object $k", f.from, f.to, f.xml, f.framename) : f)
        end
        append!(out, added)
    end
    return out
end

# The cell a page-anchored frame of `w` × `h` cm from the page's corner ends in.
function _page_end_cell(ws, w, h)
    c, x = 1, _col_cm(ws, 1)
    while x < w
        c += 1; x += _col_cm(ws, c)
    end
    r, y = 1, _row_cm(ws, 1)
    while y < h
        r += 1; y += _row_cm(ws, r)
    end
    return r, c
end

# The object's content.xml now: a chart added or edited here, from the model; a zipped file's part (a
# copy's, its source's) with the structural operations replayed; a flat file's inline document.
function _object_text(f::_ChartFrame)
    xf = get_odsfile(f.ws)
    haskey(xf.chartobjs, f.name) && return _chart_text_now(xf, f.name)
    if xf.container.zip === nothing
        m = match(r"<office:document\b.*</office:document>"s, f.xml)
        m === nothing && throw(ODSError("The chart `$(f.name)` on sheet `$(f.ws.name)` holds no object."))
        return String(m.match)
    end
    part = _object_source(xf, f.name) * "/content.xml"
    part in partnames(xf.container) || throw(ODSError("The chart `$(f.name)` on sheet `$(f.ws.name)` has no part `$part`."))
    t = read_part_text(xf.container, part)
    return isempty(xf.ops) ? t : _rewritten(t, xf.ops)
end

# A chart's object, parsed: its `chart:chart` element and its automatic styles (name => every
# property of the style's property elements).
struct _ChartDoc
    chart::XML.Node
    styles::Dict{String,Dict{String,String}}
    text::String                 # the object's content.xml (its number styles are read from it)
end

_elements(n) = (c for c in XML.children(n) if XML.nodetype(c) === XML.Element)
function _first(n, tag::AbstractString)
    for c in _elements(n)
        XML.tag(c) == tag && return c
        d = _first(c, tag)
        d === nothing || return d
    end
    return nothing
end
_children(n, tag::AbstractString) = [c for c in _elements(n) if XML.tag(c) == tag]
_get(n, name::AbstractString) = (a = XML.attributes(n); a === nothing ? nothing : get(a, name, nothing))

function _chart_doc(text::AbstractString)
    doc = parse(XML.Node, String(text))
    chart = _first(doc, "chart:chart")
    chart === nothing && throw(ODSError("The object holds no chart."))
    styles = Dict{String,Dict{String,String}}()
    auto = _first(doc, "office:automatic-styles")
    if auto !== nothing
        for s in _children(auto, "style:style")
            nm = _get(s, "style:name")
            nm === nothing && continue
            d = Dict{String,String}()
            for p in _elements(s)
                for (k, v) in something(XML.attributes(p), Dict{String,String}())
                    d[k] = v
                end
                # a theme colour (`loext:fill-complex-color loext:theme-type="accent1"`, F-082)
                for cc in _elements(p)
                    t = _get(cc, "loext:theme-type")
                    t === nothing || (d["@" * XML.tag(cc)] = t)
                end
            end
            dsn = _get(s, "style:data-style-name")
            dsn === nothing || (d["style:data-style-name"] = dsn)
            styles[nm] = d
        end
    end
    return _ChartDoc(chart, styles, String(text))
end

_style(doc::_ChartDoc, n) = (s = _get(n, "chart:style-name"); s === nothing ? Dict{String,String}() : get(doc.styles, s, Dict{String,String}()))

# The handle of a chart frame: a ChartEx for a histogram (F-080), else a Chart.
function _handle(f::_ChartFrame, doc::Union{Nothing,_ChartDoc} = nothing)
    xf = get_odsfile(f.ws)
    doc === nothing && (doc = try _chart_doc(_object_text(f)) catch; nothing end)
    T = doc !== nothing && _get(doc.chart, "loext:class") == "loext:histogram" ? ChartEx : Chart
    return T(xf, f.name * "/content.xml", f.name, nothing, f.ws.name, f.from, f.to)
end

# A handle's frame, found again (a handle never goes stale: its object's name is its key).
function _frame(c::AbstractChart)
    for f in _chart_frames(c.package; positions = false)
        f.name == c.name && return f
    end
    throw(ODSError("The chart `$(c.name)` is no longer in the workbook."))
end
_doc(c::AbstractChart) = _chart_doc(_object_text(_frame(c)))

"""
    getCharts(ws::Worksheet) -> Vector{AbstractChart}
    getCharts(xf::ODSFile) -> Vector{AbstractChart}

The charts on a sheet, or in a file (sheet by sheet), as they are now: those made in LibreOffice,
those it made when it opened a file in another format, and those added here. A histogram is a [`ChartEx`](@ref), the others are
[`Chart`](@ref)s. A chart anchored to the page reports the cells its position falls in.
"""
getCharts(xf::ODSFile) = AbstractChart[_handle(f) for f in _chart_frames(xf)]
getCharts(ws::Worksheet) = AbstractChart[_handle(f) for f in _chart_frames(get_odsfile(ws)) if f.ws === ws]

"""
    getChart(ws::Worksheet, name) -> AbstractChart
    getChart(xf::ODSFile, name) -> AbstractChart

The chart named `name`: its object's name (`"Object 1"`), its path (`"Object 1/content.xml"`), or its
frame's name (the name LibreOffice's Navigator shows). An error lists the names there are.
"""
getChart(xf::ODSFile, name::AbstractString) = _get_chart(_chart_frames(xf), name, "the workbook")
getChart(ws::Worksheet, name::AbstractString) =
    _get_chart(filter(f -> f.ws === ws, _chart_frames(get_odsfile(ws))), name, "sheet `$(ws.name)`")
function _get_chart(frames, name::AbstractString, where::String)
    for f in frames
        (f.name == name || f.name * "/content.xml" == name || (!isempty(f.framename) && f.framename == name)) && return _handle(f)
    end
    names = [f.name for f in frames]
    throw(ODSError("No chart `$name` in $where." * (isempty(names) ? " It has no charts." : " Its charts are " * join(repr.(names), ", ") * ".")))
end

"""
    getChartSchema(c) -> Symbol

`:c` for a [`Chart`](@ref), `:cx` for a [`ChartEx`](@ref).
"""
getChartSchema(::Chart) = :c
getChartSchema(::ChartEx) = :cx

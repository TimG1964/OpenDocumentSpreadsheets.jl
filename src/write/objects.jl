# Embedded objects (charts) in a zipped package: their names, copies and the objects whose frames
# are gone (phase 8 step 2, D-085). A chart is a directory (`Object 1/`, or any name: F-079) that the
# manifest lists with an OpenDocument media type, framed in a sheet by `<draw:object xlink:href=
# "./Object 1">`. A patched save keeps every object a frame still embeds, and only those: LibreOffice
# removes an object with its frame, its sheet or its cells (F-083).

# The names of the objects a zipped file holds: the directories its manifest lists with an
# OpenDocument media type (`application/vnd.oasis.opendocument.chart`).
function _object_dirs(cont)
    out = String[]
    for e in cont.manifest
        (endswith(e.path, "/") && e.path != "/" && startswith(e.mediatype, "application/vnd.oasis.opendocument.")) || continue
        push!(out, e.path[1:prevind(e.path, end)])
    end
    return out
end

# The objects a text's frames embed (`<draw:object … xlink:href="./name">`), unescaped.
const _OBJECT_HREF_RX = r"<draw:object\b[^>]*?\bxlink:href=\"\./([^\"/]+)\""
_object_hrefs(t::AbstractString) = unique!([XML.unescape(m.captures[1]) for m in eachmatch(_OBJECT_HREF_RX, t)])

# The object a copy's object was made from, followed through copies of copies to the file's own
# (`xf.objcopies`: old => new).
function _object_source(xf, name::AbstractString)
    src = String(name)
    while true
        i = findfirst(p -> p.second == src, xf.objcopies)
        i === nothing && return src
        src = xf.objcopies[i].first
    end
end

"""
    _HrefScan(dest, seen)

An `IO` that passes everything to `dest` and notes in `seen` the first path segment of every
`xlink:href="./…"` it sees (`Object 1` for `./Object 1` and `./ObjectReplacements/Object 1`): the
objects a written content.xml still embeds. It is given the large chunks content.xml is written in
(D-048), so it searches each byte once.
"""
mutable struct _HrefScan{T<:IO} <: IO
    dest::T
    seen::Set{String}
    carry::Vector{UInt8}       # the end of the last chunk, which may hold the start of a match
end
_HrefScan(dest::IO, seen::Set{String}) = _HrefScan(dest, seen, UInt8[])

const _HREF_PAT = Vector{UInt8}(codeunits("xlink:href=\"./"))

function _scan!(s::_HrefScan, chunk::AbstractVector{UInt8})
    buf = isempty(s.carry) ? chunk : vcat(s.carry, chunk)
    i = 1
    keepfrom = max(1, length(buf) - length(_HREF_PAT) + 2)
    while (r = findnext(_HREF_PAT, buf, i)) !== nothing
        q = findnext(==(UInt8('"')), buf, last(r) + 1)
        if q === nothing                       # the name runs into the next chunk
            keepfrom = first(r)
            break
        end
        name = XML.unescape(String(buf[last(r)+1:q-1]))
        parts = split(name, '/')
        push!(s.seen, String(parts[1] == "ObjectReplacements" && length(parts) > 1 ? parts[2] : parts[1]))
        i = q + 1
        keepfrom = max(keepfrom, i)
    end
    s.carry = buf[keepfrom:end]
    return
end

function Base.unsafe_write(s::_HrefScan, p::Ptr{UInt8}, n::UInt)
    _scan!(s, unsafe_wrap(Array, p, n))
    return unsafe_write(s.dest, p, n)
end
Base.write(s::_HrefScan, b::UInt8) = (_scan!(s, [b]); write(s.dest, b))
Base.isopen(s::_HrefScan) = isopen(s.dest)
Base.iswritable(::_HrefScan) = true
Base.isreadable(::_HrefScan) = false

#
# Charts added or edited (phase 8 step 5): their objects' text, frames and parts
#

# A chart object's content.xml now: as added or edited, with the structural operations made since
# replayed (a chart's references don't follow sheet copies: `_rewritten` leaves them out, F-083).
function _chart_text_now(xf, name::AbstractString)
    o = xf.chartobjs[name]
    return o.nops >= length(xf.ops) ? o.text : _rewritten(o.text, xf.ops[o.nops+1:end])
end

# The names objects may not take: the file's directories, copies' and charts' objects.
function _taken_objects(xf)
    taken = Set{String}()
    if xf.container !== nothing && xf.container.zip !== nothing
        for n in partnames(xf.container)
            i = findfirst('/', n)
            i === nothing || push!(taken, n[1:i-1])
        end
        foreach(e -> push!(taken, rstrip(e.path, '/')), xf.container.manifest)
    end
    foreach(p -> push!(taken, p.second), xf.objcopies)
    union!(taken, keys(xf.chartobjs))
    # a flat file's charts are named `Object 1`… in order (phase 8): new ones come after them
    if xf.container !== nothing && xf.container.zip === nothing
        for k in 1:count("<draw:object", xf.content)
            push!(taken, "Object $k")
        end
    end
    return taken
end
function _new_object_name(xf)
    taken = _taken_objects(xf)
    k = 1
    while "Object $k" in taken
        k += 1
    end
    return "Object $k"
end

# An object's content.xml as a flat file's inline document (`office:document`, with its media type).
function _inline_object(text::AbstractString, styles::AbstractString = "")
    t = replace(String(text), r"^<\?xml[^>]*\?>\s*" => "")
    # the object's own styles (line dashes) inline, before its automatic styles
    s = match(r"<office:styles>(.*?)</office:styles>"s, styles)
    if s !== nothing                     # into the object's own styles, if it has them (a flat file's chart)
        if occursin("</office:styles>", t)
            t = replace(t, "</office:styles>" => s.captures[1] * "</office:styles>"; count = 1)
        elseif occursin("<office:styles/>", t)
            t = replace(t, "<office:styles/>" => s.match; count = 1)
        else
            t = replace(t, "<office:automatic-styles" => s.match * "<office:automatic-styles"; count = 1)
        end
    end
    t = replace(t, r"^<office:document-content\b" => "<office:document office:mimetype=\"application/vnd.oasis.opendocument.chart\"")
    return replace(t, r"</office:document-content>\s*$" => "</office:document>")
end

# A chart's frame (an `ImageData` with an object): anchored in its first cell and resizing with its cells
# up to the last, as LibreOffice's import places XLSX.jl's (F-079); its object referred to (zipped) or
# inline (flat).
function _chart_frame_xml(io::IO, ws, img)
    xf = get_odsfile(ws)
    print(io, "<draw:frame table:end-cell-address=\"")
    _escape_attr(io, SheetCore.quoteit(ws.name) * "." * string(SheetCore.encode_column_number(img.tocol), img.torow))
    print(io, "\" table:end-x=\"", _cm(img.endx), "\" table:end-y=\"", _cm(img.endy), "\" svg:width=\"", _cm(img.width),
          "\" svg:height=\"", _cm(img.height), "\" svg:x=\"0cm\" svg:y=\"0cm\"><draw:object")
    if _links_flat(xf)
        print(io, ">", _inline_object(_chart_text_now(xf, img.object), xf.chartobjs[img.object].styles), "</draw:object>")
    else
        print(io, " xlink:href=\"./")
        _escape_attr(io, img.object)
        print(io, "\" xlink:type=\"simple\" xlink:show=\"embed\" xlink:actuate=\"onLoad\"/>")
    end
    print(io, "</draw:frame>")
end

# A sheet's charts anchored to the page (a chart sheet's, phase 8 step 7): in `table:shapes`, at the
# page's corner, as LibreOffice's import writes a chart sheet's chart (F-081).
function _page_charts_xml(io::IO, ws)
    pc = ws.pagecharts
    (pc === nothing || isempty(pc)) && return
    xf = get_odsfile(ws)
    print(io, "<table:shapes>")
    for img in pc
        print(io, "<draw:frame draw:z-index=\"0\" svg:width=\"", _cm(img.width), "\" svg:height=\"", _cm(img.height),
              "\" svg:x=\"0cm\" svg:y=\"0cm\"><draw:object")
        if _links_flat(xf)
            print(io, ">", _inline_object(_chart_text_now(xf, img.object), xf.chartobjs[img.object].styles), "</draw:object>")
        else
            print(io, " xlink:href=\"./")
            _escape_attr(io, img.object)
            print(io, "\" xlink:type=\"simple\" xlink:show=\"embed\" xlink:actuate=\"onLoad\"/>")
        end
        print(io, "</draw:frame>")
    end
    print(io, "</table:shapes>")
end

# The parts of the charts added (zipped files): each object's content.xml and its manifest entry,
# written only when a frame still embeds it (`keep`).
function _chart_parts(xf, keepif::Function)
    parts = PackagePart[]
    dirs = Set(_object_dirs_of(xf))
    names = xf.container === nothing || xf.container.zip === nothing ? Set{String}() : Set(partnames(xf.container))
    for name in sort!(collect(keys(xf.chartobjs)))
        o = xf.chartobjs[name]
        # a file's chart, edited: its own parts are replaced (a styles.xml added if it had none)
        if name in dirs
            isempty(o.styles) || (name * "/styles.xml") in names ||
                push!(parts, PackagePart(name * "/styles.xml", o.styles; mediatype = "text/xml", keep = keepif(name)))
            continue
        end
        push!(parts, PackagePart(name * "/content.xml", _chart_text_now(xf, name); mediatype = "text/xml", keep = keepif(name)))
        isempty(o.styles) || push!(parts, PackagePart(name * "/styles.xml", o.styles; mediatype = "text/xml", keep = keepif(name)))
        push!(parts, manifest_entry(name * "/", "application/vnd.oasis.opendocument.chart"; keep = keepif(name)))
    end
    return parts
end
_object_dirs_of(xf) = xf.container === nothing || xf.container.zip === nothing ? String[] : _object_dirs(xf.container)

# Charts added or edited follow every structural operation at once (as the model's other references
# do); the operation is logged after this, so it counts as applied.
function _rewrite_chart_refs!(xf, op)
    isempty(xf.chartobjs) && return
    n = length(xf.ops) + (isnewfile(xf) ? 0 : 1)
    for (name, o) in xf.chartobjs
        o.text = _rewritten(_chart_text_now(xf, name), Any[op])
        o.nops = n
    end
    return
end

# A copy of a sheet made here: its charts' frames get new objects, with the source's text (a copy's
# chart keeps pointing at the source, F-083).
function _copy_chart_frames!(xf, ws)
    imgs = ImageData[]
    ws.frames === nothing || for fe in values(ws.frames); append!(imgs, fe.added); end
    ws.pagecharts === nothing || append!(imgs, ws.pagecharts)
    for img in imgs
        (isempty(img.object) || !haskey(xf.chartobjs, img.object)) && continue
        new = _new_object_name(xf)
        xf.chartobjs[new] = ChartObj(_chart_text_now(xf, img.object), length(xf.ops), xf.chartobjs[img.object].styles)
        img.object = new
    end
    return
end

# Whether a file's chart was deleted (its frame removed from its cell: `FrameEdit.objremoved`).
_charts_removed(xf) = any(ws -> ws.frames !== nothing && any(fe -> !isempty(fe.objremoved), values(ws.frames)), _sheets(xf))

# A flat file's patched document (phase 8 step 9): its own charts changed or deleted are put in place.
# The document is written as before, its inline objects as the operations leave them; each changed
# chart's object, as it was when first changed and then replayed through the later operations, is found
# there and replaced by the chart (every copy of it: a sheet copied since carries it), or its frame
# removed. Without such charts the document streams as before.
function _write_flat_patched(io::IO, xf::ODSFile; display::Bool = true)
    own = [(name, o) for (name, o) in xf.chartobjs if !isempty(o.flatorig)]
    isempty(own) && return write_patched_content(io, xf; display)          # (`io` is the flat writer's chunked stream)
    buf = IOBuffer()
    _write_chunked(o -> write_patched_content(o, xf; display), buf)
    s = String(take!(buf))
    for (name, o) in sort!(own; by = first)
        old = o.flatops >= length(xf.ops) ? o.flatorig : _rewritten(o.flatorig, xf.ops[o.flatops+1:end])
        occursin(old, s) || throw(ODSError("The chart `$name` was changed, but its object isn't where the file had it: it can't be saved."))
        if isempty(o.text)                                   # deleted: its frame goes
            while (r = findfirst(old, s)) !== nothing
                a = findprev("<draw:frame", s, first(r)); b = findnext("</draw:frame>", s, last(r))
                (a === nothing || b === nothing) && break
                s = s[1:prevind(s, first(a))] * s[nextind(s, last(b)):end]
            end
        else
            s = replace(s, old => _inline_object(_chart_text_now(xf, name), o.styles))
        end
    end
    write(io, s)
    return nothing
end

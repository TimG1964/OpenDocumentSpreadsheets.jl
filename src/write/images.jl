# Pictures (phase 6 step 5, D-074): XLSX.jl's `addImage`, `getImages` and `deleteImage`, on
# LibreOffice's frames (F-060):
#   - a picture added is a `draw:frame` holding a `draw:image`, anchored in its first cell and resizing
#     with its cells up to the last (`table:end-cell-address`), as LibreOffice's import places XLSX.jl's;
#     its bytes are a `Pictures/` part of a zipped file (one per distinct picture, in the manifest), or
#     `office:binary-data` in a flat one. LibreOffice needs no style, name or z-order (experiment 031 part D)
#   - a delete removes a picture lying wholly in the deleted rows or columns, and moves one reaching
#     beyond them into the cell now at its place, with its offsets and size (F-060, the gap D-055 left)
#   - LibreOffice has no pictures in cells: `inCell` is an error.
# The API follows XLSX.jl 0.13.4 (src/images.jl), MIT License, Copyright (c) 2018-2026 Felipe Noronha
# Tavares and other contributors: names, keywords, checks, return shapes, the cells a picture covers
# (64 × 20 pixels a cell), and the reading of a picture's type and size (`detect_image_ext`,
# `image_dimensions`).

# XLSX.jl's fields, then the frame's alt text and description, LibreOffice's (D-076).
const ImageInfo = NamedTuple{(:sheet, :media_name, :from, :to, :alt, :description),NTuple{6,String}}

#
# The picture: its type and size (XLSX.jl's `detect_image_ext`, `image_dimensions`)
#

function _image_type(b::Vector{UInt8})
    length(b) >= 8 && b[1:8] == UInt8[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] && return (".png", "image/png")
    length(b) >= 2 && b[1] == 0xFF && b[2] == 0xD8 && return (".jpg", "image/jpeg")
    length(b) >= 4 && b[1:4] == UInt8[0x47, 0x49, 0x46, 0x38] && return (".gif", "image/gif")
    throw(ODSError("Unsupported or unknown image format: give a PNG, JPEG or GIF."))
end

function _image_dims(b::Vector{UInt8})
    if length(b) >= 24 && b[1] == 0x89
        return (Int(b[17]) << 24 | Int(b[18]) << 16 | Int(b[19]) << 8 | Int(b[20]),
                Int(b[21]) << 24 | Int(b[22]) << 16 | Int(b[23]) << 8 | Int(b[24]))
    elseif length(b) >= 10 && b[1] == 0x47
        return (Int(b[7]) | Int(b[8]) << 8, Int(b[9]) | Int(b[10]) << 8)
    else
        i = 3
        while i + 8 <= length(b)
            b[i] == 0xFF || break
            m = b[i+1]
            0xC0 <= m <= 0xC3 && return (Int(b[i+7]) << 8 | Int(b[i+8]), Int(b[i+5]) << 8 | Int(b[i+6]))
            i += 2 + (Int(b[i+2]) << 8 | Int(b[i+3]))
        end
        throw(ODSError("Could not find the size of the JPEG picture (no SOF marker)."))
    end
end

_hex8(x::Integer) = uppercase(string(x; base = 16, pad = 8))

# Its part name, in LibreOffice's pattern (F-060: `1000000<t>` + width + height in pixels + a checksum,
# here the first bytes of its SHA-1): the same picture has the same name, and is stored once.
_picture_name(b::Vector{UInt8}, ext::String, w::Int, h::Int) =
    "Pictures/1000000" * (ext == ".gif" ? "1" : "0") * _hex8(w) * _hex8(h) * uppercase(bytes2hex(sha1(b))[1:8]) * ext

#
# Cell sizes (cm): the column's or row's style, else LibreOffice's defaults
#

const _DEFAULT_COL_CM = 2.258
const _DEFAULT_ROW_CM = 0.452

function _line_cm(ws::Worksheet, family::Int, x::Int)
    f = sheet_formats(ws)
    r = _fmt_at(family == 1 ? f.cols : f.rows, x)
    r === nothing && return family == 1 ? _DEFAULT_COL_CM : _DEFAULT_ROW_CM
    v = getprop(line_props(get_odsfile(ws).styles, family, r.style), family == 1 ? "style:column-width" : "style:row-height")
    cm = v === nothing ? nothing : _length_cm(v)
    return cm === nothing ? (family == 1 ? _DEFAULT_COL_CM : _DEFAULT_ROW_CM) : cm
end
_col_cm(ws::Worksheet, c::Int) = _line_cm(ws, 1, c)
_row_cm(ws::Worksheet, r::Int) = _line_cm(ws, 2, r)

_cm(x::Real) = _fmt_num(round(x; digits = 3)) * "cm"

# The line (from `a`) at which a length `d` cm from the start of line `a` ends.
function _line_at(ws::Worksheet, family::Int, a::Int, d::Float64)
    maxl = family == 1 ? SheetCore.MAX_COLS : SheetCore.MAX_ROWS
    x = a
    while x < maxl
        s = _line_cm(ws, family, x)
        d <= s + 1e-9 && return x
        d -= s
        x += 1
    end
    return maxl
end

#
# Frames written
#

function _image_frame_xml(io::IO, ws::Worksheet, img::ImageData)
    xf = get_odsfile(ws)
    isempty(img.object) || return _chart_frame_xml(io, ws, img)
    print(io, "<draw:frame table:end-cell-address=\"")
    _escape_attr(io, SheetCore.quoteit(ws.name) * "." * string(SheetCore.encode_column_number(img.tocol), img.torow))
    print(io, "\" table:end-x=\"", _cm(img.endx), "\" table:end-y=\"", _cm(img.endy), "\" svg:width=\"", _cm(img.width),
          "\" svg:height=\"", _cm(img.height), "\" svg:x=\"0cm\" svg:y=\"0cm\"><draw:image")
    if _links_flat(xf)
        k = findfirst(m -> m[1] == img.pic, xf.media)
        print(io, " draw:mime-type=\"", img.mime, "\"><office:binary-data>", base64encode(xf.media[k][3]), "</office:binary-data>")
    else
        print(io, " xlink:href=\"", img.pic, "\" xlink:type=\"simple\" xlink:show=\"embed\" xlink:actuate=\"onLoad\" draw:mime-type=\"", img.mime, "\">")
    end
    print(io, "<text:p/></draw:image>")
    isempty(img.title) || (print(io, "<svg:title>"); _escape_text(io, img.title); print(io, "</svg:title>"))
    isempty(img.desc) || (print(io, "<svg:desc>"); _escape_text(io, img.desc); print(io, "</svg:desc>"))
    print(io, "</draw:frame>")
end

# A frame moved to a cell (by a delete, or a sort: F-060, F-072), its XML with the structural edits
# made since it was taken (`m.second`: how many of the file's operations it has) replayed on it.
_moved_now(ws::Worksheet, m::Pair{String,Int}) =
    (xf = get_odsfile(ws); isnewfile(xf) ? m.first : _rewritten(m.first, xf.ops[m.second+1:end]))

# The frames a cell edit adds: those a delete or a sort moved here, then the pictures added.
function _frames_xml(ws::Worksheet, fe::FrameEdit)
    io = IOBuffer()
    for m in fe.moved
        print(io, _moved_now(ws, m))
    end
    for img in fe.added
        _image_frame_xml(io, ws, img)
    end
    return String(take!(io))
end

# Whether a workbook's new XML has frames (for the namespaces it declares).
_has_frames(xf::ODSFile) = any(ws -> (ws.frames !== nothing && !isempty(ws.frames)) || (ws.pagecharts !== nothing && !isempty(ws.pagecharts)), _sheets(xf))

# The pictures added that some frame still uses: (Pictures/name, media type, bytes).
function _used_media(xf::ODSFile)
    used = Set{String}()
    for ws in _sheets(xf)
        ws.frames === nothing && continue
        for fe in values(ws.frames), img in fe.added
            isempty(img.object) && push!(used, img.pic)
        end
    end
    return [m for m in xf.media if m[1] in used]
end

#
# The shapes the file holds (read on first use)
#

const _HREF_RX = r"\bxlink:href=\"([^\"]*)\""
_attr_cm(xml::AbstractString, name::AbstractString) =
    (v = _attr_in(SubString(xml, 1, something(findfirst('>', xml), ncodeunits(xml))), name); v === nothing ? nothing : _length_cm(v))

# A frame holding a picture. A chart's frame also holds a `draw:image`, its replacement picture, after
# its `draw:object` (F-079): it is no picture.
_is_picture(xml::AbstractString) = startswith(xml, "<draw:frame") && occursin("<draw:image", xml) && !occursin("<draw:object", xml)

function _file_frames(ws::Worksheet)
    ws.fileframes === nothing || return ws.fileframes
    out = FileFrame[]
    # a table with no shapes isn't walked: its span is found by XML.jl's byte scanner, and searched
    # for `<draw:` and `<dr3d:` (a walk of every row and cell is what costs)
    if ws.entry !== nothing && _table_has_shapes(ws)
        node = ws.entry.node
        src = parent(XML.sourcetext(node))
        row = Ref(0)
        add(r, c, k, sp) = (x = String(SubString(src, first(sp), last(sp)));
                            m = match(_HREF_RX, x);
                            push!(out, FileFrame(r, c, k, m === nothing ? "" : XML.unescape(m.captures[1]), x)))
        walk(n::XML.LazyNode) = begin
            c = XML.Cursor(n)
            XML.next!(c)
            XML.for_each_child!(c) do ch
                XML.nodetype(ch) === XML.Element || return
                t = XML.tag(ch)
                if t == "table:shapes"                       # anchored to the page
                    sc = XML.Cursor(XML.LazyNode(ch)); XML.next!(sc)
                    k = 0
                    XML.for_each_child!(sc) do g
                        XML.nodetype(g) === XML.Element || return
                        sp = XML.sourcespan(XML.LazyNode(g))
                        add(0, 0, _is_picture(SubString(src, first(sp), last(sp))) ? (k += 1) : 0, sp)
                        XML.skip_element!(g)
                    end
                elseif t == "table:table-row"
                    nrows = min(_repeat_attr(ch, "table:number-rows-repeated"), SheetCore.MAX_ROWS - row[])
                    r0 = row[] + 1
                    row[] += nrows
                    rc = XML.Cursor(XML.LazyNode(ch)); XML.next!(rc)
                    col = 0
                    XML.for_each_child!(rc) do cc
                        XML.nodetype(cc) === XML.Element || return
                        if XML.tag(cc) in ("table:table-cell", "table:covered-table-cell")
                            n = _repeat_attr(cc, "table:number-columns-repeated")
                            cl = XML.LazyNode(cc)
                            sp = XML.sourcespan(cl)
                            if occursin("<draw:", SubString(src, first(sp), last(sp))) || occursin("<dr3d:", SubString(src, first(sp), last(sp)))
                                ac = XML.Cursor(cl); XML.next!(ac)
                                k = 0
                                XML.for_each_child!(ac) do g
                                    XML.nodetype(g) === XML.Element || return
                                    tg = XML.tag(g)
                                    if startswith(tg, "draw:") || startswith(tg, "dr3d:")
                                        gs = XML.sourcespan(XML.LazyNode(g))
                                        pic = _is_picture(SubString(src, first(gs), last(gs)))
                                        pic && (k += 1)
                                        add(r0, col + 1, pic ? k : 0, gs)        # (LibreOffice never repeats one)
                                    end
                                    XML.skip_element!(g)
                                end
                            end
                            col += n
                        end
                        XML.skip_element!(cc)
                    end
                elseif t in _ROW_CONTAINERS
                    walk(XML.LazyNode(ch))
                end
                XML.skip_element!(ch)
            end
        end
        walk(node)
    end
    ws.fileframes = out
    return out
end

# The cell a frame ends in (current numbers): its end cell, mapped (`orig`: given in original numbers),
# else where its offsets and size take it from (r, c).
function _frame_end(ws::Worksheet, xml::AbstractString, r::Int, c::Int, orig::Bool)
    ea = _attr_in(SubString(xml, 1, something(findfirst('>', xml), ncodeunits(xml))), "table:end-cell-address")
    if ea !== nothing
        cell = last(split(ea, '.'))
        if is_valid_cellname(cell)
            ref = CellRef(cell)
            er, ec = row_number(ref), column_number(ref)
            if orig
                er = _current_line(ws.rowmap, er); ec = _current_line(ws.colmap, ec)
            end
            (er > 0 && ec > 0) && return (er, ec)
        end
    end
    x = something(_attr_cm(xml, "svg:x"), 0.0); y = something(_attr_cm(xml, "svg:y"), 0.0)
    w = something(_attr_cm(xml, "svg:width"), 0.0); h = something(_attr_cm(xml, "svg:height"), 0.0)
    return (_line_at(ws, 2, max(r, 1), y + h), _line_at(ws, 1, max(c, 1), x + w))
end

#
# The pictures of a sheet, as getImages gives them
#

_media_name(href::AbstractString) = isempty(href) ? "" : String(last(split(href, '/')))

# A frame's alt text and description (its `svg:title` and `svg:desc`), "" where it has none.
function _frame_alt(xml::AbstractString)
    t = match(r"<svg:title>(.*?)</svg:title>"s, xml); d = match(r"<svg:desc>(.*?)</svg:desc>"s, xml)
    return (t === nothing ? "" : XML.unescape(String(t.captures[1])), d === nothing ? "" : XML.unescape(String(d.captures[1])))
end

function _sheet_images(ws::Worksheet)
    out = Tuple{Int,Int,ImageInfo,Symbol,Int}[]     # (row, col, info, kind, k): kind :file, :moved, :added
    name(r, c) = string(SheetCore.encode_column_number(c), r)
    frames = ws.frames
    for ff in _file_frames(ws)
        ff.k == 0 && continue
        if ff.row == 0                               # the page: from where its position takes it
            x = something(_attr_cm(ff.xml, "svg:x"), 0.0); y = something(_attr_cm(ff.xml, "svg:y"), 0.0)
            r = _line_at(ws, 2, 1, y); c = _line_at(ws, 1, 1, x)
            er, ec = _frame_end(ws, replace(ff.xml, r"\bsvg:[xy]=\"[^\"]*\"" => ""), r, c, false)
            push!(out, (r, c, ImageInfo((ws.name, _media_name(ff.href), name(r, c), name(er, ec), _frame_alt(ff.xml)...)), :page, ff.k))
            continue
        end
        r = _current_line(ws.rowmap, ff.row); c = _current_line(ws.colmap, ff.col)
        (r == 0 || c == 0 || _sort_cleared(ws, r, c)) && continue
        fe = frames === nothing ? nothing : get(frames, (r, c), nothing)
        fe !== nothing && ff.k in fe.removed && continue
        er, ec = _frame_end(ws, ff.xml, r, c, true)
        push!(out, (r, c, ImageInfo((ws.name, _media_name(ff.href), name(r, c), name(er, ec), _frame_alt(ff.xml)...)), :file, ff.k))
    end
    if frames !== nothing
        for ((r, c), fe) in frames
            for (j, mv) in enumerate(fe.moved)
                x = mv.first
                _is_picture(x) || continue
                m = match(_HREF_RX, x)
                er, ec = _frame_end(ws, _moved_now(ws, mv), r, c, false)
                push!(out, (r, c, ImageInfo((ws.name, _media_name(m === nothing ? "" : XML.unescape(m.captures[1])), name(r, c), name(er, ec), _frame_alt(x)...)), :moved, j))
            end
            for (j, img) in enumerate(fe.added)
                isempty(img.object) || continue                 # a chart's frame (phase 8)
                push!(out, (r, c, ImageInfo((ws.name, _media_name(img.pic), name(r, c), name(img.torow, img.tocol), img.title, img.desc)), :added, j))
            end
        end
    end
    sort!(out; by = x -> (x[1], x[2]))
    return out
end

#
# The API
#

# One cell of a sheet, made to exist in the model and marked edited (as `_set_note!` does).
function _touch_cell!(ws::Worksheet, r::Int, c::Int)
    f = sheet_formats(ws)
    if cell_data(_cached_store(ws), r, c) === nothing && _fmt_cell(f, r, c) === nothing
        _rows_set!(f.cells, r, c, CellData(CK_EMPTY, 0x00, Int32(effective_style(ws, r, c)), UInt64(0), nothing, nothing, Int32(1), Int32(1)))
    end
    _mark_dirty!(ws, r, c)
    return
end

_frame_edit!(ws::Worksheet, r::Int, c::Int) =
    get!(FrameEdit, ws.frames === nothing ? (ws.frames = Dict{Tuple{Int,Int},FrameEdit}()) : ws.frames, (r, c))

"""
    addImage(sheet, ref, image; size=nothing, inCell=false, alt="", description="") -> NamedTuple
    addImage(sheet, row, col, image; kw...) -> NamedTuple

Insert a picture (PNG, JPEG or GIF, from a file path or an `IOBuffer`, which is left unchanged)
over the cells from `ref`, as LibreOffice's import places XLSX.jl's (F-060, D-074): anchored in
the first cell and resizing with its cells up to the last. For a cell, the picture covers one cell
per 64 pixels of its width and per 20 of its height (its own size, or `size = (width, height)` in
pixels), as in XLSX.jl; for a range (`"B2:D6"`), the range. The picture is stored once in the file,
however many times it is shown.

LibreOffice has no pictures in cells: `inCell=true` is an error. `alt` is the picture's alt text,
which LibreOffice keeps for every picture (its *Text Alternative*, `svg:title`), and `description`
its longer description (`svg:desc`), LibreOffice's own (D-076).

Returns `(sheet, media_name, from, to, alt, description)`. The file must be writable.
"""
function addImage(ws::Worksheet, ref::Union{AbstractString,CellRef,CellRange}, image::Union{AbstractString,IOBuffer};
                  size::Union{Nothing,Tuple{<:Integer,<:Integer}} = nothing, inCell::Bool = false, alt::AbstractString = "",
                  description::AbstractString = "")
    inCell && throw(ODSError("LibreOffice has no pictures in cells (F-060): leave out `inCell`."))
    _require_writable(ws, "add an image")
    rows, cols = _link_block(ref)
    bytes = image isa IOBuffer ? take!(copy(image)) : read(image)
    ext, mime = _image_type(bytes)
    w, h = _image_dims(bytes)
    r, c = first(rows), first(cols)
    if length(rows) == 1 && length(cols) == 1 && !(ref isa CellRange)
        pw, ph = size === nothing ? (w, h) : size
        tr = r + max(1, round(Int, ph / 20)) - 1
        tc = c + max(1, round(Int, pw / 64)) - 1
    else
        tr, tc = last(rows), last(cols)
    end
    (tr <= SheetCore.MAX_ROWS && tc <= SheetCore.MAX_COLS) || throw(ODSError("The picture would reach past the sheet's last cell."))
    xf = get_odsfile(ws)
    pic = _existing_picture(xf, bytes)                  # a picture the file already holds is used again
    if pic === nothing
        pic = _picture_name(bytes, ext, w, h)
        any(m -> m[1] == pic, xf.media) || push!(xf.media, (pic, mime, bytes))
    end
    width = sum(_col_cm(ws, x) for x in c:tc); height = sum(_row_cm(ws, x) for x in r:tr)
    img = ImageData(pic, mime, tr, tc, width, height, _col_cm(ws, tc), _row_cm(ws, tr), String(alt), String(description))
    push!(_frame_edit!(ws, r, c).added, img)
    _touch_cell!(ws, r, c)
    return ImageInfo((ws.name, _media_name(pic), string(SheetCore.encode_column_number(c), r), string(SheetCore.encode_column_number(tc), tr),
                      img.title, img.desc))
end
addImage(ws::Worksheet, row::Integer, col::Integer, image; kw...) = addImage(ws, CellRef(row, col), image; kw...)

"""
    getImages(sheet) -> Vector{NamedTuple}
    getImages(xf::ODSFile) -> Vector{NamedTuple}

The pictures of a sheet, or of every sheet, as `(sheet, media_name, from, to, alt, description)`, by their first
cell: those anchored in cells or to the page, read from the file or added. `to` is the cell a
picture ends in. `media_name` is its part's name in `Pictures/` (`""` for a picture held in a flat
file).
"""
getImages(ws::Worksheet) = ImageInfo[x[3] for x in _sheet_images(ws)]
getImages(xf::ODSFile) = reduce(vcat, (getImages(ws) for ws in _sheets(xf)); init = ImageInfo[])

"""
    deleteImage(sheet, ref) -> Int
    deleteImage(sheet, image::NamedTuple) -> Int

Remove the pictures whose first cell is `ref` (`"B3"`), or the picture `image` (as
[`getImages`](@ref) gives it). Returns how many were removed. Pictures anchored to the page
can't be removed this way. The file must be writable.
"""
function deleteImage(ws::Worksheet, ref::Union{AbstractString,CellRef})
    ref isa AbstractString && !is_valid_cellname(ref) &&
        throw(ODSError("Give the cell an image's top-left corner is in, such as `B3`. Found `$ref`."))
    x = ref isa CellRef ? ref : CellRef(ref)
    return _delete_images!(ws, img -> img[1] == row_number(x) && img[2] == column_number(x))
end
function deleteImage(ws::Worksheet, image::NamedTuple)
    image.sheet == ws.name || throw(ODSError("The image is on sheet `$(image.sheet)`, not `$(ws.name)`."))
    return _delete_images!(ws, img -> img[3] == image)
end

function _delete_images!(ws::Worksheet, pick::Function)
    _require_writable(ws, "delete an image")
    n = 0
    gone = Dict{Tuple{Tuple{Int,Int},Symbol},Vector{Int}}()
    for img in _sheet_images(ws)
        (img[4] !== :page && pick(img)) || continue
        push!(get!(Vector{Int}, gone, ((img[1], img[2]), img[4])), img[5])
        n += 1
    end
    for (((r, c), kind), ks) in gone
        fe = _frame_edit!(ws, r, c)
        if kind === :file
            union!(fe.removed, ks)
        elseif kind === :moved
            deleteat!(fe.moved, sort(ks))
        else
            deleteat!(fe.added, sort(ks))
        end
        _touch_cell!(ws, r, c)
    end
    return n
end

#
# Inserts and deletes (`shift_lines!`)
#

# Before rows or columns d1:d2 (axis) are deleted: the shapes anchored there that reach beyond them,
# which LibreOffice keeps where they are, anchored in the cell now at their place (F-060). Returns
# (other coordinate, XML or ImageData) for the cells at d1 after the delete.
function _rescued_frames(ws::Worksheet, axis::Int, d1::Int, d2::Int)
    out = Tuple{Int,Union{Pair{String,Int},ImageData}}[]
    inside(r, c) = d1 <= (axis == 1 ? r : c) <= d2
    beyond(er, ec) = (axis == 1 ? er : ec) > d2
    other(r, c) = axis == 1 ? c : r
    if ws.entry !== nothing
        frames = ws.frames
        for ff in _file_frames(ws)
            ff.row == 0 && continue
            r = _current_line(ws.rowmap, ff.row); c = _current_line(ws.colmap, ff.col)
            (r == 0 || c == 0 || !inside(r, c) || _sort_cleared(ws, r, c)) && continue
            fe = frames === nothing ? nothing : get(frames, (r, c), nothing)
            fe !== nothing && ff.k > 0 && ff.k in fe.removed && continue
            beyond(_frame_end(ws, ff.xml, r, c, true)...) && push!(out, (other(r, c), ff.xml => ws.opstart))
        end
    end
    if ws.frames !== nothing
        for ((r, c), fe) in ws.frames
            inside(r, c) || continue
            for m in fe.moved
                beyond(_frame_end(ws, _moved_now(ws, m), r, c, false)...) && push!(out, (other(r, c), m))
            end
            for img in fe.added
                beyond(img.torow, img.tocol) && push!(out, (other(r, c), img))
            end
        end
    end
    return out
end

# The frame edits moved with the lines; those of deleted cells go, but for `rescued` (from
# `_rescued_frames`), which join the cells at d1.
function _shift_frames!(ws::Worksheet, axis::Int, at::Int, n::Int, rescued)
    (ws.frames === nothing && (rescued === nothing || isempty(rescued))) && return
    maxl = axis == 1 ? SheetCore.MAX_ROWS : SheetCore.MAX_COLS
    new = Dict{Tuple{Int,Int},FrameEdit}()
    shiftimg!(img) = if axis == 1
        rr = _range_after(img.torow:img.torow, at, n, maxl); img.torow = isempty(rr) ? max(at - 1, 1) : last(rr)
    else
        cc = _range_after(img.tocol:img.tocol, at, n, maxl); img.tocol = isempty(cc) ? max(at - 1, 1) : last(cc)
    end
    if ws.frames !== nothing
        for ((r, c), fe) in ws.frames
            foreach(shiftimg!, fe.added)
            x = _line_after(axis == 1 ? r : c, at, n)
            0 < x <= maxl || continue
            new[axis == 1 ? (x, c) : (r, x)] = fe
        end
    end
    if rescued !== nothing
        for (o, f) in rescued
            k = axis == 1 ? (at, o) : (o, at)
            fe = get!(FrameEdit, new, k)
            if f isa ImageData                       # (already shifted with the cell's other pictures)
                push!(fe.added, f)
            else
                push!(fe.moved, f)
            end
        end
    end
    ws.frames = new
    if rescued !== nothing
        for (o, _) in rescued
            axis == 1 ? _touch_cell!(ws, at, o) : _touch_cell!(ws, o, at)
        end
    end
    return
end

# The `Pictures/` part of a zipped file read that holds exactly `bytes`, or nothing (sizes compared first).
function _existing_picture(xf::ODSFile, bytes::Vector{UInt8})
    (isnewfile(xf) || xf.container.zip === nothing) && return nothing
    z = xf.container.zip
    for (i, n) in enumerate(ZipArchives.zip_names(z))
        startswith(n, "Pictures/") || continue
        ZipArchives.zip_uncompressed_size(z, i) == length(bytes) || continue
        read_bytes(xf.container, n) == bytes && return n
    end
    return nothing
end

# Whether a sheet's original table holds any shape (`<draw:` or `<dr3d:`): none when the document has
# no `<draw:` element at all (`_doc_has_draw`, one fast search per workbook); else its table is scanned.
function _table_has_shapes(ws::Worksheet)
    _doc_has_draw(get_odsfile(ws)) || return false
    t = XML.sourcetext(ws.entry.node)                    # (one search for the table's end)
    src = parent(t); sp = parentindices(t)[1]
    i = first(sp); b = last(sp)
    while (j = findnext('<', src, i)) !== nothing && j < b      # memchr, bounded by the table
        codeunit(src, j + 1) == UInt8('d') && (_bytes_at(src, j + 1, "draw:") || _bytes_at(src, j + 1, "dr3d:")) && return true
        i = j + 1
    end
    return false
end

# Whether the document's content holds a `<draw:` element: found by its rare `w` (memchr), checked
# for `<dra` before and `:` after; cached on the workbook. (A document whose only shapes are 3-D
# `dr3d:` scenes is taken to have none: they go with deleted cells, as before D-074.)
function _doc_has_draw(xf::ODSFile)
    xf.hasdraw === nothing || return xf.hasdraw
    s = xf.content
    n = ncodeunits(s)
    i = 1
    found = false
    while (j = findnext('w', s, i)) !== nothing
        if j >= 5 && j < n && codeunit(s, j - 4) == UInt8('<') && codeunit(s, j - 3) == UInt8('d') &&
           codeunit(s, j - 2) == UInt8('r') && codeunit(s, j - 1) == UInt8('a') && codeunit(s, j + 1) == UInt8(':')
            found = true
            break
        end
        i = j + 1
    end
    xf.hasdraw = found
    return found
end

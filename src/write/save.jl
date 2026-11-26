# Saving: `writeods`, `saveods`, and the parts of a new document.
#
# Adapted from XLSX.jl 0.13.4 (src/save.jl `writexlsx`, `savexlsx`, `_reset_io_for_save!`,
# `_check_overwrite`), MIT License, Copyright (c) 2018-2026 Felipe Noronha Tavares and other
# contributors. A file that was read is saved by patching its parts (D-023); a new one is
# written whole, in ODF 1.4 by default (D-006).

const _NS_DECL = join([" xmlns:$p=\"$u\"" for (p, u) in vcat(_NAMESPACES, [
    "meta" => "urn:oasis:names:tc:opendocument:xmlns:meta:1.0",
    "dc" => "http://purl.org/dc/elements/1.1/",
    "xlink" => "http://www.w3.org/1999/xlink"])])

const _STYLES_BODY = """<office:styles><style:default-style style:family="table-cell"/><style:style style:name="Default" style:family="table-cell"/></office:styles>"""

_generator() = "OpenDocumentSpreadsheets.jl/$(pkgversion(@__MODULE__))"

function _meta_body()
    now = Dates.format(Dates.now(Dates.UTC), "yyyy-mm-ddTHH:MM:SS")
    return "<office:meta><meta:generator>$(_generator())</meta:generator><meta:creation-date>$now</meta:creation-date></office:meta>"
end
# A new file's office:meta, with the document properties set (phase 5 step 11)
_meta_body(::Nothing) = _meta_body()
_meta_body(xf::ODSFile) = xf.meta === nothing ? _meta_body() : _meta_element(xf)

function _write_body(io::IO, xf::ODSFile; display::Bool = true)
    print(io, "<office:body><office:spreadsheet", _wb_protection_attrs_xml(xf), ">")   # structure protection (phase 5 step 9)
    print(io, _rules_xml(xf))                        # validations (phase 6 step 6)
    foreach(ws -> write_table(io, ws; display), xf.sheets)
    isempty(xf.persons.added) || print(io, "<loext:persons>", _persons_xml(xf.persons.added), "</loext:persons>")   # threads' people (phase 6 step 4)
    isempty(xf.names) || print(io, "<table:named-expressions>", _names_xml(xf.names), "</table:named-expressions>")
    dbx = _db_model_xml(xf)                          # tables (phase 6 step 7), after the names (F-062)
    isempty(dbx) || print(io, "<table:database-ranges>", dbx, "</table:database-ranges>")
    print(io, "</office:spreadsheet></office:body>")
    return nothing
end

const _XMLDECL = """<?xml version="1.0" encoding="UTF-8"?>\n"""

# The font faces OpenDocumentSpreadsheets declared (phase 4), and the namespaces content.xml needs:
# svg for them and for notes' sizes, loext for LibreOffice's extensions and threads (phase 6 step 4).
function _faces(xf::ODSFile)
    fx = added_faces_xml(xf.styles)
    lx = _needs_loext(xf.styles) || _needs_protection_loext(xf) || _has_threads(xf) ? " xmlns:loext=\"$_LOEXT_NS\"" : ""
    sx = !isempty(fx) || _has_notes(xf) || _has_frames(xf) ? " xmlns:svg=\"$_SVG_NS\"" : ""
    dx = _has_frames(xf) ? " xmlns:draw=\"$_DRAW_NS\"" : ""         # pictures (phase 6 step 5)
    cx = _has_footers(xf) || _has_cfs(xf) || _has_sparks(xf) ? " xmlns:calcext=\"$_CALCEXT_NS\"" : ""   # tables' totals rows (phase 6 step 7), rules (phase 7)
    return (sx * lx * dx * cx, isempty(fx) ? "" : "<office:font-face-decls>$fx</office:font-face-decls>")
end

# A new file's content.xml, written to `io` as it is made (D-048). The styles come first:
# writing the sheets adds none (styles are added when cells are set or formatted).
function write_new_content(io::IO, xf::ODSFile, version; display::Bool = true)
    svg, faces = _faces(xf)
    print(io, _XMLDECL, "<office:document-content", _NS_DECL, svg, " office:version=\"", version, "\">",
          faces, "<office:automatic-styles>", added_styles_xml(xf.styles, used_styles(xf)), _table_styles_xml(xf), "</office:automatic-styles>")
    _write_body(io, xf; display)
    print(io, "</office:document-content>")
    return nothing
end

# (`named`: more named styles for office:styles, as a streamed file's column formats (D-042)
# or the named styles OpenDocumentSpreadsheets added (D-045); `ns`: namespace declarations they need; `faces`:
# the font faces they name)
new_styles_xml(version, named::AbstractString = "", ns::AbstractString = "", faces::AbstractString = "";
               autos::AbstractString = "", masters::AbstractString = "") =
    string(_XMLDECL, "<office:document-styles", _NS_DECL, ns, " office:version=\"", version, "\">",
           isempty(faces) ? "" : "<office:font-face-decls>$faces</office:font-face-decls>",
           replace(_STYLES_BODY, "</office:styles>" => named * "</office:styles>"),
           isempty(autos) ? "<office:automatic-styles/>" : "<office:automatic-styles>" * autos * "</office:automatic-styles>",
           isempty(masters) ? "<office:master-styles/>" : "<office:master-styles>" * masters * "</office:master-styles>",
           "</office:document-styles>")

"""
    used_styles(xf) -> Union{UsedStyles, Nothing}

The cell, column and row styles the loaded sheets refer to, so that only the added styles in
use are written. `nothing` when OpenDocumentSpreadsheets added none: then nothing is scanned. A
sheet that was never loaded can't refer to an added style; its text is copied as it is.
"""
function used_styles(xf::ODSFile)
    sh = xf.styles.sheet[1]
    (sh === nothing || (isempty(sh.added) && all(ls -> isempty(ls.added), sh.lines))) && return nothing
    u = UsedStyles()
    for ws in _sheets(xf)
        s = ws.store
        if s !== nothing
            for r in s.rows, run in r.runs
                push!(u.ids, run.data.style)
            end
            for c in s.cols
                c.default_style >= 0 && push!(u.ids, c.default_style)
            end
        end
        f = ws.formats
        f === nothing && continue
        for r in f.cells, run in r.runs
            run.data.style >= 0 && push!(u.ids, run.data.style)
        end
        for c in f.cols
            c.default >= 0 && push!(u.ids, c.default)
            push!(u.cols, c.style)
        end
        for r in f.rows
            r.default >= 0 && push!(u.ids, r.default)
            push!(u.rows, r.style)
        end
    end
    return u
end

# A new file's styles.xml, with the named styles OpenDocumentSpreadsheets added (D-045).
function _new_styles(xf::ODSFile, version)
    fx = faces_xml(_named_faces(xf.styles))
    ns = (isempty(fx) ? "" : " xmlns:svg=\"$_SVG_NS\"") * (_needs_loext(xf.styles) ? " xmlns:loext=\"$_LOEXT_NS\"" : "")
    autos, masters = _page_styles_xml(xf)                     # page styles (phase 5 step 10)
    return new_styles_xml(version, named_styles_xml(xf.styles), ns, fx; autos, masters)
end

new_meta_xml(version) = new_meta_xml(nothing, version)
new_meta_xml(xf, version) =
    string(_XMLDECL, "<office:document-meta", _NS_DECL, " office:version=\"", version, "\">", _meta_body(xf), "</office:document-meta>")

function write_new_flat(io::IO, xf::ODSFile, version, mediatype; display::Bool = true)
    svg, faces = _faces(xf)
    # view settings (phase 5 step 8): office:settings after the meta, with the namespaces LibreOffice needs to read them
    vs = _views_edited(xf) ? _settings_views(xf, "<office:settings></office:settings>") : ""
    vns = isempty(vs) ? "" : " xmlns:config=\"$_CONFIG_NS\" xmlns:ooo=\"$_OOO_NS\""
    print(io, _XMLDECL, "<office:document", _NS_DECL, svg, vns, " office:version=\"", version, "\" office:mimetype=\"", mediatype, "\">",
          _meta_body(xf), vs, faces, replace(_STYLES_BODY, "</office:styles>" => named_styles_xml(xf.styles) * "</office:styles>"), "<office:automatic-styles>", added_styles_xml(xf.styles, used_styles(xf)), _table_styles_xml(xf),
          first(_page_styles_xml(xf)), "</office:automatic-styles>")
    pm = last(_page_styles_xml(xf))                            # master pages (phase 5 step 10)
    isempty(pm) || print(io, "<office:master-styles>", pm, "</office:master-styles>")
    _write_body(io, xf; display)
    print(io, "</office:document>")
    return nothing
end

# :ods, :ots or :fods, for a destination.
function _output_format(dest, xf::ODSFile)
    if dest isa AbstractString
        ext = lowercase(splitext(dest)[2])
        ext == ".fods" && return :fods
        ext == ".ots" && return :ots
        ext == ".ods" && return :ods
    end
    return isnewfile(xf) ? :ods : xf.container.format
end

_mediatype(fmt::Symbol) = fmt === :ots ? MEDIATYPE_OTS : MEDIATYPE_ODS

function _check_overwrite(dest, overwrite::Bool)
    dest isa AbstractString && !overwrite && isfile(dest) &&
        throw(ODSError("$dest already exists. Use `overwrite=true` to replace it."))
end

# An embedded object's content (a chart: `Object 1/content.xml`) with its references replayed
# through the structural edits (phase 5); the original bytes when none changes.
function _rewritten_part(xf::ODSFile, bytes::Vector{UInt8})
    s = _ns_canonical(String(copy(bytes)))        # the rewriter matches names as written (D-067)
    out = IOBuffer()
    rewrite_xml(out, RefRewriter(xf.ops, s), s, 1, ncodeunits(s))
    new = take!(out)
    return new == bytes ? bytes : new
end

# A part's data in a patched save: content.xml written as it is made, styles.xml with the named
# styles, settings.xml after sheet operations, embedded objects with their references replayed
# (phase 5), everything else as it was. A part that is patched is patched from its text with the
# usual namespace prefixes (D-067); one that isn't keeps its bytes, whatever its prefixes.
function _patched_part_data(xf::ODSFile, name::String, content)
    cont = xf.container
    name == "content.xml" && return content
    name == "styles.xml" && (has_named_styles(xf.styles) || _pages_edited(xf)) && return patched_styles(xf, read_part_text(cont, name))
    if name == "settings.xml" && _settings_edited(xf)
        b = read_bytes(cont, name)
        s = patched_settings(xf, _ns_canonical(String(copy(b))))
        return codeunits(s) == b ? b : s
    end
    name == "meta.xml" && _meta_edited(xf) && return _patched_meta(xf, read_part_text(cont, name))   # phase 5 step 11
    if endswith(name, "/content.xml")
        o = name[1:end-ncodeunits("/content.xml")]
        haskey(xf.chartobjs, o) && return _chart_text_now(xf, o)      # a file's chart, edited (phase 8)
        isempty(xf.ops) || return _rewritten_part(xf, read_bytes(cont, name))
    end
    if endswith(name, "/styles.xml")             # a file's chart, edited: its dashes (phase 8 step 6)
        o = get(xf.chartobjs, name[1:end-ncodeunits("/styles.xml")], nothing)
        o === nothing || isempty(o.styles) || return o.styles
    end
    return read_bytes(cont, name)
end

# The parts of a zipped file that was read, with content.xml patched (D-023).
function _patched_parts(xf::ODSFile; display::Bool = true)
    cont = xf.container
    mts = Dict(e.path => e.mediatype for e in cont.manifest)
    # Embedded objects (charts) whose frames may be gone, with their sheet, cells or copy (F-083):
    # content.xml is written first, and the objects its frames still embed are noted as it goes, so
    # that only those objects are written and listed (phase 8 step 2). Without structural
    # operations every frame stays, and nothing changes.
    objs = _object_dirs(cont)
    gating = (!isempty(xf.ops) && (!isempty(objs) || !isempty(xf.objcopies))) || !isempty(xf.chartobjs) || _charts_removed(xf)
    seen = Set{String}()
    content = gating ? (io -> _write_chunked(o -> write_patched_content(o, xf; display), _HrefScan(io, seen))) :
                       (io -> write_patched_content(io, xf; display))     # written into the zip as it is made (D-048)
    objof(name) = (i = findfirst('/', name); top = i === nothing ? "" : name[1:i-1];
                   top == "ObjectReplacements" ? name[i+1:end] : top in objs ? top : nothing)
    keepif(o) = gating && o !== nothing ? (() -> o in seen) : nothing
    # a part's media type as the manifest lists it (an object's picture: ""), else guessed
    mediatype(name) = haskey(mts, name) && (!isempty(mts[name]) || startswith(name, "ObjectReplacements/")) ? mts[name] : guess_mediatype(name)
    parts = PackagePart[]
    for name in partnames(cont)
        name in _RESERVED_PARTS && continue
        if endswith(name, "/")                   # a directory entry: kept, as an empty folder
            push!(parts, PackagePart(name, UInt8[]; mediatype = get(mts, name, ""), compress = false,
                                     keep = keepif(objof(name[1:prevind(name, end)] * "/x"))))
            continue
        end
        data = _patched_part_data(xf, name, content)
        push!(parts, PackagePart(name, data; mediatype = mediatype(name), keep = keepif(objof(name))))
    end
    # content.xml first when it decides which objects are written
    gating && (parts = vcat(filter(p -> p.name == "content.xml", parts), filter(p -> p.name != "content.xml", parts)))
    # directories the manifest lists with a media type but the zip has no entry for: an embedded
    # chart's `Object 1/` (without it LibreOffice loads the chart without its data)
    names = Set(partnames(cont))
    for e in cont.manifest
        (endswith(e.path, "/") && e.path != "/" && !isempty(e.mediatype) && !(e.path in names)) || continue
        o = e.path[1:prevind(e.path, end)]
        push!(parts, manifest_entry(e.path, e.mediatype; keep = keepif(o in objs ? o : nothing)))
    end
    # embedded objects that sheet copies duplicated (phase 5): their parts under the new name, made
    # from the file's own object (a copy of a copy, from the first one's source)
    for (_, new) in xf.objcopies
        old = _object_source(xf, new)
        for name in partnames(cont)
            newname = startswith(name, old * "/") ? new * name[ncodeunits(old)+1:end] :
                      name == "ObjectReplacements/" * old ? "ObjectReplacements/" * new : nothing
            newname === nothing && continue
            endswith(name, "/") && continue
            push!(parts, PackagePart(newname, _patched_part_data(xf, name, content); mediatype = mediatype(name),
                                     keep = keepif(new)))
        end
        mt = get(mts, old * "/", "")
        isempty(mt) || push!(parts, manifest_entry(new * "/", mt; keep = keepif(new)))
    end
    # pictures added (phase 6 step 5), once each
    for (name, mt, b) in _used_media(xf)
        name in names || push!(parts, PackagePart(name, b; mediatype = mt, compress = false))
    end
    # charts added (phase 8)
    append!(parts, _chart_parts(xf, o -> keepif(o)))
    # a package without settings.xml gets one when views were set (phase 5 step 8)
    _views_edited(xf) && !("settings.xml" in partnames(cont)) &&
        push!(parts, PackagePart("settings.xml", _settings_views(xf, _new_settings_xml(xf.version in WRITABLE_ODF_VERSIONS ? xf.version : DEFAULT_ODF_VERSION))))
    # a package without meta.xml gets one when properties were set (phase 5 step 11)
_meta_edited(xf) && !("meta.xml" in partnames(cont)) &&
    push!(parts, PackagePart("meta.xml", new_meta_xml(xf, xf.version in WRITABLE_ODF_VERSIONS ? xf.version : DEFAULT_ODF_VERSION)))
# a package without styles.xml gets one when it needs named styles
    (has_named_styles(xf.styles) || _pages_edited(xf)) && !("styles.xml" in partnames(cont)) && push!(parts, PackagePart("styles.xml", _new_styles(xf, xf.version in WRITABLE_ODF_VERSIONS ? xf.version : DEFAULT_ODF_VERSION)))
    return parts
end

"""
    writeods(dest, xf::ODSFile; overwrite=false, version="1.4") -> path or nothing

Write `xf` to `dest`, a file path or an `IO`.

- The format follows the extension of a path: `.ods`, `.ots` (a template) or `.fods` (flat
  XML). Writing to an `IO` keeps the format the file was read in (`.ods` for a new one).
- A file that was read is written by patching it: what OpenDocumentSpreadsheets does not edit is
  kept exactly as it was. It can be written as a template or a document, but not converted
  between zipped and flat XML yet.
- A new file is written in ODF 1.4, or 1.3 with `version="1.3"`.
- `display_text=false` leaves out the display text (`text:p`) of the number, date, time and
  boolean cells that OpenDocumentSpreadsheets writes; readers recompute it from the value. Files are then
  smaller (about half, for numeric data) and faster to write.
- An existing file at `dest` is only replaced with `overwrite=true`.

A path becomes the file's new `source` (for [`saveods`](@ref)). Returns the absolute path,
or `nothing` for an `IO`.
"""
function writeods(dest::Union{AbstractString,IO}, xf::ODSFile; overwrite::Bool = false,
                  version::AbstractString = DEFAULT_ODF_VERSION, display_text::Bool = true)
    _check_overwrite(dest, overwrite)
    display = display_text
    fmt = _output_format(dest, xf)
    mt = _mediatype(fmt)
    if isnewfile(xf)
        _check_version(version)
        _set_link_base!(xf.styles, fmt === :fods)      # relative hrefs in the output's form (F-065)
        if fmt === :fods
            write_flat(dest, io -> write_new_flat(io, xf, version, mt; display))
        else
            # charts (phase 8): content.xml is written first, and notes the objects its frames embed
            seen = Set{String}()
            content = isempty(xf.chartobjs) ? (io -> write_new_content(io, xf, version; display)) :
                      (io -> _write_chunked(o -> write_new_content(o, xf, version; display), _HrefScan(io, seen)))
            parts = [PackagePart("content.xml", content),
                     PackagePart("styles.xml", _new_styles(xf, version)),
                     PackagePart("meta.xml", new_meta_xml(xf, version))]
            _views_edited(xf) && push!(parts, PackagePart("settings.xml", _settings_views(xf, _new_settings_xml(version))))
            for (name, mt, b) in _used_media(xf)        # pictures (phase 6 step 5)
                push!(parts, PackagePart(name, b; mediatype = mt, compress = false))
            end
            append!(parts, _chart_parts(xf, o -> (() -> o in seen)))
            write_package(dest, parts; mediatype = mt, version)
        end
    else
        wasflat = xf.container.format === :fods
        wasflat == (fmt === :fods) ||
            throw(ODSError("Can't write a file read as $(wasflat ? "flat XML (.fods)" : "a zipped package") as $(wasflat ? "a zipped package" : "flat XML (.fods)") yet."))
        if fmt === :fods
            write_flat(dest, io -> _write_flat_patched(io, xf; display))
        else
            v = xf.version in WRITABLE_ODF_VERSIONS ? xf.version : DEFAULT_ODF_VERSION
            write_package(dest, _patched_parts(xf; display); mediatype = mt, version = v)
        end
    end
    if dest isa AbstractString
        xf.source = String(dest)
        xf.source_io = nothing
        return abspath(dest)
    end
    return nothing
end

"""
    saveods(xf::ODSFile)

Save `xf` back to where it was opened from: its file, or the `IO` it was read from (which
must be writable and seekable; its content is replaced). A file made with
[`newods`](@ref) has nowhere to go: use [`writeods`](@ref).
"""
function saveods(xf::ODSFile)
    _require_writable(xf, "save the file")
    if xf.source_io !== nothing
        io = xf.source_io
        try
            seekstart(io)
            truncate(io, 0)
        catch e
            e isa InterruptException && rethrow()
            throw(ODSError("Can't save back to the source `IO`: it must be writable and seekable. Use `writeods` to write elsewhere. ($(sprint(showerror, e)))"))
        end
        writeods(io, xf)
        xf.source_io = io
        return nothing
    end
    (xf.source == "blank.ods" || xf.source in ("IOBuffer", "IO")) &&
        throw(ODSError("This file has no file name to save to. Use `writeods(path, xf)`."))
    return writeods(xf.source, xf; overwrite = true)
end

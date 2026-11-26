# The ODF package ("container"): a zip package (.ods, .ots) or a flat XML document (.fods).
# Reading only. Writing is in writer.jl. See records D-005, D-006 and D-007.

const MEDIATYPE_ODS = "application/vnd.oasis.opendocument.spreadsheet"
const MEDIATYPE_OTS = "application/vnd.oasis.opendocument.spreadsheet-template"
const SPREADSHEET_MEDIATYPES = (MEDIATYPE_ODS, MEDIATYPE_OTS)

const NS_MANIFEST = "urn:oasis:names:tc:opendocument:xmlns:manifest:1.0"

"""
    ManifestEntry(path, mediatype, version)

One `manifest:file-entry` of `META-INF/manifest.xml`. `version` is `nothing` when the entry
has no `manifest:version` attribute.
"""
struct ManifestEntry
    path::String
    mediatype::String
    version::Union{Nothing,String}
end

"""
    ODFContainer

An opened spreadsheet package, either zipped (`.ods`/`.ots`) or flat (`.fods`).

Fields:
- `format`: `:ods`, `:ots` or `:fods`
- `mediatype`: the package media type
- `zip`: the `ZipReader` for zipped packages, otherwise `nothing`
- `flat`: the whole flat XML document for `.fods`, otherwise `nothing`
- `manifest`: the manifest entries (empty for `.fods`, and for zips without a manifest)
"""
struct ODFContainer
    format::Symbol
    mediatype::String
    zip::Union{Nothing,ZipArchives.ZipReader{Vector{UInt8}}}
    flat::Union{Nothing,String}
    manifest::Vector{ManifestEntry}
end

Base.show(io::IO, c::ODFContainer) =
    print(io, "ODFContainer(:", c.format, ", ", length(partnames(c)), " parts)")

const ZIP_MAGIC = (0x50, 0x4b, 0x03, 0x04)   # "PK\x03\x04"

_is_zip(b::AbstractVector{UInt8}) = length(b) >= 4 && (b[1], b[2], b[3], b[4]) == ZIP_MAGIC

# A flat document starts with '<', possibly after a UTF-8 BOM and whitespace.
function _is_flat_xml(b::AbstractVector{UInt8})
    i = 1
    length(b) >= 3 && b[1] == 0xef && b[2] == 0xbb && b[3] == 0xbf && (i = 4)
    while i <= length(b) && b[i] in (0x20, 0x09, 0x0a, 0x0d)
        i += 1
    end
    i <= length(b) && b[i] == UInt8('<')
end

"""
    open_container(source) -> ODFContainer

Open a spreadsheet package from a file path, a byte vector or an `IO` (read to the end).
Zipped (`.ods`/`.ots`) and flat (`.fods`) documents are both detected from their content,
not from the file extension.

The media type is taken from the `mimetype` entry. LibreOffice also accepts files without
one, so the media type in the manifest's root entry is used as a fallback.
Throws `ArgumentError` for anything that is not an ODF spreadsheet or template.
"""
open_container(path::AbstractString) = open_container(read(path))
open_container(io::IO) = open_container(read(io))

function open_container(bytes::Vector{UInt8})
    if _is_zip(bytes)
        return _open_zip(bytes)
    elseif _is_flat_xml(bytes)
        return _open_flat(String(bytes))
    else
        throw(ArgumentError("not an OpenDocument package: neither a zip archive nor an XML document"))
    end
end
open_container(bytes::AbstractVector{UInt8}) = open_container(Vector{UInt8}(bytes))

function _open_zip(bytes::Vector{UInt8})
    zr = ZipArchives.ZipReader(bytes)
    names = ZipArchives.zip_names(zr)
    manifest = "META-INF/manifest.xml" in names ?
        parse_manifest(_ns_canonical(readentry_string(zr, "META-INF/manifest.xml"))) : ManifestEntry[]
    mt = if "mimetype" in names
        strip(String(ZipArchives.zip_readentry(zr, "mimetype")))
    else
        root = findfirst(e -> e.path == "/", manifest)
        root === nothing && throw(ArgumentError(
            "cannot tell the document type: the package has neither a `mimetype` entry nor a manifest root entry"))
        manifest[root].mediatype
    end
    mt in SPREADSHEET_MEDIATYPES || throw(ArgumentError(
        "not an OpenDocument spreadsheet: the media type is $(repr(mt))"))
    "content.xml" in names || throw(ArgumentError("the package has no content.xml"))
    ODFContainer(mt == MEDIATYPE_OTS ? :ots : :ods, String(mt), zr, nothing, manifest)
end

# The root element of `xml`, its name and its `office:mimetype` attribute as written.
function _flat_root(xml::String)
    c = XML.Cursor(xml)
    while XML.next!(c) !== nothing
        XML.nodetype(c) === XML.Element || continue
        mt = nothing
        for (k, v) in XML.eachattribute!(c)
            k == "office:mimetype" && (mt = String(v))
        end
        return XML.tag(c), mt
    end
    throw(ArgumentError("empty XML document"))
end

# A flat document's prefixes are made the usual ones (D-067). The media type is the root's
# `office:mimetype` as written, whatever its prefixes: LibreOffice's type detection keys on
# that name, and opens a file without it as plain XML, not as a spreadsheet (F-057).
function _open_flat(xml::String)
    _, mt = _flat_root(xml)
    xml = _ns_canonical(xml)
    tag, _ = _flat_root(xml)
    tag == "office:document" || throw(ArgumentError(
        "not a flat OpenDocument file: the root element is <$tag>, not <office:document>"))
    mt in SPREADSHEET_MEDIATYPES || throw(ArgumentError(
        "not an OpenDocument spreadsheet: office:mimetype is $(repr(mt))"))
    return ODFContainer(:fods, mt, nothing, xml, ManifestEntry[])
end

"""
    parse_manifest(xml::AbstractString) -> Vector{ManifestEntry}

Read the `manifest:file-entry` elements of `META-INF/manifest.xml`.
"""
function parse_manifest(xml::AbstractString)
    entries = ManifestEntry[]
    c = XML.Cursor(xml)
    while XML.next!(c) !== nothing
        XML.nodetype(c) === XML.Element && XML.tag(c) == "manifest:file-entry" || continue
        path = ""; mt = ""; ver = nothing
        for (k, v) in XML.eachattribute!(c)
            if k == "manifest:full-path"
                path = String(v)
            elseif k == "manifest:media-type"
                mt = String(v)
            elseif k == "manifest:version"
                ver = String(v)
            end
        end
        push!(entries, ManifestEntry(path, mt, ver))
    end
    entries
end

"""
    partnames(c::ODFContainer) -> Vector{String}

The names of the package's parts. A flat document has a single logical part, `"content.xml"`.
"""
partnames(c::ODFContainer) = c.zip === nothing ? ["content.xml"] : ZipArchives.zip_names(c.zip)

"""
    haspart(c::ODFContainer, name) -> Bool
"""
haspart(c::ODFContainer, name::AbstractString) = name in partnames(c)

"""
    read_xml(c::ODFContainer, part::Symbol) -> Union{String,Nothing}

The XML text of a document part: `:content`, `:styles`, `:meta` or `:settings`.
Returns `nothing` if a zipped package does not have that part.

A flat document keeps every part in one `office:document`, so the whole document is
returned for any part. Readers look for the elements they need (for example `office:body`
or `office:styles`) inside it.

The text has the usual namespace prefixes ([`_ns_canonical`](@ref)).
"""
function read_xml(c::ODFContainer, part::Symbol)
    name = part === :content  ? "content.xml"  :
           part === :styles   ? "styles.xml"   :
           part === :meta     ? "meta.xml"     :
           part === :settings ? "settings.xml" :
           throw(ArgumentError("unknown part $(repr(part)); expected :content, :styles, :meta or :settings"))
    c.flat !== nothing && return c.flat
    haspart(c, name) ? read_part_text(c, name) : nothing
end

"""
    read_part_text(c::ODFContainer, name) -> String

A zipped XML part's text, with the usual namespace prefixes.
"""
read_part_text(c::ODFContainer, name::AbstractString) = _ns_canonical(readentry_string(c.zip, name))

"""
    read_bytes(c::ODFContainer, name) -> Vector{UInt8}

The raw bytes of a zipped part, such as an image. Not available for flat documents.
"""
function read_bytes(c::ODFContainer, name::AbstractString)
    c.zip === nothing && throw(ArgumentError("a flat document has no separate parts"))
    ZipArchives.zip_readentry(c.zip, name)
end

"""
    odf_version(xml::AbstractString) -> Union{String,Nothing}

The `office:version` attribute of the root element, or `nothing` if it is absent
(as in ODF 1.0/1.1 files).
"""
function odf_version(xml::AbstractString)
    c = XML.Cursor(xml)
    while XML.next!(c) !== nothing
        XML.nodetype(c) === XML.Element || continue
        for (k, v) in XML.eachattribute!(c)
            k == "office:version" && return String(v)
        end
        return nothing
    end
    nothing
end

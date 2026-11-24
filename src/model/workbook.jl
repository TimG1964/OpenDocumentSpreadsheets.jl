# The workbook and its sheets (D-020): `ODSFile`, `Worksheet`, `openods`/`readods`,
# sheet lookup, defined names (named ranges and expressions) and `show`.
#
# Adapted from XLSX.jl 0.13.4 (src/read.jl `openxlsx`/`readxlsx`/`parse_file_mode`,
# src/workbook.jl sheet lookup and `show`), MIT License, Copyright (c) 2018-2026 Felipe
# Noronha Tavares and other contributors. Changes: the ODF container and sheet index
# replace the OOXML parts; only mode "r" is available in phase 1 (D-019).

"""
    NameDef

A named range (`table:named-range`) or named expression (`table:named-expression`), as stored.
`scope` is the sheet a local name belongs to, or `nothing` for a workbook name.
`range` is the `table:cell-range-address`, `expression` the `table:expression`.
`span`: where its element is in the text it was read from (empty for a name OpenDocumentSpreadsheets added),
so that a save deletes it there and keeps every other name as it is (phase 5).
The public view of a name is [`DefinedName`](@ref).
"""
struct NameDef
    name::String
    scope::Union{Nothing,String}
    range::Union{Nothing,String}
    expression::Union{Nothing,String}
    base::Union{Nothing,String}
    span::UnitRange{Int}
end
NameDef(name, scope, range, expression, base) = NameDef(name, scope, range, expression, base, 0:-1)

# The names deleted since the file was read (their elements' spans), and where the names'
# element is (`at`), or, when `at` is empty, where one would go (`first(at)`) (phase 5).
mutable struct NameEdits
    removed::Vector{UnitRange{Int}}
    at::UnitRange{Int}
end
NameEdits() = NameEdits(UnitRange{Int}[], 0:-1)

# A sheet's visibility and tab colour (its table style's), read on first use (phase 5 step 6).
# `base`: the table style its text names; `style`: the one it has now (`base`, or one OpenDocumentSpreadsheets derived).
mutable struct SheetProps
    display::Bool
    tabcolor::Union{Nothing,String}   # "#rrggbb"
    rtl::Bool                         # right to left (`style:writing-mode`, phase 5 step 8)
    master::Union{Nothing,String}     # the master page its table style names (phase 5 step 10)
    base::Union{Nothing,String}
    style::Union{Nothing,String}
end

# The table styles OpenDocumentSpreadsheets derived (name => XML), and whether a sheet's visibility changed (the
# active sheet may then have to move, as in LibreOffice).
mutable struct TableStyleEdits
    added::Vector{Pair{String,String}}
    shown_changed::Bool
end
TableStyleEdits() = TableStyleEdits(Pair{String,String}[], false)

# A sheet's protection, as its text has it (read on first use) or as set since.
mutable struct SheetProtection
    attrs::Dict{String,String}        # the start tag's protection attributes
    options::Union{Nothing,Dict{String,String}}   # loext:table-protection's attributes, nothing if none
    child::UnitRange{Int}             # the span of the text's loext:table-protection (empty if none)
    changed::Bool
end


mutable struct WorkbookProtection
    attrs::Dict{String,String}
    changed::Bool
end


# A sheet's page style and print range (phase 5 step 10), read on first use: its master page's
# attributes and children, its page layout's properties (the page, the header's and the footer's)
# and other children, Excel's six margins in inches (left, right, top, bottom, header, footer) as
# LibreOffice's xlsx import maps them, and whether they changed.
mutable struct PrintState
    master::String                    # the master page the sheet uses now
    mattrs::Vector{Pair{String,String}}   # the master page's other attributes
    regions::Vector{Pair{String,String}}  # its children (header, header-left, …), tag => XML
    lattrs::Vector{Pair{String,String}}   # the page layout's other attributes
    lprops::Vector{Pair{String,String}}   # style:page-layout-properties
    linner::String                    # its children
    hprops::Vector{Pair{String,String}}   # the header's style:header-footer-properties
    fprops::Vector{Pair{String,String}}   # the footer's
    margins::Vector{Float64}
    page_changed::Bool                # the page style changed (a new one is written)
    margins_changed::Bool             # LibreOffice's margins are derived from `margins` again
    area::Union{Nothing,String}       # table:print-ranges
    area_changed::Bool
end

# The page styles OpenDocumentSpreadsheets derived (master page name => (master page XML, page layout XML)) and the
# text styles of the headers and footers it wrote (name => XML) (phase 5 step 10).
mutable struct PageEdits
    pages::Dict{String,Tuple{String,String}}
    text::Vector{Pair{String,String}}
end
PageEdits() = PageEdits(Dict{String,Tuple{String,String}}(), Pair{String,String}[])

# The file's office:meta (phase 5 step 11): its children (tag => XML) in order, read on first use,
# and whether OpenDocumentSpreadsheets changed them.
mutable struct MetaEdits
    children::Vector{Pair{String,String}}
    changed::Bool
end

# The view settings set since the file was read (phase 5 step 8): per sheet (by the sheet, so that
# they follow renames) and for the whole view; each item's (config:type, value), or `nothing` to remove it.
const ViewItems = Dict{String,Union{Nothing,Tuple{String,String}}}
mutable struct ViewEdits
    sheets::IdDict{Any,ViewItems}
    view::ViewItems
end
ViewEdits() = ViewEdits(IdDict{Any,ViewItems}(), ViewItems())

# The URL fields of a sheet's original cells (phase 6 step 3, D-072), read on first use: `nrows` × `ncols`
# alike original cells from (`row`, `col`), their links as (href, text), unescaped, the cell's text,
# and its paragraphs as written (which a sort moves, F-072).
struct FileLinkRun
    row::Int
    nrows::Int
    col::Int
    ncols::Int
    links::Vector{Tuple{String,String}}
    text::String
    paras::String
end

# Annotations and threaded comments (phase 6 step 4, D-073). One comment of a thread: the first, or a reply.
struct ThreadEntry
    id::String                        # loext:id ({GUID})
    person::String                    # loext:person-id ("" if none)
    author::String                    # the person's display name
    date::Union{Nothing,Dates.DateTime}
    text::String
end

# An annotation (a note), as written or to be written: its author (dc:creator), text (one line per
# paragraph), date (dc:date as written), whether it is shown, its size (svg:width, svg:height as
# written), and its thread (LibreOffice's `loext:threaded-comment`, F-059), if it has one.
mutable struct NoteData
    author::String
    text::String
    date::Union{Nothing,String}
    visible::Bool
    width::Union{Nothing,String}
    height::Union{Nothing,String}
    thread::Union{Nothing,Vector{ThreadEntry}}
    resolved::Bool
end

# A note of a sheet's original cells, at its original row and column.
struct FileNote
    row::Int
    col::Int
    note::NoteData
end

# The workbook's people (`loext:persons`, the threads' authors): the file's, by id, once read; and
# those OpenDocumentSpreadsheets added, as id => display name.
mutable struct PersonEdits
    file::Union{Nothing,Dict{String,String}}
    added::Vector{Pair{String,String}}
end
PersonEdits() = PersonEdits(nothing, Pair{String,String}[])

# Pictures (phase 6 step 5, D-074). One added: its part in `Pictures/` (or, in a flat file, its bytes
# in `ODSFile.media`), its media type, its size and anchor cells (it resizes with them, as LibreOffice's
# import places XLSX.jl's, F-060), in cm and as current cell numbers.
mutable struct ImageData
    pic::String                       # "Pictures/…"
    mime::String
    torow::Int                        # the last cell it covers (table:end-cell-address)
    tocol::Int
    width::Float64                    # cm
    height::Float64
    endx::Float64                     # its end within the last cell (table:end-x, -y), cm
    endy::Float64
    title::String                     # its alt text (svg:title) and description (svg:desc); "" for none (D-076)
    desc::String
end

# The frames of one cell changed: the original's pictures removed (by their order among its
# pictures), frames moved here by a delete or a sort (their XML, F-060, F-072, with how many of the
# file's structural operations it has), pictures added.
mutable struct FrameEdit
    removed::Set{Int}
    moved::Vector{Pair{String,Int}}
    added::Vector{ImageData}
end
FrameEdit() = FrameEdit(Set{Int}(), Pair{String,Int}[], ImageData[])

# What a cell's writer adds or changes besides its value: its note (missing: unchanged; nothing:
# removed), and its frames (D-073, D-074).
struct CellEdit
    note::Union{Missing,Nothing,NoteData}
    frames::Union{Nothing,FrameEdit}
end

# A shape of a sheet's original cells (or of its `table:shapes`, `page`): where it is, and enough of it
# for `getImages` and for a delete to move it (F-060).
struct FileFrame
    row::Int                          # its anchor cell (original numbers; 0 for the page)
    col::Int
    k::Int                            # its order among the cell's pictures (0: not a picture)
    href::String                      # the picture's `xlink:href` ("" if none)
    xml::String                       # the element, as written
end

# Data validation (phase 6 step 6, D-075). A rule, as XLSX.jl's `DataValidationInfo` gives its fields (but
# its sheet and cells), and its base cell (`table:base-cell-address`, as written).
struct ValRule
    type::Symbol
    operator::Union{Nothing,Symbol}
    formula1::Union{Nothing,String}
    formula2::Union{Nothing,String}
    allowBlank::Bool
    dropdown::Bool
    showInputMessage::Bool
    promptTitle::Union{Nothing,String}
    prompt::Union{Nothing,String}
    showErrorMessage::Bool
    errorTitle::Union{Nothing,String}
    error::Union{Nothing,String}
    errorStyle::Symbol
    base::String
    caseSensitive::Bool                # LibreOffice's own options (D-076): `table:case-sensitive`,
    sortEntries::Bool                  # and a list's `table:display-list="sort-ascending"`
end

# A rule of the file's `table:content-validations` (its `table:content-validation` element's span in the
# content), and one added: its sheet and base cell (moved with inserts and deletes; the XML is written
# when saved, with the sheet's name then).
struct FileRule
    name::String
    span::UnitRange{Int}
    rule::ValRule
end
mutable struct AddedRule
    name::String
    rule::ValRule
    sheet::Any                        # the Worksheet
    row::Int
    col::Int
end
mutable struct ValEdits
    file::Union{Nothing,Vector{FileRule}}   # read on first use
    added::Vector{AddedRule}
end
ValEdits() = ValEdits(nothing, AddedRule[])

# Tables (phase 6 step 7, D-077): a database range added or changed, as it is now: its name, sheet, cells,
# whether its first row holds the labels and its last the totals, its filter buttons, the file's element
# it replaces ("" if new: its other attributes and children are kept), and its place among the ranges.
mutable struct DBRange
    name::String
    sheet::Any                        # its Worksheet
    r1::Int
    c1::Int
    r2::Int
    c2::Int
    header::Bool                      # table:contains-header
    footer::Bool                      # calcext:contains-footer
    buttons::Bool                     # table:display-filter-buttons
    xml::String
    order::Float64
end

# The file's database ranges (span, element), once read; those removed or replaced (by index), and the
# copies' (`ODSFile.extras`) likewise; and the ranges added or changed.
mutable struct DBEdits
    file::Union{Nothing,Vector{Tuple{UnitRange{Int},String}}}
    removed::Set{Int}
    removedx::Set{Int}
    model::Vector{DBRange}
end
DBEdits() = DBEdits(nothing, Set{Int}(), Set{Int}(), DBRange[])

# The validation names of a sheet's original cells: `nrows` × `ncols` alike cells from (`row`, `col`).
struct FileValRun
    row::Int
    nrows::Int
    col::Int
    ncols::Int
    name::String
end

# Cells given a rule (its name) or none (nothing) since, in order: the last that holds a cell is its.
const ValRect = Tuple{UnitRange{Int},UnitRange{Int},Union{Nothing,String}}

"""
    Worksheet

A sheet of an [`ODSFile`](@ref). Index it like a matrix of values (`sheet["A1"]`,
`sheet["A1:B3"]`, `sheet[2, 1]`, `sheet[:]`); see [`getdata`](@ref).
"""
mutable struct Worksheet
    package::Any                      # the ODSFile (typed in accessors; circular)
    name::String
    index::Int
    entry::Union{Nothing,SheetEntry{String}}   # nothing: a sheet made by OpenDocumentSpreadsheets
    visible::Bool
    store::Union{Nothing,SheetStore}
    localnames::Union{Nothing,Vector{NameDef}}
    lock::ReentrantLock
    dirty::Dict{Int,Vector{Int}}      # edited cells of a sheet read from a file: row → columns
    formats::Union{Nothing,SheetFormats}   # read on first use by formatting (phase 4)
    rowmap::Union{Nothing,IndexMap}   # rows and columns inserted or deleted since the sheet was read
    colmap::Union{Nothing,IndexMap}   #   (phase 5: original → current lines), or nothing
    opstart::Int                      # operations already in its text (a copy's: those before the copy)
    copied::Bool                      # a copy made by `copysheet!`: its text is its own, not the file's
    nameedits::NameEdits              # its local names deleted, and where they are (phase 5)
    props::Union{Nothing,SheetProps}  # visibility and tab colour, once read (phase 5)
    protection::Union{Nothing,SheetProtection}   # its protection, once read (phase 5 step 9)
    print::Union{Nothing,PrintState}  # its page style and print range, once read (phase 5 step 10)
    links::Union{Nothing,Vector{FileLinkRun}}   # the URL fields its file holds, once read (phase 6 step 3)
    notes::Union{Nothing,Dict{Tuple{Int,Int},Union{Nothing,NoteData}}}   # notes set (or removed: nothing) since, by cell (phase 6 step 4)
    filenotes::Union{Nothing,Vector{FileNote}}   # the notes its file holds, once read
    mayextras::Union{Nothing,Bool}   # whether its original table may hold cell extras, once known (D-071)
    frames::Union{Nothing,Dict{Tuple{Int,Int},FrameEdit}}   # pictures added, removed or moved, by cell (phase 6 step 5)
    fileframes::Union{Nothing,Vector{FileFrame}}   # the shapes its file holds, once read
    valrects::Union{Nothing,Vector{ValRect}}   # validations set or removed, by block of cells (phase 6 step 6)
    filevals::Union{Nothing,Vector{FileValRun}}   # the validations of its file's cells, once read
    sortclear::Union{Nothing,Set{Tuple{Int,Int}}}   # cells a sort filled from others: the paragraphs and shapes of their original are not theirs (phase 6 step 9)
end

Worksheet(xf, name, index, entry, visible, store, localnames, lock) =
    Worksheet(xf, name, index, entry, visible, store, localnames, lock, Dict{Int,Vector{Int}}(), nothing, nothing, nothing, 0, false,
              NameEdits(), nothing, nothing, nothing, nothing, nothing, nothing, nothing, nothing, nothing, nothing, nothing, nothing)

# Whether the sheet was made by OpenDocumentSpreadsheets (so it is written whole), not read from the file.
isnewsheet(ws::Worksheet) = ws.entry === nothing

"""
    ODSFile

An opened spreadsheet, as [`openods`](@ref) and [`readods`](@ref) return it. Index it by
sheet name or number (`xf["Sheet1"]`, `xf[1]`), or with a sheet-qualified reference or a
defined name (`xf["Sheet1.A1:B2"]`, `xf["Sheet1!A1"]`, `xf["myrange"]`).
"""
mutable struct ODSFile
    source::String                    # the file path, "IOBuffer"/"IO", or "blank.ods" for a new file
    container::Union{Nothing,ODFContainer}   # nothing: a new file
    content::String                   # content.xml, or the whole flat document ("" if new)
    version::Union{Nothing,String}    # office:version
    styles::StyleIndex
    sheets::Vector{Worksheet}
    names::Vector{NameDef}
    null_date::Dates.Date             # table:null-date, for day numbers (formulas, formats)
    use_cache::Bool
    writable::Bool                    # opened with mode "w" or "rw", or made by newods
    source_io::Union{Nothing,IO}      # the IO a file was opened from, for saveods
    scanner::Union{Nothing,BodyScanner}   # the sheet index, found as far as needed (phase 3)
    lock::ReentrantLock
    ops::Vector{Any}                  # structural edits since the file was read, in order (phase 5: `RefOp`s)
    gone::Vector{Any}                 # sheets read from the file and deleted since (phase 5)
    extras::Vector{Any}               # database ranges added by sheet copies: (XML, operations already applied)
    objcopies::Vector{Pair{String,String}}   # embedded objects duplicated by sheet copies ("Object 1" => "Object 3")
    nameedits::NameEdits              # workbook names deleted, and where they are (phase 5)
    tstyles::TableStyleEdits          # table styles OpenDocumentSpreadsheets derived (phase 5)
    views::ViewEdits                  # view settings set (phase 5)
    wbprotection::Union{Nothing,WorkbookProtection}   # the structure's protection, once read (phase 5 step 9)
    pageedits::PageEdits              # page styles derived (phase 5 step 10)
    meta::Union{Nothing,MetaEdits}    # the document properties, once read (phase 5 step 11)
    persons::PersonEdits              # the threads' people (phase 6 step 4)
    media::Vector{Tuple{String,String,Vector{UInt8}}}   # pictures added: (Pictures/name, media type, bytes) (phase 6 step 5)
    hasdraw::Union{Nothing,Bool}      # whether the content holds any `<draw:` element, once known (phase 6 step 5)
    valedits::ValEdits                # validation rules read and added (phase 6 step 6)
    dbedits::DBEdits                  # database ranges (tables) read, added and changed (phase 6 step 7)
end

ODSFile(source, container, content, version, styles, sheets, names, null_date, use_cache) =
    ODSFile(source, container, content, version, styles, sheets, names, null_date, use_cache, false, nothing,
            nothing, ReentrantLock(), Any[], Any[], Any[], Pair{String,String}[], NameEdits(), TableStyleEdits(), ViewEdits(), nothing, PageEdits(), nothing, PersonEdits(), Tuple{String,String,Vector{UInt8}}[], nothing, ValEdits(), DBEdits())
ODSFile(source, container, content, version, styles, sheets, names, null_date, use_cache, writable, source_io) =
    ODSFile(source, container, content, version, styles, sheets, names, null_date, use_cache, writable, source_io,
            nothing, ReentrantLock(), Any[], Any[], Any[], Pair{String,String}[], NameEdits(), TableStyleEdits(), ViewEdits(), nothing, PageEdits(), nothing, PersonEdits(), Tuple{String,String,Vector{UInt8}}[], nothing, ValEdits(), DBEdits())

#
# The sheet index is built as far as it is needed: `xf["Sheet1"]` or `xf[1]` finds the first
# sheet without scanning past it, while `sheetnames`, `sheetcount` and the workbook's names
# (which follow the sheets in content.xml) scan to the end. Each step skips a whole sheet
# (XML.jl `skip_element!`).
#

# Index one more body item; false when the end is reached.
function _index_next!(xf::ODSFile)
    s = xf.scanner
    (s === nothing || s.done) && return false
    lock(xf.lock) do
        while (item = next_body_item!(s)) !== nothing
            kind, node, name = item
            if kind === :table
                e = SheetEntry(name, length(xf.sheets) + 1, node)
                push!(xf.sheets, Worksheet(xf, e.name, e.index, e, _sheet_visible(e, xf.styles), nothing, nothing, ReentrantLock()))
                return true
            elseif kind === :names
                append!(xf.names, _read_names(node, nothing))
                xf.nameedits.at = XML.sourcespan(node)
            else
                xf.null_date = _null_date(node)
            end
        end
        return false
    end
end

_index_all!(xf::ODSFile) = (while _index_next!(xf) end; xf)
_sheets(xf::ODSFile) = (_index_all!(xf); xf.sheets)
_wb_names(xf::ODSFile) = (_index_all!(xf); xf.names)

isnewfile(xf::ODSFile) = xf.container === nothing

@inline get_odsfile(ws::Worksheet)::ODSFile = ws.package
@inline is_cache_enabled(ws::Worksheet) = get_odsfile(ws).use_cache
@inline is_cache_enabled(xf::ODSFile) = xf.use_cache

#
# Opening
#

# (read, write) for a file mode, as XLSX.jl's `parse_file_mode`.
function _parse_file_mode(mode::AbstractString)
    m = lowercase(mode)
    m == "r" && return (true, false)
    m == "w" && return (false, true)
    (m == "rw" || m == "wr") && return (true, true)
    throw(ODSError("Couldn't parse file mode $mode."))
end

"""
    openods(source; mode="r", enable_cache=true) -> ODSFile
    openods(f::Function, source; mode="r", enable_cache=true)

Open an OpenDocument spreadsheet (`.ods`, `.fods` or `.ots`, detected from the content)
from a file path or an `IO`. The do-block form passes the file to `f` and returns what `f`
returns.

`content.xml` is read once, and the sheets are located without being parsed.
- `enable_cache=true`: a sheet is parsed into memory the first time one of its cells is
  read; later reads use that copy.
- `enable_cache=false`: every read scans the sheet again, keeping nothing, and stops after
  the last row it needs. Use it with [`eachrow`](@ref Base.eachrow(::Worksheet)) to stream a large sheet.

Modes, as in XLSX.jl:
- `"r"`: read only.
- `"rw"`: read and edit; save with [`saveods`](@ref) or [`writeods`](@ref). Saving patches the
  original file: everything OpenDocumentSpreadsheets does not edit is kept as it was (D-023).
- `"w"`: start a new, empty spreadsheet (with one sheet, `Sheet1`) that will be written to
  `source`; an existing file there is not read.

Writing modes need `enable_cache=true`. With the do-block form, a file opened for writing
is saved to `source` after `f` returns (not if `f` throws).

See also [`readods`](@ref), [`newods`](@ref).
"""
function openods(f::Function, source::Union{AbstractString,IO}; mode::AbstractString = "r", enable_cache::Bool = true)
    xf = openods(source; mode, enable_cache)
    result = f(xf)
    xf.writable && saveods(xf)
    return result
end

function openods(source::Union{AbstractString,IO}; mode::AbstractString = "r", enable_cache::Bool = true)
    reads, writes = _parse_file_mode(mode)
    writes && !enable_cache && throw(ODSError("Writing a file (mode \"$mode\") needs `enable_cache=true`."))
    name = source isa AbstractString ? String(source) : source isa IOBuffer ? "IOBuffer" : "IO"
    if !reads                      # "w": a new file
        xf = newods()
        xf.source = name
        xf.source_io = source isa IO ? source : nothing
        return xf
    end
    if source isa AbstractString
        isfile(source) || throw(ODSError("File $source not found."))
        bytes = read(source)
    else
        bytes = read(source)
    end
    xf = _open_bytes(bytes, name, enable_cache)
    if writes
        xf.writable = true
        xf.source_io = source isa IO ? source : nothing
    end
    return xf
end

"""
    readods(source) -> ODSFile

Read an OpenDocument spreadsheet from a file path or an `IO`: [`openods`](@ref) with the
cache enabled. Each sheet is parsed the first time it is used.
"""
readods(source::Union{AbstractString,IO}) = openods(source; mode = "r", enable_cache = true)

# A read-only, uncached open for a one-shot read of `sheet` (readtable, readdata): only the
# part of content.xml up to that sheet's end is inflated.
function _open_through(source::Union{AbstractString,IO}, sheet::Union{AbstractString,Integer})
    if source isa AbstractString
        isfile(source) || throw(ODSError("File $source not found."))
    end
    name = source isa AbstractString ? String(source) : source isa IOBuffer ? "IOBuffer" : "IO"
    return _open_bytes(read(source), name, false; through = sheet)
end

# `through`: a sheet (name or number) that is all a one-shot read needs; content.xml is
# then inflated only as far as its end (phase 3). The file is read-only then.
function _open_bytes(bytes::Vector{UInt8}, name::String, enable_cache::Bool;
                     through::Union{Nothing,AbstractString,Integer} = nothing)
    container = try
        open_container(bytes)
    catch e
        e isa ArgumentError || rethrow()
        throw(ODSError("$name is not a readable OpenDocument spreadsheet: $(e.msg)"))
    end
    content = try
        through === nothing || !haspart(container, "content.xml") ? read_xml(container, :content) :
            content_through_sheet(container, through)
    catch e
        e isa ArgumentError || rethrow()
        throw(ODSError("$name is not a readable OpenDocument spreadsheet: $(e.msg)"))
    end
    content === nothing && throw(ODSError("$name has no content.xml."))
    styles_xml = container.flat === nothing ? read_xml(container, :styles) : nothing
    styles = build_style_index(styles_xml, content)
    xf = ODSFile(name, container, content, odf_version(content), styles, Worksheet[], NameDef[],
                 SheetCore.DEFAULT_NULL_DATE, enable_cache)
    xf.scanner = BodyScanner(content)
    return xf
end

function _sheet_visible(e::SheetEntry, styles::StyleIndex)
    c = XML.Cursor(e.node)
    XML.next!(c)
    for (k, v) in XML.eachattribute!(c)
        k == "table:style-name" && return !(v in styles.hidden_tables)
    end
    return true
end

function _null_date(node)
    node === nothing && return SheetCore.DEFAULT_NULL_DATE
    c = XML.Cursor(node)
    XML.next!(c)
    result = SheetCore.DEFAULT_NULL_DATE
    XML.for_each_child!(c) do ch
        XML.nodetype(ch) === XML.Element || return
        if XML.tag(ch) == "table:null-date"
            for (k, v) in XML.eachattribute!(ch)
                if k == "table:date-value"
                    d = parse_odf_date(v)
                    d === nothing || (result = Dates.Date(d))
                end
            end
        end
        XML.skip_element!(ch)
    end
    return result
end

# The names in a table:named-expressions element.
function _read_names(node::XML.LazyNode{String}, scope::Union{Nothing,String})
    names = NameDef[]
    c = XML.Cursor(node)
    XML.next!(c)
    XML.for_each_child!(c) do ch
        XML.nodetype(ch) === XML.Element || return
        t = XML.tag(ch)
        if t == "table:named-range" || t == "table:named-expression"
            name = ""; rng = nothing; expr = nothing; base = nothing
            sp = XML.sourcespan(XML.LazyNode(ch))
            for (k, v) in XML.eachattribute!(ch)
                k == "table:name" && (name = String(v))
                k == "table:cell-range-address" && (rng = String(v))
                k == "table:expression" && (expr = String(v))
                k == "table:base-cell-address" && (base = String(v))
            end
            isempty(name) || push!(names, NameDef(name, scope, rng, expr, base, sp))
        end
        XML.skip_element!(ch)
    end
    return names
end

# The elements that come after a table's names (ODF 1.3 and LibreOffice's extensions).
const _AFTER_NAMES = ("table:database-ranges", "table:data-pilot-tables", "table:consolidation", "table:dde-links",
                      "calcext:conditional-formats", "calcext:sparkline-groups", "loext:sparkline-groups",
                      "office:event-listeners", "table:named-expressions")

# The sheet's own names (inside its table:table), read on first use. Where they are is noted
# too, or, if it has none, where they would go: before the first element that follows them, or
# the table's end tag (only those few elements' spans are taken: the rows are skipped).
function _local_names(ws::Worksheet)
    lock(ws.lock) do
        ws.localnames === nothing || return ws.localnames
        found = NameDef[]
        ws.entry === nothing && (ws.localnames = found; return found)
        c = XML.Cursor(ws.entry.node)
        XML.next!(c)
        span = 0:-1
        at = 0
        XML.for_each_child!(c) do ch
            XML.nodetype(ch) === XML.Element || return
            tg = XML.tag(ch)
            if tg == "table:named-expressions"
                ln = XML.LazyNode(ch)
                span = XML.sourcespan(ln)
                append!(found, _read_names(ln, ws.name))
            elseif at == 0 && tg in _AFTER_NAMES
                at = first(XML.sourcespan(XML.LazyNode(ch)))
            end
            XML.skip_element!(ch)
        end
        # none and nothing after them: the table's end tag, found when a name is added
        # (`_names_at!`; finding it here would scan the whole table again)
        ws.nameedits.at = isempty(span) ? (at:at-1) : span
        ws.localnames = found
        return found
    end
end

#
# The cell store
#

# The full store of a cached sheet, read on first use.
function _cached_store(ws::Worksheet)::SheetStore
    s = ws.store
    s === nothing || return s
    lock(ws.lock) do
        if ws.store === nothing
            ws.store = ws.entry === nothing ? SheetStore() : read_store(ws.entry.node, get_odsfile(ws).styles)
        end
        return ws.store
    end
end

# The rows `rows` of a sheet: the cache, or with the cache off, a store read for them alone.
function _store_for(ws::Worksheet, rows::AbstractUnitRange{<:Integer})::SheetStore
    (is_cache_enabled(ws) || ws.entry === nothing) && return _cached_store(ws)
    isempty(rows) && return SheetStore(RowData[], ColRun[], CellRange[], nothing)
    return read_store(ws.entry.node, get_odsfile(ws).styles; skip_before = first(rows), stop_after = last(rows))
end
_store_for(ws::Worksheet) = _store_for(ws, 1:SheetCore.MAX_ROWS)

#
# Sheets
#

"""
    sheetnames(xf::ODSFile) -> Vector{String}

The names of the sheets, in order.
"""
sheetnames(xf::ODSFile) = [s.name for s in _sheets(xf)]

"""
    sheetcount(xf::ODSFile) -> Int

The number of sheets.
"""
sheetcount(xf::ODSFile) = length(_sheets(xf))

# Sheet names match without regard to case, as in LibreOffice (and Excel). A quoted name
# (`'My sheet'`) is unquoted first. The index is extended only until an exact match is
# found; a match without regard to case needs all the names.
function _sheet_index(xf::ODSFile, sheetname::AbstractString)
    name = SheetCore.unquoteit(String(sheetname))
    i = findfirst(s -> s.name == name, xf.sheets)
    i === nothing || return i
    while _index_next!(xf)
        xf.sheets[end].name == name && return length(xf.sheets)
    end
    return findfirst(s -> _same_sheetname(s.name, name), xf.sheets)
end
_same_sheetname(a::AbstractString, b::AbstractString) =
    Unicode.normalize(a; casefold = true) == Unicode.normalize(b; casefold = true)

"""
    hassheet(xf::ODSFile, sheetname) -> Bool

Whether the file has a sheet named `sheetname`. Names match without regard to case, as in
LibreOffice, which does not allow two sheets whose names differ only in case.
"""
hassheet(xf::ODSFile, sheetname::AbstractString)::Bool = _sheet_index(xf, sheetname) !== nothing

function getsheet(xf::ODSFile, sheetname::AbstractString)::Worksheet
    i = _sheet_index(xf, sheetname)
    i === nothing && throw(ODSError("$(xf.source) does not have a sheet named `$sheetname`."))
    return xf.sheets[i]
end

function getsheet(xf::ODSFile, i::Integer)::Worksheet
    while length(xf.sheets) < i && _index_next!(xf) end
    1 <= i <= length(xf.sheets) ||
        throw(ODSError("$(xf.source) has no sheet $i: it has $(length(xf.sheets)) sheet(s)."))
    return xf.sheets[i]
end

Base.getindex(xf::ODSFile, i::Integer) = getsheet(xf, i)
function Base.getindex(xf::ODSFile, s::AbstractString)
    # a sheet-qualified reference to a sheet that exists (found without indexing the rest)
    if occursin('.', s) || occursin('!', s)
        ref = try parse_sheet_ref(s) catch; nothing end
        if ref !== nothing && _sheet_index(xf, ref.sheet) !== nothing
            return getdata(xf, ref)
        end
    end
    hassheet(xf, s) && return getsheet(xf, s)
    return getdata(xf, s)
end

"""
    isvisible(ws::Worksheet) -> Bool

Whether the sheet is shown, as opposed to hidden (`table:display="false"` on its table style).
"""
isvisible(ws::Worksheet) = ws.visible

#
# Defined names
#

# The name `name` in `names`, matched without regard to case (as LibreOffice does).
function _find_name(names::Vector{NameDef}, name::AbstractString)
    for dn in names
        dn.name == name && return dn
    end
    for dn in names
        _same_sheetname(dn.name, name) && return dn
    end
    return nothing
end

is_workbook_defined_name(xf::ODSFile, name::AbstractString) = _find_name(_wb_names(xf), name) !== nothing
is_worksheet_defined_name(ws::Worksheet, name::AbstractString) = _find_name(_local_names(ws), name) !== nothing

"""
    get_defined_name_value(dn::NameDef)

The value of a defined name: a sheet-qualified reference (`SheetCellRef`, `SheetCellRange`,
...) for a named range or a named expression that is a single reference, or the constant of
a named expression that is a number, string or logical value. Other expressions throw: they
would need a formula evaluator. A reference without a sheet (a relative name's `.B2`) is on its
base cell's sheet. LibreOffice saves a named range of several areas as an expression of
references joined by `~`, `;` or spaces (F-026, F-050).
"""
function get_defined_name_value(dn::NameDef)
    v, _, isformula = _name_value(dn)      # src/write/names.jl
    isformula && throw(ODSError("The defined name `$(dn.name)` is the expression `$(something(dn.expression, dn.range))`, " *
                                "which OpenDocumentSpreadsheets cannot evaluate."))
    return v
end
get_defined_name_value(xf::ODSFile, name::AbstractString) = get_defined_name_value(_find_name(_wb_names(xf), name))
get_defined_name_value(ws::Worksheet, name::AbstractString) = get_defined_name_value(_find_name(_local_names(ws), name))

is_defined_name_value_a_reference(v) = v isa Union{SheetCellRef,SheetCellRange,SheetColumnRange,SheetRowRange,NonContiguousRange}

"""
    defined_names(xf::ODSFile) -> Vector{NameDef}
    defined_names(ws::Worksheet) -> Vector{NameDef}

The workbook's named ranges and expressions, or those local to a sheet.
"""
defined_names(xf::ODSFile) = copy(_wb_names(xf))
defined_names(ws::Worksheet) = copy(_local_names(ws))

#
# Dimension and display
#

"""
    get_dimension(ws::Worksheet; allow_load=true) -> CellRange

The smallest range holding every cell with a value or formula. ODS files do not record it,
so it is computed from the sheet (the cache, or a scan without the cache). An empty sheet
gives `A1:A1`, as in XLSX.jl. With `allow_load=false`, an unread sheet gives `A1:A1`
without being read.
"""
function get_dimension(ws::Worksheet; allow_load::Bool = true)::CellRange
    fallback = CellRange(CellRef(1, 1), CellRef(1, 1))
    if !allow_load && ws.store === nothing
        return fallback
    end
    dim = store_dimension(is_cache_enabled(ws) ? _cached_store(ws) : _store_for(ws))
    return something(dim, fallback)
end

# The dimension if it is known without reading the sheet.
_known_dimension(ws::Worksheet) = ws.store === nothing ? nothing : store_dimension(ws.store)

Base.size(ws::Worksheet) = size(get_dimension(ws))

function Base.show(io::IO, ws::Worksheet)
    hidden = ws.visible ? "" : " (hidden)"
    rg = _known_dimension(ws)
    if rg !== nothing
        nrow, ncol = size(rg)
        print(io, nrow, "×", ncol, " OpenDocumentSpreadsheets.Worksheet: [\"", ws.name, "\"](", rg, ")", hidden)
    else
        print(io, "OpenDocumentSpreadsheets.Worksheet: [\"", ws.name, "\"]", hidden)
    end
end

function Base.show(io::IO, xf::ODSFile)
    n = sheetcount(xf)
    src = xf.source in ("IOBuffer", "IO") ? xf.source : repr(xf.source)
    print(io, "ODSFile(", src, ") containing ", n, n == 1 ? " Worksheet\n" : " Worksheets\n")
    @printf(io, "%21s %-13s %-13s\n", "sheetname", "size", "range")
    print(io, "-"^(21 + 1 + 13 + 1 + 13))
    for s in _sheets(xf)
        println(io)
        name = length(s.name) > 20 ? first(s.name, 19) * "…" : s.name
        rg = _known_dimension(s)
        if rg === nothing
            @printf(io, "%21s %s", name, s.store === nothing ? "size unknown" : "empty")
        else
            sz = size(rg)
            @printf(io, "%21s %-13s %-13s", name, string(sz[1], "x", sz[2]), string(rg))
        end
        s.visible || print(io, " (hidden)")
    end
end

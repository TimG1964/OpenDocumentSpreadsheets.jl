# The state of edits made since a file was read, one struct per feature, held by `ODSFile` and
# `Worksheet` (model/workbook.jl): names, sheet properties, protection, printing, views, links, notes,
# pictures, charts (`ChartObj`), validations, database ranges, conditional formats and sparklines.
# Moved out of model/workbook.jl in the code review (Phase 4).

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
    object::String                    # a chart's frame (phase 8): its object's name ("Object 1"); "" for a picture
end
ImageData(pic, mime, torow, tocol, width, height, endx, endy, title, desc) =
    ImageData(pic, mime, torow, tocol, width, height, endx, endy, title, desc, "")

# The frames of one cell changed: the original's pictures removed (by their order among its
# pictures), frames moved here by a delete or a sort (their XML, F-060, F-072, with how many of the
# file's structural operations it has), pictures added.
mutable struct FrameEdit
    removed::Set{Int}
    moved::Vector{Pair{String,Int}}
    added::Vector{ImageData}
    objremoved::Set{String}          # the original's charts deleted, by object name (phase 8)
end
FrameEdit() = FrameEdit(Set{Int}(), Pair{String,Int}[], ImageData[], Set{String}())

# A chart added or edited (phase 8): its object's content.xml, with how many of the file's structural
# operations it already has, its styles.xml (its line dashes; "" when it has none of its own), and
# for a flat file's own chart, its inline object as it was when it was first changed and the operations
# then (the save finds it by them, and puts the chart in its place: phase 8 step 9; "" for others).
#
# Its content is held as text, or as an XML.jl tree once a setter works on the tree (D-102). `o.text`
# is the text in either case: a tree edited since is written out first (`XML.write(…; pretty = false)`,
# which keeps LibreOffice's text byte for byte, F-094). Setting `o.text` drops the tree. `version`
# counts the changes, for the getters' cache.
mutable struct ChartObj
    src::String
    nops::Int
    styles::String
    flatorig::String
    flatops::Int
    tree::Union{Nothing,XML.Node}
    stale::Bool                      # the tree was edited since `src` was written
    version::Int
end
ChartObj(text::String, nops::Int, styles::String, flatorig::String, flatops::Int) =
    ChartObj(text, nops, styles, flatorig, flatops, nothing, false, 0)
ChartObj(text::String, nops::Int) = ChartObj(text, nops, "", "", 0)
ChartObj(text::String, nops::Int, styles::String) = ChartObj(text, nops, styles, "", 0)

function Base.getproperty(o::ChartObj, s::Symbol)
    s === :text || return getfield(o, s)
    if getfield(o, :stale)
        setfield!(o, :src, XML.write(getfield(o, :tree); pretty = false))
        setfield!(o, :stale, false)
    end
    return getfield(o, :src)
end
function Base.setproperty!(o::ChartObj, s::Symbol, v)
    s === :text || return setfield!(o, s, convert(fieldtype(ChartObj, s), v))
    setfield!(o, :src, String(v))
    setfield!(o, :tree, nothing)
    setfield!(o, :stale, false)
    setfield!(o, :version, getfield(o, :version) + 1)
    return v
end
Base.propertynames(::ChartObj) = (:text, fieldnames(ChartObj)...)

# The object's tree, parsed once and kept (D-102).
function _tree!(o::ChartObj)
    t = getfield(o, :tree)
    t === nothing || return t
    t = parse(XML.Node, o.text)
    setfield!(o, :tree, t)
    return t
end
# After an edit of the tree: its text is written again when it is next read.
function _tree_edited!(o::ChartObj)
    setfield!(o, :stale, true)
    setfield!(o, :version, getfield(o, :version) + 1)
    return o
end

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

# A getter's row (a comment, a link, a rule…) with the fields of `T`, typed by its values: a row typed `T`
# itself, whose fields are `Union{Nothing,…}`, shows at the REPL as `@NamedTuple{…}((…))` (D-090).
_info_row(::Type{<:NamedTuple{N}}, vals::Tuple) where {N} = NamedTuple{N}(vals)

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

# A sheet's conditional formats (phase 7, D-081): `list`, each `calcext:conditional-format` element as
# it is now (references current); `edited`, whether they changed since the file was read; `span`, the
# file's `calcext:conditional-formats` element in the sheet's text (empty if none); `at`, where a new
# element goes when there is none (0: before the table's end tag, found when needed).
mutable struct CfState
    list::Vector{String}
    edited::Bool
    span::UnitRange{Int}
    at::Int
end

# A sheet's sparkline groups (phase 8 step 8), as its conditional formats are kept: each
# `calcext:sparkline-group` element as it is now, whether they changed, the file's element's span, and
# where a new element goes when there is none.
mutable struct SparkState
    list::Vector{String}
    edited::Bool
    span::UnitRange{Int}
    at::Int
end

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
so that a save deletes it there and keeps every other name as it is.
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

"""
    Worksheet

A sheet of an [`ODSFile`](@ref). Index it like a matrix of values (`sheet["A1"]`,
`sheet["A1:B3"]`, `sheet[2, 1]`, `sheet[:]`); see [`getdata`](@ref).
"""
Base.@kwdef mutable struct Worksheet
    package::Any                     # the ODSFile (typed in accessors; circular)
    name::String
    index::Int
    entry::Union{Nothing,SheetEntry{String}}   # nothing: a sheet made by OpenDocumentSpreadsheets
    visible::Bool
    store::Union{Nothing,SheetStore}
    localnames::Union{Nothing,Vector{NameDef}}
    lock::ReentrantLock
    dirty::Dict{Int,Vector{Int}} = Dict{Int,Vector{Int}}()  # edited cells of a sheet read from a file: row → columns
    formats::Union{Nothing,SheetFormats} = nothing  # read on first use by formatting (phase 4)
    rowmap::Union{Nothing,IndexMap} = nothing  # rows and columns inserted or deleted since the sheet was read
    colmap::Union{Nothing,IndexMap} = nothing  #   (phase 5: original → current lines), or nothing
    opstart::Int = 0                         # operations already in its text (a copy's: those before the copy)
    copied::Bool = false                     # a copy made by `copysheet!`: its text is its own, not the file's
    nameedits::NameEdits = NameEdits()       # its local names deleted, and where they are (phase 5)
    props::Union{Nothing,SheetProps} = nothing  # visibility and tab colour, once read (phase 5)
    protection::Union{Nothing,SheetProtection} = nothing  # its protection, once read (phase 5 step 9)
    print::Union{Nothing,PrintState} = nothing  # its page style and print range, once read (phase 5 step 10)
    links::Union{Nothing,Vector{FileLinkRun}} = nothing  # the URL fields its file holds, once read (phase 6 step 3)
    notes::Union{Nothing,Dict{Tuple{Int,Int},Union{Nothing,NoteData}}} = nothing  # notes set (or removed: nothing) since, by cell (phase 6 step 4)
    filenotes::Union{Nothing,Vector{FileNote}} = nothing  # the notes its file holds, once read
    mayextras::Union{Nothing,Bool} = nothing  # whether its original table may hold cell extras, once known (D-071)
    frames::Union{Nothing,Dict{Tuple{Int,Int},FrameEdit}} = nothing  # pictures added, removed or moved, by cell (phase 6 step 5)
    fileframes::Union{Nothing,Vector{FileFrame}} = nothing  # the shapes its file holds, once read
    valrects::Union{Nothing,Vector{ValRect}} = nothing  # validations set or removed, by block of cells (phase 6 step 6)
    filevals::Union{Nothing,Vector{FileValRun}} = nothing  # the validations of its file's cells, once read
    sortclear::Union{Nothing,Set{Tuple{Int,Int}}} = nothing  # cells a sort filled from others: the paragraphs and shapes of their original are not theirs (phase 6 step 9)
    cfs::Union{Nothing,CfState} = nothing    # its conditional formats, once read (phase 7)
    pagecharts::Union{Nothing,Vector{ImageData}} = nothing  # charts added anchored to the page: a chart sheet's (phase 8 step 7)
    sparks::Union{Nothing,SparkState} = nothing  # its sparkline groups, once read (phase 8 step 8)
    filerich::Union{Nothing,Vector{Tuple{Int,Int,Int,Int,String,String}}} = nothing  # the cells of its file with rich text, once read (D-088)
    # whether a setter has run on it (`_require_writable`): a patched save then writes it again, so an
    # edit that no `_sheet_edited` check knows of is not lost (Phase 2 of the code review, D-100)
    touched::Bool = false
end

Worksheet(xf, name, index, entry, visible, store, localnames, lock) =
    Worksheet(; package = xf, name, index, entry, visible, store, localnames, lock)

# Whether the sheet was made by OpenDocumentSpreadsheets (so it is written whole), not read from the file.
isnewsheet(ws::Worksheet) = ws.entry === nothing

# A structural edit whose references the save rewrites: `LineShift`, `SheetRename`, `SheetDelete`,
# `SheetCopy`, `RowMove` (formula/refs.jl).
abstract type RefOp end

"""
    ODSFile

An opened spreadsheet, as [`openods`](@ref) and [`readods`](@ref) return it. Index it by
sheet name or number (`xf["Sheet1"]`, `xf[1]`), or with a sheet-qualified reference or a
defined name (`xf["Sheet1.A1:B2"]`, `xf["Sheet1!A1"]`, `xf["myrange"]`).
"""
Base.@kwdef mutable struct ODSFile
    source::String                    # the file path, "IOBuffer"/"IO", or "blank.ods" for a new file
    container::Union{Nothing,ODFContainer}   # nothing: a new file
    content::String                   # content.xml, or the whole flat document ("" if new)
    version::Union{Nothing,String}    # office:version
    styles::StyleIndex
    sheets::Vector{Worksheet}
    names::Vector{NameDef}
    null_date::Dates.Date             # table:null-date, for day numbers (formulas, formats)
    use_cache::Bool
    writable::Bool = false                   # opened with mode "w" or "rw", or made by newods
    source_io::Union{Nothing,IO} = nothing   # the IO a file was opened from, for saveods
    scanner::Union{Nothing,BodyScanner} = nothing  # the sheet index, found as far as needed (phase 3)
    lock::ReentrantLock = ReentrantLock()
    ops::Vector{RefOp} = RefOp[]             # structural edits since the file was read, in order (phase 5: `RefOp`s)
    gone::Vector{Worksheet} = Worksheet[]    # sheets read from the file and deleted since (phase 5)
    extras::Vector{Tuple{String,Int}} = Tuple{String,Int}[]  # database ranges added by sheet copies: (XML, operations already applied)
    objcopies::Vector{Pair{String,String}} = Pair{String,String}[]  # embedded objects duplicated by sheet copies ("Object 1" => "Object 3")
    nameedits::NameEdits = NameEdits()       # workbook names deleted, and where they are (phase 5)
    tstyles::TableStyleEdits = TableStyleEdits()  # table styles OpenDocumentSpreadsheets derived (phase 5)
    views::ViewEdits = ViewEdits()           # view settings set (phase 5)
    wbprotection::Union{Nothing,WorkbookProtection} = nothing  # the structure's protection, once read (phase 5 step 9)
    pageedits::PageEdits = PageEdits()       # page styles derived (phase 5 step 10)
    meta::Union{Nothing,MetaEdits} = nothing  # the document properties, once read (phase 5 step 11)
    persons::PersonEdits = PersonEdits()     # the threads' people (phase 6 step 4)
    media::Vector{Tuple{String,String,Vector{UInt8}}} = Tuple{String,String,Vector{UInt8}}[]  # pictures added: (Pictures/name, media type, bytes) (phase 6 step 5)
    hasdraw::Union{Nothing,Bool} = nothing   # whether the content holds any `<draw:` element, once known (phase 6 step 5)
    valedits::ValEdits = ValEdits()          # validation rules read and added (phase 6 step 6)
    dbedits::DBEdits = DBEdits()             # database ranges (tables) read, added and changed (phase 6 step 7)
    chartobjs::Dict{String,ChartObj} = Dict{String,ChartObj}()  # charts added or edited, by object name (phase 8)
    # what failed part-way through a structural edit, which leaves the model half-changed: the
    # file can still be read, but not edited or saved (Phase 2 of the code review)
    broken::Union{Nothing,String} = nothing
    # the charts' documents as their getters read them, by object name: (the object's version and the
    # operations so far, the document), parsed once per version (D-102)
    chartdocs::Dict{String,Any} = Dict{String,Any}()
end

ODSFile(source, container, content, version, styles, sheets, names, null_date, use_cache, writable = false, source_io = nothing) =
    ODSFile(; source, container, content, version, styles, sheets, names, null_date, use_cache, writable, source_io)

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

Modes:
- `"r"`: read only.
- `"rw"`: read and edit; save with [`saveods`](@ref) or [`writeods`](@ref). Saving patches the
  original file: everything OpenDocumentSpreadsheets does not edit is kept as it was.
- `"w"`: start a new, empty spreadsheet (with one sheet, `Sheet1`) that will be written to
  `source`; an existing file there is not read.

Writing modes need `enable_cache=true`. With the do-block form, a file opened for writing
is saved to `source` after `f` returns (not if `f` throws).

```julia
openods("budget.ods"; mode = "rw") do xf    # saved when the block ends
    xf["Costs"]["C2"] = "Paid"
end

xf = openods("budget.ods"; mode = "rw")     # or saved by hand
xf["Costs"]["C3"] = "Paid"
saveods(xf)
```

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

```julia
xf = readods("budget.ods")
sheetnames(xf)            # ["Income", "Costs"]
sh = xf["Costs"]          # or xf[2]
sh["B3"]                  # 100.0
sh["A1:C3"]               # a 3×3 matrix
```
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
#
# Several tasks may read one file's values at once: the index is read and extended under the file's
# lock (`_index_next!` takes it too; it is reentrant), so one task never sees another's half-added
# sheet, and each sheet loads under its own. Formats are read, and a file edited, by one task at a
# time (`stylesheet`).
function _sheet_index(xf::ODSFile, sheetname::AbstractString)
    name = SheetCore.unquoteit(String(sheetname))
    # indexed to the end (as by any save, or the reference rewriter's first lookup): the index no
    # longer grows, so it is read without the lock
    if (s = xf.scanner; s === nothing || s.done)
        i = findfirst(s -> s.name == name, xf.sheets)
        return i !== nothing ? i : findfirst(s -> _same_sheetname(s.name, name), xf.sheets)
    end
    return lock(xf.lock) do
        i = findfirst(s -> s.name == name, xf.sheets)
        i === nothing || return i
        while _index_next!(xf)
            xf.sheets[end].name == name && return length(xf.sheets)
        end
        findfirst(s -> _same_sheetname(s.name, name), xf.sheets)
    end
end
# Sheet names (and defined names) match without regard to case as LibreOffice matches them: by
# simple per-character case mapping, so `Ab` is `AB` but `Straße` is not `STRASSE`, which full
# case folding made one (F-093). Formula references use the same rule (formula/refs.jl).
_same_sheetname(a::AbstractString, b::AbstractString) = a == b || lowercase(a) == lowercase(b)

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
    n = lock(xf.lock) do                         # see `_sheet_index`
        while length(xf.sheets) < i && _index_next!(xf) end
        length(xf.sheets)
    end
    1 <= i <= n || throw(ODSError("$(xf.source) has no sheet $i: it has $n sheet(s)."))
    return xf.sheets[i]
end

Base.getindex(xf::ODSFile, i::Integer) = getsheet(xf, i)
function Base.getindex(xf::ODSFile, s::AbstractString)
    # a sheet-qualified reference to a sheet that exists (found without indexing the rest)
    if occursin('.', s) || occursin('!', s)
        ref = _tryparse_sheet_ref(s)
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
references joined by `~`, `;` or spaces.
"""
function get_defined_name_value(dn::NameDef)
    v, _, isformula = _name_value(dn)      # src/write/names.jl
    isformula && throw(ODSError("The defined name `$(dn.name)` is the expression `$(something(dn.expression, dn.range))`, " *
                                "which OpenDocumentSpreadsheets cannot evaluate."))
    return v
end
# (a missing name was a MethodError on `nothing`)
function get_defined_name_value(xf::ODSFile, name::AbstractString)
    dn = _find_name(_wb_names(xf), name)
    dn === nothing && throw(ODSError("`$name` is not a defined name of the file."))
    return get_defined_name_value(dn)
end
function get_defined_name_value(ws::Worksheet, name::AbstractString)
    dn = _find_name(_local_names(ws), name)
    dn === nothing && throw(ODSError("`$name` is not a defined name of sheet `$(ws.name)`."))
    return get_defined_name_value(dn)
end

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
gives `A1:A1` (shown as `empty` when the sheet or its file is displayed). With
`allow_load=false`, an unread sheet gives `A1:A1` without being read.
"""
function get_dimension(ws::Worksheet; allow_load::Bool = true)::CellRange
    fallback = CellRange(CellRef(1, 1), CellRef(1, 1))
    if !allow_load && ws.store === nothing
        return fallback
    end
    return something(_sheet_dimension(ws), fallback)
end

# The dimension, `nothing` for an empty sheet: the sheet is read if it hasn't been (into the cache,
# or scanned without it).
_sheet_dimension(ws::Worksheet) = store_dimension(is_cache_enabled(ws) ? _cached_store(ws) : _store_for(ws))

# The dimension for display (issue #1): `show` reads an unread sheet, as ODS records no used range.
# A sheet that can't be read shows no size rather than making `show` throw; using it shows the error.
_display_dimension(ws::Worksheet) = try
    (_sheet_dimension(ws), true)
catch e
    e isa InterruptException && rethrow()
    (nothing, false)
end

Base.size(ws::Worksheet) = size(get_dimension(ws))

function Base.show(io::IO, ws::Worksheet)
    hidden = ws.visible ? "" : " (hidden)"
    rg, ok = _display_dimension(ws)
    if rg !== nothing
        nrow, ncol = size(rg)
        print(io, nrow, "×", ncol, " OpenDocumentSpreadsheets.Worksheet: [\"", ws.name, "\"](", rg, ")", hidden)
    else
        print(io, "OpenDocumentSpreadsheets.Worksheet: [\"", ws.name, "\"]", ok ? " (empty)" : "", hidden)
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
        rg, ok = _display_dimension(s)
        if rg === nothing
            @printf(io, "%21s %s", name, ok ? "empty" : "size unknown")
        else
            sz = size(rg)
            @printf(io, "%21s %-13s %-13s", name, string(sz[1], "x", sz[2]), string(rg))
        end
        s.visible || print(io, " (hidden)")
    end
end

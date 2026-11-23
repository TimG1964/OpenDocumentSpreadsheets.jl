# The minimal style index of the read path (phase 1; phase 4's styles model replaces it).
#
# It answers the two questions reading values needs (D-016, F-019):
#   - does a cell's number format show decimals? (Int64 or Float64)
#   - does a date cell's format show a time?      (Date or DateTime)
# and gives each cell its effective style name, along the chain
#   cell style-name → row default-cell-style-name → column default-cell-style-name → Default
# (D-008, F-009). It also records which table styles hide their sheet (`table:display`).
#
# Styles come from styles.xml (`office:styles`, `office:automatic-styles`) and content.xml
# (`office:automatic-styles`). A flat document holds all of them. A cell style's data style
# is found along its `style:parent-style-name` chain.

@enum DataKind::UInt8 begin
    DK_NONE         # no data style: LibreOffice's "Standard" format
    DK_NUMBER
    DK_PERCENT
    DK_CURRENCY
    DK_DATE
    DK_TIME
    DK_BOOLEAN
    DK_TEXT
end

const _DATA_STYLE_KINDS = Dict(
    "number:number-style" => DK_NUMBER, "number:percentage-style" => DK_PERCENT,
    "number:currency-style" => DK_CURRENCY, "number:date-style" => DK_DATE,
    "number:time-style" => DK_TIME, "number:boolean-style" => DK_BOOLEAN,
    "number:text-style" => DK_TEXT)

"""
    DataStyleInfo(kind, decimals, hastime)

What the read path needs from a data style (`number:*-style`): its kind, the decimal places
its number shows (`-1` when it does not say), and, for a date style, whether it shows a time.
"""
struct DataStyleInfo
    kind::DataKind
    decimals::Int16
    hastime::Bool
end
const NO_DATA_STYLE = DataStyleInfo(DK_NONE, -1, false)

# A data style as read, before its `style:map` references are followed.
struct _RawDataStyle
    info::DataStyleInfo
    has_number::Bool          # it has its own number element
    maps::Vector{String}      # the styles its `style:map`s apply
end

"""
    LineStyles

The styles of one family of column or row styles: the properties element of each
(`style:table-column-properties` / `style:table-row-properties`), by name; the automatic
ones that say nothing else, by their properties (for deduplication); and the ones OpenDocumentSpreadsheets
added, in order.
"""
struct LineStyles
    family::String                    # "table-column" or "table-row"
    props::Dict{String,PropSet}
    dedup::Dict{PropSet,String}
    added::Vector{String}
end
LineStyles(family::AbstractString) = LineStyles(String(family), Dict{String,PropSet}(), Dict{PropSet,String}(), String[])

"""
    StyleSheet

The full cell styles of a document (phase 4), built from its XML the first time formatting
needs them (`stylesheet`, styles/stylesheet.jl):

- `cells[id + 1]`: the `CellStyle` of each style id of the `StyleIndex`
- `automatic[id + 1]`: whether it is an automatic style (else a named one, or Default)
- `datastyles`: the XML of each data style, by name; `datainfo`: what the read path knows of it
- `dedup`: the automatic styles by their properties, so that equal styles are shared
- `added` / `added_data`: the cell and data styles OpenDocumentSpreadsheets added, in order, written to
  `office:automatic-styles` on save
- `retyped`: derived styles already made for a style and a value kind (D-037)
- `data_dedup`: the added data styles by their XML
- `lines[1]` / `lines[2]`: the column and row styles (`LineStyles` of the `table-column` and
  `table-row` families)
- `default_cell`: the document's default cell properties (`style:default-style`)
- `faces` / `added_faces`: the font faces declared, and those OpenDocumentSpreadsheets added
- `display`: the named cell styles, by the name LibreOffice shows; `added_named`: those
  OpenDocumentSpreadsheets added (D-045), written to styles.xml
"""
mutable struct StyleSheet
    cells::Vector{CellStyle}
    automatic::Vector{Bool}
    datastyles::Dict{String,String}
    datainfo::Dict{String,DataStyleInfo}
    dedup::Dict{CellStyle,Int32}
    added::Vector{Int32}
    added_data::Vector{String}
    retyped::Dict{Tuple{Int32,Symbol},Int32}
    data_dedup::Dict{String,String}   # added data styles by their XML (with `$NAME` for the name)
    lines::Vector{LineStyles}         # [columns, rows]
    default_cell::CellStyle           # the `style:default-style` of family table-cell (its properties)
    faces::Set{String}                # the declared font faces (`style:font-face`), by name
    added_faces::Vector{String}       # font faces OpenDocumentSpreadsheets declared, in order
    code_styles::Dict{String,String}  # number format codes → their added data style ("" for General)
    numfmt_ids::Dict{String,Int}      # custom number format codes → their numFmtId (164 on), as getFormat meets them
    needs_loext::Bool                 # added data styles use LibreOffice's `loext:` attributes
    display::Dict{String,String}      # named cell styles: display name (else name) → style name
    added_named::Vector{Int32}        # named cell styles OpenDocumentSpreadsheets added, in order (styles.xml's office:styles)
    resolved::Dict{Tuple{Int32,Bool},NTuple{3,Dict{String,String}}}   # `resolved_props` by (id, defaults); read-only
end

"""
    StyleIndex

The cell styles of a document, numbered. Style id 0 is the document's `Default` style (or no
style at all); every other id names a cell style. `info[id + 1]` is its effective data style.
`xmls` are the documents the index was read from (styles.xml and content.xml, or a flat
document; the same strings the file holds, not copies), from which the full `StyleSheet` is
built when formatting first needs it.
"""
struct StyleIndex
    ids::Dict{String,Int32}           # cell style name → id
    names::Vector{String}             # id + 1 → name ("Default" for 0)
    info::Vector{DataStyleInfo}       # id + 1 → data style along the parent chain
    hidden_tables::Set{String}        # table styles with table:display="false"
    added::Dict{Symbol,Int32}         # OpenDocumentSpreadsheets's own typed styles (D-024), by kind, once added
    prefixes::Dict{Tuple{Int32,UInt8,Bool},String}   # the writer's cell prefixes (write/xmlout.jl)
    numbuf::Vector{UInt8}             # the writer's digit buffer (a document is written by one task at a time)
    xmls::Vector{String}              # the XML the styles were read from
    sheet::Vector{Union{Nothing,StyleSheet}}   # [the full styles], once built (phase 4)
    rich::Vector{String}              # the paragraphs of `F_RICH` cells (hyperlinks, D-072), by `bits`
    richinfo::Vector{Tuple{String,String}}   # and their link: (href, text), unescaped
    linkflat::Vector{Bool}            # [whether a new document's relative hrefs are in a flat file's form] (F-065)
end

StyleIndex(xmls::Vector{String} = String[]) =
    StyleIndex(Dict{String,Int32}(), ["Default"], [NO_DATA_STYLE], Set{String}(), Dict{Symbol,Int32}(),
               Dict{Tuple{Int32,UInt8,Bool},String}(), zeros(UInt8, 64), xmls, Union{Nothing,StyleSheet}[nothing], String[], Tuple{String,String}[], [false])

@inline style_info(s::StyleIndex, id::Integer) = @inbounds s.info[id + 1]
@inline style_name(s::StyleIndex, id::Integer) = @inbounds s.names[id + 1]

"""
    style_id(s::StyleIndex, name) -> Int32

The id of the cell style `name`, or 0 (Default) for a name the document does not define.
"""
@inline style_id(s::StyleIndex, name::AbstractString) = get(s.ids, name, Int32(0))

# Whether a number with this data style is shown with decimals (D-016): then it reads as
# Float64. "Standard" (no data style) and formats with no decimal places read whole
# numbers as Int64, as XLSX.jl does for "General".
@inline shows_decimals(d::DataStyleInfo) =
    (d.kind === DK_NUMBER || d.kind === DK_PERCENT || d.kind === DK_CURRENCY) && d.decimals > 0

"""
    build_style_index(xmls...) -> StyleIndex

Read the cell styles, data styles and table styles of the given XML documents (styles.xml,
content.xml, or a flat document; `nothing` entries are ignored). Later documents' automatic
styles add to earlier ones.
"""
function build_style_index(xmls::Union{Nothing,AbstractString}...)
    datas = Dict{String,_RawDataStyle}()
    cells = Dict{String,Tuple{Union{Nothing,String},Union{Nothing,String}}}()   # name → (parent, data style)
    default_data = Ref{Union{Nothing,String}}(nothing)   # style:default-style of table cells
    hidden = Set{String}()
    for xml in xmls
        xml === nothing && continue
        _scan_styles!(datas, cells, default_data, hidden, xml)
    end
    resolved = Dict{String,DataStyleInfo}()
    data_info(name) = get!(resolved, name) do
        _resolve_data_style(datas, name, 0)
    end
    names = sort!(collect(keys(cells)))
    filter!(!=("Default"), names)
    idx = StyleIndex(String[x for x in xmls if x !== nothing])
    # Default (id 0): the "Default" cell style, else the default style for table cells
    def = _cell_data_style(cells, "Default", default_data[])
    idx.info[1] = def === nothing ? NO_DATA_STYLE : data_info(def)
    haskey(cells, "Default") && (idx.ids["Default"] = 0)
    for n in names
        push!(idx.names, n)
        ds = _cell_data_style(cells, n, default_data[])
        push!(idx.info, ds === nothing ? NO_DATA_STYLE : data_info(ds))
        idx.ids[n] = Int32(length(idx.names) - 1)
    end
    union!(idx.hidden_tables, hidden)
    return idx
end

# The data style a cell style uses: its own, else its parent's, and so on; finally the
# default style's. Guards against parent cycles.
function _cell_data_style(cells, name::String, default_data)
    seen = 0
    n = name
    while n !== nothing && seen < 64
        entry = get(cells, n, nothing)
        entry === nothing && break
        parent, ds = entry
        ds === nothing || return ds
        n = parent
        seen += 1
    end
    return default_data
end

# A data style's info. One without a number element of its own (for example a style whose
# `style:map`s choose between a positive and a negative form) takes it from the first
# style it maps to.
function _resolve_data_style(datas, name::String, depth::Int)
    raw = get(datas, name, nothing)
    raw === nothing && return NO_DATA_STYLE
    raw.has_number && return raw.info
    depth > 8 && return raw.info
    for m in raw.maps
        sub = _resolve_data_style(datas, m, depth + 1)
        sub.kind === DK_NONE && continue
        return DataStyleInfo(raw.info.kind, sub.decimals, raw.info.hastime || sub.hastime)
    end
    return raw.info
end

function _scan_styles!(datas, cells, default_data, hidden, xml::AbstractString)
    c = XML.Cursor(xml)
    while XML.next!(c) !== nothing
        XML.nodetype(c) === XML.Element && break
    end
    XML.nodetype(c) === XML.Element || return
    rootdepth = XML.depth(c)
    # the root's children up to office:body: the styles always come before the body, so
    # the body (all the sheets) is never scanned here
    while XML.next!(c) !== nothing
        XML.depth(c) <= rootdepth && break
        (XML.nodetype(c) === XML.Element && XML.depth(c) == rootdepth + 1) || continue
        t = XML.tag(c)
        t == "office:body" && break
        if t == "office:styles" || t == "office:automatic-styles"
            XML.for_each_child!(sty -> _scan_style!(datas, cells, default_data, hidden, sty), c)
        else
            XML.skip_element!(c)
        end
    end
    return
end

function _scan_style!(datas, cells, default_data, hidden, c::XML.Cursor)
    XML.nodetype(c) === XML.Element || return
    t = XML.tag(c)
    kind = get(_DATA_STYLE_KINDS, t, nothing)
    if kind !== nothing
        name = ""
        for (k, v) in XML.eachattribute!(c)
            k == "style:name" && (name = String(v))
        end
        decimals = Int16(-1); has_number = false; hastime = false
        maps = String[]
        XML.for_each_child!(c) do el
            XML.nodetype(el) === XML.Element || return
            et = XML.tag(el)
            if et == "number:number" || et == "number:scientific-number" || et == "number:fraction"
                has_number = true
                d = Int16(0)
                for (k, v) in XML.eachattribute!(el)
                    k == "number:decimal-places" && (d = something(tryparse(Int16, v), Int16(0)))
                end
                et == "number:fraction" && (d = Int16(1))   # a fraction is not a whole number
                decimals = max(decimals, d)
            elseif et == "number:hours" || et == "number:minutes" || et == "number:seconds" || et == "number:am-pm"
                hastime = true
            elseif et == "number:boolean" || et == "number:text-content" || et == "number:day" ||
                   et == "number:month" || et == "number:year"
                has_number = true
            elseif et == "style:map"
                for (k, v) in XML.eachattribute!(el)
                    k == "style:apply-style-name" && push!(maps, String(v))
                end
            end
            XML.skip_element!(el)
        end
        # date, time, boolean and text styles are complete without a number element
        kind in (DK_DATE, DK_TIME, DK_BOOLEAN, DK_TEXT) && (has_number = true)
        isempty(name) || (datas[name] = _RawDataStyle(DataStyleInfo(kind, decimals, hastime), has_number, maps))
        return
    elseif t == "style:style"
        name = ""; family = ""; parent = nothing; ds = nothing
        for (k, v) in XML.eachattribute!(c)
            if k == "style:name"
                name = String(v)
            elseif k == "style:family"
                family = String(v)
            elseif k == "style:parent-style-name"
                parent = String(v)
            elseif k == "style:data-style-name"
                ds = String(v)
            end
        end
        if family == "table-cell"
            isempty(name) || (cells[name] = (parent, ds))
            XML.skip_element!(c)
        elseif family == "table"
            XML.for_each_child!(c) do el
                XML.nodetype(el) === XML.Element || return
                if XML.tag(el) == "style:table-properties"
                    for (k, v) in XML.eachattribute!(el)
                        k == "table:display" && v == "false" && push!(hidden, name)
                    end
                end
                XML.skip_element!(el)
            end
        else
            XML.skip_element!(c)
        end
        return
    elseif t == "style:default-style"
        family = ""; ds = nothing
        for (k, v) in XML.eachattribute!(c)
            k == "style:family" && (family = String(v))
            k == "style:data-style-name" && (ds = String(v))
        end
        family == "table-cell" && ds !== nothing && (default_data[] = ds)
    end
    XML.skip_element!(c)
    return
end

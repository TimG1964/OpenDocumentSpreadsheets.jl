# The full cell styles of a document (phase 4): built lazily from the XML the StyleIndex was
# read from, extended with deduplicated new styles, and written back as automatic styles.
#
# Plain reads and writes never build the StyleSheet: only formatting, and writing a value
# whose format does not fit a cell with more than a number format (D-037), do.

"""
    stylesheet(styles::StyleIndex) -> StyleSheet

The full cell styles of the document, built on first use.
"""
function stylesheet(styles::StyleIndex)
    sh = styles.sheet[1]
    sh === nothing || return sh
    sh = _build_stylesheet(styles)
    styles.sheet[1] = sh
    return sh
end

"""
    cell_style(styles::StyleIndex, id) -> CellStyle

The `CellStyle` of style id `id`.
"""
cell_style(styles::StyleIndex, id::Integer) = stylesheet(styles).cells[id + 1]

function _build_stylesheet(styles::StyleIndex)
    parsed = Dict{String,Tuple{CellStyle,Bool}}()
    datas = Dict{String,String}()
    lines = [LineStyles("table-column"), LineStyles("table-row")]
    defaults = [CellStyle("")]
    faces = Set{String}()
    display = Dict{String,String}()
    for xml in styles.xmls
        _scan_full_styles!(parsed, datas, lines, defaults, faces, display, xml)
    end
    # what the read path knows of each data style (styleindex.jl)
    raw = Dict{String,_RawDataStyle}()
    cells = Dict{String,Tuple{Union{Nothing,String},Union{Nothing,String}}}()
    default_data = Ref{Union{Nothing,String}}(nothing)
    hidden = Set{String}()
    for xml in styles.xmls
        _scan_styles!(raw, cells, default_data, hidden, xml)
    end
    datainfo = Dict{String,DataStyleInfo}(name => _resolve_data_style(raw, name, 0) for name in keys(raw))
    typed = Dict{Int32,Symbol}(id => kind for (kind, id) in styles.added)
    n = length(styles.names)
    sh = StyleSheet(Vector{CellStyle}(undef, n), fill(false, n), datas, datainfo, Dict{CellStyle,Int32}(),
                    Int32[], String[], Dict{Tuple{Int32,Symbol},Int32}(), Dict{String,String}(), lines,
                    defaults[1], faces, String[], Dict{String,String}(), Dict{String,Int}(), false,
                    display, Int32[], Dict{Tuple{Int32,Bool},NTuple{3,Dict{String,String}}}())
    for id in 0:n-1
        name = styles.names[id + 1]
        kind = get(typed, Int32(id), nothing)
        cs, auto = if kind !== nothing
            sh.datainfo["$name-N"] = _TYPED_STYLE_INFO[kind]
            sh.datastyles["$name-N"] = _typed_data_xml(kind, "$name-N")
            CellStyle("Default", "$name-N"), true
        else
            get(parsed, name, (CellStyle(""), false))
        end
        sh.cells[id + 1] = cs
        sh.automatic[id + 1] = auto
        auto && !haskey(sh.dedup, cs) && (sh.dedup[cs] = Int32(id))
    end
    return sh
end

# Every table-cell, table-column and table-row style and data style of a document (up to
# office:body), with their source.
function _scan_full_styles!(parsed, datas, lines::Vector{LineStyles}, defaults::Vector{CellStyle}, faces::Set{String},
                            display::Dict{String,String}, xml::AbstractString)
    c = XML.Cursor(xml)
    while XML.next!(c) !== nothing
        XML.nodetype(c) === XML.Element && break
    end
    XML.nodetype(c) === XML.Element || return
    rootdepth = XML.depth(c)
    while XML.next!(c) !== nothing
        XML.depth(c) <= rootdepth && break
        (XML.nodetype(c) === XML.Element && XML.depth(c) == rootdepth + 1) || continue
        t = XML.tag(c)
        t == "office:body" && break
        if t == "office:styles" || t == "office:automatic-styles"
            auto = t == "office:automatic-styles"
            XML.for_each_child!(c) do ch
                XML.nodetype(ch) === XML.Element || return
                tag = XML.tag(ch)
                if tag == "style:style" || (startswith(tag, "number:") && endswith(tag, "-style"))
                    text = XML.sourcetext(XML.LazyNode(ch))
                    attrs = _start_attrs(text)
                    name = XML.unescape(something(_attr_of(attrs, "style:name"), ""))
                    if tag == "style:style"
                        fam = _attr_of(attrs, "style:family")
                        if fam == "table-cell"
                            isempty(name) || (parsed[name] = (parse_cell_style(text), auto))
                            if !auto && !isempty(name)
                                dn = _attr_of(attrs, "style:display-name")
                                display[dn === nothing ? name : XML.unescape(dn)] = name
                            end
                        elseif fam == "table-column" || fam == "table-row"
                            isempty(name) || _add_line_style!(lines[fam == "table-column" ? 1 : 2], name, attrs, text, auto)
                        end
                    elseif !isempty(name)
                        datas[name] = String(text)
                    end
                elseif tag == "style:default-style"
                    text = XML.sourcetext(XML.LazyNode(ch))
                    _attr_of(_start_attrs(text), "style:family") == "table-cell" && (defaults[1] = parse_cell_style(text))
                end
                XML.skip_element!(ch)
            end
        elseif t == "office:font-face-decls"
            XML.for_each_child!(c) do ch
                if XML.nodetype(ch) === XML.Element && XML.tag(ch) == "style:font-face"
                    for (k, v) in XML.eachattribute!(ch)
                        k == "style:name" && push!(faces, String(v))
                    end
                end
                XML.skip_element!(ch)
            end
        else
            XML.skip_element!(c)
        end
    end
    return
end

# A column or row style as read: its properties element; an automatic style that says
# nothing else can be shared by equal new ones.
function _add_line_style!(ls::LineStyles, name::AbstractString, attrs, text::AbstractString, auto::Bool)
    tag = ls.family == "table-column" ? "style:table-column-properties" : "style:table-row-properties"
    props = PropSet()
    other = length(attrs) > 2                  # more than its name and family
    inner = _inner_xml(text)
    if !isempty(strip(inner))
        c = XML.Cursor(string("<x>", inner, "</x>"))
        XML.next!(c)
        XML.for_each_child!(c) do ch
            XML.nodetype(ch) === XML.Element || return
            ctext = XML.sourcetext(XML.LazyNode(ch))
            if XML.tag(ch) == tag
                props = PropSet(sort!(_start_attrs(ctext); by = first), _inner_xml(ctext))
            else
                other = true
            end
            XML.skip_element!(ch)
        end
    end
    n = XML.unescape(name)
    ls.props[n] = props
    auto && !other && !haskey(ls.dedup, props) && (ls.dedup[props] = n)
    return
end

"""
    add_line_style!(styles, family, props::PropSet) -> String

The name of an automatic column (`family = 1`) or row (`2`) style whose properties element
is `props`: an existing one with the same properties, or a new one (`odsf-co<N>`,
`odsf-ro<N>`), written to `office:automatic-styles` on save.
"""
function add_line_style!(styles::StyleIndex, family::Int, props::PropSet)
    ls = stylesheet(styles).lines[family]
    name = get(ls.dedup, props, nothing)
    name === nothing || return name
    base = family == 1 ? "odsf-co" : "odsf-ro"
    k = length(ls.added) + 1
    while haskey(ls.props, "$base$k")
        k += 1
    end
    name = "$base$k"
    ls.props[name] = props
    ls.dedup[props] = name
    push!(ls.added, name)
    return name
end

"""
    add_font_face!(styles, name) -> String

Declare the font face `name` (for `style:font-name`), unless the document declares it.
"""
function add_font_face!(styles::StyleIndex, name::AbstractString)
    sh = stylesheet(styles)
    n = String(name)
    n in sh.faces && return n
    push!(sh.faces, n)
    push!(sh.added_faces, n)
    return n
end

const _SVG_NS = "urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0"

"""
    added_faces_xml(styles) -> String

The `style:font-face` declarations OpenDocumentSpreadsheets added (as LibreOffice writes them: the family in
single quotes when it holds a space), for `office:font-face-decls`.
"""
function added_faces_xml(styles::StyleIndex)
    sh = styles.sheet[1]
    sh === nothing && return ""
    return faces_xml(sh.added_faces)
end

# `style:font-face` declarations of the faces `names`.
function faces_xml(names)
    isempty(names) && return ""
    io = IOBuffer()
    for n in names
        print(io, "<style:font-face style:name=\""); _escape_attr(io, n)
        print(io, "\" svg:font-family=\""); _escape_attr(io, occursin(' ', n) ? "'$n'" : n); print(io, "\"/>")
    end
    return String(take!(io))
end

"""
    line_props(styles, family, name) -> PropSet

The properties of column (`family = 1`) or row (`2`) style `name` (empty if unknown).
"""
line_props(styles::StyleIndex, family::Int, name::AbstractString) = get(stylesheet(styles).lines[family].props, name, PropSet())

function _attr_of(attrs::Vector{Pair{String,String}}, name::AbstractString)
    for (k, v) in attrs
        k == name && return v
    end
    return nothing
end

# A style name not used by any cell style or data style of the document.
function _fresh_style_name(styles::StyleIndex, sh::StyleSheet, base::AbstractString, k::Int)
    while true
        name = "$base$k"
        (haskey(styles.ids, name) || haskey(sh.datastyles, name)) || return name
        k += 1
    end
end

# The data style a cell style shows, along its parent chain.
function _effective_info(styles::StyleIndex, sh::StyleSheet, cs::CellStyle)
    isempty(cs.datastyle) || return get(sh.datainfo, cs.datastyle, NO_DATA_STYLE)
    isempty(cs.parent) && return style_info(styles, 0)
    return style_info(styles, style_id(styles, cs.parent))
end

# Adds a style to the index (and to the sheet, if built). Returns its id.
function _register_style!(styles::StyleIndex, name::String, info::DataStyleInfo, cs::CellStyle)
    push!(styles.names, name)
    push!(styles.info, info)
    id = Int32(length(styles.names) - 1)
    styles.ids[name] = id
    sh = styles.sheet[1]
    if sh !== nothing
        push!(sh.cells, cs)
        push!(sh.automatic, true)
        haskey(sh.dedup, cs) || (sh.dedup[cs] = id)
    end
    return id
end

"""
    add_cell_style!(styles::StyleIndex, cs::CellStyle) -> Int32

The id of an automatic style with the properties of `cs`: an existing one if the document
has one, else a new style (`odsf-ce<N>`), written to `office:automatic-styles` on save.
"""
function add_cell_style!(styles::StyleIndex, cs::CellStyle)
    sh = stylesheet(styles)
    id = get(sh.dedup, cs, nothing)
    id === nothing || return id
    name = _fresh_style_name(styles, sh, "odsf-ce", length(sh.added) + 1)
    id = _register_style!(styles, name, _effective_info(styles, sh, cs), cs)
    push!(sh.added, id)
    return id
end

"""
    add_data_style!(styles::StyleIndex, body, info::DataStyleInfo) -> String

The name of a data style whose XML is `body` with `\$NAME` standing for its name: an earlier
one with the same body, or a new one (`odsf-N<N>`), written to `office:automatic-styles`.
"""
function add_data_style!(styles::StyleIndex, body::AbstractString, info::DataStyleInfo)
    sh = stylesheet(styles)
    name = get(sh.data_dedup, body, nothing)
    name === nothing || return name
    name = _fresh_style_name(styles, sh, "odsf-N", length(sh.added_data) + 1)
    sh.datastyles[name] = replace(body, "\$NAME" => _escape_attr(name))
    sh.datainfo[name] = info
    sh.data_dedup[String(body)] = name
    push!(sh.added_data, name)
    return name
end

# LibreOffice's "Standard" number format, as it writes it (N0 in its styles.xml).
const _GENERAL_DATA_STYLE = """<number:number-style style:name="\$NAME"><number:number number:min-integer-digits="1"/></number:number-style>"""
general_data_style!(styles::StyleIndex) = add_data_style!(styles, _GENERAL_DATA_STYLE, DataStyleInfo(DK_NUMBER, 0, false))

"""
    UsedStyles(ids, cols, rows)

What a document's sheets refer to when it is written: cell style ids (cells, empty formatted
cells, column defaults), and column and row style names. Added styles outside it are not
written (D-046).
"""
struct UsedStyles
    ids::BitSet
    cols::Set{String}
    rows::Set{String}
end
UsedStyles() = UsedStyles(BitSet(), Set{String}(), Set{String}())

# The data styles `starts` name, with those their `style:map`s apply, along the chain.
function _data_closure(sh::StyleSheet, starts)
    need = Set{String}()
    todo = String[s for s in starts]
    while !isempty(todo)
        n = pop!(todo)
        (isempty(n) || n in need || !haskey(sh.datastyles, n)) && continue
        push!(need, n)
        for m in eachmatch(r"style:apply-style-name=\"([^\"]*)\"", sh.datastyles[n])
            push!(todo, XML.unescape(m.captures[1]))
        end
    end
    return need
end

"""
    added_styles_xml(styles::StyleIndex, used=nothing) -> String

The automatic styles OpenDocumentSpreadsheets added to the document: its typed styles (D-024), then the
column, row, data and cell styles added by formatting. With `used` (`UsedStyles`), only
the added cell, column and row styles the sheets refer to are written, with the data
styles those need (D-046): styles left behind by successive setters are dropped.
"""
function added_styles_xml(styles::StyleIndex, used::Union{Nothing,UsedStyles} = nothing)
    typed = typed_styles_xml(styles)
    sh = styles.sheet[1]
    (sh === nothing || (isempty(sh.added) && isempty(sh.added_data) && all(ls -> isempty(ls.added), sh.lines))) && return typed
    cells = used === nothing ? sh.added : filter(id -> id in used.ids, sh.added)
    io = IOBuffer()
    print(io, typed)
    for (k, ls) in enumerate(sh.lines), name in ls.added
        used === nothing || name in (k == 1 ? used.cols : used.rows) || continue
        print(io, "<style:style style:name=\""); _escape_attr(io, name); print(io, "\" style:family=\"", ls.family, "\">")
        _write_props(io, ls.family == "table-column" ? "style:table-column-properties" : "style:table-row-properties", ls.props[name])
        print(io, "</style:style>")
    end
    named = _named_data_styles(sh)          # these go to office:styles, with the named styles (D-045)
    keep = used === nothing ? nothing : _data_closure(sh, (sh.cells[id + 1].datastyle for id in cells))
    for name in sh.added_data
        (name in named || (keep !== nothing && !(name in keep))) || print(io, sh.datastyles[name])
    end
    for id in cells
        write_cell_style(io, style_name(styles, id), sh.cells[id + 1])
    end
    return String(take!(io))
end

"""
    retyped_style(styles, old::Int32, kind) -> Int32

The style for a value needing `kind` (`:date`, `:datetime`, `:time`, `:boolean`, or `nothing`
for numbers and text) written into a cell of style `old`, whose number format doesn't fit it
(D-037). A style that says nothing but its number format gives way to OpenDocumentSpreadsheets's typed style
(or `Default`), as before (D-027). Any other style is kept, with only its number format
replaced, so that fonts, fills and the rest stay.
"""
function retyped_style(styles::StyleIndex, old::Int32, kind::Union{Nothing,Symbol})
    sh = stylesheet(styles)
    key = (old, something(kind, :other))
    r = get(sh.retyped, key, nothing)
    r === nothing || return r
    cs = sh.cells[old + 1]
    auto = sh.automatic[old + 1]
    r = if auto && is_plain(cs) && cs.parent in ("Default", "")
        kind === nothing ? Int32(0) : typed_style_id(styles, kind)
    else
        # an automatic style keeps its parent; a named style becomes the parent
        base = auto ? cs : CellStyle(style_name(styles, old))
        ds = if kind === nothing
            pinfo = isempty(base.parent) ? style_info(styles, 0) : style_info(styles, style_id(styles, base.parent))
            pinfo.kind in (DK_DATE, DK_TIME, DK_BOOLEAN) ? general_data_style!(styles) : ""
        else
            style_name(styles, typed_style_id(styles, kind)) * "-N"
        end
        add_cell_style!(styles, with_datastyle(base, ds))
    end
    sh.retyped[key] = r
    return r
end

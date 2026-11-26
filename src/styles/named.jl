# Named cell styles (phase 4 step 8, D-045): `getCellStyle`, `setCellStyle`, `addCellStyle!`.
#
# ODF's named ("common") cell styles live in styles.xml's `office:styles`, with a
# `style:name` encoded from the name shown to users (`style:display-name`, F-040). Cells refer
# to them directly, or through an automatic style whose parent they are (direct formatting
# over the named style, D-035). XLSX.jl has no counterpart; the semantics are LibreOffice's
# (experiment 018).

#
# Names
#

# Whether a character may start (`start`) or continue an XML NCName, as far as LibreOffice's
# style name encoding needs (letters, digits, '.', '-'; F-040).
_ncname_char(c::Char, start::Bool) =
    isletter(c) || (!start && (('0' <= c <= '9') || c == '.' || c == '-' || (c > '\x7f' && isnumeric(c))))

"""
    encode_style_name(display) -> String

The `style:name` LibreOffice writes for a style shown as `display`: every character
an XML NCName can't hold, and every `_`, becomes `_xx_` (the lower-case hex of its UTF-16
code units).
"""
function encode_style_name(display::AbstractString)
    io = IOBuffer()
    start = true
    for c in display
        if c != '_' && _ncname_char(c, start)
            print(io, c)
        else
            for u in transcode(UInt16, string(c))
                print(io, '_', string(u; base = 16), '_')
            end
        end
        start = false
    end
    return String(take!(io))
end

# The name shown for named style `name` (its `style:display-name`, else its name).
function _display_name(st::StyleIndex, name::AbstractString)
    (isempty(name) || name == "Default") && return "Default"
    id = get(st.ids, name, nothing)
    id === nothing && return String(name)
    dn = getprop(PropSet(cell_style(st, id).attrs, ""), "style:display-name")
    return dn === nothing ? String(name) : XML.unescape(dn)
end

#
# LibreOffice's built-in cell styles (F-041), as LibreOffice 26.8.3 writes them in every
# document's styles.xml (experiment 018, out/lo/blank.styles.xml). They are added to a
# document, with their parents, the first time `setCellStyle` or `addCellStyle!(…; parent)`
# names one it doesn't define.
#

const _LO_BUILTIN_XML = [
    """<style:style style:name="Heading" style:family="table-cell" style:parent-style-name="Default"><style:table-cell-properties fo:wrap-option="no-wrap" style:shrink-to-fit="false"/><style:text-properties fo:font-size="24pt" fo:font-style="normal" fo:font-weight="bold" style:font-size-asian="24pt" style:font-style-asian="normal" style:font-weight-asian="bold" style:font-size-complex="24pt" style:font-style-complex="normal" style:font-weight-complex="bold"/></style:style>""",
    """<style:style style:name="Heading_20_1" style:display-name="Heading 1" style:family="table-cell" style:parent-style-name="Heading"><style:table-cell-properties fo:wrap-option="no-wrap" style:shrink-to-fit="false"/><style:text-properties fo:font-size="18pt" style:font-size-asian="18pt" style:font-size-complex="18pt"/></style:style>""",
    """<style:style style:name="Heading_20_2" style:display-name="Heading 2" style:family="table-cell" style:parent-style-name="Heading"><style:table-cell-properties fo:wrap-option="no-wrap" style:shrink-to-fit="false"/><style:text-properties fo:font-size="12pt" style:font-size-asian="12pt" style:font-size-complex="12pt"/></style:style>""",
    """<style:style style:name="Text" style:family="table-cell" style:parent-style-name="Default"><style:table-cell-properties fo:wrap-option="no-wrap" style:shrink-to-fit="false"/></style:style>""",
    """<style:style style:name="Note" style:family="table-cell" style:parent-style-name="Text"><style:table-cell-properties fo:background-color="#ffffcc" style:diagonal-bl-tr="none" style:diagonal-tl-br="none" fo:wrap-option="no-wrap" fo:border="0.74pt solid #808080" style:shrink-to-fit="false"/><style:text-properties fo:color="#333333"/></style:style>""",
    """<style:style style:name="Footnote" style:family="table-cell" style:parent-style-name="Text"><style:table-cell-properties fo:wrap-option="no-wrap" style:shrink-to-fit="false"/><style:text-properties fo:color="#808080" fo:font-style="italic" style:font-style-asian="italic" style:font-style-complex="italic"/></style:style>""",
    """<style:style style:name="Hyperlink" style:family="table-cell" style:parent-style-name="Text"><style:table-cell-properties fo:wrap-option="no-wrap" style:shrink-to-fit="false"/><style:text-properties fo:color="#0000ee" style:text-underline-style="solid" style:text-underline-width="auto" style:text-underline-color="#0000ee"/></style:style>""",
    """<style:style style:name="Status" style:family="table-cell" style:parent-style-name="Default"><style:table-cell-properties fo:wrap-option="no-wrap" style:shrink-to-fit="false"/></style:style>""",
    """<style:style style:name="Good" style:family="table-cell" style:parent-style-name="Status"><style:table-cell-properties fo:background-color="#ccffcc" fo:wrap-option="no-wrap" style:shrink-to-fit="false"/><style:text-properties fo:color="#006600"/></style:style>""",
    """<style:style style:name="Neutral" style:family="table-cell" style:parent-style-name="Status"><style:table-cell-properties fo:background-color="#ffffcc" fo:wrap-option="no-wrap" style:shrink-to-fit="false"/><style:text-properties fo:color="#996600"/></style:style>""",
    """<style:style style:name="Bad" style:family="table-cell" style:parent-style-name="Status"><style:table-cell-properties fo:background-color="#ffcccc" fo:wrap-option="no-wrap" style:shrink-to-fit="false"/><style:text-properties fo:color="#cc0000"/></style:style>""",
    """<style:style style:name="Warning" style:family="table-cell" style:parent-style-name="Status"><style:table-cell-properties fo:wrap-option="no-wrap" style:shrink-to-fit="false"/><style:text-properties fo:color="#cc0000"/></style:style>""",
    """<style:style style:name="Error" style:family="table-cell" style:parent-style-name="Status"><style:table-cell-properties fo:background-color="#cc0000" fo:wrap-option="no-wrap" style:shrink-to-fit="false"/><style:text-properties fo:color="#ffffff" fo:font-weight="bold" style:font-weight-asian="bold" style:font-weight-complex="bold"/></style:style>""",
    """<style:style style:name="Accent" style:family="table-cell" style:parent-style-name="Default"><style:table-cell-properties fo:wrap-option="no-wrap" style:shrink-to-fit="false"/><style:text-properties fo:font-weight="bold" style:font-weight-asian="bold" style:font-weight-complex="bold"/></style:style>""",
    """<style:style style:name="Accent_20_1" style:display-name="Accent 1" style:family="table-cell" style:parent-style-name="Accent"><style:table-cell-properties fo:background-color="#000000" fo:wrap-option="no-wrap" style:shrink-to-fit="false"/><style:text-properties fo:color="#ffffff"/></style:style>""",
    """<style:style style:name="Accent_20_2" style:display-name="Accent 2" style:family="table-cell" style:parent-style-name="Accent"><style:table-cell-properties fo:background-color="#808080" fo:wrap-option="no-wrap" style:shrink-to-fit="false"/><style:text-properties fo:color="#ffffff"/></style:style>""",
    """<style:style style:name="Accent_20_3" style:display-name="Accent 3" style:family="table-cell" style:parent-style-name="Accent"><style:table-cell-properties fo:background-color="#dddddd" fo:wrap-option="no-wrap" style:shrink-to-fit="false"/></style:style>""",
    """<style:style style:name="Result" style:family="table-cell" style:parent-style-name="Default"><style:table-cell-properties fo:wrap-option="no-wrap" style:shrink-to-fit="false"/><style:text-properties fo:font-style="italic" style:text-underline-style="solid" style:text-underline-width="auto" style:text-underline-color="font-color" fo:font-weight="bold" style:font-style-asian="italic" style:font-weight-asian="bold" style:font-style-complex="italic" style:font-weight-complex="bold"/></style:style>""",
]

# display name => (style name, XML)
const _LO_BUILTINS = let d = Dict{String,Tuple{String,String}}()
    for x in _LO_BUILTIN_XML
        name = match(r"style:name=\"([^\"]*)\"", x).captures[1]
        dn = match(r"style:display-name=\"([^\"]*)\"", x)
        d[dn === nothing ? name : dn.captures[1]] = (name, x)
    end
    d
end

# The XML of the built-in style named `name` (its `style:name`), or `nothing`.
function _builtin_xml(name::AbstractString)
    for (sn, x) in values(_LO_BUILTINS)
        sn == name && return x
    end
    return nothing
end

# The id of the named style `name` (a display name or a `style:name`), adding a LibreOffice
# built-in the document lacks; `nothing` if there is none.
function _find_named_style(st::StyleIndex, name::AbstractString)
    name == "Default" && return Int32(0)
    sh = stylesheet(st)
    n = get(sh.display, name, nothing)
    n === nothing || return st.ids[n]
    id = get(st.ids, name, nothing)
    id !== nothing && !sh.automatic[id + 1] && return id
    for (dn, (sn, xml)) in _LO_BUILTINS
        (dn == name || sn == name) || continue
        cs = parse_cell_style(xml)
        isempty(cs.parent) || cs.parent == "Default" || _find_named_style(st, cs.parent)
        return _register_named!(st, sn, dn, cs)
    end
    return nothing
end

function _named_style_id(st::StyleIndex, name::AbstractString)
    id = _find_named_style(st, name)
    id === nothing || return id
    known = sort!(collect(keys(stylesheet(st).display)))
    throw(ODSError("There is no cell style named `$name`. The file's named styles are: $(join(known, ", ")); " *
                   "LibreOffice's built-in ones are added when used ($(join(sort!(collect(keys(_LO_BUILTINS))), ", ")))."))
end

# Adds a named style to the index and the sheet; returns its id.
function _register_named!(st::StyleIndex, name::String, display::String, cs::CellStyle)
    sh = stylesheet(st)
    info = _effective_info(st, sh, cs)
    push!(st.names, name)
    push!(st.info, info)
    id = Int32(length(st.names) - 1)
    st.ids[name] = id
    push!(sh.cells, cs)
    push!(sh.automatic, false)
    push!(sh.added_named, id)
    sh.display[display] = name
    empty!(sh.resolved)          # a style naming this one as its parent now resolves through it
    return id
end

#
# The XML of added named styles: in styles.xml's office:styles, with the data styles they use
# and the font faces they name (F-040)
#

has_named_styles(st::StyleIndex) = (sh = st.sheet[1]; sh !== nothing && !isempty(sh.added_named))

# The added data styles the added named styles use, with those their `style:map`s apply.
function _named_data_styles(sh::StyleSheet)
    isempty(sh.added_named) && return Set{String}()
    return intersect!(_data_closure(sh, (sh.cells[id + 1].datastyle for id in sh.added_named)), Set(sh.added_data))
end

"""
    named_styles_xml(st) -> String

The named styles OpenDocumentSpreadsheets added (parents first), after the added data styles they use, for
`office:styles`.
"""
function named_styles_xml(st::StyleIndex)
    has_named_styles(st) || return ""
    sh = stylesheet(st)
    io = IOBuffer()
    need = _named_data_styles(sh)
    for n in sh.added_data
        n in need && print(io, sh.datastyles[n])
    end
    for id in sh.added_named
        name = style_name(st, id)
        b = _builtin_xml(name)
        # a built-in as LibreOffice writes it; any other style from its model
        b === nothing ? write_cell_style(io, name, sh.cells[id + 1]) : print(io, b)
    end
    return String(take!(io))
end

# The font faces the added named styles name, in order of first use.
function _named_faces(st::StyleIndex)
    has_named_styles(st) || return String[]
    sh = stylesheet(st)
    out = String[]
    for id in sh.added_named, (k, v) in sh.cells[id + 1].text.attrs
        if k in ("style:font-name", "style:font-name-asian", "style:font-name-complex")
            n = XML.unescape(v)
            n in out || push!(out, n)
        end
    end
    return out
end

#
# The API
#

"""
    getCellStyle(sheet, ref) -> String
    getCellStyle(sheet, row, col)
    getCellStyle(xf, "Sheet1.A1")

The named cell style of a cell, by the name LibreOffice shows ("Heading 1", "Good",
"Default"). A cell with direct formatting reports the named style under it. Works on
read-only files.
"""
function getCellStyle(x::Union{Worksheet,ODSFile}, ref...)
    ws, r, c = format_cell(x, ref...)
    st = get_odsfile(ws).styles
    id = effective_style(ws, r, c)
    sh = stylesheet(st)
    name = sh.automatic[id + 1] ? sh.cells[id + 1].parent : style_name(st, id)
    return _display_name(st, name)
end

# The Calc item an ODF attribute belongs to: applying a style clears whole items (F-039).
const _FONT_NAME_RE = r"^(?:style:font-name|fo:font-family|style:font-family|style:font-family-generic|style:font-pitch|style:font-charset)(-asian|-complex)?$"
function _item_of(k::AbstractString)
    (startswith(k, "fo:border") || startswith(k, "style:border-line-width")) && return "border"
    startswith(k, "fo:padding") && return "padding"
    startswith(k, "style:text-underline-") && return "underline"
    startswith(k, "style:text-line-through-") && return "strike"
    startswith(k, "style:text-overline-") && return "overline"
    k in ("fo:text-align", "style:text-align-source", "style:repeat-content") && return "halign"
    m = match(_FONT_NAME_RE, k)
    m === nothing || return "font" * something(m.captures[1], "")
    return String(k)
end

# A memoised map from a cell's style to the one it gets when named style `nid` is applied
# (F-039): a named style (or Default) gives way to it; an automatic style keeps the direct
# properties the named style's chain doesn't set, and its number format unless the chain
# sets one.
function _apply_named_map(st::StyleIndex, nid::Int32)
    sh = stylesheet(st)
    named = nid == 0 ? "Default" : style_name(st, nid)
    items = Set{String}()
    sets_format = false
    for s in _style_chain(st, sh.cells[nid + 1])
        for p in (s.cell, s.para, s.text), (k, _) in p.attrs
            push!(items, _item_of(k))
        end
        sets_format |= !isempty(s.datastyle)
    end
    keep(p::PropSet) = PropSet(filter(a -> !(_item_of(a.first) in items), p.attrs), p.inner)
    memo = Dict{Int32,Int32}()
    return id -> get!(memo, Int32(id)) do
        sh.automatic[id + 1] || return nid
        cs = sh.cells[id + 1]
        new = CellStyle(named, sets_format ? "" : cs.datastyle, cs.attrs, keep(cs.cell), keep(cs.para), keep(cs.text), cs.extra)
        is_plain(new) && isempty(new.datastyle) ? nid : add_cell_style!(st, new)
    end
end

"""
    setCellStyle(sheet, ref, name) -> String or -1
    setCellStyle(sheet, row, col, name)
    setCellStyle(xf, "Sheet1.A1:B2", name)

Apply the named cell style `name` to cells (address forms as [`setFont`](@ref)). `name` is
the name LibreOffice shows ("Heading 1") or the style's name in the file (`Heading_20_1`).
LibreOffice's built-in styles (Heading, Heading 1, Heading 2, Text, Note, Footnote,
Hyperlink, Status, Good, Neutral, Bad, Warning, Error, Accent, Accent 1 to 3, Result) are
added to a file that lacks them.

As in LibreOffice, a cell's direct formatting stays, except for what the style sets: a
style with a font size replaces the cell's own size, and a cell's number format stays
unless the style has one (so dates stay dates). Returns the name of the cell's new style
for a single cell (`name`'s style name when no direct formatting is left), else -1.
"""
function setCellStyle(x::Union{Worksheet,ODSFile}, args...)
    length(args) >= 2 && args[end] isa AbstractString ||
        throw(ODSError("`setCellStyle` takes a cell reference and a style name: `setCellStyle(sheet, \"A1\", \"Heading 1\")`."))
    ref = args[1:end-1]
    targets = format_targets(x, ref...)
    st = _styles_of(x)
    for (ws, _) in targets
        _require_writable(ws, "set cell styles")
    end
    m = _apply_named_map(st, _named_style_id(st, args[end]))
    for (ws, blocks) in targets
        _apply_map!(m, ws, blocks)
    end
    return _result(targets)
end

# Keyword arguments from a NamedTuple, a Dict or a vector of pairs.
_family_kw(x::NamedTuple) = pairs(x)
_family_kw(x::AbstractDict) = (Symbol(k) => v for (k, v) in x)
_family_kw(x::AbstractVector{<:Pair}) = (Symbol(k) => v for (k, v) in x)
_family_kw(x) = throw(ODSError("A style's font, fill, border or alignment is a NamedTuple of the setter's keywords, such as `font = (bold = true, size = 14)`; got $(repr(x))."))

"""
    addCellStyle!(xf, name; parent="Default", font, fill, border, alignment, format) -> String

Define the named cell style `name` in the file, to be applied with
[`setCellStyle`](@ref). Its properties are given as the setters take them:

- `font`: a NamedTuple of [`setFont`](@ref)'s keywords, such as `(bold = true, size = 14)`
- `fill`: [`setFill`](@ref)'s, such as `(pattern = "solid", fgColor = "FFFF00")`
- `border`: [`setBorder`](@ref)'s, such as `(allsides = ["style" => "thin"],)`
- `alignment`: [`setAlignment`](@ref)'s, such as `(horizontal = "center",)`
- `format`: a number format, as [`setFormat`](@ref) takes it

Properties not given come from `parent`, a named style (by default `Default`; LibreOffice's
built-in styles are added when needed). The style is written to styles.xml with the name
encoded as LibreOffice encodes it (`"My Style"` is `My_20_Style`, shown as "My Style").
Returns that name.
"""
function addCellStyle!(xf::ODSFile, name::AbstractString; parent::AbstractString = "Default", font = nothing, fill = nothing,
                       border = nothing, alignment = nothing, format::Union{Nothing,AbstractString} = nothing, kw...)
    _check_keywords(:addCellStyle!, kw)
    _require_writable(xf, "add a cell style")
    isempty(name) && throw(ODSError("A cell style needs a name."))
    _check_xml_text(name)
    st = xf.styles
    sh = stylesheet(st)
    enc = encode_style_name(name)
    (name == "Default" || haskey(sh.display, name) || haskey(st.ids, enc) || haskey(_LO_BUILTINS, name)) &&
        throw(ODSError("There is already a cell style named `$name`."))
    pid = _named_style_id(st, parent)
    cs = CellStyle(pid == 0 ? "Default" : style_name(st, pid))
    if border !== nothing
        any(p -> first(p) === :outside, _family_kw(border)) &&
            throw(ODSError("A cell style's border can't be `outside` (that is a range's border): use `allsides` or the sides."))
    end
    for (T, v) in ((_font_transform, font), (_fill_transform, fill), (_border_transform, border), (_alignment_transform, alignment))
        v === nothing && continue
        cs = T(st, :addCellStyle!; _family_kw(v)...)(cs)
    end
    format === nothing || (cs = _format_transform(st, :addCellStyle!; format)(cs))
    attrs = enc == name ? cs.attrs : sort!(vcat(cs.attrs, ["style:display-name" => sprint(_escape_attr, name)]); by = first)
    cs = CellStyle(cs.parent, cs.datastyle, attrs, cs.cell, cs.para, cs.text, cs.extra)
    _register_named!(st, enc, String(name), cs)
    return enc
end

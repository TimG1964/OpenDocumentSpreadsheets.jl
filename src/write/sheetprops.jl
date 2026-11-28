# Hiding rows and columns, sheet visibility and tab colours (phase 5 step 6; D-059), with XLSX.jl's
# API and LibreOffice's forms (experiment 023 part A, F-051).
#
# Adapted from XLSX.jl 0.13.4 (src/cellformats/rowscols.jl `setColumnHidden`, `setRowHidden`,
# `isColumnHidden`, `isRowHidden`; src/sheetsettings.jl `setSheetVisibility`, `getSheetVisibility`,
# `setTabColor`, `getTabColor`, `deleteTabColor`), MIT License, Copyright (c) 2018-2026 Felipe Noronha
# Tavares and other contributors. Changes: rows and columns are hidden through the formats layer
# (`table:visibility="collapse"`); a sheet's visibility and tab colour are its table style's, so a
# change derives a new automatic table style; `:veryHidden` is `:hidden`, as LibreOffice imports it.
#
# Rows and columns: `table:visibility` of their elements, already read and written by the formats
# layer (src/styles/formats.jl). Sheets: `table:display` and `table:tab-color` in the
# `style:table-properties` of the automatic table style the table names. LibreOffice shares one table
# style between sheets with the same properties, so a change never edits a style: it derives one
# (`ta_odsf1`, …; reused for the same properties) and points the table at it.

#
# Rows and columns
#

_hide_sheet(xf::ODSFile, ref::AbstractString) = _sheet_and_lines(xf, ref)

function _hidden_lines(ws::Worksheet, axis::Int, x)
    spans = _lines_of(ws, axis, x)
    isempty(spans) && throw(ODSError("No $(axis == 1 ? "rows" : "columns") given."))
    for r in spans
        _check_line(axis, first(r), axis == 1 ? "Row" : "Column")
        _check_line(axis, last(r), axis == 1 ? "Row" : "Column")
    end
    return _merge_ranges(spans)
end

"""
    setRowHidden(sheet, rows; hidden=true)
    setRowHidden(xf, "Sheet1.3:5"; hidden=true)

Hide the rows `rows`, or show them again with `hidden=false`. `rows` is a row number, a range
or vector of them, or a string naming rows (`"3"`, `"3:5"`), cells (`"A3:D5"`: their rows), a
defined name, or several of these separated by commas (`"3:4,8"`). The rows needn't hold
anything. As LibreOffice, hidden rows keep their height (`table:visibility="collapse"`).

See also [`isRowHidden`](@ref), [`setColumnHidden`](@ref).
"""
function setRowHidden(ws::Worksheet, rows; hidden::Bool = true)
    _require_writable(ws, "hide rows")
    for r in _hidden_lines(ws, 1, rows)
        set_row_formats!(ws, r; visibility = hidden ? "collapse" : _VISIBLE)
    end
    return nothing
end
setRowHidden(xf::ODSFile, ref::AbstractString; hidden::Bool = true) = setRowHidden(_hide_sheet(xf, ref)...; hidden)

"""
    setColumnHidden(sheet, cols; hidden=true)
    setColumnHidden(xf, "Sheet1.B:D"; hidden=true)

Hide the columns `cols`, or show them again with `hidden=false`. `cols` is a column number, a
range or vector of them, or a string naming columns (`"B"`, `"B:D"`), cells (`"B2:D5"`: their
columns), a defined name, or several of these separated by commas (`"B:C,F"`).

See also [`isColumnHidden`](@ref), [`setRowHidden`](@ref).
"""
function setColumnHidden(ws::Worksheet, cols; hidden::Bool = true)
    _require_writable(ws, "hide columns")
    for r in _hidden_lines(ws, 2, cols)
        set_column_formats!(ws, r; visibility = hidden ? "collapse" : _VISIBLE)
    end
    return nothing
end
setColumnHidden(xf::ODSFile, ref::AbstractString; hidden::Bool = true) = setColumnHidden(_hide_sheet(xf, ref)...; hidden)

function _single_line(ws::Worksheet, axis::Int, x)
    spans = _lines_of(ws, axis, x)
    (length(spans) == 1 && length(only(spans)) == 1) ||
        throw(ODSError("Give a single $(axis == 1 ? "row" : "column"), not $(join(spans, ", "))."))
    n = first(only(spans))
    _check_line(axis, n, axis == 1 ? "Row" : "Column")
    return n
end

"""
    isRowHidden(sheet, row) -> Bool
    isRowHidden(xf, "Sheet1.5") -> Bool

Whether row `row` (a number, or a string naming a row or a cell in it) is hidden: by hand, or by
a filter (`table:visibility="filter"`). Works on read-only files.
"""
function isRowHidden(ws::Worksheet, row)
    r = _fmt_at(sheet_formats(ws).rows, _single_line(ws, 1, row))
    return r !== nothing && r.visibility != _VISIBLE
end
isRowHidden(xf::ODSFile, ref::AbstractString) = isRowHidden(_hide_sheet(xf, ref)...)

"""
    isColumnHidden(sheet, col) -> Bool
    isColumnHidden(xf, "Sheet1.C") -> Bool

Whether column `col` (a number, or a string naming a column or a cell in it) is hidden. Works
on read-only files.
"""
function isColumnHidden(ws::Worksheet, col)
    r = _fmt_at(sheet_formats(ws).cols, _single_line(ws, 2, col))
    return r !== nothing && r.visibility != _VISIBLE
end
isColumnHidden(xf::ODSFile, ref::AbstractString) = isColumnHidden(_hide_sheet(xf, ref)...)

#
# Sheets: their table styles
#

# The value of attribute `name` in a start tag, or nothing.
function _start_tag_attr(tag::AbstractString, name::AbstractString)
    for (k, v) in _raw_attrs(tag)
        k == name && return XML.unescape(String(SubString(v, nextind(v, 1), prevind(v, lastindex(v)))))
    end
    return nothing
end

# The table style a sheet's text names.
function _table_style_name(ws::Worksheet)
    ws.entry === nothing && return nothing
    v = get(ws.entry.node, "table:style-name", nothing)       # the start tag only
    return v === nothing ? nothing : String(v)
end

# The span of the automatic styles of a document (content.xml, or a flat document).
function _autostyles_span(s::String)
    a = findfirst("<office:automatic-styles", s)
    a === nothing && return nothing
    b = findnext("</office:automatic-styles>", s, last(a))
    b === nothing && return nothing
    return first(a):last(b)
end

const _STYLE_ELEMENT_RX = r"<style:style\b[^>]*?(?:/>|>.*?</style:style>)"s

# The XML of the table style `name`: one OpenDocumentSpreadsheets derived, or the file's.
function _table_style_xml(xf::ODSFile, name::AbstractString)
    for (n, x) in xf.tstyles.added
        n == name && return x
    end
    sp = _autostyles_span(xf.content)
    sp === nothing && return nothing
    for m in eachmatch(_STYLE_ELEMENT_RX, SubString(xf.content, first(sp), last(sp)))
        tag = SubString(m.match, 1, _start_tag_end(m.match))
        _start_tag_attr(tag, "style:family") == "table" && _start_tag_attr(tag, "style:name") == name && return String(m.match)
    end
    return nothing
end

const _TABLE_PROPS_RX = r"<style:table-properties\b[^>]*?/?>"

# (display, tab colour, right to left) of a table style's XML. LibreOffice writes `table:tab-color`
# in ODF 1.3 and later, and `tableooo:tab-color` before (F-051); the direction is
# `style:writing-mode` (`rl-tb`, F-053).
function _table_style_props(x::Union{Nothing,String})
    x === nothing && return (true, nothing, false)
    m = match(_TABLE_PROPS_RX, x)
    m === nothing && return (true, nothing, false)
    d = _start_tag_attr(m.match, "table:display")
    c = something(_start_tag_attr(m.match, "table:tab-color"), _start_tag_attr(m.match, "tableooo:tab-color"), Some(nothing))
    w = _start_tag_attr(m.match, "style:writing-mode")
    return (d != "false", c === nothing ? nothing : lowercase(c), w !== nothing && startswith(w, "rl"))
end

# The master page a table style's XML names, or nothing.
_table_style_master(x::Union{Nothing,String}) = x === nothing ? nothing : _start_tag_attr(SubString(x, 1, _start_tag_end(x)), "style:master-page-name")

# A sheet's properties, read on first use.
function _sheet_props(ws::Worksheet)
    ws.props === nothing || return ws.props
    name = _table_style_name(ws)
    x = name === nothing ? nothing : _table_style_xml(get_odsfile(ws), name)
    d, c, rtl = _table_style_props(x)
    ws.props = SheetProps(d, c, rtl, _table_style_master(x), name, name)
    return ws.props
end

# The table style with these properties: the sheet's own if it has them, else one derived from it
# (reused when one with the same XML exists). `master`: the master page it names (phase 5 step 10).
function _restyle_table!(ws::Worksheet, display::Bool, color::Union{Nothing,String}; rtl::Bool = _sheet_props(ws).rtl,
                         master::Union{Nothing,String} = _sheet_props(ws).master)
    xf = get_odsfile(ws)
    p = _sheet_props(ws)
    base = p.base
    bx = base === nothing ? nothing : _table_style_xml(xf, base)
    bd, bc, br = _table_style_props(bx)
    bm = _table_style_master(bx)
    p.display = display
    p.tabcolor = color
    p.rtl = rtl
    p.master = master
    if base !== nothing && bd == display && bc == color && br == rtl && bm == master
        p.style = base                                   # back as it was: the text's own style
        return
    end
    if base === nothing && display && color === nothing && !rtl && master === nothing
        p.style = nothing
        return
    end
    x = bx
    x === nothing && (x = "<style:style style:name=\"\" style:family=\"table\"><style:table-properties/></style:style>")
    master == bm || (x = _set_attrs(x, Pair{String,Union{Nothing,String}}["style:master-page-name" => master === nothing ? nothing : _escape_attr(master)]))
    r = findfirst(_TABLE_PROPS_RX, x)
    if r === nothing
        e = _start_tag_end(x)
        if x[prevind(x, e)] == '/'                       # <style:style …/>
            x = _set_attrs(x, Pair{String,Union{Nothing,String}}[]; open = true) * "<style:table-properties/></style:style>"
        else
            x = x[1:e] * "<style:table-properties/>" * x[nextind(x, e):end]
        end
        r = findfirst(_TABLE_PROPS_RX, x)
    end
    changes = Pair{String,Union{Nothing,String}}["table:display" => display ? "true" : "false",
                                                 "table:tab-color" => color, "tableooo:tab-color" => nothing]
    rtl == br || push!(changes, "style:writing-mode" => rtl ? "rl-tb" : "lr-tb")   # only when it changes
    props = _set_attrs(x[r], changes)
    x = x[1:prevind(x, first(r))] * props * x[nextind(x, last(r)):end]
    key(y) = _set_attrs(y, Pair{String,Union{Nothing,String}}["style:name" => ""])
    k = key(x)
    for (n, y) in xf.tstyles.added
        key(y) == k && (p.style = n; return)
    end
    i = length(xf.tstyles.added) + 1
    while occursin("style:name=\"ta_odsf$i\"", xf.content)
        i += 1
    end
    name = "ta_odsf$i"
    push!(xf.tstyles.added, name => _set_attrs(x, Pair{String,Union{Nothing,String}}["style:name" => name]))
    p.style = name
    return
end

_props_changed(ws::Worksheet) = ws.props !== nothing && ws.props.style != ws.props.base

# The table styles OpenDocumentSpreadsheets derived that a sheet now names, as XML for the automatic styles.
function _table_styles_xml(xf::ODSFile)
    isempty(xf.tstyles.added) && return ""
    used = Set{String}()
    for ws in xf.sheets
        p = ws.props
        p === nothing ? (n = _table_style_name(ws); n === nothing || push!(used, n)) : (p.style === nothing || push!(used, p.style))
    end
    return join(x for (n, x) in xf.tstyles.added if n in used)
end

"""
    setSheetVisibility(sheet, visibility::Symbol)

Show (`:visible`) or hide (`:hidden`) a sheet's tab, as LibreOffice's Sheet ▸ Show Sheet and Hide
Sheet do. `:veryHidden` is also accepted, and hides the sheet as `:hidden` does: OpenDocument has
only one kind of hidden sheet. The file
must keep a visible sheet, so hiding the last one is an error (LibreOffice ignores it). When the
sheet LibreOffice opens on is hidden, it opens on the visible sheet before it (or the first
visible one), as LibreOffice does when that sheet is hidden.

See also [`getSheetVisibility`](@ref).
"""
function setSheetVisibility(ws::Worksheet, visibility::Symbol)
    _require_writable(ws, "change a sheet's visibility")
    visibility in (:visible, :hidden, :veryHidden) ||
        throw(ODSError("Invalid visibility `:$visibility`. Must be one of visible, hidden, veryHidden."))
    show = visibility === :visible
    p = _sheet_props(ws)
    p.display == show && return nothing
    xf = get_odsfile(ws)
    if !show && count(s -> s !== ws && getSheetVisibility(s) === :visible, _sheets(xf)) == 0
        throw(ODSError("Can't hide `$(ws.name)`: it is the file's only visible sheet."))
    end
    _restyle_table!(ws, show, p.tabcolor)
    ws.visible = show
    xf.tstyles.shown_changed = true
    return nothing
end

"""
    getSheetVisibility(sheet) -> Symbol

`:visible` or `:hidden`. Works on read-only files.
"""
getSheetVisibility(ws::Worksheet) = ws.props === nothing ? (ws.visible ? :visible : :hidden) :
                                                           (ws.props.display ? :visible : :hidden)

"""
    setTabColor(sheet, color)

Colour a sheet's tab: a hex colour (`"FF0000"`, `"#FF0000"`, `"FFFF0000"`: the alpha is ignored,
as LibreOffice ignores it), a Colors.jl colour name or a `Colorant`. Theme colours are
not accepted, as elsewhere in OpenDocumentSpreadsheets.

See also [`getTabColor`](@ref), [`deleteTabColor`](@ref).
"""
function setTabColor(ws::Worksheet, color)
    _require_writable(ws, "set a tab colour")
    c = SheetCore.odf_color(color)
    p = _sheet_props(ws)
    p.tabcolor == c || _restyle_table!(ws, p.display, c)
    return nothing
end

"""
    getTabColor(sheet) -> Union{Nothing, String}

The colour of a sheet's tab as `"FFRRGGBB"`, or `nothing` if it has none. Works on read-only
files.
"""
function getTabColor(ws::Worksheet)
    c = _sheet_props(ws).tabcolor
    c === nothing && return nothing
    return SheetCore.parse_odf_color(c)
end

"""
    deleteTabColor(sheet) -> Bool

Remove a sheet's tab colour. `false` if it had none.
"""
function deleteTabColor(ws::Worksheet)
    _require_writable(ws, "remove a tab colour")
    p = _sheet_props(ws)
    p.tabcolor === nothing && return false
    _restyle_table!(ws, p.display, nothing)
    return true
end

#
# The sheet LibreOffice opens on (settings.xml's ActiveTable)
#

# The active sheet, if hidden, becomes the visible sheet before it, or the first visible one after
# it (LibreOffice's choice when the active sheet is hidden, F-051).
function _settings_shown(xf::ODSFile, s::String)
    sheets = xf.sheets
    return _set_active(s, function (cur)
        i = findfirst(ws -> _same_sheet(ws.name, cur), sheets)
        (i === nothing || getSheetVisibility(sheets[i]) === :visible) && return cur
        j = findprev(ws -> getSheetVisibility(ws) === :visible, sheets, i)
        j === nothing && (j = findnext(ws -> getSheetVisibility(ws) === :visible, sheets, i))
        return j === nothing ? cur : sheets[j].name
    end)
end

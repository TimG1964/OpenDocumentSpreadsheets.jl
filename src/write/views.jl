# Panes and the sheet view (phase 5 step 8; D-061), with XLSX.jl's API and LibreOffice's settings
# (experiment 024, F-053).
#
# Adapted from XLSX.jl 0.13.4 (src/panes.jl `freezePanes`, `splitFreeze`, `splitPanes`,
# `removePanes`, `setSheetView`, `getSheetView`), MIT License, Copyright (c) 2018-2026 Felipe Noronha
# Tavares and other contributors. Changes: the settings are LibreOffice's view settings in
# settings.xml (a flat file's office:settings), not Excel's `<sheetView>`; what LibreOffice keeps for
# the whole view (headers, zeros, the page-break view) is set for the whole file; a selection is kept
# as its cursor only, as LibreOffice keeps it.
#
# LibreOffice's view settings (F-053): `ooo:view-settings` → `Views` → the first view's entry →
# `Tables`, one entry per sheet (by name) with its panes, cursor, scroll position, zoom and gridlines;
# the view's own items (`ShowZeroValues`, `HasColumnRowHeaders`, `ShowPageBreakPreview`, …) follow
# `Tables` in the view's entry. OpenDocumentSpreadsheets keeps the items it sets (`xf.views`) and writes them over the
# file's at save, leaving every other item as it was. LibreOffice reads none of it unless the root
# element declares the `ooo` namespace.

const _CONFIG_NS = "urn:oasis:names:tc:opendocument:xmlns:config:1.0"
const _OOO_NS = "http://openoffice.org/2004/office"

#
# Reading the file's settings
#

# The file's settings (settings.xml, or a flat file's office:settings), after the sheet operations
# so far; `nothing` if it has none.
function _settings_now(xf::ODSFile)
    isnewfile(xf) && return nothing
    if xf.container.format === :fods
        r = findfirst(r"<office:settings>.*?</office:settings>"s, xf.content)
        r === nothing && return nothing
        s = String(SubString(xf.content, first(r), last(r)))
    else
        s = read_xml(xf.container, :settings)
        s === nothing && return nothing
    end
    return _settings_ops(xf, s)
end

const _ITEM_RX = r"<config:config-item config:name=\"([^\"]*)\" config:type=\"([^\"]*)\">([^<]*)</config:config-item>"

# The text of the first view's entry: (its span, the Tables map's span), or nothing.
function _view_entry_span(s::AbstractString)
    v = findfirst("<config:config-item-map-indexed config:name=\"Views\">", s)
    v === nothing && return nothing
    a = findnext("<config:config-item-map-entry>", s, last(v))
    a === nothing && return nothing
    # the entry's end: the matching </config:config-item-map-entry>, counting nested entries
    depth = 0
    i = first(a)
    while true
        o = findnext(r"<config:config-item-map-entry\b", s, i + 1)
        c = findnext("</config:config-item-map-entry>", s, i + 1)
        c === nothing && return nothing
        if o !== nothing && first(o) < first(c)
            depth += 1
            i = first(o)
        else
            depth == 0 && return (first(a):last(c), _tables_span(s, first(a), last(c)))
            depth -= 1
            i = first(c)
        end
    end
end

function _tables_span(s::AbstractString, a::Int, b::Int)
    t = findnext("<config:config-item-map-named config:name=\"Tables\">", s, a)
    (t === nothing || first(t) > b) && return nothing
    e = findnext("</config:config-item-map-named>", s, last(t))
    return first(t):last(e)
end

# The span of the entry for sheet `name` in the Tables map's span `tsp`, or nothing.
function _sheet_entry_span(s::AbstractString, tsp::UnitRange{Int}, name::AbstractString)
    r = findnext(_entry_open(name), s, first(tsp))
    (r === nothing || first(r) > last(tsp)) && return nothing
    e = findnext("</config:config-item-map-entry>", s, last(r))
    return first(r):last(e)
end

_items(text::AbstractString) = Dict(String(m.captures[1]) => (String(m.captures[2]), XML.unescape(String(m.captures[3])))
                                    for m in eachmatch(_ITEM_RX, text))

# The file's items for a sheet (by its current name) and for the view.
function _file_view_items(xf::ODSFile, name::AbstractString)
    s = _settings_now(xf)
    sheet = Dict{String,Tuple{String,String}}(); view = Dict{String,Tuple{String,String}}()
    s === nothing && return sheet, view
    sp = _view_entry_span(s)
    sp === nothing && return sheet, view
    esp, tsp = sp
    if tsp !== nothing
        e = _sheet_entry_span(s, tsp, name)
        e === nothing || (sheet = _items(SubString(s, first(e), last(e))))
        view = _items(SubString(s, first(esp), first(tsp) - 1) * SubString(s, last(tsp) + 1, last(esp)))
    else
        view = _items(SubString(s, first(esp), last(esp)))
    end
    return sheet, view
end

# The items now: the file's with OpenDocumentSpreadsheets' edits over them.
function _view_items_now(ws::Worksheet)
    xf = get_odsfile(ws)
    sheet, view = _file_view_items(xf, ws.name)
    for (k, v) in get(xf.views.sheets, ws, ViewItems())
        v === nothing ? delete!(sheet, k) : (sheet[k] = v)
    end
    for (k, v) in xf.views.view
        v === nothing ? delete!(view, k) : (view[k] = v)
    end
    return sheet, view
end

_ival(d, k, default) = haskey(d, k) ? something(tryparse(Int, d[k][2]), default) : default
_bval(d, k, default) = haskey(d, k) ? d[k][2] == "true" : default

#
# Setting items
#

function _set_sheet_items!(ws::Worksheet, items::Pair...)
    d = get!(ViewItems, get_odsfile(ws).views.sheets, ws)
    for (k, v) in items
        d[k] = v
    end
    return
end
function _set_view_items!(xf::ODSFile, items::Pair...)
    for (k, v) in items
        xf.views.view[k] = v
    end
    return
end

_int(v::Integer) = ("int", string(v))
_short(v::Integer) = ("short", string(v))
_bool(v::Bool) = ("boolean", v ? "true" : "false")

_views_edited(xf::ODSFile) = !isempty(xf.views.view) || any(!isempty, values(xf.views.sheets))

#
# Panes (F-053): split modes 0 none, 1 split, 2 frozen; positions are counts of columns and rows
# when frozen, pixels when split; the active part is 0 top left, 1 top right, 2 bottom left,
# 3 bottom right. `PositionRight`/`PositionBottom` are the first column and row of the parts that
# scroll, as LibreOffice's xlsx import writes them, and the cursor goes to their top-left cell.
#

function _anchor_counts(anchor::AbstractString)
    is_valid_cellname(anchor) || throw(ODSError("`$anchor` is not a cell, such as \"B2\"."))
    c = CellRef(anchor)
    return row_number(c) - 1, column_number(c) - 1
end

function _apply_panes!(ws::Worksheet, mode::Int, nrows::Int, ncols::Int)
    _require_writable(ws, "set panes")
    (nrows < 0 || ncols < 0) && throw(ODSError("`nrows` and `ncols` must be 0 or more."))
    (nrows >= SheetCore.MAX_ROWS || ncols >= SheetCore.MAX_COLS) && throw(ODSError("The panes must leave rows and columns to scroll."))
    if mode == 0 || (nrows == 0 && ncols == 0)
        _set_sheet_items!(ws, "HorizontalSplitMode" => nothing, "VerticalSplitMode" => nothing,
                          "HorizontalSplitPosition" => nothing, "VerticalSplitPosition" => nothing,
                          "ActiveSplitRange" => _short(2), "PositionLeft" => _int(0), "PositionRight" => _int(0),
                          "PositionTop" => _int(0), "PositionBottom" => _int(0))
        return ws
    end
    hpos = mode == 2 ? ncols : _split_pixels(ws, 2, ncols)
    vpos = mode == 2 ? nrows : _split_pixels(ws, 1, nrows)
    _set_sheet_items!(ws,
        "HorizontalSplitMode" => (ncols > 0 ? _short(mode) : nothing), "HorizontalSplitPosition" => (ncols > 0 ? _int(hpos) : nothing),
        "VerticalSplitMode" => (nrows > 0 ? _short(mode) : nothing), "VerticalSplitPosition" => (nrows > 0 ? _int(vpos) : nothing),
        "ActiveSplitRange" => _short(nrows > 0 && ncols > 0 ? 3 : ncols > 0 ? 1 : 2),
        "PositionLeft" => _int(0), "PositionRight" => _int(ncols), "PositionTop" => _int(0), "PositionBottom" => _int(nrows),
        "CursorPositionX" => _int(ncols), "CursorPositionY" => _int(nrows))
    return ws
end

# A split's position in pixels: LibreOffice's, at 96 pixels an inch and 100% zoom, from the widths of
# the first `n` columns (axis 2) or the heights of the first `n` rows (axis 1).
function _split_pixels(ws::Worksheet, axis::Int, n::Int)
    n == 0 && return 0
    st = get_odsfile(ws).styles
    f = sheet_formats(ws)
    total = 0.0
    k = 1
    while k <= n
        r = axis == 2 ? _fmt_at(f.cols, k) : _fmt_at(f.rows, k)
        cnt = r === nothing ? 1 : min(n - k + 1, (axis == 2 ? _stop(r) : _stop(r)) - k + 1)
        cm = r === nothing ? nothing :
             _length_cm(getprop(line_props(st, axis == 2 ? 1 : 2, r.style), axis == 2 ? "style:column-width" : "style:row-height"))
        cm === nothing && (cm = axis == 2 ? 2.258 : 0.452)     # LibreOffice's default column width, row height
        total += cnt * cm
        k += cnt
    end
    return round(Int, total / 2.54 * 96)
end

"""
    freezePanes(sheet; nrows=1, ncols=0)
    freezePanes(sheet, anchor_cell)

Freeze the first `nrows` rows and `ncols` columns, so that they stay in view while the rest
scrolls; or everything above and to the left of `anchor_cell` (`"B3"` freezes row 1:2 and
column A). The view goes back to the top left, and the cursor to the first cell that scrolls, as
LibreOffice shows an Excel file with frozen panes. Calling it again replaces the panes.

The panes are LibreOffice's view settings for the sheet (settings.xml), which LibreOffice keeps
where they are when rows or columns are inserted or deleted (F-053).

See also [`splitPanes`](@ref), [`removePanes`](@ref), [`setSheetView`](@ref).
"""
freezePanes(ws::Worksheet; nrows::Integer = 1, ncols::Integer = 0) = _apply_panes!(ws, 2, Int(nrows), Int(ncols))
freezePanes(ws::Worksheet, anchor::AbstractString) = _apply_panes!(ws, 2, _anchor_counts(anchor)...)

"""
    splitFreeze(sheet; nrows=1, ncols=0)
    splitFreeze(sheet, anchor_cell)

The same as [`freezePanes`](@ref): LibreOffice has no separate "frozen split", and its xlsx
import reads Excel's as frozen panes.
"""
splitFreeze(ws::Worksheet; nrows::Integer = 1, ncols::Integer = 0) = freezePanes(ws; nrows, ncols)
splitFreeze(ws::Worksheet, anchor::AbstractString) = freezePanes(ws, anchor)

"""
    splitPanes(sheet; nrows=1, ncols=0)
    splitPanes(sheet, anchor_cell)

Split the view into panes that scroll on their own, after `nrows` rows and `ncols` columns (or
above and to the left of `anchor_cell`). LibreOffice stores a split in pixels: OpenDocumentSpreadsheets places it
at the edge of those rows and columns, from their heights and widths, at 100% zoom.
"""
splitPanes(ws::Worksheet; nrows::Integer = 1, ncols::Integer = 0) = _apply_panes!(ws, 1, Int(nrows), Int(ncols))
splitPanes(ws::Worksheet, anchor::AbstractString) = _apply_panes!(ws, 1, _anchor_counts(anchor)...)

"""
    removePanes(sheet)

Remove frozen or split panes, and scroll back to the top left.
"""
removePanes(ws::Worksheet) = _apply_panes!(ws, 0, 0, 0)

#
# The sheet view
#

const _SHEET_VIEW_KEYS = (:zoom, :view, :showGridLines, :showRowColHeaders, :showZeros, :rightToLeft,
                          :topLeftCell, :activeCell, :selection)

_view_cellref(c::CellRef, ::Symbol) = c
_view_cellref(c, k::Symbol) = (c isa AbstractString && is_valid_cellname(c)) ? CellRef(c) :
    throw(ODSError("`$k` must be a single cell, such as \"C10\". Found `$(repr(c))`."))

"""
    setSheetView(sheet; zoom, view, showGridLines, showRowColHeaders, showZeros, rightToLeft,
                 topLeftCell, activeCell, selection)

Set how a sheet looks when LibreOffice opens it. Only the keywords given change. As LibreOffice
keeps them (F-053):
- `zoom`: the sheet's zoom, in percent (20 to 600, LibreOffice's range), for the view it is in
- `view`: `:normal` or `:pageBreakPreview`, **for the whole file** (LibreOffice's page-break view
  is the window's). LibreOffice Calc has no page layout view: `:pageLayout` is an error.
- `showGridLines`: the sheet's gridlines
- `showRowColHeaders`, `showZeros`: **for the whole file**, as LibreOffice keeps them
- `rightToLeft`: the sheet runs right to left (its table style's writing mode)
- `topLeftCell`: the cell scrolled to the top left (of the part that scrolls, with frozen panes)
- `activeCell`, `selection`: the cursor. LibreOffice keeps no selection in a file, only the
  cursor: `activeCell`, or else the first cell of `selection` (which must hold `activeCell`).

See also [`getSheetView`](@ref), [`freezePanes`](@ref).
"""
function setSheetView(ws::Worksheet; kw...)
    _require_writable(ws, "set the sheet view")
    isempty(kw) && throw(ODSError("Give the view settings to change as keywords, such as `zoom=150`."))
    for k in keys(kw)
        k in _SHEET_VIEW_KEYS || throw(ODSError("Unknown keyword `$k`. Must be one of $(join(_SHEET_VIEW_KEYS, ", "))."))
    end
    for k in (:showGridLines, :showRowColHeaders, :showZeros, :rightToLeft)
        haskey(kw, k) && !(kw[k] isa Bool) && throw(ODSError("`$k` must be `true` or `false`. Found `$(repr(kw[k]))`."))
    end
    if haskey(kw, :view)
        kw[:view] === :pageLayout && throw(ODSError("LibreOffice Calc has no page layout view: give `:normal` or `:pageBreakPreview`."))
        kw[:view] in (:normal, :pageBreakPreview) || throw(ODSError("Invalid `view` `$(repr(kw[:view]))`. Must be :normal or :pageBreakPreview."))
    end
    if haskey(kw, :zoom)
        (kw[:zoom] isa Integer && 20 <= kw[:zoom] <= 600) ||
            throw(ODSError("Invalid `zoom` `$(repr(kw[:zoom]))`. Must be a whole percentage from 20 to 600, LibreOffice's range."))
    end
    sheet, view = _view_items_now(ws)
    topleft = haskey(kw, :topLeftCell) ? _view_cellref(kw[:topLeftCell], :topLeftCell) : nothing
    cursor = nothing
    if haskey(kw, :selection) || haskey(kw, :activeCell)
        ac = haskey(kw, :activeCell) ? _view_cellref(kw[:activeCell], :activeCell) : nothing
        if haskey(kw, :selection)
            sel = kw[:selection]
            rngs = CellRange[]
            if sel isa CellRef
                push!(rngs, CellRange(sel, sel))
            elseif sel isa CellRange
                push!(rngs, sel)
            elseif sel isa AbstractString
                for p in SheetCore._split_unquoted(String(sel), (',', '~'))
                    q = replace(strip(p), "\$" => "")
                    is_valid_cellname(q) ? push!(rngs, CellRange(CellRef(q), CellRef(q))) :
                    is_valid_cellrange(q) ? push!(rngs, CellRange(q)) :
                    throw(ODSError("A selection is made of cells, such as `B2:D5`. Found `$p`."))
                end
            else
                throw(ODSError("`selection` must be cells, such as \"B2:D5\" or \"B2:D5,F7\". Found `$(repr(sel))`."))
            end
            ac = something(ac, first(rngs).start)
            any(r -> ac in r, rngs) || throw(ODSError("The `activeCell` $ac must be in the `selection`."))
        end
        cursor = ac
    end
    # the page-break view, for the whole file
    pagebreak = haskey(kw, :view) ? kw[:view] === :pageBreakPreview : _bval(view, "ShowPageBreakPreview", false)
    haskey(kw, :view) && _set_view_items!(get_odsfile(ws), "ShowPageBreakPreview" => _bool(pagebreak))
    haskey(kw, :zoom) && _set_sheet_items!(ws, (pagebreak ? "PageViewZoomValue" : "ZoomValue") => _int(kw[:zoom]),
                                           "ZoomType" => _short(0))
    if haskey(kw, :showGridLines)
        # the sheet's own item, as LibreOffice's xlsx import writes it; LibreOffice shows gridlines when
        # both it and the view's allow them (F-053), so showing them under a view without them turns the
        # view's on and the other sheets' off
        _set_sheet_items!(ws, "ShowGrid" => _bool(kw[:showGridLines]))
        if kw[:showGridLines] && !_bval(view, "ShowGrid", true)
            xf = get_odsfile(ws)
            for other in _sheets(xf)
                other === ws && continue
                _set_sheet_items!(other, "ShowGrid" => _bool(false))
            end
            _set_view_items!(xf, "ShowGrid" => _bool(true))
        end
    end
    haskey(kw, :showRowColHeaders) && _set_view_items!(get_odsfile(ws), "HasColumnRowHeaders" => _bool(kw[:showRowColHeaders]))
    haskey(kw, :showZeros) && _set_view_items!(get_odsfile(ws), "ShowZeroValues" => _bool(kw[:showZeros]))
    if haskey(kw, :rightToLeft)
        p = _sheet_props(ws)
        p.rtl == kw[:rightToLeft] || _restyle_table!(ws, p.display, p.tabcolor; rtl = kw[:rightToLeft])
    end
    if topleft !== nothing
        hsplit = _ival(sheet, "HorizontalSplitMode", 0); vsplit = _ival(sheet, "VerticalSplitMode", 0)
        c0 = column_number(topleft) - 1; r0 = row_number(topleft) - 1
        if hsplit == 2 || vsplit == 2
            fc = hsplit == 2 ? _ival(sheet, "HorizontalSplitPosition", 0) : 0
            fr = vsplit == 2 ? _ival(sheet, "VerticalSplitPosition", 0) : 0
            (c0 >= fc && r0 >= fr) ||
                throw(ODSError("The `topLeftCell` $topleft is in the frozen panes: it must be at or below and right of $(CellRef(fr + 1, fc + 1))."))
        end
        hsplit == 0 ? _set_sheet_items!(ws, "PositionLeft" => _int(c0), "PositionRight" => _int(0)) :
                      _set_sheet_items!(ws, "PositionRight" => _int(c0))
        vsplit == 0 ? _set_sheet_items!(ws, "PositionTop" => _int(r0), "PositionBottom" => _int(r0)) :
                      _set_sheet_items!(ws, "PositionBottom" => _int(r0))
    end
    cursor === nothing || _set_sheet_items!(ws, "CursorPositionX" => _int(column_number(cursor) - 1),
                                            "CursorPositionY" => _int(row_number(cursor) - 1))
    return nothing
end

"""
    getSheetView(sheet) -> NamedTuple

How a sheet looks when LibreOffice opens it: `zoom`, `view`, `showGridLines`,
`showRowColHeaders`, `showZeros`, `rightToLeft`, `topLeftCell`, `activeCell` and `selection`, as
[`setSheetView`](@ref) describes them. `selection` is the active cell (LibreOffice keeps no
selection). A setting the file doesn't hold has LibreOffice's default. Works on read-only files.
"""
function getSheetView(ws::Worksheet)
    sheet, view = _view_items_now(ws)
    pagebreak = _bval(view, "ShowPageBreakPreview", false)
    zoom = pagebreak ? _ival(sheet, "PageViewZoomValue", _ival(view, "PageViewZoomValue", 60)) :
                       _ival(sheet, "ZoomValue", _ival(view, "ZoomValue", 100))
    hsplit = _ival(sheet, "HorizontalSplitMode", 0); vsplit = _ival(sheet, "VerticalSplitMode", 0)
    col = (hsplit == 0 ? _ival(sheet, "PositionLeft", 0) : _ival(sheet, "PositionRight", 0)) + 1
    row = _ival(sheet, "PositionBottom", 0) + 1
    active = CellRef(_ival(sheet, "CursorPositionY", 0) + 1, _ival(sheet, "CursorPositionX", 0) + 1)
    return (zoom = zoom, view = pagebreak ? :pageBreakPreview : :normal,
            showGridLines = _bval(sheet, "ShowGrid", true) && _bval(view, "ShowGrid", true),
            showRowColHeaders = _bval(view, "HasColumnRowHeaders", true),
            showZeros = _bval(view, "ShowZeroValues", true),
            rightToLeft = _sheet_props(ws).rtl,
            topLeftCell = CellRef(row, col), activeCell = active, selection = string(active))
end

#
# Writing the settings
#

_item_xml(k, (t, v)) = "<config:config-item config:name=\"$k\" config:type=\"$t\">" * _escape_attr(v) * "</config:config-item>"

# The order LibreOffice writes a sheet's items and the view's in. It reads them in turn, so the order
# matters: a split position read before its mode is taken for the wrong kind (F-053).
const _ITEM_ORDER = ["CursorPositionX", "CursorPositionY", "HorizontalSplitMode", "VerticalSplitMode",
                     "HorizontalSplitPosition", "VerticalSplitPosition", "ActiveSplitRange", "PositionLeft",
                     "PositionRight", "PositionTop", "PositionBottom", "ZoomType", "ZoomValue", "PageViewZoomValue",
                     "ShowGrid", "ActiveTable", "HorizontalScrollbarWidth", "ShowPageBreakPreview", "ShowZeroValues",
                     "ShowNotes", "ShowNoteAuthor", "ShowFormulasMarks", "GridColor", "ShowPageBreaks",
                     "HasColumnRowHeaders", "HasSheetTabs"]
_item_rank(k) = something(findfirst(==(k), _ITEM_ORDER), length(_ITEM_ORDER) + 1)

# `text` (the inside of an entry) with the items `items` set, replaced or removed. A new item goes
# before the first item LibreOffice writes after it, else at the end.
function _with_items(text::AbstractString, items)
    s = String(text)
    for (k, v) in sort!(collect(items); by = p -> _item_rank(p.first))
        rx = Regex("<config:config-item config:name=\"" * k * "\" config:type=\"[^\"]*\">[^<]*</config:config-item>")
        r = findfirst(rx, s)
        if r === nothing
            v === nothing && continue
            at = nothing
            for m in eachmatch(_ITEM_RX, s)
                if _item_rank(m.captures[1]) > _item_rank(k)
                    at = something(findfirst(m.match, s)) |> first
                    break
                end
            end
            s = at === nothing ? s * _item_xml(k, v) : s[1:prevind(s, at)] * _item_xml(k, v) * s[at:end]
        else
            s = s[1:prevind(s, first(r))] * (v === nothing ? "" : _item_xml(k, v)) * s[nextind(s, last(r)):end]
        end
    end
    return s
end

const _EMPTY_VIEW_SETTINGS = "<config:config-item-set config:name=\"ooo:view-settings\"><config:config-item-map-indexed config:name=\"Views\">" *
    "<config:config-item-map-entry><config:config-item config:name=\"ViewId\" config:type=\"string\">view1</config:config-item>" *
    "<config:config-item-map-named config:name=\"Tables\"></config:config-item-map-named></config:config-item-map-entry>" *
    "</config:config-item-map-indexed></config:config-item-set>"

"""
    _settings_views(xf, s) -> String

The settings `s` (an `office:settings` element, or a whole settings.xml) with OpenDocumentSpreadsheets' view
items written over the file's: in the first view's entry for each sheet, and in the view's own
items. Missing sets, maps and entries are made.
"""
function _settings_views(xf::ODSFile, s::String)
    _views_edited(xf) || return s
    sp = _view_entry_span(s)
    if sp === nothing
        if (v = findfirst("<config:config-item-set config:name=\"ooo:view-settings\">", s)) !== nothing
            # the set's items are kept: the Views map goes after them
            e = findnext("</config:config-item-set>", s, last(v))
            s = s[1:prevind(s, first(e))] *
                replace(replace(_EMPTY_VIEW_SETTINGS, "<config:config-item-set config:name=\"ooo:view-settings\">" => ""),
                        "</config:config-item-set>" => "") * s[first(e):end]
        else
            o = findfirst(r"<office:settings\s*>", s)
            o === nothing && throw(ODSError("The file's settings have no office:settings element."))
            s = s[1:last(o)] * _EMPTY_VIEW_SETTINGS * s[nextind(s, last(o)):end]
        end
        sp = _view_entry_span(s)
    end
    esp, tsp = sp
    if tsp === nothing
        a = first(esp) + ncodeunits("<config:config-item-map-entry>")
        s = s[1:a-1] * "<config:config-item-map-named config:name=\"Tables\"></config:config-item-map-named>" * s[a:end]
        esp, tsp = _view_entry_span(s)
    end
    # the sheets' entries (in reverse order of position, so the spans found stay right)
    for ws in xf.sheets
        items = get(xf.views.sheets, ws, nothing)
        (items === nothing || isempty(items)) && continue
        esp, tsp = _view_entry_span(s)
        e = _sheet_entry_span(s, tsp, ws.name)
        if e === nothing
            at = last(tsp) - ncodeunits("</config:config-item-map-named>") + 1
            new = _entry_open(ws.name) * _with_items("", items) * "</config:config-item-map-entry>"
            s = s[1:at-1] * new * s[at:end]
        else
            open = ncodeunits(_entry_open(ws.name))
            inner = SubString(s, first(e) + open, last(e) - ncodeunits("</config:config-item-map-entry>"))
            s = s[1:first(e)+open-1] * _with_items(inner, items) * s[last(e)-ncodeunits("</config:config-item-map-entry>")+1:end]
        end
    end
    # the view's own items: after the Tables map
    if !isempty(xf.views.view)
        esp, tsp = _view_entry_span(s)
        endtag = last(esp) - ncodeunits("</config:config-item-map-entry>") + 1
        before = SubString(s, first(esp), first(tsp) - 1)
        after = SubString(s, last(tsp) + 1, endtag - 1)
        # an item may be before the Tables map: it is replaced there; new ones go after it
        b2 = String(before); a2 = String(after)
        for (k, v) in xf.views.view
            if occursin("config:name=\"$k\"", b2)
                b2 = _with_items(b2, [k => v])
            else
                a2 = _with_items(a2, [k => v])
            end
        end
        s = s[1:first(esp)-1] * b2 * SubString(s, first(tsp), last(tsp)) * a2 * s[endtag:end]
    end
    return s
end

# A new settings.xml, for a file that has none.
_new_settings_xml(version) = string(_XMLDECL, "<office:document-settings xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\"",
                                    " xmlns:config=\"", _CONFIG_NS, "\" xmlns:ooo=\"", _OOO_NS, "\" office:version=\"", version,
                                    "\"><office:settings></office:settings></office:document-settings>")

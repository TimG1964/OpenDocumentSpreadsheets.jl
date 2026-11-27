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
        _, _, kids = _top_elements(xf.content)
        node = get(kids, "office:settings", nothing)
        node === nothing && return nothing
        s = String(XML.sourcetext(node))
    else
        s = read_xml(xf.container, :settings)
        s === nothing && return nothing
    end
    return _settings_ops(xf, s)
end

# The first view's entry: (its element, the Tables map's element or nothing), or nothing. The
# settings are read as XML.jl trees (write/xmlparts.jl, D-101).
function _view_entry(s::AbstractString, els = _xelements(s))
    v = _xfirst(s, "config:config-item-map-indexed", "config:name", "Views"; elements = els)
    (v === nothing || v.inner === nothing) && return nothing
    entry = _xfirst(s, "config:config-item-map-entry"; depth = v.depth + 1, within = v.inner, elements = els)
    entry === nothing && return nothing
    tables = entry.inner === nothing ? nothing :
             _xfirst(s, "config:config-item-map-named", "config:name", "Tables"; depth = entry.depth + 1, within = entry.inner, elements = els)
    return entry, tables
end

# The first view's entry: (its span, the Tables map's span), or nothing.
function _view_entry_span(s::AbstractString)
    r = _view_entry(s)
    r === nothing && return nothing
    entry, tables = r
    return entry.span, tables === nothing ? nothing : tables.span
end

# The entry for sheet `name` in the Tables map, or nothing.
function _sheet_entry(s::AbstractString, name::AbstractString)
    r = _view_entry(s)
    (r === nothing || r[2] === nothing || r[2].inner === nothing) && return nothing
    t = r[2]
    return _xfirst(s, "config:config-item-map-entry", "config:name", name; depth = t.depth + 1, within = t.inner)
end

# The items of a fragment of settings: name => (type, value unescaped), at any depth.
function _items(text::AbstractString)
    d = Dict{String,Tuple{String,String}}()
    for e in _xfind(text, "config:config-item")
        k = _xattr(e, "config:name")
        k === nothing && continue
        v = e.inner === nothing ? "" : XML.unescape(String(SubString(text, first(e.inner), last(e.inner))))
        haskey(d, k) || (d[k] = (something(_xattr(e, "config:type"), "string"), v))
    end
    return d
end

# The file's items for a sheet (by its current name) and for the view.
function _file_view_items(xf::ODSFile, name::AbstractString)
    s = _settings_now(xf)
    sheet = Dict{String,Tuple{String,String}}(); view = Dict{String,Tuple{String,String}}()
    s === nothing && return sheet, view
    sp = _view_entry_span(s)
    sp === nothing && return sheet, view
    esp, tsp = sp
    if tsp !== nothing
        e = _sheet_entry(s, name)
        e === nothing || (sheet = _items(SubString(s, first(e.span), last(e.span))))
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

# as Int64, cut to Int32, so a 32-bit build reads a setting as a 64-bit one does
_ival(d, k, default) = haskey(d, k) ? Int(clamp(something(tryparse(Int64, d[k][2]), default), typemin(Int32), typemax(Int32))) : default
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
column A), as LibreOffice's View ▸ Freeze Cells does. The view goes back to the top left, and the
cursor to the first cell that scrolls. Calling it again replaces the panes.

The panes are saved with the sheet's view settings, which LibreOffice keeps where they are when
rows or columns are inserted or deleted.

```julia
freezePanes(sh)            # the first row stays in view
freezePanes(sh, "B2")      # row 1 and column A
```

See also [`splitPanes`](@ref), [`removePanes`](@ref), [`setSheetView`](@ref).
"""
freezePanes(ws::Worksheet; nrows::Integer = 1, ncols::Integer = 0) = _apply_panes!(ws, 2, Int(nrows), Int(ncols))
freezePanes(ws::Worksheet, anchor::AbstractString) = _apply_panes!(ws, 2, _anchor_counts(anchor)...)

"""
    splitFreeze(sheet; nrows=1, ncols=0)
    splitFreeze(sheet, anchor_cell)

The same as [`freezePanes`](@ref): LibreOffice has no separate frozen split.
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
keeps them:
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
        els = _xelements(s)
        cur = _xfirst(s, "config:config-item", "config:name", k; depth = 1, elements = els)
        if cur === nothing
            v === nothing && continue
            # before the first item LibreOffice writes after it
            later = findfirst(e -> e.tag == "config:config-item" && e.depth == 1 &&
                                   _item_rank(something(_xattr(e, "config:name"), "")) > _item_rank(k), els)
            at = later === nothing ? nothing : first(els[later].span)
            s = at === nothing ? s * _item_xml(k, v) : s[1:prevind(s, at)] * _item_xml(k, v) * s[at:end]
        else
            s = s[1:prevind(s, first(cur.span))] * (v === nothing ? "" : _item_xml(k, v)) * s[nextind(s, last(cur.span)):end]
        end
    end
    return s
end

const _EMPTY_VIEW_SETTINGS = "<config:config-item-set config:name=\"ooo:view-settings\"><config:config-item-map-indexed config:name=\"Views\">" *
    "<config:config-item-map-entry><config:config-item config:name=\"ViewId\" config:type=\"string\">view1</config:config-item>" *
    "<config:config-item-map-named config:name=\"Tables\"></config:config-item-map-named></config:config-item-map-entry>" *
    "</config:config-item-map-indexed></config:config-item-set>"
const _VIEWS_MAP = "<config:config-item-map-indexed config:name=\"Views\"><config:config-item-map-entry>" *
    "<config:config-item config:name=\"ViewId\" config:type=\"string\">view1</config:config-item>" *
    "<config:config-item-map-named config:name=\"Tables\"></config:config-item-map-named></config:config-item-map-entry>" *
    "</config:config-item-map-indexed>"
const _TABLES_MAP = "<config:config-item-map-named config:name=\"Tables\"></config:config-item-map-named>"

# `s` with `text` added as the last content of element `e` (an empty one written `<…/>` is opened).
function _append_in(s::String, e::_XElement, text::AbstractString)
    if e.inner === nothing
        t = SubString(s, first(e.span), last(e.span))
        open = _set_attrs(t, Pair{String,Union{Nothing,String}}[]; open = true)
        return s[1:prevind(s, first(e.span))] * open * text * "</" * e.tag * ">" * s[nextind(s, last(e.span)):end]
    end
    at = _xend(e)
    return s[1:prevind(s, at)] * text * s[at:end]
end

"""
    _settings_views(xf, s) -> String

The settings `s` (an `office:settings` element, or a whole settings.xml) with OpenDocumentSpreadsheets' view
items written over the file's: in the first view's entry for each sheet, and in the view's own
items. Missing sets, maps and entries are made.
"""
function _settings_views(xf::ODSFile, s::String)
    _views_edited(xf) || return s
    if _view_entry(s) === nothing
        set = _xfirst(s, "config:config-item-set", "config:name", "ooo:view-settings")
        if set !== nothing
            # the set's items are kept: the Views map goes after them
            s = _append_in(s, set, _VIEWS_MAP)
        else
            o = _xfirst(s, "office:settings")
            o === nothing && throw(ODSError("The file's settings have no office:settings element."))
            s = _append_in(s, o, _EMPTY_VIEW_SETTINGS)
        end
    end
    entry, tables = _view_entry(s)
    if tables === nothing
        # first in the entry, as before: the view's items after it are read in order (F-053)
        s = entry.inner === nothing ? _append_in(s, entry, _TABLES_MAP) :
            s[1:prevind(s, first(entry.inner))] * _TABLES_MAP * s[first(entry.inner):end]
    end
    # the sheets' entries
    for ws in xf.sheets
        items = get(xf.views.sheets, ws, nothing)
        (items === nothing || isempty(items)) && continue
        e = _sheet_entry(s, ws.name)
        if e === nothing
            s = _append_in(s, _view_entry(s)[2], _entry_open(ws.name) * _with_items("", items) * "</config:config-item-map-entry>")
        elseif e.inner === nothing
            s = _append_in(s, e, _with_items("", items))
        else
            s = s[1:prevind(s, first(e.inner))] * _with_items(SubString(s, first(e.inner), last(e.inner)), items) * s[nextind(s, last(e.inner)):end]
        end
    end
    # the view's own items: an item before the Tables map is replaced there; new ones go after it
    if !isempty(xf.views.view)
        entry, tables = _view_entry(s)
        before = String(SubString(s, first(entry.inner), first(tables.span) - 1))
        after = String(SubString(s, last(tables.span) + 1, last(entry.inner)))
        bitems = _items(before)
        for (k, v) in xf.views.view
            haskey(bitems, k) ? (before = _with_items(before, [k => v])) : (after = _with_items(after, [k => v]))
        end
        s = s[1:prevind(s, first(entry.inner))] * before * SubString(s, first(tables.span), last(tables.span)) * after *
            s[nextind(s, last(entry.inner)):end]
    end
    return s
end

# A new settings.xml, for a file that has none.
_new_settings_xml(version) = string(_XMLDECL, "<office:document-settings xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\"",
                                    " xmlns:config=\"", _CONFIG_NS, "\" xmlns:ooo=\"", _OOO_NS, "\" office:version=\"", version,
                                    "\"><office:settings></office:settings></office:document-settings>")

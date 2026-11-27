# Protection (phase 5 step 9; D-062): sheets, the file's structure and cells, with XLSX.jl's API and
# LibreOffice's forms (experiment 025, F-054).
#
# Adapted from XLSX.jl 0.13.4 (src/sheetsettings.jl `protectSheet`, `unprotectSheet`,
# `isSheetProtected`, `getSheetProtection`, `protectWorkbook`, `unprotectWorkbook`,
# `isWorkbookProtected`, `getWorkbookProtection`; src/cellformats/protection.jl `setCellProtection`,
# `getCellProtection`), MIT License, Copyright (c) 2018-2026 Felipe Noronha Tavares and other
# contributors. Changes: LibreOffice's forms (the table's `table:protected` and key, its
# `loext:table-protection` options, `table:structure-protected` on the spreadsheet,
# `style:cell-protect`); keys are LibreOffice's (SHA-1 of the UTF-16LE password, in Base64), not
# Excel's legacy hash; permissions LibreOffice has no counterpart for can't be granted.
#
# Protection applies in LibreOffice only: OpenDocumentSpreadsheets reads and edits a protected sheet as any other.

const _SHA1_URI = "http://www.w3.org/2000/09/xmldsig#sha1"

# LibreOffice's key for a password (F-054): SHA-1 of its UTF-16LE bytes, in Base64.
function _protection_key(password::AbstractString)
    _check_xml_text(password)
    u = transcode(UInt16, String(password))
    bytes = Vector{UInt8}(undef, 2 * length(u))
    for (i, w) in enumerate(u)
        bytes[2i-1] = UInt8(w & 0xff)
        bytes[2i] = UInt8(w >> 8)
    end
    return base64encode(sha1(bytes))
end

# XLSX.jl's permissions and LibreOffice's attributes for them (F-054); `nothing`: LibreOffice has no
# such permission (its xlsx import drops them).
const _SHEET_PERMISSIONS = (
    selectLockedCells = (true, "loext:select-protected-cells"),
    selectUnlockedCells = (true, "loext:select-unprotected-cells"),
    formatCells = (false, nothing), formatColumns = (false, nothing), formatRows = (false, nothing),
    insertColumns = (false, "loext:insert-columns"), insertRows = (false, "loext:insert-rows"),
    insertHyperlinks = (false, nothing),
    deleteColumns = (false, "loext:delete-columns"), deleteRows = (false, "loext:delete-rows"),
    sort = (false, nothing), autoFilter = (false, "loext:use-autofilter"), pivotTables = (false, "loext:use-pivot"),
    objects = (false, nothing), scenarios = (false, nothing),
)

#
# Sheets
#

const _PROT_ATTRS = ("table:protected", "table:protection-key", "table:protection-key-digest-algorithm",
                     "loext:protection-key-digest-algorithm-2")

# A table's column and row elements (and their containers): the protection options come before them.
const _TABLE_LINES = ("table:table-column", "table:table-columns", "table:table-column-group", "table:table-header-columns",
                      "table:table-row", "table:table-rows", "table:table-row-group", "table:table-header-rows")

function _sheet_protection(ws::Worksheet)
    ws.protection === nothing || return ws.protection
    attrs = Dict{String,String}(); options = nothing; child = 0:-1
    if ws.entry !== nothing
        for k in _PROT_ATTRS                       # the start tag only (not the whole table's text)
            v = get(ws.entry.node, k, nothing)
            v === nothing || (attrs[k] = String(v))
        end
        # its options: a direct child before the columns and rows (LibreOffice writes it first),
        # so the walk stops at the first of those
        for ln in XML.eachelement(ws.entry.node)
            tg = XML.tag(ln)
            if tg == "loext:table-protection" || tg == "table:table-protection"
                child = XML.sourcespan(ln)
                text = SubString(parent(XML.sourcetext(ln)), first(child), last(child))
                options = Dict{String,String}()
                for (k, v) in _raw_attrs(SubString(text, 1, _start_tag_end(text)))
                    options[k] = _unquote_attr(v)
                end
                break
            end
            tg in _TABLE_LINES && break
        end
    end
    ws.protection = SheetProtection(attrs, options, child, false)
    return ws.protection
end

_prot_changed(ws::Worksheet) = ws.protection !== nothing && ws.protection.changed

"""
    protectSheet(sheet; password=nothing, allow...)

Protect a sheet, as LibreOffice's *Tools → Protect Sheet* does, so that its locked cells can't be
changed in LibreOffice. Every cell is locked unless its format says otherwise
([`setCellProtection`](@ref)).

`password`, if given, must be typed to unprotect the sheet. It is stored as LibreOffice stores it:
SHA-1 of the password (any text), in Base64. An empty password is no password, as in
LibreOffice. Protection guards against mistakes, not against anyone determined to change the sheet.

The other keywords are permissions, each a `Bool`. LibreOffice has these:
`selectLockedCells` and `selectUnlockedCells` (default `true`), `insertColumns`, `insertRows`,
`deleteColumns`, `deleteRows`, `autoFilter` and `pivotTables` (default `false`). It has no
counterpart for `formatCells`, `formatColumns`, `formatRows`, `insertHyperlinks`, `sort`,
`objects` and `scenarios`: they can only be `false` (an error otherwise).

Protecting a protected sheet replaces its settings. OpenDocumentSpreadsheets reads and edits protected sheets as
any other.

See also [`unprotectSheet`](@ref), [`isSheetProtected`](@ref), [`getSheetProtection`](@ref).
"""
function protectSheet(ws::Worksheet; password::Union{Nothing,AbstractString} = nothing, allow...)
    _require_writable(ws, "protect a sheet")
    for (k, v) in allow
        haskey(_SHEET_PERMISSIONS, k) ||
            throw(ODSError("Unknown keyword `$k`. Must be `password` or one of $(join(keys(_SHEET_PERMISSIONS), ", "))."))
        v isa Bool || throw(ODSError("`$k` must be `true` or `false`. Found `$(repr(v))`."))
        v && _SHEET_PERMISSIONS[k][2] === nothing &&
            throw(ODSError("LibreOffice has no `$k` permission on a protected sheet: it can only be `false`."))
    end
    p = _sheet_protection(ws)
    attrs = Dict{String,String}("table:protected" => "true")
    if password !== nothing && !isempty(password)
        attrs["table:protection-key"] = _protection_key(password)
        attrs["table:protection-key-digest-algorithm"] = _SHA1_URI
    end
    options = Dict{String,String}()
    for (k, (default, attr)) in pairs(_SHEET_PERMISSIONS)
        attr === nothing && continue
        get(allow, k, default) && (options[attr] = "true")
    end
    p.attrs = attrs; p.options = options; p.changed = true
    return nothing
end

"""
    unprotectSheet(sheet) -> Bool

Remove a sheet's protection, whatever its password. `false` if it wasn't protected.
"""
function unprotectSheet(ws::Worksheet)
    _require_writable(ws, "unprotect a sheet")
    isSheetProtected(ws) || return false
    p = _sheet_protection(ws)
    p.attrs = Dict{String,String}(); p.options = nothing; p.changed = true
    return true
end

"""
    isSheetProtected(sheet) -> Bool

Whether a sheet is protected. Works on read-only files.
"""
isSheetProtected(ws::Worksheet) = get(_sheet_protection(ws).attrs, "table:protected", "false") == "true"

"""
    getSheetProtection(sheet) -> Union{Nothing, NamedTuple}

How a sheet is protected, or `nothing`: `password` (whether a key is set) and a `Bool` for each of
[`protectSheet`](@ref)'s permissions (those LibreOffice lacks are `false`). Works on read-only files.
"""
function getSheetProtection(ws::Worksheet)
    isSheetProtected(ws) || return nothing
    p = _sheet_protection(ws)
    opts = something(p.options, Dict{String,String}())
    allows = map(keys(_SHEET_PERMISSIONS)) do k
        default, attr = _SHEET_PERMISSIONS[k]
        attr === nothing ? false : p.options === nothing ? default : get(opts, attr, "false") == "true"
    end
    return merge((password = haskey(p.attrs, "table:protection-key"),), NamedTuple{keys(_SHEET_PERMISSIONS)}(allows))
end

# The start tag's protection attribute changes, for a sheet whose protection changed.
_protection_changes(p::SheetProtection) =
    Pair{String,Union{Nothing,String}}[k => (haskey(p.attrs, k) ? _escape_attr(p.attrs[k]) : nothing) for k in _PROT_ATTRS]

function _protection_xml(p::SheetProtection)
    p.options === nothing && return ""
    io = IOBuffer()
    print(io, "<loext:table-protection")
    for (_, attr) in _SHEET_PERMISSIONS                 # in LibreOffice's order
        (attr === nothing || !haskey(p.options, attr)) && continue
        print(io, ' ', attr, "=\""); _escape_attr(io, p.options[attr]); print(io, '"')
    end
    print(io, "/>")
    return String(take!(io))
end

_needs_protection_loext(xf::ODSFile) = any(ws -> _prot_changed(ws) && ws.protection.options !== nothing, xf.sheets)

#
# The file's structure
#

const _WB_PROT_ATTRS = ("table:structure-protected", "table:protection-key", "table:protection-key-digest-algorithm",
                        "loext:protection-key-digest-algorithm-2")

# The span of office:spreadsheet's start tag in the document, or nothing.
function _spreadsheet_tag_span(xf::ODSFile)
    isnewfile(xf) && return nothing
    r = findfirst(r"<office:spreadsheet\b[^>]*>", xf.content)
    return r
end

function _wb_protection(xf::ODSFile)
    xf.wbprotection === nothing || return xf.wbprotection
    attrs = Dict{String,String}()
    r = _spreadsheet_tag_span(xf)
    if r !== nothing
        tag = SubString(xf.content, first(r), last(r))
        for k in _WB_PROT_ATTRS
            v = _start_tag_attr(tag, k)
            v === nothing || (attrs[k] = v)
        end
    end
    xf.wbprotection = WorkbookProtection(attrs, false)
    return xf.wbprotection
end

_wbprot_changed(xf::ODSFile) = xf.wbprotection !== nothing && xf.wbprotection.changed

"""
    protectWorkbook(xf; password=nothing, structure=true, windows=false)

Protect the file's structure, as LibreOffice's *Tools → Protect Spreadsheet Structure* does: its
sheets can't then be added, deleted, moved, renamed, hidden or shown in LibreOffice. `password` is
stored as [`protectSheet`](@ref) stores it. LibreOffice has no window protection: `windows=true` is
an error, and `structure` must be `true`.

See also [`unprotectWorkbook`](@ref), [`isWorkbookProtected`](@ref), [`getWorkbookProtection`](@ref).
"""
function protectWorkbook(xf::ODSFile; password::Union{Nothing,AbstractString} = nothing, structure::Bool = true,
                         windows::Bool = false)
    _require_writable(xf, "protect the workbook")
    windows && throw(ODSError("LibreOffice has no window protection: give `windows=false`."))
    structure || throw(ODSError("Nothing to protect: give `structure=true`. To remove protection, use `unprotectWorkbook`."))
    p = _wb_protection(xf)
    attrs = Dict{String,String}("table:structure-protected" => "true")
    if password !== nothing && !isempty(password)
        attrs["table:protection-key"] = _protection_key(password)
        attrs["table:protection-key-digest-algorithm"] = _SHA1_URI
    end
    p.attrs = attrs; p.changed = true
    return nothing
end

"""
    unprotectWorkbook(xf) -> Bool

Remove the file's structure protection, whatever its password. `false` if it had none. The
sheets keep their own protection.
"""
function unprotectWorkbook(xf::ODSFile)
    _require_writable(xf, "unprotect the workbook")
    isWorkbookProtected(xf) || return false
    p = _wb_protection(xf)
    p.attrs = Dict{String,String}(); p.changed = true
    return true
end

"""
    isWorkbookProtected(xf) -> Bool

Whether the file's structure is protected. Works on read-only files.
"""
isWorkbookProtected(xf::ODSFile) = get(_wb_protection(xf).attrs, "table:structure-protected", "false") == "true"

"""
    getWorkbookProtection(xf) -> Union{Nothing, NamedTuple}

How the file is protected, or `nothing`: `(password, structure, windows)`, `windows` always
`false` (LibreOffice has no window protection).
"""
function getWorkbookProtection(xf::ODSFile)
    isWorkbookProtected(xf) || return nothing
    return (password = haskey(_wb_protection(xf).attrs, "table:protection-key"), structure = true, windows = false)
end

_wb_protection_attrs_xml(xf::ODSFile) =
    xf.wbprotection === nothing ? "" : join(" $k=\"" * _escape_attr(xf.wbprotection.attrs[k]) * "\"" for k in _WB_PROT_ATTRS
                                            if haskey(xf.wbprotection.attrs, k))

#
# Cells
#

# style:cell-protect (F-054): `none`, `protected`, `formula-hidden`, `protected formula-hidden`,
# and `hidden-and-protected` (LibreOffice's "hide all"). Without it a cell is protected.
_cell_protect_flags(v::Union{Nothing,AbstractString}) =
    v === nothing ? (true, false) :
    v == "hidden-and-protected" ? (true, true) :
    (occursin("protected", v) && !occursin("none", v), occursin("formula-hidden", v))

_cell_protect_value(locked::Bool, hidden::Bool) =
    locked && hidden ? "protected formula-hidden" : locked ? "protected" : hidden ? "formula-hidden" : "none"

function _protection_transform(st::StyleIndex, caller::Symbol; locked::Union{Nothing,Bool} = nothing,
                               hidden::Union{Nothing,Bool} = nothing, hideAll::Union{Nothing,Bool} = nothing,
                               hidePrint::Union{Nothing,Bool} = nothing, kw...)
    _check_keywords(caller, kw)
    locked === nothing && hidden === nothing && hideAll === nothing && hidePrint === nothing && return identity
    return function (cs)
        changes = Pair{String,String}[]
        if locked !== nothing || hidden !== nothing || hideAll !== nothing
            cur = getprop(cs.cell, "style:cell-protect")
            l, h = _cell_protect_flags(cur)
            all = something(hideAll, cur == "hidden-and-protected")
            # LibreOffice's "hide all" stands for the cell's whole protection (D-076)
            push!(changes, "style:cell-protect" => all ? "hidden-and-protected" : _cell_protect_value(something(locked, l), something(hidden, h)))
        end
        hidePrint === nothing || push!(changes, "style:print-content" => hidePrint ? "false" : "true")
        with_cell(cs, setprops(cs.cell, changes...))
    end
end

"""
    setCellProtection(sheet, ref; locked=nothing, hidden=nothing, hideAll=nothing, hidePrint=nothing) -> String or -1
    setCellProtection(sheet, row, col; …) / setCellProtection(xf, "Sheet1.B2:D10"; …)

Set whether cells are locked, and whether their formulas are hidden, on a protected sheet, as the
*Cell Protection* tab of LibreOffice's *Format Cells* does (`style:cell-protect`). Every
cell is locked unless its format says otherwise. Only the keywords given change, and the cells'
other formatting is kept. Address forms as [`setFont`](@ref); as with the other format setters,
whole columns and rows are formatted as such, not only up to the used range.

Two more options: `hideAll` (LibreOffice's
*Hide all*: on a protected sheet the cell shows nothing, and is locked; while it is set, `locked`
and `hidden` change nothing) and `hidePrint` (*Hide when printing*, `style:print-content`).
"""
setCellProtection(x::Union{Worksheet,ODSFile}, ref...; kw...) =
    apply_format!(_protection_transform(_styles_of(x), :setCellProtection; kw...), format_targets(x, ref...))

"""
    getCellProtection(sheet, ref) -> NamedTuple
    getCellProtection(sheet, row, col) / getCellProtection(xf, "Sheet1.B2")

`(locked, hidden, hideAll, hidePrint)` for one cell: locked and not hidden unless its format says
otherwise. LibreOffice's *Hide all* (`hideAll`) also reads as locked and hidden; `hidePrint` is
LibreOffice's *Hide when printing*. Works on read-only files.
"""
function getCellProtection(x::Union{Worksheet,ODSFile}, ref...)
    ws, r, c = format_cell(x, ref...)
    cell, _, _ = resolved_props(get_odsfile(ws).styles, effective_style(ws, r, c); defaults = false)
    v = get(cell, "style:cell-protect", nothing)
    l, h = _cell_protect_flags(v)
    return (locked = l, hidden = h, hideAll = v == "hidden-and-protected",
            hidePrint = get(cell, "style:print-content", "true") == "false")
end

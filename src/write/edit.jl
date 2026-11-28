# Editing: `newods`, `addsheet!`, `setdata!` / `setindex!`, `setFormula`.
#
# The forms of `setdata!` and indexed assignment follow XLSX.jl 0.13.4 (src/setdata.jl;
# `newxlsx` in src/read.jl; `addsheet!` in src/sheetops.jl), MIT License, Copyright (c)
# 2018-2026 Felipe Noronha Tavares and other contributors. Values go into the run-length
# store (`store_set!`), and edits to sheets read from a file are recorded so that saving
# can patch the file (D-023).

function _require_writable(xf::ODSFile, what::AbstractString)
    xf.writable || throw(ODSError("Can't $what: the file is read-only. Open it with `openods(…; mode=\"rw\")`, or start one with `newods()`."))
    _require_whole(xf, what)
    return nothing
end
function _require_writable(ws::Worksheet, what::AbstractString)
    _require_writable(get_odsfile(ws), what)
    ws.touched = true            # its patched save writes it again (D-100)
    return nothing
end

# A file whose model a structural edit left half-changed is not edited or saved (`_all_or_nothing`).
_require_whole(xf::ODSFile, what::AbstractString) = xf.broken === nothing ||
    throw(ODSError("Can't $what: $(xf.broken) failed part-way, so the file's contents in memory are " *
                   "only partly changed. The file on disk is as it was: open it again."))

# Runs the changing part of a structural edit (`what`, as "`insertRows`"): one that fails part-way
# leaves the model half-changed, so the file is marked and refuses edits and saves from then on.
# Its checks run before, so a refused call changes nothing. (Phase 2 of the code review: a snapshot
# of everything an edit touches, to restore, would cost a copy of most of the model.)
function _all_or_nothing(f::Function, xf::ODSFile, what::AbstractString)
    try
        return f()
    catch
        xf.broken = what
        rethrow()
    end
end

"""
    newods(sheetname="") -> ODSFile

A new, empty spreadsheet with one sheet (`Sheet1`, or `sheetname`), open for writing.
Write it with [`writeods`](@ref).

```julia
xf = newods("Results")
sh = xf["Results"]
sh["A1:B1"] = ["Item" "Total"]
sh["A2"] = "Paper"; sh["B2"] = 12.5
writeods("results.ods", xf; overwrite = true)
```
"""
function newods(sheetname::AbstractString = "")
    xf = ODSFile("blank.ods", nothing, "", DEFAULT_ODF_VERSION, StyleIndex(), Worksheet[], NameDef[],
                 SheetCore.DEFAULT_NULL_DATE, true, true, nothing)
    addsheet!(xf, isempty(sheetname) ? "Sheet1" : sheetname)
    return xf
end

# LibreOffice does not allow these characters in sheet names.
const _BAD_SHEETNAME_CHARS = ('[', ']', '*', '?', ':', '/', '\\')

function _check_sheetname(xf::ODSFile, name::AbstractString)
    isempty(name) && throw(ODSError("A sheet name can't be empty."))
    for c in _BAD_SHEETNAME_CHARS
        occursin(c, name) && throw(ODSError("The sheet name `$name` holds `$c`, which LibreOffice does not allow in sheet names."))
    end
    (startswith(name, '\'') || endswith(name, '\'')) &&
        throw(ODSError("A sheet name can't start or end with an apostrophe: `$name`."))
    _check_xml_text(name)
    hassheet(xf, name) && throw(ODSError("$(xf.source) already has a sheet named `$name`."))
    return nothing
end

"""
    addsheet!(xf::ODSFile, name="") -> Worksheet

Add an empty sheet at the end. Without a name, it is called `SheetN` (the first free N).

```julia
xf = newods("Income")
costs = addsheet!(xf, "Costs")
costs["A1"] = "Month"
sheetnames(xf)            # ["Income", "Costs"]
```
"""
function addsheet!(xf::ODSFile, name::AbstractString = "")
    _require_writable(xf, "add a sheet")
    if isempty(name)
        n = length(_sheets(xf)) + 1
        while hassheet(xf, "Sheet$n")
            n += 1
        end
        name = "Sheet$n"
    end
    _check_sheetname(xf, name)
    ws = Worksheet(xf, String(name), length(_sheets(xf)) + 1, nothing, true, SheetStore(), nothing, ReentrantLock())
    push!(xf.sheets, ws)
    return ws
end

#
# Setting one cell
#

function _mark_dirty!(ws::Worksheet, row::Int, col::Int)
    ws.entry === nothing && return
    push!(get!(Vector{Int}, ws.dirty, row), col)
    return
end

# Sets one cell to `v`, keeping a merge anchor's spans and, when it fits, the cell's style.
function _set_cell!(ws::Worksheet, row::Int, col::Int, v)
    (1 <= row <= SheetCore.MAX_ROWS && 1 <= col <= SheetCore.MAX_COLS) ||
        throw(ODSError("Cell ($row, $col) is outside the sheet (at most $(SheetCore.MAX_ROWS) rows and $(SheetCore.MAX_COLS) columns)."))
    s = _cached_store(ws)
    old = cell_data(s, row, col)
    styles = get_odsfile(ws).styles
    d = if old === nothing
        (v === missing || v === nothing) && return v      # nothing to remove
        style, covered, cs, rs = _empty_cell_base(ws, row, col)
        encode_value(v, choose_style(styles, style, v); colspan = cs, rowspan = rs, covered = covered != 0)
    else
        encode_value(v, choose_style(styles, old.style, v); colspan = old.colspan, rowspan = old.rowspan,
                     covered = (old.flags & F_COVERED) != 0)
    end
    store_set!(s, row, col, d)
    _after_cell_edit!(ws, row, col, old, d)
    _mark_dirty!(ws, row, col)
    return v
end

"""
    setdata!(sheet, ref, value)
    setdata!(sheet, row, col, value)
    sheet[ref] = value
    sheet[row, col] = value

Write `value` into a cell, or into every cell of a range. The file must be writable
([`openods`](@ref) with `mode="rw"` or `"w"`, or [`newods`](@ref)).

- `value` may be a number, string, `Bool`, `Date`, `DateTime`, `Time`, a period (a
  duration), or `missing`/`nothing` to empty the cell.
- A matrix fills a range of its size.
- A vector fills a row (`dim=2`, the default) or a column (`dim=1`) from a cell, or a
  one-row or one-column range.
- `ref` takes the forms of [`getdata`](@ref): `"B2"`, `"B2:D4"`, `"Sheet1.B2"`, `"Sheet1!B2"`,
  integers and ranges, or a defined name that refers to cells on the sheet.
- With `:` for the rows or columns: `ws[3, :] = [1, 2, 3]` writes a vector
  along row 3 from column A, and `ws[:, 2] = v` down column B from row 1. Any other value
  fills the cells addressed, where `:` stands for the sheet's used columns or rows
  (`ws[3, :] = 0`, `ws[:, 2:3] = missing`, `ws[:] = 1`).

A cell keeps its style when that style's format fits the new value. Otherwise dates,
date-times, times and booleans get ISO formats, and numbers and text the `Default` style.
"""
function setdata!(ws::Worksheet, ref::CellRef, value)
    _require_writable(ws, "write to a cell")
    return _set_cell!(ws, row_number(ref), column_number(ref), value)
end
setdata!(ws::Worksheet, row::Integer, col::Integer, value) = setdata!(ws, CellRef(row, col), value)

function setdata!(ws::Worksheet, ref::CellRef, value::AbstractVector, dim::Integer = 2)
    _require_writable(ws, "write to a cell")
    dim in (1, 2) || throw(ODSError("`dim` must be 1 (down a column) or 2 (along a row), not $dim."))
    r, c = row_number(ref), column_number(ref)
    for (k, x) in enumerate(value)
        dim == 2 ? _set_cell!(ws, r, c + k - 1, x) : _set_cell!(ws, r + k - 1, c, x)
    end
    return value
end

function setdata!(ws::Worksheet, ref::CellRef, value::AbstractMatrix)
    _require_writable(ws, "write to a cell")
    r, c = row_number(ref), column_number(ref)
    for j in axes(value, 2), i in axes(value, 1)
        _set_cell!(ws, r + i - first(axes(value, 1)), c + j - first(axes(value, 2)), value[i, j])
    end
    return value
end

function setdata!(ws::Worksheet, rng::CellRange, value)
    _require_writable(ws, "write to a range")
    rows = row_number(rng.start):row_number(rng.stop)
    cols = column_number(rng.start):column_number(rng.stop)
    return _set_block!(ws, rows, cols, value)
end

# Writes `value` over rows × cols: a scalar fills them; a matrix must have their shape; a
# vector fills a one-row or one-column block.
function _set_block!(ws::Worksheet, rows, cols, value)
    if value isa AbstractMatrix
        size(value) == (length(rows), length(cols)) ||
            throw(ODSError("A $(size(value, 1))×$(size(value, 2)) matrix doesn't fit a $(length(rows))×$(length(cols)) range."))
        for (j, c) in enumerate(cols), (i, r) in enumerate(rows)
            _set_cell!(ws, r, c, value[first(axes(value, 1)) + i - 1, first(axes(value, 2)) + j - 1])
        end
    elseif value isa AbstractVector
        if length(rows) == 1 && length(cols) == length(value)
            for (k, c) in enumerate(cols); _set_cell!(ws, first(rows), c, value[firstindex(value) + k - 1]); end
        elseif length(cols) == 1 && length(rows) == length(value)
            for (k, r) in enumerate(rows); _set_cell!(ws, r, first(cols), value[firstindex(value) + k - 1]); end
        else
            throw(ODSError("A vector of $(length(value)) values doesn't fit a $(length(rows))×$(length(cols)) range: give a range of one row or one column of that length."))
        end
    else
        for c in cols, r in rows
            _set_cell!(ws, r, c, value)
        end
    end
    return value
end

setdata!(ws::Worksheet, s::SheetCellRef, value) = (do_sheet_names_match(ws, s); setdata!(ws, s.cellref, value))
setdata!(ws::Worksheet, s::SheetCellRange, value) = (do_sheet_names_match(ws, s); setdata!(ws, s.rng, value))
setdata!(ws::Worksheet, rng::Union{ColumnRange,RowRange,SheetColumnRange,SheetRowRange,NonContiguousRange}, value) =
    throw(ODSError("Writing to whole columns, whole rows or lists of ranges is not supported; give a cell or a cell range."))

function setdata!(ws::Worksheet, ref::AbstractString, value)
    _require_writable(ws, "write to a cell")
    p = _plain_ref(ref)
    if p !== nothing
        is_valid_cellname(p) && return setdata!(ws, CellRef(p), value)
        is_valid_cellrange(p) && return setdata!(ws, CellRange(p), value)
    end
    typed = _tryparse_sheet_ref(ref)
    typed === nothing || return setdata!(ws, typed, value)
    # a defined name, the sheet's or the file's, that refers to cells (phase 5); a name can't read
    # as a reference, so references are tried first: they need no names read
    dn = something(_find_name(_local_names(ws), ref), _find_name(_wb_names(get_odsfile(ws)), ref), Some(nothing))
    dn === nothing && throw(ODSError("`$ref` is not a cell or cell range to write to."))
    v, _, isformula = _name_value(dn)
    (isformula || !is_defined_name_value_a_reference(v)) &&
        throw(ODSError("The defined name `$ref` is not a cell or cell range to write to."))
    # the cells the name refers to, on the sheet its reference names (Q-031)
    return setdata!(getsheet(get_odsfile(ws), v.sheet), v, value)
end
setdata!(ws::Worksheet, ref::AbstractString, value::AbstractVector, dim::Integer) =
    setdata!(ws, CellRef(something(_plain_ref(ref), ref)), value, dim)

# indexed forms, as XLSX.jl
_as_range(x::Integer) = x:x
_as_range(x::AbstractVector{<:Integer}) = x
_as_range(x::AbstractRange{<:Integer}) = x

Base.setindex!(ws::Worksheet, v, ref::Union{AbstractString,CellRef,CellRange,SheetCellRef,SheetCellRange}) = setdata!(ws, ref, v)
function Base.setindex!(ws::Worksheet, v::AbstractVector, ref::Union{AbstractString,CellRef}; dim::Integer = 2)
    ref isa CellRef && return setdata!(ws, ref, v, dim)
    p = _plain_ref(ref)
    p !== nothing && is_valid_cellname(p) && return setdata!(ws, CellRef(p), v, dim)
    return setdata!(ws, ref, v)          # a range: the vector must fit it
end
function Base.setindex!(ws::Worksheet, v, r::Union{Integer,AbstractVector{<:Integer}}, c::Union{Integer,AbstractVector{<:Integer}})
    _require_writable(ws, "write to a cell")
    if r isa Integer && c isa Integer
        v isa AbstractArray && throw(ODSError("A single cell takes a single value, not a $(typeof(v))."))
        return _set_cell!(ws, Int(r), Int(c), v)
    end
    return _set_block!(ws, _as_range(r), _as_range(c), v)
end

# Whole rows and columns with `:`, as XLSX.jl (src/write.jl `setdata!` with `Colon`, and the
# `setindex!` forms that call it, @ 0.13.4): a vector goes along one row from column A
# (`ws[row, :]`) or down one column from row 1 (`ws[:, col]`); any other value fills the
# cells addressed, where `:` stands for the sheet's used rows or columns (`get_dimension`,
# as the getters read them).
const _SetIndex = Union{Integer,AbstractVector{<:Integer}}

setdata!(ws::Worksheet, row::Integer, ::Colon, v::AbstractVector) = setdata!(ws, CellRef(row, 1), v, 2)
setdata!(ws::Worksheet, ::Colon, col::Integer, v::AbstractVector) = setdata!(ws, CellRef(1, col), v, 1)
function setdata!(ws::Worksheet, rows::_SetIndex, ::Colon, v)
    _require_writable(ws, "write to a row")
    dim = get_dimension(ws)
    return _set_block!(ws, _as_range(rows), column_number(dim.start):column_number(dim.stop), v)
end
function setdata!(ws::Worksheet, ::Colon, cols::_SetIndex, v)
    _require_writable(ws, "write to a column")
    dim = get_dimension(ws)
    return _set_block!(ws, row_number(dim.start):row_number(dim.stop), _as_range(cols), v)
end
function setdata!(ws::Worksheet, ::Colon, v)
    _require_writable(ws, "write to a range")
    return setdata!(ws, get_dimension(ws), v)
end
setdata!(ws::Worksheet, ::Colon, ::Colon, v) = setdata!(ws, :, v)

Base.setindex!(ws::Worksheet, v, r::_SetIndex, ::Colon) = setdata!(ws, r, :, v)
Base.setindex!(ws::Worksheet, v, ::Colon, c::_SetIndex) = setdata!(ws, :, c, v)
Base.setindex!(ws::Worksheet, v, ::Colon, ::Colon) = setdata!(ws, :, v)
Base.setindex!(ws::Worksheet, v, ::Colon) = setdata!(ws, :, v)

#
# Formulas
#

"""
    setFormula(sheet, ref; val, raw=false)
    setFormula(sheet, row, col; val, raw=false)

Write a formula into a cell, or into every cell of a range (the same formula in each).
`val` is in LibreOffice's notation, as [`getFormula`](@ref) gives it:
`"=SUM(B1:B3,'My sheet'.A1)"`. It is stored as OpenFormula (`of:=SUM([.B1:.B3];['My sheet'.A1])`).
With `raw=true`, `val` is stored as given, and must be a stored formula such as
`"of:=[.A1]*2"`.

The cell's value is left empty: LibreOffice computes it when it opens the file.

```julia
setFormula(sh, "D1"; val = "=SUM(A1:A4)")
setFormula(sh, "D2:D4"; val = "=A2*2")     # the same formula in each cell
```
"""
function setFormula(ws::Worksheet, ref::CellRef; val::AbstractString, raw::Bool = false)
    _require_writable(ws, "write a formula")
    f = raw ? String(val) : ui_to_openformula(val)
    raw && !occursin(r"^[A-Za-z][A-Za-z0-9_.-]*:=", f) && !startswith(f, "=") &&
        throw(ODSError("A raw formula must start with its namespace and `=`, such as `of:=…`: got `$val`."))
    _check_xml_text(f)
    r, c = row_number(ref), column_number(ref)
    s = _cached_store(ws)
    old = cell_data(s, r, c)
    style, covered, cs, rs = old === nothing ? _empty_cell_base(ws, r, c) :
        (old.style, old.flags & F_COVERED, old.colspan, old.rowspan)
    d = CellData(CK_EMPTY, covered, style, UInt64(0), nothing, f, cs, rs)
    store_set!(s, r, c, d)
    _after_cell_edit!(ws, r, c, old, d)
    _mark_dirty!(ws, r, c)
    return f
end
setFormula(ws::Worksheet, row::Integer, col::Integer; kw...) = setFormula(ws, CellRef(row, col); kw...)
function setFormula(ws::Worksheet, rng::CellRange; kw...)
    for c in column_number(rng.start):column_number(rng.stop), r in row_number(rng.start):row_number(rng.stop)
        setFormula(ws, CellRef(r, c); kw...)
    end
    return nothing
end
function setFormula(ws::Worksheet, ref::AbstractString; kw...)
    p = _plain_ref(ref)
    if p !== nothing
        is_valid_cellname(p) && return setFormula(ws, CellRef(p); kw...)
        is_valid_cellrange(p) && return setFormula(ws, CellRange(p); kw...)
    end
    typed = parse_sheet_ref(ref)
    do_sheet_names_match(ws, typed)
    typed isa SheetCellRef && return setFormula(ws, typed.cellref; kw...)
    typed isa SheetCellRange && return setFormula(ws, typed.rng; kw...)
    throw(ODSError("`$ref` is not a cell or cell range for a formula."))
end

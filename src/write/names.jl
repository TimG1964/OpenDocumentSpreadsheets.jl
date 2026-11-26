# Defined names (phase 5 step 5; D-058): XLSX.jl's `addDefinedName`, `deleteDefinedName`,
# `deleteAllDefinedNames`, `getDefinedNames` and `getAllDefinedNames`, with LibreOffice's rules
# for names and its stored forms (experiment 028, F-050).
#
# Adapted from XLSX.jl 0.13.4 (src/workbook.jl `addDefinedName`, `deleteDefinedName`,
# `deleteAllDefinedNames`, `getDefinedNames`, `getAllDefinedNames`, `DefinedName` and its `show`
# methods), MIT License, Copyright (c) 2018-2026 Felipe Noronha Tavares and other contributors.
# Changes: names are checked by LibreOffice's rules, not Excel's; values are stored as ODF named
# ranges and expressions; a save deletes and adds name elements in place, keeping the others.
#
# A file's names are `NameDef`s (src/model/workbook.jl) that know where their elements are. Deleting
# one notes its span; adding one adds a `NameDef` without a span. A patched save removes the noted
# spans and writes the added names into the names' element (src/write/patch.jl).

"""
    DefinedName

A defined name, as [`getDefinedNames`](@ref) and [`getAllDefinedNames`](@ref) return it. Fields:
- `name::String`
- `scope::Union{Nothing,String}`: `nothing` for a name of the whole file, or the name of the
  sheet it belongs to
- `value`: a `SheetCellRef`, `SheetCellRange`, `SheetColumnRange`, `SheetRowRange` or
  `NonContiguousRange` for a name that refers to cells; a number, string or `Bool` for a
  constant; or the formula, as a string starting with `=` (in LibreOffice's notation)
- `absolute::Union{Bool,Vector{Bool}}`: whether the reference is absolute (`\$A\$1`, not
  `A1`); one entry per area for a `NonContiguousRange`; `false` for anything else
- `hidden::Bool`: always `false`: ODF has no hidden names

`addDefinedName(x, dn.name, dn.value; absolute = dn.absolute)` makes the name again. It is a
snapshot: later edits to the file don't change it.
"""
struct DefinedName
    name::String
    scope::Union{Nothing,String}
    value::Any
    absolute::Union{Bool,Vector{Bool}}
    hidden::Bool
end

Base.:(==)(a::DefinedName, b::DefinedName) =
    a.name == b.name && a.scope == b.scope && isequal(a.value, b.value) && a.absolute == b.absolute
Base.hash(dn::DefinedName, h::UInt) = hash(dn.absolute, hash(dn.value, hash(dn.scope, hash(dn.name, h))))

_show_value(dn::DefinedName) = dn.value isa AbstractString && startswith(dn.value, '=') ? dn.value :
    is_defined_name_value_a_reference(dn.value) ? string(dn.value) : repr(dn.value)
_show_scope(dn::DefinedName) = dn.scope === nothing ? "Workbook" : "Worksheet: \"$(dn.scope)\""

Base.show(io::IO, dn::DefinedName) = print(io, dn.name, " = ", _show_value(dn))

function Base.show(io::IO, ::MIME"text/plain", dn::DefinedName)
    println(io, "DefinedName: ", dn.name)
    println(io, "  scope: ", _show_scope(dn))
    print(io, "  value: ", _show_value(dn))
end

_cut(s::AbstractString, n::Int) = length(s) <= n ? s : first(s, n - 1) * "…"

function Base.show(io::IO, ::MIME"text/plain", v::AbstractVector{DefinedName})
    if isempty(v)
        print(io, "0-element Vector{DefinedName}")
        return
    end
    mixed = !allequal(dn.scope for dn in v)
    println(io, length(v), "-element Vector{DefinedName}:")
    if mixed
        @printf(io, " %-26s %-24s %-32s\n", "Name", "Value", "[Scope]")
        print(io, " ", "-"^26, " ", "-"^24, " ", "-"^32)
        for dn in v
            @printf(io, "\n %-26s %-24s %-32s", "\"" * _cut(dn.name, 24) * "\"", _cut(_show_value(dn), 24),
                    "[" * _cut(_show_scope(dn), 32) * "]")
        end
    else
        @printf(io, " %-26s %-24s\n", "Name", "Value")
        print(io, " ", "-"^26, " ", "-"^24)
        for dn in v
            @printf(io, "\n %-26s %-24s", "\"" * _cut(dn.name, 24) * "\"", _cut(_show_value(dn), 24))
        end
    end
end

#
# Names LibreOffice accepts (F-050)
#

# A name character after the first: a letter, a digit (of any script), `_` or `?`.
_name_char(c::Char) = isletter(c) || isnumeric(c) || c == '_' || c == '?'

"""
    _check_defined_name(name)

Throws unless LibreOffice accepts `name` as a defined name (experiment 028): it starts with
a letter or `_`, goes on with letters, digits, `_` and `?`, and doesn't read as a reference: not
a cell in A1 notation (`A1`, `XFD1048576`; `XFE1` and `A1048577` are names), nor in R1C1 notation
(`R`, `C`, `RC`, `R1C1`, `RC1`, and anything starting with `R` or `C` and a digit).
"""
function _check_defined_name(name::AbstractString)
    isempty(name) && throw(ODSError("A defined name can't be empty."))
    _check_xml_text(name)
    c1 = first(name)
    ok = (isletter(c1) || c1 == '_') && all(_name_char, name)
    ok || throw(ODSError("Invalid defined name `$name`: as in LibreOffice, a name starts with a letter or `_` and " *
                         "holds only letters, digits, `_` and `?`."))
    u = uppercase(name)
    m = match(r"^([A-Z]{1,3})([0-9]{1,7})$", u)
    isref = m !== nothing && SheetCore.decode_column_number(m.captures[1]) <= SheetCore.MAX_COLS &&
            1 <= parse(Int, m.captures[2]) <= SheetCore.MAX_ROWS
    isref |= occursin(r"^[RC][0-9]", u) || occursin(r"^(?:R|C|RC|RC[0-9]+)$", u)
    isref && throw(ODSError("Invalid defined name `$name`: LibreOffice reads it as a cell reference."))
    return nothing
end

#
# Values: what is stored for each kind (F-050)
#

# A sheet name as an ODF address writes it, with `$`.
_odf_sheet(sheet::AbstractString) = "\$" * SheetCore.quoteit(sheet)

function _odf_cell(c::CellRef, abs::Bool)
    d = abs ? "\$" : ""
    return string(d, SheetCore.encode_column_number(column_number(c)), d, row_number(c))
end

# One area, as ODF writes it: `$Sheet1.$A$1:.$C$6`. Whole columns and rows are written as cell
# ranges over the whole sheet.
_odf_area(sheet, x::CellRef, abs::Bool) = _odf_sheet(sheet) * "." * _odf_cell(x, abs)
_odf_area(sheet, x::CellRange, abs::Bool) =
    _odf_sheet(sheet) * "." * _odf_cell(x.start, abs) * ":." * _odf_cell(x.stop, abs)
_odf_area(sheet, x::ColumnRange, abs::Bool) =
    _odf_area(sheet, CellRange(CellRef(1, x.start), CellRef(SheetCore.MAX_ROWS, x.stop)), abs)
_odf_area(sheet, x::RowRange, abs::Bool) =
    _odf_area(sheet, CellRange(CellRef(x.start, 1), CellRef(x.stop, SheetCore.MAX_COLS)), abs)

_area_of(v::SheetCellRef) = v.cellref
_area_of(v::SheetCellRange) = v.rng
_area_of(v::SheetColumnRange) = v.colrng
_area_of(v::SheetRowRange) = v.rowrng

# The `absolute` flags for a value: one per area of a non-contiguous range (as XLSX.jl).
function _absolute_flags(value, absolute::Union{Bool,AbstractVector{Bool}})
    if value isa NonContiguousRange
        absolute isa Bool && return fill(absolute, length(value.rng))
        length(absolute) == length(value.rng) ||
            throw(ODSError("`absolute` has $(length(absolute)) entries, but the range has $(length(value.rng)) areas."))
        return collect(Bool, absolute)
    end
    absolute isa Bool && return absolute
    length(absolute) == 1 || throw(ODSError("`absolute` must be one `Bool` for a value that is not a non-contiguous range."))
    return only(absolute)
end

function _check_sheet_exists(xf::ODSFile, sheet::AbstractString)
    hassheet(xf, sheet) || throw(ODSError("$(xf.source) has no sheet named `$sheet`."))
    return getsheet(xf, sheet).name             # as the file spells it
end

# The `NameDef` for a value: a named range for one area (LibreOffice's base: the sheet's A1), and a
# named expression for anything else: several areas joined by `~`, a constant, a formula (F-050).
# `home`: the sheet whose A1 is the base of a value that names none.
function _name_def(xf::ODSFile, name::String, scope, value, absolute, home::String)
    if value isa Union{SheetCellRef,SheetCellRange,SheetColumnRange,SheetRowRange}
        sheet = _check_sheet_exists(xf, value.sheet)
        abs = _absolute_flags(value, absolute)
        return NameDef(name, scope, _odf_area(sheet, _area_of(value), abs), nothing, _odf_sheet(sheet) * ".\$A\$1")
    elseif value isa NonContiguousRange
        sheet = _check_sheet_exists(xf, value.sheet)
        abs = _absolute_flags(value, absolute)
        expr = join(("[" * _odf_area(sheet, x, a) * "]" for (x, a) in zip(value.rng, abs)), '~')
        return NameDef(name, scope, nothing, expr, _odf_sheet(sheet) * ".\$A\$1")
    end
    base = _odf_sheet(home) * ".\$A\$1"
    expr = if value isa Bool
        value ? "TRUE()" : "FALSE()"
    elseif value isa Integer
        string(Int64(value))
    elseif value isa Real
        x = Float64(value)
        isfinite(x) || throw(ODSError("A defined name's number must be finite: got $value."))
        string(x)
    elseif value isa AbstractString && startswith(value, '=')
        f = ui_to_openformula(value)
        String(SubString(f, ncodeunits("of:=") + 1))
    elseif value isa AbstractString
        _check_xml_text(value)
        "\"" * replace(value, "\"" => "\"\"") * "\""
    else
        throw(ODSError("A defined name's value must be a reference, a number, a string or a `Bool`: got $(typeof(value))."))
    end
    return NameDef(name, scope, nothing, expr, base)
end

# A reference string as a value: a reference type, or `nothing` if it isn't one (a text
# constant then). Without a sheet, the areas are on `ws` (`nothing`: an error, for a workbook name).
function _parse_name_ref(ref::String, ws::Union{Nothing,Worksheet})
    p = _plain_ref(ref)
    if p !== nothing
        x = is_valid_cellname(p) ? CellRef(p) : is_valid_cellrange(p) ? CellRange(p) :
            is_valid_column_range(p) ? ColumnRange(p) : is_valid_row_range(p) ? RowRange(p) : nothing
        if x === nothing && _is_list(p)
            areas = Union{CellRef,CellRange}[]
            for it in SheetCore._split_unquoted(p, ('~', ','))
                is_valid_cellname(it) ? push!(areas, CellRef(it)) :
                is_valid_cellrange(it) ? push!(areas, CellRange(it)) : return nothing
            end
            x = areas
        end
        x === nothing && return nothing
        ws === nothing && throw(ODSError("The reference `$ref` for a workbook name needs its sheet, such as `Sheet1.A1` or `Sheet1!A1`."))
        x isa Vector && return NonContiguousRange(ws.name, x)
        return x isa CellRef ? SheetCellRef(ws.name, x) : x isa CellRange ? SheetCellRange(ws.name, x) :
               x isa ColumnRange ? SheetColumnRange(ws.name, x) : SheetRowRange(ws.name, x)
    end
    r = try
        parse_sheet_ref(ref)
    catch e
        e isa Union{ODSError,SheetCore.SheetCoreError} || rethrow()
        nothing
    end
    r === nothing || return r
    # a list whose areas name their sheet, or leave it out
    if ws !== nothing && _is_list(ref)
        return try
            _nc_on_sheet(ws, ref)
        catch e
            e isa Union{ODSError,SheetCore.SheetCoreError} || rethrow()
            nothing
        end
    end
    return nothing
end

#
# Values: reading what is stored
#

_ref_sheet(e::RefEnd, home::Union{Nothing,String}) = e.sheet === nothing ? home : e.sheet

# The value of the areas `areas` (each a reference without brackets): a reference type and its
# `absolute` flag(s), or `nothing` if they aren't one (a 3-D range, `#REF!`, areas on several sheets).
function _areas_value(areas::Vector{String}, home::Union{Nothing,String})
    sheet = nothing
    vals = Any[]
    abss = Bool[]
    for a in areas
        ends = parse_ref(a)
        (ends === nothing || any(e -> e.err, ends)) && return nothing
        s = _ref_sheet(ends[1], home)
        s === nothing && return nothing
        all(e -> e.sheet === nothing || _same_sheet(e.sheet, s), ends) || return nothing
        sheet === nothing ? (sheet = s) : (_same_sheet(sheet, s) || return nothing)
        e1 = ends[1]; e2 = ends[end]
        if e1.col > 0 && e1.row > 0 && e2.col > 0 && e2.row > 0
            c1 = CellRef(e1.row, e1.col); c2 = CellRef(e2.row, e2.col)
            # whole columns and rows are stored as cell ranges over the sheet
            push!(vals, length(ends) == 1 ? c1 :
                        (e1.row == 1 && e2.row == SheetCore.MAX_ROWS) ? ColumnRange(e1.col, e2.col) :
                        (e1.col == 1 && e2.col == SheetCore.MAX_COLS) ? RowRange(e1.row, e2.row) : CellRange(c1, c2))
            push!(abss, all(e -> e.col_abs && e.row_abs, ends))
        elseif e1.row == 0 && e2.row == 0
            push!(vals, ColumnRange(e1.col, e2.col)); push!(abss, all(e -> e.col_abs, ends))
        elseif e1.col == 0 && e2.col == 0
            push!(vals, RowRange(e1.row, e2.row)); push!(abss, all(e -> e.row_abs, ends))
        else
            return nothing
        end
    end
    isempty(vals) && return nothing
    if length(vals) == 1
        v = vals[1]
        ref = v isa CellRef ? SheetCellRef(sheet, v) : v isa CellRange ? SheetCellRange(sheet, v) :
              v isa ColumnRange ? SheetColumnRange(sheet, v) : SheetRowRange(sheet, v)
        return ref, abss[1]
    end
    all(v -> v isa Union{CellRef,CellRange}, vals) || return nothing
    return NonContiguousRange(sheet, Union{CellRef,CellRange}[v for v in vals]), abss
end

# (value, absolute, isformula) of a stored name: a reference, a constant, or a formula in UI
# notation (`isformula`).
function _name_value(dn::NameDef)
    home = dn.base === nothing ? dn.scope : something(_base_sheet(dn.base), dn.scope, Some(nothing))
    if dn.range !== nothing
        rng = String(dn.range)
        areas = [String(SubString(rng, a, b)) for (a, b) in _areas(rng)]
        r = _areas_value(areas, home)
        r === nothing || return (r[1], r[2], false)
        return ("=" * render_ui_formula(join(("[" * a * "]" for a in areas), '~')), false, true)
    end
    expr = something(dn.expression, "")
    body = strip(_strip_formula_prefix(expr))
    startswith(body, '=') && (body = strip(SubString(body, 2)))
    toks = tokenize_formula(body)
    if !isempty(toks) && any(t -> t.kind === FT_REF, toks) &&
       all(t -> t.kind in (FT_REF, FT_SPACE) || (t.kind in (FT_OP, FT_SEP) && t.text in ("~", ";")), toks)
        r = _areas_value([String(_ref_inner(t.text)) for t in toks if t.kind === FT_REF], home)
        r === nothing || return (r[1], r[2], false)
    end
    _is_intlike(body) && return (parse(Int64, body), false, false)
    x = tryparse(Float64, body)
    x === nothing || return (x, false, false)
    if length(toks) == 1 && toks[1].kind === FT_STRING
        return (replace(body[2:prevind(body, end)], "\"\"" => "\""), false, false)
    end
    uppercase(body) in ("TRUE()", "TRUE") && return (true, false, false)
    uppercase(body) in ("FALSE()", "FALSE") && return (false, false, false)
    return ("=" * render_ui_formula(body), false, true)
end

DefinedName(dn::NameDef) = (v = _name_value(dn); DefinedName(dn.name, dn.scope, v[1], v[2], false))

#
# Adding
#

# Every name of the file in memory, with the names' edits: workbook names need every sheet indexed.
_names_of(xf::ODSFile) = _wb_names(xf)
_names_of(ws::Worksheet) = _local_names(ws)

function _add_name!(x::Union{ODSFile,Worksheet}, name::AbstractString, value; absolute = true)
    _require_writable(x, "add a defined name")
    name = String(name)
    _check_defined_name(name)
    xf = x isa ODSFile ? x : get_odsfile(x)
    names = _names_of(x)
    _find_name(names, name) === nothing ||
        throw(ODSError(x isa ODSFile ? "$(xf.source) already has a defined name `$name`." :
                       "The sheet `$(x.name)` already has a defined name `$name`."))
    if value isa AbstractString
        value = String(value)
        isempty(value) && throw(ODSError("A defined name's value can't be an empty string."))
        if !startswith(value, '=')
            r = _parse_name_ref(value, x isa Worksheet ? x : nothing)
            r === nothing || (value = r)
        end
    elseif value isa Union{CellRef,CellRange,ColumnRange,RowRange}
        x isa Worksheet || throw(ODSError("The reference `$value` for a workbook name needs its sheet."))
        value = value isa CellRef ? SheetCellRef(x.name, value) : value isa CellRange ? SheetCellRange(x.name, value) :
                value isa ColumnRange ? SheetColumnRange(x.name, value) : SheetRowRange(x.name, value)
    end
    home = x isa Worksheet ? x.name : _sheets(xf)[1].name
    dn = _name_def(xf, name, x isa Worksheet ? x.name : nothing, value, absolute, home)
    push!(names, dn)
    return nothing
end

"""
    addDefinedName(xf::ODSFile, name, value; absolute=true)
    addDefinedName(sheet::Worksheet, name, value; absolute=true)

Add a defined name to the file, or to a sheet (a name only that sheet's formulas see). `value`
can be:
- a reference: a `SheetCellRef`, `SheetCellRange`, `SheetColumnRange`, `SheetRowRange` or
  `NonContiguousRange`, or a string such as `"Sheet1.A1:B2"`, `"Sheet1!A1:B2"` or
  `"Sheet1.A1:A3,Sheet1.C1"`. A sheet's name may leave the sheet out (`"A1:B2"`, `"A1,C3"`,
  `"A:C"`); a file's name may not.
- a number, a `Bool` or any other string: a constant
- a string starting with `=`: a formula, in LibreOffice's notation (`"=SUM(\$Sheet1.\$A\$1:\$A\$9)*2"`).
  As in LibreOffice, its references are relative to `A1` of the file's first sheet (or of the
  sheet, for a sheet's name) unless they have `\$`, the sheet's name included: `Sheet1.A1`
  used on the next sheet refers to that sheet's `A1`.

`absolute=false` makes a reference relative (`A1` rather than `\$A\$1`): as in LibreOffice, a
formula using the name then refers to the cells at the same offset from its own cell as the
reference is from `A1`. Its sheet stays the one named. Give a vector, one entry per area, for a
`NonContiguousRange`.

Names follow LibreOffice's rules: a letter or `_` first, then letters, digits, `_`
and `?`, and nothing that reads as a cell reference (`A1`, `R1C1`, `R`, `C1x`). They are
unique without regard to case within a file, or within a sheet; a sheet's name may be the
same as a file's name, and then hides it on that sheet.

# Examples
```julia
addDefinedName(xf, "Prices", "Data.B2:B20")
addDefinedName(xf["Data"], "Rate", 0.2)
addDefinedName(xf, "Total", "=SUM(Data.B2:B20)")
```

See also [`getDefinedNames`](@ref), [`deleteDefinedName`](@ref).
"""
function addDefinedName end
addDefinedName(xf::ODSFile, name::AbstractString, value; absolute::Union{Bool,AbstractVector{Bool}} = true) =
    _add_name!(xf, name, value; absolute)
addDefinedName(ws::Worksheet, name::AbstractString, value; absolute::Union{Bool,AbstractVector{Bool}} = true) =
    _add_name!(ws, name, value; absolute)

#
# Deleting
#

function _delete_names!(x::Union{ODSFile,Worksheet}, targets::Vector{String})
    _require_writable(x, "delete a defined name")
    names = _names_of(x)
    where_ = x isa ODSFile ? (x::ODSFile).source : "the sheet `$((x::Worksheet).name)`"
    found = NameDef[]
    for name in targets
        isempty(name) && throw(ODSError("A defined name can't be an empty string."))
        dn = _find_name(names, name)
        dn === nothing && throw(ODSError("$where_ has no defined name `$name`."))
        j = findfirst(d -> d === dn, found)
        j === nothing || throw(ODSError("The defined name `$name` is given more than once (also as `$(targets[j])`)."))
        push!(found, dn)
    end
    ed = x.nameedits
    for dn in found
        k = findfirst(d -> d === dn, names)
        deleteat!(names, k)
        isempty(dn.span) || push!(ed.removed, dn.span)
    end
    return nothing
end

function _checked_name(dn::DefinedName, scope::Union{Nothing,String}, where_::String)
    (dn.scope === nothing ? scope === nothing : scope !== nothing && _same_sheetname(dn.scope, scope)) ||
        throw(ODSError("The defined name `$(dn.name)` belongs to $(_show_scope(dn)), not to $where_."))
    return dn.name
end

"""
    deleteDefinedName(xf::ODSFile, name; force=false)
    deleteDefinedName(sheet::Worksheet, name; force=false)
    deleteDefinedName(xf_or_sheet, names; force=false)

Delete defined names from the file, or from a sheet: one name, or a vector of names or of the
[`DefinedName`](@ref)s [`getDefinedNames`](@ref) returns (each must belong to the first
argument). Names match without regard to case. Every name is checked before any is deleted: a
name that isn't there, or is given twice, is an error and nothing is deleted.

Formulas that use a deleted name are left as they are: LibreOffice shows `#NAME?` for them.
`force` is accepted and changes nothing: ODF files have no names the
application keeps for itself.

See also [`deleteAllDefinedNames`](@ref), [`addDefinedName`](@ref).
"""
function deleteDefinedName end
deleteDefinedName(xf::ODSFile, name::AbstractString; force::Bool = false) = _delete_names!(xf, [String(name)])
deleteDefinedName(ws::Worksheet, name::AbstractString; force::Bool = false) = _delete_names!(ws, [String(name)])
deleteDefinedName(xf::ODSFile, names::AbstractVector{<:AbstractString}; force::Bool = false) = _delete_names!(xf, String.(names))
deleteDefinedName(ws::Worksheet, names::AbstractVector{<:AbstractString}; force::Bool = false) = _delete_names!(ws, String.(names))
deleteDefinedName(xf::ODSFile, dns::AbstractVector{DefinedName}; force::Bool = false) =
    _delete_names!(xf, [_checked_name(dn, nothing, "the workbook") for dn in dns])
deleteDefinedName(ws::Worksheet, dns::AbstractVector{DefinedName}; force::Bool = false) =
    _delete_names!(ws, [_checked_name(dn, ws.name, "the sheet \"$(ws.name)\"") for dn in dns])

"""
    deleteAllDefinedNames(xf::ODSFile; force=false)

Delete every defined name of the file: its own and every sheet's. `force` changes nothing, as in
[`deleteDefinedName`](@ref).
"""
function deleteAllDefinedNames(xf::ODSFile; force::Bool = false)
    _require_writable(xf, "delete defined names")
    _delete_names!(xf, [dn.name for dn in _wb_names(xf)])
    for ws in _sheets(xf)
        _delete_names!(ws, [dn.name for dn in _local_names(ws)])
    end
    return nothing
end

#
# Reading
#

"""
    getDefinedNames(xf::ODSFile; include_system=false) -> Vector{DefinedName}
    getDefinedNames(sheet::Worksheet; include_system=false) -> Vector{DefinedName}

The file's own defined names, or a sheet's, sorted by name (without regard to case). A sheet's
are only those that belong to it, not the file's names its formulas can use too. The result
can be given to [`deleteDefinedName`](@ref) with the same first argument.

`include_system` is accepted and changes nothing: ODF keeps print ranges
and filters in their own elements, not in names.

See also [`getAllDefinedNames`](@ref), [`DefinedName`](@ref).
"""
function getDefinedNames end
getDefinedNames(xf::ODSFile; include_system::Bool = false) =
    sort!(DefinedName[DefinedName(dn) for dn in _wb_names(xf)]; by = dn -> uppercase(dn.name))
getDefinedNames(ws::Worksheet; include_system::Bool = false) =
    sort!(DefinedName[DefinedName(dn) for dn in _local_names(ws)]; by = dn -> uppercase(dn.name))

"""
    getAllDefinedNames(xf::ODSFile; include_system=false) -> Vector{DefinedName}

Every defined name of the file, the file's own and every sheet's, sorted by scope (the file's
first, then by sheet name) and then by name.
"""
function getAllDefinedNames(xf::ODSFile; include_system::Bool = false)
    out = DefinedName[DefinedName(dn) for dn in _wb_names(xf)]
    for ws in _sheets(xf), dn in _local_names(ws)
        push!(out, DefinedName(dn))
    end
    return sort!(out; by = dn -> (something(dn.scope, ""), uppercase(dn.name)))
end

#
# Saving
#

_names_xml(names) = join(_name_xml(dn) for dn in names)

# Whether a list of names has edits to save.
_names_edited(names::Union{Nothing,Vector{NameDef}}, ed::NameEdits) =
    !isempty(ed.removed) || (names !== nothing && any(dn -> isempty(dn.span), names))
_names_edited(ws::Worksheet) = _names_edited(ws.localnames, ws.nameedits)

# A sheet's name edits, with where new names go found if `_local_names` left it open (a sheet
# without names, and nothing after them: before `</table:table>`).
function _names_at!(ws::Worksheet)
    ed = ws.nameedits
    if ed.at == 0:-1 && ws.entry !== nothing && _names_edited(ws)
        src = parent(XML.sourcetext(ws.entry.node))
        at = findprev('<', src, last(XML.sourcespan(ws.entry.node)))
        ed.at = at:at-1
    end
    return ed
end
_names_edited(xf::ODSFile) = _names_edited(xf.names, xf.nameedits)

"""
    _name_splices(names, ed, src) -> Vector{Tuple{Int,Int,String}}

The splices of `src` that save the names' edits: the deleted names' elements removed, the added
names written before the end of the names' element, or in a new one at `first(ed.at)`; the whole
element removed when no name is left. Sorted.
"""
function _name_splices(names::Union{Nothing,Vector{NameDef}}, ed::NameEdits, src::AbstractString)
    out = Tuple{Int,Int,String}[]
    _names_edited(names, ed) || return out
    names = something(names, NameDef[])
    added = [dn for dn in names if isempty(dn.span)]
    if isempty(ed.at)
        isempty(added) || push!(out, (first(ed.at), first(ed.at) - 1,
                                      "<table:named-expressions>" * _names_xml(added) * "</table:named-expressions>"))
        return out
    end
    if isempty(names)
        push!(out, (first(ed.at), last(ed.at), ""))          # none left: the element goes too
        return out
    end
    text = SubString(src, first(ed.at), last(ed.at))
    if endswith(text, "/>")
        push!(out, (first(ed.at), last(ed.at), "<table:named-expressions>" * _names_xml(added) * "</table:named-expressions>"))
        return out
    end
    foreach(r -> push!(out, (first(r), last(r), "")), ed.removed)
    if !isempty(added)
        at = first(ed.at) - 1 + first(findlast("</", text))
        push!(out, (at, at - 1, _names_xml(added)))
    end
    return sort!(out; by = x -> (x[1], x[2]))
end

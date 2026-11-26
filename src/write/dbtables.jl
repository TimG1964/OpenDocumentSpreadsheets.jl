# Tables (phase 6 step 7, D-077): XLSX.jl's Excel-table API on LibreOffice's database ranges (F-062, F-070):
#   - a table is a `table:database-range` of the workbook's `table:database-ranges` (after the tables and
#     the names): its name, its cells (`table:target-range-address`), whether its first row holds the
#     column labels (`table:contains-header`, true by default) and its last row the totals
#     (`calcext:contains-footer`), and its filter buttons (`table:display-filter-buttons`)
#   - LibreOffice has no table styles, no ids and no per-column totals settings: a totals cell's setting is
#     read from its formula (`SUBTOTAL(109;…)` over the column's data rows is `:sum`), and functions are
#     written as LibreOffice saves a structured reference, an absolute range (`[$Sheet.$G$2:.$G$5]`)
#   - names are LibreOffice's: those of a defined name (F-050), unique ignoring case, apart from the
#     defined names; ranges may overlap, and a range may be its header alone (F-070)
#   - sheets' anonymous ranges (`__Anonymous_Sheet_DB__N`: autofilters and sorts) are not tables
# Ranges added or changed are `ODSFile.dbedits.model` (`DBRange`), moved by line and sheet operations as
# they are made; the file's, and those sheet copies added (`ODSFile.extras`), are read and replayed as
# the save writes them, and are replaced by a model range when changed (D-069).
# The API follows XLSX.jl 0.13.4 (src/exceltables.jl, src/types.jl `Table`, `TableStyleInfo`;
# src/writetable.jl `as_table`, `totals`, `freeze_header`; src/read.jl `table_name`), MIT License,
# Copyright (c) 2018-2026 Felipe Noronha Tavares and other contributors: names, keywords, checks and
# messages, return shapes, and the totals functions' SUBTOTAL codes.

"""
    TableStyleInfo

A table style: a name and four stripe and column flags. LibreOffice has no styles for database
ranges, so a [`Table`](@ref)'s `style` is always `nothing`.
"""
struct TableStyleInfo
    name::Union{String,Nothing}
    show_first_column::Bool
    show_last_column::Bool
    show_row_stripes::Bool
    show_column_stripes::Bool
end

"""
    Table

A table: a named range of a sheet whose first row holds the column labels (LibreOffice's database
range, Data ▸ Define Range). Obtain one with [`table`](@ref) or
[`tables`](@ref), make one with [`addtable!`](@ref). A `Table` is a Tables.jl table of its data
rows (`DataFrame(t)`), as [`gettable`](@ref) reads them.

# Fields
- `id::Int`: its number among the workbook's tables, in the file's order (LibreOffice has no ids:
  deleting a table renumbers those after it)
- `name::String`: its name, unique in the workbook ignoring case; `display_name` is the same
- `ref::CellRange`: its cells, with the header row and any totals row
- `columns::Vector{String}`: the column labels, from the header row (`"Column B"` for an empty one,
  and for every column of a table without a header, as LibreOffice names them)
- `has_header_row::Bool`: whether the first row holds the labels (LibreOffice's *Contains column
  labels*)
- `has_totals_row::Bool`: whether the last row holds the totals (*Contains totals row*)
- `style`: always `nothing` (LibreOffice has no table styles)
- `sheet`: the `Worksheet`
- `filterButtons::Bool`: whether the header shows filter buttons (LibreOffice's)

A `Table` is a snapshot: the functions that change a table return a new one.
"""
struct Table
    id::Int
    name::String
    display_name::String
    ref::CellRange
    columns::Vector{String}
    has_header_row::Bool
    has_totals_row::Bool
    style::Union{TableStyleInfo,Nothing}
    sheet
    filterButtons::Bool
end

const _ANON_DB = "__Anonymous_Sheet_DB__"
const _CALCEXT_NS = "urn:org:documentfoundation:names:experimental:calc:xmlns:calcext:1.0"

# SUBTOTAL's codes for the totals functions, which ignore hidden rows (XLSX.jl's TOTALS_ROW_FUNCTIONS,
# as LibreOffice's import writes them).
const TOTALS_FUNCTIONS = (sum = 109, average = 101, count = 103, countnums = 102, max = 104, min = 105, stddev = 107, var = 110)
const _TOTALS_BY_CODE = Dict(v => k for (k, v) in pairs(TOTALS_FUNCTIONS))

#
# The database ranges as they are now
#

# A database range now: its name, sheet and cells, flags, where it is kept (`:file`, `:copy` or
# `:model`, and its index there), its place, and its element now ("" for one of the model).
struct _DBNow
    name::String
    sheet::Worksheet
    r1::Int
    c1::Int
    r2::Int
    c2::Int
    header::Bool
    footer::Bool
    buttons::Bool
    kind::Symbol
    k::Int
    order::Float64
    xml::String
end

const _DBR_RX = r"<table:database-range\b[^>]*?(?:/>|>.*?</table:database-range>)"s

# The file's database ranges (their spans and elements), read on first use: the workbook's element
# follows the tables, so it is looked for from the end.
function _file_dbranges(xf::ODSFile)
    d = xf.dbedits
    d.file === nothing || return d.file
    out = Tuple{UnitRange{Int},String}[]
    if !isnewfile(xf)
        s = xf.content
        i = findlast("<table:database-ranges", s)
        if i !== nothing
            j = findnext("</table:database-ranges>", s, last(i))
            lim = j === nothing ? ncodeunits(s) : first(j)
            pos = first(i)
            while (rg = findnext(_DBR_RX, s, pos)) !== nothing && last(rg) <= lim
                push!(out, (rg, String(SubString(s, rg))))
                pos = nextind(s, last(rg))
            end
        end
    end
    d.file = out
    return out
end

const _DB_ADDR_RX = r"^\$?('(?:[^']|'')*'|[^.']+)\.\$?([A-Za-z]{1,3})\$?([0-9]+)(?::(?:\$?(?:'(?:[^']|'')*'|[^.']+)\.)?\$?([A-Za-z]{1,3})\$?([0-9]+))?$"

# `Sheet.A1:Sheet.C5` (or a cell) as (sheet, r1, c1, r2, c2), or nothing.
function _db_address(a::AbstractString)
    m = match(_DB_ADDR_RX, a)
    m === nothing && return nothing
    sh = String(m.captures[1])
    startswith(sh, '\'') && (sh = replace(sh[2:prevind(sh, lastindex(sh))], "''" => "'"))
    c1 = SheetCore.decode_column_number(uppercase(m.captures[2])); r1 = Int(parse(Int64, m.captures[3]))
    c2 = m.captures[4] === nothing ? c1 : SheetCore.decode_column_number(uppercase(m.captures[4]))
    r2 = m.captures[5] === nothing ? r1 : Int(parse(Int64, m.captures[5]))
    return sh, min(r1, r2), min(c1, c2), max(r1, r2), max(c1, c2)
end

function _db_push!(out::Vector{_DBNow}, x::String, byname, kind::Symbol, k::Int, order::Float64)
    isempty(x) && return                                   # its target is gone (F-043)
    e = something(findfirst('>', x), ncodeunits(x))
    tag = SubString(x, 1, e)
    a = _attr_in(tag, "table:target-range-address")
    a === nothing && return
    p = _db_address(a)
    p === nothing && return
    ws = get(byname, p[1], nothing)
    ws === nothing && return
    push!(out, _DBNow(something(_attr_in(tag, "table:name"), ""), ws, p[2], p[3], p[4], p[5],
                      _attr_in(tag, "table:contains-header") != "false", _attr_in(tag, "calcext:contains-footer") == "true",
                      _attr_in(tag, "table:display-filter-buttons") == "true", kind, k, order, x))
end

# Every database range now, in the file's order (the file's, then copies', then those added).
function _db_now(xf::ODSFile)
    out = _DBNow[]
    d = xf.dbedits
    sheets = _sheets(xf)
    byname = Dict(ws.name => ws for ws in sheets)
    if !isnewfile(xf)
        for (k, (_, x)) in enumerate(_file_dbranges(xf))
            k in d.removed && continue
            _db_push!(out, isempty(xf.ops) ? x : _rewritten(x, xf.ops), byname, :file, k, Float64(k))
        end
        for (k, (x, n)) in enumerate(xf.extras)
            k in d.removedx && continue
            _db_push!(out, _rewritten(x, xf.ops[n+1:end]), byname, :copy, k, 1.0e6 + k)
        end
    end
    for (k, m) in enumerate(d.model)
        any(ws -> ws === m.sheet, sheets) || continue       # its sheet was deleted
        push!(out, _DBNow(m.name, m.sheet, m.r1, m.c1, m.r2, m.c2, m.header, m.footer, m.buttons, :model, k, m.order, ""))
    end
    sort!(out; by = x -> x.order)
    return out
end

_db_edited(xf::ODSFile) = (d = xf.dbedits; !isempty(d.model) || !isempty(d.removed) || !isempty(d.removedx))

# A range now as one of the model, to change: the file's or a copy's is replaced by one (D-077).
function _db_model!(xf::ODSFile, d::_DBNow)
    e = xf.dbedits
    d.kind === :model && return e.model[d.k]
    d.kind === :file ? push!(e.removed, d.k) : push!(e.removedx, d.k)
    m = DBRange(d.name, d.sheet, d.r1, d.c1, d.r2, d.c2, d.header, d.footer, d.buttons, d.xml, d.order)
    push!(e.model, m)
    return m
end

function _db_remove!(xf::ODSFile, d::_DBNow)
    e = xf.dbedits
    if d.kind === :model
        deleteat!(e.model, d.k)
    else
        d.kind === :file ? push!(e.removed, d.k) : push!(e.removedx, d.k)
    end
    return
end

_db_cell(r::Int, c::Int) = string(SheetCore.encode_column_number(c), r)
function _db_target(m)
    q = SheetCore.quoteit(m.sheet.name)
    return q * "." * _db_cell(m.r1, m.c1) * ":" * q * "." * _db_cell(m.r2, m.c2)
end

# A range of the model as LibreOffice writes it; one replacing the file's keeps that element's other
# attributes and its children (its filter and sort).
function _db_xml(m::DBRange)
    ch = Pair{String,Union{Nothing,String}}["table:name" => _escape_attr(m.name), "table:target-range-address" => _escape_attr(_db_target(m)),
          "table:contains-header" => m.header ? nothing : "false", "table:display-filter-buttons" => m.buttons ? "true" : nothing,
          "calcext:contains-footer" => m.footer ? "true" : nothing]
    return _set_attrs(isempty(m.xml) ? "<table:database-range/>" : m.xml, ch)
end

# The ranges of the model to write (those whose sheet is still there).
_db_alive(xf::ODSFile, m::DBRange) = any(ws -> ws === m.sheet, xf.sheets)
_db_model_xml(xf::ODSFile) = join(_db_xml(m) for m in xf.dbedits.model if _db_alive(xf, m))
# Whether a range written holds `calcext:contains-footer`, so the root must declare the prefix.
_has_footers(xf::ODSFile) = any(m -> m.footer && _db_alive(xf, m), xf.dbedits.model)

# A line or sheet operation on the ranges of the model, as the save replays it on the file's (F-043):
# a range whose cells are all deleted goes.
function _rewrite_db_refs!(xf::ODSFile, op)
    e = xf.dbedits
    isempty(e.model) && return
    keep = trues(length(e.model))
    for (i, m) in enumerate(e.model)
        a = _db_target(m)
        v = _replay(_rl, a, Any[op], m.sheet.name, 0, 0)
        v == a && continue
        p = occursin("#REF!", v) ? nothing : _db_address(v)
        if p === nothing
            keep[i] = false
        else
            m.r1, m.c1, m.r2, m.c2 = p[2], p[3], p[4], p[5]
        end
    end
    all(keep) || (e.model = e.model[keep])
    return
end

# The ranges of the model on `ws`, copied for its copy `new`, named as LibreOffice names copies (F-047).
function _copy_model_dbranges!(xf::ODSFile, ws::Worksheet, new::Worksheet)
    src = [m for m in xf.dbedits.model if m.sheet === ws]
    isempty(src) && return
    names = Set(uppercase(d.name) for d in _db_now(xf))
    for m in src
        newname = if startswith(m.name, _ANON_DB)
            _ANON_DB * string(length(xf.sheets) - 1)
        else
            k = 2
            while uppercase("$(m.name)_$k") in names; k += 1; end
            "$(m.name)_$k"
        end
        push!(names, uppercase(newname))
        push!(xf.dbedits.model, DBRange(newname, new, m.r1, m.c1, m.r2, m.c2, m.header, m.footer, m.buttons, m.xml,
                                        1.0e9 + length(xf.dbedits.model) + 1))
    end
    return
end

#
# Tables
#

function _table_of(d::_DBNow, id::Int)
    ws = d.sheet
    cols = String[]
    for c in d.c1:d.c2
        v = d.header ? getdata(ws, d.r1, c) : missing
        push!(cols, (v === missing || v === nothing || v == "") ? "Column " * SheetCore.encode_column_number(c) : string(v))
    end
    return Table(id, d.name, d.name, CellRange(d.r1, d.c1, d.r2, d.c2), cols, d.header, d.footer, nothing, ws, d.buttons)
end

function _all_tables(xf::ODSFile)
    out = Table[]
    for d in _db_now(xf)
        startswith(d.name, _ANON_DB) && continue
        push!(out, _table_of(d, length(out) + 1))
    end
    return out
end

"""
    tables(sheet) -> Vector{Table}
    tables(xf::ODSFile) -> Vector{Table}

The tables of a sheet, or of the workbook, in the file's order: LibreOffice's named database
ranges (sheets' anonymous ones, which hold their autofilters, are not tables).
"""
tables(ws::Worksheet) = filter(t -> t.sheet === ws, _all_tables(get_odsfile(ws)))
tables(xf::ODSFile) = _all_tables(xf)

"""
    table(sheet, name) -> Table
    table(sheet, id::Integer) -> Table
    table(xf::ODSFile, name) / table(xf, id)

A table by name (ignoring case, as LibreOffice compares them) or number, on the sheet or in the
workbook. A `KeyError` if there is none.
"""
function table(ws::Worksheet, name::AbstractString)
    t = findfirst(t -> uppercase(t.name) == uppercase(name), tables(ws))
    t === nothing && throw(KeyError(name))
    return tables(ws)[t]
end
function table(ws::Worksheet, id::Integer)
    t = findfirst(t -> t.id == id, tables(ws))
    t === nothing && throw(KeyError(id))
    return tables(ws)[t]
end
function table(xf::ODSFile, name::AbstractString)
    v = tables(xf)
    t = findfirst(t -> uppercase(t.name) == uppercase(name), v)
    t === nothing && throw(KeyError(name))
    return v[t]
end
function table(xf::ODSFile, id::Integer)
    v = tables(xf)
    (1 <= id <= length(v)) || throw(KeyError(id))
    return v[id]
end

# A table looked up again (a `Table` is a snapshot), with its range now.
_resolve(t::Table) = table(get_odsfile(t.sheet), t.name)
function _db_of(t::Table)
    xf = get_odsfile(t.sheet)
    for d in _db_now(xf)
        uppercase(d.name) == uppercase(t.name) && return d
    end
    throw(KeyError(t.name))
end

function Base.show(io::IO, t::Table)
    n = max(0, _last_data_row(t) - _first_data_row(t) + 1)
    print(io, n, "x", length(t.columns), " Table (id=", t.id, ", \"", t.name, "\", ", t.ref)
    t.has_totals_row && print(io, ", +totals")
    print(io, ")")
end
function Base.show(io::IO, ::MIME"text/plain", t::Table)
    println(io, "Table: \"", t.name, "\"")
    println(io, "  id      : ", t.id)
    println(io, "  sheet   : ", t.sheet.name)
    println(io, "  range   : ", t.ref)
    println(io, "  columns : ", join(t.columns, ", "))
    println(io, "  header  : ", t.has_header_row ? "yes" : "no")
    print(io, "  totals  : ", t.has_totals_row ? "yes" : "no")
end

_first_data_row(t::Table) = row_number(t.ref.start) + (t.has_header_row ? 1 : 0)
_last_data_row(t::Table) = row_number(t.ref.stop) - (t.has_totals_row ? 1 : 0)
_col0(t::Table) = column_number(t.ref.start)

# A table's name, checked as LibreOffice checks a database range's (F-050, F-070); "" gives the first
# free `TableN`.
function _new_table_name(xf::ODSFile, name::AbstractString)
    used = Set(uppercase(d.name) for d in _db_now(xf))
    if isempty(name)
        i = 1
        while uppercase("Table$i") in used; i += 1; end
        return "Table$i"
    end
    startswith(name, _ANON_DB) && throw(ODSError("Table names starting with `$_ANON_DB` are LibreOffice's, for sheets' autofilters."))
    try
        _check_defined_name(name)
    catch e
        e isa ODSError || rethrow()
        throw(ODSError("Invalid table name `$name`: as in LibreOffice, a table's name is formed as a defined name's: " *
                       "it starts with a letter or `_`, holds only letters, digits, `_` and `?`, and doesn't read as a cell reference."))
    end
    uppercase(name) in used && throw(ODSError("Table name `$name` is already in use (LibreOffice ignores case in them)."))
    return String(name)
end

function _check_table_style(style)
    (style === nothing || style == "None") && return
    throw(ODSError("LibreOffice has no table styles (F-062): leave out `style` (or give `\"None\"`). Got `$style`."))
end

function _table_range(ref)
    ref isa CellRange && return ref
    s = String(ref)
    is_valid_cellname(s) && return CellRange(CellRef(s), CellRef(s))
    is_valid_cellrange(s) && return CellRange(s)
    throw(ODSError("Give a table's cells as a range such as `A1:C10`. Got `$ref`."))
end

"""
    addtable!(sheet, ref; name="", style=nothing, has_totals_row=false, has_header_row=true,
              filterButtons=true) -> Table

Make the cells `ref` (`"A1:C10"`) a table, as LibreOffice's Data ▸ Define Range makes a database
range. The cells are not
changed: the first row must already hold the column labels, each given and none repeated
(ignoring case).

`name` is LibreOffice's: formed as a defined name's, and unique among the workbook's tables
ignoring case (it may be a defined name's too, as LibreOffice allows); `""` gives the first free
`TableN`. `has_totals_row=true` makes the last row the totals row (see [`settotals!`](@ref));
its cells are left as they are. LibreOffice has no table styles: `style` other than `nothing` or
`"None"` is an error.

LibreOffice's own options: `has_header_row=false` makes a table whose first row is data
(its columns are then named `"Column A"`, …), and `filterButtons=false` hides the header's filter
buttons, which a table shows by default.

As in LibreOffice, tables may overlap each other and merged cells, and a table may be its header
row alone. The file must be writable.
"""
function addtable!(ws::Worksheet, ref; name::AbstractString = "", style = nothing, has_totals_row::Bool = false,
                   has_header_row::Bool = true, filterButtons::Bool = true)
    _require_writable(ws, "add a table")
    xf = get_odsfile(ws)
    _check_table_style(style)
    rng = _table_range(ref)
    r1, c1, r2, c2 = row_number(rng.start), column_number(rng.start), row_number(rng.stop), column_number(rng.stop)
    r2 - r1 + 1 >= has_header_row + has_totals_row ||
        throw(ODSError("Table `$ref` has one row: it can't hold both its header and its totals."))
    name = _new_table_name(xf, name)
    if has_header_row
        cols = String[]
        for c in c1:c2
            v = getdata(ws, r1, c)
            (v === missing || v == "") &&
                throw(ODSError("Table header cell $(_db_cell(r1, c)) is empty; every column needs a header value before calling `addtable!`."))
            push!(cols, string(v))
        end
        length(unique(uppercase.(cols))) == length(cols) || throw(ODSError("Table header row contains duplicate column names."))
    end
    push!(xf.dbedits.model, DBRange(name, ws, r1, c1, r2, c2, has_header_row, has_totals_row, filterButtons, "",
                                    1.0e9 + length(xf.dbedits.model) + 1))
    return table(ws, name)
end

"""
    deletetable!(t::Table)
    deletetable!(sheet, name) / deletetable!(sheet, id::Integer)

Remove a table (LibreOffice's database range), leaving its cells as they are, as LibreOffice's
Define Range ▸ Delete does. Totals formulas already refer to the cells
(LibreOffice stores no table references), so they are unchanged. The file must be writable.
"""
deletetable!(t::Table) = _deletetable!(t)
deletetable!(ws::Worksheet, name::AbstractString) = _deletetable!(table(ws, name))
deletetable!(ws::Worksheet, id::Integer) = _deletetable!(table(ws, id))
function _deletetable!(t::Table)
    xf = get_odsfile(t.sheet)
    _require_writable(xf, "delete a table")
    _db_remove!(xf, _db_of(t))
    return nothing
end

#
# Totals
#

_col_letters(c::Int) = SheetCore.encode_column_number(c)
# A column's data rows as an absolute reference, as LibreOffice saves a structured one (F-070).
function _data_ref(t::Table, c::Int; a::Int = _first_data_row(t), b::Int = _last_data_row(t))
    q = "\$" * SheetCore.quoteit(t.sheet.name) * "."
    x = "\$" * _col_letters(c) * "\$"
    return a == b ? q * x * string(a) : q * x * string(a) * ":" * x * string(b)
end

# A totals cell's setting, read from the cell (LibreOffice keeps none): a SUBTOTAL of the column's data
# rows by a totals function's code, `:custom` for another formula, `:label` for text, `:none` if empty.
function _totals_setting(t::Table, c::Int)
    ws = t.sheet
    r = row_number(t.ref.stop)
    f = getFormula(ws, r, c; raw = true)
    if f === nothing
        v = getdata(ws, r, c)
        return v === missing ? :none : v isa AbstractString ? :label : :custom
    end
    m = match(r"^(?:of:)?=SUBTOTAL\(\s*(\d+)\s*;\s*\[([^\]]*)\]\s*\)$", f)
    m === nothing && return :custom
    code = Int(parse(Int64, m.captures[1]))
    haskey(_TOTALS_BY_CODE, code) || return :custom
    p = _db_address(replace(m.captures[2], r"^\$?\." => SheetCore.quoteit(t.sheet.name) * ".", ":." => ":"))
    p === nothing && return :custom
    ok = _same_sheetname(p[1], t.sheet.name) && p[3] == c && p[5] == c && p[2] == _first_data_row(t) && p[4] == _last_data_row(t)
    return ok ? _TOTALS_BY_CODE[code] : :custom
end

# Structured references to table `t` in a formula (`Sales[Revenue]`, `Sales[[#All],[Revenue]]`,
# `Sales[#Data]`, …) as the absolute ranges LibreOffice saves them as (F-070).
function _structured_refs(f::AbstractString, t::Table)
    out = IOBuffer()
    s = String(f)
    i = 1
    n = ncodeunits(s)
    rx = Regex("(?<![\\w.\$])" * replace(t.name, r"([\\^$.|?*+()\[\]{}])" => s"\\\1") * "\\[", "i")
    while (m = findnext(rx, s, i)) !== nothing
        print(out, SubString(s, i, prevind(s, first(m))))
        j = last(m) + 1                                  # after the `[`
        depth = 1; k = j
        while k <= n && depth > 0
            ch = s[k]
            if ch == '\''
                k = nextind(s, k)                        # an escaped character
            elseif ch == '['
                depth += 1
            elseif ch == ']'
                depth -= 1
            end
            depth > 0 && (k = nextind(s, k))
        end
        depth == 0 || throw(ODSError("Unclosed structured reference in `$f`."))
        print(out, _structured_range(t, SubString(s, j, prevind(s, k)), f))
        i = nextind(s, k)
    end
    print(out, SubString(s, i))
    return String(take!(out))
end

function _structured_range(t::Table, inner::AbstractString, f)
    items = startswith(inner, '[') ? [String(m.captures[1]) for m in eachmatch(r"\[((?:[^\]']|'.)*)\]", inner)] : [String(inner)]
    area = "#Data"; col = nothing
    for it in items
        if startswith(it, '#')
            area = it
        elseif !isempty(it)
            col = replace(it, r"'(.)" => s"\1")
        end
    end
    a, b = if lowercase(area) == "#data"
        _first_data_row(t), _last_data_row(t)
    elseif lowercase(area) == "#all"
        row_number(t.ref.start), row_number(t.ref.stop)
    elseif lowercase(area) == "#headers"
        t.has_header_row || throw(ODSError("Table `$(t.name)` has no header row, for `$f`."))
        row_number(t.ref.start), row_number(t.ref.start)
    elseif lowercase(area) == "#totals"
        t.has_totals_row || throw(ODSError("Table `$(t.name)` has no totals row, for `$f`."))
        row_number(t.ref.stop), row_number(t.ref.stop)
    else
        throw(ODSError("Unknown part `$area` in a structured reference of `$f`: give `#Data`, `#All`, `#Headers` or `#Totals`."))
    end
    if col === nothing
        q = "\$" * SheetCore.quoteit(t.sheet.name) * "."
        return q * "\$" * _col_letters(column_number(t.ref.start)) * "\$" * string(a) * ":\$" * _col_letters(column_number(t.ref.stop)) * "\$" * string(b)
    end
    k = findfirst(c -> uppercase(c) == uppercase(col), t.columns)
    k === nothing && throw(ODSError("Table `$(t.name)` has no column `$col`, in `$f`. Its columns are: $(join(t.columns, ", "))."))
    return _data_ref(t, _col0(t) + k - 1; a, b)
end

function _set_totals_cell!(t::Table, c::Int, value)
    ws = t.sheet
    r = row_number(t.ref.stop)
    col = t.columns[c - _col0(t) + 1]
    if value === :none
        _set_cell!(ws, r, c, missing)
    elseif value isa Symbol
        haskey(TOTALS_FUNCTIONS, value) || throw(ODSError("Unknown totals function `:$value`. Supported: $(join(sort!(string.(collect(keys(TOTALS_FUNCTIONS)))), ", ")), or pass `(:custom, \"formula\")` for a custom function."))
        setFormula(ws, CellRef(r, c); val = "=SUBTOTAL($(TOTALS_FUNCTIONS[value]),$(_data_ref(t, c)))")
    elseif value isa Tuple{Symbol,<:AbstractString}
        value[1] === :custom || throw(ODSError("Tuple totals setting for column `$col` must be `(:custom, formula)`; got `(:$(value[1]), ...)`."))
        f = _structured_refs(value[2], t)
        setFormula(ws, CellRef(r, c); val = startswith(f, '=') ? f : "=" * f)
    elseif value isa AbstractString
        _set_cell!(ws, r, c, String(value))
    else
        throw(ODSError("Totals setting for column `$col` must be a Symbol (built-in function), a `(:custom, formula)` tuple, or a String (label); got $(typeof(value))."))
    end
end

"""
    settotals!(t::Table, settings::Pair...) -> Table
    settotals!(t::Table; kwargs...) -> Table
    settotals!(sheet, name | id, settings::Pair...) / settotals!(sheet, name | id; kwargs...)

Set a table's totals: each setting is `"column" => value` (or `column = value`),
where `value` is a totals function (`:sum`, `:average`, `:count`, `:countnums`, `:max`, `:min`,
`:stddev`, `:var`), `(:custom, formula)`, a text label, or `:none` to clear the column's cell.
Columns not given are left as they are. A table without a totals row gets one: the row after its
last, which must be empty, and the table grows by it (LibreOffice's *Contains totals row*,
`calcext:contains-footer`).

A function is written as LibreOffice's import writes it, `SUBTOTAL(109,…)` over the column's data
rows as an absolute range (LibreOffice saves structured references so). A custom formula is
in LibreOffice's notation; structured references to the table in it (`Sales[Revenue]`,
`Sales[[#All],[Revenue]]`) are written as ranges too. The file must be writable.
"""
settotals!(t::Table, settings::Pair...) = _settotals!(_resolve(t), settings...)
settotals!(t::Table; kwargs...) = _settotals!(_resolve(t), (String(k) => v for (k, v) in kwargs)...)
settotals!(ws::Worksheet, name::Union{AbstractString,Integer}, settings::Pair...) = _settotals!(table(ws, name), settings...)
settotals!(ws::Worksheet, name::Union{AbstractString,Integer}; kwargs...) =
    _settotals!(table(ws, name), (String(k) => v for (k, v) in kwargs)...)

function _settotals!(t::Table, settings::Pair...)
    ws = t.sheet
    xf = get_odsfile(ws)
    _require_writable(xf, "set a totals row")
    for (col, _) in settings
        String(col) in t.columns || throw(ODSError("Column `$col` not found in table `$(t.name)`. Available columns: $(join(t.columns, ", "))."))
    end
    if !t.has_totals_row
        r = row_number(t.ref.stop) + 1
        r > SheetCore.MAX_ROWS && throw(ODSError("Cannot add a totals row to table `$(t.name)`: it already reaches the sheet's last row."))
        for c in _col0(t):column_number(t.ref.stop)
            v = getdata(ws, r, c)
            (v === missing || v == "") || throw(ODSError("Cannot add a totals row to table `$(t.name)`: row $r already has content at $(_db_cell(r, c)). Clear that row first, or use `addtable!` with `has_totals_row=true` if this row was always meant to be part of the table."))
        end
        m = _db_model!(xf, _db_of(t))
        m.r2 = r; m.footer = true
        t = _resolve(t)
    end
    for (col, value) in settings
        _set_totals_cell!(t, _col0(t) + findfirst(==(String(col)), t.columns) - 1, value)
    end
    return _resolve(t)
end

"""
    gettotals(t::Table) -> NamedTuple
    gettotals(sheet, name | id) -> NamedTuple

A table's totals row by column name, each `(setting, formula, value)`: the totals function
(`:sum`, …), `:custom`, `:label` or `:none` (read from the cell, as LibreOffice keeps no setting:
a function is a `SUBTOTAL` of the column's data rows), the cell's formula (LibreOffice's notation,
or `nothing`) and its value (`missing` for a formula OpenDocumentSpreadsheets wrote, until
LibreOffice computes it). An empty `NamedTuple` if the table has no totals row.
"""
gettotals(t::Table) = _gettotals(_resolve(t))
gettotals(ws::Worksheet, name::Union{AbstractString,Integer}) = _gettotals(table(ws, name))
function _gettotals(t::Table)
    t.has_totals_row || return NamedTuple()
    ws = t.sheet
    r = row_number(t.ref.stop)
    vals = Any[]
    for i in eachindex(t.columns)
        c = _col0(t) + i - 1
        push!(vals, (setting = _totals_setting(t, c), formula = getFormula(ws, r, c), value = getdata(ws, r, c)))
    end
    return NamedTuple{Tuple(Symbol.(t.columns))}(Tuple(vals))
end

"""
    removetotals!(t::Table) -> Table
    removetotals!(sheet, name | id) -> Table

Remove a table's totals row: its cells are emptied and the table loses the row. Nothing changes
for a table without one. The file must be writable.
"""
removetotals!(t::Table) = _removetotals!(_resolve(t))
removetotals!(ws::Worksheet, name::Union{AbstractString,Integer}) = _removetotals!(table(ws, name))
function _removetotals!(t::Table)
    xf = get_odsfile(t.sheet)
    _require_writable(xf, "remove a totals row")
    t.has_totals_row || return t
    r = row_number(t.ref.stop)
    for c in _col0(t):column_number(t.ref.stop)
        _set_cell!(t.sheet, r, c, missing)
    end
    m = _db_model!(xf, _db_of(t))
    m.r2 = r - 1; m.footer = false
    return _resolve(t)
end

#
# Appending, reading, ranges
#

# The rows to append, each with the table's columns in order (XLSX.jl's `_normalize_append_rows`).
function _append_rows(data, t::Table)
    ncols = length(t.columns)
    rows = if data isa AbstractMatrix
        [collect(data[r, :]) for r in axes(data, 1)]
    elseif data isa AbstractVector && (isempty(data) || first(data) isa Union{AbstractVector,Tuple})
        [collect(r) for r in data]
    else
        Tables.istable(data) || throw(ODSError("Give the rows to append as a Tables.jl table, a matrix, or a vector of rows."))
        sch = Tables.schema(data)
        src = sch !== nothing && sch.names !== nothing ? sch.names :
              Tables.columnaccess(data) ? Tables.columnnames(Tables.columns(data)) : nothing
        if src === nothing
            [collect(Tables.getcolumn(r, i) for i in 1:ncols) for r in Tables.rows(data)]
        else
            have = collect(Symbol.(src)); want = Symbol.(t.columns)
            miss = setdiff(want, have)
            isempty(miss) || throw(ODSError("Source is missing column(s) $(join(miss, ", ")) required by table `$(t.name)`. Table columns are: $(join(t.columns, ", "))."))
            extra = setdiff(have, want)
            isempty(extra) || throw(ODSError("Source has column(s) $(join(extra, ", ")) that table `$(t.name)` does not have. Table columns are: $(join(t.columns, ", "))."))
            [collect(Tables.getcolumn(r, nm) for nm in want) for r in Tables.rows(data)]
        end
    end
    for (i, r) in enumerate(rows)
        length(r) == ncols || throw(ODSError("Row $i has $(length(r)) values but table `$(t.name)` has $ncols columns."))
    end
    return rows
end

"""
    appendtable!(t::Table, data; check_empty=true) -> Table
    appendtable!(sheet, name | id, data; check_empty=true) -> Table

Add rows to the end of a table: `data` is a Tables.jl table (its columns matched
by name), a matrix or a vector of rows (matched by position). The table grows over them. A totals
row moves down to stay last: its functions are written again over the new data rows, its labels
kept, and its custom formulas' references to the old data rows made to reach the new ones. The
rows below the table must be empty, unless `check_empty=false`. The file must be writable.
"""
appendtable!(t::Table, data; kw...) = _appendtable!(_resolve(t), data; kw...)
appendtable!(ws::Worksheet, name::Union{AbstractString,Integer}, data; kw...) = _appendtable!(table(ws, name), data; kw...)
function _appendtable!(t::Table, data; check_empty::Bool = true)
    ws = t.sheet
    xf = get_odsfile(ws)
    _require_writable(xf, "append to a table")
    rows = _append_rows(data, t)
    n = length(rows)
    n == 0 && return t
    c0 = _col0(t); c9 = column_number(t.ref.stop)
    old = row_number(t.ref.stop)
    stop = old + n
    stop > SheetCore.MAX_ROWS && throw(ODSError("Appending $n rows to table `$(t.name)` would go past the sheet's last row."))
    if check_empty
        for r in old+1:stop, c in c0:c9
            v = getdata(ws, r, c)
            (v === missing || v == "") || throw(ODSError("Cannot append to table `$(t.name)`: cell $(_db_cell(r, c)) is not empty. Clear the rows below the table, or pass `check_empty=false` to overwrite."))
        end
    end
    # the totals row's settings and custom formulas, before it is written over
    totals = t.has_totals_row ? [(c, _totals_setting(t, c), getFormula(ws, old, c; raw = true), getdata(ws, old, c)) for c in c0:c9] : nothing
    a, b = _first_data_row(t), _last_data_row(t)
    first_new = t.has_totals_row ? old : old + 1
    for (i, row) in enumerate(rows), (j, v) in enumerate(row)
        _set_cell!(ws, first_new + i - 1, c0 + j - 1, v)
    end
    m = _db_model!(xf, _db_of(t))
    m.r2 = stop
    t = _resolve(t)
    if totals !== nothing
        for c in c0:c9
            _set_cell!(ws, stop, c, missing)
        end
        nb = _last_data_row(t)
        for (c, setting, raw, v) in totals
            if setting === :none
            elseif setting === :label
                _set_cell!(ws, stop, c, v)
            elseif setting === :custom && raw !== nothing
                f = raw
                for x in c0:c9                           # the old data rows of each column, to the new
                    l = _col_letters(x)
                    f = replace(f, Regex("(\\\$?$l\\\$?$a:\\.?\\\$?$l\\\$?)$b(?![0-9])") => SubstitutionString("\\g<1>$nb"))
                end
                setFormula(ws, CellRef(stop, c); val = f, raw = true)
            elseif setting === :custom
                _set_cell!(ws, stop, c, v)
            else
                _set_totals_cell!(t, c, setting)
            end
        end
    end
    return _resolve(t)
end

function _table_data_rows(t::Table)
    a, b = _first_data_row(t), _last_data_row(t)
    b >= a || throw(ODSError("Table `$(t.name)` has no data rows."))
    return a, b
end

function _table_column(t::Table, column)
    if column isa Integer
        1 <= column <= length(t.columns) || throw(ODSError("Table `$(t.name)` has $(length(t.columns)) columns; asked for column $column."))
        return Int(column)
    end
    i = findfirst(==(String(column)), t.columns)
    i === nothing && throw(ODSError("Table `$(t.name)` has no column `$column`. Its columns are: $(join(t.columns, ", "))."))
    return i
end

"""
    gettablerange(t::Table) -> SheetCellRange
    gettablerange(t::Table, column; header=false) -> SheetCellRange or SheetCellRef
    gettablerange(t::Table, first, last) -> SheetCellRange

A table's data rows (without its header and totals rows) as a sheet-qualified range: all its
columns, one (by name or number; with `header=true`, that column's header cell), or the columns
from `first` to `last`. The table is looked up again, so `t` may be from before it changed.
"""
function gettablerange(t::Table)
    t = _resolve(t)
    a, b = _table_data_rows(t)
    return SheetCellRange(t.sheet.name, CellRange(a, _col0(t), b, column_number(t.ref.stop)))
end
function gettablerange(t::Table, column; header::Bool = false)
    t = _resolve(t)
    c = _col0(t) + _table_column(t, column) - 1
    if header
        t.has_header_row || throw(ODSError("Table `$(t.name)` has no header row, so column `$column` has no header cell."))
        return SheetCellRef(t.sheet.name, CellRef(row_number(t.ref.start), c))
    end
    a, b = _table_data_rows(t)
    return SheetCellRange(t.sheet.name, CellRange(a, c, b, c))
end
function gettablerange(t::Table, first, last)
    t = _resolve(t)
    x, y = minmax(_table_column(t, first), _table_column(t, last))
    a, b = _table_data_rows(t)
    return SheetCellRange(t.sheet.name, CellRange(a, _col0(t) + x - 1, b, _col0(t) + y - 1))
end

"""
    gettable(t::Table; infer_eltypes=true, normalizenames=false, missing_strings=nothing) -> DataTable

A table's data rows (without its header and totals rows) as a `DataTable`, labelled by its
columns: its range is the table's, so empty rows inside it are
data. `normalizenames`, `missing_strings` and `infer_eltypes` are as for
[`gettable(sheet)`](@ref gettable).
"""
function gettable(t::Table; infer_eltypes::Bool = true, normalizenames::Bool = false,
                  missing_strings::Union{AbstractString,AbstractVector{<:AbstractString},Nothing} = nothing)
    t = _resolve(t)
    miss = missing_strings === nothing ? nothing : missing_strings isa AbstractString ? Set([missing_strings]) : Set(missing_strings)
    a, b = _first_data_row(t), _last_data_row(t)
    nc = length(t.columns)
    data = Vector{Any}(undef, nc)
    m = b >= a ? getdata(t.sheet, CellRange(a, _col0(t), b, column_number(t.ref.stop))) : Matrix{Any}(undef, 0, nc)
    for i in 1:nc
        col = Any[(miss !== nothing && x isa AbstractString && x in miss) ? missing : x for x in m[:, i]]
        data[i] = infer_eltypes ? SheetCore.typed_column(col) : col
    end
    labels = normalizenames ? SheetCore.normalizename.(t.columns) : Symbol.(t.columns)
    return DataTable(data, labels)
end

Tables.istable(::Type{Table}) = true
Tables.columnaccess(::Type{Table}) = true
Tables.columns(t::Table) = gettable(t)

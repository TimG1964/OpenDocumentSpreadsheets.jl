# Tabular data shared by the readers and writers: the `DataTable` result type and its
# Tables.jl interface, the cell value types, column type inference and typed column
# builders, column-label normalisation, and the handling of Tables.jl input to
# `writetable` (sheet specs, conversion to columns, shape checks).
#
# Adapted from XLSX.jl 0.13.4 (src/types.jl, src/table.jl, src/tables_interface.jl and
# src/writetable.jl; line ranges in records/provenance.md),
# MIT License, Copyright (c) 2018-2026 Felipe Noronha Tavares and other contributors.
# Changes from XLSX.jl:
#   - XLSXError → SheetCoreError; EXCEL_MAX_ROWS/EXCEL_MAX_COLS → MAX_ROWS/MAX_COLS
#   - the messages that named Excel or XLSX-only functions are made format-neutral
#   - `push_unique!` keeps only its string method (the other one reads XLSX cells)
#   - `CellConcreteType` gains `Dates.CompoundPeriod` (D-017: ODF durations of 24 hours or
#     more); its docstring was XLSX-specific and is replaced

"""
    CellConcreteType

The Julia types a cell value can have: `String`, `Missing`, `Float64`, `Int64`, `Bool`,
`Dates.Date`, `Dates.Time`, `Dates.DateTime` and `Dates.CompoundPeriod` (a duration of 24
hours or more, or a negative one, which ODF time cells can hold). `Int64` rather
than `Int`, so that the set does not depend on the host word size.
"""
const CellConcreteType = Union{String, Missing, Float64, Int64, Bool, Dates.Date, Dates.Time, Dates.DateTime, Dates.CompoundPeriod}

"""
`DataTable` is a simple `Tables.jl` compatible data structure that holds tabular data
read from a spreadsheet: a vector of columns and their labels.

Pass a `DataTable` to any `Tables.jl` compatible sink, e.g. `DataFrame(dt)`.
"""
struct DataTable
    data::Vector{Any} # columns
    column_labels::Vector{Symbol}
    column_label_index::Dict{Symbol, Int} # column_label -> column_index

    function DataTable(
            data::Vector{Any}, # columns
            column_labels::Vector{Symbol},
        )

        if length(data) != length(column_labels)
            throw(SheetCoreError("Data has $(length(data)) columns but $(length(column_labels)) column labels."))
        end

        column_label_index = Dict{Symbol, Int}()
        for (i, sym) in enumerate(column_labels)
            if haskey(column_label_index, sym)
                throw(SheetCoreError("DataTable has repeated label for column `$sym`"))
            end
            column_label_index[sym] = i
        end

        return new(data, column_labels, column_label_index)
    end
end

Tables.istable(::Type{DataTable}) = true
Tables.columnaccess(::Type{DataTable}) = true
Tables.columns(dt::DataTable) = dt # DataTable implements Tables.AbstractColumns interface
Tables.schema(dt::DataTable) = Tables.Schema(dt.column_labels, Type[eltype(c) for c in dt.data])
Tables.columnnames(dt::DataTable) = dt.column_labels
Tables.getcolumn(dt::DataTable, i::Int) = dt.data[i]

function Tables.getcolumn(dt::DataTable, column_label::Symbol)
    if !haskey(dt.column_label_index, column_label)
        throw(SheetCoreError("Column `$column_label` not found."))
    end

    column_index = dt.column_label_index[column_label]
    return Tables.getcolumn(dt, column_index)
end

# helper function to manage problematic column labels
# Empty cell -> "#Empty"
function push_unique!(vect::Vector{String}, base::String)
    name = base
    i = 1
    while name in vect
        i += 1
        name = base * "_" * string(i)
    end
    push!(vect, name)
    return nothing
end


# Issue 260
const RESERVED = Set(["local", "global", "export", "let",
    "for", "struct", "while", "const", "continue", "import",
    "function", "if", "else", "try", "begin", "break", "catch",
    "return", "using", "baremodule", "macro", "finally",
    "module", "elseif", "end", "quote", "do"])
# Base's `is_id_start_char`/`is_id_char` are not public; these give the same answers through
# the public `Base.isidentifier` (checked for every valid character up to U+2FFFF).
_is_id_start_char(c::AbstractChar) = Base.isidentifier(string(c))
_is_id_char(c::AbstractChar) = Base.isidentifier(string('x', c))

normalizename(name::Symbol) = name
normalizename(name::AbstractString) = normalizename(String(name))   # e.g. a SubString label (#498)
function normalizename(name::String)::Symbol
    uname = strip(Unicode.normalize(name))
    id = Base.isidentifier(uname) ? uname : map(c->_is_id_char(c) ? c : '_', uname)
    cleansed = string((isempty(id) || !_is_id_start_char(id[1]) || id in RESERVED) ? "_" : "", id)
    return Symbol(replace(cleansed, r"(_)\1+"=>"_"))
end

infer_eltype(v::Vector{Any}) = _infer_values_eltype(v)

# The element type `infer_eltype` gives a `Vector{Any}` of `v`'s values, for a vector of
# any element type: `gettable` builds typed columns, and must infer exactly as before.
function _infer_values_eltype(v::AbstractVector)
    isempty(v) && return Any
    hasmissing = false
    t = Any
    for x in v
        if ismissing(x)
            hasmissing = true
        elseif t === Any
            t = typeof(x)
        elseif typeof(x) != t
            t = promote_type(t, typeof(x))
            t === Any && return Any
        end
    end
    return hasmissing ? Union{Missing, t} : t
end

infer_eltype(v::Vector{T}) where T = T


# Address issue 225
function typed_column(v::Vector{Any})
    T = infer_eltype(v)
    result = Vector{T}(undef, length(v))
    for (i, x) in enumerate(v)
        result[i] = x
    end
    return result
end

function check_table_data_dimension(data::Vector)
    isempty(data) && return
    for (i, col) in enumerate(data)
        isa(col, Vector) || throw(SheetCoreError("Data type at index $i is not a vector. Found: $(typeof(col))."))
    end
    length(data) == 1 && return
    row_count = length(data[1])
    for (i, col) in enumerate(@view data[2:end])
        length(col) == row_count || throw(SheetCoreError("Not all columns have the same number of rows. Check column $(i+1)."))
    end
end

# Typed column builders for `gettable`. A column starts with no element type and widens,
# by copying, to the Union of the types of the values pushed so far, up to
# `_MAX_COLUMN_TYPES` of them, then to `Any`. Values are kept as read, not converted, so
# that a column ending up as `Any` holds them unchanged, as a `Vector{Any}` built from the
# start would; `_finish_column` then infers and converts exactly as `infer_eltype` does.
# This keeps numbers unboxed and saves the copy inference used to make of every column.
const _MAX_COLUMN_TYPES = 4

_new_column(infer_eltypes::Bool) = infer_eltypes ? Vector{Union{}}() : Any[]

# Push `x` to `col`, returning the column it went into: `col`, or a wider copy of it.
@inline function _push_column!(col::Vector{T}, x::S) where {T,S}
    S <: T || return _widen_column!(col, x)
    push!(col, x)
    return col
end

function _widen_column!(col::Vector{T}, x::S) where {T,S}
    W = S <: CellConcreteType && _column_type_count(T) < _MAX_COLUMN_TYPES ? Union{T,S} : Any
    wide = Vector{W}(undef, length(col))
    copyto!(wide, col)
    push!(wide, x)
    return wide
end

# The number of cell value types a column's element type has collected (only cell value
# types are collected: any other widens to `Any`).
const _CELL_CONCRETE_TYPES = (String, Missing, Float64, Int64, Bool, Dates.Date, Dates.Time, Dates.DateTime, Dates.CompoundPeriod)
_column_type_count(T::Type) = count(t -> t <: T, _CELL_CONCRETE_TYPES)

# The column `infer_eltypes=true` returns: its values with `infer_eltype`'s element type.
function _finish_column(col::Vector{T}) where {T}
    E = _infer_values_eltype(col)
    return E === T ? col : convert(Vector{E}, col)
end

_as_vector(y::AbstractVector) = y
_as_vector(y) = collect(y)

_sheetname_string(name::AbstractString) = String(name)
_sheetname_string(name::Symbol) = String(name)
_sheetname_string(name) = throw(SheetCoreError(
    "Sheet name must be an `AbstractString` or `Symbol`, got `$(typeof(name))`. " *
    "Write sheets as `\"Sheet1\" => table` or `:Sheet1 => table`."))

# Returns `nothing` if `t` is a usable `(sheetname, data, columnnames)` spec,
# otherwise a phrase describing why it isn't. Shared by `_is_sheet_spec_vector`
# and `_shape_hint` so the guard and the diagnostic can never disagree.
function _sheet_spec_problem(t)
    t isa Tuple || return "is a `$(typeof(t))`, not a tuple"
    length(t) == 3 || return "is a $(length(t))-tuple, not a 3-tuple"
    (t[1] isa AbstractString || t[1] isa Symbol) ||
        return "has a sheet name of type `$(typeof(t[1]))`, which is neither `AbstractString` nor `Symbol`"
    return nothing
end

_is_sheet_spec_vector(x) =
    x isa AbstractVector && !isempty(x) && all(t -> isnothing(_sheet_spec_problem(t)), x)

# The element type must be pinned: the result is re-dispatched through
# `writetable`, and an inferred `Vector{Any}` would land back in the fallback
# method and loop.
_normalize_sheet_specs(x) = Tuple{String,Vector{Any},Vector{String}}[
    (_sheetname_string(name), Any[c for c in data], [string(l) for l in labels])
    for (name, data, labels) in x
]

function _shape_hint(x)
    if x isa AbstractVector && !isempty(x) && any(t -> t isa Tuple, x)
        i = findfirst(t -> !isnothing(_sheet_spec_problem(t)), x)
        isnothing(i) && return ""
        return "\nThis looks like a vector of `(sheetname, data, columnnames)` tuples, " *
               "but element $i " * _sheet_spec_problem(x[i]) * "."
    elseif x isa Pair
        return "\n`writetable` accepts `name => table` pairs where `name` is an " *
               "`AbstractString` or `Symbol` (got `$(typeof(x.first))`). Writing into a " *
               "sheet that already exists takes the table alone."
    end
    return ""
end

function _table_to_arrays(x)
    if Tables.istable(x)
        columns = Any[_as_vector(c) for c in Tables.Columns(x)]
        colnames = collect(Symbol, Tables.columnnames(x))
        return columns, colnames
    else
        throw(SheetCoreError("$(typeof(x)) does not implement Tables.jl interface." * _shape_hint(x)))
    end
end

# The number of rows in `data`, a vector of columns named by `columnnames`, checked
# to fit in a sheet.
function _check_table_shape(data, columnnames)::Int
    col_count = length(data)
    col_count != length(columnnames) && throw(SheetCoreError("Column count mismatch between `data` ($col_count columns) and `columnnames` ($(length(columnnames)) columns)."))
    col_count <= 0 && throw(SheetCoreError("Can't write table with no columns."))
    col_count > MAX_COLS && throw(SheetCoreError("`data` contains $col_count columns, but a sheet holds at most $MAX_COLS; must reduce `data` size"))
    row_count = length(data[1])
    row_count > MAX_ROWS - 1 && throw(SheetCoreError("`data` contains $row_count rows, but a sheet holds at most $(MAX_ROWS-1) below its header row; must reduce `data` size"))
    if col_count > 1
        for c in 2:col_count
            length(data[c]) != row_count && throw(SheetCoreError("Row count mismatch between column 1 ($row_count rows) and column $c ($(length(data[c])) rows)."))
        end
    end
    return row_count
end

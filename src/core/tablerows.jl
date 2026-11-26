# Reading a table from a sheet's rows: `eachtablerow`, `TableRowIterator`, `TableRow`,
# `gettable`, and their Tables.jl interface. Format-independent (D-020): it reads rows only
# through the row protocol below, which each back end implements for its own row types.
#
# Adapted from XLSX.jl 0.13.4 (src/table.jl `_eachtablerow`, `_detect_column_range`,
# `_find_first_row_with_data`, `TableRow`, `_table_start`, `_table_step`, `_handle_gap`,
# `_skip_empty_rows`, `iterate`, `_gettable_rows!`, `gettable`, `Tables.columns`;
# src/types.jl `Index`, `TableRowIterator`, `TableRow`, `TableRowIteratorState`;
# src/tables_interface.jl the TableRowIterator / TableRow methods), MIT License,
# Copyright (c) 2018-2026 Felipe Noronha Tavares and other contributors.
# Changes from XLSX.jl:
#   - generic over the row source: an iterable of rows implementing the row protocol,
#     instead of an XLSX `Worksheet` with its cache, stream or value rows
#   - `resume` (XLSX's pre-fetched first row) is dropped; the header row is found by
#     iterating the source again
#   - `TableRow.cell_values` is `Vector{Any}` (values are `CellConcreteType`)
#   - XLSXError → SheetCoreError; the sheet name for messages is passed in

#
# The row protocol. A row source is anything iterable (and re-iterable from the start)
# whose rows implement:
#   row_number(r)::Int                  the sheet row number
#   table_row_value(r, col::Int)        the value at sheet column `col` (missing if none)
#   table_row_isempty(r)::Bool          whether the row has no cells at all
#   table_row_columns(r)                the columns holding a cell, in order
# and, optionally, for speed:
#   table_push_value!(col::Vector, r, column::Int, ms::Set{String}) -> Vector
#     push the value to a typed column (see `_push_column!`), returning the column
#   table_rows_batchable(::Type{R}) -> Bool
#     true when a row stays valid after the source has given the next one; `gettable`
#     then fills the columns a batch of rows at a time (D-047). Default false.
#

function table_row_value end
function table_row_isempty end
function table_row_columns end
table_rows_batchable(::Type) = false

@inline function _apply_missing_strings(val, ms::Set{String})
    isempty(ms) && return val
    val isa AbstractString && val in ms && return missing
    return val
end

table_push_value!(col::Vector, r, column::Int, ms::Set{String}) =
    _push_column!(col, _apply_missing_strings(table_row_value(r, column), ms))

"""
    Index

The columns of a table: the label → table column lookup, the labels, and the table column
→ sheet column map.
"""
struct Index # for TableRowIterator - based on DataFrames.jl
    lookup::Dict{Symbol,Int}
    column_labels::Vector{Symbol}
    column_map::Vector{Int}     # table column index → sheet column number

    function Index(column_range::Union{ColumnRange,AbstractString}, column_labels)
        syms = [Symbol(i) for i in column_labels]
        column_range = column_range isa ColumnRange ? column_range : ColumnRange(column_range)
        length(unique(syms)) == length(syms) || throw(SheetCoreError("Column labels must be unique."))
        lookup = Dict{Symbol,Int}(n => i for (i, n) in enumerate(syms))
        return new(lookup, syms, collect(column_range.start:column_range.stop))
    end
end

"""
    TableRowIterator

An iterator of [`TableRow`](@ref)s over a row source, as [`eachtablerow`](@ref) builds it.
"""
struct TableRowIterator{I}
    itr::I
    index::Index
    first_data_row::Int
    stop_in_empty_row::Bool
    stop_in_row_function::Union{Nothing,Function}
    keep_empty_rows::Bool
    missing_strings::Set{String}
end

"""
    TableRow

A row of a table: `row` (its index in the table, not the sheet row), the table's `Index`,
and its values. Index it with a column number or label: `r[1]`, `r[:name]`.
"""
struct TableRow
    row::Int
    index::Index
    cell_values::Vector{Any}
end

struct TableRowIteratorState{S,R}
    table_row_index::Int
    sheet_row_index::Int
    sheet_row_iterator_state::S
    missing_rows::Int               # all-empty rows still to give before `row_pending`
    row_pending::Union{Nothing,R}
    TableRowIteratorState{S,R}(t::Int, s::Int, st, m::Int, p) where {S,R} = new{S,R}(t, s, st, m, p)
end

# the type of the rows a source gives (for a typed state)
_source_row_type(itr) = eltype(itr)

_table_state(itr::TableRowIterator{I}, t::Int, s::Int, st::S, m::Int, pending) where {I,S} =
    TableRowIteratorState{S,_source_row_type(itr.itr)}(t, s, st, m, pending)

@inline sheet_column_numbers(i::Index) = i.column_map
@inline table_column_numbers(i::Index) = eachindex(i.column_labels)
@inline table_column_numbers(r::TableRow) = table_column_numbers(r.index)
@inline table_column_to_sheet_column_number(index::Index, n::Int) = index.column_map[n]
@inline table_columns_count(i::Index) = length(i.column_labels)
@inline table_columns_count(itr::TableRowIterator) = table_columns_count(itr.index)
@inline table_columns_count(r::TableRow) = table_columns_count(r.index)
@inline row_number(r::TableRow) = r.row
@inline get_column_labels(index::Index) = index.column_labels
@inline get_column_labels(itr::TableRowIterator) = get_column_labels(itr.index)
@inline get_column_labels(r::TableRow) = get_column_labels(r.index)
@inline get_column_label(r::TableRow, n::Int) = get_column_labels(r)[n]

#
# Building the iterator
#

_missing_string_set(ms::Nothing) = Set{String}()
_missing_string_set(ms::AbstractString) = Set{String}([String(ms)])
_missing_string_set(ms::AbstractVector{<:AbstractString}) = Set{String}(String.(ms))

"""
    eachtablerow(rows, [columns]; sheetname="", first_row, column_labels, header=true,
                 stop_in_empty_row=true, stop_in_row_function, keep_empty_rows=false,
                 normalizenames=false, missing_strings) -> TableRowIterator

The table in a row source `rows` (see the row protocol in this file). The back ends wrap it
for their worksheets. `columns` is a `ColumnRange` or a string such as `"B:E"`; without it,
the table's columns are the first run of consecutive non-empty cells in its first row.
`sheetname` is used in messages.
"""
function eachtablerow(rows, cols::Union{ColumnRange,AbstractString};
        sheetname::AbstractString = "",
        first_row::Union{Nothing,Int} = nothing,
        column_labels = nothing,
        header::Bool = true,
        stop_in_empty_row::Bool = true,
        stop_in_row_function::Union{Nothing,Function} = nothing,
        keep_empty_rows::Bool = false,
        normalizenames::Bool = false,
        missing_strings::Union{AbstractString,AbstractVector{<:AbstractString},Nothing} = nothing)

    ms = _missing_string_set(missing_strings)
    column_range = cols isa ColumnRange ? cols : ColumnRange(cols)
    if column_labels !== nothing && length(column_labels) != length(column_range)
        throw(SheetCoreError("`column_range` (length=$(length(column_range))) and `column_labels` (length=$(length(column_labels))) must have the same length."))
    end
    first_row === nothing && (first_row = _find_first_row_with_data(rows, column_range.start, sheetname))

    col_lab = String[]
    if column_labels === nothing
        if header
            hr = _find_row(rows, first_row)
            hr === nothing && throw(SheetCoreError("Row $first_row not found in sheet $sheetname."))
            for c in column_range.start:column_range.stop
                v = table_row_value(hr, c)
                push_unique!(col_lab, ismissing(v) ? "#Empty" : v isa AbstractString ? String(v) : string(v))
            end
        else
            for c in column_range
                push!(col_lab, string(c))
            end
        end
    end
    labels = normalizenames ? normalizename.(column_labels === nothing ? col_lab : column_labels) :
                              Symbol.(column_labels === nothing ? col_lab : column_labels)
    first_data_row = header ? first_row + 1 : first_row
    index = Index(column_range, labels)
    return TableRowIterator(rows, index, first_data_row, stop_in_empty_row, stop_in_row_function, keep_empty_rows, ms)
end

function eachtablerow(rows; sheetname::AbstractString = "", first_row::Union{Nothing,Int} = nothing,
                      keep_empty_rows::Bool = false, kw...)
    first_row = something(first_row, 1)
    for r in rows
        row_number(r) < first_row && continue
        table_row_isempty(r) && continue
        cols = collect(Int, table_row_columns(r))
        ci = findfirst(cn -> !ismissing(table_row_value(r, cn)), cols)
        ci === nothing && continue
        column_range = _detect_column_range(r, cols, ci)
        return eachtablerow(rows, column_range; sheetname, first_row = row_number(r), keep_empty_rows, kw...)
    end
    throw(SheetCoreError("Couldn't find a table in sheet $sheetname"))
end

# The contiguous columns from `cols[ci]` whose cells are not empty.
function _detect_column_range(r, cols::Vector{Int}, ci::Int)::ColumnRange
    start = cols[ci]
    stop = start
    for k in (ci + 1):length(cols)
        cn = cols[k]
        (ismissing(table_row_value(r, cn)) || cn - 1 != stop) && break
        stop = cn
    end
    return ColumnRange(start, stop)
end

function _find_first_row_with_data(rows, column::Int, sheetname::AbstractString)
    for r in rows
        ismissing(table_row_value(r, column)) || return row_number(r)
    end
    throw(SheetCoreError("Column $(encode_column_number(column)) has no data."))
end

function _find_row(rows, n::Int)
    for r in rows
        row_number(r) == n && return r
        row_number(r) > n && return nothing
    end
    return nothing
end

#
# Rows
#

function TableRow(table_row::Int, index::Index, sheet_row, ms::Set{String})
    vals = Any[_apply_missing_strings(table_row_value(sheet_row, c), ms) for c in index.column_map]
    return TableRow(table_row, index, vals)
end

getdata(r::TableRow, n::Int) = r.cell_values[n]
getdata(r::TableRow, ns::Union{AbstractVector{<:Integer},UnitRange{<:Integer}}) = Any[r.cell_values[x] for x in ns]
function getdata(r::TableRow, label::Symbol)
    i = get(r.index.lookup, label, 0)
    i == 0 && throw(SheetCoreError("Invalid column label: $label."))
    return r.cell_values[i]
end
Base.getindex(r::TableRow, x) = getdata(r, x)
Base.length(r::TableRow) = table_columns_count(r)
Base.eltype(::Type{TableRow}) = Any
function Base.iterate(r::TableRow, st = 1)
    st > length(r.cell_values) && return nothing
    return r.cell_values[st], st + 1
end

function is_empty_table_row(itr::TableRowIterator, r)::Bool
    table_row_isempty(r) && return true
    return all(c -> ismissing(table_row_value(r, c)), sheet_column_numbers(itr.index))
end

Base.IteratorSize(::Type{<:TableRowIterator}) = Base.SizeUnknown()
Base.eltype(::TableRowIterator) = TableRow

@inline _should_stop(itr::TableRowIterator, row::TableRow) =
    itr.stop_in_row_function !== nothing && itr.stop_in_row_function(row)

function _handle_gap(itr::TableRowIterator, table_row_index::Int, expected::Int, actual::Int, sheet_row, st)
    itr.stop_in_empty_row && return nothing
    itr.keep_empty_rows || return :skip
    return nothing, _table_state(itr, table_row_index, expected, st, actual - expected - 1, sheet_row)
end

function _skip_empty_rows(itr::TableRowIterator, sheet_row, st)
    if itr.keep_empty_rows
        is_empty_table_row(itr, sheet_row) && itr.stop_in_empty_row && return nothing
        return sheet_row, st
    end
    while is_empty_table_row(itr, sheet_row)
        itr.stop_in_empty_row && return nothing
        next = iterate(itr.itr, st)
        next === nothing && return nothing
        sheet_row, st = next
    end
    return sheet_row, st
end

function _table_start(itr::TableRowIterator)
    next = iterate(itr.itr)
    while next !== nothing && row_number(next[1]) < itr.first_data_row
        next = iterate(itr.itr, next[2])
    end
    next === nothing && return nothing
    sheet_row, st = next
    return _table_state(itr, 0, itr.first_data_row - 1, st, 0, sheet_row)
end

# One step: (sheet_row, state) for the next table row (`sheet_row === nothing` for an
# all-missing row kept by `keep_empty_rows`), or `nothing` at the end of the table.
function _table_step(itr::TableRowIterator, state::TableRowIteratorState)
    table_row_index = state.table_row_index + 1
    if state.missing_rows > 0
        return nothing, _table_state(itr, table_row_index, state.sheet_row_index + 1,
                                     state.sheet_row_iterator_state, state.missing_rows - 1, state.row_pending)
    end
    local sheet_row, st
    if state.row_pending !== nothing
        sheet_row = state.row_pending
        st = state.sheet_row_iterator_state
    else
        next = iterate(itr.itr, state.sheet_row_iterator_state)
        next === nothing && return nothing
        sheet_row, st = next
    end
    actual = row_number(sheet_row)
    expected = state.sheet_row_index + 1
    if actual > expected
        result = _handle_gap(itr, table_row_index, expected, actual, sheet_row, st)
        result === :skip || return result
    end
    result = _skip_empty_rows(itr, sheet_row, st)
    result === nothing && return nothing
    sheet_row, st = result
    return sheet_row, _table_state(itr, table_row_index, row_number(sheet_row), st, 0, nothing)
end

function Base.iterate(itr::TableRowIterator)
    state = _table_start(itr)
    state === nothing && return nothing
    return iterate(itr, state)
end

function Base.iterate(itr::TableRowIterator, state::TableRowIteratorState)
    step = _table_step(itr, state)
    step === nothing && return nothing
    sheet_row, newstate = step
    row = sheet_row === nothing ?
        TableRow(newstate.table_row_index, itr.index, Any[missing for _ in itr.index.column_map]) :
        TableRow(newstate.table_row_index, itr.index, sheet_row, itr.missing_strings)
    _should_stop(itr, row) && return nothing
    return row, newstate
end

#
# gettable
#

function _push_row!(data::Vector{Any}, r, sheet_columns::Vector{Int}, ms::Set{String})
    for ci in eachindex(data)
        data[ci] = table_push_value!(data[ci], r, sheet_columns[ci], ms)
    end
    return nothing
end

# Pushes a batch of rows (`nothing`: an all-missing row) to one column. A function barrier:
# the loop is compiled for the column's element type. When a value widens the column, the
# rest of the batch goes to the wider column.
function _push_rows!(col::Vector, buf::Vector, from::Int, column::Int, ms::Set{String})
    @inbounds for i in from:length(buf)
        r = buf[i]
        new = r === nothing ? _push_column!(col, missing) : table_push_value!(col, r, column, ms)
        new === col || return _push_rows!(new, buf, i + 1, column, ms)
    end
    return col
end

function _push_batch!(data::Vector{Any}, buf::Vector, sheet_columns::Vector{Int}, ms::Set{String})
    for ci in eachindex(data)
        data[ci] = _push_rows!(data[ci], buf, 1, sheet_columns[ci], ms)
    end
    return nothing
end

const _TABLE_BATCH = 256

function _gettable_rows!(data::Vector{Any}, itr::TableRowIterator, state::TableRowIteratorState)
    sheet_columns = itr.index.column_map
    R = _source_row_type(itr.itr)
    if table_rows_batchable(R)
        # a batch of rows at a time, column by column: one dynamic call per column and
        # batch instead of one per cell
        buf = Union{Nothing,R}[]
        sizehint!(buf, _TABLE_BATCH)
        while true
            step = _table_step(itr, state)
            step === nothing && break
            sheet_row, state = step
            push!(buf, sheet_row)
            if length(buf) == _TABLE_BATCH
                _push_batch!(data, buf, sheet_columns, itr.missing_strings)
                empty!(buf)
            end
        end
        isempty(buf) || _push_batch!(data, buf, sheet_columns, itr.missing_strings)
        return nothing
    end
    while true
        step = _table_step(itr, state)
        step === nothing && break
        sheet_row, state = step
        if sheet_row === nothing
            for ci in eachindex(data)
                data[ci] = _push_column!(data[ci], missing)
            end
        else
            _push_row!(data, sheet_row, sheet_columns, itr.missing_strings)
        end
    end
    return nothing
end

"""
    gettable(itr::TableRowIterator; infer_eltypes=true) -> DataTable

Read the table's rows into a [`DataTable`](@ref). With `infer_eltypes`, each column gets the
narrowest element type of its values (plus `Missing`), else `Any`.
"""
function gettable(itr::TableRowIterator; infer_eltypes::Bool = true)::DataTable
    labels = get_column_labels(itr)
    data = Any[_new_column(infer_eltypes) for _ in 1:table_columns_count(itr)]
    if itr.stop_in_row_function === nothing
        state = _table_start(itr)
        state === nothing || _gettable_rows!(data, itr, state)
    else
        for r in itr
            for (ci, v) in enumerate(r)
                data[ci] = _push_column!(data[ci], v)
            end
        end
    end
    if infer_eltypes
        for i in eachindex(data)
            data[i] = _finish_column(data[i])
        end
    end
    check_table_data_dimension(data)
    return DataTable(data, labels)
end

#
# Tables.jl
#

Tables.istable(::Type{<:TableRowIterator}) = true
Tables.rowaccess(::Type{<:TableRowIterator}) = true
Tables.rows(itr::TableRowIterator) = itr
Tables.schema(itr::TableRowIterator) = Tables.Schema(itr.index.column_labels, fill(Any, length(itr.index.column_labels)))
Tables.columnnames(tr::TableRow) = tr.index.column_labels
Tables.getcolumn(tr::TableRow, nm::Symbol) = getdata(tr, nm)
Tables.getcolumn(tr::TableRow, i::Int) = getdata(tr, i)
Tables.getcolumn(tr::TableRow, i::Integer) = getdata(tr, Int(i))

function Tables.columns(tr::TableRowIterator)
    names = Tables.schema(tr).names
    collected = collect(tr)
    isempty(collected) && return NamedTuple{Tuple(names)}(map(_ -> Any[], names))
    cols = Tables.columntable(collected)
    return map(v -> typed_column(Vector{Any}(v)), cols)
end

# Displays that read nothing: an iterator shows its columns, not its source's contents (issue #1's audit).
function Base.show(io::IO, it::TableRowIterator)
    print(io, "TableRowIterator(", length(it.index.column_labels), " columns: ")
    join(io, (repr(l) for l in it.index.column_labels), ", ")
    print(io, "; data from row ", it.first_data_row, ")")
end
function Base.show(io::IO, r::TableRow)
    print(io, "TableRow ", r.row, ": ")
    show(io, NamedTuple{Tuple(r.index.column_labels)}(Tuple(r.cell_values)))
end

Base.show(io::IO, dt::DataTable) = Base.show(io, MIME"text/plain"(), dt)
Base.show(io::IO, ::MIME"text/plain", dt::DataTable) =
    print(io, "DataTable with $(length(dt.data)) columns and $(isempty(dt.data) ? 0 : length(dt.data[1])) rows.")

# Writing tables: `writetable!` into a sheet, `writetable` to a new file.
#
# Signatures follow XLSX.jl 0.13.4 (src/writetable.jl `writetable!`, `writetable` and its
# sheet forms; src/tables_interface.jl the Tables.jl forms), MIT License, Copyright (c)
# 2018-2026 Felipe Noronha Tavares and other contributors. `column_widths` and
# `column_formats` came with formatting (phase 4); the table keywords (`as_table`, `table_name`,
# `table_style`, `totals`) and `freeze_header` with tables (phase 6 step 7, D-077).

# `column_widths` and `column_formats` as `column => setting` pairs, columns counted from the
# first written. Adapted from XLSX.jl 0.13.4 (src/streamwrite.jl `_column_settings`,
# `_column_index`).
function _column_settings(columns, column_widths, column_formats)
    widths = Pair{Int,Float64}[]
    if column_widths isa Real
        columns === nothing && throw(ODSError("A single `column_widths` applies to every column, so it needs `columns`; give a vector of widths instead."))
        append!(widths, c => Float64(column_widths) for c in eachindex(columns))
    elseif column_widths isa AbstractVector
        append!(widths, c => Float64(w) for (c, w) in enumerate(column_widths) if w !== nothing)
    elseif column_widths !== nothing
        throw(ODSError("`column_widths` must be a number or a vector of numbers, got `$(typeof(column_widths))`."))
    end
    formats = Pair{Int,String}[]
    if column_formats isa AbstractDict
        for (k, fmt) in column_formats
            push!(formats, _column_index(columns, k) => String(fmt))
        end
    elseif column_formats !== nothing
        throw(ODSError("`column_formats` must be a `Dict` from columns to number formats, got `$(typeof(column_formats))`."))
    end
    return widths, formats
end

function _column_index(columns, k)::Int
    if k isa Integer
        1 <= k <= SheetCore.MAX_COLS || throw(ODSError("Column $k is outside the sheet's columns 1 to $(SheetCore.MAX_COLS)."))
        return Int(k)
    end
    columns === nothing && throw(ODSError("Column `$k` is named, but there are no column names to find it in."))
    i = findfirst(c -> string(c) == string(k), columns)
    i === nothing && throw(ODSError("There is no column named `$k` among $(join(string.(columns), ", "))."))
    return i
end


const _TABLE_KW_DOC = """
- `as_table=true` makes the written cells a table ([`addtable!`](@ref): LibreOffice's database
  range), named `table_name` (`""`: the first free `TableN`). It needs the header row. LibreOffice
  has no table styles, so `table_style` other than `nothing` or `"None"` is an error.
- `totals` (with `as_table`) gives the table a totals row, as [`settotals!`](@ref) does:
  `["id" => "Total", "score" => :sum]`.
- `freeze_header=true` freezes the rows down to the header ([`freezePanes`](@ref))."""

"""
    writetable!(sheet, data, columnnames; anchor_cell="A1", write_columnnames=true, column_widths,
                column_formats, as_table=false, table_name="", table_style=nothing, totals=nothing,
                freeze_header=false)
    writetable!(sheet, table; kw...)

Write a table into `sheet`, with its column names as a header row (unless
`write_columnnames=false`) and its top-left cell at `anchor_cell`. `data` is a vector of
columns and `columnnames` their names; or `table` is any Tables.jl table.

- `column_widths`: one width for every column, or a vector of widths by column (`nothing`
  leaves a column's width as it is), in characters as [`setColumnWidth`](@ref) takes them.
- `column_formats`: a `Dict` from column (number from the first written, or name) to a
  number format, as [`setFormat`](@ref) takes it, applied to the column's data cells.
$_TABLE_KW_DOC
"""
function writetable!(ws::Worksheet, data, columnnames; anchor_cell::Union{AbstractString,CellRef} = CellRef("A1"),
                     write_columnnames::Bool = true, column_widths = nothing, column_formats = nothing,
                     as_table::Bool = false, table_name::AbstractString = "", table_style = nothing,
                     totals::Union{Nothing,AbstractVector{<:Pair}} = nothing, freeze_header::Bool = false)
    _require_writable(ws, "write a table")
    freeze_header && !write_columnnames &&
        throw(ODSError("`freeze_header=true` requires `write_columnnames=true`: there is no header row to freeze otherwise."))
    as_table && !write_columnnames &&
        throw(ODSError("`as_table=true` requires `write_columnnames=true`: a table needs a header row, and `writetable!` is what writes it."))
    totals !== nothing && !as_table &&
        throw(ODSError("`totals` requires `as_table=true`: there's no table to set a totals row on otherwise."))
    anchor = anchor_cell isa CellRef ? anchor_cell : CellRef(String(anchor_cell))
    nrows = SheetCore._check_table_shape(data, columnnames)
    widths, formats = _column_settings([string(c) for c in columnnames], column_widths, column_formats)
    r0, c0 = row_number(anchor), column_number(anchor)
    last_row = r0 + nrows - (write_columnnames ? 0 : 1)
    last_col = c0 + length(data) - 1
    (last_row <= SheetCore.MAX_ROWS && last_col <= SheetCore.MAX_COLS) ||
        throw(ODSError("The table doesn't fit in the sheet from $(anchor): it would end at row $last_row, column $last_col."))
    if as_table                                       # checked first: a refused table leaves the sheet as it was
        _check_table_style(table_style)
        table_name = _new_table_name(get_odsfile(ws), table_name)
    end
    if write_columnnames
        for (j, name) in enumerate(columnnames)
            _set_cell!(ws, r0, c0 + j - 1, string(name))
        end
        r0 += 1
    end
    for (j, col) in enumerate(data)
        _write_column!(ws, col, r0, c0 + j - 1)
    end
    for (j, w) in widths
        setColumnWidth(ws, :, c0 + j - 1; width = w)
    end
    if nrows > 0
        for (j, fmt) in formats
            setFormat(ws, r0:r0+nrows-1, c0 + j - 1; format = fmt)
        end
    end
    if as_table
        t = addtable!(ws, CellRange(row_number(anchor), c0, last_row, last_col); name = table_name)
        totals === nothing || settotals!(t, totals...)
    end
    freeze_header && freezePanes(ws; nrows = row_number(anchor))
    return nothing
end

# A function barrier: the column's element type is known inside.
function _write_column!(ws::Worksheet, col, r0::Int, c::Int)
    for (i, v) in enumerate(col)
        _set_cell!(ws, r0 + i - 1, c, v)
    end
end
writetable!(ws::Worksheet, table; kw...) = writetable!(ws, SheetCore._table_to_arrays(table)...; kw...)

"""
    writetable(filename, data, columnnames; overwrite=false, sheetname="", anchor_cell="A1", streaming=false, kw...)
    writetable(filename, table; overwrite=false, sheetname="", anchor_cell="A1", streaming=false, kw...)
    writetable(filename, "Sheet1" => table1, "Sheet2" => table2, ...; overwrite=false, streaming=false, kw...)
    writetable(filename, [(sheetname, data, columnnames), ...]; overwrite=false, streaming=false, kw...)
    writetable(filename; overwrite=false, streaming=false, Sheet1=(data, columnnames), ...)

Write tables to a new file (a path or an `IO`), one per sheet, each with a header row.
The format follows the file's extension (`.ods`, `.ots`, `.fods`). An existing file is only
replaced with `overwrite=true`. With `streaming=true`, rows are written as they are produced,
in bounded memory ([`streamods`](@ref)); `anchor_cell`, `totals` and `freeze_header` are then
not available. `display_text=false` leaves out the display text of number, date, time and
boolean cells (smaller files, faster writes; see [`writeods`](@ref)). `column_widths` and
`column_formats` lay out every sheet's columns, as in [`writetable!`](@ref).

`as_table=true` makes each written range a table, as [`writetable!`](@ref) does (also streamed).
A single table is named `table_name`, with its `totals`; with several sheets, each table is
named after its sheet (made a valid name, with a warning, or the first free `TableN`).

```julia
sales = (Region = ["North", "South"], Total = [120, 95])
writetable("sales.ods", sales; sheetname = "Sales", overwrite = true)

writetable("report.ods", "Sales" => sales, "Costs" => (Item = ["Rent"], Amount = [800]);
           overwrite = true)                       # one sheet per table
```
"""
function writetable(filename::Union{AbstractString,IO}, data, columnnames; overwrite::Bool = false,
                    sheetname::AbstractString = "", anchor_cell::Union{AbstractString,CellRef} = CellRef("A1"),
                    streaming::Bool = false, display_text::Bool = true, column_widths = nothing, column_formats = nothing,
                    as_table::Bool = false, table_name::AbstractString = "", table_style = nothing,
                    totals::Union{Nothing,AbstractVector{<:Pair}} = nothing, freeze_header::Bool = false)
    return _write_sheets(filename, [(String(sheetname), data, columnnames)]; overwrite, streaming, anchor_cell, display_text,
                         column_widths, column_formats, as_table, table_name, table_style, totals, freeze_header)
end

function writetable(filename::Union{AbstractString,IO}, x; overwrite::Bool = false, sheetname::AbstractString = "",
                    anchor_cell::Union{AbstractString,CellRef} = CellRef("A1"), streaming::Bool = false,
                    display_text::Bool = true, column_widths = nothing, column_formats = nothing,
                    as_table::Bool = false, table_name::AbstractString = "", table_style = nothing,
                    totals::Union{Nothing,AbstractVector{<:Pair}} = nothing, freeze_header::Bool = false)
    if SheetCore._is_sheet_spec_vector(x)
        return _write_sheets(filename, SheetCore._normalize_sheet_specs(x); overwrite, streaming, display_text, column_widths,
                             column_formats, as_table, table_style, freeze_header, names_from_sheets = true)
    end
    data, names = SheetCore._table_to_arrays(x)
    return _write_sheets(filename, [(String(sheetname), data, names)]; overwrite, streaming, anchor_cell, display_text,
                         column_widths, column_formats, as_table, table_name, table_style, totals, freeze_header)
end

function writetable(filename::Union{AbstractString,IO}, tables::Pair...; overwrite::Bool = false, streaming::Bool = false,
                    display_text::Bool = true, column_widths = nothing, column_formats = nothing,
                    as_table::Bool = false, table_style = nothing, freeze_header::Bool = false)
    specs = Tuple{String,Vector{Any},Vector{Any}}[]
    for p in tables
        data, names = SheetCore._table_to_arrays(p.second)
        push!(specs, (SheetCore._sheetname_string(p.first), Any[c for c in data], Any[n for n in names]))
    end
    return _write_sheets(filename, specs; overwrite, streaming, display_text, column_widths, column_formats, as_table,
                         table_style, freeze_header, names_from_sheets = true)
end
writetable(filename::Union{AbstractString,IO}, tables::AbstractVector{<:Pair}; kw...) = writetable(filename, tables...; kw...)

function writetable(filename::Union{AbstractString,IO}; overwrite::Bool = false, streaming::Bool = false,
                    display_text::Bool = true, as_table::Bool = false, table_style = nothing, kw...)
    isempty(kw) && throw(ODSError("No tables to write: give them as `sheetname = (data, columnnames)`."))
    specs = Tuple{String,Any,Any}[]
    for (name, spec) in kw
        (spec isa Tuple && length(spec) == 2) || throw(ODSError(
            "Keyword `$name` must be a `(data, columnnames)` tuple, got `$(typeof(spec))`. To write a Tables.jl table, use `writetable(filename, :$name => table)`."))
        push!(specs, (String(name), spec[1], spec[2]))
    end
    return _write_sheets(filename, specs; overwrite, streaming, display_text, as_table, table_style, names_from_sheets = true)
end

# A table's name from its sheet's (XLSX.jl's `_table_name_from_sheet`): made a valid name, with a
# warning, or "" (the first free `TableN`) if that is not one or is in use.
function _table_name_from_sheet(used, sheetname::AbstractString)
    candidate = string(SheetCore.normalizename(sheetname))
    candidate == sheetname || @warn "Sheet name `$sheetname` isn't a valid table name; using normalized name `$candidate` instead."
    ok = try
        _check_defined_name(candidate); true
    catch e
        e isa ODSError || rethrow(); false
    end
    if !ok || uppercase(candidate) in used || startswith(candidate, _ANON_DB)
        @warn "Table name `$candidate` (from sheet name `$sheetname`) is not a valid table name or is in use; using an automatic table name instead."
        return ""
    end
    return candidate
end

function _write_sheets(filename, specs; overwrite::Bool, streaming::Bool, anchor_cell = CellRef("A1"), display_text::Bool = true,
                       column_widths = nothing, column_formats = nothing, as_table::Bool = false, table_name::AbstractString = "",
                       table_style = nothing, totals = nothing, freeze_header::Bool = false, names_from_sheets::Bool = false)
    _check_overwrite(filename, overwrite)
    as_table && _check_table_style(table_style)
    if streaming
        (anchor_cell == CellRef("A1") || anchor_cell == "A1") ||
            throw(ODSError("`anchor_cell` can't be used with `streaming=true`: streamed sheets start at A1."))
        totals === nothing || throw(ODSError("`streaming=true` can't write a totals row: use `as_table=true` and add totals with `settotals!` after opening the file with `mode=\"rw\"`."))
        freeze_header && throw(ODSError("`freeze_header` can't be used with `streaming=true`: a streamed file has no view settings."))
        # every sheet's column widths, declared before the first sheet starts (D-042)
        declare_widths = Float64[w for (_, _, names) in specs for (_, w) in first(_column_settings([string(c) for c in names], column_widths, nothing))]
        streamods(filename; overwrite, display_text, declare_widths) do s
            used = Set{String}()
            for (name, data, names) in specs
                nrows = SheetCore._check_table_shape(data, names)
                tn = !as_table ? "" : names_from_sheets ? _table_name_from_sheet(used, name) : table_name
                sh = addsheet!(s, name; columns = names, column_widths, column_formats, as_table, table_name = tn)
                as_table && push!(used, uppercase(s.tables[end][1]))
                row = Vector{Any}(undef, length(data))
                for i in 1:nrows
                    for j in eachindex(data)
                        row[j] = data[j][i]
                    end
                    writerow!(sh, row)
                end
            end
        end
        return filename isa AbstractString ? abspath(filename) : nothing
    end
    xf = newods(isempty(specs[1][1]) ? "" : specs[1][1])
    for (k, (name, data, names)) in enumerate(specs)
        ws = k == 1 ? xf[1] : addsheet!(xf, name)
        tn = !as_table ? "" : names_from_sheets ? _table_name_from_sheet(Set(uppercase(t.name) for t in tables(xf)), ws.name) : table_name
        writetable!(ws, data, names; anchor_cell = k == 1 ? anchor_cell : CellRef("A1"), column_widths, column_formats,
                    as_table, table_name = tn, table_style, totals, freeze_header)
    end
    return writeods(filename, xf; overwrite, display_text)
end

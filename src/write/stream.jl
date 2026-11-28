# Streaming a new file row by row: `streamods`, `addsheet!(::StreamWriter, …)`, `writerow!`,
# `writerows!`. content.xml is deflated into the package as rows are written, so memory is
# bounded by the zip writer's buffer, however many rows there are.
#
# The API follows XLSX.jl 0.13.4 (src/streamwrite.jl `streamxlsx`, `StreamWriter`,
# `StreamSheet`, `addsheet!`, `writerow!`, `writerows!`), MIT License, Copyright (c)
# 2018-2026 Felipe Noronha Tavares and other contributors. All sheets share one content.xml
# in ODS, so a sheet is finished when the next one is added.

# The rows not yet passed to the zip, and the zip's content.xml entry, shared by the writer
# and its sheets. A flush hands the bytes to the zip (`take!`) and wraps the same memory in
# a new buffer, so it is not allocated again for each chunk (as XLSX.jl's writer does).
mutable struct _StreamBuffer
    io::IOBuffer
    zip::IO
end

function _flush!(b::_StreamBuffer)
    v = take!(b.io)
    write(b.zip, v)
    b.io = IOBuffer(v; read = false, write = true, truncate = true)
    return nothing
end

"""
    StreamSheet

A sheet being written by [`streamods`](@ref). Write rows to it in order with
[`writerow!`](@ref) and [`writerows!`](@ref).
"""
mutable struct StreamSheet
    name::String
    buf::_StreamBuffer
    styles::StyleIndex
    row::Int               # the last row written
    isopen::Bool
    display::Bool          # display text in typed cells (D-029)
    colstyles::Dict{Int,Int32}   # the style of each formatted column's cells (`column_formats`)
end

"""
    StreamWriter

A file being written by [`streamods`](@ref). Add sheets to it with `addsheet!`.
"""
mutable struct StreamWriter
    buf::_StreamBuffer
    styles::StyleIndex
    names::Vector{String}
    current::Union{Nothing,StreamSheet}
    display::Bool
    named::IOBuffer                  # named cell styles for styles.xml, written last (column formats; D-042)
    widths::Dict{String,String}      # column-width text → its automatic column style
    formats::Dict{String,Int32}      # format code → its named cell style
    version::String
    started::Bool                    # content.xml's styles and the body's start are written
    tables::Vector{Tuple{String,StreamSheet,Int}}   # tables (phase 6 step 7): name, sheet, columns
end

# A column style for a width (in characters), declared in content.xml's automatic styles:
# only before the first sheet starts them (LibreOffice takes column widths from automatic
# styles only, D-042).
function _declare_width!(s::StreamWriter, width::Real)
    w = _length_text(_width_cm(width, :chars))
    haskey(s.widths, w) && return s.widths[w]
    s.started && throw(ODSError("A streamed file declares its column widths before its first sheet, and the width $width is new " *
        "after it. Give every sheet's widths to `writetable(…; streaming=true)`, or to `streamods(…; declare_widths=[…])`."))
    s.widths[w] = "odsf-co$(length(s.widths) + 1)"
end

# The start of content.xml: the automatic styles (typed styles, column widths), then the body.
function _start_content!(s::StreamWriter)
    s.started && return
    w = s.buf.zip
    print(w, _XMLDECL, "<office:document-content", _NS_DECL, " office:version=\"", s.version, "\">",
          "<office:automatic-styles>", typed_styles_xml(s.styles))
    for (wtext, name) in sort!(collect(s.widths); by = last)
        print(w, "<style:style style:name=\"", name, "\" style:family=\"table-column\"><style:table-column-properties style:column-width=\"",
              wtext, "\"/></style:style>")
    end
    print(w, "</office:automatic-styles><office:body><office:spreadsheet>")
    s.started = true
end

Base.show(io::IO, s::StreamWriter) = print(io, "StreamWriter(", length(s.names), " sheets)")
Base.show(io::IO, sh::StreamSheet) = print(io, "StreamSheet(\"", sh.name, "\", ", sh.row, " rows written", sh.isopen ? ")" : ", closed)")

# The typed styles are declared before the body (they come before it in content.xml), so
# streamed files always carry all four.
function _stream_styles()
    st = StyleIndex()
    foreach(k -> typed_style_id(st, k), (:date, :datetime, :time, :boolean))
    return st
end

"""
    streamods(f, dest; overwrite=false, version="1.4", display_text=true, declare_widths=[])

Write a new file to `dest` (a path or an `IO`) row by row, in bounded memory. `f` gets a
[`StreamWriter`](@ref): add sheets with `addsheet!(s, name; columns)` (a header row) or
`addsheet!(s, name, table)` (a Tables.jl table, header and rows), and write rows with
[`writerow!`](@ref) and [`writerows!`](@ref). The format follows the extension (`.ods`,
`.ots`; flat `.fods` is not streamed). `display_text=false` leaves out the display text of
number, date, time and boolean cells, as in [`writeods`](@ref).

Column widths (`addsheet!(…; column_widths)`) are declared at the start of the file, before
its first sheet: a width a later sheet uses must be the first sheet's too, or be listed in
`declare_widths` (in characters). `writetable(…; streaming=true)` declares them all.

```julia
streamods("big.ods") do s
    sh = addsheet!(s, "data"; columns = ["n", "square"])
    for n in 1:1_000_000
        writerow!(sh, (n, n^2))
    end
end
```
"""
function streamods(f::Function, dest::Union{AbstractString,IO}; overwrite::Bool = false,
                   version::AbstractString = DEFAULT_ODF_VERSION, display_text::Bool = true,
                   declare_widths::AbstractVector{<:Real} = Float64[])
    _check_overwrite(dest, overwrite)
    _check_version(version)
    fmt = dest isa AbstractString ? lowercase(splitext(dest)[2]) : ".ods"
    fmt == ".fods" && throw(ODSError("Flat XML (.fods) files can't be streamed; write them with `writeods`."))
    mt = fmt == ".ots" ? MEDIATYPE_OTS : MEDIATYPE_ODS
    styles = _stream_styles()
    produce(w) = begin
        ZipArchives.zip_newfile(w, "content.xml"; compress = true)
        sw = StreamWriter(_StreamBuffer(IOBuffer(), w), styles, String[], nothing, display_text, IOBuffer(),
                          Dict{String,String}(), Dict{String,Int32}(), version, false, Tuple{String,StreamSheet,Int}[])
        foreach(x -> _declare_width!(sw, x), declare_widths)
        f(sw)
        isempty(sw.names) && addsheet!(sw, "Sheet1")
        _close_sheet!(sw)
        isempty(sw.tables) || print(sw.buf.io, "<table:database-ranges>", _stream_tables_xml(sw), "</table:database-ranges>")
        _flush!(sw.buf)
        print(w, "</office:spreadsheet></office:body></office:document-content>")
        ZipArchives.zip_commitfile(w)
        # styles.xml last: it holds the named cell styles of the sheets' column formats
        named = String(take!(sw.named))
        sh = styles.sheet[1]
        sh === nothing || (named = join(sh.datastyles[n] for n in sh.added_data) * named)
        ns = _xmlns(_styles_ns(styles, ""))
        others = [PackagePart("styles.xml", new_styles_xml(version, named, ns)), PackagePart("meta.xml", new_meta_xml(version))]
        _append_parts!(w, others, manifest_xml(vcat([PackagePart("content.xml", "")], others), mt, version))
    end
    if dest isa AbstractString
        _write_replacing(dest) do tmp
            open(io -> _write_mimetype_zip(io, mt), tmp, "w")
            ZipArchives.zip_append_archive(produce, tmp)
        end
        return abspath(dest)
    else
        buf = IOBuffer()
        _write_mimetype_zip(buf, mt)
        ZipArchives.zip_append_archive(produce, buf)
        write(dest, take!(buf))
        return nothing
    end
end

function _close_sheet!(s::StreamWriter)
    sh = s.current
    (sh === nothing || !sh.isopen) && return
    sh.row == 0 && print(s.buf.io, _EMPTY_ROW)
    print(s.buf.io, "</table:table>")
    sh.isopen = false
    return
end

"""
    addsheet!(s::StreamWriter, name=""; columns=nothing, column_widths=nothing, column_formats=nothing,
              as_table=false, table_name="", table_style=nothing) -> StreamSheet
    addsheet!(s::StreamWriter, name, table; column_widths, column_formats, as_table, table_name, table_style) -> StreamSheet

Start the next sheet of a streamed file, finishing the one before. `columns` writes a header
row; a Tables.jl `table` writes its header and all its rows. `column_widths` and
`column_formats` set the columns' widths and the number formats of the rows written after
the header, as in [`writetable!`](@ref). `as_table=true` makes the sheet's rows a table, named
`table_name` (`""`: the first free `TableN`), as `writetable!` does; it needs `columns`.
"""
function addsheet!(s::StreamWriter, name::AbstractString = ""; columns = nothing, column_widths = nothing,
                   column_formats = nothing, as_table::Bool = false, table_name::AbstractString = "", table_style = nothing)
    if as_table                                 # checked first: the sheet isn't started if refused
        columns === nothing && throw(ODSError("`as_table=true` needs `columns`: a table needs a header row."))
        _check_table_style(table_style)
        table_name = _stream_table_name(s, table_name)
    end
    widths, formats = _column_settings(columns === nothing ? nothing : [string(c) for c in columns], column_widths, column_formats)
    _close_sheet!(s)
    if isempty(name)
        n = length(s.names) + 1
        while any(x -> _same_sheetname(x, "Sheet$n"), s.names); n += 1; end
        name = "Sheet$n"
    end
    _check_sheetname(name, s.names, "There is already a sheet named `$name`.")
    push!(s.names, String(name))
    foreach(p -> _declare_width!(s, p.second), widths)       # the first sheet's can still be declared
    _start_content!(s)
    io = s.buf.io
    print(io, "<table:table table:name=\""); _escape_attr(io, name); print(io, "\">")
    # the width is not known in advance; a wide column definition costs nothing (F-028)
    _stream_columns!(io, s, widths)
    sh = StreamSheet(String(name), s.buf, s.styles, 0, true, s.display, Dict{Int,Int32}())
    s.current = sh
    columns === nothing || writerow!(sh, [string(c) for c in columns])
    as_table && push!(s.tables, (String(table_name), sh, length(columns)))
    for (c, fmt) in formats                     # the header keeps no format: set after it
        sh.colstyles[c] = _stream_format_style!(s, fmt)
    end
    return sh
end

# The sheet's columns: a named column style for each width, then the rest of the sheet.
function _stream_columns!(io::IOBuffer, s::StreamWriter, widths::Vector{Pair{Int,Float64}})
    bycol = Dict(widths)
    c = 1
    for k in sort!(collect(keys(bycol)))
        k > c && print(io, "<table:table-column", k - c > 1 ? " table:number-columns-repeated=\"$(k - c)\"" : "", "/>")
        name = _declare_width!(s, bycol[k])
        print(io, "<table:table-column table:style-name=\"", name, "\"/>")
        c = k + 1
    end
    c <= SheetCore.MAX_COLS && print(io, "<table:table-column table:number-columns-repeated=\"", SheetCore.MAX_COLS - c + 1, "\"/>")
end

# A named cell style with the number format `fmt` (its data style, too, goes to styles.xml).
function _stream_format_style!(s::StreamWriter, fmt::AbstractString)
    code = _format_code(fmt)
    get!(s.formats, code) do
        ds = add_number_format!(s.styles, code)
        isempty(ds) && return Int32(0)
        name = "odsf-fmt$(length(s.formats) + 1)"
        print(s.named, "<style:style style:name=\"", name, "\" style:family=\"table-cell\" style:parent-style-name=\"Default\" style:data-style-name=\"", _xattr(ds), "\"/>")
        _register_style!(s.styles, name, stylesheet(s.styles).datainfo[ds], CellStyle("Default", ds))
    end
end

function addsheet!(s::StreamWriter, name::AbstractString, table; kw...)
    sh = addsheet!(s, name; columns = collect(String, string.(Tables.columnnames(Tables.columns(table)))), kw...)
    writerows!(sh, table)
    return sh
end

"""
    writerow!(sh::StreamSheet, row)

Write the next row of a streamed sheet: a tuple, `NamedTuple` or vector of values (`missing`
or `nothing` leave a cell empty).
"""
function writerow!(sh::StreamSheet, row::Union{Tuple,NamedTuple,AbstractVector})
    sh.isopen || throw(ODSError("Can't write to sheet `$(sh.name)`: it is closed. A streamed sheet is closed when the next sheet is added, and when `streamods` returns."))
    length(row) > SheetCore.MAX_COLS && throw(ODSError("A row of $(length(row)) values is wider than a sheet ($(SheetCore.MAX_COLS) columns)."))
    sh.row >= SheetCore.MAX_ROWS && throw(ODSError("A sheet holds at most $(SheetCore.MAX_ROWS) rows."))
    io = sh.buf.io
    print(io, "<table:table-row>")
    gap = 0
    any = false
    for (j, v) in enumerate(values(row))
        if v === missing || v === nothing
            gap += 1
            continue
        end
        gap > 0 && write_cell(io, nothing, sh.styles; repeat = gap)
        gap = 0
        _stream_cell!(io, sh, v, isempty(sh.colstyles) ? Int32(0) : get(sh.colstyles, j, Int32(0)))
        any = true
    end
    any || print(io, "<table:table-cell/>")
    print(io, "</table:table-row>")
    sh.row += 1
    position(io) > (1 << 20) && _flush!(sh.buf)
    return nothing
end

# A function barrier: specialised on the value's type, the cell is encoded and written
# without boxing its stored form (phase 3).
function _stream_cell!(io::IOBuffer, sh::StreamSheet, v, colstyle::Int32 = Int32(0))
    # a column's format, when it fits the value; else as without one (no derived styles can be
    # added once the sheet has begun)
    style = colstyle != 0 && _style_fits(style_info(sh.styles, colstyle), _needed_kind(v)) ? colstyle : choose_style(sh.styles, 0, v)
    d = encode_value(v, style)
    d === nothing || write_cell(io, d, sh.styles; display = sh.display)
    return nothing
end
writerow!(::StreamSheet, row) = throw(ODSError("`writerow!` takes a row as a tuple, `NamedTuple` or vector, got `$(typeof(row))`."))

"""
    writerows!(sh::StreamSheet, table)

Write every row of a Tables.jl table (without its header) to a streamed sheet.
"""
function writerows!(sh::StreamSheet, table)
    Tables.istable(table) || throw(ODSError("$(typeof(table)) is not a Tables.jl table."))
    for r in Tables.rows(table)
        names = Tables.columnnames(r)
        writerow!(sh, [Tables.getcolumn(r, n) for n in names])
    end
    return nothing
end

# A streamed table's name, checked as `addtable!` checks one, against the stream's tables.
_stream_table_name(s::StreamWriter, name::AbstractString) = _table_name(Set{String}(uppercase(t[1]) for t in s.tables), name)

# The streamed tables, each over its sheet's rows, as `addtable!` writes them.
_stream_tables_xml(s::StreamWriter) =
    join(_db_xml(DBRange(n, (; name = sh.name), 1, 1, max(sh.row, 1), nc, true, false, true, "", 0.0)) for (n, sh, nc) in s.tables)

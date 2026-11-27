# Writing values into the cell store: OpenDocumentSpreadsheets's typed styles (D-024), the encoding of Julia
# values as `CellData` (D-026), which style a written cell keeps (D-027), and `store_set!`,
# which splits row and cell runs around an edit.

#
# Typed styles (D-024): ISO formats, so that LibreOffice keeps the value types (F-011, F-028)
#

const _TYPED_STYLE_INFO = Dict(
    :date => DataStyleInfo(DK_DATE, -1, false),
    :datetime => DataStyleInfo(DK_DATE, -1, true),
    :time => DataStyleInfo(DK_TIME, -1, true),
    :boolean => DataStyleInfo(DK_BOOLEAN, -1, false))

# the XML of each typed style: (data style, cell style), given their names
function _typed_style_xml(kind::Symbol, cellname::AbstractString)
    cell = """<style:style style:name="$cellname" style:family="table-cell" style:parent-style-name="Default" style:data-style-name="$(cellname)-N"/>"""
    return _typed_data_xml(kind, "$(cellname)-N") * cell
end

function _typed_data_xml(kind::Symbol, dname::AbstractString)
    ymd ="""<number:year number:style="long"/><number:text>-</number:text><number:month number:style="long"/><number:text>-</number:text><number:day number:style="long"/>"""
    hms = """<number:hours number:style="long"/><number:text>:</number:text><number:minutes number:style="long"/><number:text>:</number:text><number:seconds number:style="long"/>"""
    data = kind === :date ? """<number:date-style style:name="$dname">$ymd</number:date-style>""" :
           kind === :datetime ? """<number:date-style style:name="$dname">$ymd<number:text> </number:text>$hms</number:date-style>""" :
           kind === :time ? """<number:time-style style:name="$dname" number:truncate-on-overflow="false">$hms</number:time-style>""" :
           """<number:boolean-style style:name="$dname"><number:boolean/></number:boolean-style>"""
    return data
end

"""
    typed_style_id(styles::StyleIndex, kind::Symbol) -> Int32

The id of OpenDocumentSpreadsheets's cell style for `kind` (`:date`, `:datetime`, `:time`, `:boolean`),
adding it to the index on first use. Its name is `odsf-<kind>`, with a number added if the
document already uses that name.
"""
function typed_style_id(styles::StyleIndex, kind::Symbol)
    id = get(styles.added, kind, nothing)
    id === nothing || return id
    base = "odsf-$kind"
    name = base
    k = 1
    while haskey(styles.ids, name)
        k += 1
        name = "$base-$k"
    end
    sh = styles.sheet[1]
    if sh !== nothing
        sh.datainfo["$name-N"] = _TYPED_STYLE_INFO[kind]
        sh.datastyles["$name-N"] = _typed_data_xml(kind, "$name-N")    # for getFormat and getText (not written again)
    end
    id = _register_style!(styles, name, _TYPED_STYLE_INFO[kind], CellStyle("Default", "$name-N"))
    styles.added[kind] = id
    return id
end

# The XML of every typed style added to the index, for office:automatic-styles.
function typed_styles_xml(styles::StyleIndex)
    io = IOBuffer()
    for kind in (:date, :datetime, :time, :boolean)
        id = get(styles.added, kind, nothing)
        id === nothing || print(io, _typed_style_xml(kind, style_name(styles, id)))
    end
    return String(take!(io))
end

#
# Values → CellData
#

# The typed style a value needs, or `nothing`.
_needed_kind(::Dates.Date) = :date
_needed_kind(::Dates.DateTime) = :datetime
_needed_kind(::Union{Dates.Time,Dates.Period,Dates.CompoundPeriod}) = :time
_needed_kind(::Bool) = :boolean
_needed_kind(_) = nothing

# Whether an existing style shows a value needing `kind` (then the cell keeps it).
function _style_fits(info::DataStyleInfo, kind::Union{Nothing,Symbol})
    if kind === nothing
        # a number or text under a date, time or boolean format would be retyped by
        # LibreOffice on its next save (F-011): such a style is not kept
        return !(info.kind in (DK_DATE, DK_TIME, DK_BOOLEAN))
    elseif kind === :date || kind === :datetime
        return info.kind === DK_DATE
    elseif kind === :time
        return info.kind === DK_TIME
    else
        return info.kind === DK_BOOLEAN
    end
end

"""
    choose_style(styles, old_style, value) -> Int32

The style a cell written with `value` gets: its current style if that style's data
format fits the value. Otherwise a style that is only a number format gives way to
OpenDocumentSpreadsheets's typed style for dates, times and booleans, or `Default` for numbers and text; any
other style is kept with only its number format replaced (D-037, `retyped_style`).
"""
function choose_style(styles::StyleIndex, old::Integer, value)
    kind = _needed_kind(value)
    _style_fits(style_info(styles, old), kind) && return Int32(old)
    old == 0 && return kind === nothing ? Int32(0) : typed_style_id(styles, kind)
    return retyped_style(styles, Int32(old), kind)
end

_duration_ns(t::Dates.Time) = Dates.value(t)
_duration_ns(p::Dates.Period) = _duration_ns(Dates.CompoundPeriod(p))
function _duration_ns(p::Dates.CompoundPeriod)
    total = Int128(0)
    for x in p.periods
        x isa Union{Dates.Month,Dates.Year,Dates.Quarter} &&
            throw(ODSError("A duration of $p can't be written: months and years have no fixed length."))
        total += Dates.value(convert(Dates.Nanosecond, x))
    end
    typemin(Int64) <= total <= typemax(Int64) || throw(ODSError("The duration $p is too long."))
    return Int64(total)
end

"""
    encode_value(value, style::Int32; colspan=1, rowspan=1, covered=false) -> Union{CellData, Nothing}

The stored form of a Julia value: `nothing` (remove the cell) for `missing` and `nothing`.
Integers are stored as whole numbers, other reals as Float64, except `NaN`, `Inf`
and `-Inf`, which ODF can't hold as numbers: they are stored as the text `"NaN"`, `"Inf"`
and `"-Inf"`; dates, date-times,
times and durations, booleans and strings as their ODF types.
"""
function encode_value(v, style::Int32; colspan::Integer = 1, rowspan::Integer = 1, covered::Bool = false)
    flags = covered ? F_COVERED : 0x00
    mk(kind, bits, text = nothing; extra = 0x00) =
        CellData(kind, flags | extra, style, bits, text, nothing, Int32(colspan), Int32(rowspan))
    if v === missing || v === nothing
        return nothing
    elseif v isa Bool
        return mk(CK_BOOL, UInt64(v))
    elseif v isa Integer
        x = Int64(v)
        return mk(CK_FLOAT, reinterpret(UInt64, Float64(x)), string(x); extra = F_INTLIKE)
    elseif v isa Real
        x = Float64(v)
        # ODF has no NaN or Inf: like XLSX.jl, write them as the text "NaN", "Inf", "-Inf" (D-043).
        isfinite(x) || return mk(CK_STRING, UInt64(0), string(x))
        return mk(CK_FLOAT, reinterpret(UInt64, x))
    elseif v isa AbstractString
        s = String(v)
        _check_xml_text(s)
        return mk(CK_STRING, UInt64(0), s)
    elseif v isa Dates.DateTime
        return mk(CK_DATETIME, reinterpret(UInt64, Dates.value(v)))
    elseif v isa Dates.Date
        return mk(CK_DATE, reinterpret(UInt64, Dates.value(v)))
    elseif v isa Union{Dates.Time,Dates.Period,Dates.CompoundPeriod}
        return mk(CK_TIME, reinterpret(UInt64, _duration_ns(v)))
    end
    throw(ODSError("$(repr(v)): values of type $(typeof(v)) can't be written to a cell. Supported are numbers, strings, Bool, Date, DateTime, Time, periods, missing and nothing."))
end

# XML 1.0 allows no control characters but tab, LF and CR, nor U+FFFE, U+FFFF or text that
# isn't valid UTF-8; LibreOffice refuses a file holding one (F-090). Every setter that takes
# user text calls this, so the error comes from the call that gave it (code review, Phase 1).
function _check_xml_text(s::AbstractString)
    for c in s
        if !isvalid(c)
            throw(ODSError("The text $(repr(s)) is not valid UTF-8, which an XML file needs."))
        elseif (c < ' ' && !(c in ('\t', '\n', '\r'))) || c == '￾' || c == '￿'
            throw(ODSError("The text $(repr(s)) holds the control character $(repr(c)), which an XML file can't hold."))
        end
    end
end
_check_xml_text(::Nothing) = nothing

#
# Editing the store
#

# `runs` with column `col` set to `d` (removed if `d === nothing`), splitting the run there.
function _runs_set!(runs::Vector{CellRun}, col::Int, d::Union{Nothing,CellData})
    lo, hi = 1, length(runs)
    while lo <= hi                              # the first run ending at or after col
        mid = (lo + hi) >>> 1
        if _lastcol(runs[mid]) < col
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    i = lo
    if i <= length(runs) && runs[i].col <= col
        r = runs[i]
        parts = CellRun[]
        r.col < col && push!(parts, CellRun(r.col, col - r.col, r.data))
        d === nothing || push!(parts, CellRun(col, 1, d))
        _lastcol(r) > col && push!(parts, CellRun(col + 1, _lastcol(r) - col, r.data))
        splice!(runs, i, parts)
    elseif d !== nothing
        insert!(runs, i, CellRun(col, 1, d))
    end
    return runs
end

"""
    store_set!(s::SheetStore, row, col, d::Union{CellData, Nothing})

Set (or with `nothing`, remove) one cell of the store, splitting the repeated rows and
cells around it. The bounds are kept up to date.
"""
function store_set!(s::SheetStore, row::Int, col::Int, d::Union{Nothing,CellData})
    _rows_set!(s.rows, row, col, d) || return s
    if d === nothing
        s.stale = true
    elseif !s.stale
        dim = s.dimension
        s.dimension = dim === nothing ? CellRange(CellRef(row, col), CellRef(row, col)) :
            CellRange(CellRef(min(row, row_number(dim.start)), min(col, column_number(dim.start))),
                      CellRef(max(row, row_number(dim.stop)), max(col, column_number(dim.stop))))
    end
    return s
end

# Sets (or with `nothing`, removes) cell (row, col) of a run-length row list, splitting the
# repeated rows and cells around it. False if there was nothing to remove.
function _rows_set!(rows::Vector{RowData}, row::Int, col::Int, d::Union{Nothing,CellData})
    i = _first_row_index(rows, row)
    if i <= length(rows) && rows[i].row <= row
        rd = rows[i]
        if rd.count > 1
            parts = RowData[]
            rd.row < row && push!(parts, RowData(rd.row, row - rd.row, copy(rd.runs)))
            push!(parts, RowData(row, 1, copy(rd.runs)))
            _lastrow(rd) > row && push!(parts, RowData(row + 1, _lastrow(rd) - row, copy(rd.runs)))
            splice!(rows, i, parts)
            rd.row < row && (i += 1)
        end
        _runs_set!(rows[i].runs, col, d)
        isempty(rows[i].runs) && deleteat!(rows, i)
    elseif d !== nothing
        insert!(rows, i, RowData(row, 1, [CellRun(col, 1, d)]))
    else
        return false
    end
    return true
end

# Cell values: what a cell holds as the reader stores it (`CellData`), how the stored form
# becomes a Julia value, and the public `Cell` / `EmptyCell` types.
#
# Value types (D-016, D-017, F-018 to F-023):
#   float, percentage, currency → Int64 if the stored text is a whole number and the cell's
#                                 data style shows no decimals, else Float64
#   date                        → DateTime if the value has a time part or the data style
#                                 shows a time, else Date
#   time (a duration)           → Dates.Time from 0 to under 24 hours, else a canonical
#                                 Dates.CompoundPeriod
#   boolean                     → Bool
#   string                      → String; an empty string reads as `missing`
#   error (calcext)             → `missing`; `iserror`/`geterror` see it
#   none                        → `missing`

@enum CellKind::UInt8 begin
    CK_EMPTY
    CK_FLOAT
    CK_PERCENT
    CK_CURRENCY
    CK_DATE        # bits: days (Dates.value of a Date)
    CK_DATETIME    # bits: milliseconds (Dates.value of a DateTime)
    CK_TIME        # bits: nanoseconds, signed
    CK_BOOL
    CK_STRING
    CK_ERROR
end

const F_INTLIKE = 0x01     # the stored number text is a whole number that fits an Int64
const F_COVERED = 0x02     # a table:covered-table-cell
const F_RICH = 0x04        # a string cell written from markup: `bits` indexes `StyleIndex.rich` (a hyperlink, D-072)
const F_PLAIN = 0x08       # a string cell whose original paragraphs are not kept on save (a link removed, D-072)

"""
    CellData

A cell as the reader stores it: its kind, flags, effective style id (`StyleIndex`), the
value bits (a Float64, day, millisecond or nanosecond count, or a Bool, by kind), the text
of a string or error (or the currency code of a currency cell), the raw formula, and the
spans of a merge anchor.
"""
struct CellData
    kind::CellKind
    flags::UInt8
    style::Int32
    bits::UInt64
    text::Union{Nothing,String}
    formula::Union{Nothing,String}
    colspan::Int32
    rowspan::Int32
end

# Whether a stored cell is content: it holds a value or a formula. Anything else (empty,
# styled-only, an empty covered cell) is not stored by the reader (D-008).
@inline has_content(d::CellData) = d.kind !== CK_EMPTY || d.formula !== nothing

#
# Parsing the value attributes
#

# A whole number written without a decimal point or exponent, that fits an Int64.
function _is_intlike(s::AbstractString)
    n = ncodeunits(s)
    n == 0 && return false
    i = 1
    @inbounds b = codeunit(s, 1)
    if b == UInt8('-') || b == UInt8('+')
        n == 1 && return false
        i = 2
    end
    n - i + 1 > 18 && return false
    @inbounds for k in i:n
        b = codeunit(s, k)
        UInt8('0') <= b <= UInt8('9') || return false
    end
    return true
end

# `office:value` is parsed millions of times per sheet, so Parsers.jl rather than Base's
# `tryparse(Float64, …)`, which goes through C `strtod` (half the read time in phase 3;
# D-030, as XLSX.jl does). Parsers.jl 3 gives Base's correctly rounded result.
# Parsers.jl 2 (allowed, for environments capped at it) differs from Base on overflow,
# underflow and some unusual forms, so its non-finite and zero results are checked with
# Base. Text that is not a number reads as 0.0, as LibreOffice re-saves it (F-018), and so
# do `INF`, `-inf` and `NaN`, which LibreOffice reads as 0 (F-092).
const _PARSERS_V2 = pkgversion(Parsers) < v"3"

function _parse_float(s::AbstractString)
    x = Parsers.tryparse(Float64, s)
    if x === nothing || (_PARSERS_V2 && (!isfinite(x) || iszero(x)))
        y = tryparse(Float64, strip(s))
        x = y === nothing ? something(x, 0.0) : y
    end
    return isfinite(x) ? x : 0.0
end

# Read `n` digits starting at `i`; returns (value, next index) or (-1, i) on failure.
@inline function _digits(s, i::Int, n::Int)
    v = 0
    for k in i:i+n-1
        k > ncodeunits(s) && return -1, i
        b = codeunit(s, k)
        UInt8('0') <= b <= UInt8('9') || return -1, i
        v = 10v + (b - UInt8('0'))
    end
    return v, i + n
end

# Whether `e` says a file's content is bad: the package's own errors, a damaged part
# (`ArgumentError`) or XML that doesn't parse (XML.jl's `ErrorException`). Code that falls
# back on such content catches these only, so a bug (a `MethodError`), an interrupt or a lack
# of memory still propagates.
_content_error(e) = e isa ODSError || e isa ArgumentError || e isa ErrorException

# A count from a file (a repeat or a span): read as Int64, so a 32-bit build reads a file as a
# 64-bit one does, and cut to `lo:hi`, as no count passes the sheet's end. Digits too many for
# Int64 are `hi`; a value that isn't a whole number is `default`.
function _file_count(v::AbstractString, default::Integer, lo::Integer, hi::Integer)::Int
    n = tryparse(Int64, v)
    if n === nothing
        t = strip(v)
        return !isempty(t) && all(isdigit, t) ? hi : default
    end
    return Int(clamp(n, lo, hi))
end

# The spaces a `text:s` stands for, from its `text:c` (`nothing`: none given). As in
# LibreOffice (F-092), a count that isn't a number from 1 to 2^31 - 1 is one space. Past
# 2^24 the count is cut (D-097), so a 30-byte element can't ask for gigabytes.
const _MAX_SPACES = 1 << 24
function _space_count(v::Union{Nothing,AbstractString})::Int
    v === nothing && return 1
    n = tryparse(Int64, v)
    (n === nothing || n < 1 || n > typemax(Int32)) && return 1
    return Int(min(n, _MAX_SPACES))
end

"""
    parse_odf_date(s) -> Union{Date, DateTime, Nothing}

An `office:date-value`: `YYYY-MM-DD` or `YYYY-MM-DDThh:mm:ss[.fff]`, with an optional sign
or extra year digits and an optional time zone (ignored). Fractions of a second beyond
milliseconds are rounded. Returns `nothing` if `s` is not a date.
"""
function parse_odf_date(s::AbstractString)
    s = strip(s)
    n = ncodeunits(s)
    n == 0 && return nothing
    i = 1
    neg = false
    if codeunit(s, 1) == UInt8('-')
        neg = true; i = 2
    elseif codeunit(s, 1) == UInt8('+')
        i = 2
    end
    # the year: 4 or more digits up to the next '-'
    j = i
    while j <= n && UInt8('0') <= codeunit(s, j) <= UInt8('9')
        j += 1
    end
    # at most 9 digits: a longer year overflowed (and threw on a 32-bit build), and is no date
    (1 <= j - i <= 9 && j <= n && codeunit(s, j) == UInt8('-')) || return nothing
    y = parse(Int64, SubString(s, i, j - 1))
    neg && (y = -y)
    m, j = _digits(s, j + 1, 2); m < 0 && return nothing
    (j <= n && codeunit(s, j) == UInt8('-')) || return nothing
    d, j = _digits(s, j + 1, 2); d < 0 && return nothing
    (1 <= m <= 12 && 1 <= d <= Dates.daysinmonth(y, m)) || return nothing
    j > n && return Dates.Date(y, m, d)
    codeunit(s, j) == UInt8('T') || return nothing
    hh, j = _digits(s, j + 1, 2); hh < 0 && return nothing
    (j <= n && codeunit(s, j) == UInt8(':')) || return nothing
    mm, j = _digits(s, j + 1, 2); mm < 0 && return nothing
    ss = 0; ms = 0
    if j <= n && codeunit(s, j) == UInt8(':')
        ss, j = _digits(s, j + 1, 2); ss < 0 && return nothing
        if j <= n && codeunit(s, j) == UInt8('.')
            k = j + 1
            while k <= n && UInt8('0') <= codeunit(s, k) <= UInt8('9')
                k += 1
            end
            frac = SubString(s, j + 1, k - 1)
            isempty(frac) || (ms = round(Int, parse(Float64, "0." * frac) * 1000))
            j = k
        end
    end
    (hh <= 24 && mm <= 59 && ss <= 60) || return nothing
    # anything left is a time zone (Z, +hh:mm, -hh:mm): not modelled
    return Dates.DateTime(y, m, d) + Dates.Hour(hh) + Dates.Minute(mm) + Dates.Second(ss) + Dates.Millisecond(ms)
end

"""
    parse_odf_duration(s) -> Union{Int64, Nothing}

An `office:time-value`, an ISO 8601 duration such as `PT13H45M30S`, `-PT01H00M00S`,
`P1DT2H` or `PT0.5S`, in nanoseconds. Years count 365 days and months 30 (ODF time values
do not use them in practice). Returns `nothing` if `s` is not a duration.
"""
function parse_odf_duration(s::AbstractString)
    s = strip(s)
    n = ncodeunits(s)
    i = 1
    neg = false
    if n >= 1 && codeunit(s, 1) == UInt8('-')
        neg = true; i = 2
    elseif n >= 1 && codeunit(s, 1) == UInt8('+')
        i = 2
    end
    (i <= n && codeunit(s, i) == UInt8('P')) || return nothing
    i += 1
    intime = false
    total = Int128(0)
    any = false
    while i <= n
        b = codeunit(s, i)
        if b == UInt8('T')
            intime && return nothing
            intime = true; i += 1
            continue
        end
        j = i
        while j <= n && (UInt8('0') <= codeunit(s, j) <= UInt8('9') || codeunit(s, j) == UInt8('.') || codeunit(s, j) == UInt8(','))
            j += 1
        end
        (j > i && j <= n) || return nothing
        numtext = replace(SubString(s, i, j - 1), ',' => '.')
        unit = codeunit(s, j)
        if occursin('.', numtext)
            x = tryparse(Float64, numtext); x === nothing && return nothing
            # whole part exact, fraction rounded to the nanosecond
            whole = floor(Int128, x)
            fracns(mult) = round(Int128, (x - whole) * mult)
            mult = _duration_unit_ns(unit, intime); mult == 0 && return nothing
            total += whole * mult + fracns(mult)
        else
            v = tryparse(Int128, numtext); v === nothing && return nothing
            mult = _duration_unit_ns(unit, intime); mult == 0 && return nothing
            total += v * mult
        end
        any = true
        i = j + 1
    end
    any || return nothing
    neg && (total = -total)
    typemin(Int64) <= total <= typemax(Int64) || return nothing
    return Int64(total)
end

const _NS_SECOND = Int128(1_000_000_000)
function _duration_unit_ns(unit::UInt8, intime::Bool)::Int128
    if intime
        unit == UInt8('H') && return 3600 * _NS_SECOND
        unit == UInt8('M') && return 60 * _NS_SECOND
        unit == UInt8('S') && return _NS_SECOND
    else
        unit == UInt8('D') && return 86400 * _NS_SECOND
        unit == UInt8('W') && return 7 * 86400 * _NS_SECOND
        unit == UInt8('M') && return 30 * 86400 * _NS_SECOND
        unit == UInt8('Y') && return 365 * 86400 * _NS_SECOND
    end
    return Int128(0)
end

const _NS_PER_DAY = Int64(86_400_000_000_000)

# Dates and date-times are stored as `Dates.value` (days, and milliseconds, counted so that
# 0001-01-01 is day 1); back through public arithmetic only.
_date_from_days(v::Integer) = Dates.Date(1, 1, 1) + Dates.Day(v - 1)
_datetime_from_ms(v::Integer) = Dates.DateTime(1, 1, 1) + Dates.Millisecond(v - 86_400_000)

"""
    duration_value(ns::Integer)

The Julia value of a time cell holding `ns` nanoseconds: a `Dates.Time` from 0 to
under 24 hours, otherwise a canonical `Dates.CompoundPeriod` (for example `1 day, 12 hours`
or `-1 hour`).
"""
duration_value(ns::Integer) =
    0 <= ns < _NS_PER_DAY ? Dates.Time(Dates.Nanosecond(ns)) :
                            Dates.canonicalize(Dates.CompoundPeriod(Dates.Nanosecond(ns)))

#
# From stored form to value
#

"""
    _with_cell_value(f, d::CellData, styles::StyleIndex)

Call `f` on the Julia value of `d`, in a branch per value type, so that `f` sees a concrete
type (a function barrier for the table readers). Returns what `f` returns.
"""
@inline function _with_cell_value(f::F, d::CellData, styles::StyleIndex) where {F}
    k = d.kind
    if k === CK_FLOAT || k === CK_PERCENT || k === CK_CURRENCY
        x = reinterpret(Float64, d.bits)
        if (d.flags & F_INTLIKE) != 0 && !shows_decimals(style_info(styles, d.style))
            return f(Int64(x))
        end
        return f(x)
    elseif k === CK_STRING
        t = d.text::String
        return isempty(t) ? f(missing) : f(t)
    elseif k === CK_DATE
        day = _date_from_days(reinterpret(Int64, d.bits))
        if style_info(styles, d.style).hastime
            return f(Dates.DateTime(day))
        end
        return f(day)
    elseif k === CK_DATETIME
        return f(_datetime_from_ms(reinterpret(Int64, d.bits)))
    elseif k === CK_BOOL
        return f(d.bits != 0)
    elseif k === CK_TIME
        ns = reinterpret(Int64, d.bits)
        if 0 <= ns < _NS_PER_DAY
            return f(Dates.Time(Dates.Nanosecond(ns)))
        end
        return f(duration_value(ns))
    end
    return f(missing)     # empty, error
end

cell_value(d::CellData, styles::StyleIndex) = _with_cell_value(identity, d, styles)

const _KIND_SYMBOLS = Dict(CK_EMPTY => :empty, CK_FLOAT => :float, CK_PERCENT => :percentage,
    CK_CURRENCY => :currency, CK_DATE => :date, CK_DATETIME => :date, CK_TIME => :time,
    CK_BOOL => :boolean, CK_STRING => :string, CK_ERROR => :error)

#
# Public cell types
#

"""
    AbstractCell

A cell of a worksheet: a [`Cell`](@ref), or an [`EmptyCell`](@ref) where the sheet holds
nothing.
"""
abstract type AbstractCell end

"""
    Cell

A cell read from a worksheet. Fields:
- `ref::CellRef`: its position
- `datatype::Symbol`: the ODF value type: `:float`, `:percentage`, `:currency`, `:date`,
  `:time`, `:boolean`, `:string`, `:error`, or `:empty` (a formula with no result, or a
  covered cell)
- `value`: its value, as [`getdata`](@ref) returns it
- `formula`: the stored formula (`"of:=[.A1]*3"`), or `nothing`;
  [`getFormula`](@ref) gives it in LibreOffice's notation
- `style::String`: the name of its effective cell style
- `currency`: the currency code of a currency cell (`"GBP"`), else `nothing`
- `error`: the displayed text of an error result (`"#DIV/0!"`, `"Err:502"`), else `nothing`
- `colspan`, `rowspan`: the size of a merge whose top-left cell this is (1 otherwise)
- `covered::Bool`: whether the cell is hidden by a merge
"""
struct Cell <: AbstractCell
    ref::CellRef
    datatype::Symbol
    value::Any
    formula::Union{Nothing,String}
    style::String
    currency::Union{Nothing,String}
    error::Union{Nothing,String}
    colspan::Int
    rowspan::Int
    covered::Bool
end

"""
    EmptyCell(ref)

A position where the worksheet holds no value and no formula.
"""
struct EmptyCell <: AbstractCell
    ref::CellRef
end

function Cell(ref::CellRef, d::CellData, styles::StyleIndex)
    Cell(ref, _KIND_SYMBOLS[d.kind], cell_value(d, styles), d.formula, style_name(styles, d.style),
         d.kind === CK_CURRENCY ? d.text : nothing, d.kind === CK_ERROR ? d.text : nothing,
         Int(d.colspan), Int(d.rowspan), (d.flags & F_COVERED) != 0)
end

SheetCore.row_number(c::AbstractCell) = SheetCore.row_number(c.ref)
SheetCore.column_number(c::AbstractCell) = SheetCore.column_number(c.ref)
Base.isempty(::EmptyCell) = true
Base.isempty(c::Cell) = c.datatype === :empty && c.formula === nothing

Base.:(==)(a::Cell, b::Cell) = a.ref == b.ref && a.datatype == b.datatype && isequal(a.value, b.value) &&
    a.formula == b.formula && a.style == b.style && a.currency == b.currency && a.error == b.error &&
    a.colspan == b.colspan && a.rowspan == b.rowspan && a.covered == b.covered
Base.hash(c::Cell, h::UInt) = hash((c.ref, c.datatype, c.value, c.formula, c.style), h)

Base.show(io::IO, c::EmptyCell) = print(io, "EmptyCell(", c.ref, ")")
function Base.show(io::IO, c::Cell)
    print(io, "Cell(", c.ref, ", :", c.datatype, ", ", repr(c.value))
    c.formula === nothing || print(io, ", formula=", repr(c.formula))
    c.error === nothing || print(io, ", error=", repr(c.error))
    print(io, ")")
end

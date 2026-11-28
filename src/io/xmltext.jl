# Text for XML: escaping, and numbers in attribute values (code review Phase 4, D-110).
#
# Escaping: the package's one implementation.
# `XML.unescape` reads values back. `XML.escape` (public) is not used for writing: it also
# writes `'` as `&apos;`, which LibreOffice doesn't (every quoted sheet name in a formula would
# change), and it returns a new String where these write to the IO. Text escapes `&`, `<` and
# `>`; an attribute value also `"` and, as character references, tab, LF and CR (which a reader
# would turn into spaces).

# Whether `s` holds none of the given ASCII bytes (most texts and names need no escaping:
# they are then written at once, phase 3).
@inline function _none_of(s::AbstractString, bytes)
    for b in codeunits(s)
        b in bytes && return false
    end
    return true
end
const _TEXT_SPECIAL = (UInt8('&'), UInt8('<'), UInt8('>'))
const _ATTR_SPECIAL = (UInt8('&'), UInt8('<'), UInt8('>'), UInt8('"'), UInt8('\n'), UInt8('\r'), UInt8('\t'))

function _escape_text(io::IO, s::AbstractString)
    _none_of(s, _TEXT_SPECIAL) && (write(io, s); return)
    for c in s
        if c == '&'
            print(io, "&amp;")
        elseif c == '<'
            print(io, "&lt;")
        elseif c == '>'
            print(io, "&gt;")
        else
            print(io, c)
        end
    end
end

function _escape_attr(io::IO, s::AbstractString)
    _none_of(s, _ATTR_SPECIAL) && (write(io, s); return)
    for c in s
        if c == '&'
            print(io, "&amp;")
        elseif c == '<'
            print(io, "&lt;")
        elseif c == '>'
            print(io, "&gt;")
        elseif c == '"'
            print(io, "&quot;")
        elseif c == '\n'
            print(io, "&#10;")
        elseif c == '\r'
            print(io, "&#13;")
        elseif c == '\t'
            print(io, "&#9;")
        else
            print(io, c)
        end
    end
end
_escape_attr(s::AbstractString) = sprint(_escape_attr, s)
_xtext(s::AbstractString) = sprint(_escape_text, s)
_xattr(s::AbstractString) = sprint(_escape_attr, s)

# A number as decimal text for an attribute value: ODF's lengths and percentages have no
# exponent (`1e-7pt` is not a length), so one written as `1.0e-7` by `string` is spelt out.
# Rounded to `digits` places when given, else the shortest text that reads back the same.
# Trailing zeros are dropped; a whole number is written as Int64 digits (an `Int` overflows
# past 2^31 on a 32-bit build).
function _decimal_text(x::Real; digits::Union{Nothing,Int} = nothing)
    y = digits === nothing || abs(x) >= 1e15 ? Float64(x) : round(Float64(x); digits)   # past 1e15 a Float64 has no decimals
    isfinite(y) || throw(ArgumentError("$x is not a finite number"))
    y == 0 && return "0"
    isinteger(y) && abs(y) < 2.0^53 && return string(Int64(y))
    s = string(y)
    i = findfirst('e', s)
    i === nothing && return endswith(s, ".0") ? s[1:end-2] : s
    m, e = s[1:i-1], parse(Int, s[i+1:end])
    neg = startswith(m, '-')
    neg && (m = m[2:end])
    p = something(findfirst('.', m), length(m) + 1)
    ds = replace(m, "." => "")
    point = p - 1 + e                       # the digits before the point
    t = point <= 0 ? "0." * "0"^(-point) * ds :
        point >= length(ds) ? ds * "0"^(point - length(ds)) : ds[1:point] * "." * ds[point+1:end]
    occursin('.', t) && (t = rstrip(rstrip(t, '0'), '.'))
    return neg ? "-" * t : String(t)
end

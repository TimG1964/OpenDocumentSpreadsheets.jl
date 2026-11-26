# Reading content.xml only as far as one sheet (phase 3). All sheets share content.xml, so a
# one-shot read of the first sheet (`readtable`, `readdata`) would otherwise inflate them
# all. The inflated bytes are walked tag by tag as they arrive (D-047): each `<` is found
# with `findnext` (memchr), and only `table:table` start and end tags are told apart, with
# their nesting, so that a table inside a sheet doesn't end it. Comments, CDATA and
# processing instructions are stepped over. Inflating stops at the end tag that closes the
# wanted sheet. The prefix is everything the readers need: the styles come before the
# body, and the sheet index ends cleanly at the end of the data. A sheet that isn't found
# makes the whole part be read instead.

mutable struct _SheetFinder
    want_name::Union{Nothing,String}
    want_index::Int
    scan::Int          # where to look for the next `<`
    count::Int         # sheets seen
    depth::Int         # table:table elements open at `scan`
    found::Bool        # inside the wanted sheet (from depth 1)
end

const _TABLE_TAG = Vector{UInt8}("table:table")
const _NAME_RX = r"table:name\s*=\s*(?:\"([^\"]*)\"|'([^']*)')"

@inline _is_space_or_gt(b::UInt8) = b == UInt8(' ') || b == UInt8('\t') || b == UInt8('\n') || b == UInt8('\r') || b == UInt8('>')

# Whether `v` has `lit` at `i` (false when it runs past `n`).
@inline function _bytes_at(v, i::Int, n::Int, lit::Vector{UInt8})
    i + length(lit) - 1 <= n || return false
    @inbounds for k in eachindex(lit)
        v[i+k-1] == lit[k] || return false
    end
    return true
end

# The index after the terminator `lit` searched from `i`, or 0 if it hasn't arrived yet.
function _after_terminator(v, i::Int, n::Int, lit::Vector{UInt8})
    r = findnext(lit, view(v, 1:n), i)
    return r === nothing ? 0 : last(r) + 1
end

const _PI_END = Vector{UInt8}("?>")
const _COMMENT_START = Vector{UInt8}("<!--")
const _COMMENT_END = Vector{UInt8}("-->")
const _CDATA_START = Vector{UInt8}("<![CDATA[")
const _CDATA_END = Vector{UInt8}("]]>")

# Walks the bytes from `f.scan` to `n`. Returns the index of the `>` that closes the wanted
# sheet, or `nothing` to wait for more data.
function _find_sheet_end!(f::_SheetFinder, data::Vector{UInt8}, n::Int)
    v = view(data, 1:n)                                  # only what has arrived
    i = f.scan
    while true
        p = findnext(==(UInt8('<')), v, i)
        p === nothing && (f.scan = n + 1; return nothing)
        p + 14 > n && (f.scan = p; return nothing)          # the tag may be cut: wait
        @inbounds b = data[p+1]
        if b == UInt8('t') && _bytes_at(data, p + 1, n, _TABLE_TAG) && _is_space_or_gt(@inbounds data[p+12])
            gt = findnext(==(UInt8('>')), v, p)
            gt === nothing && (f.scan = p; return nothing)
            empty = @inbounds data[gt-1] == UInt8('/')
            if f.depth == 0
                f.count += 1
                if f.want_name === nothing
                    f.found = f.count == f.want_index
                else
                    m = match(_NAME_RX, String(data[p:gt]))
                    name = m === nothing ? "" : XML.unescape(something(m.captures[1], m.captures[2]))
                    f.found = name == f.want_name
                end
                f.found && empty && return gt                # the wanted sheet is `<table:table …/>`
            end
            empty || (f.depth += 1)
            i = gt + 1
        elseif b == UInt8('/') && _bytes_at(data, p + 2, n, _TABLE_TAG) && @inbounds data[p+13] == UInt8('>')
            f.depth = max(0, f.depth - 1)
            f.depth == 0 && f.found && return p + 13
            i = p + 14
        elseif b == UInt8('?')
            e = _after_terminator(data, p + 2, n, _PI_END)
            e == 0 && (f.scan = p; return nothing)
            i = e
        elseif b == UInt8('!') && _bytes_at(data, p, n, _COMMENT_START)
            e = _after_terminator(data, p + 4, n, _COMMENT_END)
            e == 0 && (f.scan = p; return nothing)
            i = e
        elseif b == UInt8('!') && _bytes_at(data, p, n, _CDATA_START)
            e = _after_terminator(data, p + 9, n, _CDATA_END)
            e == 0 && (f.scan = p; return nothing)
            i = e
        else
            i = p + 1
        end
    end
end

"""
    content_through_sheet(c::ODFContainer, sheet) -> String

content.xml inflated only as far as the end of `sheet` (a name or a 1-based number), or the
whole document when that can't be told (a flat document, or a sheet not found by its exact
name).

The walk matches `table:table` as written. When the prefix read has a namespace prefix other
than the usual ones, it may have stopped in the wrong place, and the whole part is
read instead, with the usual prefixes.
"""
function content_through_sheet(c::ODFContainer, sheet::Union{AbstractString,Integer})
    c.zip === nothing && return c.flat
    f = sheet isa Integer ? _SheetFinder(nothing, Int(sheet), 1, 0, 0, false) :
                            _SheetFinder(SheetCore.unquoteit(String(sheet)), 0, 1, 0, 0, false)
    # (want_name, want_index, scan, count, depth, found)
    s = readentry_prefix((data, n) -> _find_sheet_end!(f, data, n), c.zip, "content.xml")
    return _ns_usual(s) ? s : read_part_text(c, "content.xml")
end

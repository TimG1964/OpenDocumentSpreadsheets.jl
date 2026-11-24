# Text in LibreOffice's order (phase 6 step 9; F-072): its collator, ICU's for the root locale, as
# its sort and its filters' comparisons use it; and its natural sort.
#
# Near enough to the Unicode Collation Algorithm for spreadsheet text, without its tables (experiment
# 037 parts A and C): each character is a collation element of three weights.
#   - primary: spaces, then punctuation and symbols in the root order, currency signs, digits by value,
#     then letters: Latin, Greek, Cyrillic, other scripts, Hangul, kana, Han. ß, æ, œ expand to two
#     letters, ø, đ, ł, ð are o, d, l with a mark; ı, ŋ, ʒ, þ are letters of their own.
#   - secondary: accents (acute, grave, breve, circumflex, caron, ring, diaeresis, …, in that order).
#   - tertiary: lower case before upper case; ordinary before full-width before other compatibility
#     forms (superscripts, ligatures); hiragana before katakana.
# Compatibility forms are decomposed (ﬁ is fi, ™ TM, ½ 1⁄2). Without case sensitivity LibreOffice
# compares primary and secondary weights, with it all three.

const _LO_SYMBOLS = collect("_-‐‑‒–—―,;:!¡?¿.·'‘’‚‛‹›\"“”„‟«»()[]{}§¶@*/\\&#%‰†‡•`´˜^¯˘˙¨˚˝¸˛°©®+±÷×<=>¬|¦~")
const _LO_CURRENCY = collect("¤¢\$£¥₣₤₦₩₪₫€₭₮₱₲₴₵₹₺₽₿")
const _LO_SYM_INDEX = Dict{Char,Int}(c => i for (i, c) in enumerate(_LO_SYMBOLS))
const _LO_CUR_INDEX = Dict{Char,Int}(c => i for (i, c) in enumerate(_LO_CURRENCY))

# Accents' secondary weights, in the root order; others after them.
const _LO_MARKS = Dict{Char,Int}('́' => 1, '̀' => 2, '̆' => 3, '̂' => 4, '̌' => 5, '̊' => 6,
    '̈' => 7, '̋' => 8, '̃' => 9, '̇' => 10, '̧' => 12, '̨' => 13, '̄' => 14)
_lo_mark_weight(c::Char) = get(_LO_MARKS, c, 20 + Int(UInt32(c) % 40))

# Letters that are others with a mark, or two letters (lower case), and their secondary weight.
const _LO_EXPANSIONS = Dict{Char,Tuple{String,Int}}('ß' => ("ss", 0x200), 'æ' => ("ae", 0x200), 'œ' => ("oe", 0x200),
    'ĳ' => ("ij", 0), 'ø' => ("o", 0x300), 'đ' => ("d", 0x300), 'ð' => ("d", 0x301), 'ł' => ("l", 0x300),
    'ħ' => ("h", 0x300), 'ŧ' => ("t", 0x300))
# Latin letters of their own, after their neighbour: ı after i, ŋ after n, ʒ and þ after z.
const _LO_LATIN_EXTRA = Dict{Char,Int}('ı' => 4 * 8 + 2, 'ŋ' => 4 * 13 + 2, 'ʒ' => 4 * 25 + 2, 'þ' => 4 * 25 + 3)

const _Z_SPACE = 1; const _Z_SYM = 2; const _Z_CUR = 3; const _Z_DIG = 4; const _Z_LATIN = 5; const _Z_GREEK = 6
const _Z_CYRILLIC = 7; const _Z_OTHER = 8; const _Z_HANGUL = 9; const _Z_KANA = 10; const _Z_HAN = 11
_lo_prim(z::Int, s::Integer) = (Int64(z) << 32) + Int64(s)

# A collation element: (primary, secondary, tertiary).
const _CollElem = NTuple{3,Int64}

# The value of a decimal digit of a script LibreOffice reads as one (-1: none).
function _lo_digit(c::Char)
    u = UInt32(c)
    0x30 <= u <= 0x39 && return Int(u - 0x30)
    for z in (0x0660, 0x06F0, 0x07C0, 0x0966, 0x09E6, 0x0A66, 0x0AE6, 0x0B66, 0x0BE6, 0x0C66, 0x0CE6, 0x0D66, 0x0E50, 0x0ED0, 0x0F20, 0x1040, 0x17E0, 0x1810)
        z <= u <= z + 9 && return Int(u - z)
    end
    return -1
end

_lo_is_mark(c::Char) = !isascii(c) && isempty(Unicode.normalize(string(c); stripmark = true))

function _lo_letter_prim(l::Char)
    u = UInt32(l)
    'a' <= l <= 'z' && return (_lo_prim(_Z_LATIN, 4 * (u - 0x61) + 1), 0)
    x = get(_LO_LATIN_EXTRA, l, 0)
    x > 0 && return (_lo_prim(_Z_LATIN, x), 0)
    0x0370 <= u <= 0x03FF && return (_lo_prim(_Z_GREEK, u == 0x03C2 ? 0x03C3 : u), 0)     # final sigma is sigma
    0x0400 <= u <= 0x052F && return (_lo_prim(_Z_CYRILLIC, u), 0)
    (0x1100 <= u <= 0x11FF || 0x3130 <= u <= 0x318F || 0xAC00 <= u <= 0xD7AF) && return (_lo_prim(_Z_HANGUL, u), 0)
    0x3041 <= u <= 0x3096 && return (_lo_prim(_Z_KANA, u), 0)
    0x30A1 <= u <= 0x30F6 && return (_lo_prim(_Z_KANA, u - 0x60), 1)                       # katakana: hiragana's, after it
    (0x3400 <= u <= 0x4DBF || 0x4E00 <= u <= 0x9FFF || 0xF900 <= u <= 0xFAFF || 0x20000 <= u <= 0x3FFFF) &&
        return (_lo_prim(_Z_HAN, u), 0)
    (u < 0x0250 || 0x1E00 <= u <= 0x1EFF) && return (_lo_prim(_Z_LATIN, 200 + u), 0)
    return (_lo_prim(_Z_OTHER, u), 0)
end

# The elements of one character of a decomposition (`var`: its tertiary variant, 1 full-width, 2 other
# compatibility forms).
function _lo_elem!(out::Vector{_CollElem}, x::Char, var::Int)
    k = get(_LO_SYM_INDEX, x, 0)
    k > 0 && return push!(out, (_lo_prim(_Z_SYM, k), 0, var))
    k = get(_LO_CUR_INDEX, x, 0)
    k > 0 && return push!(out, (_lo_prim(_Z_CUR, k), 0, var))
    isspace(x) && return push!(out, (_lo_prim(_Z_SPACE, x == '\t' ? 0 : 1), 0, var + (x == ' ' ? 0 : 2)))
    v = _lo_digit(x)
    v >= 0 && return push!(out, (_lo_prim(_Z_DIG, v), 0, var))
    if isletter(x)
        t = (isuppercase(x) ? 8 : 2) + var
        l = lowercase(x)
        e = get(_LO_EXPANSIONS, l, nothing)
        if e !== nothing
            for (i, y) in enumerate(e[1])
                p, _ = _lo_letter_prim(y)
                push!(out, (p, i == 1 ? e[2] : 0, t + (e[2] == 0 ? 2 : 0)))
            end
            return out
        end
        p, dt = _lo_letter_prim(l)
        return push!(out, (p, 0, t + dt))
    end
    isnumeric(x) && return push!(out, (_lo_prim(_Z_DIG, 1000 + UInt32(x)), 0, var))
    iscntrl(x) && return out                                                    # ignorable
    return push!(out, (_lo_prim(_Z_SYM, 10_000 + UInt32(x)), 0, var))
end

function _lo_char!(out::Vector{_CollElem}, ch::Char)
    if isascii(ch)
        return _lo_elem!(out, ch, 0)
    end
    k = get(_LO_SYM_INDEX, ch, 0)                       # symbols before decomposing (´ is not a space and a mark)
    k > 0 && return push!(out, (_lo_prim(_Z_SYM, k), 0, 0))
    k = get(_LO_CUR_INDEX, ch, 0)
    k > 0 && return push!(out, (_lo_prim(_Z_CUR, k), 0, 0))
    haskey(_LO_EXPANSIONS, lowercase(ch)) && return _lo_elem!(out, ch, 0)
    s = string(ch)
    d = Unicode.normalize(s, :NFKD)
    var = d == Unicode.normalize(s, :NFD) ? 0 : (0xFF01 <= UInt32(ch) <= 0xFFEE ? 1 : 2)
    for x in d
        if _lo_is_mark(x)
            if !isempty(out)
                p, sec, t = out[end]
                out[end] = (p, sec * 64 + _lo_mark_weight(x), t)
            end
        else
            _lo_elem!(out, x, var)
        end
    end
    return out
end

"""
    _lo_coll_key(s) -> Vector{_CollElem}

The collation elements of `s`, as LibreOffice's collator weighs them (see the top of this file).
"""
function _lo_coll_key(s::AbstractString)
    out = _CollElem[]
    for ch in s
        _lo_char!(out, ch)
    end
    return out
end

# Two keys compared: -1, 0 or 1; `cs` compares case (the tertiary weights) too.
function _lo_key_cmp(a::Vector{_CollElem}, b::Vector{_CollElem}, cs::Bool)
    n = min(length(a), length(b))
    for i in 1:n
        x = a[i][1]; y = b[i][1]
        x == y || return x < y ? -1 : 1
    end
    length(a) == length(b) || return length(a) < length(b) ? -1 : 1
    for lvl in 2:(cs ? 3 : 2), i in 1:n
        x = a[i][lvl]; y = b[i][lvl]
        x == y || return x < y ? -1 : 1
    end
    return 0
end

"""
    _lo_collate(a, b, cs) -> Int

Text `a` against `b` in LibreOffice's order: -1, 0 or 1; `cs`: case-sensitive.
"""
_lo_collate(a::AbstractString, b::AbstractString, cs::Bool) = a == b ? 0 : _lo_key_cmp(_lo_coll_key(a), _lo_coll_key(b), cs)

#
# Natural sort (LibreOffice's, `table:embedded-number-behavior="double"`; F-072)
#

# Text split as LibreOffice's natural sort splits it: the text before its first digit, the number
# there (digits, a decimal point and digits, an exponent; a number in other digits counts as 0), and
# the rest, split again. `rest[i]` is the text from part i on, for comparing it whole.
struct _NatKey
    pre::Vector{Vector{_CollElem}}
    num::Vector{Float64}
    rest::Vector{Vector{_CollElem}}             # one more than the parts: the text after the last number
end

_lo_nat_digit(c::Char) = _lo_digit(c) >= 0 || '０' <= c <= '９' || c in "⁰¹²³⁴⁵⁶⁷⁸⁹₀₁₂₃₄₅₆₇₈₉"

function _lo_nat_key(s::AbstractString)
    pre = Vector{_CollElem}[]
    num = Float64[]
    rest = Vector{_CollElem}[]
    t = String(s)
    while true
        push!(rest, _lo_coll_key(t))
        i = findfirst(_lo_nat_digit, t)
        i === nothing && break
        j = i
        if isascii(t[i])
            m = match(r"^[0-9]+(?:\.[0-9]*)?(?:[eE][+-]?[0-9]+)?", SubString(t, i))
            v = parse(Float64, m.match)
            j = prevind(t, i + ncodeunits(m.match))
        else
            v = 0.0
            while (k = nextind(t, j)) <= ncodeunits(t) && _lo_nat_digit(t[k]) && !isascii(t[k])
                j = k
            end
        end
        push!(pre, _lo_coll_key(SubString(t, 1, prevind(t, i))))
        push!(num, v)
        t = String(SubString(t, nextind(t, j)))
    end
    return _NatKey(pre, num, rest)
end

# LibreOffice's natural comparison: prefixes by the collator, then numbers by value, then the rest
# in the same way; text without a number (on either side) by the collator, whole.
function _lo_nat_cmp(a::_NatKey, b::_NatKey, cs::Bool)
    i = 1
    while true
        (i > length(a.num) || i > length(b.num)) && return _lo_key_cmp(a.rest[i], b.rest[i], cs)
        c = _lo_key_cmp(a.pre[i], b.pre[i], cs)
        c == 0 || return c
        a.num[i] == b.num[i] || return a.num[i] < b.num[i] ? -1 : 1
        i += 1
    end
end

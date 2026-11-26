# OpenFormula: a tokenizer for the formulas ODF stores (`table:formula="of:=SUM([.A1:.B2];1)"`)
# and a renderer to LibreOffice's UI notation (`=SUM(A1:B2,1)`), for `getFormula` (D-018).
#
# The rules come from LibreOffice 26.8.3 itself (experiment 008, F-024, F-025):
#   - references lose their brackets and a leading "." (this sheet): [.A1] → A1,
#     [Plain.A1:'My sheet'.B2] → Plain.A1:'My sheet'.B2, [.A:.A] → A:A
#   - function arguments ";" → ","; in inline arrays ";" → "," and "|" → ";"
#     (LibreOffice's en-US separators)
#   - upper-case function names lose COM.MICROSOFT., ORG.OPENOFFICE., ORG.LIBREOFFICE. and
#     LEGACY., with a few renames; LET parameters lose "_xlpm."; names LibreOffice does not
#     know are stored in lower case and shown as they are
#   - everything else (strings, numbers, error literals, operators, spaces) is kept
# The tokens keep the source text exactly, so that phase 5 can shift references with them.

@enum FormulaTokenKind::UInt8 begin
    FT_REF        # a bracketed reference: [.A1], ['My sheet'.$A$1:.B2], ['url'#$S.A1]
    FT_FUNC       # a function name (followed by "(")
    FT_NAME       # any other identifier: a named range or expression, a LET parameter
    FT_NUMBER
    FT_STRING     # with its quotes
    FT_ERROR      # #N/A, #REF!, ...
    FT_OP         # + - * / ^ & = <> < > <= >= % ! ~ :
    FT_SEP        # ; between function arguments, or between array columns
    FT_ROWSEP     # | between array rows
    FT_OPEN       # (
    FT_CLOSE      # )
    FT_ARRAY_OPEN # {
    FT_ARRAY_CLOSE # }
    FT_SPACE
    FT_OTHER      # anything else, kept as it is (e.g. LibreOffice's bare A1 in A1:#REF!)
end

"""
    FormulaToken(kind, text)

A token of an OpenFormula expression, with its exact source text.
"""
struct FormulaToken
    kind::FormulaTokenKind
    text::SubString{String}
end

const _ERROR_LITERALS = ("#NULL!", "#DIV/0!", "#VALUE!", "#REF!", "#NAME?", "#NUM!", "#N/A")

_is_ident_start(c::Char) = isletter(c) || c == '_' || c == '\\'
_is_ident_char(c::Char) = isletter(c) || isdigit(c) || c == '_' || c == '.' || c == '\\'

"""
    tokenize_formula(s::AbstractString) -> Vector{FormulaToken}

Split an OpenFormula expression (without its `of:=` prefix) into tokens. Every character of
`s` belongs to exactly one token, so joining the token texts gives `s` back.
"""
function tokenize_formula(s::AbstractString)
    s = String(s)
    toks = FormulaToken[]
    i = firstindex(s)
    n = lastindex(s)
    push(kind, a, b) = push!(toks, FormulaToken(kind, SubString(s, a, b)))
    while i <= n
        c = s[i]
        if c == '['
            # to the matching ']', skipping quoted parts ('...' with '' inside)
            j = i
            inq = false
            k = nextind(s, i)
            while k <= n
                ch = s[k]
                if ch == '\''
                    inq = !inq
                elseif ch == ']' && !inq
                    break
                end
                k = nextind(s, k)
            end
            k > n && (push(FT_OTHER, i, n); break)
            push(FT_REF, j, k)
            i = nextind(s, k)
        elseif c == '"'
            k = nextind(s, i)
            while k <= n
                if s[k] == '"'
                    k2 = nextind(s, k)
                    if k2 <= n && s[k2] == '"'
                        k = nextind(s, k2)
                        continue
                    end
                    break
                end
                k = nextind(s, k)
            end
            k = min(k, n)
            push(FT_STRING, i, k)
            i = nextind(s, k)
        elseif c == '#'
            matched = false
            for e in _ERROR_LITERALS
                if startswith(SubString(s, i), e)
                    push(FT_ERROR, i, i + ncodeunits(e) - 1)
                    i += ncodeunits(e)
                    matched = true
                    break
                end
            end
            matched || (push(FT_OTHER, i, i); i = nextind(s, i))
        elseif isdigit(c) || (c == '.' && i < n && isdigit(s[nextind(s, i)]))
            k = i
            while k <= n && (isdigit(s[k]) || s[k] == '.')
                k = nextind(s, k)
            end
            if k <= n && (s[k] == 'e' || s[k] == 'E')
                k2 = nextind(s, k)
                k2 <= n && (s[k2] == '+' || s[k2] == '-') && (k2 = nextind(s, k2))
                if k2 <= n && isdigit(s[k2])
                    k = k2
                    while k <= n && isdigit(s[k])
                        k = nextind(s, k)
                    end
                end
            end
            push(FT_NUMBER, i, prevind(s, k))
            i = k
        elseif _is_ident_start(c)
            k = i
            while k <= n && _is_ident_char(s[k])
                k = nextind(s, k)
            end
            push(k <= n && s[k] == '(' ? FT_FUNC : FT_NAME, i, prevind(s, k))
            i = k
        elseif c == ' ' || c == '\t' || c == '\n' || c == '\r'
            k = i
            while k <= n && s[k] in (' ', '\t', '\n', '\r')
                k = nextind(s, k)
            end
            push(FT_SPACE, i, prevind(s, k))
            i = k
        elseif c == '<' || c == '>'
            k = nextind(s, i)
            if k <= n && (s[k] == '=' || (c == '<' && s[k] == '>'))
                push(FT_OP, i, k); i = nextind(s, k)
            else
                push(FT_OP, i, i); i = k
            end
        elseif c in ('+', '-', '*', '/', '^', '&', '=', '%', '!', '~', ':')
            push(FT_OP, i, i); i = nextind(s, i)
        elseif c == ';'
            push(FT_SEP, i, i); i = nextind(s, i)
        elseif c == '|'
            push(FT_ROWSEP, i, i); i = nextind(s, i)
        elseif c == '('
            push(FT_OPEN, i, i); i = nextind(s, i)
        elseif c == ')'
            push(FT_CLOSE, i, i); i = nextind(s, i)
        elseif c == '{'
            push(FT_ARRAY_OPEN, i, i); i = nextind(s, i)
        elseif c == '}'
            push(FT_ARRAY_CLOSE, i, i); i = nextind(s, i)
        else
            push(FT_OTHER, i, i); i = nextind(s, i)
        end
    end
    return toks
end

# Stored (ODFF) function names whose UI name is not the name minus its prefix (F-025).
const _ODFF_UI_RENAMES = Dict(
    "COM.MICROSOFT.CEILING" => "CEILING.XCL",
    "COM.MICROSOFT.FLOOR" => "FLOOR.XCL",
    "ORG.OPENOFFICE.CONVERT" => "CONVERT_OOO",
    "BINOM.DIST.RANGE" => "B",
    "FDIST" => "F.DIST",
    "FINV" => "F.INV",
)
const _ODFF_PREFIXES = ("COM.MICROSOFT.", "ORG.OPENOFFICE.", "ORG.LIBREOFFICE.", "LEGACY.")

"""
    ui_function_name(name) -> String

The name LibreOffice shows for a stored (ODFF) function name: from LibreOffice's own map
(experiment 010), else by dropping a known prefix.
"""
function ui_function_name(name::AbstractString)
    any(islowercase, name) && return String(name)     # unknown to LibreOffice: as stored
    r = get(ODFF_TO_UI, name, nothing)
    r === nothing || return r
    r = get(_ODFF_UI_RENAMES, name, nothing)
    r === nothing || return r
    for p in _ODFF_PREFIXES
        startswith(name, p) && ncodeunits(name) > ncodeunits(p) && return String(SubString(name, ncodeunits(p) + 1))
    end
    return String(name)
end

_ui_name(name::AbstractString) = startswith(name, "_xlpm.") ? String(SubString(name, 7)) : String(name)

# A bracketed reference in UI notation: without the brackets, and without the "." that
# marks "this sheet" at the start of each end of a range.
function ui_reference(ref::AbstractString)
    inner = SubString(ref, nextind(ref, firstindex(ref)), prevind(ref, lastindex(ref)))
    ends = SheetCore._split_unquoted(inner, (':',))
    return join((startswith(e, '.') ? e[2:end] : e for e in ends), ':')
end

"""
    render_ui_formula(expr::AbstractString) -> String

An OpenFormula expression (`=SUM([.A1:.B2];1)`, the `of:` prefix removed) in LibreOffice's
UI notation (`=SUM(A1:B2,1)`), as `=FORMULA()` shows it with the en-US separators.
"""
function render_ui_formula(expr::AbstractString)
    io = IOBuffer()
    depth_array = 0
    for t in tokenize_formula(expr)
        k = t.kind
        if k === FT_REF
            print(io, ui_reference(t.text))
        elseif k === FT_FUNC
            print(io, ui_function_name(_ui_name(t.text)))
        elseif k === FT_NAME
            print(io, _ui_name(t.text))
        elseif k === FT_SEP
            print(io, ',')
        elseif k === FT_ROWSEP
            print(io, depth_array > 0 ? ';' : '|')
        elseif k === FT_ARRAY_OPEN
            depth_array += 1; print(io, '{')
        elseif k === FT_ARRAY_CLOSE
            depth_array = max(0, depth_array - 1); print(io, '}')
        else
            print(io, t.text)
        end
    end
    return String(take!(io))
end

# A stored formula without its namespace prefix: "of:=1+1" → "=1+1". A formula without a
# prefix is returned as it is.
function _strip_formula_prefix(f::AbstractString)
    m = match(r"^[A-Za-z][A-Za-z0-9_.-]*:(?==)", f)
    m === nothing && return String(f)
    return String(SubString(f, ncodeunits(m.match) + 1))
end

"""
    getFormula(sheet, ref; raw=false) -> Union{String, Nothing}
    getFormula(sheet, row, col; raw=false)
    getFormula(xf, "Sheet1.A1"; raw=false)

The formula of a cell, as LibreOffice shows it (`"=SUM(A1:B2,1)"`, `"='My sheet'.A1*2"`),
or `nothing` if the cell has none. With `raw=true`, the formula as stored in the file
(`"of:=SUM([.A1:.B2];1)"`).

The UI notation follows LibreOffice with its en-US settings: `,` between function arguments
and between the columns of an inline array, `;` between its rows. Formulas written in
another namespace than OpenFormula (such as `msoxl:`) lose their prefix and are otherwise
returned unchanged.
"""
function getFormula(ws::Worksheet, ref; raw::Bool = false)
    c = getcell(ws, ref)
    c isa AbstractCell || throw(ODSError("getFormula reads one cell; `$ref` is a range."))
    return _formula_text(c, raw)
end
getFormula(ws::Worksheet, row::Integer, col::Integer; raw::Bool = false) = _formula_text(getcell(ws, row, col), raw)
function getFormula(xf::ODSFile, ref::AbstractString; raw::Bool = false)
    c = getcell(xf, ref)
    c isa AbstractCell || throw(ODSError("getFormula reads one cell; `$ref` is a range."))
    return _formula_text(c, raw)
end

_formula_text(::EmptyCell, ::Bool) = nothing
function _formula_text(c::Cell, raw::Bool)
    f = c.formula
    f === nothing && return nothing
    raw && return f
    body = _strip_formula_prefix(f)
    ns = SubString(f, 1, max(0, ncodeunits(f) - ncodeunits(body) - 1))
    (ns == "" || ns == "of" || ns == "oooc") || return body   # another syntax: as stored
    return render_ui_formula(body)
end

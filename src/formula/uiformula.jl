# LibreOffice's function names in both directions, from its own opcode maps (experiment 010,
# F-027): `data/odff-ui.tsv`, ODFF (stored) name → UI name. And the conversion from the UI
# notation to OpenFormula for `setFormula` (D-025), the reverse of `render_ui_formula`.

const _ODFF_UI_FILE = joinpath(@__DIR__, "data", "odff-ui.tsv")
include_dependency(_ODFF_UI_FILE)

const ODFF_TO_UI, UI_TO_ODFF = let
    fwd = Dict{String,String}()
    rev = Dict{String,String}()
    for (i, line) in enumerate(eachline(_ODFF_UI_FILE))
        i == 1 && continue
        parts = split(line, '\t')
        length(parts) == 2 || continue
        o, u = String(parts[1]), String(parts[2])
        (isempty(o) || isempty(u)) && continue
        fwd[o] = u
        # writing: the plain or namespaced ODFF name rather than the add-in's programmatic one
        if !haskey(rev, u) || (startswith(rev[u], "COM.SUN.STAR.") && !startswith(o, "COM.SUN.STAR."))
            rev[u] = o
        end
    end
    fwd, rev
end

"""
    odff_function_name(ui_name) -> String

The name OpenFormula stores for a function LibreOffice shows as `ui_name` (`IFS` →
`COM.MICROSOFT.IFS`, `WEEKS` → `ORG.OPENOFFICE.WEEKS`). Names are matched without regard to
case; an unknown name is returned as it was typed.
"""
function odff_function_name(name::AbstractString)
    return get(UI_TO_ODFF, uppercase(name), String(name))
end

# LET and LAMBDA parameters are stored with the prefix `_xlpm.` (F-025): `LET(x,1,x)` →
# `COM.MICROSOFT.LET(_xlpm.x;1;_xlpm.x)`. `f` is OpenFormula with `;` separators.
function _prefix_parameters(f::String)
    for fname in ("COM.MICROSOFT.LET(", "COM.MICROSOFT.LAMBDA(")
        start = 1
        while (r = findnext(fname, f, start)) !== nothing
            open_at = last(r)                       # the "("
            args, close_at = _split_args(f, open_at)
            close_at === nothing && break
            params = fname == "COM.MICROSOFT.LET(" ? args[1:2:end-1] : args[1:end-1]
            names = Set(strip(a) for a in params if occursin(r"^\s*[\p{L}_][\p{L}\p{N}_.]*\s*$", a) && !startswith(strip(a), "_xlpm."))
            inner = SubString(f, nextind(f, open_at), prevind(f, close_at))
            newinner = isempty(names) ? String(inner) : _rename_names(String(inner), names)
            f = string(SubString(f, 1, open_at), newinner, SubString(f, close_at))
            start = open_at + 1
        end
    end
    return f
end

# The top-level arguments of the call whose "(" is at `open_at`, and the index of its ")".
function _split_args(f::String, open_at::Int)
    args = String[]
    depth = 0; q = '\0'; buf = IOBuffer()
    i = nextind(f, open_at)
    while i <= lastindex(f)
        c = f[i]
        if q != '\0'
            c == q && (q = '\0')
        elseif c == '"' || c == '\''
            q = c
        elseif c in ('(', '[', '{')
            depth += 1
        elseif c in (')', ']', '}')
            if depth == 0 && c == ')'
                push!(args, String(take!(buf)))
                return args, i
            end
            depth -= 1
        elseif c == ';' && depth == 0
            push!(args, String(take!(buf)))
            i = nextind(f, i)
            continue
        end
        print(buf, c)
        i = nextind(f, i)
    end
    return args, nothing
end

# `s` with each standalone identifier in `names` (outside strings and references) prefixed
# with `_xlpm.`.
function _rename_names(s::String, names)
    io = IOBuffer()
    for t in tokenize_formula(s)
        if t.kind === FT_NAME && t.text in names
            print(io, "_xlpm.", t.text)
        else
            print(io, t.text)
        end
    end
    return String(take!(io))
end

#
# UI notation → OpenFormula
#

# A reference in UI notation: an optional external file, an optional sheet, and a cell,
# column or row, possibly a range whose second end may name a sheet too.
const _SHEET_RX = raw"(?:\$?(?:'(?:[^']|'')*'|[\p{L}_][\p{L}\p{N}_]*)\.)"
const _CELL_RX = raw"\$?[A-Za-z]{1,3}\$?[0-9]+"
const _COL_RX = raw"\$?[A-Za-z]{1,3}"
const _ROW_RX = raw"\$?[0-9]+"
const _EXT_RX = raw"(?:'(?:[^']|'')*'#)"
const _UI_REF_RX = Regex("^(?:" *
    "$(_EXT_RX)?$(_SHEET_RX)?$(_CELL_RX)(?::$(_SHEET_RX)?$(_CELL_RX))?" * "|" *
    "$(_EXT_RX)?$(_SHEET_RX)?$(_COL_RX):$(_SHEET_RX)?$(_COL_RX)" * "|" *
    "$(_EXT_RX)?$(_SHEET_RX)?$(_ROW_RX):$(_SHEET_RX)?$(_ROW_RX)" * ")")

# A UI reference as OpenFormula: in brackets, each end without a sheet marked with ".".
function _odf_reference(ref::AbstractString)
    ends = SheetCore._split_unquoted(ref, (':',))
    parts = map(ends) do e
        hassheet = occursin(r"^(?:'(?:[^']|'')*'#)?\$?(?:'(?:[^']|'')*'|[\p{L}_][\p{L}\p{N}_]*)\.", e) ||
                   occursin('#', e)
        hassheet ? e : "." * e
    end
    return "[" * join(parts, ':') * "]"
end

_is_name_char(c::Char) = isletter(c) || isdigit(c) || c == '_' || c == '.' || c == '\\'

"""
    ui_to_openformula(f::AbstractString) -> String

A formula in LibreOffice's UI notation (en-US separators), such as
`"=SUM(A1:B2,'My sheet'.C3)"`, as stored OpenFormula: `"of:=SUM([.A1:.B2];['My sheet'.C3])"`.
Function names get their ODFF names (experiment 010); `,` separates arguments and
array columns, `;` array rows.
"""
function ui_to_openformula(f::AbstractString)
    s = strip(String(f))
    startswith(s, "=") || throw(ODSError("A formula must start with `=`: got `$f`."))
    io = IOBuffer()
    print(io, "of:=")
    i = nextind(s, firstindex(s))
    n = lastindex(s)
    braces = 0
    while i <= n
        c = s[i]
        if c == '"'                                   # a string, with "" inside
            k = nextind(s, i)
            while k <= n
                if s[k] == '"'
                    k2 = nextind(s, k)
                    (k2 <= n && s[k2] == '"') || break
                    k = nextind(s, k2)
                else
                    k = nextind(s, k)
                end
            end
            print(io, SubString(s, i, min(k, n)))
            i = nextind(s, min(k, n))
            continue
        elseif c == '{'
            braces += 1; print(io, c)
        elseif c == '}'
            braces = max(0, braces - 1); print(io, c)
        elseif c == ','
            print(io, ';')
        elseif c == ';'
            print(io, braces > 0 ? '|' : ';')
        elseif c == '#'                               # an error literal, as it is
            m = match(r"^#(?:NULL!|DIV/0!|VALUE!|REF!|NAME\?|NUM!|N/A)", SubString(s, i))
            if m === nothing
                print(io, c)
            else
                print(io, m.match); i += ncodeunits(m.match); continue
            end
        elseif isdigit(c) || c == '$' || c == '\'' || isletter(c) || c == '_'
            rest = SubString(s, i)
            m = match(_UI_REF_RX, rest)
            if m !== nothing
                after = i + ncodeunits(m.match)
                nxt = after <= n ? s[after] : ' '
                # a reference must not run on into a name or a function call
                if !(_is_name_char(nxt) || nxt == '(') && !(isdigit(c) && !occursin(':', m.match))
                    print(io, _odf_reference(m.match))
                    i = after
                    continue
                end
            end
            if isdigit(c) || c == '.'
                m2 = match(r"^[0-9]*\.?[0-9]+(?:[eE][+-]?[0-9]+)?", rest)
                print(io, m2.match); i += ncodeunits(m2.match); continue
            end
            if isletter(c) || c == '_'
                k = i
                while k <= n && _is_name_char(s[k])
                    k = nextind(s, k)
                end
                name = SubString(s, i, prevind(s, k))
                if k <= n && s[k] == '('
                    print(io, odff_function_name(name))
                else
                    print(io, name)
                end
                i = k
                continue
            end
            print(io, c)
        else
            print(io, c)
        end
        i = nextind(s, i)
    end
    return _prefix_parameters(String(take!(io)))
end

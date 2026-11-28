# Data validation (phase 6 step 6, D-075): XLSX.jl's `addDataValidation`, `deleteDataValidation`,
# `getDataValidation` and `getDataValidations`, on LibreOffice's validations (F-061, F-068):
#   - a rule is a `table:content-validation` of the workbook's `table:content-validations` (before the
#     tables): its condition (`of:` forms for every type and operator), whether an empty cell is valid,
#     a list's drop-down, its base cell, and its help and error messages, as LibreOffice's import writes
#     XLSX.jl's
#   - a cell names its rule (`table:content-validation-name`); identical rules added share one name
#   - inserted cells take the validation of the line before them; a rule no cell uses is dropped on
#     save (LibreOffice also renumbers its rules then; names are kept here, D-075)
# Validations set or removed are blocks of cells by sheet (`Worksheet.valrects`), written by the cell
# writers; the file's rules and cells are read on first use (D-069). The API follows XLSX.jl 0.13.4
# (src/datavalidation.jl), MIT License, Copyright (c) 2018-2026 Felipe Noronha Tavares and other
# contributors: names, keywords, checks and messages, and the return shape. Excel's limits (no comma
# in a list item, 255 characters, 32-character titles) are not LibreOffice's, and are not kept.

# XLSX.jl's fields, then LibreOffice's own options (D-076).
const DataValidationInfo = NamedTuple{(:sheet, :range, :type, :operator, :formula1, :formula2, :allowBlank, :dropdown,
                                       :showInputMessage, :promptTitle, :prompt, :showErrorMessage, :errorTitle, :error, :errorStyle,
                                       :caseSensitive, :sortEntries),
    Tuple{String,Union{CellRange,NonContiguousRange},Symbol,Union{Nothing,Symbol},Union{Nothing,String},Union{Nothing,String},
          Bool,Bool,Bool,Union{Nothing,String},Union{Nothing,String},Bool,Union{Nothing,String},Union{Nothing,String},Symbol,
          Bool,Bool}}

const DV_TYPES = (:any, :whole, :decimal, :list, :date, :time, :textLength, :custom)
const DV_OPERATORS = (:between, :notBetween, :equal, :notEqual, :greaterThan, :lessThan, :greaterThanOrEqual, :lessThanOrEqual)
const DV_ERROR_STYLES = (:stop, :warning, :information)
const _DV_OP_TEXT = Dict(:equal => "=", :notEqual => "!=", :greaterThan => ">", :lessThan => "<",
                         :greaterThanOrEqual => ">=", :lessThanOrEqual => "<=")
const _DV_TEXT_OP = Dict(v => k for (k, v) in _DV_OP_TEXT)
const _DV_KIND = Dict(:whole => "whole-number", :decimal => "decimal-number", :date => "date", :time => "time")
const _DV_KIND_TYPE = Dict(v => k for (k, v) in _DV_KIND)

#
# Formulas: XLSX.jl's values, as the condition's OpenFormula (stored), and back
#

_dv_expr(::ODSFile, ::Nothing, ::String) = nothing
_dv_expr(::ODSFile, ::Bool, k::String) = throw(ODSError("`$k` can't be a Bool."))
# Numbers as LibreOffice writes them: whole ones without a point, others to 15 significant digits.
_dv_num(x::Real) = isinteger(x) && abs(x) < 1e15 ? string(Int64(x)) : string(round(Float64(x); sigdigits = 15))
_dv_expr(::ODSFile, v::Real, ::String) = _dv_num(v)
_dv_expr(xf::ODSFile, v::Dates.Date, ::String) = string(Dates.value(v - xf.null_date))
_dv_expr(xf::ODSFile, v::Dates.DateTime, ::String) =
    _dv_num(Dates.value(v - Dates.DateTime(xf.null_date)) / 86_400_000)
_dv_expr(::ODSFile, v::Dates.Time, ::String) = _dv_num(Dates.value(v) / 86_400_000_000_000)
function _dv_expr(::ODSFile, v::AbstractString, k::String)
    _check_xml_text(v)
    s = strip(v)
    startswith(s, '=') && (s = strip(s[nextind(s, 1):end]))
    isempty(s) && throw(ODSError("`$k` can't be empty."))
    # XLSX.jl's sheet separator in a plain reference (`Lists!$A$1:$A$4`): LibreOffice's is `.` (D-014)
    m = match(r"^('(?:[^']|'')+'|[^'!\s\"(),;]+)!(\$?[A-Za-z]{1,3}\$?\d+(?::\$?[A-Za-z]{1,3}\$?\d+)?)$", s)
    m === nothing || (s = "\$" * m.captures[1] * "." * m.captures[2])     # an absolute sheet, as the import writes it
    return String(SubString(ui_to_openformula("=" * s), 5))            # "of:=" dropped
end
_dv_expr(::ODSFile, v, k::String) =
    throw(ODSError("`$k` must be a number, a date or time, or a string holding a reference or formula. Got a $(typeof(v))."))

# A list's items as LibreOffice writes them: `"a";"b"`, with `""` for a quote.
function _dv_list(values::AbstractVector)
    isempty(values) && throw(ODSError("A list needs at least one item in `values`."))
    foreach(v -> _check_xml_text(string(v)), values)
    return join(("\"" * replace(string(v), "\"" => "\"\"") * "\"" for v in values), ';')
end

# A stored expression in LibreOffice's UI notation (as `getFormula` gives formulas).
_dv_ui(x::Union{Nothing,String}) = x === nothing ? nothing : String(SubString(render_ui_formula("=" * x), 2))

#
# Conditions
#

function _dv_condition(r::ValRule)
    t, a, b = r.type, r.formula1, r.formula2
    t === :any && return nothing
    t === :list && return "of:cell-content-is-in-list($a)"
    t === :custom && return "of:is-true-formula($a)"
    op = r.operator
    if t === :textLength
        op === :between && return "of:cell-content-text-length-is-between($a,$b)"
        op === :notBetween && return "of:cell-content-text-length-is-not-between($a,$b)"
        return "of:cell-content-text-length()" * _DV_OP_TEXT[op] * a
    end
    rest = op === :between ? "cell-content-is-between($a,$b)" : op === :notBetween ? "cell-content-is-not-between($a,$b)" :
           "cell-content()" * _DV_OP_TEXT[op] * a
    return "of:cell-content-is-$(_DV_KIND[t])() and " * rest
end

# The arguments of `s` split at commas outside quotes, brackets and parentheses.
function _dv_split(s::AbstractString)
    out = String[]; depth = 0; q = false; start = firstindex(s)
    for i in eachindex(s)
        c = s[i]
        if q
            c == '"' && (q = false)
        elseif c == '"'
            q = true
        elseif c in ('(', '[', '{')
            depth += 1
        elseif c in (')', ']', '}')
            depth -= 1
        elseif c == ',' && depth == 0
            push!(out, String(SubString(s, start, prevind(s, i)))); start = nextind(s, i)
        end
    end
    push!(out, String(SubString(s, start)))
    return out
end

# (type, operator, formula1, formula2) of a stored condition.
function _dv_parse_condition(cond::Union{Nothing,AbstractString})
    cond === nothing && return (:any, nothing, nothing, nothing)
    c = replace(String(cond), r"^(?:of|oooc|msoxl):" => "")
    (m = match(r"^cell-content-is-in-list\((.*)\)$"s, c)) === nothing || return (:list, nothing, String(m.captures[1]), nothing)
    (m = match(r"^is-true-formula\((.*)\)$"s, c)) === nothing || return (:custom, nothing, String(m.captures[1]), nothing)
    if (m = match(r"^cell-content-text-length-is-(not-)?between\((.*)\)$"s, c)) !== nothing
        args = _dv_split(m.captures[2])
        return (:textLength, m.captures[1] === nothing ? :between : :notBetween, args[1], get(args, 2, nothing))
    end
    if (m = match(r"^cell-content-text-length\(\)(>=|<=|!=|=|>|<)(.*)$"s, c)) !== nothing
        return (:textLength, _DV_TEXT_OP[m.captures[1]], String(m.captures[2]), nothing)
    end
    if (m = match(r"^cell-content-is-(whole-number|decimal-number|date|time)\(\) and (.*)$"s, c)) !== nothing
        t = _DV_KIND_TYPE[m.captures[1]]; rest = m.captures[2]
        if (n = match(r"^cell-content-is-(not-)?between\((.*)\)$"s, rest)) !== nothing
            args = _dv_split(n.captures[2])
            return (t, n.captures[1] === nothing ? :between : :notBetween, args[1], get(args, 2, nothing))
        end
        (n = match(r"^cell-content\(\)(>=|<=|!=|=|>|<)(.*)$"s, rest)) === nothing ||
            return (t, _DV_TEXT_OP[n.captures[1]], String(n.captures[2]), nothing)
    end
    return (:custom, nothing, c, nothing)                     # a form not modelled: as a custom formula
end

#
# A rule's XML (as LibreOffice's import writes XLSX.jl's, F-061)
#

function _dv_paragraphs(io::IO, s::Union{Nothing,String})
    s === nothing && return
    for line in split(replace(s, "\r\n" => "\n"), '\n')
        print(io, "<text:p>"); _escape_text(io, line); print(io, "</text:p>")
    end
end

function _rule_xml(name::String, r::ValRule, base::String)
    io = IOBuffer()
    print(io, "<table:content-validation table:name=\""); _escape_attr(io, name); print(io, '"')
    cond = _dv_condition(r)
    cond === nothing || (print(io, " table:condition=\""); _escape_attr(io, cond); print(io, '"'))
    r.type === :any || print(io, " table:allow-empty-cell=\"", r.allowBlank, '"')
    r.caseSensitive && print(io, " table:case-sensitive=\"true\"")
    r.type === :list && print(io, " table:display-list=\"", !r.dropdown ? "no" : r.sortEntries ? "sort-ascending" : "unsorted", '"')
    print(io, " table:base-cell-address=\""); _escape_attr(io, base); print(io, "\">")
    print(io, "<table:help-message")
    r.promptTitle === nothing || (print(io, " table:title=\""); _escape_attr(io, r.promptTitle); print(io, '"'))
    print(io, " table:display=\"", r.showInputMessage, '"')
    if r.prompt === nothing
        print(io, "/>")
    else
        print(io, '>'); _dv_paragraphs(io, r.prompt); print(io, "</table:help-message>")
    end
    if r.showErrorMessage
        print(io, "<table:error-message table:message-type=\"", r.errorStyle === :stop ? "stop" : r.errorStyle === :warning ? "warning" : "information", '"')
        r.errorTitle === nothing || (print(io, " table:title=\""); _escape_attr(io, r.errorTitle); print(io, '"'))
        print(io, " table:display=\"true\"")
        if r.error === nothing
            print(io, "/>")
        else
            print(io, '>'); _dv_paragraphs(io, r.error); print(io, "</table:error-message>")
        end
    end
    print(io, "</table:content-validation>")
    return String(take!(io))
end

_rule_base(a::AddedRule) = SheetCore.quoteit(a.sheet.name) * "." * string(SheetCore.encode_column_number(a.col), a.row)
_added_xml(a::AddedRule) = _rule_xml(a.name, a.rule, _rule_base(a))

#
# The file's rules (read on first use)
#

# A message element of a rule (`x`, its XML): its start tag and the text of its paragraphs, a line each.
function _rule_message(x::AbstractString, tag::String)
    m = match(Regex("<" * tag * "\\b[^>]*?(?:/>|>(.*?)</" * tag * ">)", "s"), x)
    m === nothing && return nothing
    st = SubString(m.match, 1, something(findfirst('>', m.match), ncodeunits(m.match)))
    body = something(m.captures[1], "")
    lines = String[]
    for p in eachmatch(r"<text:p\b[^>]*?(?:/>|>(.*?)</text:p>)"s, body)
        t = something(p.captures[1], "")
        t = replace(t, r"<text:s\s*/>" => " ", r"<text:s\s+text:c=\"\d+\"\s*/>" => z -> " "^_space_count(match(r"\d+", z).match),
                    r"<text:tab\s*/>" => "\t", r"<text:line-break\s*/>" => "\n", r"<[^>]*>" => "")
        push!(lines, XML.unescape(t))
    end
    return st, join(lines, '\n')
end

# The span of the content's `table:content-validations` element, if it comes before the first table.
function _rules_span(s::String)
    t = findfirst("<table:table ", s)
    lim = t === nothing ? ncodeunits(s) : first(t)
    i = findfirst("<table:content-validations", SubString(s, 1, lim))      # only before the tables
    i === nothing && return nothing
    j = findnext("</table:content-validations>", s, last(i))
    return j === nothing ? nothing : first(i):last(j)
end

const _RULE_RX = r"<table:content-validation\b[^>]*?(?:/>|>.*?</table:content-validation>)"s

function _file_rules(xf::ODSFile)
    v = xf.valedits
    v.file === nothing || return v.file
    out = FileRule[]
    if !isnewfile(xf)
        s = xf.content
        sp = _rules_span(s)
        if sp !== nothing
            pos = first(sp)
            while (rg = findnext(_RULE_RX, s, pos)) !== nothing && last(rg) <= last(sp)
                x = SubString(s, rg)
                tag = SubString(x, 1, something(findfirst('>', x), ncodeunits(x)))
                name = something(_tag_attr(tag, "table:name"), "")
                t, op, f1, f2 = _dv_parse_condition(_tag_attr(tag, "table:condition"))
                pt = nothing; pr = nothing; showin = true; et = nothing; er = nothing; showerr = false; style = :stop
                h = _rule_message(x, "table:help-message")
                if h !== nothing
                    pt = _tag_attr(h[1], "table:title"); showin = something(_tag_attr(h[1], "table:display"), "true") == "true"
                    pr = isempty(h[2]) ? nothing : h[2]
                end
                e = _rule_message(x, "table:error-message")
                if e !== nothing
                    et = _tag_attr(e[1], "table:title"); showerr = something(_tag_attr(e[1], "table:display"), "true") == "true"
                    er = isempty(e[2]) ? nothing : e[2]
                    mt = something(_tag_attr(e[1], "table:message-type"), "stop")
                    style = mt == "warning" ? :warning : mt == "information" ? :information : :stop
                end
                dl = something(_tag_attr(tag, "table:display-list"), "unsorted")
                rule = ValRule(t, op, f1, f2, something(_tag_attr(tag, "table:allow-empty-cell"), "true") == "true",
                               dl != "no", showin, pt, pr, showerr, et, er, style,
                               something(_tag_attr(tag, "table:base-cell-address"), ""),
                               _tag_attr(tag, "table:case-sensitive") == "true", dl == "sort-ascending")
                push!(out, FileRule(name, rg, rule))
                pos = nextind(s, last(rg))
            end
        end
    end
    v.file = out
    return out
end

function _rule_named(xf::ODSFile, name::AbstractString)
    for a in xf.valedits.added
        a.name == name && return a.rule
    end
    for f in _file_rules(xf)
        f.name == name && return _replayed(f.rule, xf.ops)
    end
    return nothing
end

# A file rule as it is now: its formulas' references replayed through the line and sheet operations
# since the file was read, as the save rewrites them with the copied text.
function _replayed(r::ValRule, ops)
    (isempty(ops) || (r.formula1 === nothing && r.formula2 === nothing)) && return r
    base = r.base; f1 = r.formula1; f2 = r.formula2
    for op in ops
        i = something(findlast('.', base), 0)
        sh = replace(i == 0 ? "" : base[1:prevind(base, i)], '$' => "")
        length(sh) >= 2 && startswith(sh, '\'') && endswith(sh, '\'') && (sh = replace(sh[2:prevind(sh, lastindex(sh))], "''" => "'"))
        cn = replace(base[nextind(base, i):end], '$' => "")
        cr = is_valid_cellname(cn) ? CellRef(cn) : nothing
        ctx = cr === nothing ? RefContext(sh) : RefContext(sh; row = row_number(cr), col = column_number(cr))
        f1 === nothing || (f1 = rewrite_formula(f1, op, ctx))
        f2 === nothing || (f2 = rewrite_formula(f2, op, ctx))
        base = _rewrite_base(base, op)
    end
    return _rule_with(r, f1, f2, base)
end

# A rule with other formulas and base cell.
_rule_with(r::ValRule, f1, f2, base::String) =
    ValRule(r.type, r.operator, f1, f2, r.allowBlank, r.dropdown, r.showInputMessage, r.promptTitle, r.prompt,
            r.showErrorMessage, r.errorTitle, r.error, r.errorStyle, base, r.caseSensitive, r.sortEntries)

function _next_val_name(xf::ODSFile)
    n = 0
    for x in Iterators.flatten(((f.name for f in _file_rules(xf)), (a.name for a in xf.valedits.added)))
        m = match(r"^val(\d+)$", x)
        m === nothing || (n = max(n, parse(Int, m.captures[1])))
    end
    return "val$(n + 1)"
end

#
# The validations of the file's cells (read on first use)
#

function _file_vals(ws::Worksheet)
    ws.filevals === nothing || return ws.filevals
    out = FileValRun[]
    xf = get_odsfile(ws)
    if ws.entry !== nothing && (!isempty(_file_rules(xf)) || !isempty(xf.valedits.added))   # a copy holds added names
        row = Ref(0)
        walk(n::XML.LazyNode) = begin
            c = XML.Cursor(n); XML.next!(c)
            XML.for_each_child!(c) do ch
                XML.nodetype(ch) === XML.Element || return
                t = XML.tag(ch)
                if t == "table:table-row"
                    nrows = min(_repeat_attr(ch, "table:number-rows-repeated"), SheetCore.MAX_ROWS - row[])
                    r0 = row[] + 1; row[] += nrows
                    rc = XML.Cursor(XML.LazyNode(ch)); XML.next!(rc)
                    col = 0
                    XML.for_each_child!(rc) do cc
                        XML.nodetype(cc) === XML.Element || return
                        if XML.tag(cc) in ("table:table-cell", "table:covered-table-cell")
                            k = 1; name = nothing
                            for (key, v) in XML.eachattribute!(cc)
                                key == "table:number-columns-repeated" && (k = _file_count(v, 1, 1, SheetCore.MAX_ROWS))
                                key == "table:content-validation-name" && (name = String(v))
                            end
                            k = min(k, SheetCore.MAX_COLS - col)
                            name === nothing || push!(out, FileValRun(r0, nrows, col + 1, k, name))
                            col += k
                        end
                        XML.skip_element!(cc)
                    end
                elseif t in _ROW_CONTAINERS
                    walk(XML.LazyNode(ch))
                end
                XML.skip_element!(ch)
            end
        end
        walk(ws.entry.node)
    end
    ws.filevals = out
    return out
end

# The rule of current cell (r, c): set or removed since, else the file's (moved with its cell).
function _val_at(ws::Worksheet, r::Int, c::Int)
    rs = ws.valrects
    if rs !== nothing
        for k in length(rs):-1:1
            rr, cc, v = rs[k]
            (r in rr && c in cc) && return v
        end
    end
    ws.entry === nothing && return nothing
    o = _original_line(ws.rowmap, r); p = _original_line(ws.colmap, c)
    (o == 0 || p == 0) && return nothing
    for run in _file_vals(ws)
        run.row <= o < run.row + run.nrows && run.col <= p < run.col + run.ncols && return run.name
    end
    return nothing
end

#
# Areas: the cells of each rule on a sheet now
#

const _Area = Tuple{UnitRange{Int},UnitRange{Int}}

# `a` less `b`: up to four areas.
function _area_minus(a::_Area, b::_Area)
    (ar, ac), (br, bc) = a, b
    ir = max(first(ar), first(br)):min(last(ar), last(br)); ic = max(first(ac), first(bc)):min(last(ac), last(bc))
    (isempty(ir) || isempty(ic)) && return _Area[a]
    out = _Area[]
    first(ar) < first(ir) && push!(out, (first(ar):first(ir)-1, ac))
    last(ir) < last(ar) && push!(out, (last(ir)+1:last(ar), ac))
    first(ac) < first(ic) && push!(out, (ir, first(ac):first(ic)-1))
    last(ic) < last(ac) && push!(out, (ir, last(ic)+1:last(ac)))
    return out
end

# Areas joined where one continues another (same columns, next rows; then same rows, next columns).
function _merge_areas(v::Vector{_Area})
    for pass in 1:2
        sort!(v; by = a -> pass == 1 ? (first(a[2]), last(a[2]), first(a[1])) : (first(a[1]), last(a[1]), first(a[2])))
        out = _Area[]
        for a in v
            if !isempty(out)
                l = out[end]
                if pass == 1 && l[2] == a[2] && last(l[1]) + 1 == first(a[1])
                    out[end] = (first(l[1]):last(a[1]), l[2]); continue
                elseif pass == 2 && l[1] == a[1] && last(l[2]) + 1 == first(a[2])
                    out[end] = (l[1], first(l[2]):last(a[2])); continue
                end
            end
            push!(out, a)
        end
        v = out
    end
    return v
end

# Every rule on the sheet now, with its areas: name => areas, in the file's order, then added.
function _sheet_rules(ws::Worksheet)
    cur = Tuple{_Area,String}[]
    for run in _file_vals(ws)
        for (_, rl, rc) in (ws.rowmap === nothing ? [(run.row, run.nrows, run.row)] : line_pieces(ws.rowmap, run.row, run.row + run.nrows - 1)),
            (_, cl, cc) in (ws.colmap === nothing ? [(run.col, run.ncols, run.col)] : line_pieces(ws.colmap, run.col, run.col + run.ncols - 1))
            push!(cur, ((rc:rc+rl-1, cc:cc+cl-1), run.name))
        end
    end
    if ws.valrects !== nothing
        for (rr, cc, v) in ws.valrects
            (isempty(rr) || isempty(cc)) && continue
            cur = [(p, n) for (a, n) in cur for p in _area_minus(a, (rr, cc))]
            v === nothing || push!(cur, ((rr, cc), v))
        end
    end
    xf = get_odsfile(ws)
    order = vcat([f.name for f in _file_rules(xf)], [a.name for a in xf.valedits.added])
    out = Pair{String,Vector{_Area}}[]
    for n in order
        areas = _Area[a for (a, m) in cur if m == n]
        isempty(areas) || push!(out, n => _merge_areas(areas))
    end
    return out
end

function _dv_info(ws::Worksheet, name::String, areas::Vector{_Area})
    r = _rule_named(get_odsfile(ws), name)
    rngs = [CellRange(first(a[1]), first(a[2]), last(a[1]), last(a[2])) for a in areas]
    range = length(rngs) == 1 ? rngs[1] : NonContiguousRange(ws.name, Union{CellRef,CellRange}[rngs...])
    return _info_row(DataValidationInfo, (ws.name, range, r.type, r.operator, _dv_ui(r.formula1), _dv_ui(r.formula2), r.allowBlank,
                               r.type === :list && r.dropdown, r.showInputMessage, r.promptTitle, r.prompt, r.showErrorMessage,
                               r.errorTitle, r.error, r.errorStyle, r.caseSensitive, r.type === :list && r.dropdown && r.sortEntries))
end

#
# The writers: a sheet's validations set or removed, by cell
#

const _NO_VAL_SEGS = Tuple{Int,Int,Union{Nothing,String}}[]

# Columns x:y of row r where a block sets or removes a validation: (first, last, name or nothing).
function _val_layer_in(ws::Worksheet, r::Int, x::Int, y::Int)
    rs = ws.valrects
    (rs === nothing || isempty(rs)) && return _NO_VAL_SEGS
    pts = Int[]
    for (rr, cc, _) in rs
        r in rr || continue
        lo = max(first(cc), x); hi = min(last(cc), y)
        lo <= hi && push!(pts, lo, hi + 1)
    end
    isempty(pts) && return _NO_VAL_SEGS
    sort!(unique!(pts))
    out = Tuple{Int,Int,Union{Nothing,String}}[]
    for k in 1:length(pts)-1
        a = pts[k]; b = pts[k+1] - 1
        for j in length(rs):-1:1
            rr, cc, v = rs[j]
            if r in rr && a in cc
                push!(out, (a, b, v)); break
            end
        end
    end
    return out
end

# Rows starting or ending a block, as their own segments (`write_model_rows`); whether a row is in a
# block that sets a validation; the last column such blocks give a row.
function _val_bounds!(bps::Vector{Int}, ws::Worksheet, a::Int, b::Int)
    ws.valrects === nothing && return
    for (rr, cc, _) in ws.valrects
        (isempty(rr) || isempty(cc) || last(rr) < a || first(rr) > b) && continue
        push!(bps, max(first(rr), a), min(last(rr), b) + 1)
    end
end
_val_row(ws::Worksheet, r::Int) = ws.valrects !== nothing && any(x -> x[3] !== nothing && r in x[1] && !isempty(x[2]), ws.valrects)
function _val_lastcol(ws::Worksheet, r::Int)
    ws.valrects === nothing && return 0
    m = 0
    for (rr, cc, v) in ws.valrects
        v !== nothing && r in rr && !isempty(cc) && (m = max(m, last(cc)))
    end
    return m
end
function _val_lastrow(ws::Worksheet)
    ws.valrects === nothing && return 0
    m = 0
    for (rr, cc, v) in ws.valrects
        v !== nothing && !isempty(rr) && !isempty(cc) && (m = max(m, last(rr)))
    end
    return m
end

_val_attr(v::Union{Nothing,String}) = v === nothing ? "" : " table:content-validation-name=\"" * sprint(_escape_attr, v) * "\""

# A cell's extras with its validation set (a name) or removed (nothing).
_with_val(::Nothing, v) = _CellExtras(_val_attr(v), Union{String,SubString{String}}[], Union{String,SubString{String}}[], nothing, nothing, false)
_with_val(ex::_CellExtras, v) = _CellExtras(_val_attr(v), ex.lead, ex.tail, ex.paras, ex.text, ex.single)

# Whether the rules must be checked when saved: rules or blocks were added, or lines or sheets deleted.
_val_check_needed(xf::ODSFile) = !isempty(xf.valedits.added) || any(ws -> ws.valrects !== nothing && !isempty(ws.valrects), _sheets(xf)) ||
    any(op -> (op isa LineShift && op.n < 0) || op isa SheetDelete, xf.ops)

# The rules some cell still uses (sheets deleted since are not looked at).
function _used_rules(xf::ODSFile)
    used = Set{String}()
    for ws in _sheets(xf)
        for (n, _) in _sheet_rules(ws)
            push!(used, n)
        end
    end
    return used
end

# A new file's rules (those used), for `_write_body`.
function _rules_xml(xf::ODSFile)
    isempty(xf.valedits.added) && return ""
    used = _used_rules(xf)
    x = join(_added_xml(a) for a in xf.valedits.added if a.name in used)
    return isempty(x) ? "" : "<table:content-validations>" * x * "</table:content-validations>"
end

#
# Inserts and deletes (`shift_lines!`)
#

# The validations of line `line` (axis 1: a row, 2: a column) along the other axis: (range, name).
function _line_vals(ws::Worksheet, axis::Int, line::Int)
    maxo = axis == 1 ? SheetCore.MAX_COLS : SheetCore.MAX_ROWS
    pts = Int[1, maxo + 1]
    if ws.entry !== nothing
        o = _original_line(axis == 1 ? ws.rowmap : ws.colmap, line)
        om = axis == 1 ? ws.colmap : ws.rowmap
        if o > 0
            for run in _file_vals(ws)
                lo, n = axis == 1 ? (run.row, run.nrows) : (run.col, run.ncols)
                lo <= o < lo + n || continue
                a, k = axis == 1 ? (run.col, run.ncols) : (run.row, run.nrows)
                for (_, len, cur) in (om === nothing ? [(a, k, a)] : line_pieces(om, a, a + k - 1))
                    push!(pts, cur, cur + len)
                end
            end
        end
    end
    if ws.valrects !== nothing
        for (rr, cc, _) in ws.valrects
            (axis == 1 ? line in rr : line in cc) || continue
            o = axis == 1 ? cc : rr
            isempty(o) || push!(pts, first(o), last(o) + 1)
        end
    end
    sort!(unique!(pts))
    out = Tuple{UnitRange{Int},String}[]
    for k in 1:length(pts)-1
        a = pts[k]; b = min(pts[k+1] - 1, maxo)
        a > maxo && break
        v = axis == 1 ? _val_at(ws, line, a) : _val_at(ws, a, line)
        v === nothing || push!(out, (a:b, v))
    end
    return out
end

# The blocks moved with the lines (cells moving as cells: a block across an insert splits around the
# new lines), the new lines given the validation of the line before them (`copies`, F-068), and the
# added rules' base cells moved.
function _shift_valrects!(ws::Worksheet, axis::Int, at::Int, n::Int, copies)
    maxl = axis == 1 ? SheetCore.MAX_ROWS : SheetCore.MAX_COLS
    if ws.valrects !== nothing
        new = ValRect[]
        for (rr, cc, v) in ws.valrects
            l = axis == 1 ? rr : cc
            parts = UnitRange{Int}[]
            if n > 0
                first(l) < at && push!(parts, first(l):min(last(l), at - 1))
                last(l) >= at && push!(parts, max(first(l), at)+n:min(last(l) + n, maxl))
            else
                r2 = _range_after(l, at, n, maxl)
                isempty(r2) || push!(parts, r2)
            end
            for p in parts
                isempty(p) && continue
                push!(new, axis == 1 ? (p, cc, v) : (rr, p, v))
            end
        end
        ws.valrects = new
    end
    if copies !== nothing && !isempty(copies)
        rs = ws.valrects === nothing ? (ws.valrects = ValRect[]) : ws.valrects
        lines = at:min(at + n - 1, maxl)
        for (o, v) in copies
            rect = axis == 1 ? (lines, o, v) : (o, lines, v)
            push!(rs, rect)
            ws.entry === nothing || push!(sheet_formats(ws).rects, (rect[1], rect[2]))
        end
    end
    for a in get_odsfile(ws).valedits.added
        a.sheet === ws || continue
        if axis == 1
            x = _line_after(a.row, at, n); a.row = x == 0 ? max(at, 1) : x
        else
            x = _line_after(a.col, at, n); a.col = x == 0 ? max(at, 1) : x
        end
    end
    return
end

# The references in the added rules' formulas, rewritten by a line or sheet operation (before the
# cells move: relative references are relative to the base cell). The file's rules are rewritten
# with the text that is copied.
function _rewrite_rule_refs!(xf::ODSFile, op)
    for a in xf.valedits.added
        r = a.rule
        (r.formula1 === nothing && r.formula2 === nothing) && continue
        ctx = RefContext(a.sheet.name; row = a.row, col = a.col)
        f1 = r.formula1 === nothing ? nothing : rewrite_formula(r.formula1, op, ctx)
        f2 = r.formula2 === nothing ? nothing : rewrite_formula(r.formula2, op, ctx)
        (f1 === r.formula1 && f2 === r.formula2) && continue
        a.rule = _rule_with(r, f1, f2, r.base)
    end
    return
end

#
# The patched save: unused rules dropped, added ones written
#

# The splices of the file's content.xml for its validations: each file rule no cell
# uses removed (the whole element if none is left, as LibreOffice drops them, F-068), the added rules
# used written at the element's end, or in a new element before the first table.
function _rules_splices(xf::ODSFile, first_table::Int)
    out = _Splice[]
    _val_check_needed(xf) || return out
    used = _used_rules(xf)
    fr = _file_rules(xf)
    add = join(_added_xml(a) for a in xf.valedits.added if a.name in used)
    sp = _rules_span(xf.content)
    drop = [f for f in fr if !(f.name in used)]
    if sp === nothing
        (isempty(add) || first_table == 0) && return out
        push!(out, (first_table, first_table - 1, "<table:content-validations>" * add * "</table:content-validations>"))
    elseif length(drop) == length(fr) && isempty(add)
        push!(out, (first(sp), last(sp), ""))
    else
        s = xf.content
        for f in drop
            a = first(f.span)                  # with the indentation before it
            while a > first(sp) && codeunit(s, a - 1) in (UInt8(' '), UInt8('\t'), UInt8('\n'), UInt8('\r'))
                a -= 1
            end
            push!(out, (a, last(f.span), ""))
        end
        isempty(add) || (k = last(sp) - ncodeunits("</table:content-validations>") + 1; push!(out, (k, k - 1, add)))
    end
    return out
end

#
# The API
#

# The blocks a validation's range names on a sheet, as (rows, cols).
# The areas a target names on `ws` (a range, or rows and columns), as (rows, cols): whole rows and
# columns reach the sheet's edge. A target on another sheet, or one naming no cells, is an error.
# The one check for validations, conditional formats and coloured data bars.
function _sheet_areas(ws::Worksheet, target...)
    out = _Area[]
    for (w, blocks) in format_targets(ws, target...)
        w === ws || throw(ODSError("The range names another sheet than `$(ws.name)`."))
        for b in blocks
            push!(out, b.kind === :cells ? (b.rows, b.cols) : b.kind === :rows ? (b.rows, 1:SheetCore.MAX_COLS) : (1:SheetCore.MAX_ROWS, b.cols))
        end
    end
    isempty(out) && throw(ODSError("The range names no cells."))
    return out
end

function _dv_sheet_ref(xf::ODSFile, ref::AbstractString)
    # the sheet ends at the first `.` or `!` outside quotes: a quoted name may hold either, and the
    # range after it may name the sheet again (`Sheet1.A1:Sheet1.B5`)
    i, quoted = 0, false
    for (k, c) in pairs(ref)
        c == '\'' && (quoted = !quoted)
        !quoted && (c == '!' || c == '.') && (i = k; break)
    end
    i == 0 && throw(ODSError("Give the sheet with the range, such as `Sheet1.B2:B20`: got `$ref`."))
    sh = String(SubString(ref, 1, prevind(ref, i)))
    length(sh) >= 2 && startswith(sh, '\'') && endswith(sh, '\'') && (sh = replace(chop(sh; head = 1, tail = 1), "''" => "'"))
    rest = String(SubString(ref, nextind(ref, i)))
    prefix = SubString(ref, 1, i)                       # the sheet and its separator, as written
    j = findfirst(':', rest)
    if j !== nothing && startswith(SubString(rest, nextind(rest, j)), prefix)
        rest = rest[1:j] * rest[nextind(rest, j) + ncodeunits(prefix):end]
    end
    return getsheet(xf, sh), rest
end

"""
    addDataValidation(sheet, rng; type, operator, formula1, formula2, values, allowBlank=true, dropdown,
                      showInputMessage=true, promptTitle, prompt, showErrorMessage=true, errorTitle, error,
                      errorStyle=:stop, caseSensitive=false, sortEntries=false) -> NamedTuple
    addDataValidation(xf, "Sheet1.B2:B20"; kw...)

Restrict what may be typed into the cells of `rng` (a cell, range, whole columns `"B:B"` or rows,
a list of ranges `"A1:A5,C1:C5"`, or a defined name), as LibreOffice's Data ▸ Validity does.

`type` is `:list`, `:whole`, `:decimal`, `:date`, `:time`, `:textLength`, `:custom` or `:any`
(`:list` when `values` is given). For the number, date, time and length types, `operator` is
`:between` (the default), `:notBetween`, `:equal`, `:notEqual`, `:greaterThan`, `:lessThan`,
`:greaterThanOrEqual` or `:lessThanOrEqual`, with `formula1` (and `formula2` for the two between
forms). `formula1` and `formula2` are numbers, a `Date`, `Time` or `DateTime`, or a reference or
formula in LibreOffice's notation (`"\$D\$1:\$D\$3"`, `"Lists.\$A\$1:\$A\$9"`, or
`"Lists!\$A\$1:\$A\$9"`; `"=ISNUMBER(B2)"`). A list's items may be given as `values`.

`allowBlank`, `dropdown` (a list's drop-down), `showInputMessage` with `prompt` and `promptTitle`,
and `showErrorMessage` with `error`, `errorTitle` and `errorStyle` (`:stop`, `:warning`,
`:information`) set the input help and error alert. As in LibreOffice, a cell has one validation: a new one replaces
the validation of the cells it covers. Identical validations share one rule.

Two more options: `caseSensitive`
(lists and comparisons with text tell upper and lower case apart) and
`sortEntries` (a `:list`'s drop-down shows its items sorted ascending).

Returns the validation, as [`getDataValidation`](@ref) reads it. An `:any` validation without a
prompt or error message restricts nothing, and LibreOffice stores none: it removes the validation of
its cells, and `nothing` is returned. The file must be writable.

```julia
addDataValidation(sh, "D2:D20"; values = ["Open", "Paid", "Late"])       # a drop-down list
addDataValidation(sh, "E2:E20"; type = :whole, operator = :between, formula1 = 1, formula2 = 10,
                  errorTitle = "Quantity", error = "Enter a whole number from 1 to 10.")
addDataValidation(sh, "F2:F20"; type = :date, operator = :greaterThanOrEqual,
                  formula1 = Date(2026, 1, 1), prompt = "A date in 2026 or later")
```
"""
function addDataValidation(ws::Worksheet, rng; type::Union{Nothing,Symbol} = nothing, operator::Union{Nothing,Symbol} = nothing,
                           formula1 = nothing, formula2 = nothing, values::Union{Nothing,AbstractVector} = nothing,
                           allowBlank::Bool = true, dropdown::Union{Nothing,Bool} = nothing,
                           showInputMessage::Bool = true, promptTitle::Union{Nothing,AbstractString} = nothing,
                           prompt::Union{Nothing,AbstractString} = nothing, showErrorMessage::Bool = true,
                           errorTitle::Union{Nothing,AbstractString} = nothing, error::Union{Nothing,AbstractString} = nothing,
                           errorStyle::Symbol = :stop, caseSensitive::Bool = false, sortEntries::Bool = false)
    _require_writable(ws, "add a data validation")
    foreach(_check_xml_text, (promptTitle, prompt, errorTitle, error))
    xf = get_odsfile(ws)
    isnothing(type) && !isnothing(values) && (type = :list)
    isnothing(type) && throw(ODSError("Give the kind of value allowed as `type`: one of $(join(DV_TYPES, ", "))."))
    type in DV_TYPES || throw(ODSError("Invalid `type` `:$type`. Must be one of $(join(DV_TYPES, ", "))."))
    if !isnothing(values)
        type === :list || throw(ODSError("`values` gives the items of a `:list` validation, not a `:$type` one."))
        isnothing(formula1) || throw(ODSError("Give a list's items as `values` or as `formula1`, not both."))
        f1 = _dv_list(values)
    else
        f1 = _dv_expr(xf, formula1, "formula1")
    end
    f2 = _dv_expr(xf, formula2, "formula2")
    if type === :any
        (isnothing(f1) && isnothing(f2) && isnothing(operator)) ||
            throw(ODSError("An `:any` validation allows any value, so it takes no `formula1`, `formula2` or `operator`."))
    elseif type in (:list, :custom)
        isnothing(f1) && throw(ODSError("A `:$type` validation needs `formula1`$(type === :list ? " or `values`" : "")."))
        isnothing(operator) || throw(ODSError("A `:$type` validation takes no `operator`."))
        isnothing(f2) || throw(ODSError("A `:$type` validation takes no `formula2`."))
    else
        operator = something(operator, :between)
        operator in DV_OPERATORS ||
            throw(ODSError("Invalid `operator` `:$operator`. Must be one of $(join(DV_OPERATORS, ", "))."))
        isnothing(f1) && throw(ODSError("A `:$type` validation needs `formula1`."))
        two = operator in (:between, :notBetween)
        two && isnothing(f2) && throw(ODSError("Operator `:$operator` needs `formula2` as well as `formula1`."))
        !two && !isnothing(f2) && throw(ODSError("Operator `:$operator` takes `formula1` only, not `formula2`."))
    end
    isnothing(dropdown) || type === :list || throw(ODSError("`dropdown` applies to a `:list` validation, not a `:$type` one."))
    sortEntries && type !== :list && throw(ODSError("`sortEntries` applies to a `:list` validation, not a `:$type` one."))
    sortEntries && dropdown === false && throw(ODSError("`sortEntries` sorts a list's drop-down, so it needs `dropdown=true`."))
    errorStyle in DV_ERROR_STYLES ||
        throw(ODSError("Invalid `errorStyle` `:$errorStyle`. Must be one of $(join(DV_ERROR_STYLES, ", "))."))
    blocks = _sheet_areas(ws, rng)
    # `:any` with no message restricts nothing: LibreOffice stores no validation then (F-061)
    if type === :any && all(isnothing, (promptTitle, prompt, errorTitle, error))
        _set_val_blocks!(ws, blocks, nothing)
        return nothing
    end
    str(x) = x === nothing ? nothing : String(x)
    rule = ValRule(type, type in (:list, :custom, :any) ? nothing : operator, f1, f2, allowBlank, something(dropdown, true),
                   showInputMessage, str(promptTitle), str(prompt), showErrorMessage, str(errorTitle), str(error), errorStyle, "",
                   caseSensitive, sortEntries)
    r0, c0 = first(blocks[1][1]), first(blocks[1][2])
    k = findfirst(a -> a.rule == rule && a.sheet === ws && a.row == r0 && a.col == c0, xf.valedits.added)
    name = k === nothing ? _next_val_name(xf) : xf.valedits.added[k].name
    k === nothing && push!(xf.valedits.added, AddedRule(name, rule, ws, r0, c0))
    _set_val_blocks!(ws, blocks, name)
    for (n, areas) in _sheet_rules(ws)
        n == name && return _dv_info(ws, n, areas)
    end
    return _dv_info(ws, name, blocks)
end
function addDataValidation(xf::ODSFile, ref::AbstractString; kw...)
    ws, rng = _dv_sheet_ref(xf, ref)
    return addDataValidation(ws, rng; kw...)
end

function _set_val_blocks!(ws::Worksheet, blocks::Vector{_Area}, name::Union{Nothing,String})
    rs = ws.valrects === nothing ? (ws.valrects = ValRect[]) : ws.valrects
    f = sheet_formats(ws)                      # a sheet with validations is written with its formats
    for (rr, cc) in blocks
        push!(rs, (rr, cc, name))
        ws.entry === nothing || push!(f.rects, (rr, cc))
    end
    return
end

"""
    deleteDataValidation(sheet, rng) -> Int
    deleteDataValidation(xf, "Sheet1.B2:B20") -> Int

Remove every validation whose cells all lie inside `rng` (the forms of
[`addDataValidation`](@ref); `:` for the whole sheet), from all its cells on the sheet. Returns how
many were removed. A rule no cell uses any more is dropped from the file when it is saved, as
LibreOffice drops it. The file must be writable.
"""
function deleteDataValidation(ws::Worksheet, rng)
    _require_writable(ws, "delete a data validation")
    target = rng isa Colon ? _Area[(1:SheetCore.MAX_ROWS, 1:SheetCore.MAX_COLS)] : _sheet_areas(ws, rng)
    within(a) = isempty(foldl((rest, b) -> [p for x in rest for p in _area_minus(x, b)], target; init = _Area[a]))
    n = 0
    for (_, areas) in _sheet_rules(ws)
        all(within, areas) || continue
        _set_val_blocks!(ws, areas, nothing)
        n += 1
    end
    return n
end
function deleteDataValidation(xf::ODSFile, ref::AbstractString)
    ws, rng = _dv_sheet_ref(xf, ref)
    return deleteDataValidation(ws, rng)
end

"""
    getDataValidations(sheet) -> Vector{NamedTuple}
    getDataValidations(xf::ODSFile) -> Vector{NamedTuple}

Every validation of a sheet, or of every sheet: `(sheet, range, type,
operator, formula1, formula2, allowBlank, dropdown, showInputMessage, promptTitle, prompt,
showErrorMessage, errorTitle, error, errorStyle, caseSensitive, sortEntries)` (see
[`addDataValidation`](@ref)). `range` is a `CellRange`, or a
`NonContiguousRange` for several areas; formulas are in LibreOffice's notation, without `=` (a list's
items as `"a","b"`); `operator` is `nothing` for `:list`, `:custom` and `:any`. In the file's order.
"""
getDataValidations(ws::Worksheet) = NamedTuple[_dv_info(ws, n, a) for (n, a) in _sheet_rules(ws)]
getDataValidations(xf::ODSFile) = reduce(vcat, (getDataValidations(ws) for ws in _sheets(xf)); init = NamedTuple[])

"""
    getDataValidation(sheet, ref) -> Union{Nothing, NamedTuple}
    getDataValidation(sheet, row, col) -> Union{Nothing, NamedTuple}

The validation of a cell, as [`getDataValidations`](@ref) gives it (its `range` all its cells on the
sheet), or `nothing`.
"""
function getDataValidation(ws::Worksheet, ref::Union{AbstractString,CellRef})
    r, c = _note_cell(ref, "`getDataValidation`")
    name = _val_at(ws, r, c)
    name === nothing && return nothing
    for (n, areas) in _sheet_rules(ws)
        n == name && return _dv_info(ws, n, areas)
    end
    return nothing
end
getDataValidation(ws::Worksheet, row::Integer, col::Integer) = getDataValidation(ws, CellRef(row, col))

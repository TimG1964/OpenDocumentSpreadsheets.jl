# Sheet operations (phase 5 step 4; D-053, D-054): renaming, deleting, copying and moving sheets,
# with XLSX.jl's API and LibreOffice's rules (experiment 022, F-047).
#
# Renames and deletes rewrite every formula and name of the model at once, and are logged
# (`xf.ops`) so that a patched save replays them on the text it copies (src/write/rewrite.jl). A
# copy of a sheet read from the file gets its own text: the source table as it is now, with its
# references repointed as LibreOffice repoints them; it is then treated as a sheet read from that
# text, with only later operations replayed on it. Moves change only the order of the tables.

# Every sheet's store and names in memory: an operation rewrites them all.
function _load_all!(xf::ODSFile)
    sheets = _sheets(xf)
    foreach(_cached_store, sheets)
    foreach(_local_names, sheets)
    _wb_names(xf)
    return sheets
end

_renumber!(xf::ODSFile) = (foreach(((i, ws),) -> ws.index = i, enumerate(xf.sheets)); xf)

# A sheet name for an existing sheet or a new one: LibreOffice's rules (D-028), and not another
# sheet's name in any case.
function _check_rename(xf::ODSFile, ws::Union{Nothing,Worksheet}, name::AbstractString)
    isempty(name) && throw(ODSError("A sheet name can't be empty."))
    for c in _BAD_SHEETNAME_CHARS
        occursin(c, name) && throw(ODSError("The sheet name `$name` holds `$c`, which LibreOffice does not allow in sheet names."))
    end
    (startswith(name, '\'') || endswith(name, '\'')) &&
        throw(ODSError("A sheet name can't start or end with an apostrophe: `$name`."))
    _check_xml_text(name)
    any(s -> s !== ws && _same_sheetname(s.name, name), _sheets(xf)) &&
        throw(ODSError("$(xf.source) already has a sheet named `$name`."))
    return nothing
end

"""
    renamesheet!(sheet, name)

Rename a sheet. Every reference to it follows, as in LibreOffice: formulas on every sheet,
defined names and their base cells, print ranges, conditional formats, validations, database
ranges and charts (D-053). Internal hyperlinks (`#Sheet1.A1`) are not changed, as LibreOffice
doesn't change them. Renaming a sheet to its own name in another case is allowed; a name another
sheet has (in any case), or one LibreOffice doesn't allow, is an error.
"""
function renamesheet!(ws::Worksheet, name::AbstractString)
    name = String(name)
    ws.name == name && return nothing
    _require_writable(ws, "rename a sheet")
    xf = get_odsfile(ws)
    _check_rename(xf, ws, name)
    _load_all!(xf)
    op = SheetRename(ws.name, name)
    _rewrite_model_refs!(xf, op)
    ws.localnames === nothing ||
        (ws.localnames = [NameDef(dn.name, name, dn.range, dn.expression, dn.base, dn.span) for dn in ws.localnames])
    ws.name = name
    isnewfile(xf) || push!(xf.ops, op)
    return nothing
end

"""
    deletesheet!(sheet) -> ODSFile
    deletesheet!(xf, name) -> ODSFile
    deletesheet!(xf, i::Integer) -> ODSFile

Delete a sheet (by itself, its name or its position). As in LibreOffice (D-053, F-047):
references to it in the other sheets' formulas, and in defined names, become `#REF!`; a 3-D
reference that ends on it ends on the sheet next to it, inside the span; its local names, and the
database ranges, conditional formats and validations on it go with it. The only sheet can't be
deleted.
"""
function deletesheet!(ws::Worksheet)
    _require_writable(ws, "delete a sheet")
    xf = get_odsfile(ws)
    sheets = _load_all!(xf)
    length(sheets) == 1 && throw(ODSError("Can't delete `$(ws.name)`: it is the only sheet of $(xf.source)."))
    i = findfirst(s -> s === ws, sheets)
    i === nothing && throw(ODSError("The sheet `$(ws.name)` is not in $(xf.source)."))
    op = SheetDelete(ws.name, [s.name for s in sheets])
    deleteat!(xf.sheets, i)
    _renumber!(xf)
    _rewrite_model_refs!(xf, op)
    ws.entry === nothing || ws.copied || push!(xf.gone, ws)
    isnewfile(xf) || push!(xf.ops, op)
    return xf
end
deletesheet!(xf::ODSFile, name::AbstractString) = (hassheet(xf, name) ||
    throw(ODSError("$(xf.source) has no sheet named `$name`.")); deletesheet!(getsheet(xf, name)))
deletesheet!(xf::ODSFile, i::Integer) = deletesheet!(_sheet_at(xf, i))

function _sheet_at(xf::ODSFile, i::Integer)
    sheets = _sheets(xf)
    1 <= i <= length(sheets) || throw(ODSError("$(xf.source) has no sheet $i: it has $(length(sheets)) sheet(s)."))
    return sheets[i]
end

_sheet_arg(xf::ODSFile, s::Worksheet) = (any(w -> w === s, _sheets(xf)) ? s :
    throw(ODSError("The sheet `$(s.name)` is not in $(xf.source).")))
_sheet_arg(xf::ODSFile, s::Integer) = _sheet_at(xf, s)
_sheet_arg(xf::ODSFile, s::AbstractString) = (hassheet(xf, s) ? getsheet(xf, s) :
    throw(ODSError("$(xf.source) has no sheet named `$s`.")))

"""
    movesheet!(sheet; before = nothing, after = nothing) -> ODSFile
    movesheet!(xf, sheet; before = nothing, after = nothing) -> ODSFile

Move a sheet next to another: immediately `before` or `after` it (give exactly one). Each of
`sheet`, `before` and `after` can be a `Worksheet`, a sheet name or a position (as before the
move): `before = 1` moves it to the start, `after = sheetcount(xf)` to the end.

Nothing is rewritten, as in LibreOffice and XLSX.jl: references name their sheets. A 3-D
reference (`Sheet1.A1:Sheet3.A1`) covers the sheets between its two ends in the order they are
in, so moving a sheet into or out of that span changes what it covers.
"""
movesheet!(ws::Worksheet; kw...) = movesheet!(get_odsfile(ws), ws; kw...)
function movesheet!(xf::ODSFile, sheet; before = nothing, after = nothing)
    (before === nothing) == (after === nothing) &&
        throw(ODSError("Give exactly one of `before` or `after` to say where to move the sheet."))
    _require_writable(xf, "move a sheet")
    ws = _sheet_arg(xf, sheet)
    target = _sheet_arg(xf, something(before, after))
    ws === target && return xf
    deleteat!(xf.sheets, findfirst(w -> w === ws, xf.sheets))
    t = findfirst(w -> w === target, xf.sheets)
    insert!(xf.sheets, before === nothing ? t + 1 : t, ws)
    _renumber!(xf)
    return xf
end

# A sheet's table as it is now (its edits and the operations so far applied), as text.
function _table_text_now(ws::Worksheet)
    xf = get_odsfile(ws)
    io = IOBuffer()
    _write_chunked(out -> _write_sheet(out, ws, _sheet_rewriter(ws, nothing); display = true), io)
    return String(take!(io))
end

# The global names a sheet's formulas use that refer to the sheet itself (their references, or
# the sheet of a relative name's base): LibreOffice gives a copy its own (F-047).
function _names_to_localize(xf::ODSFile, ws::Worksheet)
    used = Set{String}()
    for rd in _cached_store(ws).rows, r in rd.runs
        f = r.data.formula
        f === nothing && continue
        for t in tokenize_formula(f)
            t.kind === FT_NAME && push!(used, lowercase(t.text))
        end
    end
    locals = Set(lowercase(dn.name) for dn in _local_names(ws))
    out = NameDef[]
    for dn in _wb_names(xf)
        k = lowercase(dn.name)
        (k in used && !(k in locals)) || continue
        areas = String[]
        dn.range === nothing || append!(areas, [String(SubString(dn.range, a, b)) for (a, b) in _areas(String(dn.range))])
        dn.expression === nothing || append!(areas, [String(_ref_inner(t.text)) for t in tokenize_formula(dn.expression) if t.kind === FT_REF])
        basesheet = dn.base === nothing ? nothing : _base_sheet(dn.base)
        refers = any(areas) do area
            ends = parse_ref(area)
            ends === nothing && return false
            # a qualified reference to the sheet, or a relative name's (on its base's sheet)
            any(e -> e.sheet !== nothing && _same_sheet(e.sheet, ws.name), ends) ||
                (all(e -> e.sheet === nothing, ends) && basesheet !== nothing && _same_sheet(basesheet, ws.name))
        end
        refers && push!(out, dn)
    end
    return out
end

function _name_xml(dn::NameDef)
    io = IOBuffer()
    print(io, dn.range === nothing ? "<table:named-expression" : "<table:named-range", " table:name=\"")
    _escape_attr(io, dn.name); print(io, '"')
    if dn.base !== nothing
        print(io, " table:base-cell-address=\""); _escape_attr(io, dn.base); print(io, '"')
    end
    if dn.range !== nothing
        print(io, " table:cell-range-address=\""); _escape_attr(io, dn.range); print(io, "\"/>")
    else
        print(io, " table:expression=\""); _escape_attr(io, something(dn.expression, "")); print(io, "\"/>")
    end
    return String(take!(io))
end

# Where a table's direct child `table:named-expressions` is (its span), or where one would go:
# after the rows and columns (nothing, insertion point).
function _local_names_span(t::String)
    c = XML.Cursor(t)
    while XML.next!(c) !== nothing
        XML.nodetype(c) === XML.Element && break
    end
    span = nothing
    after = 0
    XML.for_each_child!(c) do ch
        XML.nodetype(ch) === XML.Element || return
        tg = XML.tag(ch)
        sp = XML.sourcespan(XML.LazyNode(ch))
        if tg == "table:named-expressions"
            span = sp
        elseif tg == "table:table-row" || tg == "table:table-column" || tg in _ROW_CONTAINERS || tg in _COL_CONTAINERS ||
               tg == "table:shapes" || tg == "table:table-source" || tg == "table:scenario" || tg == "office:forms" ||
               tg == "table:title" || tg == "table:desc" || tg == "table:table-protection" || tg == "loext:table-protection"
            after = last(sp)
        end
        XML.skip_element!(ch)
    end
    return span, after + 1
end

# The objects (`./Object 1`) a copy's text embeds get new names, and their parts are copied at
# save (zipped files; a flat file holds them inline).
function _copy_objects!(xf::ODSFile, t::String)
    (xf.container === nothing || xf.container.zip === nothing) && return t
    names = unique([m.captures[1] for m in eachmatch(r"xlink:href=\"\./(Object [^\"/]+)\"", t)])
    isempty(names) && return t
    taken = Set{String}()
    for n in partnames(xf.container)
        m = match(r"^(Object [^/]+)/", n)
        m === nothing || push!(taken, m.captures[1])
    end
    foreach(p -> push!(taken, p.second), xf.objcopies)
    for old in names
        k = 1
        while "Object $k" in taken
            k += 1
        end
        new = "Object $k"
        push!(taken, new)
        push!(xf.objcopies, old => new)
        t = replace(t, "\"./$old\"" => "\"./$new\"", "\"./ObjectReplacements/$old\"" => "\"./ObjectReplacements/$new\"")
    end
    return t
end

# The database ranges on `src` (the file's, through the operations so far, and earlier copies'),
# copied for its copy `dst`, as LibreOffice copies them (F-047): `DB1` → `DB1_2`.
function _copy_database_ranges!(xf::ODSFile, src::String, dst::String, op::SheetCopy)
    current = String[]
    if !isnewfile(xf)
        s = xf.content
        rw = isempty(xf.ops) ? nothing : RefRewriter(xf.ops, s)
        for m in eachmatch(r"<table:database-range\s[^>]*?(?:/>|>.*?</table:database-range>)"s, s)
            x = String(m.match)
            if rw !== nothing
                io = IOBuffer(); rewrite_xml(io, RefRewriter(xf.ops, x), x, 1, ncodeunits(x)); x = String(take!(io))
            end
            isempty(x) || push!(current, x)
        end
    end
    for (x, n) in xf.extras
        io = IOBuffer(); rewrite_xml(io, RefRewriter(xf.ops[n+1:end], x), x, 1, ncodeunits(x)); x = String(take!(io))
        isempty(x) || push!(current, x)
    end
    names = Set{String}()
    for x in current
        m = match(r"table:name=\"([^\"]*)\"", x)
        m === nothing || push!(names, XML.unescape(m.captures[1]))
    end
    for x in current
        m = match(r"table:target-range-address=\"([^\"]*)\"", x)
        m === nothing && continue
        target = XML.unescape(m.captures[1])
        ends = parse_ref(SubString(target, _areas(String(target))[1]...))
        (ends !== nothing && ends[1].sheet !== nothing && _same_sheet(ends[1].sheet, src)) || continue
        name = XML.unescape(match(r"table:name=\"([^\"]*)\"", x).captures[1])
        base = name
        k = 2
        newname = startswith(name, "__Anonymous_Sheet_DB__") ? "__Anonymous_Sheet_DB__" * string(length(xf.sheets) - 1) :
                  "$(base)_$k"
        while newname in names
            k += 1
            newname = "$(base)_$k"
        end
        push!(names, newname)
        rw = RefRewriter(Any[SheetCopy(op.src, op.dst, true, op.order)], x; withcopy = true)
        io = IOBuffer(); rewrite_xml(io, rw, x, 1, ncodeunits(x)); y = String(take!(io))
        y = replace(y, r"table:name=\"[^\"]*\"" => "table:name=\"" * _escape_attr(newname) * "\""; count = 1)
        push!(xf.extras, (y, length(xf.ops)))
    end
    return
end

"""
    copysheet!(sheet, name = "") -> Worksheet

Copy a sheet to the end of the file, named `name`, or `"<name> (copy)"` (with a number added
until it is free). As in LibreOffice (D-053, F-047):
- the copy's references to the source sheet written with a relative sheet name (`[Data.A5]`)
  keep their distance in the sheet order, so they refer to the copy; references with an absolute
  sheet name (`[\$Data.A5]`), and those without one, are kept
- the source's local names are copied and point at the copy, and the global names its formulas
  use that refer to the source become local names of the copy, pointing at it
- conditional formats, print ranges, shapes, charts and the database ranges on the source are
  copied too
Returns the new sheet.
"""
function copysheet!(ws::Worksheet, name::AbstractString = "")
    _require_writable(ws, "copy a sheet")
    xf = get_odsfile(ws)
    sheets = _load_all!(xf)
    if isempty(name)
        name = ws.name * " (copy)"
        i = 1
        base = name
        while any(s -> _same_sheetname(s.name, name), sheets)
            name = base * " " * string(i)
            i += 1
        end
    end
    name = String(name)
    _check_rename(xf, nothing, name)
    order = [[s.name for s in sheets]; name]
    op = SheetCopy(ws.name, name, false, order)
    localize = _names_to_localize(xf, ws)
    n = length(sheets) + 1
    if ws.entry === nothing
        # a sheet made by OpenDocumentSpreadsheets: its model is copied
        new = Worksheet(xf, name, n, nothing, ws.visible, deepcopy(_cached_store(ws)), nothing, ReentrantLock())
        new.formats = deepcopy(ws.formats)
        new.props = deepcopy(ws.props)                 # visibility and tab colour (phase 5 step 6)
        new.protection = deepcopy(ws.protection)       # protection (phase 5 step 9)
        new.print = deepcopy(ws.print)                 # page style and print area (phase 5 step 10)
        for rd in new.store.rows, (j, r) in enumerate(rd.runs)
            r.data.formula === nothing && continue
            d = r.data
            rd.runs[j] = CellRun(r.col, r.count, CellData(d.kind, d.flags, d.style, d.bits, d.text,
                                 rewrite_formula(d.formula, op, RefContext(name)), d.colspan, d.rowspan))
        end
        all = SheetCopy(ws.name, name, true, order)
        new.localnames = [NameDef(dn.name, name, dn.range === nothing ? nothing : rewrite_rangelist(dn.range, all, RefContext(name)),
                                      dn.expression === nothing ? nothing : rewrite_formula(dn.expression, all, RefContext(name)),
                                      dn.base === nothing ? nothing : _rewrite_base(dn.base, all))
                          for dn in vcat(_local_names(ws), localize)]
    else
        t = _table_text_now(ws)
        # references repointed (relative sheet names), the table renamed
        io = IOBuffer()
        rewrite_xml(io, RefRewriter(Any[op], t; withcopy = true), t, 1, ncodeunits(t); sheet = ws.name)
        t = String(take!(io))
        e = _start_tag_end(t)
        t = _set_attrs(SubString(t, 1, e), Pair{String,Union{Nothing,String}}["table:name" => _escape_attr(name)]; open = true) *
            SubString(t, nextind(t, e))
        # the local names point at the copy (absolute sheet names too), and the localized global names join them
        all = SheetCopy(ws.name, name, true, order)
        span, at = _local_names_span(t)
        extra = join(_name_xml(NameDef(dn.name, name, dn.range, dn.expression, dn.base)) for dn in localize)
        if span !== nothing
            seg = t[first(span):last(span)]
            io = IOBuffer(); rewrite_xml(io, RefRewriter(Any[all], seg; withcopy = true), seg, 1, ncodeunits(seg); sheet = name)
            seg = String(take!(io))
            if !isempty(extra)
                ex = IOBuffer(); rewrite_xml(ex, RefRewriter(Any[all], extra; withcopy = true), extra, 1, ncodeunits(extra); sheet = name)
                k = findlast("</table:named-expressions>", seg)
                seg = seg[1:prevind(seg, first(k))] * String(take!(ex)) * seg[first(k):end]
            end
            t = t[1:prevind(t, first(span))] * seg * t[nextind(t, last(span)):end]
        elseif !isempty(extra)
            ex = IOBuffer(); rewrite_xml(ex, RefRewriter(Any[all], extra; withcopy = true), extra, 1, ncodeunits(extra); sheet = name)
            t = t[1:prevind(t, at)] * "<table:named-expressions>" * String(take!(ex)) * "</table:named-expressions>" * t[at:end]
        end
        t = _copy_objects!(xf, t)
        c = XML.Cursor(t)
        while XML.next!(c) !== nothing
            XML.nodetype(c) === XML.Element && break
        end
        new = Worksheet(xf, name, n, SheetEntry(name, n, XML.LazyNode(c)), ws.visible, nothing, nothing, ReentrantLock())
        new.copied = true
    end
    push!(xf.sheets, new)
    haskey(xf.views.sheets, ws) && (xf.views.sheets[new] = copy(xf.views.sheets[ws]))   # its view (phase 5 step 8)
    if !isnewfile(xf)
        _copy_database_ranges!(xf, ws.name, name, op)
        push!(xf.ops, op)                          # orders the settings; its text rewriting is done
        new.opstart = length(xf.ops)
    end
    return new
end

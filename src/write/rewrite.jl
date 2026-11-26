# Rewriting the references in original XML for a patched save after structural edits (phase 5,
# D-049, D-050, D-053). The operations logged since the file was read (`xf.ops`) are replayed, in
# order, on every reference-bearing attribute of the text the patcher copies (F-044's registry).
# Only values that change are spliced; everything else is copied as it is (D-023). A file without
# operations never comes here.
#
# The attributes are found once, by one regex pass over the document (`_REF_RX`; 0.13 s for 152
# MiB), so text without references (numbers, strings, styles) is copied in whole pieces.

# The registered attributes, by name.
const _REF_ATTRS = Set(["table:formula", "table:expression", "table:condition", "table:cell-range-address",
    "table:base-cell-address", "table:target-range-address", "table:print-ranges", "table:end-cell-address",
    "table:source-cell-range-address", "table:cell-address", "table:target-cell-address",
    "draw:notify-on-update-of-ranges", "chart:values-cell-range-address", "chart:label-cell-address",
    "chart:cell-range-address", "chart:error-upper-range", "chart:error-lower-range", "calcext:value", "calcext:base-cell-address", "calcext:target-range-address",
    "style:condition", "style:base-cell-address",
    "calcext:cell-address", "calcext:data-range"])

"""
    RefRewriter(ops, src)

The operations to replay (`xf.ops`) on the text of `src` (content.xml or the flat document), with:
- `hits`: where in `src` the start tags with registered attributes are, found by one regex pass
  (sorted), so that any piece of `src` is copied in one write when it holds none
- `cf`: the rewritten conditional-format conditions found in the document ((condition body, base) →
  (new body, new base)), which the `style:map`s that duplicate them take
"""
struct RefRewriter
    ops::Vector{Any}
    cf::Dict{Tuple{String,String},Tuple{String,String}}
    src::String
    hits::Vector{Int}
    # the operations for a chart's references: those but sheet copies, which leave a copied chart
    # pointing at its source (F-083)
    chartops::Vector{Any}
end
RefRewriter(ops::Vector{Any}, cf::Dict{Tuple{String,String},Tuple{String,String}}, src::String, hits::Vector{Int}) =
    RefRewriter(ops, cf, src, hits, Any[op for op in ops if !(op isa SheetCopy)])

const _REF_RX = r"(?:formula|expression|condition|range-address|cell-address|print-ranges|calcext:value|notify-on-update-of-ranges|error-upper-range|error-lower-range|data-range)="

# The start tags in s[a:b] holding a registered attribute (sorted).
function _ref_hits(s::String, a::Int = 1, b::Int = ncodeunits(s))
    hits = Int[]
    i = a
    while (r = findnext(_REF_RX, s, i)) !== nothing && first(r) <= b
        t = _tag_start(s, first(r))
        t >= a && push!(hits, t)
        i = last(r) + 1
    end
    return unique!(hits)
end

# A `SheetCopy` in the log only orders things (settings.xml, D-053): its rewriting was done to the
# copy's own text when the copy was made, so it is replayed only when asked (`withcopy`).
function RefRewriter(ops::Vector{Any}, src::String; withcopy::Bool = false)
    ops = withcopy ? ops : Any[op for op in ops if !(op isa SheetCopy)]
    rw = RefRewriter(ops, Dict{Tuple{String,String},Tuple{String,String}}(), src, _ref_hits(src))
    return cf_rewrites!(rw, src)
end

# Whether s[a:b] (of the rewriter's source) holds a registered attribute.
function _has_hits(rw::RefRewriter, a::Int, b::Int)
    i = searchsortedfirst(rw.hits, a)
    return i <= length(rw.hits) && rw.hits[i] <= b
end

# Replays the operations on `s`, with `f(s, op, ctx)` rewriting one value. The text's sheet and
# cell are where they were when each operation happened: they follow renames and line shifts.
function _replay(f, s::String, ops::Vector{Any}, sheet::String, row::Int, col::Int; kw...)
    for op in ops
        s = f(s, op, RefContext(sheet; row, col, kw...))
        if op isa LineShift && _same_sheet(op.sheet, sheet)
            op.axis == 1 ? (row > 0 && (row = _line_after(row, op.at, op.n))) :
                           (col > 0 && (col = _line_after(col, op.at, op.n)))
        elseif op isa SheetRename && _same_sheet(op.old, sheet)
            sheet = op.new
        end
    end
    return s
end

_rf(s, op, ctx) = rewrite_formula(s, op, ctx)
_rl(s, op, ctx) = rewrite_rangelist(s, op, ctx)
_rbase(s, op, ctx) = _rewrite_base(s, op)

# The sheet a base address names, or `sheet`.
_ctx_sheet(base, sheet::String) = base === nothing ? sheet : something(_base_sheet(base), sheet)

# A conditional format's condition, base and target, through the operations.
function _replay_condition(rw::RefRewriter, cond::String, base::String, target::String, sheet::String)
    for op in rw.ops
        r = rebase_condition(cond, base, target, op, sheet)
        target = rewrite_rangelist(target, op, RefContext(sheet; expand = true))
        r === nothing || ((cond, base) = r)
        op isa SheetRename && _same_sheet(op.old, sheet) && (sheet = op.new)
    end
    return cond, base
end

# "formula-is(X)" / "is-true-formula(X)" → "X" (the body a style:map shares with its calcext twin).
function _condition_body(v::AbstractString)
    for p in ("formula-is(", "is-true-formula(")
        startswith(v, p) && endswith(v, ")") && return String(v[ncodeunits(p)+1:end-1])
    end
    return String(v)
end

# The new values of a start tag's registered attributes (`attrs`: name => unescaped value), as
# name => new unescaped value, for those that change. `sheet` is the table the tag is in (""
# outside tables), `row`/`col` the cell's original position (0: not a cell), `target` the
# enclosing conditional format's target.
function _new_attr_values(rw::RefRewriter, tag::AbstractString, attrs::Vector{Pair{String,String}}, sheet::String,
                          row::Int, col::Int, target::Union{Nothing,String})
    out = Pair{String,String}[]
    get_(k) = (i = findfirst(p -> p.first == k, attrs); i === nothing ? nothing : attrs[i].second)
    set_(k, v, new) = new == v || push!(out, k => new)
    if tag == "table:named-range" || tag == "table:named-expression"
        base = get_("table:base-cell-address")
        bs = _ctx_sheet(base, sheet)
        for (k, v) in attrs
            k == "table:cell-range-address" && set_(k, v, _replay(_rl, v, rw.ops, bs, 0, 0; names = true))
            k == "table:expression" && set_(k, v, _replay(_rf, v, rw.ops, bs, 0, 0; names = true))
            k == "table:base-cell-address" && set_(k, v, _replay(_rbase, v, rw.ops, bs, 0, 0))
        end
    elseif tag == "calcext:condition" && target !== nothing && get_("calcext:value") !== nothing &&
           get_("calcext:base-cell-address") !== nothing
        v = get_("calcext:value"); b = get_("calcext:base-cell-address")
        nv, nb = _replay_condition(rw, v, b, target, sheet)
        set_("calcext:value", v, nv); set_("calcext:base-cell-address", b, nb)
    elseif tag == "style:map" && get_("style:condition") !== nothing
        v = get_("style:condition"); b = something(get_("style:base-cell-address"), "")
        hit = get(rw.cf, (_condition_body(v), b), nothing)
        if hit !== nothing
            body, nb = hit
            set_("style:condition", v, startswith(v, "is-true-formula(") ? "is-true-formula(" * body * ")" : body)
            isempty(b) || set_("style:base-cell-address", b, nb)
        else
            bs = _ctx_sheet(isempty(b) ? nothing : b, sheet)
            set_("style:condition", v, _replay(_rf, v, rw.ops, bs, 0, 0))
            isempty(b) || set_("style:base-cell-address", b, _replay(_rl, b, rw.ops, bs, 0, 0; marked = false))
        end
    elseif tag == "calcext:sparkline"
        # a sparkline goes with its cell; its data moves as LibreOffice moves a chart's (Q-029, D-086):
        # clipped, never #REF!, re-pointed when its sheet goes, left on its sheet by a copy
        c = get_("calcext:cell-address"); d = get_("calcext:data-range")
        if c !== nothing
            nc = _replay(_rl, c, rw.ops, sheet, 0, 0)
            occursin("#REF!", nc) && return :drop
            set_("calcext:cell-address", c, nc)
        end
        d === nothing || set_("calcext:data-range", d, _replay(_rl, d, rw.chartops, sheet, 0, 0; marked = false))
    else
        unmarked = startswith(tag, "chart:") || tag == "draw:object" || tag == "draw:frame" ||
                   tag == "table:content-validation"
        # a chart's references (its object's, and its frame's notify list) don't follow a sheet copy
        chart = startswith(tag, "chart:") || tag == "draw:object"
        base = get_("table:base-cell-address")
        bs = _ctx_sheet(base, sheet)
        # elements LibreOffice drops (F-043, F-047): a validation based on a deleted sheet, and a
        # conditional format or database range whose target is gone
        if tag == "table:content-validation" && base !== nothing
            sheetops = Any[op for op in rw.ops if !(op isa LineShift)]
            _replay(_rl, base, sheetops, bs, 0, 0) == "#REF!" && return :drop
        end
        for (k, dropk) in (("calcext:target-range-address", "calcext:conditional-format"),
                           ("table:target-range-address", "table:database-range"))
            tag == dropk || continue
            v = get_(k)
            v === nothing && continue
            _replay(_rl, v, rw.ops, sheet, 0, 0; expand = k == "calcext:target-range-address") == "#REF!" && return :drop
        end
        for (k, v) in attrs
            k in _REF_ATTRS || continue
            if k == "table:formula"
                set_(k, v, _replay(_rf, v, rw.ops, sheet, row, col))
            elseif k == "table:condition" || k == "calcext:value"
                set_(k, v, _replay(_rf, v, rw.ops, bs, 0, 0))
            elseif k == "table:base-cell-address"
                set_(k, v, _replay(_rl, v, rw.ops, bs, 0, 0; marked = false))
            elseif k == "calcext:target-range-address"
                set_(k, v, _replay(_rl, v, rw.ops, sheet, 0, 0; expand = true))
            elseif k == "table:end-cell-address" || k == "draw:notify-on-update-of-ranges"
                set_(k, v, _replay(_rl, v, chart ? rw.chartops : rw.ops, sheet, 0, 0; marked = false))
            elseif k == "chart:error-upper-range" || k == "chart:error-lower-range"     # in a series' style (F-083)
                set_(k, v, _replay(_rl, v, rw.chartops, sheet, 0, 0; marked = false))
            elseif k == "style:condition" || k == "style:base-cell-address" || k == "calcext:base-cell-address"
                continue                     # handled with their elements above
            else
                set_(k, v, _replay(_rl, v, chart ? rw.chartops : rw.ops, sheet, 0, 0; marked = !unmarked))
            end
        end
    end
    return out
end

# The attributes of a start tag: (name, unescaped value, first and last byte of the value).
function _tag_attrs(s::AbstractString, a::Int, b::Int)
    out = Tuple{String,String,Int,Int}[]
    i = a
    while i <= b && !(isspace(s[i]) || s[i] in ('>', '/'))      # past the tag's name
        i = nextind(s, i)
    end
    while i <= b
        while i <= b && isspace(s[i])
            i = nextind(s, i)
        end
        (i > b || s[i] in ('>', '/')) && break
        n0 = i
        while i <= b && !(isspace(s[i]) || s[i] == '=')
            i = nextind(s, i)
        end
        name = String(SubString(s, n0, prevind(s, i)))
        while i <= b && isspace(s[i])
            i = nextind(s, i)
        end
        (i <= b && s[i] == '=') || break
        i = nextind(s, i)
        while i <= b && isspace(s[i])
            i = nextind(s, i)
        end
        (i <= b && s[i] in ('"', '\'')) || break
        q = s[i]
        z = findnext(q, s, nextind(s, i))
        (z === nothing || z > b) && break
        va = nextind(s, i); vb = prevind(s, z)
        push!(out, (name, XML.unescape(String(SubString(s, va, vb))), va, vb))
        i = nextind(s, z)
    end
    return out
end

# Where the start tag holding byte `i` begins, or 0 when `i` is in text, a comment or an end tag.
function _tag_start(s::AbstractString, i::Int)
    lt = findprev('<', s, i)
    lt === nothing && return 0
    gt = findprev('>', s, i)
    (gt !== nothing && gt > lt) && return 0
    nextind(s, lt) <= ncodeunits(s) && s[nextind(s, lt)] in ('/', '!', '?') && return 0
    return lt
end

"""
    rewrite_xml(out, rw, s, a, b; sheet, row = 0, col = 0)

Writes `s[a:b]` (original XML) to `out` with the references of its registered attributes replayed
through `rw`'s operations. `sheet` is the table the text is in (`""` outside tables). `row`/`col`
give the original position of the one cell the text holds, if it is a cell's text (the formula's
position matters for F-043's end-of-sheet rule).
"""
function rewrite_xml(out::IO, rw::RefRewriter, s::String, a::Int, b::Int; sheet::String = "", row::Int = 0, col::Int = 0,
                     rowbase::Int = -1)
    a > b && return
    if s === rw.src
        i = searchsortedfirst(rw.hits, a)
        j = searchsortedlast(rw.hits, b)
        if i > j
            write(out, SubString(s, a, b))
            return
        end
        hits = rw.hits[i:j]
    else
        hits = _ref_hits(s, a, b)
        if isempty(hits)
            write(out, SubString(s, a, b))
            return
        end
    end
    # with `rowbase` (the original rows before s[a]), a formula's row is counted from the row
    # elements before it (rows left in a gap by the mapped walk: their formulas need their row)
    counted = a; nrows = rowbase; rowof = 0
    pos = a
    target = nothing
    # the conditional format a condition belongs to: the last one before it in this text
    cfs = findall("<calcext:conditional-format ", SubString(s, a, b))
    for t in hits
        t < pos && continue                         # inside an element dropped before
        e = t - 1 + _start_tag_end(SubString(s, t, b))
        name = _tag_name(SubString(s, t, e))
        if name == "calcext:condition"
            k = findlast(r -> first(r) + a - 1 < t, cfs)
            if k !== nothing
                ct = first(cfs[k]) + a - 1
                ce = ct - 1 + _start_tag_end(SubString(s, ct, b))
                ta = _tag_attrs(s, ct, ce)
                i = findfirst(x -> x[1] == "calcext:target-range-address", ta)
                target = i === nothing ? nothing : ta[i][2]
            end
        end
        attrs = _tag_attrs(s, t, e)
        r = row
        if rowbase >= 0 && name in ("table:table-cell", "table:covered-table-cell")
            while (k = findnext("<table:table-row", s, counted)) !== nothing && first(k) < t
                ke = first(k) - 1 + _start_tag_end(SubString(s, first(k), b))
                rowof = nrows + 1
                nrows += max(1, _attr_int(SubString(s, first(k), ke), "table:number-rows-repeated", 1))
                counted = ke + 1
            end
            r = rowof
        end
        new = _new_attr_values(rw, name, [x[1] => x[2] for x in attrs], sheet, r, col, name == "calcext:condition" ? target : nothing)
        if new === :drop                            # the whole element goes
            write(out, SubString(s, pos, prevind(s, t)))
            if s[prevind(s, e)] == '/'
                pos = e + 1
            else
                z = findnext("</" * name * ">", s, e)
                pos = z === nothing ? e + 1 : last(z) + 1
            end
            continue
        end
        isempty(new) && continue
        for (k, v, va, vb) in attrs
            i = findfirst(p -> p.first == k, new)
            i === nothing && continue
            write(out, SubString(s, pos, prevind(s, va)))
            _escape_attr(out, new[i].second)
            pos = vb + 1
        end
    end
    pos <= b && write(out, SubString(s, pos, b))
    return
end

# The last sheet's `<table:table ` before byte `i`: in a flat file a chart is inline, and its local
# table (`table:name="local-table"`, F-079) is no sheet.
function _sheet_table_before(s::String, i::Int)
    while (tt = findprev("<table:table ", s, i)) !== nothing
        o = findprev("<draw:object", s, first(tt))
        if o !== nothing
            oe = first(o) - 1 + _start_tag_end(SubString(s, first(o)))
            if s[prevind(s, oe)] != '/'                  # an inline object, not a zipped file's reference
                c = findnext("</draw:object>", s, oe)
                if c !== nothing && first(c) > first(tt)
                    i = first(o) - 1
                    continue
                end
            end
        end
        return tt
    end
    return nothing
end

"""
    cf_rewrites(rw, content) -> Dict

The conditional formats of a document (`calcext:conditional-format` and their conditions), with their
conditions and bases replayed: for the `style:map`s that duplicate them.
"""
function cf_rewrites!(rw::RefRewriter, s::String)
    i = 1
    sheet = ""
    while (r = findnext("<calcext:conditional-format ", s, i)) !== nothing
        ct = first(r)
        tt = _sheet_table_before(s, ct)
        if tt !== nothing
            ta = _tag_attrs(s, first(tt), first(tt) - 1 + _start_tag_end(SubString(s, first(tt))))
            k = findfirst(x -> x[1] == "table:name", ta)
            sheet = k === nothing ? "" : ta[k][2]
        end
        ce = ct - 1 + _start_tag_end(SubString(s, ct))
        ta = _tag_attrs(s, ct, ce)
        k = findfirst(x -> x[1] == "calcext:target-range-address", ta)
        stop = something(findnext("</calcext:conditional-format>", s, ce), ce:ce)
        if k !== nothing
            target = ta[k][2]
            j = ce
            while (c = findnext("<calcext:condition ", s, j)) !== nothing && first(c) < first(stop)
                e = first(c) - 1 + _start_tag_end(SubString(s, first(c)))
                ca = _tag_attrs(s, first(c), e)
                vi = findfirst(x -> x[1] == "calcext:value", ca); bi = findfirst(x -> x[1] == "calcext:base-cell-address", ca)
                if vi !== nothing && bi !== nothing
                    v = ca[vi][2]; b = ca[bi][2]
                    nv, nb = _replay_condition(rw, v, b, target, sheet)
                    rw.cf[(_condition_body(v), b)] = (_condition_body(nv), nb)
                end
                j = e
            end
        end
        i = last(stop) + 1
    end
    return rw
end

# settings.xml (or a flat document's office:settings) after sheet operations (phase 5, D-053):
# the entries keyed by sheet name follow renames, deletes and copies, as LibreOffice keeps them
# (F-047): each view's per-sheet entries (`Tables`), the sheets' code names
# (`ScriptConfiguration`), and the active sheet (`ActiveTable`). Everything else is kept as it is.
# The settings are read as XML.jl trees (write/xmlparts.jl): names are compared unescaped, so a
# sheet LibreOffice writes as `Bob&apos;s` is found (D-101).

const _SHEET_MAPS = ("Tables", "ScriptConfiguration")

# Applies `f(inner, mapname)` to the content of every named map holding entries keyed by sheet
# name; an empty map (`<…/>`) is left as it is.
function _in_sheet_maps(f::Function, s::String)
    splices = Tuple{Int,Int,Any}[]
    for e in _xelements(s)
        (e.tag == "config:config-item-map-named" && e.inner !== nothing) || continue
        m = _xattr(e, "config:name")
        m in _SHEET_MAPS || continue
        inner = String(SubString(s, first(e.inner), last(e.inner)))
        new = f(inner, m)
        new == inner || push!(splices, (first(e.inner), last(e.inner), new))
    end
    return isempty(splices) ? s : _apply_splices(s, splices)
end

_entry_open(name) = "<config:config-item-map-entry config:name=\"" * _escape_attr(name) * "\">"

# The span of the entry for `name` among a map's entries (`inner`, its content), or nothing.
function _entry_span(inner::AbstractString, name::AbstractString)
    e = _xfirst(inner, "config:config-item-map-entry", "config:name", name; depth = 1)
    return e === nothing ? nothing : e.span
end

# `text` (an entry) with its name `name`.
_entry_named(text::AbstractString, name::AbstractString) =
    _set_attrs(text, Pair{String,Union{Nothing,String}}["config:name" => _escape_attr(name)]; open = !endswith(text, "/>")) *
    SubString(text, nextind(text, _start_tag_end(text)))

# The settings with the active sheet's name `f(current)`.
function _set_active(s::String, f::Function)
    splices = Tuple{Int,Int,Any}[]
    for e in _xfind(s, "config:config-item", "config:name", "ActiveTable")
        (e.inner === nothing || _xattr(e, "config:type") != "string") && continue
        cur = XML.unescape(String(SubString(s, first(e.inner), last(e.inner))))
        new = f(cur)
        new == cur || push!(splices, (first(e.inner), last(e.inner), sprint(_escape_text, new)))
    end
    return isempty(splices) ? s : _apply_splices(s, splices)
end

function _settings_rename(s::String, old::String, new::String)
    s = _in_sheet_maps(s) do inner, _
        sp = _entry_span(inner, old)
        sp === nothing && return inner
        return inner[1:prevind(inner, first(sp))] * _entry_named(inner[sp], new) * inner[nextind(inner, last(sp)):end]
    end
    return _set_active(s, cur -> _same_sheet(cur, old) ? new : cur)
end

function _settings_delete(s::String, name::String, order::Vector{String})
    s = _in_sheet_maps(s) do inner, _
        sp = _entry_span(inner, name)
        sp === nothing ? inner : inner[1:prevind(inner, first(sp))] * inner[nextind(inner, last(sp)):end]
    end
    i = _sheet_index(order, name)
    other = i === nothing || length(order) < 2 ? "" : i > 1 ? order[i - 1] : order[2]
    return _set_active(s, cur -> _same_sheet(cur, name) ? other : cur)
end

function _settings_copy(s::String, src::String, dst::String)
    return _in_sheet_maps(s) do inner, m
        if m == "ScriptConfiguration"
            inner * _entry_open(dst) * "<config:config-item config:name=\"CodeName\" config:type=\"string\">" *
                sprint(_escape_text, dst) * "</config:config-item></config:config-item-map-entry>"
        else
            sp = _entry_span(inner, src)
            sp === nothing ? inner : inner * _entry_named(inner[sp], dst)
        end
    end
end

# Whether settings.xml changes: after sheet operations, a change of a sheet's visibility, or view
# settings set (phase 5 step 8).
_settings_edited(xf::ODSFile) = any(op -> !(op isa LineShift), xf.ops) || xf.tstyles.shown_changed || _views_edited(xf)

"""
    patched_settings(xf, s) -> String

The settings `s` (settings.xml, or a flat document's office:settings) after the sheet operations
in `xf.ops`, in order, and with the active sheet moved off a sheet that was hidden (phase 5 step 6).
"""
function patched_settings(xf::ODSFile, s::String)
    s = _settings_ops(xf, s)
    xf.tstyles.shown_changed && (s = _settings_shown(xf, s))     # src/write/sheetprops.jl
    return _settings_views(xf, s)                               # src/write/views.jl
end

# The settings after the sheet operations alone.
function _settings_ops(xf::ODSFile, s::String)
    for op in xf.ops
        if op isa SheetRename
            s = _settings_rename(s, op.old, op.new)
        elseif op isa SheetDelete
            s = _settings_delete(s, op.name, op.order)
        elseif op isa SheetCopy
            s = _settings_copy(s, op.src, op.dst)
        end
    end
    return s
end

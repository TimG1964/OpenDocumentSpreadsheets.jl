# Number formats on cells (phase 4): `setFormat`, `getFormat`, `setUniformFormat`, and the
# text a cell shows, `getText`.
#
# The API follows XLSX.jl 0.13.4 (src/cellformats/numberformat.jl; `builtinFormats` and
# `builtinFormatNames` in src/cellformat-helpers.jl; `getText` in
# src/cellformats/displaytext.jl), MIT License, Copyright (c) 2018-2026 Felipe Noronha
# Tavares and other contributors. Codes are stored as ODF data styles (numberstyle.jl), and
# shown as LibreOffice shows them (SheetCore's engine with `libreoffice=true`, F-030).

"""
    BUILTIN_FORMATS

Excel's built-in number formats, by their ids.
"""
const BUILTIN_FORMATS = Dict{Int,String}(
    0 => "General", 1 => "0", 2 => "0.00", 3 => "#,##0", 4 => "#,##0.00",
    5 => "\$#,##0_);(\$#,##0)", 6 => "\$#,##0_);[Red](\$#,##0)", 7 => "\$#,##0.00_);(\$#,##0.00)",
    8 => "\$#,##0.00_);[Red](\$#,##0.00)", 9 => "0%", 10 => "0.00%", 11 => "0.00E+00", 12 => "# ?/?",
    13 => "# ??/??", 14 => "m/d/yyyy", 15 => "d-mmm-yy", 16 => "d-mmm", 17 => "mmm-yy", 18 => "h:mm AM/PM",
    19 => "h:mm:ss AM/PM", 20 => "h:mm", 21 => "h:mm:ss", 22 => "m/d/yyyy h:mm", 37 => "#,##0_);(#,##0)",
    38 => "#,##0_);[Red](#,##0)", 39 => "#,##0.00_);(#,##0.00)", 40 => "#,##0.00_);[Red](#,##0.00)",
    45 => "mm:ss", 46 => "[h]:mm:ss", 47 => "mm:ss.0", 48 => "##0.0E+0", 49 => "@")
const BUILTIN_FORMAT_NAMES = Dict("General" => 0, "Number" => 2, "Currency" => 7, "Percentage" => 9,
                                  "ShortDate" => 14, "LongDate" => 15, "Time" => 21, "Scientific" => 48)
const _BUILTIN_IDS = Dict(v => k for (k, v) in BUILTIN_FORMATS)
const _FIRST_CUSTOM_ID = 164

# The code `format` names: a built-in code, a built-in name (in any case), a built-in id, or
# a code (in XLSX.jl's order: `"0"` is the code 0, not the id of General).
function _format_code(format::AbstractString)
    haskey(_BUILTIN_IDS, format) && return String(format)
    for (n, id) in BUILTIN_FORMAT_NAMES
        lowercase(n) == lowercase(format) && return BUILTIN_FORMATS[id]
    end
    id = tryparse(Int, format)
    id !== nothing && haskey(BUILTIN_FORMATS, id) && return BUILTIN_FORMATS[id]
    _check_xml_text(format)
    SC.is_valid_format(format) || throw(ODSError("`$format` is not a valid number format."))
    return String(format)
end

# The data style a style shows: its own, else its parents'.
function _resolved_datastyle(st::StyleIndex, cs::CellStyle)
    for s in _style_chain(st, cs)
        isempty(s.datastyle) || return s.datastyle
    end
    return ""
end

function _format_transform(st::StyleIndex, caller::Symbol; format::Union{Nothing,AbstractString} = nothing, kw...)
    _check_keywords(caller, kw)
    format === nothing && return identity
    code = _format_code(format)
    ds = add_number_format!(st, code)
    return function (cs::CellStyle)
        d = ds
        # General under a parent with a format of its own: say so (LibreOffice's Standard, D-037)
        isempty(d) && !isempty(_resolved_datastyle(st, with_datastyle(cs, ""))) && (d = general_data_style!(st))
        return with_datastyle(cs, d)
    end
end

"""
    setFormat(sheet, ref; format) -> String or -1
    setFormat(sheet, row, col; format)
    setFormat(xf, "Sheet1.A1:B2"; format)

Set the number format of cells (address forms as [`setFont`](@ref)). `format` is:
- a built-in name: `"General"`, `"Number"` (`0.00`), `"Currency"`, `"Percentage"` (`0%`),
  `"ShortDate"` (`m/d/yyyy`), `"LongDate"` (`d-mmm-yy`), `"Time"` (`h:mm:ss`), `"Scientific"`
  (`##0.0E+0`);
- a built-in id, as a string (`"39"` is `#,##0.00_);(#,##0.00)`);
- or a format code, checked as Excel checks it (`"#,##0.00"`, `"d mmm yyyy"`, `"[Red]0.0%"`).

The code is stored as an ODF data style, in the form LibreOffice writes for it: a
code of several sections becomes one style per section, chosen by `style:map` conditions.
A value whose type doesn't fit the format is not converted: a date cell given `"0.00"`
stays a date cell, which LibreOffice shows as a number and retypes when it saves.
Returns the name of the cell's new style for a single cell, else -1.
"""
setFormat(x::Union{Worksheet,ODSFile}, ref...; kw...) =
    apply_format!(_format_transform(_styles_of(x), :setFormat; kw...), format_targets(x, ref...))

"""
    CellFormat(numFmtId, format, applyNumberFormat)

A cell's number format, as [`getFormat`](@ref) returns it:
`format["numFmt"]` holds `"numFmtId"` and `"formatCode"`.
"""
struct CellFormat
    numFmtId::Int
    format::Dict{String,Union{Nothing,Dict{String,String}}}
    applyNumberFormat::String
end

# The code of a data style: as `setFormat` was given it, for one added in this session (ODF
# can't hold the code itself), else rebuilt from the style.
function _code_of_style(sh::StyleSheet, ds::AbstractString)
    isempty(ds) && return "General"
    for (code, name) in sh.code_styles
        name == ds && return code
    end
    return data_style_code(sh, ds)
end

# The numFmtId of a code: a built-in one's, else one from 164 in the order codes are met.
_numfmt_id(sh::StyleSheet, code::String) =
    get(_BUILTIN_IDS, code, nothing) === nothing ? get!(sh.numfmt_ids, code, _FIRST_CUSTOM_ID + length(sh.numfmt_ids)) : _BUILTIN_IDS[code]

"""
    getFormat(sheet, ref) -> CellFormat
    getFormat(sheet, row, col) / getFormat(xf, "Sheet1.A1")

The number format of one cell: its code (read back from the ODF data style, as Excel's
code for it) and an id, Excel's built-in id where the code is a built-in one, else one from
164 up. An unformatted cell has `General` (id 0). Works on read-only files.
"""
function getFormat(x::Union{Worksheet,ODSFile}, ref...)
    ws, r, c = format_cell(x, ref...)
    st = get_odsfile(ws).styles
    sh = stylesheet(st)
    id = effective_style(ws, r, c)
    cs = cell_style(st, id)
    code = _code_of_style(sh, _resolved_datastyle(st, cs))
    fid = _numfmt_id(sh, code)
    applied = any(s -> !isempty(s.datastyle), _style_chain(st, cs)) && code != "General"
    return CellFormat(fid, Dict{String,Union{Nothing,Dict{String,String}}}("numFmt" => Dict("numFmtId" => string(fid), "formatCode" => code)),
                      applied ? "1" : "0")
end

"""
    setUniformFormat(sheet, ref; format) -> String

Format the first (top-left) cell of `ref` with [`setFormat`](@ref), then give every cell of
`ref` that cell's number format. Returns the first cell's style name.
"""
function setUniformFormat(x::Union{Worksheet,ODSFile}, ref...; kw...)
    st = _styles_of(x)
    t = _format_transform(st, :setUniformFormat; kw...)
    targets = format_targets(x, ref...)
    ws, r, c = _first_cell(targets)
    first_id = _style_map(t, st)(effective_style(ws, r, c))
    ds = _resolved_datastyle(st, cell_style(st, first_id))
    apply_format!(cs -> with_datastyle(cs, ds), targets)
    return style_name(st, effective_style(ws, r, c))
end

#
# The text a cell shows
#

# A cell's value as the engine takes it: a day number for dates and times (from the
# document's null date), a number, a string or a Bool.
function _engine_value(d::CellData, null_date::Dates.Date)
    k = d.kind
    if k === CK_STRING
        return something(d.text, "")
    elseif k === CK_BOOL
        return d.bits != 0
    elseif k === CK_DATE
        return Float64(reinterpret(Int64, d.bits) - Dates.value(null_date))
    elseif k === CK_DATETIME
        return (reinterpret(Int64, d.bits) - Dates.value(Dates.DateTime(null_date))) / 86_400_000
    elseif k === CK_TIME
        return reinterpret(Int64, d.bits) / 86_400e9
    end
    return reinterpret(Float64, d.bits)
end

# The code each style id shows, and its parsed sections, cached for many cells.
const _CodeCache = Dict{Int32,Tuple{String,Union{Nothing,Vector{SheetCore._FmtSection}}}}

function _code_of(st::StyleIndex, id::Int32, cache::_CodeCache)
    get!(cache, id) do
        code = data_style_code(stylesheet(st), _resolved_datastyle(st, cell_style(st, id)))
        (code, code == "BOOLEAN" ? nothing : SC._parse_numfmt(code))
    end
end

"""
    cell_text(ws, row, col; for_width=false, cache) -> String

The text cell (row, col) shows (see [`getText`](@ref)). With `for_width`, padding is given as
the characters whose width it takes, for measuring the text.
"""
function cell_text(ws::Worksheet, row::Integer, col::Integer; for_width::Bool = false, cache::_CodeCache = _CodeCache(),
                   store::SheetStore = _store_for(ws, row:row))
    d = cell_data(store, row, col)
    d === nothing && return ""
    d.kind === CK_EMPTY && return ""                    # a formula without a value
    d.kind === CK_ERROR && return something(d.text, "")
    xf = get_odsfile(ws)
    code, sections = _code_of(xf.styles, d.style, cache)
    v = _engine_value(d, xf.null_date)
    if code == "BOOLEAN"
        return (v isa Bool ? v : v isa Real ? v != 0 : nothing) |> b -> b === nothing ? String(v) : (b ? "TRUE" : "FALSE")
    end
    return SC._display_text(v, code; epoch = xf.null_date, for_width, libreoffice = true, sections)
end

"""
    getText(sheet, ref) -> String
    getText(sheet, row, col) / getText(xf, "Sheet1.A1")

The text a cell shows: its value in its number format, as LibreOffice shows it when the
column is wide enough. `1234.5` formatted `"#,##0.00"` is `"1,234.50"`, a date
formatted `"d mmm yyyy"` is `"7 Mar 2026"`. A formula shows its stored value; an empty cell,
or a formula without a value, is `""`; an error shows its text.

`getText` shows a value as LibreOffice does: General shows
up to 15 significant digits, `?` pads with a figure space (U+2007), `0.##` of a whole number
has no point, seconds are truncated, and day numbers count from the document's null date.
A fill (`*x`) is left out, as there is no column width. Works on read-only files.
"""
function getText(x::Union{Worksheet,ODSFile}, ref...)
    ws, r, c = format_cell(x, ref...)
    return cell_text(ws, r, c)
end

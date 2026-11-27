# Rich text (D-088): XLSX.jl's `RichTextRun` and `RichTextString`, a cell's text in runs each with its
# own font attributes. In ODF a run is a `text:span` with an automatic text style; a line break starts a
# new paragraph (experiment 040, F-087).
# The types follow XLSX.jl 0.13.4 (src/types.jl, src/sst.jl), MIT License, Copyright (c) 2018-2026 Felipe
# Noronha Tavares and other contributors: names, fields, attributes, checks and messages.

const ValidRichTextAttributes = [:bold, :italic, :under, :strike, :vertAlign, :color, :size, :name]

"""
    RichTextRun(text::AbstractString, pairs::Union{Nothing,Vector{Pair{Symbol,Any}}} = nothing) -> RichTextRun

One run of a [`RichTextString`](@ref): its text and none, one or several font attributes:
- `:bold`, `:italic`, `:under`, `:strike`: `true` to set it;
- `:vertAlign`: `"superscript"` or `"subscript"`;
- `:color`: a colour, as hex (`"FF0000"`, `"FFFF0000"`) or a name (`"red"`);
- `:size`: the font size in points;
- `:name`: the font's name.

An attribute a run doesn't set is the cell's, as in LibreOffice.

```julia
rt = RichTextString(RichTextRun("Water is H"), RichTextRun("2", [:vertAlign => "subscript"]),
                    RichTextRun("O!", [:bold => true]))
sh["A1"] = rt
```
"""
struct RichTextRun
    text::String
    atts::Union{Nothing,Dict{Symbol,Any}}
    function RichTextRun(text::AbstractString, pairs::Union{Nothing,Vector{<:Pair{Symbol}}} = nothing)
        isempty(text) && throw(ODSError("Cannot create a RichTextRun with no text."))
        pairs === nothing && return new(String(text), nothing)
        atts = Dict{Symbol,Any}(pairs)
        for x in keys(atts)
            x in ValidRichTextAttributes ||
                throw(ODSError("Unknown Rich Text Attribute: ':$x'. Valid attributes are :bold, :italic, :under, :strike, :vertAlign, :color, :size, :name."))
        end
        haskey(atts, :color) && SheetCore.odf_color(atts[:color])             # an invalid colour is an error here
        v = get(atts, :vertAlign, nothing)
        v === nothing || v in ("superscript", "subscript", "baseline") ||
            throw(ODSError("Invalid vertAlign: \"$v\". Must be \"superscript\", \"subscript\" or \"baseline\"."))
        s = get(atts, :size, nothing)
        s === nothing || (s isa Real && 1 <= s <= 409) || throw(ODSError("Invalid size value: $s. Must be between 1 and 409."))
        return new(String(text), atts)
    end
end

"""
    RichTextString(runs::RichTextRun...) -> RichTextString
    RichTextString(runs::Vector{RichTextRun}) -> RichTextString

A cell's text made of runs, each with its own font attributes (see [`RichTextRun`](@ref)). Its text is the runs' joined; a `"\\n"` starts a new line (a paragraph in ODF).

Written to a cell (`sheet["A1"] = rt`), each run with attributes is a span with a text style, as
LibreOffice keeps one. A string of one run is written as plain text, the run's
attributes the cell's font ([`setFont`](@ref)), but a superscript or subscript, which a cell style
can't hold. [`getRichTextString`](@ref) reads one back.
"""
struct RichTextString <: AbstractString
    text::String
    runs::Vector{RichTextRun}
    function RichTextString(text::String, runs::Vector{RichTextRun})
        (isempty(text) || isempty(runs)) && throw(ODSError("Cannot create an empty RichTextString"))
        return new(text, runs)
    end
end
function RichTextString(runs::Vector{RichTextRun})
    isempty(runs) && throw(ODSError("Cannot create a RichTextString with no RichTextRuns"))
    return RichTextString(join(r.text for r in runs), runs)
end
RichTextString(runs::RichTextRun...) = RichTextString(collect(runs))

# An AbstractString: its text.
Base.String(s::RichTextString) = s.text
Base.ncodeunits(s::RichTextString) = ncodeunits(s.text)
Base.codeunit(s::RichTextString) = codeunit(s.text)
Base.codeunit(s::RichTextString, i::Integer) = codeunit(s.text, i)
Base.isvalid(s::RichTextString, i::Integer) = isvalid(s.text, i)
Base.iterate(s::RichTextString, i::Integer = 1) = iterate(s.text, i)

# Attributes compared as they are written: colours as RGB, sizes as numbers, flags as true.
function _norm_atts(a::Union{Nothing,Dict{Symbol,Any}})
    a === nothing && return Dict{Symbol,Any}()
    d = Dict{Symbol,Any}()
    for (k, v) in a
        if k in (:bold, :italic, :under, :strike)
            v in (true, 1) && (d[k] = true)
        elseif k === :color
            d[k] = uppercase(lstrip(SheetCore.odf_color(v), '#'))
        elseif k === :size
            d[k] = Float64(v)
        elseif k === :vertAlign
            v == "baseline" || (d[k] = String(v))
        else
            d[k] = String(v)
        end
    end
    return d
end
Base.:(==)(a::RichTextRun, b::RichTextRun) = a.text == b.text && _norm_atts(a.atts) == _norm_atts(b.atts)
Base.hash(r::RichTextRun, h::UInt) = hash(_norm_atts(r.atts), hash(r.text, hash(:RichTextRun, h)))
Base.:(==)(a::RichTextString, b::RichTextString) = a.runs == b.runs
# As an AbstractString it equals its plain text (`rts == "ab"`), so it hashes as that text: values
# that are `isequal` must hash alike (a Set held it and "ab" twice). Two with the same text and
# different formats differ, and share a hash.
Base.hash(s::RichTextString, h::UInt) = hash(s.text, h)

function Base.show(io::IO, r::RichTextRun)
    print(io, "RichTextRun (", repr(r.text), "  [")
    a = r.atts === nothing ? Pair{Symbol,Any}[] : sort!(collect(r.atts); by = first)
    print(io, isempty(a) ? " " : join((repr(p) for p in a), ", "), "])")
end
function Base.show(io::IO, ::MIME"text/plain", s::RichTextString)
    println(io, "RichTextString: ", repr(s.text), " ")
    println(io, " containing ", length(s.runs), " run", length(s.runs) == 1 ? "" : "s", ":")
    println(io, " Run text                 Run attributes")
    print(io, " ", repeat('-', 91))
    for r in s.runs
        a = r.atts === nothing ? Pair{Symbol,Any}[] : sort!(collect(r.atts); by = first)
        attxt = "[" * (isempty(a) ? " " : join((repr(p) for p in a), ", ")) * "]"
        print(io, "\n ", rpad(repr(r.text), 24), " ", attxt)
    end
end

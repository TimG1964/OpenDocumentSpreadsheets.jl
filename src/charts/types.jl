# The chart types, with XLSX.jl's names and fields (D-085). A handle holds a chart's identity and
# anchor; everything else is read from the chart as it is now, on each call.

"""
    ChartRef

One reference of a chart series, with the values its cells hold now (LibreOffice draws a chart from
its cells).

# Fields
- `kind::Symbol`: `:num` when every value is a number (or empty), else `:str`; `:strLit` for a series
  name given as text (`loext:label-string`).
- `ref::Union{Nothing,String}`: the reference in this package's notation (`Data.B2:B7`); `nothing` for
  a literal.
- `format_code::Union{Nothing,String}`: the number format of the first number (`"General"`…), or
  `nothing`.
- `ptCount::Int`: the number of points (cells).
- `data::Vector`: the values, `missing` for empty cells and errors.
- `errors::Dict{Int,String}`: position => error text (`"#DIV/0!"`): every error.
"""
struct ChartRef
    kind::Symbol
    ref::Union{Nothing,String}
    format_code::Union{Nothing,String}
    ptCount::Int
    data::Vector
    errors::Dict{Int,String}
end

"""
    ChartSeries

One series (`chart:series`), as read. `categories` holds the chart's categories for category charts,
and the series' x values for XY and bubble charts; `values` its values (y values); `bubble_sizes` a
bubble series' sizes. `idx` and `order` are its place in the chart, from 0. `charttype` is its group's
tag (`:barChart`…). `raw` is the element.
"""
struct ChartSeries
    idx::Int
    order::Int
    charttype::Symbol
    name::Union{Nothing,String}
    name_ref::Union{Nothing,ChartRef}
    categories::Union{Nothing,ChartRef}
    values::Union{Nothing,ChartRef}
    bubble_sizes::Union{Nothing,ChartRef}
    raw::Union{Nothing,XML.Node}
end

"""
    ChartRange

A series reference as a range: a `SheetCellRef`, `SheetCellRange`, `SheetRowRange`,
`SheetColumnRange` or `NonContiguousRange`, or `nothing` where there is none.
"""
const ChartRange = Union{Nothing,SheetCellRef,SheetCellRange,SheetRowRange,SheetColumnRange,NonContiguousRange}

"""
    ChartRanges

What [`getChartRanges`](@ref) gives for one series: `idx`, `name`, and its `categories`, `values` and
`bubble_sizes` ranges.
"""
const ChartRanges = @NamedTuple{idx::Int, name::Union{Nothing,String}, categories::ChartRange,
                                values::ChartRange, bubble_sizes::ChartRange}

"""
    AbstractChart

Supertype of [`Chart`](@ref) and [`ChartEx`](@ref).
"""
abstract type AbstractChart end

"""
    Chart

A handle to one chart: its object and anchor. Its content is read from the chart as it is now, on
each call.

# Fields
- `package`: the [`ODSFile`](@ref OpenDocumentSpreadsheets.ODSFile).
- `path`: the object's content, `"Object 1/content.xml"`.
- `name`: the object's name, `"Object 1"`.
- `rId`: always `nothing` (ODF has no relationships).
- `sheet`: the sheet the chart is on.
- `from`, `to`: the cells its frame starts and ends in (a page-anchored frame's, from its position).
"""
struct Chart <: AbstractChart
    package::ODSFile
    path::String
    name::String
    rId::Union{Nothing,String}
    sheet::Union{Nothing,String}
    from::Union{Nothing,String}
    to::Union{Nothing,String}
end

"""
    ChartEx

A handle to a chart made with [`addChartEx`](@ref): in LibreOffice, a histogram
(`loext:histogram`). Fields as [`Chart`](@ref)'s.
"""
struct ChartEx <: AbstractChart
    package::ODSFile
    path::String
    name::String
    rId::Union{Nothing,String}
    sheet::Union{Nothing,String}
    from::Union{Nothing,String}
    to::Union{Nothing,String}
end

Base.:(==)(a::T, b::T) where {T<:AbstractChart} = a.package === b.package && a.name == b.name
Base.hash(c::AbstractChart, h::UInt) = hash(c.name, hash(objectid(c.package), hash(typeof(c), h)))
Base.show(io::IO, c::AbstractChart) =
    print(io, nameof(typeof(c)), "(", repr(c.name), something(c.sheet, "") == "" ? "" : " on " * repr(c.sheet),
          c.from === nothing ? "" : " at " * c.from * ":" * something(c.to, c.from), ")")

"""
    ChartGroup

One group of a chart's series: those of one type on one pair of axes. `kind` is its tag
(`:barChart`, `:lineChart`…), `axids` its axes (1, 2 primary; 3, 4 secondary).
"""
struct ChartGroup
    kind::Symbol
    axids::Vector{Int}
    raw::Union{Nothing,XML.Node}
end
Base.:(==)(a::ChartGroup, b::ChartGroup) = a.kind == b.kind && a.axids == b.axids
Base.hash(g::ChartGroup, h::UInt) = hash(g.axids, hash(g.kind, h))

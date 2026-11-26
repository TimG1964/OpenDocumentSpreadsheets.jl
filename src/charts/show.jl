# How the chart types show at the REPL (issue #1's audit). XLSX.jl's displays for the types it has them
# for (`charts/discovery.jl`, `charts/drawingml.jl`), without its `XLSX.Charts.` prefix, as `Chart`'s
# one-line form here has none; compact forms for the others. Nothing shows a `raw` XML node, and the
# one-line forms read nothing from the chart, so a vector of charts displays at once.

function Base.show(io::IO, ::MIME"text/plain", c::AbstractChart)
    print(io, nameof(typeof(c)), " ", repr(c.name))
    c.sheet === nothing || print(io, " on sheet ", repr(c.sheet))
    c.from === nothing || print(io, " at ", c.from, ":", something(c.to, c.from))
    t = getChartTitle(c)
    t === nothing || print(io, "\n  title: ", repr(t))
    if c isa ChartEx
        print(io, "\n  type: ", getChartType(c), "\n  series: ", getChartSeriesCount(c))
        return
    end
    print(io, "\n  type: ", join(string.(getChartTypes(c)), ", "))
    series = getChartSeries(c)
    print(io, "\n  series: ", length(series))
    for (i, s) in enumerate(series)
        print(io, "\n    [", i, "] ", something(s.name, "Series$i"))
        s.values === nothing || print(io, " - ", something(s.values.ref, "<literal>"), " (", s.values.ptCount, " pts)")
    end
end

Base.show(io::IO, s::ChartSeries) = print(io, "ChartSeries(", something(s.name, "<unnamed>"), ", ", s.charttype, ")")
function Base.show(io::IO, ::MIME"text/plain", s::ChartSeries)
    print(io, "ChartSeries ", something(s.name, "<unnamed>"), " (", s.charttype, ")")
    for (label, r) in (("categories", s.categories), ("values", s.values), ("sizes", s.bubble_sizes))
        r === nothing && continue
        print(io, "\n  ", label, ": ", something(r.ref, "<literal>"), " - ", r.ptCount, " pts, ", r.kind)
    end
end

Base.show(io::IO, r::ChartRef) = print(io, "ChartRef(", something(r.ref, "<literal>"), ", ", r.ptCount, " pts)")
function Base.show(io::IO, ::MIME"text/plain", r::ChartRef)
    print(io, "ChartRef ", something(r.ref, "<literal>"), " (", r.kind, ", ", r.ptCount, " pts)")
    r.format_code === nothing || print(io, "\n  format: ", r.format_code)
    isempty(r.errors) || print(io, "\n  errors at: ", join(sort!(collect(keys(r.errors))), ", "))
    isempty(r.data) || print(io, "\n  data: ", r.data)
end

Base.show(io::IO, g::ChartGroup) = print(io, "ChartGroup(", repr(g.kind), ", axes ", g.axids, ")")

const _AXIS_POS = Dict(:b => "bottom", :l => "left", :t => "top", :r => "right")
function Base.show(io::IO, a::ChartAxis)
    print(io, "ChartAxis(", repr(a.kind), ", id ", a.axid)
    a.pos === nothing || print(io, ", ", get(_AXIS_POS, a.pos, string(a.pos)))
    a.deleted && print(io, ", hidden")
    print(io, ")")
end

Base.show(io::IO, m::ChartMarker) =
    print(io, "ChartMarker(", m.symbol === nothing ? "symbol inherited" : string(m.symbol),
          m.size === nothing ? "" : ", size $(m.size)", m.point_idx === nothing ? "" : ", point idx $(m.point_idx)", ")")
function Base.show(io::IO, ::MIME"text/plain", m::ChartMarker)
    print(io, "ChartMarker", m.point_idx === nothing ? " (series idx $(m.series_idx))" :
                             " (series idx $(m.series_idx), point idx $(m.point_idx))")
    print(io, "\n  symbol: ", m.symbol === nothing ? "inherited" : m.symbol)
    m.size === nothing || print(io, "\n  size: ", m.size, " pt")
    m.shape === nothing || print(io, "\n  shape: ", m.shape)
end

Base.show(io::IO, c::DrawingColor) =
    print(io, "DrawingColor(", c.val, " -> #", c.rgb, c.alpha == 1.0 ? "" : ", alpha " * string(round(c.alpha; digits = 3)), ")")
function Base.show(io::IO, ::MIME"text/plain", c::DrawingColor)
    print(io, "DrawingColor ", c.kind, " ", repr(c.val), "\n  resolves to: #", c.rgb)
    c.alpha == 1.0 || print(io, "\n  alpha: ", round(c.alpha; digits = 3))
    isempty(c.transforms) || print(io, "\n  transforms: ", join(("$k=$(v / 1000)%" for (k, v) in c.transforms), ", "))
end

_show_color(c::DrawingColor) = "#" * c.rgb
_show_color(c::AbstractString) = String(c)

Base.show(io::IO, fl::DrawingFill) =
    print(io, "DrawingFill(", fl.kind, fl.fgcolor === nothing ? "" : ", " * _show_color(fl.fgcolor),
          fl.bgcolor === nothing ? "" : " on " * _show_color(fl.bgcolor), ")")
function Base.show(io::IO, ::MIME"text/plain", fl::DrawingFill)
    print(io, "DrawingFill ", fl.kind)
    fl.preset === nothing || print(io, "\n  name: ", fl.preset)
    fl.fgcolor === nothing || print(io, "\n  foreground: ", _show_color(fl.fgcolor))
    fl.bgcolor === nothing || print(io, "\n  background: ", _show_color(fl.bgcolor))
end

function Base.show(io::IO, ln::DrawingLine)
    parts = String[]
    if ln.fill !== nothing
        push!(parts, ln.fill.kind === :none ? "no stroke" : ln.fill.fgcolor === nothing ? string(ln.fill.kind) :
                     _show_color(ln.fill.fgcolor))
    end
    ln.width === nothing || push!(parts, string(ln.width) * "pt")
    ln.dash === nothing || push!(parts, ln.dash)
    print(io, "DrawingLine(", isempty(parts) ? "inherited" : join(parts, ", "), ")")
end
function Base.show(io::IO, ::MIME"text/plain", ln::DrawingLine)
    print(io, "DrawingLine\n  stroke: ", ln.fill === nothing ? "inherited" : ln.fill.kind === :none ? "none" : sprint(show, ln.fill))
    ln.width === nothing || print(io, "\n  width: ", ln.width, " pt")
    for (label, v) in (("dash", ln.dash), ("cap", ln.cap), ("compound", ln.compound), ("join", ln.join))
        v === nothing || print(io, "\n  ", label, ": ", v)
    end
    ln.miter_limit === nothing || print(io, "\n  miter limit: ", ln.miter_limit, " × width")
end

function Base.show(io::IO, sp::DrawingShapeProps)
    parts = String[sp.fill === nothing ? "fill inherited" : "fill $(sp.fill.kind)"]
    if sp.line === nothing
        push!(parts, "line inherited")
    elseif sp.line.fill !== nothing && sp.line.fill.kind === :none
        push!(parts, "no line")
    else
        push!(parts, sp.line.width === nothing ? "line" : "line $(sp.line.width)pt")
    end
    sp.effects === nothing || push!(parts, "effects")
    print(io, "DrawingShapeProps(", join(parts, ", "), ")")
end

# The types XLSX.jl shows as they are: their set fields, without `raw`.
function _show_set_fields(io::IO, x)
    print(io, nameof(typeof(x)), "(")
    first = true
    for f in fieldnames(typeof(x))
        f === :raw && continue
        v = getfield(x, f)
        (v === nothing || v isa XML.Node) && continue
        first || print(io, ", ")
        print(io, f, " = ", repr(v; context = io))
        first = false
    end
    print(io, ")")
end
Base.show(io::IO, x::Union{DrawingRunProps,DrawingParaProps,DrawingBodyProps}) = _show_set_fields(io, x)

_run_text(r::DrawingRun) = something(r.text, "")
_para_text(p::DrawingParagraph) = join(_run_text(r) for r in p.runs)
_cut_text(s::AbstractString, n::Int) = length(s) <= n ? s : first(s, n - 1) * "…"

function Base.show(io::IO, r::DrawingRun)
    print(io, "DrawingRun(", repr(_run_text(r)))
    r.kind === :run || print(io, ", ", repr(r.kind))
    r.props === nothing || print(io, ", ", r.props)
    print(io, ")")
end
Base.show(io::IO, p::DrawingParagraph) =
    print(io, "DrawingParagraph(", repr(_cut_text(_para_text(p), 40)), ", ", length(p.runs), " run(s))")

function Base.show(io::IO, t::DrawingText)
    s = join((_para_text(p) for p in t.paragraphs), "\n")
    np = length(t.paragraphs)
    nr = sum(length(p.runs) for p in t.paragraphs; init = 0)
    if isempty(s)
        print(io, "DrawingText($np paragraph(s), formatting only)")
    else
        print(io, "DrawingText(", repr(_cut_text(s, 40)), ", $np paragraph(s), $nr run(s))")
    end
end

Base.show(io::IO, s::FormatSite) = print(io, "FormatSite(", repr(s.level), ", ", repr(s.kind), ")")

function Base.show(io::IO, e::Effective{T}) where {T}
    print(io, "Effective{", nameof(T), "}(")
    e.value === nothing ? print(io, "nothing") : show(io, e.value)
    e.site === nothing || print(io, " from ", e.site.level, " ", e.site.kind)
    print(io, ")")
end

function Base.show(io::IO, t::ChartTrendline)
    print(io, "ChartTrendline(", repr(t.kind))
    t.name === nothing || print(io, ", ", repr(t.name))
    print(io, ", series idx ", t.series_idx, ")")
end
Base.show(io::IO, b::ChartErrorBars) =
    print(io, "ChartErrorBars(", something(b.direction, "y"), ", ", something(b.bar_type, "both"), ", ",
          something(b.value_type, "?"), b.value === nothing ? "" : " $(b.value)", ", series idx ", b.series_idx, ")")
Base.show(io::IO, p::ChartDataPoint) = print(io, "ChartDataPoint(series idx ", p.series_idx, ", idx ", p.idx, ")")
Base.show(io::IO, l::ChartDataLabel) =
    print(io, "ChartDataLabel(series idx ", l.series_idx, ", idx ", l.idx, l.delete === true ? ", deleted" : "", ")")
Base.show(io::IO, b::ChartUpDownBars) =
    print(io, "ChartUpDownBars(", b.group, b.gap_width === nothing ? "" : ", gap width $(b.gap_width)", ")")

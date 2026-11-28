# Where a sheet's original rows (or columns) are now, after rows or columns were inserted or
# deleted (phase 5, D-049). A patched save walks the original XML and finds each original line's
# place through this map; lines inserted since have no original, and come from the model.

"""
    IndexMap(max)

A monotone map from a sheet's original lines (rows or columns, 1…`max`) to their current
numbers, as segments `(original start, length, current start)` in order. Deleted lines are in no
segment; inserted lines are current numbers no segment reaches.
"""
mutable struct IndexMap
    max::Int
    segs::Vector{NTuple{3,Int}}
end
IndexMap(max::Integer) = IndexMap(Int(max), [(1, Int(max), 1)])


"""
    insert_lines!(m, at, n)

`n` lines inserted before current line `at`. Lines pushed past the end are dropped.
"""
function insert_lines!(m::IndexMap, at::Int, n::Int)
    out = NTuple{3,Int}[]
    for (o, len, c) in m.segs
        if c >= at
            push!(out, (o, len, c + n))
        elseif c + len - 1 >= at
            k = at - c
            push!(out, (o, k, c))
            push!(out, (o + k, len - k, at + n))
        else
            push!(out, (o, len, c))
        end
    end
    m.segs = _clip(out, m.max)
    return m
end

"""
    delete_lines!(m, d1, d2)

Current lines `d1:d2` deleted.
"""
function delete_lines!(m::IndexMap, d1::Int, d2::Int)
    cnt = d2 - d1 + 1
    out = NTuple{3,Int}[]
    for (o, len, c) in m.segs
        e = c + len - 1
        if e < d1
            push!(out, (o, len, c))
        elseif c > d2
            push!(out, (o, len, c - cnt))
        else
            c < d1 && push!(out, (o, d1 - c, c))
            e > d2 && push!(out, (o + (d2 + 1 - c), e - d2, d1))
        end
    end
    m.segs = out
    return m
end

function _clip(segs::Vector{NTuple{3,Int}}, max::Int)
    out = NTuple{3,Int}[]
    for (o, len, c) in segs
        c > max && continue
        push!(out, (o, min(len, max - c + 1), c))
    end
    return out
end

"""
    current_line(m, o) -> Int

The current number of original line `o`, or 0 if it was deleted.
"""
function current_line(m::IndexMap, o::Int)
    for (so, len, c) in m.segs
        so <= o <= so + len - 1 && return c + (o - so)
    end
    return 0
end

"""
    line_pieces(m, o0, o1) -> Vector{NTuple{3,Int}}

The surviving parts of original lines `o0:o1`, as `(original start, length, current start)`.
"""
function line_pieces(m::IndexMap, o0::Int, o1::Int)
    out = NTuple{3,Int}[]
    for (so, len, c) in m.segs
        se = so + len - 1
        (se < o0 || so > o1) && continue
        a = max(so, o0); b = min(se, o1)
        push!(out, (a, b - a + 1, c + (a - so)))
    end
    return out
end

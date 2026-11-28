# The LibreOffice oracle helpers that formula/test_refs.jl, write/test_lines.jl, write/test_sheetops.jl
# and write/test_write.jl share (experiments 021, 022): loaded by runtests.jl before any group, so that
# each group can run on its own.

using OpenDocumentSpreadsheets: parse_ref, LineShift, tokenize_formula, FT_REF

# A TSV's rows, split on tabs, without its header.
read_tsv(path) = [split(l, '\t') for l in split(chomp(read(path, String)), r"\r?\n")[2:end]]

const ORDER = ["Data", "Other", "My Sheet", "Z"]

# file => (key, attribute) => value
function load_oracle(path)
    o = Dict{String,Dict{Tuple{String,String},String}}()
    for l in split(chomp(read(path, String)), r"\r?\n")[2:end]
        f, k, a, v = split(l, '\t'; limit = 4)
        get!(o, String(f), Dict{Tuple{String,String},String}())[(String(k), String(a))] = String(v)
    end
    return o
end

# "Data!R10C10" → ("Data", 10, 10)
function cellpos(s)
    m = match(r"^(.*)!R(\d+)C(\d+)$", s)
    return String(m.captures[1]), parse(Int, m.captures[2]), parse(Int, m.captures[3])
end

# "ins_r5_1", "del_other_c2_3", "q_del_r11_1" → LineShift
function lineop(name, order)
    m = match(r"^(?:q_)?(ins|del)_(?:(other|z)_)?([rc])(\d+)_(\d+)$", name)
    sheet = m.captures[2] === nothing ? order[1] : m.captures[2] == "other" ? "Other" : "Z"
    at = parse(Int, m.captures[4]); n = parse(Int, m.captures[5])
    return LineShift(sheet, m.captures[3] == "r" ? 1 : 2, at, m.captures[1] == "ins" ? n : -n, order)
end

basesheet(addr) = something(parse_ref(addr)[1].sheet, "")

# Every formula of a file's model, by (sheet, row, column): the saved file is compared with it
# (write/test_lines.jl, write/test_sheetops.jl).
model_formulas(xf) = Dict((ws.name, Int(rd.row), Int(r.col)) => r.data.formula
                          for ws in OpenDocumentSpreadsheets._sheets(xf) for rd in OpenDocumentSpreadsheets._cached_store(ws).rows
                          for r in rd.runs if r.data.formula !== nothing)

# A conditional format's references as seen from its target's top-left cell: what it means.
function cf_meaning(cond, base, target)
    b = parse_ref(base)[1]
    tl = parse_ref(SubString(target, OpenDocumentSpreadsheets._areas(String(target))[1]...))[1]
    out = String[]
    for t in tokenize_formula(cond)
        t.kind === FT_REF || continue
        ends = parse_ref(t.text[2:end-1])
        ends === nothing && (push!(out, t.text); continue)
        push!(out, join(map(ends) do e
            e.err && return "#REF!"
            c = e.col > 0 && !e.col_abs ? tl.col + e.col - b.col : e.col
            r = e.row > 0 && !e.row_abs ? tl.row + e.row - b.row : e.row
            string(e.col_abs ? "\$" : "", c, ",", e.row_abs ? "\$" : "", r)
        end, ":"))
    end
    return out
end

# Compares one rewritten value with LibreOffice's, recording a readable failure.
function check!(fails, what, got, want)
    got == want || push!(fails, "$what: got `$got`, LibreOffice `$want`")
    return got == want
end

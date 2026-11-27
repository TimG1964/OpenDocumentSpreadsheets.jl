# The docs: their examples run, they are written for someone who knows LibreOffice (XLSX.jl only on the
# home page and "Coming from XLSX.jl", issue #3), and their pictures are all there (issue #4).

include("docs_env.jl")

@testset "the docs' examples run" begin
    dir = docs_dir()
    nblocks = 0
    for p in docs_pages()
        for (k, ok, err) in run_docs_page(p, dir)
            ok || @error "a docs example fails" page = relpath(p, DOCS) example = k exception = err
            @test (relpath(p, DOCS), k, ok) == (relpath(p, DOCS), k, true)
            nblocks += 1
        end
    end
    @test nblocks > 50
end

# The ```julia examples in the docstrings of public names, which the API pages show: each runs in a
# module of its own, after the prelude the guide's pages get (`xf`, `sh`), next to the Tutorial's
# `budget.ods`, made again for each example.
function _docstring_examples(m::Module, n::Symbol)
    b = Base.Docs.Binding(m, n)
    out = String[]
    for mod in Base.Docs.modules
        meta = Base.Docs.meta(mod)
        haskey(meta, b) || continue
        for (_, d) in meta[b].docs
            text = join(string.(d.text))
            append!(out, String(x.captures[1]) for x in eachmatch(r"```julia\r?\n(.*?)```"s, text))
        end
    end
    return out
end

@testset "the docstrings' examples run" begin
    dir = docs_dir()
    nblocks = 0
    for m in (OpenDocumentSpreadsheets, OpenDocumentSpreadsheets.Charts), n in names(m)
        for (k, b) in enumerate(_docstring_examples(m, n))
            occursin("using DataFrames", b) && continue
            for f in readdir(dir)
                f in ("logo.png", "chart.jpg") || rm(joinpath(dir, f); recursive = true)
            end
            cd(_docs_budget, dir)
            mod = Module(Symbol("example_of_", n))     # not `n`: a module's name is bound inside it
            err = nothing
            try
                redirect_stdout(devnull) do
                    cd(dir) do
                        Core.eval(mod, :(using OpenDocumentSpreadsheets, OpenDocumentSpreadsheets.Charts))
                        Base.include_string(mod, _DOCS_PRELUDE, "prelude")
                        Base.include_string(mod, b, "$n example $k")
                    end
                end
            catch e
                err = (e, catch_backtrace())
            end
            err === nothing || @error "a docstring example fails" name = n example = k exception = err
            @test (n, k, err === nothing) == (n, k, true)
            nblocks += 1
        end
    end
    @test nblocks >= 20
end

# Words that belong only in records/, never in the docs: decision, finding and question ids, phases.
const _RECORD_IDS = r"\b[DFQ]-\d{3}\b|\b[Pp]hase \d"

@testset "the docs stand on their own" begin
    for p in docs_pages()
        rel = replace(relpath(p, DOCS), '\\' => '/')
        text = read(p, String)
        @test (rel, occursin(_RECORD_IDS, text)) == (rel, false)
        # the shared core is an implementation detail, not part of the docs (D-091)
        @test (rel, occursin("SheetCore", text)) == (rel, false)
        rel in ("index.md", "xlsx.md") && continue
        @test (rel, occursin("XLSX", text)) == (rel, false)
        # "LibreOffice's own" contrasts with XLSX.jl, which these pages don't assume (the docs audit)
        @test (rel, occursin("LibreOffice's own", text)) == (rel, false)
    end
    # The docstrings of public names, which the API pages show. `@doc` without REPL loaded gives the
    # docstring object, whose printed form holds its text. A name bound from the shared core has its
    # own docstrings here, not the core's (D-091). On Julia 1.11+ the printed form also holds each
    # method's signature, where the core's types are `OpenDocumentSpreadsheets.SheetCore.ColumnRange`:
    # only other mentions are wording.
    _core_words = r"(?<!OpenDocumentSpreadsheets\.)SheetCore|shared core|back end"
    for m in (OpenDocumentSpreadsheets, OpenDocumentSpreadsheets.Charts), n in names(m)   # the public names
        isdefined(m, n) || continue
        s = string(Core.eval(@__MODULE__, :(@doc $m.$n)))
        @test (m, n, occursin("XLSX", s), occursin(_RECORD_IDS, s), occursin(_core_words, s),
               occursin("LibreOffice's own", s)) == (m, n, false, false, false, false)
    end
end

@testset "the docs' pictures" begin
    imgdir = joinpath(DOCS, "images")
    pngs = Set(filter(endswith(".png"), readdir(imgdir)))
    used = Set{String}()
    for p in docs_pages()
        rel = relpath(p, DOCS)
        text = read(p, String)
        for m in eachmatch(r"!\[([^\]]*)\]\(([^)]*)\)", text)
            alt, src = m.captures
            @test (rel, src, length(strip(alt)) >= 20) == (rel, src, true)    # a description, not a label
            f = normpath(joinpath(dirname(p), src))
            @test (rel, src, isfile(f)) == (rel, src, true)
            push!(used, basename(f))
        end
        # every screenshot marker is followed by its picture
        for m in eachmatch(r"<!--\s*shot:\s*(\S+)[^>]*-->\s*\n!\[[^\]]*\]\(([^)]*)\)", text)
            @test (rel, basename(m.captures[2])) == (rel, m.captures[1] * ".png")
        end
        @test (rel, count("<!-- shot:", text)) ==
              (rel, length(collect(eachmatch(r"<!--\s*shot:\s*(\S+)[^>]*-->\s*\n!\[", text))))
    end
    @test setdiff(pngs, used) == Set{String}()            # no picture left unused
    @test sum(f -> filesize(joinpath(imgdir, f)), pngs; init = 0) <= 3 * 2^20
end

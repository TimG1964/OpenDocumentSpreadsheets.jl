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

# Words that belong only in records/, never in the docs: decision, finding and question ids, phases.
const _RECORD_IDS = r"\b[DFQ]-\d{3}\b|\b[Pp]hase \d"

@testset "the docs stand on their own" begin
    for p in docs_pages()
        rel = replace(relpath(p, DOCS), '\\' => '/')
        text = read(p, String)
        @test (rel, occursin(_RECORD_IDS, text)) == (rel, false)
        rel in ("index.md", "xlsx.md") && continue
        @test (rel, occursin("XLSX", text)) == (rel, false)
    end
    # The docstrings of public names, which the API pages show. `@doc` without REPL loaded gives the
    # docstring object, whose printed form holds its text.
    for m in (OpenDocumentSpreadsheets, OpenDocumentSpreadsheets.Charts), n in names(m)   # the public names
        isdefined(m, n) || continue
        s = string(Core.eval(@__MODULE__, :(@doc $m.$n)))
        @test (m, n, occursin("XLSX", s), occursin(_RECORD_IDS, s)) == (m, n, false, false)
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

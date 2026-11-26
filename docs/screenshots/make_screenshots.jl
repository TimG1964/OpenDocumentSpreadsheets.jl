# Makes the docs' pictures: runs every page's examples as the docs test does (`test/docs_env.jl`), and
# after each block followed by a screenshot marker, opens what it made in LibreOffice Calc and captures it
# (`capture.ps1`). Windows only, with LibreOffice installed and the desktop unlocked; see README.md.
#
#   julia --project=. docs/screenshots/make_screenshots.jl [name ...]
#
# With names, only those pictures are made (the pages still run in full, so each is made as the docs
# describe it).

using OpenDocumentSpreadsheets

include(joinpath(@__DIR__, "..", "..", "test", "docs_env.jl"))

const HERE = @__DIR__
const WORK = joinpath(HERE, "work")
const IMAGES = joinpath(DOCS, "images")
const SOFFICE = get(ENV, "ODS_SOFFICE", raw"C:\Program Files\LibreOffice\program\soffice.com")
const PROFILE = joinpath(WORK, "profile")
const ONLY = Set(ARGS)

# A throwaway profile, made by a headless run (a GUI start with a new profile shows first-start pages).
function ensure_profile()
    if !isdir(joinpath(PROFILE, "user"))
        mkpath(WORK)
        csv = joinpath(WORK, "init.csv")
        write(csv, "x\n")
        url = "file:///" * replace(PROFILE, '\\' => '/')
        run(pipeline(`$SOFFICE -env:UserInstallation=$url --headless --norestore --convert-to ods --outdir $WORK $csv`;
                     stdout = devnull, stderr = devnull))
        isdir(joinpath(PROFILE, "user")) || error("LibreOffice made no profile at $PROFILE")
    end
    # No automatic spell check: its red underlines would mark codes and names in the pictures.
    xcu = joinpath(PROFILE, "user", "registrymodifications.xcu")
    s = read(xcu, String)
    occursin("IsSpellAuto", s) && return
    item = """<item oor:path="/org.openoffice.Office.Linguistic/SpellChecking"><prop oor:name="IsSpellAuto" oor:op="fuse"><value>false</value></prop></item>\n"""
    write(xcu, replace(s, "</oor:items>" => item * "</oor:items>"))
end

# The workbook a marker shows: a file the block saved (`file=`), or a variable of the page (`xf=`, by
# default `xf`), saved to a file of its own, then opened for writing so that its view can be set.
function shot_file(m::Module, dir::AbstractString, shot::DocsShot)
    path = joinpath(WORK, shot.name * ".ods")
    for f in readdir(WORK)                                 # LibreOffice's lock files, if one was killed
        startswith(f, ".~lock.") && rm(joinpath(WORK, f))
    end
    isfile(path) && rm(path)
    if haskey(shot.opts, "file")
        cp(joinpath(dir, shot.opts["file"]), path)
    else
        xf = Core.eval(m, Symbol(get(shot.opts, "xf", "xf")))
        cd(() -> writeods(path, xf), dir)
    end
    openods(path; mode = "rw") do xf
        ws = haskey(shot.opts, "sheet") ? xf[shot.opts["sheet"]] : xf[1]
        ws === xf[1] || movesheet!(ws; before = 1)      # LibreOffice opens on the first sheet
        view = Dict{Symbol,Any}(:zoom => parse(Int, get(shot.opts, "zoom", "100")))
        top = get(shot.opts, "top", "A1")
        top == "keep" || (view[:topLeftCell] = top)
        cursor = get(shot.opts, "cursor", "A1")
        cursor == "keep" || (view[:activeCell] = cursor)
        setSheetView(ws; view...)
    end
    return path
end

function capture(path::AbstractString, shot::DocsShot)
    out = joinpath(IMAGES, shot.name * ".png")
    args = ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", joinpath(HERE, "capture.ps1"),
            "-File", path, "-Out", out, "-LoProfile", PROFILE]
    o = shot.opts
    haskey(o, "cells") && append!(args, ["-Cells", o["cells"]])
    haskey(o, "bar") && push!(args, "-Bar")
    haskey(o, "tabs") && push!(args, "-Tabs")
    haskey(o, "dropdown") && append!(args, ["-Keys", "%{DOWN}"])
    haskey(o, "preview") && append!(args, ["-Keys", "^+o"])
    haskey(o, "size") && append!(args, ["-Width", split(o["size"], 'x')[1], "-Height", split(o["size"], 'x')[2]])
    print(rpad(shot.name, 22))
    run(`powershell $args`)
end

function main()
    ensure_profile()
    mkpath(IMAGES)
    dir = docs_dir(joinpath(HERE, "..", "..", "test"))
    made = String[]
    after = function (m, k, shots)
        for s in shots
            isempty(ONLY) || s.name in ONLY || continue
            capture(shot_file(m, dir, s), s)
            push!(made, s.name)
        end
    end
    for p in docs_pages()
        for (k, ok, err) in run_docs_page(p, dir; after)
            ok || @error "a docs example fails" page = relpath(p, DOCS) example = k exception = err
        end
    end
    println(length(made), " pictures made")
    missing_ = setdiff(ONLY, made)
    isempty(missing_) || @warn "no marker for" missing_
end

main()

# Annotations and threaded comments (phase 6 step 4, D-073): LibreOffice's notes and `loext` threads
# (F-059), with XLSX.jl's API. Fixtures: experiment 030 (test/data/links).
using Dates
const O_N = OpenDocumentSpreadsheets
using OpenDocumentSpreadsheets: ODSError
const NT_OWN = joinpath(@__DIR__, "..", "data", "links", "lo-links-own.fods")
const NT_IMPORT = joinpath(@__DIR__, "..", "data", "links", "lo-links-xlsx-import.fods")
const NT_D = DateTime(2026, 11, 23, 10, 30)

_c4(c) = c[(:sheet, :ref, :author, :text)]      # XLSX.jl's fields (the date: test_lo_options.jl)
_notes(x) = [(c.ref, c.author, c.text) for c in O_N.getComments(x)]
_threads(x) = [(t.ref, t.author, t.text, t.date, t.resolved, [(r.author, r.text, r.date) for r in t.replies])
               for t in O_N.getThreadedComments(x)]

@testset "LibreOffice's own notes" begin
    ws = readods(NT_OWN)["Own"]
    @test _c4(O_N.getComment(ws, "B11")) == (sheet = "Own", ref = "B11", author = "Unknown Author", text = "A note")
    @test O_N.getComment(ws, "B13").text == "Line one\nLine two"
    @test O_N.getComment(ws, 14, 2).text == "On seven"                   # on a number
    @test O_N.getComment(ws, "B17").text == "On an empty cell"
    @test O_N.getComment(ws, "A1") === nothing
    @test_throws ODSError O_N.getComment(ws, "A1:B2")
    @test [n[1] for n in _notes(ws)] == ["B11", "B12", "B13", "B14", "B15", "B16", "B17", "B21"]
    @test isempty(O_N.getThreadedComments(ws))
end

@testset "LibreOffice's import of XLSX.jl's notes and threads" begin
    xf = readods(NT_IMPORT)
    ws = xf["Notes"]
    @test O_N.getComment(ws, "B1").author == "Ann Author"                # the import's shifted authors (F-059)
    @test O_N.getComment(ws, "B3").text == "Line one\nLine two\n\nLine four"
    @test O_N.getComment(ws, "B7").text == "<a & b> \"q\" 'x'  two  spaces\ttab"
    @test O_N.getComment(ws, "B8").text == "Größe ✓ 日本"
    @test O_N.getComment(ws, "Z100").text == "Far away"
    th = xf["Threads"]
    t = O_N.getThreadedComment(th, "B2")
    @test (t.author, t.text, t.date, t.resolved) == ("Ann", "Question?", NT_D, false)
    @test [(r.author, r.text, r.date) for r in t.replies] == [("Bob", "Answer.", NT_D + Hour(1)), ("Ann", "Thanks", NT_D + Hour(2))]
    @test O_N.getThreadedComment(th, "B3").resolved
    @test O_N.getThreadedComment(th, "B1").replies == []
    @test startswith(O_N.getComment(th, "B1").text, "[Threaded comment]")   # the note kept with the thread
    @test length(O_N.getThreadedComments(xf)) == 3
    @test length(O_N.getComments(xf)) == 13
end

@testset "notes: XLSX.jl's checks" begin
    xf = newods("Data"); ws = xf["Data"]
    @test _c4(addComment(ws, "B3", "Checked"; author = "Tim")) == (sheet = "Data", ref = "B3", author = "Tim", text = "Checked")
    @test addComment(ws, 5, 2, "Line one\nLine two"; visible = true).ref == "B5"
    @test addComment(ws, CellRef("C1"), "x").author == ""
    @test_throws ODSError addComment(ws, "A1:B2", "range")
    @test_throws ODSError addComment(ws, "notacell", "x")
    @test_throws ODSError addComment(ws, "A1", "x"; width = 0)
    addComment(ws, "B3", "Replaced"; author = "Ann")
    @test _c4(O_N.getComment(ws, "B3")) == (sheet = "Data", ref = "B3", author = "Ann", text = "Replaced")
    @test deleteComment(ws, "C1") && !deleteComment(ws, "C1") && !deleteComment(ws, 9, 9)
    @test _notes(ws) == [("B3", "Ann", "Replaced"), ("B5", "", "Line one\nLine two")]
    # a note on a value, in a sheet with no other formatting: written (the sheet gets its formats)
    v = newods("V"); v["V"]["A1"] = 1; addComment(v["V"], "A1", "on one")
    @test O_N.getComment(readods(writeods(joinpath(mktempdir(), "v.ods"), v))["V"], "A1").text == "on one"
    @test ws["B3"] === missing                                          # a note leaves the value alone
    ws["B3"] = 42
    @test O_N.getComment(ws, "B3").text == "Replaced" && ws["B3"] == 42   # and a value leaves the note
    @test_throws ODSError addComment(readods(NT_OWN)["Own"], "A1", "x")   # read-only
end

@testset "threads: XLSX.jl's checks" begin
    xf = newods("Data"); ws = xf["Data"]
    t = addThreadedComment(ws, "B3", "Is this final?"; author = "Tim", date = NT_D)
    @test t == (sheet = "Data", ref = "B3", author = "Tim", text = "Is this final?", date = NT_D, resolved = false, replies = [])
    @test_throws UndefKeywordError addThreadedComment(ws, "C3", "x")      # `author` is required
    @test_throws ODSError addThreadedComment(ws, "B3", "again"; author = "Tim")
    @test_throws ODSError addComment(ws, "B3", "a note")
    addComment(ws, "D3", "a note")
    @test_throws ODSError addThreadedComment(ws, "D3", "x"; author = "Tim")
    @test_throws ODSError addThreadedReply(ws, "E3", "x"; author = "Tim")
    t = addThreadedReply(ws, 3, 2, "Yes."; author = "Ann", date = NT_D + Minute(5))
    @test t.replies == [(author = "Ann", text = "Yes.", date = NT_D + Minute(5))]
    @test setThreadedCommentResolved(ws, "B3") === nothing && O_N.getThreadedComment(ws, "B3").resolved
    setThreadedCommentResolved(ws, "B3", false)
    @test !O_N.getThreadedComment(ws, "B3").resolved
    @test_throws ODSError setThreadedCommentResolved(ws, "D3")
    @test O_N.getComment(ws, "B3").text ==
          O_N._THREAD_NOTE_HEADER * "\nComment:\n    Is this final?\nReply:\n    Yes."     # Excel's note for it
    @test O_N.getComment(ws, "B3").author == "Tim"
    @test !deleteThreadedComment(ws, "D3") && O_N.getComment(ws, "D3") !== nothing   # a note isn't a thread
    @test deleteThreadedComment(ws, "B3") && O_N.getThreadedComment(ws, "B3") === nothing && O_N.getComment(ws, "B3") === nothing
    addThreadedComment(ws, "A1", "one"; author = "Tim", date = NT_D)
    addThreadedComment(ws, "A2", "two"; author = "Tim", date = NT_D)
    @test length(xf.persons.added) == 2                                  # Tim and Ann, once each
    # saved and read back, flat and zipped
    dir = mktempdir()
    for ext in ("ods", "fods")
        r = readods(writeods(joinpath(dir, "t.$ext"), xf))
        @test _threads(r) == _threads(xf) && _notes(r) == _notes(xf)
    end
    t = read(joinpath(dir, "t.fods"), String)
    @test count("<loext:person ", t) == 2 && occursin("xmlns:loext=", t) && occursin("xmlns:svg=", t)
end

function _edit_notes_files()
    a = openods(NT_OWN; mode = "rw")
    ws = a["Own"]
    addComment(ws, "C5", "New on an empty cell"; author = "Tim")
    addComment(ws, "B11", "Replaced")                                    # LibreOffice's note
    deleteComment(ws, "B12")
    addComment(ws, "B14", "On seven, replaced")                          # on a number
    addThreadedComment(ws, "C2", "A thread"; author = "Tim", date = NT_D)
    b = openods(NT_IMPORT; mode = "rw")
    th = b["Threads"]
    addThreadedReply(th, "B2", "Another"; author = "Bob", date = NT_D + Hour(3))   # Bob is one of the file's people
    setThreadedCommentResolved(th, "B1")
    addThreadedComment(th, "D5", "New"; author = "Cy", date = NT_D)
    deleteThreadedComment(th, "B3")
    return a, b
end

@testset "a patched save: notes and threads in LibreOffice's files" begin
    a, b = _edit_notes_files()
    dir = mktempdir()
    ra = readods(writeods(joinpath(dir, "own.fods"), a))
    @test _notes(ra) == _notes(a)
    @test O_N.getComment(ra["Own"], "B12") === nothing
    @test O_N.getComment(ra["Own"], "B13").text == "Line one\nLine two"              # untouched
    @test ra["Own"]["B14"] == 7 && O_N.getComment(ra["Own"], "B14").text == "On seven, replaced"
    @test O_N.getThreadedComment(ra["Own"], "C2").text == "A thread"
    t = read(joinpath(dir, "own.fods"), String)
    @test count("<loext:persons>", t) == 1
    @test occursin("<text:a xlink:href=\"https://example.org/whole\"", t)          # links untouched (D-023)
    rb = readods(writeods(joinpath(dir, "import.fods"), b))
    @test _threads(rb) == _threads(b) && _notes(rb) == _notes(b)
    tb = O_N.getThreadedComment(rb["Threads"], "B2")
    @test [r.author for r in tb.replies] == ["Bob", "Ann", "Bob"]
    @test O_N.getThreadedComment(rb["Threads"], "B1").resolved
    @test O_N.getThreadedComment(rb["Threads"], "B3") === nothing
    s = read(joinpath(dir, "import.fods"), String)
    @test count("<loext:persons>", s) == 1 && count("loext:display-name=\"Bob\"", s) == 1   # Bob reused
    @test count("loext:display-name=\"Cy\"", s) == 1
    @test length(O_N.getComments(rb["Notes"])) == 10                                 # another sheet, untouched
end

@testset "notes follow inserted and deleted lines; copies" begin
    xf = openods(NT_OWN; mode = "rw")
    ws = xf["Own"]
    addComment(ws, "C5", "Mine")
    insertRows(ws, 1; count = 2)
    deleteColumns(ws, "A")
    @test O_N.getComment(ws, "A13").text == "A note"                    # B11
    @test O_N.getComment(ws, "B7").text == "Mine"                       # C5
    deleteRows(ws, 13)
    @test O_N.getComment(ws, "A13").text == "Visible"                   # B12, now up one
    r = readods(writeods(joinpath(mktempdir(), "shifted.fods"), xf))["Own"]
    @test _notes(r) == _notes(ws)
    n = newods("S"); s = n["S"]
    addComment(s, "A1", "copied"); addThreadedComment(s, "B1", "thread"; author = "Tim", date = NT_D)
    copysheet!(s, "S2")
    @test _notes(n["S2"]) == [("A1", "", "copied"), ("B1", "Tim", O_N.getComment(s, "B1").text)]
    insertColumns(s, "A")
    @test O_N.getComment(s, "B1").text == "copied" && O_N.getComment(n["S2"], "A1").text == "copied"
end

@testset "LibreOffice reads the notes and threads" begin
    if isempty(SOFFICE) || !isfile(SOFFICE)
        @info "LibreOffice not found; skipping the notes oracle (set ODS_SOFFICE)"
        @test_skip false
    else
        dir = mktempdir()
        profile = lo_profile_url(joinpath(dir, "lo-profile"))
        xf = newods("Data"); ws = xf["Data"]
        ws["B2"] = 3.5
        addComment(ws, "B2", "On a number"; author = "Ann")
        addComment(ws, "D4", "Line one\nLine two"; visible = true)
        addThreadedComment(ws, "C1", "Question?"; author = "Ann", date = NT_D)
        addThreadedReply(ws, "C1", "Answer."; author = "Bob", date = NT_D + Hour(1))
        setThreadedCommentResolved(ws, "C1")
        files = [writeods(joinpath(dir, "new.ods"), xf)]
        a, b = _edit_notes_files()
        push!(files, writeods(joinpath(dir, "own.fods"), a), writeods(joinpath(dir, "import.fods"), b))
        run(pipeline(`$SOFFICE -env:UserInstallation=$profile --headless --norestore --convert-to fods --outdir $(joinpath(dir, "lo")) $files`;
                     stdout = devnull, stderr = devnull))
        threads = lo_major(SOFFICE) >= LO_FIXTURE_MAJOR     # an older LibreOffice drops the threads (CI's distribution one)
        threads || @info "LibreOffice $(lo_major(SOFFICE)) is older than the fixtures' $LO_FIXTURE_MAJOR: its reading of threads is not checked"
        for (f, x) in (("new", xf), ("own", a), ("import", b))
            lo = readods(joinpath(dir, "lo", f * ".fods"))
            if threads
                @test _threads(lo) == _threads(x)
            else
                @test_skip _threads(lo) == _threads(x)
            end
            # LibreOffice gives a note with no author "Unknown Author"? It keeps an empty one empty.
            @test [(n[1], n[3]) for n in _notes(lo)] == [(n[1], n[3]) for n in _notes(x)]
        end
        lo = readods(joinpath(dir, "lo", "new.fods"))["Data"]
        @test O_N.getComment(lo, "B2").author == "Ann" && lo["B2"] == 3.5
    end
end

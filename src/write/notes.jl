# Annotations (notes) and threaded comments (phase 6 step 4, D-073): XLSX.jl's `addComment`,
# `deleteComment`, `getComment`, `getComments`, and its threaded comments (`addThreadedComment`,
# `addThreadedReply`, `setThreadedCommentResolved`, `deleteThreadedComment`, `getThreadedComment`,
# `getThreadedComments`), on LibreOffice's `office:annotation` (F-059):
#   - a note is the cell's first child: `dc:creator`, `dc:date`, a `text:p` per line, `office:display`
#     when shown, and `svg:width`/`svg:height` (LibreOffice sizes a note's width from its text and
#     takes the height as a minimum, experiment 030 part E)
#   - a thread is a `loext:threaded-comment` (with `loext:reply`s) inside the note, before the
#     paragraphs, which hold the note Excel keeps for it: LibreOffice drops a thread without them
#     (part E). Its people are the workbook's `loext:persons`, after the tables.
# Notes set or removed live in `Worksheet.notes` until saved; the file's are read on first use
# (`Worksheet.filenotes`, D-069). The API follows XLSX.jl 0.13.4 (src/comments.jl,
# src/threadedcomments.jl), MIT License, Copyright (c) 2018-2026 Felipe Noronha Tavares and other
# contributors: names, keywords, checks and return shapes, and the text of a thread's note.

const CommentInfo = NamedTuple{(:sheet, :ref, :author, :text),Tuple{String,String,String,String}}
const ThreadedReply = NamedTuple{(:author, :text, :date),Tuple{String,String,Union{Nothing,Dates.DateTime}}}
const ThreadedCommentInfo = NamedTuple{(:sheet, :ref, :author, :text, :date, :resolved, :replies),
    Tuple{String,String,String,String,Union{Nothing,Dates.DateTime},Bool,Vector{ThreadedReply}}}

# The text Excel puts in a thread's note (XLSX.jl's `_THREAD_NOTE_HEADER`), which LibreOffice's
# import keeps (F-059).
const _THREAD_NOTE_HEADER = "[Threaded comment]\n\nYour version of Excel allows you to read this threaded comment; " *
    "however, any edits to it will get removed if the file is opened in a newer version of Excel. " *
    "Learn more: https://go.microsoft.com/fwlink/?linkid=870924\n"

function _thread_note_text(entries::Vector{ThreadEntry})
    io = IOBuffer()
    print(io, _THREAD_NOTE_HEADER)
    for (k, e) in enumerate(entries)
        print(io, k == 1 ? "\nComment:\n    " : "\nReply:\n    ", e.text)
    end
    return String(take!(io))
end

# A GUID-shaped id (`{XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}`), from a SHA-1 of `seed`: no new dependency.
function _guid(seed::AbstractString)
    h = uppercase(bytes2hex(sha1(seed)))
    return "{$(h[1:8])-$(h[9:12])-$(h[13:16])-$(h[17:20])-$(h[21:32])}"
end

# Excel's and LibreOffice's form of a thread's dates: to the hundredth of a second, no time zone.
_thread_date(d::Dates.DateTime) = Dates.format(d, "yyyy-mm-ddTHH:MM:SS") * "." * lpad(Dates.millisecond(d) ÷ 10, 2, '0')
function _parse_thread_date(s::AbstractString)
    length(s) >= 19 || return nothing
    d = tryparse(Dates.DateTime, s[1:19], Dates.dateformat"yyyy-mm-ddTHH:MM:SS")
    d === nothing && return nothing
    m = match(r"^\.(\d{1,3})", s[20:end])
    m === nothing && return d
    return d + Dates.Millisecond(parse(Int, rpad(m.captures[1], 3, '0')))
end

_note_date_now() = Dates.format(Dates.now(Dates.UTC), "yyyy-mm-ddTHH:MM:SS")

# A length of `px` pixels (at 96 per inch) in cm, as an ODF length.
_px_cm(px::Integer) = _fmt_num(round(px * 2.54 / 96; digits = 3)) * "cm"

#
# The XML of a note
#

function _note_xml(n::NoteData)
    io = IOBuffer()
    print(io, "<office:annotation")
    n.visible && print(io, " office:display=\"true\"")
    n.width === nothing || print(io, " svg:width=\"", n.width, "\"")
    n.height === nothing || print(io, " svg:height=\"", n.height, "\"")
    print(io, '>')
    isempty(n.author) || (print(io, "<dc:creator>"); _escape_text(io, n.author); print(io, "</dc:creator>"))
    n.date === nothing || (print(io, "<dc:date>"); _escape_text(io, n.date); print(io, "</dc:date>"))
    t = n.thread
    if t !== nothing && !isempty(t)
        for (k, e) in enumerate(t)
            print(io, k == 1 ? "<loext:threaded-comment" : "<loext:reply", " loext:id=\"", e.id, '"')
            e.date === nothing || print(io, " loext:date-time=\"", _thread_date(e.date), '"')
            k == 1 && n.resolved && print(io, " loext:resolved=\"true\"")
            isempty(e.person) || print(io, " loext:person-id=\"", e.person, '"')
            print(io, "><loext:text>"); _escape_text(io, e.text); print(io, "</loext:text>")
            k == 1 || print(io, "</loext:reply>")
        end
        print(io, "</loext:threaded-comment>")
    end
    _write_paragraphs(io, n.text)
    print(io, "</office:annotation>")
    return String(take!(io))
end

#
# Cell edits, by cell (what the writers need): a note set or removed (D-073), frames added, removed or
# moved (D-074)
#

const _NO_CELL_EDITS = Pair{Int,CellEdit}[]

# The cell edits of row r in columns x:y, sorted by column.
function _cell_edits_in(ws::Union{Nothing,Worksheet}, r::Int, x::Int, y::Int)
    ws === nothing && return _NO_CELL_EDITS
    notes = ws.notes; frames = ws.frames
    nn = notes === nothing ? 0 : length(notes)
    nf = frames === nothing ? 0 : length(frames)
    nn + nf == 0 && return _NO_CELL_EDITS
    cols = Int[]
    if y - x + 1 <= nn + nf
        for c in x:y
            ((nn > 0 && haskey(notes, (r, c))) || (nf > 0 && haskey(frames, (r, c)))) && push!(cols, c)
        end
    else
        nn > 0 && for (rr, c) in keys(notes); rr == r && x <= c <= y && push!(cols, c); end
        nf > 0 && for (rr, c) in keys(frames); rr == r && x <= c <= y && push!(cols, c); end
        sort!(unique!(cols))
    end
    isempty(cols) && return _NO_CELL_EDITS
    return [c => CellEdit(nn > 0 && haskey(notes, (r, c)) ? notes[(r, c)] : missing,
                          nf > 0 ? get(frames, (r, c), nothing) : nothing) for c in cols]
end

# Rows with new notes or frames as their own segments (`write_model_rows`).
function _edit_bounds!(bps::Vector{Int}, ws::Worksheet, a::Int, b::Int)
    if ws.notes !== nothing
        for ((r, _), nd) in ws.notes
            nd !== nothing && a <= r <= b && push!(bps, r, r + 1)
        end
    end
    if ws.frames !== nothing
        for (r, _) in keys(ws.frames)
            a <= r <= b && push!(bps, r, r + 1)
        end
    end
    return
end

# A cell written by `write_cell` (`frag`), with `lead` as its first children and `tail` as its last.
function _with_children(frag::String, lead::AbstractString, tail::AbstractString)
    e = _start_tag_end(frag)
    covered = startswith(frag, "<table:covered-table-cell")
    endtag = covered ? "</table:covered-table-cell>" : "</table:table-cell>"
    if codeunit(frag, prevind(frag, e)) == UInt8('/')
        return string(SubString(frag, 1, prevind(frag, prevind(frag, e))), '>', lead, tail, endtag)
    end
    inner = SubString(frag, nextind(frag, e), ncodeunits(frag) - ncodeunits(endtag))
    return string(SubString(frag, 1, e), lead, inner, tail, endtag)
end

# The XML an edit adds to a new cell: its note, and its frames.
_edit_lead(e::CellEdit) = e.note isa NoteData ? _note_xml(e.note) : ""
_edit_tail(ws::Worksheet, e::CellEdit) = e.frames === nothing ? "" : _frames_xml(ws, e.frames)

# `write_merged_cells` for columns x:y, with the cells of `nc` (column => edit) written alone, each
# with its note and frames (a new file's rows; rows added after a file's last).
function _write_noted_cells(io::IO, styles::StyleIndex, vals, emps, x::Int, y::Int, rowdefault::Bool, coldefault, nc, ws::Worksheet;
                            display::Bool = true)
    gap(o) = n -> write_cell(o, nothing, styles; repeat = n)
    pos = x
    for (c, e) in nc
        c > pos && write_merged_cells(io, styles, vals, emps, pos, c - 1, rowdefault, coldefault, gap(io); display)
        buf = IOBuffer()
        write_merged_cells(buf, styles, vals, emps, c, c, rowdefault, coldefault, gap(buf); display)
        frag = String(take!(buf))
        lead = _edit_lead(e); tail = _edit_tail(ws, e)
        print(io, isempty(lead) && isempty(tail) ? frag : _with_children(frag, lead, tail))
        pos = c + 1
    end
    pos <= y && write_merged_cells(io, styles, vals, emps, pos, y, rowdefault, coldefault, gap(io); display)
    return
end

# Whether a workbook's new XML has notes, or threads (for the namespaces it declares).
_has_notes(xf::ODSFile) = any(ws -> ws.notes !== nothing && any(!isnothing, values(ws.notes)), _sheets(xf))
_has_threads(xf::ODSFile) = !isempty(xf.persons.added) ||
    any(ws -> ws.notes !== nothing && any(nd -> nd !== nothing && nd.thread !== nothing, values(ws.notes)), _sheets(xf))

# The note edits moved with inserted or deleted lines (`shift_lines!`); those of deleted cells go.
function _shift_notes!(ws::Worksheet, axis::Int, at::Int, n::Int)
    ws.notes === nothing && return
    max = axis == 1 ? SheetCore.MAX_ROWS : SheetCore.MAX_COLS
    new = Dict{Tuple{Int,Int},Union{Nothing,NoteData}}()
    for ((r, c), nd) in ws.notes
        x = _line_after(axis == 1 ? r : c, at, n)
        0 < x <= max || continue
        new[axis == 1 ? (x, c) : (r, x)] = nd
    end
    ws.notes = new
    return
end

#
# The people of threads
#

const _PERSON_RX = r"<loext:person\b[^>]*?/>"
_attr_in(tag::AbstractString, name::AbstractString) =
    (m = match(Regex("\\b" * name * "=\"([^\"]*)\""), tag); m === nothing ? nothing : XML.unescape(m.captures[1]))

# The file's people, by id (read once).
function _file_persons(xf::ODSFile)
    p = xf.persons
    p.file === nothing || return p.file
    d = Dict{String,String}()
    if !isnewfile(xf)
        i = findfirst("<loext:persons", xf.content)
        if i !== nothing
            j = something(findnext("</loext:persons>", xf.content, last(i)), last(i):last(i))
            for m in eachmatch(_PERSON_RX, SubString(xf.content, first(i), last(j)))
                id = _attr_in(m.match, "loext:person-id")
                id === nothing || (d[id] = something(_attr_in(m.match, "loext:display-name"), ""))
            end
        end
    end
    p.file = d
    return d
end

function _person_name(xf::ODSFile, id::AbstractString)
    n = get(_file_persons(xf), id, nothing)
    n === nothing || return n
    for (pid, name) in xf.persons.added
        pid == id && return name
    end
    return ""
end

# The id of the person named `name`: the file's or an added one, else a new one.
function _person_id!(xf::ODSFile, name::AbstractString)
    for (id, n) in _file_persons(xf)
        n == name && return id
    end
    for (id, n) in xf.persons.added
        n == name && return id
    end
    id = _guid("person:" * name)
    push!(xf.persons.added, id => String(name))
    return id
end

_persons_xml(added::Vector{Pair{String,String}}) =
    join("<loext:person loext:person-id=\"$id\" loext:display-name=\"$(sprint(_escape_attr, n))\" loext:user-id=\"$(sprint(_escape_attr, n))\" loext:provider-id=\"None\"/>"
         for (id, n) in added)

#
# The notes the file holds (read on first use)
#

function _text_of!(buf::IOBuffer, c)
    XML.for_each_child!(c) do ch
        nt = XML.nodetype(ch)
        (nt === XML.Text || nt === XML.CData) && (v = XML.value(ch); v === nothing || write(buf, v))
        nt === XML.Element && _text_of!(buf, ch)
    end
    return
end
_text_of(c) = (b = IOBuffer(); _text_of!(b, c); String(take!(b)))

function _thread_entry(ch, xf::ODSFile)
    id = ""; person = ""; date = nothing; resolved = false
    for (k, v) in XML.eachattribute!(ch)
        k == "loext:id" && (id = String(v))
        k == "loext:person-id" && (person = String(v))
        k == "loext:date-time" && (date = _parse_thread_date(v))
        k == "loext:resolved" && (resolved = v == "true")
    end
    text = ""
    replies = ThreadEntry[]
    XML.for_each_child!(ch) do g
        XML.nodetype(g) === XML.Element || return
        t = XML.tag(g)
        if t == "loext:text"
            text = _text_of(g)
        elseif t == "loext:reply"
            e, _, _ = _thread_entry(g, xf)
            push!(replies, e)
        else
            XML.skip_element!(g)
        end
    end
    return ThreadEntry(id, person, _person_name(xf, person), date, text), replies, resolved
end

# The note of an original cell's annotation (`c` at the element).
function _parse_note(c, xf::ODSFile)
    visible = false; width = nothing; height = nothing
    for (k, v) in XML.eachattribute!(c)
        k == "office:display" && (visible = v == "true")
        k == "svg:width" && (width = String(v))
        k == "svg:height" && (height = String(v))
    end
    author = ""; date = nothing; thread = nothing; resolved = false
    buf = IOBuffer(); n = 0
    XML.for_each_child!(c) do ch
        XML.nodetype(ch) === XML.Element || return
        t = XML.tag(ch)
        if t == "dc:creator"
            author = _text_of(ch)
        elseif t == "dc:date"
            date = _text_of(ch)
        elseif t == "loext:threaded-comment"
            e1, replies, resolved = _thread_entry(ch, xf)
            thread = [e1; replies]
        elseif t == "text:p" || t == "text:h"
            n > 0 && write(buf, '\n'); n += 1
            _para_text!(buf, ch)
        else
            XML.skip_element!(ch)
        end
    end
    text = replace(String(take!(buf)), "\r\n" => "\n", '\r' => '\n')
    return NoteData(author, text, date, visible, width, height, thread, resolved)
end

function _file_notes(ws::Worksheet)
    ws.filenotes === nothing || return ws.filenotes
    out = FileNote[]
    if ws.entry !== nothing
        xf = get_odsfile(ws)
        node = ws.entry.node
        src = parent(XML.sourcetext(node))
        row = Ref(0)
        walk(n::XML.LazyNode) = begin
            c = XML.Cursor(n)
            XML.next!(c)
            XML.for_each_child!(c) do ch
                XML.nodetype(ch) === XML.Element || return
                t = XML.tag(ch)
                if t == "table:table-row"
                    nrows = min(_repeat_attr(ch, "table:number-rows-repeated"), SheetCore.MAX_ROWS - row[])
                    r0 = row[] + 1
                    row[] += nrows
                    rc = XML.Cursor(XML.LazyNode(ch))
                    XML.next!(rc)
                    col = 0
                    XML.for_each_child!(rc) do cc
                        XML.nodetype(cc) === XML.Element || return
                        if XML.tag(cc) in ("table:table-cell", "table:covered-table-cell")
                            k = _repeat_attr(cc, "table:number-columns-repeated")
                            cl = XML.LazyNode(cc)
                            sp = XML.sourcespan(cl)
                            if occursin("office:annotation", SubString(src, first(sp), last(sp)))
                                ac = XML.Cursor(cl)
                                XML.next!(ac)
                                XML.for_each_child!(ac) do g
                                    XML.nodetype(g) === XML.Element || return
                                    if XML.tag(g) == "office:annotation"
                                        nd = _parse_note(g, xf)
                                        for r in r0:r0+nrows-1, cc2 in col+1:col+k   # (LibreOffice never repeats one)
                                            push!(out, FileNote(r, cc2, nd))
                                        end
                                    else
                                        XML.skip_element!(g)
                                    end
                                end
                            end
                            col += k
                        end
                        XML.skip_element!(cc)
                    end
                elseif t in _ROW_CONTAINERS
                    walk(XML.LazyNode(ch))
                end
                XML.skip_element!(ch)
            end
        end
        walk(node)
    end
    ws.filenotes = out
    return out
end

# The note of current cell (r, c): set or removed since, else the file's (moved with its cell).
function _note_at(ws::Worksheet, r::Int, c::Int)
    notes = ws.notes
    notes !== nothing && haskey(notes, (r, c)) && return notes[(r, c)]
    ws.entry === nothing && return nothing
    o = _original_line(ws.rowmap, r); p = _original_line(ws.colmap, c)
    (o == 0 || p == 0) && return nothing
    for fn in _file_notes(ws)
        fn.row == o && fn.col == p && return fn.note
    end
    return nothing
end

# Every cell with a note, sorted by row and column, with its note.
function _all_notes(ws::Worksheet)
    cells = Dict{Tuple{Int,Int},NoteData}()
    for fn in _file_notes(ws)
        r = _current_line(ws.rowmap, fn.row); c = _current_line(ws.colmap, fn.col)
        (r == 0 || c == 0) || (cells[(r, c)] = fn.note)
    end
    if ws.notes !== nothing
        for (k, nd) in ws.notes
            nd === nothing ? delete!(cells, k) : (cells[k] = nd)
        end
    end
    return sort!(collect(cells); by = first)
end

_cellname(r::Int, c::Int) = string(SheetCore.encode_column_number(c), r)
_comment_info(ws::Worksheet, r::Int, c::Int, nd::NoteData) = CommentInfo((ws.name, _cellname(r, c), nd.author, nd.text))
function _thread_info(ws::Worksheet, r::Int, c::Int, nd::NoteData)
    t = nd.thread
    e1 = t[1]
    replies = ThreadedReply[ThreadedReply((e.author, e.text, e.date)) for e in t[2:end]]
    return ThreadedCommentInfo((ws.name, _cellname(r, c), e1.author, e1.text, e1.date, nd.resolved, replies))
end

#
# Setting notes
#

# One cell of a reference (a range is an error, as in XLSX.jl).
function _note_cell(ref, what::AbstractString)
    rows, cols = _link_block(ref)
    (length(rows) == 1 && length(cols) == 1) ||
        throw(ODSError("$what goes on a single cell, not a range: `$ref`."))
    return first(rows), first(cols)
end

# Sets cell (r, c)'s note (or removes it: nothing). The cell is made to exist in the model (a
# formatted empty cell, D-038) so that every writer writes it, and marked edited.
function _set_note!(ws::Worksheet, r::Int, c::Int, nd::Union{Nothing,NoteData})
    notes = ws.notes === nothing ? (ws.notes = Dict{Tuple{Int,Int},Union{Nothing,NoteData}}()) : ws.notes
    notes[(r, c)] = nd
    f = sheet_formats(ws)        # a sheet with notes is written with its formats (`write_model_rows` places them)
    if nd !== nothing && cell_data(_cached_store(ws), r, c) === nothing
        if _fmt_cell(f, r, c) === nothing
            _rows_set!(f.cells, r, c, CellData(CK_EMPTY, 0x00, Int32(effective_style(ws, r, c)), UInt64(0), nothing, nothing, Int32(1), Int32(1)))
        end
    end
    ws.entry === nothing && nd === nothing && delete!(notes, (r, c))    # a new sheet has no original to remove
    _mark_dirty!(ws, r, c)
    return
end

"""
    addComment(sheet, ref, text; author="", width=144, height=79, visible=false) -> NamedTuple
    addComment(sheet, row, col, text; kw...) -> NamedTuple

Attach a note (LibreOffice's comment, an annotation) to one cell, replacing any it has (F-059,
D-073). `text` may hold line breaks (`\\n`). `author` is shown with the note; `width` and
`height` are its size in pixels (LibreOffice sizes a note's width from its text, and takes the
height as a minimum); `visible=true` shows it always, not only when the mouse is over the cell.
A cell with a threaded comment is refused.

Returns `(sheet, ref, author, text)`. The file must be writable.
"""
function addComment(ws::Worksheet, ref::Union{AbstractString,CellRef}, text::AbstractString;
                    author::AbstractString = "", width::Integer = 144, height::Integer = 79, visible::Bool = false)
    _require_writable(ws, "add a comment")
    r, c = _note_cell(ref, "A comment")
    (width > 0 && height > 0) || throw(ODSError("A comment's `width` and `height` must be positive."))
    old = _note_at(ws, r, c)
    old !== nothing && old.thread !== nothing &&
        throw(ODSError("Cell $(_cellname(r, c)) has a threaded comment. A cell can't have both: delete it first with `deleteThreadedComment`."))
    nd = NoteData(String(author), String(text), _note_date_now(), visible, _px_cm(width), _px_cm(height), nothing, false)
    _set_note!(ws, r, c, nd)
    return _comment_info(ws, r, c, nd)
end
addComment(ws::Worksheet, row::Integer, col::Integer, text::AbstractString; kw...) = addComment(ws, CellRef(row, col), text; kw...)

"""
    getComment(sheet, ref) -> Union{Nothing, NamedTuple}
    getComment(sheet, row, col) -> Union{Nothing, NamedTuple}

The note of a cell, as `(sheet, ref, author, text)`, or `nothing`. For a cell with a threaded
comment, the note kept with it (Excel's text for versions without threads); read the thread with
[`getThreadedComment`](@ref).
"""
function getComment(ws::Worksheet, ref::Union{AbstractString,CellRef})
    r, c = _note_cell(ref, "`getComment`")
    nd = _note_at(ws, r, c)
    return nd === nothing ? nothing : _comment_info(ws, r, c, nd)
end
getComment(ws::Worksheet, row::Integer, col::Integer) = getComment(ws, CellRef(row, col))

"""
    getComments(sheet) -> Vector{NamedTuple}
    getComments(xf::ODSFile) -> Vector{NamedTuple}

Every note of a sheet, or of every sheet, as [`getComment`](@ref) gives them, by row and then
column.
"""
getComments(ws::Worksheet) = CommentInfo[_comment_info(ws, r, c, nd) for ((r, c), nd) in _all_notes(ws)]
getComments(xf::ODSFile) = reduce(vcat, (getComments(ws) for ws in _sheets(xf)); init = CommentInfo[])

"""
    deleteComment(sheet, ref) -> Bool
    deleteComment(sheet, row, col) -> Bool

Remove a cell's note (with its thread, if it has one: in LibreOffice they are one object).
Returns whether there was one. The file must be writable.
"""
function deleteComment(ws::Worksheet, ref::Union{AbstractString,CellRef})
    _require_writable(ws, "delete a comment")
    r, c = _note_cell(ref, "A comment")
    _note_at(ws, r, c) === nothing && return false
    _set_note!(ws, r, c, nothing)
    return true
end
deleteComment(ws::Worksheet, row::Integer, col::Integer) = deleteComment(ws, CellRef(row, col))

#
# Threaded comments
#

function _thread_note!(ws::Worksheet, r::Int, c::Int, nd::NoteData)
    nd.text = _thread_note_text(nd.thread)
    _set_note!(ws, r, c, nd)
    return _thread_info(ws, r, c, nd)
end

# A copy of a note, to change (a note read from the file is never changed in place).
_copy_note(n::NoteData) = NoteData(n.author, n.text, n.date, n.visible, n.width, n.height,
                                   n.thread === nothing ? nothing : copy(n.thread), n.resolved)

"""
    addThreadedComment(sheet, ref, text; author, date=now(UTC)) -> NamedTuple
    addThreadedComment(sheet, row, col, text; kw...) -> NamedTuple

Start a threaded comment on one cell, as LibreOffice keeps Excel's (F-059, D-073): a
`loext:threaded-comment` inside the cell's note, whose text is the one Excel shows in versions
without threads. `author` is the name shown (one of the workbook's people, shared by every
comment with that name); `date` is when it was written, in UTC. A cell with a note or a thread
is refused: add to a thread with [`addThreadedReply`](@ref).

Returns the thread, as [`getThreadedComment`](@ref) reads it. The file must be writable.
"""
function addThreadedComment(ws::Worksheet, ref::Union{AbstractString,CellRef}, text::AbstractString;
                            author::AbstractString, date::Dates.DateTime = Dates.now(Dates.UTC))
    _require_writable(ws, "add a threaded comment")
    r, c = _note_cell(ref, "A threaded comment")
    old = _note_at(ws, r, c)
    old === nothing || throw(ODSError(old.thread !== nothing ?
        "Cell $(_cellname(r, c)) already has a threaded comment. Add to it with `addThreadedReply`." :
        "Cell $(_cellname(r, c)) has a note. A cell can't have both: delete it first with `deleteComment`."))
    xf = get_odsfile(ws)
    e = ThreadEntry(_guid("thread:$(ws.name)!$(_cellname(r, c)):1:$(text):$(date)"), _person_id!(xf, author), String(author), date, String(text))
    nd = NoteData(String(author), "", _thread_date(date)[1:19], false, nothing, nothing, [e], false)
    return _thread_note!(ws, r, c, nd)
end
addThreadedComment(ws::Worksheet, row::Integer, col::Integer, text::AbstractString; kw...) =
    addThreadedComment(ws, CellRef(row, col), text; kw...)

function _thread_at(ws::Worksheet, ref, what::AbstractString)
    r, c = _note_cell(ref, what)
    nd = _note_at(ws, r, c)
    (nd === nothing || nd.thread === nothing) &&
        throw(ODSError("Cell $(_cellname(r, c)) has no threaded comment. Start one with `addThreadedComment`."))
    return r, c, _copy_note(nd)
end

"""
    addThreadedReply(sheet, ref, text; author, date=now(UTC)) -> NamedTuple
    addThreadedReply(sheet, row, col, text; kw...) -> NamedTuple

Add a reply to the end of a cell's threaded comment. Returns the thread. The file must be
writable.
"""
function addThreadedReply(ws::Worksheet, ref::Union{AbstractString,CellRef}, text::AbstractString;
                          author::AbstractString, date::Dates.DateTime = Dates.now(Dates.UTC))
    _require_writable(ws, "add a reply")
    r, c, nd = _thread_at(ws, ref, "A reply")
    k = length(nd.thread) + 1
    push!(nd.thread, ThreadEntry(_guid("thread:$(ws.name)!$(_cellname(r, c)):$k:$(text):$(date)"),
                                 _person_id!(get_odsfile(ws), author), String(author), date, String(text)))
    return _thread_note!(ws, r, c, nd)
end
addThreadedReply(ws::Worksheet, row::Integer, col::Integer, text::AbstractString; kw...) =
    addThreadedReply(ws, CellRef(row, col), text; kw...)

"""
    setThreadedCommentResolved(sheet, ref, resolved=true)
    setThreadedCommentResolved(sheet, row, col, resolved=true)

Mark a cell's threaded comment resolved, or (`false`) open again. The file must be writable.
"""
function setThreadedCommentResolved(ws::Worksheet, ref::Union{AbstractString,CellRef}, resolved::Bool = true)
    _require_writable(ws, "resolve a threaded comment")
    r, c, nd = _thread_at(ws, ref, "A threaded comment")
    nd.resolved = resolved
    _set_note!(ws, r, c, nd)
    return nothing
end
setThreadedCommentResolved(ws::Worksheet, row::Integer, col::Integer, resolved::Bool = true) =
    setThreadedCommentResolved(ws, CellRef(row, col), resolved)

"""
    deleteThreadedComment(sheet, ref) -> Bool
    deleteThreadedComment(sheet, row, col) -> Bool

Remove a cell's threaded comment, with its replies and its note. Returns whether there was one.
The file must be writable.
"""
function deleteThreadedComment(ws::Worksheet, ref::Union{AbstractString,CellRef})
    _require_writable(ws, "delete a threaded comment")
    r, c = _note_cell(ref, "A threaded comment")
    nd = _note_at(ws, r, c)
    (nd === nothing || nd.thread === nothing) && return false
    _set_note!(ws, r, c, nothing)
    return true
end
deleteThreadedComment(ws::Worksheet, row::Integer, col::Integer) = deleteThreadedComment(ws, CellRef(row, col))

"""
    getThreadedComment(sheet, ref) -> Union{Nothing, NamedTuple}
    getThreadedComment(sheet, row, col) -> Union{Nothing, NamedTuple}

A cell's threaded comment, as `(sheet, ref, author, text, date, resolved, replies)`, each reply
`(author, text, date)`, or `nothing`. `author` is the person's display name.
"""
function getThreadedComment(ws::Worksheet, ref::Union{AbstractString,CellRef})
    r, c = _note_cell(ref, "`getThreadedComment`")
    nd = _note_at(ws, r, c)
    return nd === nothing || nd.thread === nothing ? nothing : _thread_info(ws, r, c, nd)
end
getThreadedComment(ws::Worksheet, row::Integer, col::Integer) = getThreadedComment(ws, CellRef(row, col))

"""
    getThreadedComments(sheet) -> Vector{NamedTuple}
    getThreadedComments(xf::ODSFile) -> Vector{NamedTuple}

Every threaded comment of a sheet, or of every sheet, as [`getThreadedComment`](@ref) gives
them, by row and then column.
"""
getThreadedComments(ws::Worksheet) =
    ThreadedCommentInfo[_thread_info(ws, r, c, nd) for ((r, c), nd) in _all_notes(ws) if nd.thread !== nothing]
getThreadedComments(xf::ODSFile) = reduce(vcat, (getThreadedComments(ws) for ws in _sheets(xf)); init = ThreadedCommentInfo[])

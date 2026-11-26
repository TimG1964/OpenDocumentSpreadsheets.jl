```@meta
CurrentModule = OpenDocumentSpreadsheets
```

# Notes and comments

A note is LibreOffice's Insert ▸ Comment: a box of text attached to a cell, marked by a small square
in the cell's corner.

```julia
using OpenDocumentSpreadsheets
using OpenDocumentSpreadsheets: getComment, getThreadedComment

xf = newods("Invoices")
sh = xf["Invoices"]
sh["A1:B1"] = ["Invoice" "Amount"]
sh["A2:B4"] = ["INV-101" 420; "INV-102" 1250; "INV-103" 87]
addComment(sh, "B3", "Checked against the invoice"; author = "Ann", visible = true)
getComment(sh, "B3").text           # "Checked against the invoice"
```

<!-- shot: notes cells=5x7 -->
![Three invoices with their amounts; the cell B3 has a note marker in its corner, and its note, Checked against the invoice, shown beside it](../images/notes.png)

```julia
deleteComment(sh, "B3")
```

`visible = true` shows a note always, as View ▸ Comments or Show Comment does, rather than only
when the mouse is over its cell. `date` sets the date LibreOffice shows on the note.

## Threaded comments

A threaded comment is a conversation on a cell: a comment and its replies, each with an author, that
can be marked resolved.

```julia
addThreadedComment(sh, "B4", "Is this final?"; author = "Ann")
addThreadedReply(sh, "B4", "Yes."; author = "Bob")
setThreadedCommentResolved(sh, "B4")
getThreadedComment(sh, "B4")
```

LibreOffice keeps a thread inside a note, which shows the thread's text in versions of LibreOffice
without threads.

All of these stay with their cells: a cell whose value changes keeps its note, and inserting or
deleting rows and columns, sorting and copying sheets move notes with their cells.

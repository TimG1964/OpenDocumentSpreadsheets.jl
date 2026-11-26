```@meta
CurrentModule = OpenDocumentSpreadsheets
```

# Creating and editing files

## A new file

[`newods`](@ref) makes a file with one sheet, named as you choose. [`addsheet!`](@ref) adds more:

```julia
using OpenDocumentSpreadsheets

xf = newods("Plan")
plan = xf["Plan"]
plan["A1"] = "Task"; plan["B1"] = "Days"
plan["A2:B4"] = ["Design" 5; "Build" 12; "Test" 4]
setFormula(plan, "B5"; val = "=SUM(B2:B4)")

memo = addsheet!(xf, "Notes")
memo["A1"] = "Estimates agreed on 18 November."
writeods("plan.ods", xf; overwrite = true)
```

<!-- shot: creating_new cells=4x6 -->
![A sheet named Plan with Task and Days in row 1, three tasks with their days below, and their total, 21, in B5](../images/creating_new.png)

A sheet is addressed by name or by position (`xf["Plan"]`, `xf[1]`), and [`sheetnames`](@ref)
lists them in order.

## Opening a file

| To | Use |
|---|---|
| read a file | `readods(path)`, or `openods(path)`, which is the same |
| read and edit a file | `openods(path; mode="rw")`; save with [`saveods`](@ref) or [`writeods`](@ref) |
| start a new, empty file | [`newods`](@ref), or `openods(path; mode="w")` |

With the do-block form of [`openods`](@ref), a file opened for writing is saved when the block ends
(but not if the block throws). This edits the `plan.ods` made above:

```julia
openods("plan.ods"; mode = "rw") do xf
    xf["Plan"]["B3"] = 14                    # Build takes longer
end
```

Without it, save explicitly:

```julia
xf = openods("plan.ods"; mode = "rw")
xf["Plan"]["B4"] = 5
saveods(xf)                                       # back to plan.ods
writeods("plan-copy.ods", xf; overwrite = true)   # or to another file
```

## Writing a table

[`writetable`](@ref) writes any Tables.jl source (a DataFrame, a named tuple of vectors, …) with its
column names as a header row. [`writetable!`](@ref) writes one into a sheet of an open file:

```julia
people = (Name = ["Ann", "Bob"], Team = ["North", "South"])
notes = (Note = ["Teams agreed on 18 November."],)

writetable("people.ods", people; sheetname = "People", overwrite = true)
writetable("all.ods", "People" => people, "Notes" => notes; overwrite = true)   # several sheets

xf = openods("plan.ods"; mode = "rw")
writetable!(addsheet!(xf, "People"), people; anchor_cell = "B2")
saveods(xf)
```

## Editing keeps the rest of the file

Editing a file changes only what you change:
- the sheets, settings, pictures, charts and everything else you don't touch stay exactly as they
  were;
- the styles already in the file are never changed: new formatting adds styles of its own;
- in a row you edit, the cells you didn't change keep their formatting, notes and links.

A file saved without edits is identical to the original. So a file made in LibreOffice, even with
features this package doesn't know about, can be edited safely.

This is because OpenDocumentSpreadsheets doesn't rebuild a file it edits. It copies the original and
rewrites only the rows that hold edited or formatted cells, and the columns whose formats changed.
Styles it added that no cell uses any more aren't written.

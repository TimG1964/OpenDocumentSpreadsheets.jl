```@meta
CurrentModule = OpenDocumentSpreadsheets
```

# Hiding and grouping rows and columns

## Hiding

```julia
using OpenDocumentSpreadsheets

xf = newods("Year")
s = xf["Year"]
months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
s["A1:B1"] = ["Month" "Sales"]
for (i, m) in enumerate(months)
    s[i+1, 1] = m; s[i+1, 2] = 100 + 10i
end
s["C1"] = "Note"

setRowHidden(s, 3:4)                     # hidden = true by default
setColumnHidden(s, "C")
setColumnHidden(s, "C"; hidden = false)  # shown again
OpenDocumentSpreadsheets.isRowHidden(s, 3)   # true
setRowHidden(s, 3:4; hidden = false)
```

## Grouping

LibreOffice's Data ▸ Group and Outline puts outline buttons beside grouped rows and columns, which
collapse and expand them:

```julia
groupRows(s, 2:13)                       # the year
groupRows(s, 2:4)                        # the first quarter, inside it
groupRows(s, 5:7; collapsed = true)      # the second, its rows hidden
OpenDocumentSpreadsheets.getRowOutlineLevel(s, 3)   # 2
```

<!-- shot: groups cells=3x14 -->
![The months of the year with outline brackets to the left of the row numbers: one round all twelve months and two inside it, the first open on January to March and the second collapsed with April to June hidden](../images/groups.png)

```julia
groupColumns(s, "B:C")
ungroupRows(s, 5:7)
```

Groups are LibreOffice's nested groups: two groups side by side stay two groups, a group may not
cross another, and there are at most seven levels. Ungrouping removes a whole group, and lifts the
groups inside it.

```@meta
CurrentModule = OpenDocumentSpreadsheets
```

# Conditional formats

[`setConditionalFormat`](@ref) makes the rules of LibreOffice's Format ▸ Conditional menu: conditions
that apply a cell style when they hold, and data bars, colour scales and icon sets.

## Conditions

```julia
using OpenDocumentSpreadsheets

xf = newods("Sales")
s = xf["Sales"]
for i in 1:10
    s[i, 1] = i * 3 - 7
    s[i, 2] = isodd(i) ? "north" : "south"
end
setConditionalFormat(s, "A1:A10", :cellIs; operator = "greaterThan", value = "10",
                     dxStyle = "greenfilltext")
setConditionalFormat(s, "A1:A10", :cellIs; operator = "lessThan", value = "0",
                     font = ["color" => "red", "bold" => "true"])
setConditionalFormat(s, "B1:B10", :containsText; value = "north", style = "Good")
```

<!-- shot: condfmt_conditions cells=3x11 -->
![Values from -4 to 23 in column A: those over 10 in green text on a green fill, those below 0 in bold red; in column B, each cell reading north in LibreOffice's Good style, on light green](../images/condfmt_conditions.png)

The conditions are:
- comparisons (`:cellIs`), top and bottom ranks (`:top10`), above and below average;
- text that contains, doesn't contain, begins or ends with a value;
- date periods (today, last week, this month, this year, …);
- blanks, errors, unique and duplicate values;
- formulas (`:expression`).

A condition's format is a cell style:
- `style` applies a style you already have, or one of LibreOffice's built-in styles
  (`style = "Good"`).
- `dxStyle` (a preset such as `"redfilltext"`) or a custom `font`, `fill`, `border` or `format` makes
  a style of the rule's own, `ConditionalStyle_1`, `ConditionalStyle_2` and so on, which the Styles
  deck lists.

Conditions set on the same range become one conditional format, in the order they were set, and
LibreOffice applies the first that holds. Cells keep their own styles underneath.

## Data bars, colour scales and icon sets

```julia
xf = newods("Scales")
c = xf["Scales"]
for i in 1:10
    c[i, 1] = i^2; c[i, 2] = i^2; c[i, 3] = i^2
end
setConditionalFormat(c, "A1:A10", :dataBar; databar = "green")
setConditionalFormat(c, "B1:B10", :colorScale; colorscale = "redwhitegreen")
setConditionalFormat(c, "C1:C10", :iconSet; iconset = "3Arrows")
setColumnWidth(c, "A:C"; width = 14)
```

<!-- shot: condfmt_scales cells=4x11 -->
![The squares 1 to 100 three times: in column A with green data bars growing with the value, in column B shaded from green at 1 through white to red at 100, and in column C with red down, yellow sideways and green up arrows](../images/condfmt_scales.png)

Each comes with presets: the data bar colours, two- and three-colour scales, and LibreOffice's icon
sets, including its `3Smilies` and `3ColorSmilies`. [`setColoredDataBars`](@ref
OpenDocumentSpreadsheets.setColoredDataBars) sets a data bar's colours for positive and negative
values, and `minLength` and `maxLength` its shortest and longest bar.

## Reading and clearing

```julia
OpenDocumentSpreadsheets.getConditionalFormats(s)            # range => (type = "cellIs", priority = 1), …
OpenDocumentSpreadsheets.clearConditionalFormats(s, "B:B")   # 1 rule removed
```

## LibreOffice's rules

- Whole columns and rows keep their full extent, and empty cells can have rules.
- Rules move with their cells: inserted and deleted rows and columns, sheet copies and renames rewrite
  them as LibreOffice does. A sort moves none.
- LibreOffice has no "stop if true", no standard-deviation forms of above average (use an
  `:expression`), no data bar borders or right-to-left bars, and doesn't read back custom or reversed
  icon sets: asking for them is an error.

```@meta
CurrentModule = OpenDocumentSpreadsheets
```

# Hyperlinks

```julia
using OpenDocumentSpreadsheets
using OpenDocumentSpreadsheets: getHyperlink, getHyperlinks

xf = newods("Links")
s = xf["Links"]
addsheet!(xf, "Data")["B10"] = 42
s["A1"] = "Links"
addHyperlink(s, "A2"; url = "https://example.org/", display = "Our site")
addHyperlink(s, "A3"; location = "Data.B10", display = "See the data")
s["A4"] = 1234
addHyperlink(s, "A4"; url = "https://example.org/figures")      # a link of the cell itself
addHyperlink(s, "B5:B7"; url = "https://example.org/list")       # one link per cell
getHyperlink(s, "A2")       # (sheet, ref, url, location, display, tooltip)
getHyperlinks(s)            # every link on the sheet
```

<!-- shot: hyperlinks cells=3x5 -->
![A sheet with two links shown as underlined text, Our site and See the data, the number 1234 below them, and in B5 a link shown as its address](../images/hyperlinks.png)

```julia
deleteHyperlink(s, "A3")
```

- **Text cells** get a link round their text, as LibreOffice's Insert ▸ Hyperlink makes. `display`
  sets the text.
- **Numbers and formulas** get a link of the cell itself, since their shown text isn't the cell's.
- **Places in the file** are given with `location`, a cell or range on a sheet.

LibreOffice has no tooltips for links, so `tooltip` is an error. A link stays with its cell through
edits, inserts, deletes, sorts and sheet copies.

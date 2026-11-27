```@meta
CurrentModule = OpenDocumentSpreadsheets
```

# Pictures

```julia
using OpenDocumentSpreadsheets
using OpenDocumentSpreadsheets: getImages

xf = newods("Report")
sh = xf["Report"]
sh["A1"] = "Our logo:"
addImage(sh, "B2", "logo.png")                              # its own size: a cell per 64 × 20 pixels
addImage(sh, "D2:G12", "chart.jpg"; alt = "Sales by month")  # stretched to fill D2:G12
getImages(sh)             # (sheet, media_name, from, to, alt, description) for each
```

```@raw html
<!-- shot: pictures cells=8x13 -->
```
![A sheet with a small red-to-yellow picture anchored at B2, and a photograph stretched over the cells D2 to G12](../images/pictures.png)

```julia
deleteImage(sh, "B2")
```

A picture (PNG, JPEG or GIF) is anchored to its first cell and resizes with its cells, as
LibreOffice's Anchor ▸ To Cell (resize with cell) does. It moves with its cell through inserts,
deletes, sorts and sheet copies. `alt` and `description` are the picture's short and long
descriptions for readers who can't see it: the *Text* and *Alt Text* fields of LibreOffice's
Format ▸ Alt Text.

## Not available

LibreOffice has no pictures inside cells, so `inCell=true` is an error that says why.

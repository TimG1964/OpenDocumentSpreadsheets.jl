```@meta
CurrentModule = OpenDocumentSpreadsheets
```

# Document properties

These are what LibreOffice shows in File ▸ Properties: the title, subject, keywords and comments on
its Description tab, the author and dates on its General tab, and its Custom Properties.

```julia
using OpenDocumentSpreadsheets

xf = newods("Sheet1")
setDocumentProperties(xf; title = "Budget 2027", creator = "Finance", keywords = "budget; plan")
setCustomProperty(xf, "Approved", true)
setCustomProperty(xf, "Version", 3)

OpenDocumentSpreadsheets.getDocumentProperties(xf).title     # "Budget 2027"
OpenDocumentSpreadsheets.getCustomProperties(xf)             # ["Approved" => true, "Version" => 3]
deleteCustomProperty(xf, "Version")
```

- Custom properties are text, numbers, booleans and dates, kept in name order, as LibreOffice
  keeps them.
- Saving never changes the modification date: set `modified` yourself if you want it.

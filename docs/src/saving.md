```@meta
CurrentModule = OpenDocumentSpreadsheets
```

# Saving and large files

## Formats and versions

[`writeods`](@ref) chooses the format from the file name:
- `.ods`, LibreOffice's usual zipped file;
- `.ots`, a template;
- `.fods`, flat XML: one file without zip, readable and easy to compare.

New files are written in ODF 1.4, the version LibreOffice writes, or in ODF 1.3 with
`version="1.3"`. An edited file keeps its version. Opening, editing and saving files is covered in
[Creating and editing files](tutorial/creatingFiles.md).

## Smaller files: `display_text=false`

`display_text=false` makes a file of numbers about half the size, and faster to write. It leaves out
the text shown in each number, date, time and boolean cell, which LibreOffice and
OpenDocumentSpreadsheets otherwise write beside the value. Spreadsheet programs work out the shown
text from the value, so nothing is lost:

```julia
using OpenDocumentSpreadsheets

squares = (n = collect(1:1000), square = collect(1:1000) .^ 2)
writetable("squares.ods", squares; display_text = false, overwrite = true)

xf = newods("Data")
xf["Data"]["A1:B2"] = [1 2; 3 4]
writeods("small.ods", xf; display_text = false, overwrite = true)

streamods("rows.ods"; display_text = false, overwrite = true) do s
    writerow!(addsheet!(s, "rows"), (1, 2))
end
```

Tools that read only the shown text, rather than the value, would see such cells as empty.

## Large files

- To write a file too large to hold in memory, write its rows as they are produced, with
  [`streamods`](@ref) or `writetable(...; streaming=true)`:

```julia
streamods("big.ods"; overwrite = true) do s
    sh = addsheet!(s, "data"; columns = ["n", "square"])
    for n in 1:1_000_000
        writerow!(sh, (n, n^2))
    end
end
```

- To read one sheet of a large file, use `readtable` or `readdata`: they read the file only as far as
  that sheet.
- To go through a large sheet row by row without loading it all, open the file with
  `openods(path; enable_cache=false)` and use `eachrow`: each row is read when you reach it, and not
  kept.

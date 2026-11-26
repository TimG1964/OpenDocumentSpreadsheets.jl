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

Like LibreOffice, OpenDocumentSpreadsheets writes each number, date, time and boolean cell twice: as
its value and as the text shown in the cell. Spreadsheet programs work out the shown text from the
value, so it can be left out:

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

For numeric data the files are then about half the size, and faster to write. Tools that read only
the shown text would see such cells as empty.

## Large files

- [`streamods`](@ref) and `writetable(...; streaming=true)` write rows as they are produced, in
  bounded memory:

```julia
streamods("big.ods"; overwrite = true) do s
    sh = addsheet!(s, "data"; columns = ["n", "square"])
    for n in 1:1_000_000
        writerow!(sh, (n, n^2))
    end
end
```

- `readtable` and `readdata` read a file only as far as the sheet they need.
- `openods(path; enable_cache=false)` with `eachrow` reads rows without keeping them.

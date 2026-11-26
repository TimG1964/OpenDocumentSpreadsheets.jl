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
writetable("big.ods", df; display_text = false)
writeods("out.ods", xf; display_text = false)
streamods(f, "rows.ods"; display_text = false)
```

For numeric data the files are then about half the size, and faster to write. Tools that read only
the shown text would see such cells as empty.

## Large files

- [`streamods`](@ref) and `writetable(...; streaming=true)` write rows as they are produced, in
  bounded memory:

```julia
streamods("big.ods") do s
    sh = addsheet!(s, "data"; columns = ["n", "square"])
    for n in 1:1_000_000
        writerow!(sh, (n, n^2))
    end
end
```

- `readtable` and `readdata` read a file only as far as the sheet they need.
- `openods(path; enable_cache=false)` with `eachrow` reads rows without keeping them.

```@meta
CurrentModule = OpenDocumentSpreadsheets
```

# Saving and writing

## Modes

| | |
|---|---|
| `readods(path)`, `openods(path)` | read only |
| `openods(path; mode="rw")` | read and edit; save with [`saveods`](@ref) or [`writeods`](@ref) |
| `openods(path; mode="w")`, [`newods`](@ref) | a new, empty file |

With the do-block form of [`openods`](@ref), a file opened for writing is saved when the
block ends (not if it throws).

## Editing keeps the rest of the file

OpenDocumentSpreadsheets does not rebuild a file it edits. It copies the original and rewrites only the rows
that hold edited or formatted cells, and the columns whose formats changed:

- untouched sheets, settings, images, charts and the other parts stay byte for byte
- styles are only added: new automatic styles go into content.xml, and named styles into
  styles.xml ([Formatting](formatting.md)). Styles OpenDocumentSpreadsheets made that no cell uses any more are
  not written.
- in an edited row, the cells you did not change keep their formatting, comments and links

A file saved without edits is identical to the original.

## Formats and versions

[`writeods`](@ref) chooses the format from the file name: `.ods`, `.ots` (a template) or `.fods`
(flat XML, one file without zip). New files are written in ODF 1.4, the version LibreOffice
writes, or in ODF 1.3 with `version="1.3"`. An edited file keeps its version.

## Smaller files: `display_text=false`

Like LibreOffice, OpenDocumentSpreadsheets writes each number, date, time and boolean cell twice: as its value
and as the text shown in the cell. Spreadsheet programs recompute the shown text from the
value, so it can be left out:

```julia
writetable("big.ods", df; display_text = false)
writeods("out.ods", xf; display_text = false)
streamods(f, "rows.ods"; display_text = false)
```

For numeric data the files are then about half the size and faster to write. Tools that read
only the shown text would see such cells as empty.

## Large files

- [`streamods`](@ref) and `writetable(...; streaming=true)` write rows as they are
  produced, in bounded memory.
- `readtable` and `readdata` read a file only as far as the sheet they need.
- `openods(path; enable_cache=false)` with `eachrow` reads rows without keeping them.

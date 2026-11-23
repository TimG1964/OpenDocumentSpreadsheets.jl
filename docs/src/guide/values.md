```@meta
CurrentModule = OpenDocumentSpreadsheets
```

# Cell values and types

An OpenDocument cell stores its value with a type. OpenDocumentSpreadsheets reads it as follows:

| Cell | Julia value |
|---|---|
| number, percentage, currency | `Int64` if the value is whole and its number format shows no decimals, else `Float64` |
| date | `Date`, or `DateTime` if it has a time or its format shows one |
| time (a duration) | `Dates.Time` from 0 to under 24 hours; otherwise a `Dates.CompoundPeriod` such as `1 day, 12 hours` |
| boolean | `Bool` |
| text | `String` (several paragraphs are joined with `"\n"`) |
| empty, empty text, error | `missing` |

Percentages are read as their value (50% reads as `0.5`). The currency of a currency cell is
in its [`Cell`](@ref) (`getcell(sheet, "B2").currency`).

## Errors

A formula whose result is an error reads as `missing`, as in XLSX.jl. [`iserror`](@ref) and
[`geterror`](@ref) tell them apart, with the text LibreOffice shows:

```julia
iserror(sh, "C1")      # true
geterror(sh, "C1")     # "#DIV/0!", or LibreOffice's own codes such as "Err:502"
```

## Cells

[`getcell`](@ref) gives the whole cell: its value type, value, formula, style name,
currency, error text and merge spans.

```julia
c = getcell(sh, "B2")
c.datatype     # :float, :percentage, :currency, :date, :time, :boolean, :string, :error, :empty
c.value
c.style        # the name of its cell style
```

Where a sheet holds nothing, `getcell` returns an [`EmptyCell`](@ref).

## Writing values

Writing takes numbers, strings, `Bool`, `Date`, `DateTime`, `Time`, periods (durations) and
`missing` or `nothing` (an empty cell). Whole numbers keep their type (`7` reads back as `7`,
`7.0` as `7.0`), and floats are written exactly.

Dates, times and booleans need a number format, or LibreOffice treats them as plain numbers
the next time it saves. OpenDocumentSpreadsheets gives them ISO formats (`2026-11-18`, `2026-11-18 13:45:00`,
`[HH]:MM:SS`, `TRUE`). A cell whose existing format fits the new value keeps it.

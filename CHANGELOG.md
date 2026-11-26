# Changelog

## Unreleased

### Changed
- **Sheet sizes on display (#1):** a file or sheet shows its size and range as soon as it is opened, rather than `size unknown`. Displaying reads a sheet that hasn't been read yet. An empty sheet shows `empty`.
- **Errors** print as `ODSError: …` (it was `SheetCoreError: …`). `ODSError` is the same type as before.
- **Row types:** `getComments`, `getThreadedComments`, `getHyperlinks`, `getDataValidations` (and their single-cell forms) and `Charts.getChartRanges` return `Vector{NamedTuple}`, with each row typed by its own values. Before, the rows had `Union` field types, so they printed as `@NamedTuple{…}((…))`. The fields are unchanged.

### Fixed
- **Compact displays** for values that used to print their internals:
  - `eachrow`, `eachtablerow` and their rows: these printed the whole sheet.
  - The chart and drawing types: these printed XML nodes.
  - `CellFont`, `CellFill`, `CellBorder`, `CellAlignment` and `CellFormat`.
  - `TableStyleInfo`.
- **A single `Chart`** shows its title, type and series.

### Tests
- **Quiet (#2):** a test run no longer prints a docs example's output.
- **Grouped by function (#2):** each group prints its results, with a line per file, as soon as it finishes, so a run shows progress. A failing group no longer stops the rest; the run fails at the end, naming it. `Pkg.test(test_args = ["charts"])` runs only the groups it names, and each group runs on its own. `write` is split into four groups.


## v0.1.0

Initial release.

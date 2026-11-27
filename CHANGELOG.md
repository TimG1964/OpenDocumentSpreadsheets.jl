# Changelog

## Unreleased

### Added

- `addChart(sheet, :histogram; anchor)` makes a histogram, and `addSeries` adds its series, as for
  any other chart; `addChart(file, :histogram; sheetname)` makes one on a chart sheet. A histogram
  also takes a subtitle and axis titles. `addChartEx` still works and makes the same chart.

### Fixed

- A sheet's own defined name that refers to cells on another sheet can be read, written and
  formatted through its sheet (`sheet["name"]`), giving those cells as LibreOffice does. It was an
  error. Writing through a file-wide name that refers to another sheet works too.

## v0.1.0

Initial release.

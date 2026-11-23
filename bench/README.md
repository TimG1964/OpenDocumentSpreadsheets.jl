# Benchmarks: OpenDocumentSpreadsheets against XLSX.jl

XLSX.jl 0.13.4's own benchmark fixtures and cases (its `bench/bench_worker.jl`). The `.xlsx` files are read by XLSX.jl, and LibreOffice's `.ods` conversions of them by OpenDocumentSpreadsheets.

```sh
bash bench/make_fixtures.sh                 # copies XLSX.jl's fixtures, converts them with LibreOffice
julia --project=bench -e 'using Pkg; Pkg.instantiate()'
julia --project=bench bench/run.jl bench/results/<name>.tsv
```

- **Fixtures:** `make_fixtures.sh` reads them from a read-only XLSX.jl checkout (`XLSX_BENCH_FIXTURES`, default `../../../XLSX-Cursor/XLSX.jl/bench/fixtures`). Both `fixtures/` folders are git-ignored.
- **Environment:** registered XLSX.jl 0.13.4 and this checkout of OpenDocumentSpreadsheets (`Pkg.develop(path="..")`).
- **Filters:** `BENCH_FIXTURES` and `BENCH_CASES` (comma-separated names) choose what runs; `BENCH_SECONDS` sets the time budget per case and package (default 10).
- **Output:** one TSV row per case, with fixture, case, both times, the ratio OpenDocumentSpreadsheets/XLSX.jl, and the allocations.

The results over time are summarised in the workspace's `records/benchmarks.md`.

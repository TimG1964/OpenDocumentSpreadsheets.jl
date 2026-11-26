# The core's exception type and sheet limits.
#
# `SheetCoreError` plays the role of XLSX.jl's `XLSXError` (MIT, see records/provenance.md):
# one type for every error the core raises itself. A back end can rethrow it as its own
# type, or catch it as it is (records/core-migration.md).

"""
    SheetCoreError(msg::String)

The exception the shared core throws for every error it raises itself, such as an invalid
cell reference, a malformed table or an unknown colour. `e isa SheetCoreError` tells these
apart from errors coming from Julia or from a dependency.
"""
struct SheetCoreError <: Exception
    msg::String
end

Base.showerror(io::IO, e::SheetCoreError) = print(io, "SheetCoreError: ", e.msg)

"""
    MAX_ROWS, MAX_COLS

The largest sheet: 1,048,576 rows by 16,384 columns (A to XFD). This is Excel's size, and
LibreOffice's since version 7.4, the size its 26.8 release writes (experiment 004).
"""
const MAX_ROWS = 1_048_576
const MAX_COLS = 16_384

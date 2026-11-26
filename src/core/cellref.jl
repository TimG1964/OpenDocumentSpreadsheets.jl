# Cell references and ranges: CellRef, CellRange, ColumnRange, RowRange, and the
# sheet-qualified SheetCellRef, SheetCellRange, SheetColumnRange, SheetRowRange and
# NonContiguousRange, with their A1-style parsing, validation, printing and iteration.
#
# Adapted from XLSX.jl 0.13.4 (src/types.jl lines 1-45 and 399-505, src/cellref.jl,
# and quoteit/unquoteit from src/workbook.jl),
# MIT License, Copyright (c) 2018-2026 Felipe Noronha Tavares and other contributors.
# See records/provenance.md. Changes from XLSX.jl:
#   - XLSXError → SheetCoreError; EXCEL_MAX_ROWS/EXCEL_MAX_COLS → MAX_ROWS/MAX_COLS
#   - dropped: the `==` methods for XLSX formula types, and
#     `NonContiguousRange(::Worksheet, ...)` (both need XLSX types)
#   - docstring examples say `SheetCore.` instead of `XLSX.`
#   - D-015: the sheet-qualified types take a style parameter, `ExcelStyle` (XLSX.jl's
#     `Sheet1!A1`, parsed and printed as before) or `ODFStyle` (LibreOffice's `Sheet1.A1`).
#     `string` uses `_sheet_prefix`/`_list_separator` for the style. The Excel parsers are
#     now the `{ExcelStyle}` constructors, and `nCR` takes the style first. There are no
#     style-less constructors. The ODFStyle parser and `parse_sheet_ref` are new.


struct CellPosition
    row::Int
    column::Int
end

"""
    CellRef(n::AbstractString)
    CellRef(row::Int, col::Int)

A `CellRef` represents a cell location given by row and column identifiers.

`CellRef("B6")` indicates a cell located at column `2` and row `6`.

These row and column integers can also be passed directly to the `CellRef` constructor: `CellRef(6,2) == CellRef("B6")`.

Finally, a convenience macro `@ref_str` is provided: `ref"B6" == CellRef("B6")`.

# Examples

```julia
cn = SheetCore.CellRef("AB1")
println( SheetCore.row_number(cn) ) # will print 1
println( SheetCore.column_number(cn) ) # will print 28
println( string(cn) ) # will print out AB1
println( cellname(cn) ) # will print out AB1

cn = SheetCore.CellRef(1, 28)
println( SheetCore.row_number(cn) ) # will print 1
println( SheetCore.column_number(cn) ) # will print 28
println( string(cn) ) # will print out AB1
println( cellname(cn) ) # will print out AB1

cn = SheetCore.ref"AB1"
println( SheetCore.row_number(cn) ) # will print 1
println( SheetCore.column_number(cn) ) # will print 28
println( string(cn) ) # will print out AB1
println( cellname(cn) ) # will print out AB1
```

"""
struct CellRef
    row_number::Int32
    column_number::Int32
end

#=
A `CellRange` represents a rectangular range of cells in a spreadsheet.

`CellRange("A1:C4")` denotes cells ranging from `A1` (upper left corner) to `C4` (bottom right corner).

As a convenience, `@range_str` macro is provided.

```julia
cr = SheetCore.range"A1:C4"
```
=#

abstract type AbstractCellRange end
abstract type ContiguousCellRange <: AbstractCellRange end
abstract type AbstractSheetCellRange <: AbstractCellRange end
abstract type ContiguousSheetCellRange <: AbstractSheetCellRange end

struct CellRange <: ContiguousCellRange
    start::CellRef
    stop::CellRef

    function CellRange(a::CellRef, b::CellRef)

        top = row_number(a)
        bottom = row_number(b)
        left = column_number(a)
        right = column_number(b)

        if left > right || top > bottom
            throw(SheetCoreError("Invalid CellRange. Start cell should be at the top left corner of the range."))
        end

        return new(a, b)
    end
end

struct ColumnRange <: ContiguousCellRange
    start::Int # column number
    stop::Int  # column number

    function ColumnRange(a::Integer, b::Integer)
        if a > b 
            throw(SheetCoreError("Invalid ColumnRange. Start column must be located before end column."))
        end
        return new(a, b)
    end
end
struct RowRange <: ContiguousCellRange
    start::Int # row number
    stop::Int  # row number

    function RowRange(a::Integer, b::Integer)
        if a > b
            throw(SheetCoreError("Invalid RowRange. Start row must be located before end row."))
        end
        return new(a, b)
    end
end

#
# Reference styles (D-015). A sheet-qualified reference carries the style of the package
# that made it, so that each package's users only ever see their own notation, even with
# both packages loaded in one session:
#   ExcelStyle: Sheet1!A1, 'My sheet'!A1:B2, lists joined by ","   (XLSX.jl)
#   ODFStyle:   Sheet1.A1, 'My sheet'.A1:B2, lists joined by "~"   (OpenDocumentSpreadsheets, as LibreOffice
#               shows references: experiment 006, F-017)
# Each back end binds the names to its own style, e.g. in OpenDocumentSpreadsheets
#   const SheetCellRef = SheetCore.SheetCellRef{SheetCore.ODFStyle}
# There are deliberately no style-less constructors: the core always knows which style.
#

"""
    RefStyle

The notation a sheet-qualified reference is written and shown in: [`ExcelStyle`](@ref)
(`Sheet1!A1`) or [`ODFStyle`](@ref) (`Sheet1.A1`, as LibreOffice shows).
"""
abstract type RefStyle end

"""
    ExcelStyle <: RefStyle

Excel's notation: `Sheet1!A1`, `'My sheet'!A1:B2`, lists of ranges joined by `,`. Parsing
accepts only this form.
"""
struct ExcelStyle <: RefStyle end

"""
    ODFStyle <: RefStyle

LibreOffice's notation: `Sheet1.A1`, `'My sheet'.A1:B2`, `'My sheet'.A:C`, lists of
ranges joined by `~`. Parsing also accepts absolute marks (`\$Sheet1.\$A\$1`), a sheet named on
both ends of a range (`'S'.A1:'S'.B2`), lists joined by `,`, and the `!` form other spreadsheet
programs use.
"""
struct ODFStyle <: RefStyle end

"""
    SheetCellRef{S<:RefStyle}(ref::AbstractString)
    SheetCellRef{S<:RefStyle}(sheet::AbstractString, cellref::CellRef)

A cell on a named sheet: a [`CellRef`](@ref) together with the name of its sheet, in
the fields `sheet` and `cellref`. `S` is the notation it is parsed from and shown in
(`RefStyle`); each back end binds `SheetCellRef` to its own style.

`SheetCellRef{ExcelStyle}("Sheet1!B2")` refers to cell `B2` on sheet `Sheet1`. A sheet name
containing spaces or other special characters is quoted, as in Excel:
`SheetCellRef{ExcelStyle}("'Sheet 1'!B2")`, which
`SheetCellRef{ExcelStyle}("Sheet 1", CellRef("B2"))` also gives. In `ODFStyle` the same
cell is `Sheet1.B2` and `'Sheet 1'.B2`.

# Examples

```julia
julia> r = SheetCore.SheetCellRef{SheetCore.ExcelStyle}("Sheet1!B2")
Sheet1!B2

julia> SheetCore.SheetCellRef{SheetCore.ODFStyle}("'My sheet'.B2")
'My sheet'.B2

julia> r.sheet
"Sheet1"

julia> r.cellref
B2
```
"""
struct SheetCellRef{S<:RefStyle}
    sheet::String
    cellref::CellRef
end

struct SheetCellRange{S<:RefStyle} <: ContiguousSheetCellRange
   sheet::String
   rng::CellRange
end

struct NonContiguousRange{S<:RefStyle} <: AbstractSheetCellRange
    sheet::String
    rng::Vector{Union{CellRef, CellRange}}
end

struct SheetColumnRange{S<:RefStyle} <: ContiguousSheetCellRange
    sheet::String
    colrng::ColumnRange
end
struct SheetRowRange{S<:RefStyle} <: ContiguousSheetCellRange
    sheet::String
    rowrng::RowRange
end

"""
    refstyle(r) -> Type{<:RefStyle}

The notation of a sheet-qualified reference.
"""
refstyle(::Union{SheetCellRef{S},SheetCellRange{S},NonContiguousRange{S},
                 SheetColumnRange{S},SheetRowRange{S}}) where {S} = S


function CellRef(n::AbstractString)
    i = 1
    len = ncodeunits(n)
    len == 0 && throw(SheetCoreError("$n is not a valid CellRef."))

    # scan letters for column (bytes: a non-ASCII character's bytes are never 'A':'Z')
    while i <= len && UInt8('A') <= codeunit(n, i) <= UInt8('Z')
        i += 1
    end
    col_end = i - 1
    col_end == 0 && throw(SheetCoreError("$n is not a valid CellRef."))
    
    # decode column number inline (no SubString, no decode_column_number call)
    col = 0
    for j in 1:col_end
        col = col * 26 + (codeunit(n, j) - UInt8('A') + 1)
    end
    
    # parse row number inline (no SubString, no parse() call)
    row = 0
    while i <= len
        c = codeunit(n, i)
        (c < UInt8('0') || c > UInt8('9')) && throw(SheetCoreError("$n is not a valid CellRef."))
        row = row * 10 + (c - UInt8('0'))
        i += 1
    end
    row == 0 && throw(SheetCoreError("$n is not a valid CellRef."))

    return CellRef(Int32(row), Int32(col))
end

@inline CellRef(row::Integer, col::Integer) = CellRef(Int32(row), Int32(col))
@inline CellPosition(ref::CellRef) = CellPosition(row_number(ref), column_number(ref))
@inline row_number(p::CellPosition) = p.row
@inline column_number(p::CellPosition) = p.column
@inline CellRef(p::CellPosition) = CellRef(row_number(p), column_number(p))

# Converts column name to a column number. See also SheetCore.encode_column_number.
function decode_column_number(column_name::AbstractString) :: Int
    local result::Int = 0

    !isascii(column_name) && throw(SheetCoreError("$column_name is not a valid column name."))
    num_characters = length(column_name) # this is safe, since `column_name` is encoded as ASCII

    iteration = 1
    for i in num_characters:-1:1
        column_char_as_int = Int(column_name[i])
        result += (26^(iteration-1)) * (column_char_as_int - 64) # From A to Z we have 26 values. 'A' Char is ASCII 65.
        iteration += 1
    end

    return result
end

# Converts column number to a column name. See also SheetCore.decode_column_number.
function encode_column_number(column_number::Integer) :: String
    if column_number <= 0 || column_number > MAX_COLS
        throw(SheetCoreError("Column number should be in the range from 1 to $MAX_COLS."))
    end

    third_letter_sequence = div(column_number - 26 - 1, 26*26)
    column_number = column_number - third_letter_sequence*(26*26)

    second_letter_sequence = div(column_number - 1, 26) # 26^1
    column_number = column_number - second_letter_sequence*(26)

    first_letter_sequence = column_number # 26^0

    if third_letter_sequence > 0
        # result will have 3 letters
        return String([ Char(third_letter_sequence+64), Char(second_letter_sequence+64), Char(first_letter_sequence+64) ])

    elseif second_letter_sequence > 0
        # result will have 2 letters
        return String([ Char(second_letter_sequence+64), Char(first_letter_sequence+64) ])

    else
        # result will have 1 letter
        return String([ Char(first_letter_sequence+64) ])
    end
end

function Base.print(io::IO, c::CellRef)
    col = column_number(c)
    third_letter_sequence = div(col - 26 - 1, 26*26)
    col = col - third_letter_sequence*(26*26)
    second_letter_sequence = div(col - 1, 26)
    col = col - second_letter_sequence*26
    first_letter_sequence = col

    if third_letter_sequence > 0
        write(io, Char(third_letter_sequence+64))
        write(io, Char(second_letter_sequence+64))
        write(io, Char(first_letter_sequence+64))
    elseif second_letter_sequence > 0
        write(io, Char(second_letter_sequence+64))
        write(io, Char(first_letter_sequence+64))
    else
        write(io, Char(first_letter_sequence+64))
    end
    print(io, row_number(c))
end

Base.show(io::IO, c::CellRef) = print(io, c)
Base.string(c::CellRef) = sprint(print, c)
Base.:(==)(c1::CellRef, c2::CellRef) = c1.row_number == c2.row_number && c1.column_number == c2.column_number
Base.hash(c::CellRef, h::UInt) = hash(c.column_number, hash(c.row_number, h))
Base.isless(c1::CellRef, c2::CellRef) = Base.isless(string(c1), string(c2))
cellname(c::CellRef) :: String = string(encode_column_number(column_number(c))) * string(row_number(c))


const RGX_COLUMN_NAME = r"^[A-Z]?[A-Z]?[A-Z]$"
const RGX_ROW_NAME = r"^[1-9][0-9]*$"
const RGX_CELLNAME = r"^[A-Z]+[0-9]+$"
const RGX_CELLRANGE = r"^[A-Z]+[0-9]+:[A-Z]+[0-9]+$"

function is_valid_column_name(n::AbstractString) :: Bool
    if !occursin(RGX_COLUMN_NAME, n)
        return false
    end

    column_number = decode_column_number(n)
    if column_number < 1 || column_number > MAX_COLS
        return false
    end

    return true
end
function is_valid_row_name(n::AbstractString) :: Bool
    if !occursin(RGX_ROW_NAME, n)
        return false
    end

    row_number = parse(Int, n)
    if row_number < 1 || row_number > MAX_ROWS
        return false
    end

    return true
end

const RGX_CELLNAME_LEFT = r"^[A-Z]+"
const RGX_CELLNAME_RIGHT = r"[0-9]+$"

# Splits a string representing a cell name to its column name and row number.
@inline function split_cellname(n::AbstractString)
    !isascii(n) && throw(SheetCoreError("$n is not a valid cell name."))
    for (i, c) in enumerate(n)
        if isdigit(c) # this block is safe since n is encoded as ASCII
            column_name = SubString(n, 1, i-1)
            row = parse(Int, SubString(n, i, length(n)))
            return column_name, row
        end
    end

    throw(SheetCoreError("Couldn't split (column_name, row) for cellname $n."))
end

# Whether Excel would read `name` as a cell address, in A1 or R1C1 style and in any case
# (`t1`, `XFD1`, `R1C1`, `RC`, `R`, `C`). Excel refuses a file with a table so named.
_is_cell_address_like(name::AbstractString)::Bool =
    _is_r1c1_address_like(name) || is_valid_cellname(uppercase(name))

# Whether `name` is an R1C1-style address (`R1C1`, `rc`), or just `R` or `C`, in any case.
# Excel refuses a file with a defined name or a table so named.
function _is_r1c1_address_like(name::AbstractString)::Bool
    u = uppercase(name)
    return u in ("R", "C") || occursin(r"^R[0-9]*C[0-9]*$", u)
end

# Checks whether `n` is a valid name for a cell.
function is_valid_cellname(n::AbstractString) :: Bool

    if is_valid_non_contiguous_range(n) # Non-contiguous ranges are comma separated `CellRef-like` or `CellRange-like` strings
        return false
    end

    if !occursin(RGX_CELLNAME, n)
        return false
    end

    column_name, row = split_cellname(n)

    if row < 1 || row > MAX_ROWS
        return false
    end

    if !is_valid_column_name(column_name)
        return false
    end

    return true
end

const RGX_CELLRANGE_START = r"^[A-Z]+[0-9]+"
const RGX_CELLRANGE_STOP = r"[A-Z]+[0-9]+$"

#=
    split_cellrange(n::AbstractString) -> start_name, stop_name

Splits a string representing a cell range into its cell names.

# Example

```julia
julia> SheetCore.split_cellrange("AB12:CD24")
("AB12", "CD24")
```
=#
@inline function split_cellrange(n::AbstractString)
    s = split(n, ":")
    length(s) != 2 && throw(SheetCoreError("$n is not a valid cell range."))
    return s[1], s[2]
end

function is_valid_cellrange(n::AbstractString) :: Bool
    if is_valid_non_contiguous_range(n) # Non-contiguous ranges are comma separated `CellRef-like` or `CellRange-like` strings
        return false
    end

    if !occursin(RGX_CELLRANGE, n)
        return false
    end

    start_name, stop_name = split_cellrange(n)

    if !is_valid_cellname(start_name)
        return false
    end

    if !is_valid_cellname(stop_name)
        return false
    end

    return true
end

macro ref_str(ref)
    CellRef(ref)
end

function CellRange(r::AbstractString)
    !occursin(RGX_CELLRANGE, r) && throw(SheetCoreError("Invalid cell range: $r."))
    start_name, stop_name = split_cellrange(r)
    return CellRange(CellRef(start_name), CellRef(stop_name))
end

CellRange(start_row::Integer, start_column::Integer, stop_row::Integer, stop_column::Integer) = CellRange(CellRef(start_row, start_column), CellRef(stop_row, stop_column))

Base.string(cr::CellRange) = string(cr.start)*":"*string(cr.stop)
Base.show(io::IO, cr::CellRange) = print(io, string(cr))
Base.:(==)(cr1::CellRange, cr2::CellRange) = cr1.start == cr2.start && cr1.stop == cr2.stop
Base.hash(cr::CellRange, h::UInt) = hash(cr.stop, hash(cr.start, h))
Base.isless(cr1::CellRange, cr2::CellRange) = Base.isless(string(cr1), string(cr2)) # needed for tests

macro range_str(cellrange)
    CellRange(cellrange)
end

# Checks whether `ref` is a cell reference inside a range given by `rng`.
function Base.in(ref::CellRef, rng::CellRange) :: Bool
    top = row_number(rng.start)
    bottom = row_number(rng.stop)
    r = row_number(ref)

    if top <= r && r <= bottom
        left = column_number(rng.start)
        right = column_number(rng.stop)
        c = column_number(ref)

        if left <= c && c <= right
            return true
        end
    end

    return false
end

# Checks whether `subrng` is a cell range contained in `rng`.
Base.issubset(subrng::CellRange, rng::CellRange) :: Bool = in(subrng.start, rng) && in(subrng.stop, rng)
 
function intersects(rng1::CellRange, rng2::CellRange) :: Bool
    if row_number(rng1.start) <= row_number(rng2.stop) && row_number(rng1.start) >= row_number(rng2.start) && 
        column_number(rng1.stop) <= column_number(rng2.stop) && column_number(rng1.stop) >= column_number(rng2.start)
        # offset 1
        return true
    end
    if row_number(rng2.start) <= row_number(rng1.stop) && row_number(rng2.start) >= row_number(rng1.start) && 
        column_number(rng2.stop) <= column_number(rng1.stop) && column_number(rng2.stop) >= column_number(rng1.start)
        # offset 2
        return true
    end
    if row_number(rng1.start)>=row_number(rng2.start) && column_number(rng1.start)<=column_number(rng2.start) && 
        row_number(rng1.stop)<=row_number(rng2.stop) && column_number(rng1.stop)>=column_number(rng2.stop)
        # cruciform 1
        return true
    end
    if row_number(rng2.start)>=row_number(rng1.start) && column_number(rng2.start)<=column_number(rng1.start) && 
        row_number(rng2.stop)<=row_number(rng1.stop) && column_number(rng2.stop)>=column_number(rng1.stop)
        # cruciform 2
        return true
    end
    if in(rng1.start, rng2) || in(rng1.stop, rng2)
        # inside corner 1
        return true
    end
    if in(rng2.start, rng1) || in(rng2.stop, rng1)
        # inside corner 2
        return true
    end
    if issubset(rng1, rng2) || issubset(rng2, rng1)
        # subset
        return true
    end
    return false
end


function Base.size(rng::CellRange)
    top = row_number(rng.start)
    bottom = row_number(rng.stop)
    left = column_number(rng.start)
    right = column_number(rng.stop)

    return ( bottom - top + 1, right - left + 1 )
end

"""
    row_number(c::CellRef) :: Int

Returns the row number of a given cell reference.
"""
row_number(c::CellRef) :: Int = c.row_number

"""
    column_number(c::CellRef) :: Int

Returns the column number of a given cell reference.
"""
column_number(c::CellRef) :: Int = c.column_number

column_name(c::CellRef) :: String = encode_column_number(column_number(c))

#=
Returns (row, column) representing a `ref` position relative to `rng`.

For example, for a range "B2:D4", we have:

* "C3" relative position is (2, 2)

* "B2" relative position is (1, 1)

* "C4" relative position is (3, 2)

* "D4" relative position is (3, 3)
=#

function relative_cell_position(ref::CellRef, rng::CellRange)
    ref ∉ rng && throw(SheetCoreError("$ref is outside range $rng."))

    top = row_number(rng.start)
    left = column_number(rng.start)

    r, c = row_number(ref), column_number(ref)

    return ( r - top + 1 , c - left + 1 )
end

#
# ColumnRange and RowRange
#

Base.string(cr::ColumnRange) = encode_column_number(cr.start)*":"*encode_column_number(cr.stop)
Base.show(io::IO, cr::ColumnRange) = print(io, string(cr))
Base.:(==)(cr1::ColumnRange, cr2::ColumnRange) = cr1.start == cr2.start && cr1.stop == cr2.stop
Base.hash(cr::ColumnRange, h::UInt) = hash(cr.stop, hash(cr.start, h))
Base.in(column_number::Integer, rng::ColumnRange) = rng.start <= column_number && column_number <= rng.stop

Base.string(cr::RowRange) = string(cr.start)*":"*string(cr.stop)
Base.show(io::IO, cr::RowRange) = print(io, string(cr))
Base.:(==)(cr1::RowRange, cr2::RowRange) = cr1.start == cr2.start && cr1.stop == cr2.stop
Base.hash(cr::RowRange, h::UInt) = hash(cr.stop, hash(cr.start, h))
Base.in(row_number::Integer, rng::RowRange) = rng.start <= row_number && row_number <= rng.stop

function cell_offset(from::CellRef, to::CellRef) # return tuple (row_offset, column_offset) between `from` and `to` cells
    offset = (to.row_number - from.row_number, to.column_number - from.column_number)
    (first(offset)>=0 && last(offset) >=0) || throw(SheetCoreError("The 'to' cell cannot be above or to the left of the 'from' cell."))
    return offset
end


const RGX_COLUMN_RANGE = r"^[A-Z]?[A-Z]?[A-Z]:[A-Z]?[A-Z]?[A-Z]$"
const RGX_COLUMN_RANGE_START = r"^[A-Z]+"
const RGX_COLUMN_RANGE_STOP = r"[A-Z]+$"
const RGX_SINGLE_COLUMN = r"^[A-Z]+$"
const RGX_ROW_RANGE = r"^[1-9][0-9]*:[1-9][0-9]*$"
const RGX_ROW_RANGE_START = r"^[1-9][0-9]*"
const RGX_ROW_RANGE_STOP = r"[1-9][0-9]*$"
const RGX_SINGLE_ROW = r"^[1-9][0-9]*$"

# Returns tuple (column_name_start, column_name_stop).
# Also works for row ranges (row_name_start, row_name_stop)!
@inline function split_sheet_range(n::AbstractString)
    if !occursin(":", n)
        return n, n
    else
        s = split(n, ":")
        return s[1], s[2]
    end
end

function is_valid_column_range(r::AbstractString) :: Bool
    if occursin(RGX_SINGLE_COLUMN, r)
        return true
    end
    if !occursin(RGX_COLUMN_RANGE, r)
        return false
    end
    start_name, stop_name = split_sheet_range(r)
    if !is_valid_column_name(start_name) || !is_valid_column_name(stop_name)
        return false
    end
    return true
end
function is_valid_row_range(r::AbstractString) :: Bool
    if occursin(RGX_SINGLE_ROW, r)
        row_number = parse(Int, r)
        if row_number <= 0 || row_number > MAX_ROWS
            throw(SheetCoreError("Row number should be in the range from 1 to $MAX_ROWS."))
        end
        return true
    end
    if !occursin(RGX_ROW_RANGE, r)
        return false
    end
    start_name, stop_name = split_sheet_range(r) # Function works for row ranges too.
    if !is_valid_row_name(start_name) || !is_valid_row_name(stop_name)
        return false
    end
    return true
end

function RowRange(r::AbstractString)
    if is_valid_cellrange(r)
        cr=CellRange(r)
        return RowRange(row_number(cr.start), row_number(cr.stop))
    end
    !is_valid_row_range(r) && throw(SheetCoreError("Invalid row range: $r."))
    start_name, stop_name = split_sheet_range(r) 
    return RowRange(parse(Int, start_name), parse(Int, stop_name))
end
function ColumnRange(r::AbstractString)
    if is_valid_cellrange(r)
        cr=CellRange(r)
        return ColumnRange(column_number(cr.start), column_number(cr.stop))
    end
        !is_valid_column_range(r) && throw(SheetCoreError("Invalid column range: $r."))
    start_name, stop_name = split_sheet_range(r)
    return ColumnRange(decode_column_number(start_name), decode_column_number(stop_name))
end

Base.convert(::Type{ColumnRange}, str::AbstractString) = ColumnRange(str)
Base.convert(::Type{ColumnRange}, column_range::ColumnRange) = column_range
Base.convert(::Type{RowRange}, str::AbstractString) = RowRange(str)
Base.convert(::Type{RowRange}, row_range::RowRange) = row_range

column_bounds(r::ColumnRange) = (r.start, r.stop)
Base.length(r::ColumnRange) = r.stop - r.start + 1
row_bounds(r::RowRange) = (r.start, r.stop)
Base.length(r::RowRange) = r.stop - r.start + 1

# ColumnRange iterator: element is a String with the column name, the state is the column number.
function Base.iterate(itr::ColumnRange, state::Int=itr.start)
    if state > itr.stop
        return nothing
    end

    return encode_column_number(state), state + 1
end

# RowRange iterator: element is a String with the row name (e.g. "1"). The state is the row number.
function Base.iterate(itr::RowRange, state::Int=itr.start)
    if state > itr.stop
        return nothing
    end

    return string(state), state + 1
end

# CellRange iterator: element is a CellRef, the state is a CellPosition.
function Base.iterate(rng::CellRange, state::CellPosition=CellPosition(rng.start))

    if row_number(state) > row_number(rng.stop)
        return nothing
    elseif column_number(state) == column_number(rng.stop)
        # reached last column. Go to the next row.
        next_state = CellPosition(row_number(state) + 1, column_number(rng.start))
    else
        # go to the next column
        next_state = CellPosition(row_number(state), column_number(state) + 1)
    end

    return CellRef(state), next_state
end

function Base.length(rng::CellRange)
    (r, c) = size(rng)
    return r * c
end

#
# SheetCellRef, SheetCellRange, SheetColumnRange, SheetRowRange, NonContiguousRange
#

# The sheet prefix and the list separator of each style. LibreOffice quotes the same sheet
# names Excel does (experiment 006, F-017), so both use `quoteit`.
_sheet_prefix(::Type{ExcelStyle}, sheet::AbstractString) = string(quoteit(sheet), "!")
_sheet_prefix(::Type{ODFStyle}, sheet::AbstractString) = string(quoteit(sheet), ".")
_list_separator(::Type{ExcelStyle}) = ","
_list_separator(::Type{ODFStyle}) = "~"

# Equality and hashing ignore the style: it is how a reference is written, not what it
# refers to.
Base.string(cr::SheetCellRef{S}) where {S} = string(_sheet_prefix(S, cr.sheet), cr.cellref)
Base.show(io::IO, cr::SheetCellRef) = print(io, string(cr))
Base.:(==)(cr1::SheetCellRef, cr2::SheetCellRef) = cr1.sheet == cr2.sheet && cr1.cellref == cr2.cellref
Base.hash(cr::SheetCellRef, h::UInt) = hash(cr.cellref, hash(cr.sheet, h))

Base.string(cr::SheetCellRange{S}) where {S} = string(_sheet_prefix(S, cr.sheet), cr.rng)
Base.show(io::IO, cr::SheetCellRange) = print(io, string(cr))
Base.:(==)(cr1::SheetCellRange, cr2::SheetCellRange) = cr1.sheet == cr2.sheet && cr1.rng == cr2.rng
Base.hash(cr::SheetCellRange, h::UInt) = hash(cr.rng, hash(cr.sheet, h))

Base.string(cr::SheetColumnRange{S}) where {S} = string(_sheet_prefix(S, cr.sheet), cr.colrng)
Base.show(io::IO, cr::SheetColumnRange) = print(io, string(cr))
Base.:(==)(cr1::SheetColumnRange, cr2::SheetColumnRange) = cr1.sheet == cr2.sheet && cr1.colrng == cr2.colrng
Base.hash(cr::SheetColumnRange, h::UInt) = hash(cr.colrng, hash(cr.sheet, h))

Base.string(cr::SheetRowRange{S}) where {S} = string(_sheet_prefix(S, cr.sheet), cr.rowrng)
Base.show(io::IO, cr::SheetRowRange) = print(io, string(cr))
Base.:(==)(cr1::SheetRowRange, cr2::SheetRowRange) = cr1.sheet == cr2.sheet && cr1.rowrng == cr2.rowrng
Base.hash(cr::SheetRowRange, h::UInt) = hash(cr.rowrng, hash(cr.sheet, h))

Base.string(cr::NonContiguousRange{S}) where {S} = join([string(_sheet_prefix(S, cr.sheet), x) for x in cr.rng], _list_separator(S))
Base.show(io::IO, cr::NonContiguousRange) = print(io, string(cr))
Base.:(==)(cr1::NonContiguousRange, cr2::NonContiguousRange) = cr1.sheet == cr2.sheet && cr1.rng == cr2.rng
Base.hash(cr::NonContiguousRange, h::UInt) = hash(cr.rng, hash(cr.sheet, h))

function Base.in(ref::SheetCellRef, ncrng::NonContiguousRange) :: Bool
    if ref.sheet != ncrng.sheet
        return false
    end
    for r in ncrng.rng
        if r isa CellRef
            if ref.cellref == r
                return true
            end
        else
            if ref.cellref in r
                return true
            end
        end
    end
    return false
end

function nc_bounds(r::NonContiguousRange)::CellRange # Smallest rectangualar `CellRange` that contains all the elements in `r`.
    top = MAX_ROWS
    bottom = 0
    left = MAX_COLS
    right = 0
    for rng in r.rng
        if isa(rng, CellRef)
            top = min(top, row_number(rng))
            bottom = max(bottom, row_number(rng))
            left = min(left, column_number(rng))
            right = max(right, column_number(rng))
        else
            top = min(top, row_number(rng.start))
            bottom = max(bottom, row_number(rng.stop))
            left = min(left, column_number(rng.start))
            right = max(right, column_number(rng.stop))
        end
    end
    return CellRange(CellRef(top, left), CellRef(bottom, right))
end
function Base.length(r::NonContiguousRange)::Int # Number of cells in `r`, eliminating duplicates.
    allcells= Vector{String}()
    for rng in r.rng
        if rng isa CellRef
            push!(allcells, cellname(rng))
        else
            for cell in rng
                push!(allcells, cellname(cell))
            end
        end
    end
    return length(unique(allcells))
end

const RGX_SHEET_CELLNAME = r"^.+![A-Z]+[0-9]+$"
const RGX_SHEET_CELLRANGE = r"^.+![A-Z]+[0-9]+:[A-Z]+[0-9]+$"
const RGX_SHEET_COLUMN_RANGE = r"^.+![A-Z]?[A-Z]?[A-Z]:[A-Z]?[A-Z]?[A-Z]$"
const RGX_SHEET_ROW_RANGE = r"^.+![1-9][0-9]*:[1-9][0-9]*$"

const RGX_SHEET_CELLNAME_RIGHT = r"[A-Z]+[0-9]+$"
const RGX_SHEET_CELLRANGE_RIGHT = r"[A-Z]+[0-9]+:[A-Z]+[0-9]+$"
const RGX_SHEET_COLUMN_RANGE_RIGHT = r"[A-Z]?[A-Z]?[A-Z]:[A-Z]?[A-Z]?[A-Z]$"
const RGX_SHEET_ROW_RANGE_RIGHT = r"[1-9][0-9]*:[1-9][0-9]*$"

function is_valid_sheet_cellname(n::AbstractString) :: Bool

    if is_valid_non_contiguous_range(n) # Non-contiguous ranges are comma separated `CellRef-like` or `CellRange-like` strings
        return false
    end

    if !occursin(RGX_SHEET_CELLNAME, n)
        return false
    end

    cellname = match(RGX_SHEET_CELLNAME_RIGHT, n).match
    if !is_valid_cellname(cellname)
        return false
    end

    return true
end

function is_valid_sheet_cellrange(n::AbstractString) :: Bool

    if is_valid_non_contiguous_range(n) # Non-contiguous ranges are comma separated `CellRef-like` or `CellRange-like` strings
        return false
    end

    if !occursin(RGX_SHEET_CELLRANGE, n)
        return false
    end

    cellrange = match(RGX_SHEET_CELLRANGE_RIGHT, n).match
    if !is_valid_cellrange(cellrange)
        return false
    end

    return true
end

function is_valid_sheet_column_range(n::AbstractString) :: Bool
    if !occursin(RGX_SHEET_COLUMN_RANGE, n)
        return false
    end

    column_range = match(RGX_SHEET_COLUMN_RANGE_RIGHT, n).match
    if !is_valid_column_range(column_range)
        return false
    end

    return true
end
function is_valid_sheet_row_range(n::AbstractString) :: Bool
    if !occursin(RGX_SHEET_ROW_RANGE, n)
        return false
    end

    row_range = match(RGX_SHEET_ROW_RANGE_RIGHT, n).match
    if !is_valid_row_range(row_range)
        return false
    end

    return true
end

const RGX_SHEET_PREFIX = r"^.+!"
const RGX_SHEET_CELLNAME_RIGHT_FIXED = r"\$[A-Z]+\$[0-9]+$"
const RGX_SHEET_CELLRANGE_RIGHT_FIXED = r"\$[A-Z]+\$[0-9]+:\$[A-Z]+\$[0-9]+$"
const RGX_SHEET_COLUMN_RANGE_RIGHT_FIXED = r"\$[A-Z]?[A-Z]?[A-Z]:\$[A-Z]?[A-Z]?[A-Z]$"
const RGX_SHEET_ROW_RANGE_RIGHT_FIXED    = r"\$[1-9][0-9]*:\$[1-9][0-9]*$"

function parse_sheetname_from_sheetcell_name(n::AbstractString) :: SubString
    !occursin(RGX_SHEET_PREFIX, n) && throw(SheetCoreError("$n is not a SheetCell reference."))
    sheetname = match(RGX_SHEET_PREFIX, n).match
    sheetname = SubString(sheetname, firstindex(sheetname), prevind(sheetname, lastindex(sheetname)))
    return sheetname
end

function SheetCellRef{ExcelStyle}(n::AbstractString)
    local cellref::CellRef

    if is_valid_fixed_sheet_cellname(n)
        fixed_cellname = match(RGX_SHEET_CELLNAME_RIGHT_FIXED, n).match
        cellref = CellRef(replace(fixed_cellname, "\$" => ""))
    else
        !is_valid_sheet_cellname(n) && throw(SheetCoreError("$n is not a valid SheetCellRef."))
        cellref = CellRef(match(RGX_SHEET_CELLNAME_RIGHT, n).match)
    end
    sheetname = unquoteit(parse_sheetname_from_sheetcell_name(n))
    return SheetCellRef{ExcelStyle}(sheetname, cellref)
end

function SheetCellRange{ExcelStyle}(n::AbstractString)
    local cellrange::CellRange

    if is_valid_fixed_sheet_cellrange(n)
        fixed_cellrange = match(RGX_SHEET_CELLRANGE_RIGHT_FIXED, n).match
        cellrange = CellRange(replace(fixed_cellrange, "\$" => ""))
    else
        !is_valid_sheet_cellrange(n) && throw(SheetCoreError("$n is not a valid SheetCellRange."))
        cellrange = CellRange(match(RGX_SHEET_CELLRANGE_RIGHT, n).match)
    end

    sheetname = unquoteit(parse_sheetname_from_sheetcell_name(n))
    return SheetCellRange{ExcelStyle}(sheetname, cellrange)
end

function SheetColumnRange{ExcelStyle}(n::AbstractString)
    local column_range::ColumnRange

    if is_valid_fixed_sheet_column_range(n)
        fixed = match(RGX_SHEET_COLUMN_RANGE_RIGHT_FIXED, n).match
        column_range = ColumnRange(replace(fixed, "\$" => ""))
    else
        !is_valid_sheet_column_range(n) && throw(SheetCoreError("$n is not a valid SheetColumnRange."))
        column_range = ColumnRange(match(RGX_SHEET_COLUMN_RANGE_RIGHT, n).match)
    end

    sheetname = unquoteit(parse_sheetname_from_sheetcell_name(n))
    return SheetColumnRange{ExcelStyle}(sheetname, column_range)
end

function SheetRowRange{ExcelStyle}(n::AbstractString)
    local row_range::RowRange

    if is_valid_fixed_sheet_row_range(n)
        fixed = match(RGX_SHEET_ROW_RANGE_RIGHT_FIXED, n).match
        row_range = RowRange(replace(fixed, "\$" => ""))
    else
        !is_valid_sheet_row_range(n) && throw(SheetCoreError("$n is not a valid SheetRowRange."))
        row_range = RowRange(match(RGX_SHEET_ROW_RANGE_RIGHT, n).match)
    end

    sheetname = unquoteit(parse_sheetname_from_sheetcell_name(n))
    return SheetRowRange{ExcelStyle}(sheetname, row_range)
end

# Named ranges
const RGX_FIXED_CELLNAME = r"^\$[A-Z]+\$[0-9]+$"
const RGX_FIXED_CELLRANGE = r"^\$[A-Z]+\$[0-9]+:\$[A-Z]+\$[0-9]+$"
const RGX_FIXED_SHEET_CELLNAME = r"^.+!\$[A-Z]+\$[0-9]+$"
const RGX_FIXED_SHEET_CELLRANGE = r"^.+!\$[A-Z]+\$[0-9]+:\$[A-Z]+\$[0-9]+$"
const RGX_FIXED_SHEET_COLUMN_RANGE = r"^.+!\$[A-Z]?[A-Z]?[A-Z]:\$[A-Z]?[A-Z]?[A-Z]$"
const RGX_FIXED_SHEET_ROW_RANGE    = r"^.+!\$[1-9][0-9]*:\$[1-9][0-9]*$"

is_valid_fixed_cellname(s::AbstractString) = occursin(RGX_FIXED_CELLNAME, s)
is_valid_fixed_cellrange(s::AbstractString) = occursin(RGX_FIXED_CELLRANGE, s)
is_valid_fixed_sheet_cellname(s::AbstractString) = occursin(RGX_FIXED_SHEET_CELLNAME, s)
is_valid_fixed_sheet_cellrange(s::AbstractString) = occursin(RGX_FIXED_SHEET_CELLRANGE, s)
is_valid_fixed_sheet_column_range(s::AbstractString) = occursin(RGX_FIXED_SHEET_COLUMN_RANGE, s)
is_valid_fixed_sheet_row_range(s::AbstractString)    = occursin(RGX_FIXED_SHEET_ROW_RANGE, s)

is_valid_non_contiguous_range(v::AbstractString) :: Bool = is_valid_non_contiguous_cellrange(v) || is_valid_non_contiguous_sheetcellrange(v)

function is_valid_non_contiguous_sheetcellrange(v::AbstractString) :: Bool

    if !occursin(",", string(v)) # Non-contiguous ranges are comma separated `SheetCellRef-like` or `SheetCellRange-like` strings
        return false
    end

    ranges = split(v, ",")
    for r in ranges
        if !is_valid_sheet_cellname(r) && !is_valid_sheet_cellrange(r) && !is_valid_fixed_sheet_cellname(r) && !is_valid_fixed_sheet_cellrange(r)
            return false
        end
    end

    firstsheet = parse_sheetname_from_sheetcell_name(ranges[begin])

    if any(parse_sheetname_from_sheetcell_name(r) != firstsheet for r in ranges) # All `SheetCellRef`s and `SheetCellRange`s should have the same sheet name
        return false
    end

    return true
end

function is_valid_non_contiguous_cellrange(v::AbstractString) :: Bool

    if !occursin(",", string(v)) # Non-contiguous ranges are comma separated `SheetCellRef-like` or `SheetCellRange-like` strings

        return false
    end

    ranges = split(v, ",")

    for r in ranges
        if !is_valid_cellname(r) && !is_valid_cellrange(r) &&!is_valid_fixed_cellname(r) && !is_valid_fixed_cellrange(r)
            return false
        end
    end

    return true
end

function NonContiguousRange{ExcelStyle}(v::AbstractString)::NonContiguousRange{ExcelStyle}

    !is_valid_non_contiguous_sheetcellrange(v) && throw(SheetCoreError("$v is not a valid non-contiguous sheetcell range."))
    
    ranges = string.(split(v, ","))
    firstsheet = parse_sheetname_from_sheetcell_name(ranges[1])
    if !all(parse_sheetname_from_sheetcell_name(r) == firstsheet for r in ranges)
        throw(SheetCoreError("All `CellRef`s and `CellRange`s should have the same sheet name."))
    end

    return nCR(ExcelStyle, unquoteit(firstsheet), ranges)
end

# The areas are parsed in Excel form (with or without a sheet), whatever the style `S` of
# the result: ODFStyle input is rewritten to that form before it gets here.
function nCR(::Type{S}, s::AbstractString, ranges::Vector{String}) :: NonContiguousRange{S} where {S<:RefStyle}
    noncontig = Vector{Union{CellRef, CellRange}}()
    
    for n in ranges
        if is_valid_fixed_sheet_cellname(n)
            fixed_cellname = match(RGX_SHEET_CELLNAME_RIGHT_FIXED, n).match
            push!(noncontig, CellRef(replace(fixed_cellname, "\$" => "")))
        elseif is_valid_sheet_cellname(n)
            push!(noncontig, CellRef(match(RGX_SHEET_CELLNAME_RIGHT, n).match))
        elseif is_valid_fixed_sheet_cellrange(n)
            fixed_cellrange = match(RGX_SHEET_CELLRANGE_RIGHT_FIXED, n).match
            push!(noncontig, CellRange(replace(fixed_cellrange, "\$" => "")))
        elseif is_valid_sheet_cellrange(n)
            push!(noncontig, CellRange(match(RGX_SHEET_CELLRANGE_RIGHT, n).match))
        elseif is_valid_fixed_cellname(n)
            push!(noncontig, CellRef(replace(n, "\$" => "")))
        elseif is_valid_fixed_cellrange(n)
            push!(noncontig, CellRange(replace(n, "\$" => "")))
        elseif is_valid_cellname(n)
            push!(noncontig, CellRef(n))
        elseif is_valid_cellrange(n)
            push!(noncontig, CellRange(n))
        else
            throw(SheetCoreError("Invalid non-contiguous range: $n."))
        end
    end

    return NonContiguousRange{S}(s, noncontig)
end

const NCArea = Union{CellRef,CellRange}

_area(r1, c1, r2, c2) =
    (r1 == r2 && c1 == c2) ? CellRef(r1, c1) :
                             CellRange(CellRef(r1, c1), CellRef(r2, c2))

"""
    _compress(cells::AbstractVector{CellRef}) -> Vector{Union{CellRef,CellRange}}

Merge a set of cell references into the smallest convenient set of areas covering
exactly the same cells.

Consecutive rows within a column are merged into a `CellRange`, and horizontally
adjacent columns sharing an identical set of row runs are merged into a rectangle.
Single cells that merge with nothing are returned as `CellRef`. No attempt is made
to find a minimal rectangle cover: a ragged selection may return more areas than
strictly necessary.

Duplicate references are ignored. Areas are returned ordered by column block, then
by row within each block, which is not in general the order the cells were supplied in.

Used to keep the `sqref` attribute of a non-contiguous range compact. An
uncompressed selection of scattered cells can exceed what Excel will accept.
"""
function _compress(cells::AbstractVector{CellRef})::Vector{NCArea}
    isempty(cells) && return NCArea[]

    bycol = Dict{Int,Vector{Int}}()
    for c in cells
        push!(get!(() -> Int[], bycol, c.column_number), c.row_number)
    end

    # vertical runs within each column
    runs = Dict{Int,Vector{UnitRange{Int}}}()
    for (col, rows) in bycol
        unique!(sort!(rows))
        v = UnitRange{Int}[]
        i = 1
        while i <= length(rows)
            j = i
            while j < length(rows) && rows[j+1] == rows[j] + 1
                j += 1
            end
            push!(v, rows[i]:rows[j])
            i = j + 1
        end
        runs[col] = v
    end

    # merge adjacent columns whose run sets are identical -> rectangles
    areas = NCArea[]
    cols = sort!(collect(keys(runs)))
    i = 1
    while i <= length(cols)
        j = i
        while j < length(cols) && cols[j+1] == cols[j] + 1 && runs[cols[j+1]] == runs[cols[i]]
            j += 1
        end
        for r in runs[cols[i]]
            push!(areas, _area(first(r), cols[i], last(r), cols[j]))
        end
        i = j + 1
    end
    return areas
end

#
# ODFStyle parsing (D-015), new in SheetCore. LibreOffice's notation as experiment 006
# found it (F-017): `Sheet1.A1`, `'My sheet'.A1:B2`, `'It''s'.A1`, `$'S'.$A$1`,
# `'S'.A1:'S'.B2`, `'S'.A:C`, `'S'.2:4`, and lists joined by `~`. Also accepted: lists
# joined by `,`, and Excel's `!` in place of `.` (D-014).
#

# Split `s` at the characters in `seps` that are outside single-quoted sheet names.
function _split_unquoted(s::AbstractString, seps)::Vector{String}
    parts = String[]
    buf = IOBuffer()
    inq = false
    for c in s
        if c == '\''
            inq = !inq            # a doubled '' inside a name toggles twice
        elseif !inq && c in seps
            push!(parts, String(take!(buf)))
            continue
        end
        print(buf, c)
    end
    inq && throw(SheetCoreError("Unbalanced quote in the reference `$s`."))
    push!(parts, String(take!(buf)))
    return parts
end

# One end of an area, such as `$'My sheet'.$A$1`, `Sheet1!A1` or `B2`: the sheet name
# (unquoted; `nothing` if none is given) and the reference with its `$` marks removed.
function _odf_split_end(a::AbstractString)::Tuple{Union{Nothing,String},String}
    a = strip(a)
    isempty(a) && throw(SheetCoreError("Empty reference."))
    rest = startswith(a, '$') ? SubString(a, nextind(a, firstindex(a))) : SubString(a, firstindex(a))
    if startswith(rest, '\'')
        name = IOBuffer()
        j = nextind(rest, firstindex(rest))
        while true
            j > lastindex(rest) && throw(SheetCoreError("Unbalanced quote in the reference `$a`."))
            c = rest[j]
            if c == '\''
                k = nextind(rest, j)
                if k <= lastindex(rest) && rest[k] == '\''     # '' is a quote in the name
                    print(name, '\'')
                    j = nextind(rest, k)
                    continue
                end
                j = k
                break
            end
            print(name, c)
            j = nextind(rest, j)
        end
        (j <= lastindex(rest) && rest[j] in ('.', '!')) ||
            throw(SheetCoreError("Expected `.` after the sheet name in `$a`."))
        return String(take!(name)), replace(String(SubString(rest, nextind(rest, j))), "\$" => "")
    end
    # unquoted: the name ends at the last `!`, or else at the last `.`
    k = findlast('!', rest)
    k === nothing && (k = findlast('.', rest))
    k === nothing && return nothing, replace(String(rest), "\$" => "")
    name = String(SubString(rest, firstindex(rest), prevind(rest, k)))
    isempty(name) && return nothing, replace(String(SubString(rest, nextind(rest, k))), "\$" => "")
    return name, replace(String(SubString(rest, nextind(rest, k))), "\$" => "")
end

# A reference without a sheet, as the type it names.
function _classify_ref(r::AbstractString, orig::AbstractString)
    is_valid_cellname(r) && return CellRef(r)
    is_valid_cellrange(r) && return CellRange(r)
    is_valid_column_range(r) && return ColumnRange(r)
    occursin(RGX_ROW_RANGE, r) && is_valid_row_range(r) && return RowRange(r)
    throw(SheetCoreError("`$orig` is not a valid reference."))
end

# One area in ODFStyle: its sheet (or `nothing`) and what it refers to.
function _odf_parse_area(a::AbstractString)
    ends = _split_unquoted(a, (':',))
    length(ends) > 2 && throw(SheetCoreError("`$a` is not a valid reference."))
    sheet, r1 = _odf_split_end(ends[1])
    length(ends) == 1 && return sheet, _classify_ref(r1, a)
    sheet2, r2 = _odf_split_end(ends[2])
    sheet2 === nothing || sheet2 == something(sheet, sheet2) ||
        throw(SheetCoreError("`$a` spans two sheets, which is not supported."))
    sheet === nothing && (sheet = sheet2)
    return sheet, _classify_ref(r1 * ":" * r2, a)
end

function _odf_sheet_area(a::AbstractString, want::Type, what::AbstractString)
    sheet, x = _odf_parse_area(a)
    sheet === nothing && throw(SheetCoreError("`$a` has no sheet name; write it as `Sheet1.$(strip(a))`."))
    x isa want || throw(SheetCoreError("`$a` is not a valid $what."))
    return sheet, x
end

SheetCellRef{ODFStyle}(n::AbstractString) =
    SheetCellRef{ODFStyle}(_odf_sheet_area(n, CellRef, "cell reference")...)
SheetCellRange{ODFStyle}(n::AbstractString) =
    SheetCellRange{ODFStyle}(_odf_sheet_area(n, CellRange, "cell range")...)
SheetColumnRange{ODFStyle}(n::AbstractString) =
    SheetColumnRange{ODFStyle}(_odf_sheet_area(n, ColumnRange, "column range")...)
SheetRowRange{ODFStyle}(n::AbstractString) =
    SheetRowRange{ODFStyle}(_odf_sheet_area(n, RowRange, "row range")...)

# A list of cells and ranges on one sheet. Areas after the first may leave the sheet out.
function NonContiguousRange{ODFStyle}(v::AbstractString)::NonContiguousRange{ODFStyle}
    items = _split_unquoted(v, ('~', ','))
    sheet = nothing
    areas = Vector{Union{CellRef,CellRange}}()
    for it in items
        s, x = _odf_parse_area(it)
        x isa Union{CellRef,CellRange} ||
            throw(SheetCoreError("`$v`: a list of ranges holds cells and cell ranges only, not `$(strip(it))`."))
        if sheet === nothing
            s === nothing && throw(SheetCoreError("`$v` has no sheet name."))
            sheet = s
        elseif s !== nothing && s != sheet
            throw(SheetCoreError("`$v`: all the areas must be on the same sheet."))
        end
        push!(areas, x)
    end
    return NonContiguousRange{ODFStyle}(sheet, areas)
end

"""
    parse_sheet_ref(S::Type{<:RefStyle}, s::AbstractString)

Parse a sheet-qualified reference in style `S` into whichever type it names:
`SheetCellRef{S}`, `SheetCellRange{S}`, `SheetColumnRange{S}`, `SheetRowRange{S}` or
`NonContiguousRange{S}`. Throws `SheetCoreError` if `s` is none of these.

```julia
julia> SheetCore.parse_sheet_ref(SheetCore.ODFStyle, "'My sheet'.A:C")
'My sheet'.A:C

julia> SheetCore.parse_sheet_ref(SheetCore.ExcelStyle, "Sheet1!A1,Sheet1!B2:C3")
Sheet1!A1,Sheet1!B2:C3
```
"""
function parse_sheet_ref(::Type{ODFStyle}, s::AbstractString)
    length(_split_unquoted(s, ('~', ','))) > 1 && return NonContiguousRange{ODFStyle}(s)
    sheet, x = _odf_parse_area(s)
    sheet === nothing && throw(SheetCoreError("`$s` has no sheet name."))
    x isa CellRef && return SheetCellRef{ODFStyle}(sheet, x)
    x isa CellRange && return SheetCellRange{ODFStyle}(sheet, x)
    x isa ColumnRange && return SheetColumnRange{ODFStyle}(sheet, x)
    return SheetRowRange{ODFStyle}(sheet, x)
end

function parse_sheet_ref(::Type{ExcelStyle}, s::AbstractString)
    is_valid_non_contiguous_sheetcellrange(s) && return NonContiguousRange{ExcelStyle}(s)
    (is_valid_sheet_cellname(s) || is_valid_fixed_sheet_cellname(s)) && return SheetCellRef{ExcelStyle}(s)
    (is_valid_sheet_cellrange(s) || is_valid_fixed_sheet_cellrange(s)) && return SheetCellRange{ExcelStyle}(s)
    (is_valid_sheet_column_range(s) || is_valid_fixed_sheet_column_range(s)) && return SheetColumnRange{ExcelStyle}(s)
    (is_valid_sheet_row_range(s) || is_valid_fixed_sheet_row_range(s)) && return SheetRowRange{ExcelStyle}(s)
    throw(SheetCoreError("`$s` is not a valid sheet reference."))
end

# A sheet name as a formula writes it: quoted when it holds anything but word
# characters, starts with a digit, or could be read as a cell address (`A1`, `R1C1`).
function quoteit(x::AbstractString)
    if occursin(r"[^\w]|\s", x) || (!isempty(x) && isdigit(first(x))) || _is_cell_address_like(x)
        escaped = replace(x, "'" => "''")
        return "'$escaped'"
    else
        return x
    end
end

function unquoteit(x::AbstractString)
    if startswith(x, "'") && endswith(x, "'") && ncodeunits(x) >= 2
        inner = x[2:prevind(x, end)] # First character always ASCII - "'".
        return replace(inner, "''" => "'")
    else
        return x
    end
end

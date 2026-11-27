# Reading zip parts.
#
# `readentry_string` is adapted from XLSX.jl's `_readentry_string` (src/read.jl, XLSX.jl 0.13.4),
# MIT License, Copyright (c) 2018-2026 Felipe Noronha Tavares and other contributors.
# See records/provenance.md. Part of the shared core (records/core-migration.md).

# A part's size from the zip directory, as an `Int` (past `typemax(Int)` no `String` can hold it)
function _entry_size(zr::ZipArchives.ZipReader, i::Integer, name::AbstractString)::Int
    n = ZipArchives.zip_uncompressed_size(zr, i)
    n <= typemax(Int) || throw(ArgumentError("part $(repr(name)) is too large to read ($n bytes)"))
    return Int(n)
end

# The bytes to allocate for a part of `n` bytes before its data comes. A damaged or hostile zip
# directory can claim any size, so no more than deflate can make of the compressed bytes (at
# most 1032 times as many). That bound is never below a real part's size, so a real part is
# allocated once, at its size (a fixed cap made large parts grow by doubling: 3× the memory).
_size_hint(zr::ZipArchives.ZipReader, i::Integer, n::Int) =
    Int(min(n, 1032 * min(ZipArchives.zip_compressed_size(zr, i), typemax(Int) ÷ 2064) + (1 << 16)))

"""
    readentry_string(zr::ZipArchives.ZipReader, name::AbstractString) -> String

Decompress the zip entry `name` directly into a `String`, without the intermediate copy
that `zip_readentry(zr, name, String)` makes (experiment 002: half the allocation and
about 40% faster on large parts). The length and CRC-32 are checked against the zip
directory. Throws `ArgumentError` if the entry is missing or damaged.
"""
function readentry_string(zr::ZipArchives.ZipReader, name::AbstractString)::String
    i = ZipArchives.zip_findlast_entry(zr, name)
    isnothing(i) && throw(ArgumentError("the package has no part named $(repr(name))"))
    n = _entry_size(zr, i, name)
    # `String(take!(buf))` takes over the buffer's memory instead of copying it. The hint is
    # capped, as the size is the zip directory's word: the buffer grows past it as data comes.
    buf = IOBuffer(; sizehint = _size_hint(zr, i, n))
    chunk = Vector{UInt8}(undef, clamp(n, 1, 1 << 16))
    crc = UInt32(0)
    io = ZipArchives.zip_openentry(zr, i)
    try
        while !eof(io)
            nr = readbytes!(io, chunk)
            position(buf) + nr <= n ||
                throw(ArgumentError("part $(repr(name)) is longer than the zip directory says"))
            block = view(chunk, 1:nr)
            crc = ZipArchives.zip_crc32(block, crc)
            write(buf, block)
        end
    finally
        close(io)
    end
    position(buf) == n ||
        throw(ArgumentError("part $(repr(name)) is shorter than the zip directory says"))
    crc == ZipArchives.zip_stored_crc32(zr, i) ||
        throw(ArgumentError("CRC mismatch in part $(repr(name))"))
    return String(take!(buf))
end

"""
    readentry_prefix(stop, zr::ZipArchives.ZipReader, name) -> String

Decompress the zip entry `name` only as far as needed: after each chunk, `stop(data, n)` is
called with the bytes decompressed so far (`data[1:n]`) and returns the length of the
prefix to keep, or `nothing` to go on. The whole part is returned (with its length and CRC
checked, as `readentry_string` does) if `stop` never asks to stop; a prefix can't be
checked against the CRC, which covers the whole part.

New in SheetCore: a reader of one sheet among several in one part (ODS keeps all
sheets in content.xml) can stop inflating after that sheet.
"""
function readentry_prefix(stop, zr::ZipArchives.ZipReader, name::AbstractString)::String
    i = ZipArchives.zip_findlast_entry(zr, name)
    isnothing(i) && throw(ArgumentError("the package has no part named $(repr(name))"))
    n = _entry_size(zr, i, name)
    data = Vector{UInt8}(undef, _size_hint(zr, i, n))      # grown as data comes (see `readentry_string`)
    pos = 0
    crc = UInt32(0)
    chunk = Vector{UInt8}(undef, clamp(n, 1, 1 << 20))
    io = ZipArchives.zip_openentry(zr, i)
    try
        while !eof(io)
            nr = readbytes!(io, chunk)
            pos + nr <= n || throw(ArgumentError("part $(repr(name)) is longer than the zip directory says"))
            block = view(chunk, 1:nr)
            crc = ZipArchives.zip_crc32(block, crc)
            pos + nr > length(data) && resize!(data, min(n, max(2 * length(data), pos + nr)))
            copyto!(data, pos + 1, chunk, 1, nr)
            pos += nr
            keep = stop(data, pos)
            if keep !== nothing
                resize!(data, keep)
                return String(data)
            end
        end
    finally
        close(io)
    end
    pos == n || throw(ArgumentError("part $(repr(name)) is shorter than the zip directory says"))
    crc == ZipArchives.zip_stored_crc32(zr, i) || throw(ArgumentError("CRC mismatch in part $(repr(name))"))
    return String(data)
end

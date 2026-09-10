"""
Values whose types belong to a package rather than to `Main`, for the
serialization round-trip tests.

A notebook evaluates its cells in a module of its own and a script evaluates in
`Main`, and `QuartoTools.serialize` maps one onto the other. A type defined
here is named the same way in both processes, so a value of one shows that the
mapping leaves everything outside `Main` alone.
"""
module SampleValues

export Bitmap, Table, rows

"""
    Table(columns)

A named collection of integer columns, built from `:name => values` pairs.
"""
struct Table
    columns::Vector{Pair{Symbol,Vector{Int}}}
end

Base.show(io::IO, table::Table) =
    print(io, "Table with ", length(table.columns), " columns")

"""
    rows(table::Table) -> Int

How many rows `table` holds.
"""
rows(table::Table) = isempty(table.columns) ? 0 : length(first(table.columns).second)

# A two-by-two image, small enough to write out in full and still a PNG that a
# reader accepts.
const PNG_BYTES = hex2bytes(
    "89504e470d0a1a0a0000000d4948445200000002000000020802000000fd" *
    "d49a730000001049444154789c63f8cf0004ff192014001bf203fdd696f2" *
    "2b0000000049454e44ae426082",
)

"""
    Bitmap()

An image that renders as PNG.
"""
struct Bitmap
    bytes::Vector{UInt8}
end

Bitmap() = Bitmap(PNG_BYTES)

Base.show(io::IO, ::MIME"image/png", bitmap::Bitmap) = write(io, bitmap.bytes)

end

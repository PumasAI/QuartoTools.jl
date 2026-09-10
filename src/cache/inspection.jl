# Reporting on what is stored.
#
# A cache directory is readable by design: one file per result with a TOML
# sidecar beside it. These types read that layout back so a directory can be
# looked over and cut down from the REPL, without anyone having to know how it
# is laid out.

"""
    Entry

One stored result, as found by [`entries`](@ref).

  - `name`, `mod`, `file`: the definition whose call produced the result.
  - `key`: the digest that names the entry.
  - `path`: the file holding the result.
  - `bytes`: what the result and its metadata take up together.
  - `created`: when the result was stored, `nothing` when its metadata is gone.
  - `used`: when the result was last read.
  - `result_type`, `julia`: what was stored, and the Julia that stored it.
"""
struct Entry
    name::String
    mod::String
    file::String
    key::String
    path::String
    bytes::Int
    created::Union{Dates.DateTime,Nothing}
    used::Dates.DateTime
    result_type::String
    julia::String
end

"""
    EntryList

The results [`entries`](@ref) found, which display as a table. A vector of
[`Entry`](@ref) in every other respect.

The table is displayed for this type rather than for a vector of entries, so
that loading this package leaves the display of everything else alone.
"""
struct EntryList <: AbstractVector{Entry}
    found::Vector{Entry}
end

EntryList() = EntryList(Entry[])

Base.size(list::EntryList) = size(list.found)
Base.getindex(list::EntryList, index::Int) = list.found[index]
Base.IndexStyle(::Type{EntryList}) = Base.IndexLinear()

"""
    entries() -> EntryList
    entries(directory) -> EntryList

Every result stored under `directory`, most recently used first, and under
every directory [`managed_directories`](@ref) names when none is given.

```julia
julia> QuartoTools.entries()
2 entries, 1.358 GiB in /home/mike/project/.cache
function        bytes  last used         result
summarise   1.350 GiB  2026-09-09 11:02  NamedTuple{(:total,), Tuple{Float64}}
load_table  8.000 MiB  2026-09-08 16:40  Matrix{Float64}
```
"""
entries(directory::AbstractString) = entries([directory])

function entries(directories::AbstractVector{<:AbstractString} = managed_directories())
    return EntryList([Entry(path, used) for (path, used) in entry_files(directories)])
end

function Entry(path::AbstractString, used::Float64)
    metadata = read_metadata(path)
    return Entry(
        get(metadata, "function", basename(dirname(path))),
        get(metadata, "module", ""),
        get(metadata, "file", ""),
        first(splitext(basename(path))),
        path,
        entry_bytes(path),
        recorded_datetime(get(metadata, "created", nothing)),
        local_datetime(used),
        get(metadata, "result_type", ""),
        get(metadata, "julia", ""),
    )
end

# An entry whose sidecar was lost still holds a result, and the directory it
# sits in still says which function stored it.
function read_metadata(path::AbstractString)
    sidecar = metadata_path(path)
    isfile(sidecar) || return Dict{String,Any}()
    return try
        TOML.parsefile(sidecar)
    catch
        Dict{String,Any}()
    end
end

recorded_datetime(::Nothing) = nothing

function recorded_datetime(recorded::AbstractString)
    return try
        Dates.DateTime(recorded)
    catch
        nothing
    end
end

# A modification time is a unix timestamp, and the sidecar records local time,
# so both are reported in local time.
local_datetime(seconds::Real) = Dates.DateTime(Libc.strftime("%Y-%m-%dT%H:%M:%S", seconds))

"""
    Usage

What one cached function has stored, as found by [`usage`](@ref).
"""
struct Usage
    name::String
    entries::Int
    bytes::Int
    oldest::Dates.DateTime
    newest::Dates.DateTime
end

"""
    UsageList

What [`usage`](@ref) grouped, which displays as a table. A vector of
[`Usage`](@ref) in every other respect, and owned here for the same reason
[`EntryList`](@ref) is.
"""
struct UsageList <: AbstractVector{Usage}
    grouped::Vector{Usage}
end

UsageList() = UsageList(Usage[])

Base.size(list::UsageList) = size(list.grouped)
Base.getindex(list::UsageList, index::Int) = list.grouped[index]
Base.IndexStyle(::Type{UsageList}) = Base.IndexLinear()

"""
    usage() -> Vector{Usage}
    usage(directory) -> Vector{Usage}
    usage(entries::AbstractVector{Entry}) -> Vector{Usage}

What each cached function has stored, largest first, over the same directories
[`entries`](@ref) covers. Use it to find which function is worth pruning before
pruning anything, and pass a filtered list of [`entries`](@ref) to group only
part of what is stored.

```julia
julia> QuartoTools.usage()
function    entries      bytes  oldest use        newest use
summarise         2  1.358 GiB  2026-08-30 09:14  2026-09-09 11:02
load_table        1  8.000 MiB  2026-09-08 16:40  2026-09-08 16:40
```
"""
usage(directory::AbstractString) = usage(entries(directory))

usage(directories::AbstractVector{<:AbstractString} = managed_directories()) =
    usage(entries(directories))

function usage(found::AbstractVector{Entry})
    grouped = Dict{String,Vector{Entry}}()
    for entry in found
        push!(get!(Vector{Entry}, grouped, entry.name), entry)
    end
    summaries = [
        Usage(
            name,
            length(group),
            sum(entry -> entry.bytes, group),
            minimum(entry -> entry.used, group),
            maximum(entry -> entry.used, group),
        ) for (name, group) in grouped
    ]
    sort!(summaries; by = summary -> (-summary.bytes, summary.name))
    return UsageList(summaries)
end

"""
    drop!(entry::Entry) -> Bool

Delete one stored result and its metadata, and return whether there was
anything to delete. Use it to cut out an entry picked from [`entries`](@ref),
where [`prune!`](@ref) sweeps by age, count or size.
"""
function drop!(entry::Entry)
    stored = isfile(entry.path)
    rm(entry.path; force = true)
    rm(metadata_path(entry.path); force = true)
    return stored
end


# Display.

format_time(when::Dates.DateTime) = Dates.format(when, "yyyy-mm-dd HH:MM")

# Entries can come from several directories at once, and then there is no one
# place to name.
function located_in(found::AbstractVector{Entry})
    directories = unique([dirname(dirname(entry.path)) for entry in found])
    return length(directories) == 1 ? string(" in ", first(directories)) : ""
end

"""
    fit_type(type::AbstractString, room::Int) -> String

`type` as the table should print it, given `room` characters to print it in.

A stored result can be a fitted model whose type runs to thousands of
characters, and a column is as wide as its widest cell, so one of those would
set the width of every row. A type that fits is printed whole, since the
element type of a matrix and the field names of a named tuple are what make
the column worth reading. One that does not is named by its outermost
constructor, which is the part a reader is scanning for, and cut where even
that overruns.
"""
function fit_type(type::AbstractString, room::Int)
    length(type) <= room && return String(type)
    collapsed = outer_type(type)
    length(collapsed) <= room && return collapsed
    return clip_text(collapsed, room)
end

function outer_type(type::AbstractString)
    opening = findfirst('{', type)
    opening === nothing && return String(type)
    return string(type[1:prevind(type, opening)], "{…}")
end

function clip_text(text::AbstractString, room::Int)
    room <= 0 && return ""
    room == 1 && return "…"
    return string(first(text, room - 1), "…")
end

# What the result column has to itself, once the columns whose width the
# content settles have taken theirs and the gaps between them are counted.
function room_for_type(io::IO, taken::Integer, columns::Integer)
    width = displaysize(io)[2]
    return max(width - taken - 2 * (columns - 1), 3)
end

Base.show(io::IO, entry::Entry) = print(
    io,
    "Entry(",
    entry.name,
    ", ",
    Base.format_bytes(entry.bytes),
    ", used ",
    format_time(entry.used),
    ")",
)

function Base.show(io::IO, ::MIME"text/plain", found::EntryList)
    if isempty(found)
        print(io, "no stored results")
        return nothing
    end
    total = sum(entry -> entry.bytes, found)
    println(
        io,
        length(found),
        length(found) == 1 ? " entry, " : " entries, ",
        Base.format_bytes(total),
        located_in(found),
    )
    headers = ["function", "bytes", "last used", "result"]
    leading = [
        [entry.name, Base.format_bytes(entry.bytes), format_time(entry.used)] for
        entry in found
    ]
    taken = sum(
        column ->
            maximum(length, String[headers[column]; [row[column] for row in leading]]),
        eachindex(first(leading)),
    )
    room = room_for_type(io, taken, length(headers))
    print_columns(
        io,
        headers,
        [:left, :right, :left, :left],
        [
            String[leading[index]; fit_type(found[index].result_type, room)] for
            index in eachindex(found)
        ],
    )
    return nothing
end

function Base.show(io::IO, usage::Usage)
    print(
        io,
        "Usage(",
        usage.name,
        ", ",
        usage.entries,
        usage.entries == 1 ? " entry, " : " entries, ",
        Base.format_bytes(usage.bytes),
        ")",
    )
    return nothing
end

function Base.show(io::IO, ::MIME"text/plain", found::UsageList)
    if isempty(found)
        print(io, "no stored results")
        return nothing
    end
    print_columns(
        io,
        ["function", "entries", "bytes", "oldest use", "newest use"],
        [:left, :right, :right, :left, :left],
        [
            [
                usage.name,
                string(usage.entries),
                Base.format_bytes(usage.bytes),
                format_time(usage.oldest),
                format_time(usage.newest),
            ] for usage in found
        ],
    )
    return nothing
end

function print_columns(
    io::IO,
    headers::Vector{String},
    alignments::Vector{Symbol},
    rows::Vector{Vector{String}},
)
    widths = [
        maximum(length, String[headers[column]; [row[column] for row in rows]]) for
        column in eachindex(headers)
    ]
    print_row(io, headers, alignments, widths)
    for row in rows
        println(io)
        print_row(io, row, alignments, widths)
    end
    return nothing
end

function print_row(
    io::IO,
    cells::Vector{String},
    alignments::Vector{Symbol},
    widths::Vector{Int},
)
    padded = [
        alignment === :right ? lpad(cell, width) : rpad(cell, width) for
        (cell, alignment, width) in zip(cells, alignments, widths)
    ]
    print(io, rstrip(join(padded, "  ")))
    return nothing
end

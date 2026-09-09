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

# Where results live and how they are keyed.

const DIRECTORY = Ref{Union{String,Nothing}}(nothing)
const ENABLED = Ref(true)

# The file holding each cached definition this process has loaded. A definition
# caches beside its own file, which need not be the working directory of
# whatever loaded it, so the directories to sweep are not knowable from the
# working directory alone.
const SITE_FILES = Set{String}()

"""
    CallSite

Where a cached definition was written. Built by [`@cache`](@ref) at expansion
time, so `digest` covers the source of the definition itself.
"""
struct CallSite
    name::String
    mod::Module
    file::String
    digest::String

    function CallSite(
        name::AbstractString,
        mod::Module,
        file::AbstractString,
        digest::AbstractString,
    )
        push!(SITE_FILES, String(file))
        return new(name, mod, file, digest)
    end
end

"""
    cache_directory() -> String

The `.cache` directory under the working directory, which is where a call
typed into a REPL stores its results. The `QUARTOTOOLS_CACHE_DIRECTORY`
environment variable overrides it, and [`cache_directory!`](@ref) overrides
both.

A definition written to a file caches beside that file instead, so
[`managed_directories`](@ref) is what the reporting and sweeping functions
cover by default.
"""
cache_directory() = configured_directory(pwd())

"""
    managed_directories() -> Vector{String}

Every directory holding results this process could have written: the one
[`cache_directory`](@ref) names, and the one beside each cached definition
loaded so far. [`entries`](@ref), [`usage`](@ref), [`prune!`](@ref) and
[`clear!`](@ref) cover all of them unless given a directory of their own.
"""
function managed_directories()
    primary = cache_directory()
    beside = String[]
    for file in SITE_FILES
        directory = site_directory(file)
        directory == primary && continue
        directory in beside || push!(beside, directory)
    end
    # A set has no order to hand on, and a caller reading this back wants the
    # same list twice.
    return String[primary; sort!(beside)]
end

"""
    cache_directory!(path)

Send cached results to `path` instead of the directory
[`cache_directory`](@ref) would pick. Passing `nothing` restores the default.
"""
function cache_directory!(path::Union{AbstractString,Nothing})
    DIRECTORY[] = path === nothing ? nothing : abspath(path)
    return DIRECTORY[]
end

function configured_directory(fallback::AbstractString)
    override = DIRECTORY[]
    override === nothing || return override
    from_environment = get(ENV, "QUARTOTOOLS_CACHE_DIRECTORY", "")
    isempty(from_environment) || return abspath(from_environment)
    return joinpath(fallback, ".cache")
end

# A definition written to a file caches beside that file, so that moving the
# project moves its cache with it. A definition typed into a REPL has no file
# to sit beside, so it falls back to the working directory.
site_directory(site::CallSite) = site_directory(site.file)

function site_directory(file::AbstractString)
    beside = isfile(file) ? dirname(abspath(file)) : pwd()
    return configured_directory(beside)
end

"""
    is_enabled() -> Bool

Whether cached definitions consult their cache. Set at load time from the
`QUARTOTOOLS_CACHE_DISABLE` environment variable, and changed by [`enable!`](@ref)
and [`disable!`](@ref).
"""
is_enabled() = ENABLED[]

"""
    enable!()

Consult the cache on calls to cached definitions.
"""
enable!() = (ENABLED[] = true)

"""
    disable!()

Run every call to a cached definition, storing nothing and reading nothing.
"""
disable!() = (ENABLED[] = false)

"""
    clear!()
    clear!(directory)

Delete stored results, under `directory` when one is given and under every
directory [`managed_directories`](@ref) names otherwise. Only entries that
this package writes are removed, so a directory holding anything else keeps
it.
"""
clear!() = clear!(managed_directories())

clear!(directory::AbstractString) = clear!([directory])

function clear!(directories::AbstractVector{<:AbstractString})
    for directory in directories
        isdir(directory) || continue
        for entry in readdir(directory)
            path = joinpath(directory, entry)
            holds_only_entries(path) && rm(path; recursive = true)
        end
    end
    return nothing
end

"""
    prune!(; directory = nothing, older_than = nothing, keep = nothing,
           max_size = nothing, name = nothing)

Delete stored entries that are no longer worth keeping, and return how many
went.

An entry's modification time is when it was last read, so `older_than` drops
what has gone unused for that long. `keep` drops everything but that many most
recently used entries, whatever their age. `max_size` drops the least recently
used until the entries left fit in that many bytes, and drops an entry that
overruns the budget on its own.

Every criterion given applies, so an entry that any of them condemns goes, and
a call naming none of the three drops what has gone unused for thirty days.
Asking to keep five hundred entries therefore keeps five hundred, however old.

`name` confines the sweep to the results of one function, and `directory` to
one directory rather than every directory [`managed_directories`](@ref) names.
Reach for [`usage`](@ref) to see what is worth sweeping, and [`drop!`](@ref)
to cut out a single entry.
"""
function prune!(;
    directory::Union{AbstractString,Nothing} = nothing,
    older_than::Union{Dates.Period,Nothing} = nothing,
    keep::Union{Integer,Nothing} = nothing,
    max_size::Union{Integer,Nothing} = nothing,
    name::Union{AbstractString,Nothing} = nothing,
)
    age_limit = if older_than !== nothing
        older_than
    elseif keep === nothing && max_size === nothing
        Dates.Day(30)
    else
        nothing
    end

    found = entry_files(directory === nothing ? managed_directories() : [directory])
    name === nothing || filter!(pair -> stores_function(first(pair), name), found)

    doomed = Set{String}()
    if age_limit !== nothing
        span = unused_span(age_limit)
        now = time()
        for (path, used) in found
            unused_for(now, used) >= span && push!(doomed, path)
        end
    end
    if keep !== nothing
        for (path, _) in Iterators.drop(found, max(keep, 0))
            push!(doomed, path)
        end
    end
    if max_size !== nothing
        spent = 0
        for (path, _) in found
            spent += entry_bytes(path)
            spent > max_size && push!(doomed, path)
        end
    end

    for path in doomed
        rm(path; force = true)
        rm(metadata_path(path); force = true)
    end
    return length(doomed)
end

"""
    unused_span(older_than::Dates.Period) -> Float64

How many seconds `older_than` stands for, counted from now.

A month and a year have no fixed length, so the answer comes from calendar
arithmetic rather than from a count of milliseconds, and `Dates.Month(1)` is
as usable a cutoff as `Dates.Day(30)`.
"""
function unused_span(older_than::Dates.Period)
    anchor = Dates.unix2datetime(time())
    return Dates.datetime2unix(anchor) - Dates.datetime2unix(anchor - older_than)
end

"""
    unused_for(now::Float64, used::Float64) -> Float64

How long an entry last used at `used` has gone unused, in seconds.

A file is stamped at a finer resolution than `time()` reports, NTFS to a
hundred nanoseconds against a clock Windows runs to about a millisecond, so an
entry stored moments ago carries a modification time a fraction ahead of the
reading taken after it. An entry cannot be used in the future, so that reads
as no age rather than a negative one, and a sweep of no age at all condemns it
the way it condemns the rest.
"""
unused_for(now::Float64, used::Float64) = max(now - used, 0.0)

# Every result stored under the given directories, most recently used first.
# One pass serves reporting and sweeping alike.
function entry_files(directories::AbstractVector{<:AbstractString})
    found = Tuple{String,Float64}[]
    for directory in directories
        isdir(directory) || continue
        for (root, _, files) in walkdir(directory)
            for file in files
                endswith(file, ".jls") || continue
                path = joinpath(root, file)
                push!(found, (path, safe_mtime(path)))
            end
        end
    end
    sort!(found; by = last, rev = true)
    return found
end

entry_files(directory::AbstractString) = entry_files([directory])

# The results of one function share a directory named after it.
stores_function(path::AbstractString, name::AbstractString) =
    basename(dirname(path)) == path_component(name)

# What an entry occupies is its result and the metadata describing it.
entry_bytes(path::AbstractString) = safe_filesize(path) + safe_filesize(metadata_path(path))

function safe_filesize(path::AbstractString)
    return try
        isfile(path) ? filesize(path) : 0
    catch
        0
    end
end

# The suffix a result is written under before it is moved into place. A process
# killed between the two leaves the partial file behind, and it is one of ours
# to remove rather than a reason to leave a directory standing.
const PARTIAL_SUFFIX = ".writing"

is_entry_file(path) =
    endswith(path, ".jls") ||
    endswith(path, ".toml") ||
    endswith(path, ".jls$(PARTIAL_SUFFIX)")

function holds_only_entries(path)
    isfile(path) && return is_entry_file(path)
    isdir(path) || return false
    for (root, _, files) in walkdir(path)
        all(file -> is_entry_file(joinpath(root, file)), files) || return false
    end
    return true
end


# Reading and writing a result.
#
# Results go through this package's own `serialize` and `deserialize`, which
# map the module a notebook evaluates its cells in onto the one a script uses,
# so a notebook and a script read each other's entries. Those two apply
# `deconstruct` and `reconstruct` on the way past.

"""
    store_result(path, value)

Write `value` to `path`, through a temporary file so that an interrupted write
never leaves a half-written entry for the next process to read.
"""
function store_result(path::AbstractString, @nospecialize(value))
    mkpath(dirname(path))
    partial = "$(path)$(PARTIAL_SUFFIX)"
    try
        serialize(partial, value)
        mv(partial, path; force = true)
    catch
        rm(partial; force = true)
        rethrow()
    end
    return path
end

"""
    load_result(path)

Read back a value written by [`store_result`](@ref).

Throws when the file is not a serialized stream, and when the value it holds
would bind to code that has moved on since it was written. `Serialization`
reads a foreign file as whatever its bytes happen to say rather than refusing
it, so a file holding anything else would otherwise come back as a result. A
caller that cannot use a stored result runs the call instead, so refusing here
is what keeps a wrong value from reaching one.
"""
function load_result(path::AbstractString)
    return open(path, "r") do io
        opening = read(io, length(SERIALIZATION_MAGIC))
        opening == SERIALIZATION_MAGIC || error("$(path) is not a serialized stream.")
        seekstart(io)
        value = deserialize(io)
        check_closures(path, value)
        return value
    end
end

# What `Serialization` opens a stream with. The byte after it is the format
# version, which every Julia release is free to move, so the mark alone is what
# says a file is a serialized stream.
const SERIALIZATION_MAGIC = codeunits("7JL")

"""
    closure_digest(value) -> String

A digest of the code behind the closures a value's type names, empty for a
value naming none.

`Serialization` records a closure by the name lowering gave it, and a session
that redefines the code around it can hand that name to a different closure.
Reading such an entry binds the value to code it was never written from, and
the failure surfaces wherever the value is next called. Digesting the code when
the value is stored, and again when it is read, is what catches that.
"""
function closure_digest(@nospecialize(value))
    found = closure_types(typeof(value))
    isempty(found) && return ""
    parts = Vector{UInt8}[]
    for T in found, m in callable_methods(T)
        push!(parts, content_hash(method_statements(m)))
    end
    sort!(parts)
    context = SHA.SHA2_256_CTX()
    for part in parts
        SHA.update!(context, part)
    end
    return bytes2hex(SHA.digest!(context))
end

# A closure a value holds appears in the value's own type, so the types are
# where to look rather than the data, however much of it there is.
function closure_types(@nospecialize(T), found = Any[], depth::Int = 0)
    depth > 16 && return found
    T isa DataType || return found
    if is_generated_name(T.name.name) && !(T in found)
        push!(found, T)
    end
    for parameter in T.parameters
        closure_types(parameter, found, depth + 1)
    end
    return found
end

"""
    drop_entry(path)

Remove an entry and its metadata, for a file that reading has already refused.
Leaving it costs a failed read on every call, and the result that runs in its
place is written where it stood.
"""
function drop_entry(path::AbstractString)
    try
        rm(path; force = true)
        rm(metadata_path(path); force = true)
    catch error
        @warn "Cannot remove an entry that could not be read." path error maxlog = 1
    end
    return nothing
end

function check_closures(path::AbstractString, @nospecialize(value))
    recorded = get(read_metadata(path), "closures", nothing)
    recorded === nothing && return nothing
    found = closure_digest(value)
    found == recorded ||
        error("the closures $(path) names hold different code than when it was written.")
    return nothing
end


# Keying.

"""
    cache_key(site, public, implementation, args, kws) -> String

The digest that identifies one cached result. Every input that can change the
result takes part: the version of Julia, the manifest of the active project,
the source of the definition, every tracked definition it depends on, and the
arguments.
"""
function cache_key(
    site::CallSite,
    @nospecialize(public),
    @nospecialize(implementation),
    args::Tuple,
    kws::NamedTuple,
)
    serializer = ContentHashSerializer()
    Serialization.serialize(serializer, string(VERSION))
    write(serializer.io, project_digest())
    Serialization.serialize(serializer, site.digest)
    Serialization.serialize(serializer, (module_name(site.mod), site.name))
    write(
        serializer.io,
        dependency_digest(implementation, Tuple{map(Core.Typeof, args)...}),
    )
    Serialization.serialize(serializer, dependencies(public))
    Serialization.serialize(serializer, map(deconstruct, args))
    Serialization.serialize(serializer, map(deconstruct, kws))
    return bytes2hex(SHA.digest!(serializer.io.ctx))
end

const PROJECT_DIGESTS = Dict{String,Tuple{Float64,Vector{UInt8}}}()

"""
    project_digest() -> Vector{UInt8}

Digest the active project and its manifest. Code from a package that the
manifest pins cannot change without this digest changing, which is what lets
the dependency walk stop at the boundary of tracked code.
"""
function project_digest()
    project = Base.active_project()
    project === nothing && return UInt8[]
    files = [project, joinpath(dirname(project), "Manifest.toml")]
    stamp = sum(safe_mtime, files)
    return lock(ANALYSIS_LOCK) do
        cached = get(PROJECT_DIGESTS, project, nothing)
        if cached !== nothing && cached[1] == stamp
            return cached[2]
        end
        context = SHA.SHA2_256_CTX()
        for file in files
            isfile(file) || continue
            SHA.update!(context, read(file))
        end
        digest = SHA.digest!(context)
        PROJECT_DIGESTS[project] = (stamp, digest)
        return digest
    end
end

function safe_mtime(path)
    return try
        mtime(path)
    catch
        0.0
    end
end


# Reading and writing.

entry_path(site::CallSite, key::AbstractString) =
    joinpath(site_directory(site), path_component(site.name), "$(key).jls")

# A definition can be named `+`, and that is not a directory name. Rewriting it
# alone would put `+` and `*` in one directory, and a sweep confined to either
# name would take the other's results with it, so a name that had to be
# rewritten carries a digest of what it was.
function path_component(name::AbstractString)
    safe = replace(name, r"[^A-Za-z0-9_]" => "_")
    isempty(safe) && return "function"
    safe == name && return safe
    return string(safe, "-", bytes2hex(SHA.sha256(name))[1:8])
end

function write_metadata(
    path::AbstractString,
    site::CallSite,
    @nospecialize(result),
    args::Tuple,
    kws::NamedTuple,
)
    metadata = Dict{String,Any}(
        "function" => site.name,
        "module" => string(site.mod),
        "file" => site.file,
        "julia" => string(VERSION),
        "created" => string(Dates.now()),
        "result_type" => string(typeof(result)),
        "closures" => closure_digest(result),
    )
    isempty(args) || (metadata["argument_types"] = [string(typeof(a)) for a in args])
    isempty(kws) || (
        metadata["keyword_types"] =
            Dict(String(k) => string(typeof(v)) for (k, v) in pairs(kws))
    )
    open(io -> TOML.print(io, metadata; sorted = true), metadata_path(path), "w")
    return nothing
end

metadata_path(path::AbstractString) = "$(first(splitext(path))).toml"

# The modification time of the entry is its last use, which is what a future
# pass over the directory needs to decide what to drop. Recording it costs one
# `utime` call rather than a parse and a rewrite of the metadata.
function record_use(path::AbstractString)
    try
        touch(path)
    catch
        # A read-only cache directory is a legitimate way to ship results.
    end
    return nothing
end


# The call itself.

"""
    run_cached(site, public, implementation, args, kws)

Return the stored result for this call, or run `implementation` and store what
it returns. Any failure to key, read or write falls back to running the call:
a wrong result is never returned in place of a slow one. An interrupt is not
such a failure, and stops the call where it was.
"""
function run_cached(
    site::CallSite,
    @nospecialize(public),
    @nospecialize(implementation),
    args::Tuple,
    kws::NamedTuple,
)
    (is_enabled() && cacheable(public)) || return implementation(args...; kws...)

    # A call that cannot be keyed, read or stored hits the same failure on every
    # pass through a loop, and one warning says what the ten thousandth would.
    key = try
        cache_key(site, public, implementation, args, kws)
    catch error
        error isa InterruptException && rethrow()
        @warn "Cannot key this call, running it uncached." site.name mod =
            module_name(site.mod) error maxlog = 1
        return implementation(args...; kws...)
    end

    path = entry_path(site, key)
    if isfile(path)
        try
            result = load_result(path)
            record_use(path)
            return result
        catch error
            error isa InterruptException && rethrow()
            @warn "Cannot read a stored result, running the call again." path error maxlog =
                1
            # A file that cannot be read costs a failed read on every call, and
            # the result about to run takes its place.
            drop_entry(path)
        end
    end

    result = implementation(args...; kws...)
    try
        store_result(path, result)
        write_metadata(path, site, result, args, kws)
    catch error
        error isa InterruptException && rethrow()
        @warn "Cannot store this result." path error maxlog = 1
    end
    return result
end

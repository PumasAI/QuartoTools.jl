# Which modules hold code whose *content* takes part in cache keys.
#
# Code from a registry package or from the Julia installation itself cannot
# change without the manifest or `VERSION` changing, and both of those are part
# of every cache key already. Hashing it would cost a great deal and buy
# nothing. Code that can change under a fixed manifest, on the other hand, has
# to be hashed: scripts, notebooks, `Main`, and packages checked out for
# development.

# A cached call can be made from any task, and the memos that make the walk
# cheap are one per process: the tracking decisions below, the analyses and
# resolutions in `edges.jl`, and the project digests in `store.jl`. Every entry
# point that reads or writes one holds this, which serialises the walk itself.
# Running one is what a cache hit exists to avoid, so two tasks waiting on each
# other here cost less than the walk either of them would otherwise repeat.
const ANALYSIS_LOCK = ReentrantLock()

const TRACK_OVERRIDES = IdDict{Module,Bool}()
const TRACK_RESULTS = IdDict{Module,Bool}()

"""
    is_tracked(mod::Module) -> Bool

Whether the content of code defined in `mod` participates in cache keys.

Defaults to `true` for `Main`, for modules created at runtime, for the types
`Serialization` rebuilds when reading a stored value, and for packages whose
source lies outside the read-only parts of the depot. Defaults to `false` for
`Base`, `Core`, the standard libraries, and packages installed by the package
manager. Use [`track!`](@ref) and [`untrack!`](@ref) to override.
"""
function is_tracked(mod::Module)
    return lock(ANALYSIS_LOCK) do
        # An override on a submodule wins over one on its parent, so that a
        # single vendored submodule can be excluded without excluding
        # everything around it.
        scope = mod
        while true
            override = get(TRACK_OVERRIDES, scope, nothing)
            override === nothing || return override
            parent = parentmodule(scope)
            parent === scope && break
            scope = parent
        end
        holds_rebuilt_types(mod) && return true
        root = Base.moduleroot(mod)
        return get!(() -> tracked_by_default(root), TRACK_RESULTS, root)
    end
end

# `Serialization` cannot look a gensym-named type up by name, so reading a
# stored closure rebuilds its type under a module of its own. Judging that
# module by its root would call it a standard library and leave the closure out
# of the walk, which is how a restored value came to key differently from the
# live one it was stored from. The code such a type carries came from whoever
# stored it, and each of its methods keeps the module it was written in for the
# per-method decision.
function holds_rebuilt_types(mod::Module)
    REBUILT_TYPES === nothing && return false
    scope = mod
    while true
        scope === REBUILT_TYPES && return true
        parent = parentmodule(scope)
        parent === scope && return false
        scope = parent
    end
end

const REBUILT_TYPES = if isdefined(Serialization, :__deserialized_types__)
    getfield(Serialization, :__deserialized_types__)
else
    nothing
end

"""
    track!(mod::Module)

Include the content of code defined in `mod` in cache keys, overriding the
default policy described by [`is_tracked`](@ref).
"""
function track!(mod::Module)
    lock(ANALYSIS_LOCK) do
        TRACK_OVERRIDES[mod] = true
        forget_analysis!()
    end
    return mod
end

"""
    untrack!(mod::Module)

Exclude the content of code defined in `mod` from cache keys, overriding the
default policy described by [`is_tracked`](@ref). Only do this for code that
cannot change while the manifest stays fixed.
"""
function untrack!(mod::Module)
    lock(ANALYSIS_LOCK) do
        TRACK_OVERRIDES[mod] = false
        forget_analysis!()
    end
    return mod
end

"""
    reset_tracking!()

Drop every [`track!`](@ref) and [`untrack!`](@ref) override.
"""
function reset_tracking!()
    lock(ANALYSIS_LOCK) do
        empty!(TRACK_OVERRIDES)
        empty!(TRACK_RESULTS)
        forget_analysis!()
    end
    return nothing
end

function tracked_by_default(root::Module)
    (root === Base || root === Core) && return false
    # Our own code takes part in no computation being cached.
    root === (@__MODULE__) && return false
    root === Main && return true
    path = pathof(root)
    if path === nothing
        # No source to change. A module carrying a package identity is built
        # into the Julia installation, `Base.Compiler` being one; a module
        # carrying none was built at runtime, which a notebook or a test module
        # is, so track that.
        return package_uuid(root) === nothing
    end
    path = normpath(path)
    startswith(path, normpath(Sys.STDLIB)) && return false
    startswith(path, normpath(Sys.BINDIR)) && return false
    for depot in DEPOT_PATH
        startswith(path, normpath(joinpath(depot, "packages"))) && return false
        startswith(path, normpath(joinpath(depot, "juliaup"))) && return false
    end
    return in_active_project(package_uuid(root))
end

"""
    in_active_project(uuid) -> Bool

Whether a package belongs to the environment the cached code runs in.

A package the active project does not name comes from elsewhere on the load
path, a development tool in a shared environment being the usual case. It can
reach cached code only by replacing something that code uses, `stdout` being
how that happens, so its own state decides nothing about a result. A module
with no package identity, and any package at all when no manifest says
otherwise, belongs to the project.
"""
function in_active_project(uuid::Union{Base.UUID,Nothing})
    uuid === nothing && return true
    uuids = active_project_uuids()
    uuids === nothing && return true
    return uuid in uuids
end

const PROJECT_UUIDS = Dict{String,Tuple{Float64,Union{Set{Base.UUID},Nothing}}}()

# Read afresh whenever either file is touched, so that adding a dependency
# mid-session moves the boundary with it.
function active_project_uuids()
    project = Base.active_project()
    project === nothing && return nothing
    manifest = joinpath(dirname(project), "Manifest.toml")
    stamp = safe_mtime(project) + safe_mtime(manifest)
    return lock(ANALYSIS_LOCK) do
        cached = get(PROJECT_UUIDS, project, nothing)
        cached === nothing || cached[1] == stamp || (cached = nothing)
        if cached === nothing
            cached = (stamp, read_project_uuids(project, manifest))
            PROJECT_UUIDS[project] = cached
        end
        return cached[2]
    end
end

function read_project_uuids(project::AbstractString, manifest::AbstractString)
    isfile(manifest) || return nothing
    uuids = Set{Base.UUID}()
    try
        # The project's own package is not in its manifest, and code cached
        # from a package being developed runs under that identity.
        own = get(TOML.parsefile(project), "uuid", nothing)
        own === nothing || push!(uuids, Base.UUID(own))
        collect_manifest_uuids!(uuids, TOML.parsefile(manifest))
    catch
        # A manifest that cannot be read says nothing about what belongs, so
        # the boundary falls back to the paths alone.
        return nothing
    end
    return uuids
end

# A manifest written before format 2 lists its packages at the top level, and
# one written since lists them under `deps`.
function collect_manifest_uuids!(uuids::Set{Base.UUID}, manifest::AbstractDict)
    packages = get(manifest, "deps", manifest)
    packages isa AbstractDict || return uuids
    for (_, entries) in packages
        entries isa AbstractVector || continue
        for entry in entries
            entry isa AbstractDict || continue
            uuid = get(entry, "uuid", nothing)
            uuid === nothing || push!(uuids, Base.UUID(uuid))
        end
    end
    return uuids
end

function package_uuid(root::Module)
    return try
        Base.PkgId(root).uuid
    catch
        nothing
    end
end

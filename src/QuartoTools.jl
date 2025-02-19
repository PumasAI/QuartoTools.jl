module QuartoTools

# Imports.

import Dates
import Pkg
import Preferences
import REPL
import Requires
import SHA
import Serialization
import TOML


# Exports.

export @cache
export @nc_cmd
export deserialize
export serialize


# Serialization implementation.

struct QuartoSerializer <: Serialization.AbstractSerializer
    __serializer__::Serialization.Serializer

    function QuartoSerializer(serializer::Serialization.Serializer)
        return new(serializer)
    end
end

function Base.setproperty!(q::QuartoSerializer, name::Symbol, value)
    if name === :__serializer__
        return setfield!(q, :__serializer__, value)
    else
        return Base.setproperty!(getfield(q, :__serializer__), name, value)
    end
end

function Base.getproperty(q::QuartoSerializer, name::Symbol)
    if name === :__serializer__
        return getfield(q, :__serializer__)
    else
        return getproperty(getfield(q, :__serializer__), name)
    end
end

function Serialization.serialize(q::QuartoSerializer, m::Module)
    if fullname(m) === (:Main, :Notebook)
        m = Main
    end
    return Serialization.serialize(q.__serializer__, m)
end

"""
    serialize(s::IO, x)
    serialize(filename::AbstractString, x)

Serialize `x` to the given IO stream or file using Julia's built-in
serialization while correctly handling differences in "root" evaluation module
between the REPL and Quarto notebooks.
"""
function serialize end

function serialize(s::IO, x)
    x = deconstruct(x)
    if is_quarto_notebook()
        q = QuartoSerializer(Serialization.Serializer(s))
        return Serialization.serialize(q, x)
    else
        @debug "Falling back to default serialization. Not a Quarto notebook."
        Serialization.serialize(s, x)
    end
end
serialize(filename::AbstractString, x) = open(io -> serialize(io, x), filename, "w")

function Serialization.deserialize_module(q::QuartoSerializer)
    real_module = Serialization.deserialize_module(q.__serializer__)
    return real_module === Main ? Main.Notebook : real_module
end

"""
    deserialize(s::IO)
    deserialize(filename::AbstractString)

Deserialize a value from the given IO stream or file using Julia's built-in
serialization while correctly handling differences in "root" evaluation module
between the REPL and Quarto notebooks.
"""
function deserialize end

function deserialize(s::IO)
    result = if is_quarto_notebook()
        q = QuartoSerializer(Serialization.Serializer(s))
        Serialization.deserialize(q)
    else
        @debug "Falling back to default deserialization. Not a Quarto notebook."
        Serialization.deserialize(s)
    end
    return reconstruct(result)
end
deserialize(filename::AbstractString) = open(deserialize, filename)


# Content Hashing.

"""
    content_hash(object)

Compute a content hash for the given object. This should result in hashes that
match between different instances of identical objects. Used for cache keys.
"""
function content_hash(@nospecialize(object))
    serializer = ContentHashSerializer()
    Serialization.serialize(serializer, object)
    return SHA.digest!(serializer.io.ctx)
end

struct HashContext <: IO
    ctx::SHA.SHA1_CTX
end

function Base.unsafe_write(io::HashContext, ptr::Ptr{UInt8}, nb::UInt)
    for _ = 1:nb
        SHA.update!(io.ctx, (unsafe_load(ptr),))
        ptr += 1
    end
    return nb
end
Base.write(io::HashContext, u::UInt8) = SHA.update!(io.ctx, (u,))

struct ContentHashSerializer <: Serialization.AbstractSerializer
    io::HashContext
    __serializer__::Serialization.Serializer

    function ContentHashSerializer()
        serializer = Serialization.Serializer(IOBuffer())
        io = HashContext(SHA.SHA1_CTX())
        return new(io, serializer)
    end
end

function Base.setproperty!(q::ContentHashSerializer, name::Symbol, value)
    if name in (:io, :__serializer__)
        return setfield!(q, name, value)
    else
        return Base.setproperty!(getfield(q, :__serializer__), name, value)
    end
end

function Base.getproperty(q::ContentHashSerializer, name::Symbol)
    if name in (:io, :__serializer__)
        return getfield(q, name)
    else
        return getproperty(getfield(q, :__serializer__), name)
    end
end

function Serialization.serialize(cs::ContentHashSerializer, f::Function)
    name = String(nameof(f))
    if startswith(name, "#")
        for each in code_lowered(f)
            Serialization.serialize(cs, each.code)
        end
    else
        invoke(
            Serialization.serialize,
            Tuple{Serialization.AbstractSerializer,Function},
            cs,
            f,
        )
    end
end

Serialization.serialize(::ContentHashSerializer, ::Core.LineInfoNode) = nothing
Serialization.serialize(::ContentHashSerializer, ::LineNumberNode) = nothing

function Serialization.serialize(cs::ContentHashSerializer, tn::Core.TypeName)
    if !Serialization.serialize_cycle(cs, tn)
        if startswith(String(tn.name), '#')
            obj = getfield(tn.module, tn.name)
            if isdefined(obj, :instance)
                for ci in code_lowered(obj.instance)
                    Serialization.serialize(cs, ci.code)
                end
                return nothing
            end
        else
            Serialization.writetag(cs.io, Serialization.TYPENAME_TAG)
            Serialization.write(cs.io, Serialization.object_number(cs, tn))
            Serialization.serialize_typename(cs, tn)
        end
    end
    return nothing
end

function Serialization.serialize(cs::ContentHashSerializer, s::Symbol)
    str = String(s)
    stripped_s = contains(str, '#') ? Symbol(filter(!isdigit, str)) : s
    return invoke(
        Serialization.serialize,
        Tuple{Serialization.AbstractSerializer,Symbol},
        cs,
        stripped_s,
    )
end


# Caching.

struct Cached{F}
    f::F
    mod::Module
    file::String
    project::String
    expr::Expr
end

"""
    deconstruct(value::T) -> S

An extension function for turning values of type `T` into a type `S` such that
they can be serialized properly.
"""
deconstruct(value) = value

"""
    reconstruct(value::S) -> T

An extension function for turning values of type `S` back into a type `T` after
they have been deserialized.
"""
reconstruct(value) = value

"""
    cacheable(f) -> Bool

Determine if a function is cacheable. By default all functions are cacheable.
Use this function to override that behaviour, for example to make `Base.read`
uncacheable:

```julia
QuartoTools.cacheable(::typeof(Base.read)) = false
```
"""
cacheable(f) = true

@inline function (cache::Cached)(args...; kws...)
    cacheable(cache.f) || error("Cannot cache function call: $(cache.expr)")

    key = _cache_key(cache, args, kws)
    cache_file = joinpath(_cache_dir(cache), key)

    if safe_isfile(cache_file)
        @debug "Loading cached result from" cache_file
        try
            result_from_file = QuartoTools.deserialize(cache_file)
            last_used = Dates.now()
            _update_metadata!(cache_file, last_used)

            return result_from_file
        catch error
            @warn(
                "Failed to load cached result, re-running.",
                error,
                stacktrace = stacktrace(),
                cache_file,
                cache,
                args,
                kws,
            )
        end
    end

    result = cache.f(args...; kws...)
    created = Dates.now()

    mkpath(dirname(cache_file))
    try
        QuartoTools.serialize(cache_file, result)
        _create_metadata(cache_file, cache, created, args, kws, result)
    catch error
        @warn(
            "Failed to save cached result.",
            error,
            stacktrace = stacktrace(),
            cache_file,
            cache,
            args,
            kws,
        )
    end

    return result
end

function _create_metadata(cache_file, cache, created, args, kws, result)
    metadata = _metadata(cache, created, args, kws, result)
    open("$cache_file.toml", "w") do io
        TOML.print(io, metadata; sorted = true)
    end
end

function _update_metadata!(cache_file, last_used)
    metadata = TOML.parsefile("$cache_file.toml")
    metadata["last_used"] = string(last_used)
    open("$cache_file.toml", "w") do io
        TOML.print(io, metadata; sorted = true)
    end
end

function _metadata(cache, created, args, kws, result)
    args_str = string.(typeof.(collect(args)))
    kws_str = Dict([string(k) => string(typeof(v)) for (k, v) in pairs(kws)])
    metadata = Dict{String,Any}(
        "created" => string(created),
        "last_used" => string(created),
        "function" => string(cache.f),
        "module" => string(cache.mod),
        "project" => cache.project,
        "result_type" => string.(typeof(result)),
    )
    isempty(args_str) || (metadata["arg_types"] = args_str)
    isempty(kws_str) || (metadata["kw_types"] = kws_str)
    return metadata
end

function _cache_dir(c::Cached)
    dir = safe_isfile(c.file) ? dirname(c.file) : pwd()
    return normpath(joinpath(dir, ".cache"))
end

function _cache_key(c::Cached, args, kws)
    payload = (;
        version = VERSION,
        func = c.f,
        method = code_lowered(c.f, typeof(args)),
        mod = c.mod,
        file = safe_isfile(c.file) ? c.file : "",
        project = read(c.project),
        args = args,
        kws = kws,
    )
    return bytes2hex(content_hash(payload))
end

"""
    @cache func(args...; kws...)

Cache the result of a function call with the given arguments and keyword
arguments.

The caching key is based on:

  - The full `VERSION` of Julia.
  - The `Function` being called.
  - The `Module` in which the function is called.
  - The file in which the function is called.
  - The active `Project.toml`.
  - The argument values and keyword argument values passed to the function.

The cache is stored in a `.cache` directory in the same directory as the file in
which the function is called. Deleting this directory will clear the cache.
"""
macro cache(expr)
    if Meta.isexpr(expr, :call)
        # Swap out the function call with a cached version of it that overloads
        # calls with a check for cached results for the specific argument
        # combination.
        expr.args[1] = Expr(
            :call,
            Cached,
            expr.args[1],
            __module__,
            String(__source__.file),
            Expr(:call, Base.active_project),
            QuoteNode(deepcopy(expr)),
        )
        return esc(expr)
    else
        # TODO: maybe expand the use of `@cache` to other expressions?
        error("`@cache` is only valid on a function call expression.")
    end
end

active_repl_backend_available() =
    isdefined(Base, :active_repl_backend) && Base.active_repl_backend !== nothing

# Based on `__init__` code from `Revise.jl`.
function _init_transform_ast_cache()
    pushfirst!(REPL.repl_ast_transforms, _transform_ast_cache)
    if active_repl_backend_available()
        push!(Base.active_repl_backend.ast_transforms, _transform_ast_cache)
    else
        t = @async begin
            iter = 0
            while !active_repl_backend_available() && iter < 20
                sleep(0.05)
                iter += 1
            end
            if active_repl_backend_available()
                push!(Base.active_repl_backend.ast_transforms, _transform_ast_cache)
            end
        end
        isdefined(Base, :errormonitor) && Base.errormonitor(t)
    end
end

function walk(f, ex::Expr; before = Returns(true), after = Returns(true))
    if before(ex)
        result = f(ex)
        if after(result)
            rebuilt = Expr(result.head)
            for arg in result.args
                push!(rebuilt.args, walk(f, arg; before, after))
            end
            return rebuilt
        else
            return result
        end
    else
        return ex
    end
end
function walk(f, other; before = Returns(true), after = Returns(true))
    if before(other)
        return f(other)
    else
        other
    end
end

function _transform_ast_cache(expr::Expr)
    enabled, ignored = _caching_options()
    if enabled
        ignored = Set(Symbol.(ignored))
        function before(ex)
            if Meta.isexpr(ex, (:function, :call, :macrocall, :struct, :module))
                return false
            else
                return true
            end
        end
        function after(ex)
            if Meta.isexpr(ex, (:function, :call, :macrocall, :struct, :module, :(=)))
                return false
            else
                return true
            end
        end
        lnn = Ref(LineNumberNode(0, nothing))
        return walk(expr; before, after) do ex
            if isa(ex, LineNumberNode)
                lnn[] = ex
            else
                if Meta.isexpr(ex, :(=), 2)
                    vars = ex.args[1]
                    if no_ignored_vars(vars, ignored)
                        callexpr = ex.args[2]
                        if Meta.isexpr(callexpr, :call) && isa(lnn[].file, Symbol)
                            newfunc = Expr(
                                :call,
                                Cached,
                                callexpr.args[1],
                                Expr(:macrocall, Symbol("@__MODULE__"), lnn[]),
                                String(lnn[].file),
                                Expr(:call, Base.active_project),
                                QuoteNode(deepcopy(ex)),
                            )
                            return Expr(
                                ex.head,
                                ex.args[1],
                                Expr(callexpr.head, newfunc, callexpr.args[2:end]...),
                            )
                        end
                    end
                end
            end
            return ex
        end
    else
        return expr
    end
end
_transform_ast_cache(other) = other

function no_ignored_vars(ex::Expr, ignored)
    if Meta.isexpr(ex, :macrocall)
        return false
    elseif Meta.isexpr(ex, (:tuple, :parameters))
        for each in ex.args
            result = no_ignored_vars(each, ignored)
            if !result
                return false
            end
        end
    end
    return true
end
no_ignored_vars(s::Symbol, ignored) = !(s in ignored)
no_ignored_vars(other, ignored) = false # any other LHS should be ignored.

"""
    nc`variable_name` = func(args...)

Mark the given variable as non-cachable. This means that assigning to this
variable from a function call will not cache the function call. This is
equivalent to using the `julia.cache.ignored` array in cell options or notebook
frontmatter in a Quarto notebook.
"""
macro nc_cmd(s)
    return esc(Symbol(s))
end

const QT_CACHE = "QUARTOTOOLS_CACHE"

"""
    toggle_cache()

Switch caching of function calls in the REPL on/off.
"""
toggle_cache() = ENV[QT_CACHE] = !(parse(Bool, get(ENV, QT_CACHE, "false")))

function _caching_options(::Any)
    cache = get(ENV, QT_CACHE, nothing)
    cache =
        isnothing(cache) ? Preferences.@load_preference("cache", nothing) :
        parse(Bool, cache)

    return cache === true, String[]
end
_caching_options() = _caching_options(nothing)

_recursive_merge(x::AbstractDict...) = merge(_recursive_merge, x...)
_recursive_merge(x...) = x[end]

function __caching_options(notebook_options, cell_options)
    notebook_julia = __notebook_caching_options(notebook_options)
    D = Dict
    cell_julia = get(D, cell_options, "julia")
    julia = _recursive_merge(notebook_julia, cell_julia)
    cache = get(D, julia, "cache")
    enabled = get(cache, "enabled", false) === true
    ignored = enabled ? identity.(get(Vector{String}, cache, "ignored")) : String[]
    isa(ignored, Vector{String}) || error("ignored must be a vector of strings.")
    return enabled, ignored
end

function __notebook_caching_options(notebook_options)
    function _get(d, k)
        result = get(Dict, d, k)
        return isa(result, Dict) ? result : Dict()
    end
    format = _get(notebook_options, "format")
    metadata = _get(format, "metadata")
    return _get(metadata, "julia")
end

# Utilities.

struct IsQuartoNotebook end
# Extended in the package extension to return `true` when `QuartoNotebookWorker`
# is loaded.
_is_quarto_notebook(::Any) = false

# Handle both versions of the `QuartoNotebookWorker`.
function is_quarto_notebook()
    if _is_quarto_notebook(IsQuartoNotebook())
        return true
    else
        # Fall back on the older detection method.
        if isdefined(Main, :Notebook) && isa(Main.Notebook, Module)
            if isdefined(Main, :NotebookInclude) && isa(Main.NotebookInclude, Module)
                return true
            end
        end
        return false
    end
end

function safe_isfile(file)
    return try
        isfile(file)
    catch err
        err isa Base.IOError || rethrow()
        false
    end
end

include("expandables.jl")


function __init__()
    if ccall(:jl_generating_output, Cint, ()) == 0
        _init_transform_ast_cache()
    end

    # Since UUIDs are checked by the registry checks for package extensions we
    # cannot make these "real" extensions and have to rely on `Requires.jl`.
    Requires.@require QuartoNotebookWorker = "38328d9c-a911-4051-bc06-3f7f556ffeda" begin
        # Written directly in this file such that it is compatible with use
        # within a system image where source has been stripped.

        QuartoTools._is_quarto_notebook(::QuartoTools.IsQuartoNotebook) = true

        # Convert the `QuartoToos.Cell` to the equivalent `QuartoNotebookWorker.Cell`.
        _cell(c::QuartoTools.Cell) =
            QuartoNotebookWorker.Cell(c.thunk; code = c.code, options = c.options)
        _cell(value) = QuartoNotebookWorker.Cell(value)

        function QuartoNotebookWorker.expand(tabset::QuartoTools.Div)
            ids = string.("#", tabset.id)
            classes = string.(".", tabset.class)
            keyvals = ["$key=$(repr(val))" for (key, val) in tabset.attributes]
            formatted = join(Iterators.flatten((ids, classes, keyvals)), " ")
            return vcat(
                _cell(QuartoTools.MarkdownCell("::: {$formatted}")),
                _cell.(tabset.children),
                _cell(QuartoTools.MarkdownCell(":::")),
            )
        end

        function QuartoNotebookWorker.expand(tabset::QuartoTools.Tabset)
            children = []
            for (str, ex) in tabset.tabs
                push!(children, QuartoTools.MarkdownCell("# $str"), ex)
            end
            attributes = Dict{String,String}()
            isnothing(tabset.group) || (attributes["group"] = tabset.group)
            return QuartoNotebookWorker.expand(
                QuartoTools.Div(children; class = "panel-tabset", attributes),
            )
        end

        QuartoNotebookWorker.expand(expand::QuartoTools.Expand) = _cell.(expand.children)
        QuartoNotebookWorker.expand(cell::QuartoTools.Cell) = [_cell(cell)]

        function QuartoTools._caching_options(::Nothing)
            ns = QuartoNotebookWorker.NotebookState
            nb_options = isdefined(ns, :OPTIONS) ? ns.OPTIONS[] : Dict()
            cell_options = isdefined(ns, :CELL_OPTIONS) ? ns.CELL_OPTIONS[] : Dict()
            QuartoTools.__caching_options(nb_options, cell_options)
        end
    end
end

end # module QuartoTools

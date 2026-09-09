# The macro.
#
# A cached definition becomes two: an implementation carrying the original
# body, and a method under the original name that keys the call and either
# returns a stored result or runs the implementation. Splitting them this way
# keeps the public signature exactly as it was written, dispatch included.

"""
    @cache function f(args...; kws...) ... end
    @cache f(args...; kws...) = ...
    @cache f(args...; kws...)

Cache the results of calls to `f`.

On a definition, every call to it is cached. On a call, that one call is
cached and `f` itself is left alone. A definition of a callable object,
`(c::Counter)(x)`, works too, and the object takes part in the key.

A call digests the definition, every tracked definition it transitively
depends on, and its arguments. A result stored under that digest is returned
without running the body; otherwise the body runs and its result is stored.

Change the body, or anything the body calls, at any depth, and the next call
runs again. Definitions from `Base`, the standard libraries, and packages the
manifest pins are not walked: they cannot change without the version of Julia
or the manifest changing, and both take part in the digest already. See
[`is_tracked`](@ref) for that boundary and [`track!`](@ref) to move it.

Results are stored with `Serialization`, under a `.cache` directory beside the
file holding the definition. See [`cache_directory`](@ref), [`disable!`](@ref),
[`cacheable`](@ref) and [`clear!`](@ref).

```julia
@cache function summarise(rows, passes = 1000)
    return expensive(rows, passes)
end

result = @cache summarise(rows, 5000)
```
"""
macro cache(expr)
    MacroTools.isdef(expr) && return cache_definition(expr, __module__, __source__)
    Meta.isexpr(expr, :call) && return cache_call(expr, __module__, __source__)
    return error(
        "`@cache` expects a function definition or a function call, got `$(expr)`.",
    )
end

# Caching one call rather than a definition. The call's own source says nothing
# about the result beyond which function it names, since the arguments are
# keyed by value, so only the callee takes part in the digest.
function cache_call(expr::Expr, mod::Module, source::LineNumberNode)
    callee = expr.args[1]
    arguments, keywords = split_call_arguments(expr.args[2:end])
    site = CallSite(
        String(something(base_name(callee), :call)),
        mod,
        source_file(source),
        content_hex(callee),
    )
    return esc(
        Expr(
            :call,
            run_cached,
            site,
            callee,
            callee,
            Expr(:tuple, arguments...),
            keyword_tuple(keywords),
        ),
    )
end

function split_call_arguments(given)
    arguments = Any[]
    keywords = Any[]
    for argument in given
        if Meta.isexpr(argument, :parameters)
            append!(keywords, argument.args)
        elseif Meta.isexpr(argument, :kw)
            push!(keywords, argument)
        else
            push!(arguments, argument)
        end
    end
    return arguments, keywords
end

function cache_definition(expr::Expr, mod::Module, source::LineNumberNode)
    definition = MacroTools.splitdef(expr)

    name = definition[:name]
    base, receiver = definition_name(name)
    base === nothing && error("`@cache` cannot name results for a definition of `$(name)`.")
    implementation = Symbol('#', base, "#implementation")

    args, forwarded = forwardable(definition[:args])
    kwargs, forwarded_kws = forwardable(definition[:kwargs])

    # A callable object dispatches on itself rather than on a name, so its
    # implementation takes the object as an ordinary first argument and the
    # object is what stands in for the function being cached.
    if receiver === nothing
        called = name
    else
        called, declaration = receiver
        args = Any[declaration; args]
        forwarded = Any[called; forwarded]
    end

    site = CallSite(
        String(base),
        mod,
        source_file(source),
        content_hex(MacroTools.striplines(expr)),
    )

    definition[:name] = implementation
    definition[:args] = args
    definition[:kwargs] = kwargs
    implementation_def = MacroTools.combinedef(definition)

    definition[:name] = receiver === nothing ? name : name_with_receiver(name, called)
    definition[:args] = receiver === nothing ? args : args[2:end]
    definition[:body] = Expr(
        :call,
        run_cached,
        site,
        called,
        implementation,
        Expr(:tuple, forwarded...),
        keyword_tuple(forwarded_kws),
    )
    wrapper_def = MacroTools.combinedef(definition)

    # A docstring written above the definition has two definitions to choose
    # from once the macro has expanded, so the docsystem refuses to guess.
    # `Base.@__doc__` points it at the method under the original name.
    documented = Expr(:macrocall, GlobalRef(Base, Symbol("@__doc__")), source, wrapper_def)

    return esc(Expr(:block, implementation_def, documented))
end

"""
    definition_name(name) -> (base, receiver)

The name to store results under, and how the definition names its receiver.

`base` is the bare name, so `Base.sum` gives `:sum`. `receiver` is `nothing`
for an ordinary definition, and for a callable object it is the name the
object is bound to along with the declaration that binds it, so
`(c::Counter)(x)` gives `(:Counter, (:c, :(c::Counter)))`.
"""
function definition_name(@nospecialize(name))
    Meta.isexpr(name, :(::)) || return (base_name(name), nothing)
    declaration = name::Expr
    if length(declaration.args) == 1
        # Written without a name for the object, as in `(::Counter)(x)`.
        bound = gensym(:receiver)
        type = declaration.args[1]
        declaration = Expr(:(::), bound, type)
    else
        bound, type = declaration.args
    end
    return (base_name(type), (bound, declaration))
end

name_with_receiver(name::Expr, bound) = Expr(:(::), bound, name.args[end])

source_file(source::LineNumberNode) = source.file === nothing ? "" : String(source.file)

base_name(name::Symbol) = name
base_name(name::Expr) = Meta.isexpr(name, :., 2) ? base_name(name.args[2]) : nothing
base_name(name::QuoteNode) = base_name(name.value)
base_name(@nospecialize(other)) = nothing

"""
    forwardable(arguments) -> (declarations, forwarding)

Rewrite an argument list so that every argument has a name to forward under,
and return the rewritten declarations alongside the expressions that pass them
on. An argument written without a name gets a generated one; the digits in a
generated name are stripped before hashing, so it stays stable across
processes.
"""
function forwardable(arguments)
    declarations = Any[]
    forwarding = Any[]
    for argument in arguments
        name, type, splat, default = MacroTools.splitarg(argument)
        name === nothing && (name = gensym(:argument))
        push!(declarations, MacroTools.combinearg(name, type, splat, default))
        push!(forwarding, splat ? Expr(:..., name) : name)
    end
    return declarations, forwarding
end

# A definition forwards its keywords by name, so a bare name means `name =
# name`. A call site already carries `name = value` and splats as written.
function keyword_tuple(forwarded)
    isempty(forwarded) && return Expr(:call, NamedTuple)
    entries = Any[
        Meta.isexpr(entry, (:..., :kw)) ? entry : Expr(:kw, entry, entry) for
        entry in forwarded
    ]
    return Expr(:tuple, Expr(:parameters, entries...))
end

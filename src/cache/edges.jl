# Finding the definitions a definition depends on.
#
# Two sources of edges, unioned, because neither one alone is enough.
#
# Lowered code names what a method refers to lexically: its callees, the types
# it builds, and the globals it reads. That covers a call that inference cannot
# resolve, and it costs no inference.
#
# Inferred code names what a method actually calls. That covers a method of
# ours reached only through foreign code, `Base.iterate` on one of our types
# being the usual case, which no amount of reading our own source would reveal.
#
# Descent through foreign code is bounded by asking whether a callee's
# signature mentions a tracked type at all. Dispatch can only land back in our
# code if something of ours is visible in the call, so a signature made
# entirely of foreign types cannot lead anywhere we care about.

"""
    Definitions

What a cached call depends on, found by [`reachable_definitions`](@ref).

  - `methods`: every tracked method reachable from the entry point, sorted.
  - `types`: every tracked type the code refers to, sorted.
  - `globals`: every tracked global the code reads whose value is not itself
    code. Their values are hashed per call, since assigning to a global does
    not advance the world age.
  - `digest`: a digest of `methods` and `types`. Stable for as long as the
    world age holds.
"""
struct Definitions
    methods::Vector{Method}
    types::Vector{Any}
    globals::Vector{GlobalRef}
    digest::Vector{UInt8}
end

const ANALYSES = Dict{Tuple{Any,Any},Definitions}()
const ANALYSED_WORLD = Ref(typemin(UInt))

# Foreign code can be arbitrarily deep, so cap the descent. Reaching the cap
# means edges may be missed, which is why the lexical scan is not optional.
const MAX_INFERRED_EDGES = 5_000

"""
    reachable_definitions(f, argtypes::Type{<:Tuple}) -> Definitions

The tracked definitions that calling `f` with `argtypes` depends on,
transitively. Memoised for as long as the world age holds, so a redefinition
anywhere recomputes it and nothing else does.
"""
function reachable_definitions(@nospecialize(f), @nospecialize(argtypes::Type))
    return lock(ANALYSIS_LOCK) do
        world = Base.get_world_counter()
        if ANALYSED_WORLD[] != world
            # Whether a definition changed is unknown, so every analysis is
            # recomputed on demand. `resolve` makes that cheap for the ones
            # whose closure held still.
            empty!(ANALYSES)
            empty!(TRACKED_CALLABLES)
            ANALYSED_WORLD[] = world
        end
        # What a call reaches follows from the type of the callable, so every
        # instance of one closure type shares an answer.
        return get!(() -> analyse(f, argtypes), ANALYSES, (Core.Typeof(f), argtypes))
    end
end

"""
    dependency_digest(f, argtypes::Type{<:Tuple}) -> Vector{UInt8}

Digest every definition that calling `f` with `argtypes` depends on, together
with the current values of the globals it reads.
"""
function dependency_digest(@nospecialize(f), @nospecialize(argtypes::Type))
    definitions = reachable_definitions(f, argtypes)
    serializer = ContentHashSerializer()
    write(serializer.io, definitions.digest)
    for ref in definitions.globals
        Serialization.serialize(serializer, (module_name(ref.mod), ref.name))
        write(serializer.io, global_digest(ref))
    end
    return SHA.digest!(serializer.io.ctx)
end

"""
    global_digest(ref::GlobalRef) -> Vector{UInt8}

Digest the current value of a global.

A value nothing can write, a running task being the usual one, leaves its type
standing in for it. The call keeps a key it would otherwise have lost, at the
price of a change to that value going unnoticed, which is what the warning is
for.
"""
function global_digest(ref::GlobalRef)
    value = global_value(ref)
    return try
        content_hash(value)
    catch error
        @warn "Cannot hash a global, keying on its type instead. Exempt it with `ignore_global!`, or `untrack!` the module it belongs to." reference =
            string(ref) type = typeof(value) error maxlog = 1
        content_hash((:unhashable, string(typeof(value))))
    end
end

const IGNORED_GLOBALS = Set{GlobalRef}()

"""
    ignore_global!(mod::Module, name::Symbol)

Stop the value of a global taking part in cache keys.

The value of every tracked global that cached code reads is hashed on every
call, since assigning to a global does not advance the world age and so
nothing cheaper would notice a change. Use this for a global whose value is
large and does not affect results, such as a preallocated buffer, and
[`watch_global!`](@ref) to undo it.
"""
function ignore_global!(mod::Module, name::Symbol)
    lock(ANALYSIS_LOCK) do
        push!(IGNORED_GLOBALS, GlobalRef(mod, name))
        forget_analysis!()
    end
    return nothing
end

"""
    watch_global!(mod::Module, name::Symbol)

Let the value of a global take part in cache keys again, undoing
[`ignore_global!`](@ref).
"""
function watch_global!(mod::Module, name::Symbol)
    lock(ANALYSIS_LOCK) do
        delete!(IGNORED_GLOBALS, GlobalRef(mod, name))
        forget_analysis!()
    end
    return nothing
end

function forget_analysis!()
    lock(ANALYSIS_LOCK) do
        empty!(ANALYSES)
        empty!(RESOLUTIONS)
        empty!(TRACKED_CALLABLES)
        empty!(TRACKED_SIGNATURES)
    end
    return nothing
end

mutable struct Walk
    pending::Vector{Method}
    methods::Set{Method}
    types::Set{Any}
    globals::Set{GlobalRef}
    callables::Set{Any}
    budget::Int
end

Walk() = Walk(
    Method[],
    Set{Method}(),
    Set{Any}(),
    Set{GlobalRef}(),
    Set{Any}(),
    MAX_INFERRED_EDGES,
)

function analyse(@nospecialize(f), @nospecialize(argtypes::Type))
    walk = Walk()
    push_callable!(walk, f)
    add_inferred_edges!(walk, f, argtypes)
    # Scanning a method can queue more methods, so run to a fixpoint.
    while !isempty(walk.pending)
        scan_method!(walk, pop!(walk.pending))
    end

    methods = sort!(collect(walk.methods); by = method_sort_key)
    types = sort!(collect(walk.types); by = string)
    globals = sort!(
        collect(walk.globals);
        by = ref -> (string(module_name(ref.mod)), String(ref.name)),
    )
    return Definitions(methods, types, globals, structural_digest(methods, types))
end

function structural_digest(methods::Vector{Method}, types::Vector{Any})
    context = SHA.SHA2_256_CTX()
    SHA.update!(context, combined_digest(methods))
    SHA.update!(context, combined_digest(types))
    return SHA.digest!(context)
end


# Growing the set.

function push_method!(walk::Walk, m::Method)
    is_tracked(m.module) || return nothing
    m in walk.methods && return nothing
    push!(walk.methods, m)
    push!(walk.pending, m)
    return nothing
end

push_callable!(walk::Walk, @nospecialize(f)) = push_callable_type!(walk, Core.Typeof(f))

function push_callable_type!(walk::Walk, @nospecialize(T::Type))
    T in walk.callables && return nothing
    push!(walk.callables, T)
    for m in tracked_callable_methods(T)
        push_method!(walk, m)
    end
    return nothing
end

const TRACKED_CALLABLES = Dict{Any,Vector{Method}}()

# Enumerating the methods of a foreign function such as `sum` walks several
# hundred of them to find the handful that tracked code added. Keep the answer
# for as long as the world age holds, since only a new definition can change
# it.
function tracked_callable_methods(@nospecialize(T::Type))
    return get!(TRACKED_CALLABLES, T) do
        filter(m -> is_tracked(m.module), callable_methods(T))
    end
end

function push_type!(walk::Walk, @nospecialize(T::Type))
    named = Base.unwrap_unionall(T)
    named isa DataType || return nothing
    is_tracked(named.name.module) || return nothing
    push!(walk.types, T)
    # Constructors are methods of `Type{T}`, and changing one changes what a
    # call to it produces.
    push_callable_type!(walk, Type{T})
    return nothing
end


# Lexical edges: what the source of a method names.

function scan_method!(walk::Walk, m::Method)
    for statement in method_statements(m)
        scan!(walk, statement)
    end
    return nothing
end

function scan!(walk::Walk, @nospecialize(x))
    if x isa GlobalRef
        scan_global!(walk, x)
    elseif x isa Expr
        for arg in x.args
            scan!(walk, arg)
        end
    elseif x isa Core.CodeInfo
        # Lowering hoists an inner function into a `:method` statement that
        # carries the body as code of its own.
        for statement in x.code
            scan!(walk, statement)
        end
    elseif x isa QuoteNode
        scan_value!(walk, x.value)
    elseif x isa Core.ReturnNode
        isdefined(x, :val) && scan!(walk, x.val)
    elseif x isa Core.GotoIfNot
        scan!(walk, x.cond)
    elseif x isa Type
        push_type!(walk, x)
    elseif x isa Function
        push_callable!(walk, x)
    end
    return nothing
end

function scan_global!(walk::Walk, ref::GlobalRef)
    owner = binding_owner(ref)
    owner === nothing && return nothing
    isdefined(owner, ref.name) || return nothing
    value = try
        get_global(owner, ref.name)
    catch
        return nothing
    end
    if value isa Module
        return nothing
    elseif value isa Type || value isa Function
        # A foreign function is followed too, since a method added to it from
        # tracked code is tracked code.
        scan_value!(walk, value)
    elseif is_tracked(owner)
        # Plain data. Its name is in the code, its value is not, so the value
        # has to be read again on every call.
        binding = GlobalRef(owner, ref.name)
        binding in IGNORED_GLOBALS || push!(walk.globals, binding)
    end
    return nothing
end

function scan_value!(walk::Walk, @nospecialize(value))
    if value isa Type
        push_type!(walk, value)
    elseif !(value isa Module)
        push_callable!(walk, value)
    end
    return nothing
end

function binding_owner(ref::GlobalRef)
    return try
        Base.which(ref.mod, ref.name)
    catch
        isdefined(ref.mod, ref.name) ? ref.mod : nothing
    end
end

function global_value(ref::GlobalRef)
    isdefined(ref.mod, ref.name) || return nothing
    return try
        get_global(ref.mod, ref.name)
    catch
        nothing
    end
end


# Inferred edges: what a method actually calls.

# Inference runs without the optimiser here. An optimised method body has had
# its callees inlined into it, and on Julia 1.11 and earlier nothing on the
# caller's side records what those callees were. Unoptimised code keeps every
# call site, and the inferred types at each one are enough to ask Julia's own
# method lookup which definitions the call can reach.

# How many methods a single call site may resolve to before it counts as too
# vague to follow. The lexical scan covers a call this abandons.
const MAX_MATCHES = 10

function add_inferred_edges!(walk::Walk, @nospecialize(f), @nospecialize(argtypes::Type))
    entry = entry_signature(f, argtypes)
    entry === nothing && return nothing
    pending = Any[entry]
    seen = Set{Any}()
    while !isempty(pending) && walk.budget > 0
        signature = pop!(pending)
        signature in seen && continue
        push!(seen, signature)

        # The call being cached is always followed. Past it, dispatch reaches
        # tracked code only where something tracked is still visible in the
        # signature, whether one of our types or one of our functions.
        signature === entry || mentions_tracked(signature) || continue
        walk.budget -= 1

        resolution = resolve(signature)
        for m in resolution.methods
            push_method!(walk, m)
        end
        append!(pending, resolution.callees)
    end
    return nothing
end

function entry_signature(@nospecialize(f), @nospecialize(argtypes::Type))
    return try
        Tuple{Core.Typeof(f),argtypes.parameters...}
    catch
        nothing
    end
end

"""
    Resolution

The methods a call signature resolves to, and the signatures those methods go
on to call.
"""
struct Resolution
    methods::Vector{Method}
    callees::Vector{Any}
end

const RESOLUTIONS = Dict{Any,Resolution}()

# The memo outlives the world age on purpose, so that redefining one function
# does not re-infer the frontier of every cached definition. Cap it so that a
# long session cannot grow it without bound.
const MAX_RESOLUTIONS = 100_000

"""
    resolve(signature) -> Resolution

Resolve `signature` and find what the methods it resolves to call.

Resolving costs a method lookup. Finding the calls costs inference, which is
several orders more, so the result is kept and reused for as long as the same
lookup gives back the same methods. A redefinition anywhere in the closure
shows up as a different method here, and only then is inference run again.
"""
function resolve(@nospecialize(signature))
    matches = method_matches(signature)
    methods = Method[match.method for match in matches]
    cached = get(RESOLUTIONS, signature, nothing)
    if cached !== nothing && cached.methods == methods
        return cached
    end

    callees = Any[]
    for match in matches
        for code in typed_code_by_type(match.spec_types)
            collect_signatures!(callees, code)
        end
    end
    length(RESOLUTIONS) > MAX_RESOLUTIONS && empty!(RESOLUTIONS)
    resolution = Resolution(methods, callees)
    RESOLUTIONS[signature] = resolution
    return resolution
end

function method_matches(@nospecialize(signature))
    matches = Base._methods_by_ftype(signature, MAX_MATCHES, Base.get_world_counter())
    matches isa Vector || return Core.MethodMatch[]
    return Core.MethodMatch[match for match in matches]
end

function typed_code_by_type(@nospecialize(signature))
    return try
        Core.CodeInfo[
            pair.first for pair in Base.code_typed_by_type(signature; optimize = false)
        ]
    catch
        Core.CodeInfo[]
    end
end

function collect_signatures!(pending::Vector{Any}, code::Core.CodeInfo)
    for statement in code.code
        collect_signatures_from!(pending, statement, code)
    end
    return nothing
end

function collect_signatures_from!(
    pending::Vector{Any},
    @nospecialize(x),
    code::Core.CodeInfo,
)
    if x isa Expr
        if x.head === :call
            signature = call_signature(x, code)
            signature === nothing || push!(pending, signature)
        end
        for arg in x.args
            collect_signatures_from!(pending, arg, code)
        end
    elseif x isa Core.ReturnNode
        isdefined(x, :val) && collect_signatures_from!(pending, x.val, code)
    elseif x isa Core.GotoIfNot
        collect_signatures_from!(pending, x.cond, code)
    end
    return nothing
end

function call_signature(call::Expr, code::Core.CodeInfo)
    types = Any[statement_type(arg, code) for arg in call.args]
    any(T -> T === Union{}, types) && return nothing
    return try
        Tuple{types...}
    catch
        nothing
    end
end

"""
    statement_type(x, code::Core.CodeInfo) -> Type

The inferred type of `x` inside `code`, widened out of the inference lattice
into an ordinary type.
"""
function statement_type(@nospecialize(x), code::Core.CodeInfo)
    if x isa Core.SSAValue
        types = code.ssavaluetypes
        types isa Vector || return Any
        return widen_lattice(types[x.id])
    elseif x isa Core.SlotNumber || x isa Core.Argument
        types = code.slottypes
        types isa Vector || return Any
        index = x isa Core.Argument ? x.n : x.id
        return checkbounds(Bool, types, index) ? widen_lattice(types[index]) : Any
    elseif x isa GlobalRef
        isdefined(x.mod, x.name) || return Any
        isconst(x.mod, x.name) || return Any
        return Core.Typeof(get_global(x.mod, x.name))
    elseif x isa QuoteNode
        return Core.Typeof(x.value)
    elseif x isa Expr
        return Any
    else
        return Core.Typeof(x)
    end
end

function widen_lattice(@nospecialize(t))
    t isa Type && return t
    t isa Core.Const && return Core.Typeof(t.val)
    # `PartialStruct` and friends each carry the widened type in `typ`.
    hasproperty(t, :typ) && return widen_lattice(getproperty(t, :typ))
    return Any
end

const TRACKED_SIGNATURES = Dict{Any,Bool}()

# One entry per type the walk has asked about, which a long session keeps
# adding to. Cap it the way `RESOLUTIONS` is capped, since recomputing an
# answer costs a walk over one type.
const MAX_TRACKED_SIGNATURES = 100_000

"""
    mentions_tracked(T) -> Bool

Whether any tracked type appears anywhere in `T`. A call signature made only
of foreign types cannot dispatch back into tracked code.
"""
function mentions_tracked(@nospecialize(T))
    cached = get(TRACKED_SIGNATURES, T, nothing)
    cached === nothing || return cached
    result = compute_mentions_tracked(T)
    length(TRACKED_SIGNATURES) > MAX_TRACKED_SIGNATURES && empty!(TRACKED_SIGNATURES)
    TRACKED_SIGNATURES[T] = result
    return result
end

function compute_mentions_tracked(@nospecialize(T))
    if T isa DataType
        is_tracked(T.name.module) && return true
        return any(mentions_tracked, T.parameters)
    elseif T isa UnionAll
        return mentions_tracked(T.body)
    elseif T isa Union
        return mentions_tracked(T.a) || mentions_tracked(T.b)
    elseif T isa TypeVar
        return mentions_tracked(T.ub)
    elseif is_vararg(T)
        return isdefined(T, :T) ? mentions_tracked(T.T) : false
    else
        return false
    end
end

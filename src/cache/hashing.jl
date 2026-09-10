# Content hashing.
#
# Two identical values must hash to the same digest in two different processes,
# so nothing that varies between runs may reach the hash: no pointers, no
# process-local object numbering, no gensym counters, and no source locations.
# Code hashes on its lowered statements, so a definition the walk reaches keeps
# its digest through a renamed local variable or a move down the file, and
# loses it whenever what the code does changes. A cached definition's own
# source is digested as written, and a rename there gives a new key.

const LIBXXHASH = xxHash_jll.libxxhash

# The 128 bit hash the library hands back, halves named as its own struct names
# them.
struct XXH128Hash
    low64::UInt64
    high64::UInt64
end

# An `IO` that digests what is written to it. Every part of a cache key is
# assembled by writing into one of these, so a key means one thing whichever
# part of the cache put it together. Bytes reach the library from where they
# already sit: a cached call hands over whole arguments, and copying one to
# hash it is the cost the cache exists to avoid.
mutable struct HashSink <: IO
    state::Ptr{Cvoid}

    function HashSink()
        state = ccall((:XXH3_createState, LIBXXHASH), Ptr{Cvoid}, ())
        ccall((:XXH3_128bits_reset, LIBXXHASH), Cint, (Ptr{Cvoid},), state)
        sink = new(state)
        finalizer(free_state!, sink)
        return sink
    end
end

free_state!(sink::HashSink) =
    ccall((:XXH3_freeState, LIBXXHASH), Cint, (Ptr{Cvoid},), sink.state)

Base.isreadable(::HashSink) = false
Base.iswritable(::HashSink) = true

@inline function update!(sink::HashSink, ptr::Ptr{UInt8}, nbytes::UInt)
    ccall(
        (:XXH3_128bits_update, LIBXXHASH),
        Cint,
        (Ptr{Cvoid}, Ptr{UInt8}, Csize_t),
        sink.state,
        ptr,
        nbytes,
    )
    return nothing
end

@inline function Base.write(sink::HashSink, byte::UInt8)
    # The byte is handed over where it stands. `Serialization` writes tags a
    # byte at a time, so this runs once per tag and must not allocate.
    holder = Ref(byte)
    GC.@preserve holder update!(sink, Base.unsafe_convert(Ptr{UInt8}, holder), UInt(1))
    return 1
end

@inline function Base.unsafe_write(sink::HashSink, ptr::Ptr{UInt8}, nbytes::UInt)
    update!(sink, ptr, nbytes)
    return Int(nbytes)
end

"""
    sink_digest(sink::HashSink) -> Vector{UInt8}

The 16 bytes digesting everything written to `sink`.

The two halves of the hash are laid down in the library's canonical order: the
high half first, each half most significant byte first. Every XXH3
implementation writes those bytes in that order, so a digest taken here says
the same thing as a digest taken anywhere else, on a machine of either
endianness.
"""
function sink_digest(sink::HashSink)
    hash = ccall((:XXH3_128bits_digest, LIBXXHASH), XXH128Hash, (Ptr{Cvoid},), sink.state)
    digest = Vector{UInt8}(undef, 16)
    for (offset, half) in ((0, hash.high64), (8, hash.low64))
        for i = 1:8
            digest[offset+i] = (half >> (8 * (8 - i))) % UInt8
        end
    end
    return digest
end

struct ContentHashSerializer <: Serialization.AbstractSerializer
    io::HashSink
    __serializer__::Serialization.Serializer

    function ContentHashSerializer()
        # The inner serializer holds the bookkeeping that `Serialization` needs
        # (object tables, counters). Its own stream is never written to;
        # property forwarding below hands out the hash sink as `io` instead.
        return new(HashSink(), Serialization.Serializer(IOBuffer()))
    end
end

const OWN_FIELDS = (:io, :__serializer__)

const OPEN_TYPES_KEY = :quartotools_open_types

"""
    open_types() -> Vector{Core.TypeName}

The type names on the path this task is part way through writing, which is what
stops a type that reaches itself from recursing.

The path does not live in the serializer, because a nested digest starts a
serializer of its own and the guard has to span the two. It lives per task
rather than per process because nothing stops two tasks hashing at once, and
one task's path is not the other's.
"""
open_types() =
    get!(() -> Core.TypeName[], task_local_storage(), OPEN_TYPES_KEY)::Vector{Core.TypeName}

function Base.setproperty!(s::ContentHashSerializer, name::Symbol, value)
    name in OWN_FIELDS && return setfield!(s, name, value)
    return setproperty!(getfield(s, :__serializer__), name, value)
end

function Base.getproperty(s::ContentHashSerializer, name::Symbol)
    name in OWN_FIELDS && return getfield(s, name)
    return getproperty(getfield(s, :__serializer__), name)
end

"""
    content_hash(value) -> Vector{UInt8}

Digest the content of `value`. Structurally identical values digest to the same
bytes across processes, which is what makes the digest usable as a cache key.
Values that cannot be serialized throw; a cache key is never guessed.
"""
function content_hash(@nospecialize(value))
    serializer = ContentHashSerializer()
    Serialization.serialize(serializer, deconstruct(value))
    return sink_digest(serializer.io)
end

"""
    content_hex(value) -> String

[`content_hash`](@ref) rendered as a hexadecimal string.
"""
content_hex(@nospecialize(value)) = bytes2hex(content_hash(value))

# Tags separating the shapes written below, so that a callable and a struct
# holding the same field values cannot digest alike.
const TAG_CALLABLE = 0xc0
const TAG_ANONYMOUS = 0xc1
const TAG_METHOD = 0xc2
const TAG_DATATYPE = 0xc5
const TAG_TYPENAME = 0xc6
const TAG_METHODS = 0xc3
const TAG_UNDEF = 0xc4
const TAG_OPEN = 0xc7

# Source locations are presentation, not content.
Serialization.serialize(::ContentHashSerializer, ::LineNumberNode) = nothing

if isdefined(Core, :LineInfoNode)
    Serialization.serialize(::ContentHashSerializer, ::Core.LineInfoNode) = nothing
end

if isdefined(Core, :DebugInfo)
    Serialization.serialize(::ContentHashSerializer, ::Core.DebugInfo) = nothing
end

# An address says nothing about content and differs on every run.
Serialization.serialize(::ContentHashSerializer, ::Ptr) = nothing

"""
    normalize_symbol(sym::Symbol) -> Symbol

Strip the counters out of generated names. `Symbol("#foo##3")` becomes
`Symbol("#foo##")`, so that a name generated during lowering digests the same
way in every process regardless of how many names were generated before it.

Only a generated name is stripped. A symbol a caller built is data, and
`Symbol("Item #1")` has to keep the digit that tells it from `Symbol("Item #2")`.
"""
function normalize_symbol(sym::Symbol)
    is_generated_name(sym) || return sym
    return Symbol(filter(!isdigit, String(sym)))
end

function Serialization.serialize(s::ContentHashSerializer, sym::Symbol)
    return invoke(
        Serialization.serialize,
        Tuple{Serialization.AbstractSerializer,Symbol},
        s,
        normalize_symbol(sym),
    )
end

is_generated_name(name::Symbol) = startswith(String(name), '#')

"""
    module_name(mod::Module) -> Tuple{Symbol, Vararg{Symbol}}

The name to digest for `mod`, after [`storage_module`](@ref) has had its say.
Every digest goes through this, so that code mapped onto another module keys
the same way there.
"""
module_name(mod::Module) = fullname(storage_module(mod))

# A module reached as a value is written under its mapped name too.
function Serialization.serialize(s::ContentHashSerializer, mod::Module)
    return invoke(
        Serialization.serialize,
        Tuple{Serialization.AbstractSerializer,Module},
        s,
        storage_module(mod),
    )
end

"""
    callable_name(tn::Core.TypeName) -> Union{Symbol,Nothing}

The name a callable is known by, or `nothing` when it has none.

Julia decorates the type name of every function with a leading `#`, so the
decoration alone does not tell a named function from an anonymous one. A name
exists when the defining module has a binding of it pointing back at this
type, which is true of `sum` and false of a closure.
"""
function callable_name(tn::Core.TypeName)
    decorated = String(tn.name)
    startswith(decorated, '#') || return tn.name
    bare = Symbol(decorated[nextind(decorated, 1):end])
    isdefined(tn.module, bare) || return nothing
    value = try
        get_global(tn.module, bare)
    catch
        return nothing
    end
    return Core.Typeof(value) === Base.unwrap_unionall(tn.wrapper) ? bare : nothing
end

"""
    method_statements(m::Method)

The lowered statements of `m`, which carry what the method does without
carrying where it was written.
"""
method_statements(m::Method) = Base.uncompressed_ast(m).code

# A method's identity is its module, name and signature. Its content is its
# lowered code, and only tracked code needs that: everything else is pinned by
# `VERSION` and the manifest.
function Serialization.serialize(s::ContentHashSerializer, m::Method)
    write(s.io, TAG_METHOD)
    # Each part is digested on its own and its digest written, so that no part
    # can be written as a back reference to an object an earlier part happened
    # to write first. `Serialization` numbers those references by position, and
    # code read back from a store refers to objects that the live code it came
    # from shared, which would put the difference into the digest.
    write(s.io, content_hash(module_name(m.module)))
    # A name that lowering invented for a closure says nothing about what the
    # closure computes, and what it holds varies between Julia versions. Two
    # closures with the same body and the same captures are the same
    # computation whatever they ended up called.
    if !is_generated_name(m.name)
        write(s.io, content_hash(m.name))
    end
    # A count and a flag hold nothing that a later part could point back at, so
    # they go into the stream as they stand.
    Serialization.serialize(s, m.nargs)
    Serialization.serialize(s, m.isva)
    write(s.io, content_hash(argument_types(m)))
    if tracked(m.module)
        write(s.io, content_hash(method_statements(m)))
    end
    return nothing
end

# What a method accepts after the callable itself. The callable is what this
# digest is being written as part of, so writing its type again here would walk
# the code of every method it has once per method.
function argument_types(m::Method)
    signature = Base.unwrap_unionall(m.sig)
    signature isa DataType || return Any[m.sig]
    parameters = signature.parameters
    isempty(parameters) && return Any[]
    return Any[parameters[i] for i = 2:length(parameters)]
end

function Serialization.serialize(s::ContentHashSerializer, mi::Core.MethodInstance)
    Serialization.serialize(s, mi.def)
    Serialization.serialize(s, mi.specTypes)
    return nothing
end

"""
    callable_methods(@nospecialize(T::Type)) -> Vector{Method}

The methods that make `T` callable, in a stable order. Empty for a type that is
not callable, and for `Core.kwcall`.
"""
function callable_methods(@nospecialize(T::Type))
    # Every keyword call in the system goes through `Core.kwcall`, and its table
    # holds every keyword method there is. Enumerating it would make one
    # keyword call depend on every function that takes keywords. What such a
    # call actually reaches is its callee, which the call names itself.
    T === KWCALL_TYPE && return Method[]
    primary = Base.unwrap_unionall(T)
    primary isa DataType || return Method[]
    # A constructor is a method of `Type{T}`, which is abstract, so the test
    # below would drop it. The table hanging off `Type` holds every constructor
    # in the system, so the signature is intersected instead.
    is_type_type(primary) && return matching_methods(T)
    # `Tuple{Any, Vararg{Any}}` matches every method in the system. Abstract
    # types are never the exact type of a callable, so skip them.
    isabstracttype(primary) && return Method[]
    table = own_method_table(primary)
    table === nothing || return Method[m for m in Base.MethodList(table) if is_live(m)]
    return matching_methods(T)
end

const TYPE_TYPENAME = Base.unwrap_unionall(Type).name

is_type_type(primary::DataType) = primary.name === TYPE_TYPENAME

# The methods a call to something of type `T` can reach, found by intersecting
# its signature against the whole system.
function matching_methods(@nospecialize(T::Type))
    matches = Base._methods_by_ftype(Tuple{T,Vararg{Any}}, -1, Base.get_world_counter())
    matches isa Vector || return Method[]
    return Method[match.method for match in matches if is_live(match.method)]
end

"""
    is_live(m::Method) -> Bool

Whether `m` is the definition in force rather than one a later definition
replaced.

Redefining a method leaves the one it replaced in its table, so a session that
edits a function keeps every version it has passed through. Counting them all
puts the history of the session into the key, which stops a function returned
to what it said before from keying the way it did then.
"""
function is_live(m::Method)
    hasfield(Method, :deleted_world) || return true
    return getfield(m, :deleted_world) == typemax(UInt)
end

const HAS_METHOD_TABLES = :mt in fieldnames(Core.TypeName)

# Julia 1.9 routed every keyword call through one function. Before that each
# one had a sorter of its own, and there was no shared table to avoid.
const KWCALL_TYPE = isdefined(Core, :kwcall) ? Core.Typeof(Core.kwcall) : nothing

"""
    own_method_table(primary::DataType) -> Union{Core.MethodTable,Nothing}

The method table belonging to `primary` alone, or `nothing` when it has none.

A function's own table holds exactly its own methods, and walking it beats
intersecting a signature against every method in the system. Everything that
is not a function shares one table, and a callable struct can inherit its call
method from an abstract parent, so neither gets the shortcut.
"""
function own_method_table(primary::DataType)
    HAS_METHOD_TABLES || return nothing
    name = primary.name
    isdefined(name, :mt) || return nothing
    table = getfield(name, :mt)
    table === nothing && return nothing
    # The table every non-function type shares.
    table === Symbol.name.mt && return nothing
    return table
end

# Printed type names depend on which modules are loaded, so a signature is not
# something to order by. This orders on what a method is, and callers that
# need a total order break ties on content digests instead.
method_sort_key(m::Method) =
    (string(module_name(m.module)), String(normalize_symbol(m.name)), Int(m.nargs), m.isva)

# Only an anonymous callable needs its code hashed here. A named one is
# identified by its name, and what its methods do reaches a cache key through
# the dependency walk instead, which is where a change to them belongs.
function serialize_anonymous_methods(s::ContentHashSerializer, @nospecialize(T::Type))
    # Written into the serializer in hand rather than digested separately, so
    # that the cycle table still holds: an anonymous callable's own signature
    # names its own type.
    found = sort!(callable_methods(T); by = method_sort_key)
    write(s.io, TAG_METHODS)
    Serialization.serialize(s, length(found))
    for m in found
        Serialization.serialize(s, m)
    end
    return nothing
end

"""
    combined_digest(values) -> Vector{UInt8}

Digest a collection without depending on the order it came in. Each value is
digested on its own and the digests are sorted, so a set found in one order
here and another order there still digests alike.
"""
function combined_digest(values)
    parts = Vector{UInt8}[part_digest(value) for value in values]
    sort!(parts)
    sink = HashSink()
    for part in parts
        write(sink, part)
    end
    return sink_digest(sink)
end

"""
    evict_half!(memo::AbstractDict, cap::Integer)

Drop half of `memo` once it holds more than `cap` entries.

A memo answers the question it holds for nothing, so emptying one hands a
session's work back to be done again. Half of it goes instead, and the entries
sit in no order worth choosing by, so the half the iteration reaches first is
the half that goes.
"""
function evict_half!(memo::AbstractDict, cap::Integer)
    length(memo) > cap || return nothing
    # Collected first: a dictionary cannot be walked while it is being deleted
    # from.
    for key in collect(Iterators.take(keys(memo), length(memo) ÷ 2))
        delete!(memo, key)
    end
    return nothing
end

const METHOD_DIGESTS = IdDict{Method,Vector{UInt8}}()

# One entry per method the walk has digested, which a long session keeps adding
# to. Cap it the way the memos in `edges.jl` are capped.
const MAX_METHOD_DIGESTS = 100_000

part_digest(@nospecialize(value)) = content_hash(value)

# A method's lowered code cannot change: a redefinition writes a method of its
# own and leaves this one where it stands. So the digest outlives a world age,
# and one definition made in a session costs no rehashing of every method every
# cached call reaches. What the digest also carries is whether the method's
# module is tracked, which `forget_analysis!` is what moves.
function part_digest(m::Method)
    cached = get(METHOD_DIGESTS, m, nothing)
    cached === nothing || return cached
    digest = content_hash(m)
    evict_half!(METHOD_DIGESTS, MAX_METHOD_DIGESTS)
    METHOD_DIGESTS[m] = digest
    return digest
end

# A callable's content is the values it captures plus the code of its own
# methods. An anonymous callable has no name worth hashing: two closures with
# the same body and the same captures are the same computation, whatever
# lowering chose to call them.
function Serialization.serialize(s::ContentHashSerializer, f::Function)
    Serialization.serialize_cycle(s, f) && return nothing
    T = typeof(f)
    name = callable_name(T.name)
    if name === nothing
        # The type name carries the code, under the same guard against a type
        # that refers to itself.
        Serialization.serialize(s, T.name)
    else
        write(s.io, TAG_CALLABLE)
        Serialization.serialize(s, module_name(T.name.module))
        Serialization.serialize(s, name)
    end
    for i = 1:nfields(f)
        if isdefined(f, i)
            Serialization.serialize(s, getfield(f, i))
        else
            write(s.io, TAG_UNDEF)
        end
    end
    return nothing
end

# The default serialization writes a type that can be found by name as its
# module and name, which puts a generated name back into the digest and makes
# the digest depend on whether the name happens to be bound yet. A type's
# content is its name and its parameters, so write those.
function Serialization.serialize(s::ContentHashSerializer, t::DataType)
    write(s.io, TAG_DATATYPE)
    Serialization.serialize(s, t.name)
    Serialization.serialize(s, t.parameters)
    return nothing
end

# A type name carries the shape of the type: what it is called, what it is a
# subtype of, and what fields it holds. The default serialization also walks
# the method table hanging off a function's type name, which for a function
# like `+` means several hundred methods that `VERSION` already pins, so this
# writes the shape itself instead.
function Serialization.serialize(s::ContentHashSerializer, tn::Core.TypeName)
    name = callable_name(tn)
    if name === nothing
        # A name lowering invented is not content, and on some versions it
        # carries the name of the function the closure was written in. What the
        # type holds and, when it is callable, what its code does, are.
        write(s.io, TAG_ANONYMOUS)
    else
        write(s.io, TAG_TYPENAME)
        Serialization.serialize(s, module_name(tn.module))
        Serialization.serialize(s, name)
    end

    # A type reaches itself through its supertype, its fields, or the code of
    # its methods, so the shape below is written once per path, and a revisit
    # is marked by how deep in the path the type sits. That keeps the digest on
    # the shape, where `Serialization`'s own guard would put in the order two
    # objects happened to be seen: code read back from a store refers to a
    # rebuilt type where the live value referred to one type throughout.
    open = open_types()
    depth = findfirst(==(tn), open)
    if depth !== nothing
        write(s.io, TAG_OPEN)
        Serialization.serialize(s, depth)
        return nothing
    end
    push!(open, tn)
    try
        name === nothing && serialize_anonymous_methods(s, tn.wrapper)
        Serialization.serialize(s, tn.names)
        primary = Base.unwrap_unionall(tn.wrapper)
        if primary isa DataType
            Serialization.serialize(s, primary.super)
            Serialization.serialize(s, primary.types)
            Serialization.serialize(s, isabstracttype(primary))
            Serialization.serialize(s, is_mutable_type(primary))
        end
    finally
        pop!(open)
    end
    return nothing
end

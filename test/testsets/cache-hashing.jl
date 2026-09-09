module CacheHashingTests

using Test

import QuartoTools

# Two structurally identical closures built at different source locations.
make_adder_a(n) = x -> x + n
make_adder_b(n) = x -> x + n

struct Point
    x::Int
    y::Int
end

@testset "content_hash" begin
    @testset "equal values hash equal" begin
        @test QuartoTools.content_hash([1, 2, 3]) == QuartoTools.content_hash([1, 2, 3])
        @test QuartoTools.content_hash(Point(1, 2)) == QuartoTools.content_hash(Point(1, 2))
        @test QuartoTools.content_hash((a = 1, b = "x")) ==
              QuartoTools.content_hash((a = 1, b = "x"))
    end

    @testset "different values hash differently" begin
        @test QuartoTools.content_hash([1, 2, 3]) != QuartoTools.content_hash([1, 2, 4])
        @test QuartoTools.content_hash(Point(1, 2)) != QuartoTools.content_hash(Point(2, 1))
        @test QuartoTools.content_hash(1) != QuartoTools.content_hash(1.0)
    end

    @testset "closures hash on their code, not their identity" begin
        @test QuartoTools.content_hash(make_adder_a(1)) ==
              QuartoTools.content_hash(make_adder_a(1))
        # Same body, different source lines and different generated type names.
        @test QuartoTools.content_hash(make_adder_a(1)) ==
              QuartoTools.content_hash(make_adder_b(1))
        # Captured values participate in the hash.
        @test QuartoTools.content_hash(make_adder_a(1)) !=
              QuartoTools.content_hash(make_adder_a(2))
        # A different body gives a different hash.
        @test QuartoTools.content_hash(make_adder_a(1)) !=
              QuartoTools.content_hash(n -> n * 2)
    end

    @testset "a named function is not mistaken for an anonymous one" begin
        # A named function is identified by its name. Reading that name back
        # off the type is what keeps its whole method table out of the digest.
        @test QuartoTools.callable_name(typeof(sum).name) === :sum
        @test QuartoTools.callable_name(typeof(Base.iterate).name) === :iterate
        @test QuartoTools.callable_name(typeof(n -> n + 1).name) === nothing
    end

    @testset "hex digest" begin
        h = QuartoTools.content_hex(Point(3, 4))
        @test length(h) == 64
        @test all(isxdigit, h)
        @test h == QuartoTools.content_hex(Point(3, 4))
    end

    @testset "types hash on their shape" begin
        shapes = Any[
            Tuple{Int,Int},
            Tuple{Int,Vararg{Int}},
            Vector{Vector{Int}},
            Union{Int,Nothing},
            Dict,
            Point,
            Type{Point},
            Integer,
            typeof(sum),
            typeof(x -> x),
        ]
        digests = map(QuartoTools.content_hash, shapes)
        @test length(unique(digests)) == length(shapes)
        @test digests == map(QuartoTools.content_hash, shapes)
    end

    @testset "unhashable values throw rather than collide" begin
        @test_throws Exception QuartoTools.content_hash(current_task())
    end

    @testset "a symbol a caller built keeps its digits" begin
        # Only a name lowering invented has counters worth stripping. A symbol
        # holding a `#` is ordinary data, and a column name read off a data
        # header is the usual way one arrives.
        @test QuartoTools.content_hash(Symbol("Item #1")) !=
              QuartoTools.content_hash(Symbol("Item #2"))
        @test QuartoTools.content_hash([Symbol("col#1"), :b]) !=
              QuartoTools.content_hash([Symbol("col#2"), :b])
        @test QuartoTools.content_hash(Dict(Symbol("k#1") => 1)) !=
              QuartoTools.content_hash(Dict(Symbol("k#2") => 1))
        @test QuartoTools.content_hash(NamedTuple{(Symbol("c#1"),)}((1,))) !=
              QuartoTools.content_hash(NamedTuple{(Symbol("c#2"),)}((1,)))
    end

    @testset "a name lowering invented loses its counters" begin
        @test QuartoTools.normalize_symbol(Symbol("#foo##3")) === Symbol("#foo##")
        @test QuartoTools.normalize_symbol(Symbol("##x#12")) === Symbol("##x#")
        @test QuartoTools.normalize_symbol(Symbol("Item #1")) === Symbol("Item #1")
        @test QuartoTools.normalize_symbol(:plain2) === :plain2
    end
end

# A digest keeps the path of types it is part way through writing, so that a
# type reaching itself stops rather than recurses, and two tasks hashing at
# once must not see each other's path. Threads are what makes them overlap, so
# this runs in a process that has some.
@testset "concurrent hashing agrees with sequential hashing" begin
    script = """
    import QuartoTools

    struct Node
        child::Union{Node,Nothing}
    end

    make(n) = x -> x + n

    function subjects()
        return Any[
            Node(Node(nothing)),
            Node,
            Type{Node},
            make(1),
            make(2),
            typeof(make(1)),
            Tuple{Node,Vararg{Int}},
            Dict{Symbol,Node},
        ]
    end

    function agrees(rounds, tasks)
        values = subjects()
        expected = map(QuartoTools.content_hex, values)
        for _ = 1:rounds
            racing = [Threads.@spawn map(QuartoTools.content_hex, values) for _ = 1:tasks]
            all(fetch(task) == expected for task in racing) || return false
        end
        return Threads.nthreads() > 1
    end

    print(agrees(20, 8))
    """
    answered = read(
        `$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) -t 4 -e $script`,
        String,
    )
    @test answered == "true"
end

@testset "cross-process determinism" begin
    script = """
    import QuartoTools
    struct S
        a::__FIELDTYPE__
    end
    f(x) = x + 1
    print(QuartoTools.content_hex((S(1), f, [1, 2, 3], Dict("k" => :v))))
    """

    function digest(fieldtype)
        code = replace(script, "__FIELDTYPE__" => fieldtype)
        return read(
            `$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) -e $code`,
            String,
        )
    end

    a = digest("Int")
    b = digest("Int")
    c = digest("Float64")

    @test length(a) == 64
    # Identical definitions in separate processes agree.
    @test a == b
    # A changed field type changes the digest.
    @test a != c
end

end # module

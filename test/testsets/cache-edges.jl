module CacheEdgeTests

using Test

import QuartoTools

module Chain

scale = 2

struct Wrapper
    value::Int
end

inner(x) = x * scale
middle(x) = inner(x) + 1
outer(x) = middle(x) + Wrapper(x).value
unrelated(x) = x - 1

end # module

module Interfaces

struct Counter
    n::Int
end

Base.iterate(c::Counter, i = 1) = i > c.n ? nothing : (i, i + 1)
Base.length(c::Counter) = c.n
Base.eltype(::Type{Counter}) = Int

total(c::Counter) = sum(collect(c))

survey(c::Counter) = (
    sum(collect(c)),
    maximum(map(x -> x + 1, collect(c))),
    length(filter(iseven, collect(c))),
    sort(collect(c); rev = true),
    join(string.(collect(c)), ","),
)

end # module

module Unwritable

# A running task cannot be serialized, and a global holding one is what a REPL
# or a server leaves in a module the walk reaches.
task = current_task()

reads_task(x) = task === nothing ? x : x + 1

end # module

module Generations

value() = 1
caller(x) = value() + x

end # module

module Keywords

# Every keyword method in the system lives in one table, `Core.kwcall`'s, so a
# keyword call is where a walk can spill into code it never reaches.
target(x; scale = 2) = x * scale
caller(x) = target(x; scale = 3)
unrelated(; verbose = false) = verbose

end # module

module Dispatch

one_way(x) = x + 1
other_way(x) = x - 1
choose(flag) = flag ? one_way : other_way
run_chosen(flag, x) = choose(flag)(x)

end # module

include("cache-redefinition.jl")

names_of(defs) = Set(String(m.name) for m in defs.methods)

@testset "reachable definitions" begin
    defs = QuartoTools.reachable_definitions(Chain.outer, Tuple{Int})

    @testset "the whole call chain is reached" begin
        @test issubset(Set(["outer", "middle", "inner"]), names_of(defs))
    end

    @testset "untracked code is a boundary" begin
        @test all(m -> QuartoTools.is_tracked(m.module), defs.methods)
        @test !("+" in names_of(defs))
        @test !("sum" in names_of(defs))
    end

    @testset "referenced globals and types are recorded" begin
        @test GlobalRef(Chain, :scale) in defs.globals
        @test Chain.Wrapper in defs.types
    end

    @testset "methods reached only through foreign code are found" begin
        found =
            QuartoTools.reachable_definitions(Interfaces.total, Tuple{Interfaces.Counter})
        iterators = filter(m -> m.name === :iterate, found.methods)
        @test !isempty(iterators)
        @test all(m -> m.module === Interfaces, iterators)
    end

    @testset "a keyword call reaches its callee and nothing else" begin
        found = QuartoTools.reachable_definitions(Keywords.caller, Tuple{Int})
        @test "target" in names_of(found)
        @test !("unrelated" in names_of(found))
    end

    @testset "targets of a call that inference cannot resolve are found" begin
        found = QuartoTools.reachable_definitions(Dispatch.run_chosen, Tuple{Bool,Int})
        @test issubset(
            Set(["run_chosen", "choose", "one_way", "other_way"]),
            names_of(found),
        )
    end
end

@testset "dependency_digest" begin
    @testset "stable when nothing changes" begin
        a = QuartoTools.dependency_digest(Chain.outer, Tuple{Int})
        b = QuartoTools.dependency_digest(Chain.outer, Tuple{Int})
        @test a == b
        @test length(a) == 32
    end

    @testset "a change anywhere in the chain invalidates" begin
        before = QuartoTools.dependency_digest(Chain.outer, Tuple{Int})
        redefine(Chain, :(inner(x) = x * scale + 100))
        after = QuartoTools.dependency_digest(Chain.outer, Tuple{Int})
        @test before != after
    end

    @testset "a change outside the chain does not invalidate" begin
        before = QuartoTools.dependency_digest(Chain.outer, Tuple{Int})
        redefine(Chain, :(unrelated(x) = x - 999))
        @test before == QuartoTools.dependency_digest(Chain.outer, Tuple{Int})
    end

    @testset "a change reached only through foreign code invalidates" begin
        before = QuartoTools.dependency_digest(Interfaces.total, Tuple{Interfaces.Counter})
        redefine(
            Interfaces,
            :(Base.iterate(c::Counter, i = 1) = i > c.n ? nothing : (i, i + 2)),
        )
        @test before !=
              QuartoTools.dependency_digest(Interfaces.total, Tuple{Interfaces.Counter})
    end

    @testset "a repeated analysis reuses the frontier instead of re-inferring" begin
        argtypes = Tuple{Interfaces.Counter}
        QuartoTools.forget_analysis!()
        QuartoTools.analyse(Interfaces.survey, argtypes)

        # Inference is skipped wherever a signature's method lookup still gives
        # back the methods it gave before, which shows up as `resolve` handing
        # back the frontier it kept rather than building another one. Counting
        # that holds steady where timing the two analyses does not.
        signatures = collect(keys(QuartoTools.RESOLUTIONS))
        @test !isempty(signatures)
        @test all(signatures) do signature
            kept = QuartoTools.RESOLUTIONS[signature]
            return QuartoTools.resolve(signature) === kept
        end

        # A redefinition inside the frontier gives a different one back.
        redefine(Interfaces, :(Base.length(c::Counter) = c.n + 0))
        lengths = filter(signatures) do signature
            return any(m -> m.name === :length, QuartoTools.RESOLUTIONS[signature].methods)
        end
        @test !isempty(lengths)
        @test all(lengths) do signature
            kept = QuartoTools.RESOLUTIONS[signature]
            return QuartoTools.resolve(signature) !== kept
        end
    end

    @testset "a change to a referenced global invalidates" begin
        before = QuartoTools.dependency_digest(Chain.outer, Tuple{Int})
        @eval Chain scale = 7
        @test before != QuartoTools.dependency_digest(Chain.outer, Tuple{Int})
    end

    # Redefining a method leaves the one it replaced in its table. Counting
    # both put every edit of a session into the key, so returning a function to
    # what it said before never returned the key it had then.
    @testset "an earlier generation of a method leaves no trace" begin
        before = QuartoTools.dependency_digest(Generations.caller, Tuple{Int})
        redefine(Generations, :(value() = 2))
        @test before != QuartoTools.dependency_digest(Generations.caller, Tuple{Int})
        redefine(Generations, :(value() = 1))
        @test before == QuartoTools.dependency_digest(Generations.caller, Tuple{Int})
    end

    @testset "a keyword method nothing calls does not invalidate" begin
        before = QuartoTools.dependency_digest(Keywords.caller, Tuple{Int})
        redefine(Keywords, :(unrelated(; verbose = false) = !verbose))
        @test before == QuartoTools.dependency_digest(Keywords.caller, Tuple{Int})
    end

    # One global nothing can write used to cost the call its key, and with it
    # the cache. Its type stands in for it instead, and the warning says which
    # global gave up its value.
    @testset "a global that cannot be written keys on its type" begin
        digest =
            @test_logs (:warn, r"ignore_global!") match_mode = :any QuartoTools.dependency_digest(
                Unwritable.reads_task,
                Tuple{Int},
            )
        @test !isempty(digest)
        @test digest == QuartoTools.dependency_digest(Unwritable.reads_task, Tuple{Int})
    end
end

end # module

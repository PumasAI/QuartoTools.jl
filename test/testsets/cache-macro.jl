module CacheMacroTests

using Test

import QuartoTools
import Dates
import TOML
import Logging

# A cached call that returns a random number reveals whether it ran: a hit
# gives back the number the first call stored, a miss draws a new one.

dependency(x) = x + 1
unrelated(x) = x - 1

QuartoTools.@cache simple(x) = (dependency(x), rand())

QuartoTools.@cache function annotated(
    x::Integer,
    y::Integer = 2;
    scale::Real = 1,
    extras...,
)::Tuple
    return (x + y, scale, values(extras), rand())
end

QuartoTools.@cache generic(x::T, rest...) where {T<:Number} = (T, rest, rand())

QuartoTools.@cache anonymous(::Int, y) = (y, rand())

QuartoTools.@cache unhashable(x) = 1

QuartoTools.@cache unstorable(x) = (x, current_task())

# A result that carries a closure, which is what a value read back can bind to
# the wrong code.
QuartoTools.@cache closure_maker(x) = (y -> y + x)

# Two names that no directory can hold as written, so both are rewritten.
QuartoTools.@cache ⊕(x) = (x, rand())
QuartoTools.@cache ⊗(x) = (x, rand())

"""
    documented(x)

A cached definition carries its own documentation.
"""
QuartoTools.@cache documented(x) = (x, rand())

struct Weighted
    weight::Int
end

QuartoTools.@cache function (weighted::Weighted)(x; offset = 0)
    return (weighted.weight * x + offset, rand())
end

struct Anonymous end

QuartoTools.@cache (::Anonymous)(x) = (x, rand())

function with_cache_directory(body)
    mktempdir() do directory
        QuartoTools.cache_directory!(directory)
        try
            body(directory)
        finally
            QuartoTools.cache_directory!(nothing)
        end
    end
end

include("cache-redefinition.jl")

@testset "caching a definition" begin
    @testset "a repeated call is served from the cache" begin
        with_cache_directory() do directory
            @test simple(1) == simple(1)
            @test simple(1) != simple(2)
        end
    end

    @testset "results land on disk" begin
        with_cache_directory() do directory
            simple(1)
            entries = readdir(joinpath(directory, "simple"))
            @test any(endswith(".jls"), entries)
            @test any(endswith(".toml"), entries)
        end
    end

    @testset "keyword arguments, defaults, splats and constraints" begin
        with_cache_directory() do directory
            @test annotated(1) == annotated(1)
            @test annotated(1; scale = 2) == annotated(1; scale = 2)
            @test annotated(1; scale = 2) != annotated(1; scale = 3)
            @test annotated(1; a = 1) != annotated(1; a = 2)
            @test first(annotated(1, 5)) == 6

            @test generic(1.0, :a, :b) == generic(1.0, :a, :b)
            @test generic(1.0, :a) != generic(1, :a)
            @test first(generic(1.0)) === Float64

            @test anonymous(1, 2) == anonymous(1, 2)
            @test last(anonymous(1, 2)) != last(anonymous(1, 3))
        end
    end

    @testset "a docstring documents the definition" begin
        @test occursin(
            "A cached definition carries its own documentation.",
            string(Base.Docs.doc(documented)),
        )
    end
end

@testset "caching a callable object" begin
    @testset "the object takes part in the key" begin
        with_cache_directory() do directory
            @test Weighted(2)(3) == Weighted(2)(3)
            @test first(Weighted(2)(3)) == 6
            @test Weighted(2)(3) != Weighted(5)(3)
            @test Weighted(2)(3; offset = 1) != Weighted(2)(3; offset = 2)
        end
    end

    @testset "an object written without a name still caches" begin
        with_cache_directory() do directory
            @test Anonymous()(1) == Anonymous()(1)
            @test Anonymous()(1) != Anonymous()(2)
        end
    end
end

@testset "invalidation" begin
    @testset "a changed dependency invalidates" begin
        with_cache_directory() do directory
            before = simple(10)
            redefine(@__MODULE__, :(dependency(x) = x + 1000))
            @test before != Base.@invokelatest simple(10)
        end
    end

    @testset "an unrelated change does not invalidate" begin
        with_cache_directory() do directory
            before = simple(11)
            redefine(@__MODULE__, :(unrelated(x) = x - 1000))
            @test before == Base.@invokelatest simple(11)
        end
    end

    @testset "a changed body invalidates" begin
        with_cache_directory() do directory
            before = simple(12)
            redefine(
                @__MODULE__,
                :(QuartoTools.@cache simple(x) = (dependency(x), 0.5, rand())),
            )
            @test before != Base.@invokelatest simple(12)
        end
    end
end

@testset "opting out" begin
    @testset "a disabled cache always runs the call" begin
        with_cache_directory() do directory
            QuartoTools.disable!()
            try
                @test anonymous(3, 4) != anonymous(3, 4)
            finally
                QuartoTools.enable!()
            end
            @test anonymous(3, 4) == anonymous(3, 4)
        end
    end

    @testset "an uncacheable function always runs the call" begin
        with_cache_directory() do directory
            @eval QuartoTools.cacheable(::typeof(generic)) = false
            try
                @test Base.@invokelatest(generic(2.0)) != Base.@invokelatest(generic(2.0))
            finally
                redefine(@__MODULE__, :(QuartoTools.cacheable(::typeof(generic)) = true))
            end
        end
    end
end

@testset "failure leaves the result correct" begin
    @testset "an argument that cannot be hashed runs uncached" begin
        with_cache_directory() do directory
            result = @test_logs (:warn,) match_mode = :any unhashable(current_task())
            @test result == 1
        end
    end

    # An entry written by code that has since moved on can deserialize into
    # something unusable, and one that a killed process left behind can be
    # unreadable outright. Reading is never what fails the call.
    @testset "an entry that cannot be read is replaced" begin
        with_cache_directory() do directory
            stored = simple(30)
            entry = only(QuartoTools.entries()).path
            write(entry, "not a stored result")

            again = @test_logs (:warn,) match_mode = :any simple(30)
            @test again != stored
            # The unreadable file went, and the result that ran in its place is
            # what the next call reads.
            @test simple(30) == again
        end
    end

    # A session that redefines the code around a closure can give its name to a
    # different closure, and a value read back under that name is bound to code
    # it was never written from. The failure would otherwise surface wherever
    # the value is next called.
    @testset "an entry whose closures moved on is not served" begin
        with_cache_directory() do directory
            stored = closure_maker(2)
            @test stored(1) == 3

            entry = only(QuartoTools.entries())
            metadata = TOML.parsefile(QuartoTools.metadata_path(entry.path))
            metadata["closures"] = repeat("0", 64)
            open(
                io -> TOML.print(io, metadata; sorted = true),
                QuartoTools.metadata_path(entry.path),
                "w",
            )

            again = @test_logs (:warn,) match_mode = :any closure_maker(2)
            @test again(1) == 3
        end
    end

    @testset "a result that cannot be stored is still returned" begin
        with_cache_directory() do directory
            result = @test_logs (:warn,) match_mode = :any unstorable(1)
            @test first(result) == 1
        end
    end

    # A cached call inside a loop hits the same failure on every pass, and one
    # warning says what the ten thousandth would have said. `Test.TestLogger`
    # ignores `maxlog` before Julia 1.9, so this reads what a logger that
    # honours it wrote.
    @testset "the warning for a failure comes once" begin
        with_cache_directory() do directory
            recorded = IOBuffer()
            Logging.with_logger(Logging.SimpleLogger(recorded, Logging.Warn)) do
                for _ = 1:3
                    unhashable(current_task())
                    unstorable(1)
                end
            end
            written = String(take!(recorded))
            warned(pattern) = length(collect(eachmatch(pattern, written)))
            @test warned(r"Cannot key this call") == 1
            @test warned(r"Cannot store this result") == 1
        end
    end
end

@testset "clear!" begin
    with_cache_directory() do directory
        simple(20)
        @test !isempty(readdir(directory))
        QuartoTools.clear!()
        @test isempty(readdir(directory))
    end

    # A process killed between the write and the rename leaves the partial file
    # behind, and it is one of ours to remove rather than a reason to stop.
    @testset "a partial write left behind is cleared too" begin
        with_cache_directory() do directory
            simple(21)
            stored = only(QuartoTools.entries()).path
            touch("$(stored).writing")
            QuartoTools.clear!()
            @test isempty(readdir(directory))
        end
    end

    # A sweep confined to one function's results leaves another's alone, even
    # when neither name can be written as a directory.
    @testset "sweeping by name keeps another function's results" begin
        with_cache_directory() do directory
            ⊕(1)
            ⊗(1)
            @test length(QuartoTools.entries()) == 2

            @test QuartoTools.prune!(; name = "⊕", older_than = Dates.Millisecond(0)) == 1
            left = QuartoTools.entries()
            @test length(left) == 1
            @test only(left).name == "⊗"
        end
    end

    # Anything else in the directory is somebody's, so the directory stays.
    @testset "a directory holding anything else is left alone" begin
        with_cache_directory() do directory
            simple(22)
            stored = only(QuartoTools.entries()).path
            write(joinpath(dirname(stored), "notes.txt"), "mine")
            QuartoTools.clear!()
            @test isfile(stored)
        end
    end
end

@testset "results persist across processes" begin
    mktempdir() do directory
        script = """
        import QuartoTools
        QuartoTools.cache_directory!(raw"__DIRECTORY__")
        factor(x) = x * __FACTOR__
        QuartoTools.@cache measurement(x) = (factor(x), rand())
        print(last(measurement(3)))
        """
        script = replace(script, "__DIRECTORY__" => directory)

        function run_script(factor)
            code = replace(script, "__FACTOR__" => factor)
            return read(
                `$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) -e $code`,
                String,
            )
        end

        first_run = run_script("2")
        second_run = run_script("2")
        changed_dependency = run_script("3")

        @test !isempty(first_run)
        # A second process reads the stored result rather than drawing a new
        # number.
        @test first_run == second_run
        # Changing a function the cached definition calls invalidates the entry.
        @test first_run != changed_dependency
    end
end

end # module

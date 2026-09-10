module CacheCallSiteTests

using Test

import QuartoTools

step(x) = x + 1
scale(x; factor = 2) = x * factor

measure(x) = (step(x), rand())

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

@testset "caching a call" begin
    @testset "a repeated call is served from the cache" begin
        with_cache_directory() do directory
            first_call = QuartoTools.@cache measure(1)
            @test first_call == QuartoTools.@cache measure(1)
            @test first_call != QuartoTools.@cache measure(2)
        end
    end

    @testset "arguments are evaluated once" begin
        with_cache_directory() do directory
            evaluations = Ref(0)
            argument() = (evaluations[] += 1; 1)
            QuartoTools.@cache measure(argument())
            @test evaluations[] == 1
        end
    end

    @testset "keyword arguments and splats" begin
        with_cache_directory() do directory
            arguments = (3,)
            @test (QuartoTools.@cache scale(arguments...; factor = 2)) == 6
            @test (QuartoTools.@cache scale(3; factor = 4)) == 12
        end
    end

    @testset "a changed dependency invalidates" begin
        with_cache_directory() do directory
            before = QuartoTools.@cache measure(10)
            redefine(@__MODULE__, :(step(x) = x + 1000))
            @test before != QuartoTools.@cache measure(10)
        end
    end

    @testset "a qualified callee is cached under its own name" begin
        with_cache_directory() do directory
            value = QuartoTools.@cache Base.sum([1, 2, 3])
            @test value == 6
            @test isdir(joinpath(directory, "sum"))
        end
    end
end

end # module

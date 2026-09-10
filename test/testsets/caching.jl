@testset "caching.jl" begin
    cache_dir = joinpath(@__DIR__, ".cache")
    isdir(cache_dir) && rm(cache_dir; recursive = true)

    deps1 = QuartoTools.@cache Pkg.dependencies()

    result1 = QuartoTools.@cache rand(5)
    result2 = QuartoTools.@cache rand(5)
    @test result1 == result2

    sum1 = QuartoTools.@cache sum(result1)
    sum2 = QuartoTools.@cache sum(result2)
    @test sum1 == sum2

    # Each cached function has a directory of its own, holding a result and the
    # metadata beside it.
    cache_files = readdir(cache_dir)
    @test sort(cache_files) == ["dependencies", "rand", "sum"]
    @test length(QuartoTools.entries(cache_dir)) == 3

    deps2 = QuartoTools.@cache Pkg.dependencies()

    @test deps1 == deps2

    result3 = QuartoTools.@cache rand(5)
    result4 = QuartoTools.@cache rand(5)
    @test all((==)(result1), (result3, result4))

    @test cache_files == readdir(cache_dir)
end

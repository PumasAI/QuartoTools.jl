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

    cache_files = readdir(cache_dir)
    @test length(cache_files) == 6

    deps2 = QuartoTools.@cache Pkg.dependencies()

    @test deps1 == deps2

    result3 = QuartoTools.@cache rand(5)
    result4 = QuartoTools.@cache rand(5)
    @test all((==)(result1), (result3, result4))

    @test cache_files == readdir(cache_dir)
end

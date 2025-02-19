import QuartoNotebookRunner
using QuartoTools
using Test

@testset "Implicit caching" begin
    @testset "nc macro" begin
        nc`a` = 1
        @test nc`a` == 1
        @test a == 1
        @test nc`a` == a
    end

    @testset "expression transformation" begin
        withenv(QuartoTools.QT_CACHE => true) do
            # Transformations require LineNumberNodes, so this will not transform:
            ex = QuartoTools._transform_ast_cache(:(a = f(1)))
            @test ex == :(a = f(1))

            # `quote` includes LNNs:
            ex = QuartoTools._transform_ast_cache(quote
                a = f(1)
            end)
            fex = ex.args[2]
            @test fex != :(a = f(1))
            @test fex.args[1] == :a
            @test fex.args[2].args[1].args[1] == QuartoTools.Cached

            # assignments within functions are not cached:
            ex = QuartoTools._transform_ast_cache(quote
                function foo()
                    a = f(1)
                end
            end)
            fex = ex.args[2].args[end].args[end]
            @test fex == :(a = f(1))
        end
    end

    @testset "ignoring vars" begin
        for each in (:a, :(a, b), :(; a, b))
            @test QuartoTools.no_ignored_vars(each, Set{Symbol}([]))
            @test QuartoTools.no_ignored_vars(each, Set{Symbol}([:c]))
            @test !QuartoTools.no_ignored_vars(each, Set{Symbol}([:a]))
            @test !QuartoTools.no_ignored_vars(each, Set{Symbol}([:a, :b]))
        end
        # Non-Symbols or Exprs are always ignored regardless of ignore list.
        @test !QuartoTools.no_ignored_vars("a", Set{Symbol}([]))
        @test !QuartoTools.no_ignored_vars("a", Set{Symbol}([:a]))
    end

    @testset "QMD options" begin
        notebook_options(cache) =
            Dict("format" => Dict("metadata" => Dict("julia" => Dict("cache" => cache))))

        cell_options(cache) = Dict("julia" => Dict("cache" => cache))

        enabled, ignored = QuartoTools.__caching_options(
            notebook_options(Dict("enabled" => true, "ignored" => ["a", "b"])),
            cell_options(Dict("enabled" => true, "ignored" => ["a", "b"])),
        )
        @test enabled === true
        @test ignored == ["a", "b"]

        enabled, ignored = QuartoTools.__caching_options(
            notebook_options(Dict("enabled" => false, "ignored" => ["a", "b"])),
            cell_options(Dict("ignored" => ["a", "b"])),
        )
        @test enabled === false
        @test ignored == []

        enabled, ignored = QuartoTools.__caching_options(
            notebook_options(Dict("enabled" => true, "ignored" => ["a", "b"])),
            cell_options(Dict()),
        )
        @test enabled === true
        @test ignored == ["a", "b"]

        enabled, ignored = QuartoTools.__caching_options(
            notebook_options(Dict()),
            cell_options(Dict("enabled" => true, "ignored" => ["a", "b"])),
        )
        @test enabled === true
        @test ignored == ["a", "b"]

        enabled, ignored =
            QuartoTools.__caching_options(notebook_options(Dict()), cell_options(Dict()))
        @test enabled === false
        @test ignored == []
    end

    @testset "QNR integration" begin
        notebook_root = joinpath(@__DIR__, "..", "notebooks")
        cache_dir = joinpath(notebook_root, ".cache")
        isdir(cache_dir) && rm(cache_dir; force = true, recursive = true)
        s = QuartoNotebookRunner.Server()
        json = QuartoNotebookRunner.run!(s, joinpath(notebook_root, "implicit-caching.qmd"))

        @test isdir(cache_dir)

        a = json.cells[4]
        b = json.cells[6]
        c = json.cells[8]
        d = json.cells[10]

        @test a.outputs[1].data["text/plain"] == c.outputs[1].data["text/plain"]
        @test a.outputs[1].data["text/plain"] != b.outputs[1].data["text/plain"]
        @test a.outputs[1].data["text/plain"] != d.outputs[1].data["text/plain"]
    end
end

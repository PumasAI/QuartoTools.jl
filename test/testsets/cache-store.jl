module CacheStoreTests

using Test

import QuartoTools
import Dates

QuartoTools.@cache reading(x) = (x, rand())
QuartoTools.@cache counting(x) = (x + 1, rand())

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

stored_files(directory) = filter(endswith(".jls"), readdir(joinpath(directory, "reading")))

# Last use is the modification time of the entry, so a test that cares about
# the order entries were used sets it rather than waiting for the clock.
function set_last_used(path, when)
    file = Base.Filesystem.open(path, Base.Filesystem.JL_O_RDWR)
    try
        Base.Filesystem.futime(file, when, when)
    finally
        close(file)
    end
    return nothing
end

@testset "cache_directory" begin
    @testset "an override wins over the default" begin
        with_cache_directory() do directory
            @test QuartoTools.cache_directory() == directory
        end
    end

    @testset "the default sits beside the file holding the definition" begin
        site = QuartoTools.CallSite("f", @__MODULE__, @__FILE__, "digest")
        @test QuartoTools.site_directory(site) == joinpath(@__DIR__, ".cache")
    end

    @testset "a definition with an unwritable name still gets a directory" begin
        @test startswith(QuartoTools.path_component("+"), "_")
        @test QuartoTools.path_component("summarise") == "summarise"

        # Two names that write the same way would share a directory, and a
        # sweep by one of them would take the other's results with it.
        @test QuartoTools.path_component("+") != QuartoTools.path_component("*")
        @test QuartoTools.path_component("+") == QuartoTools.path_component("+")
    end

    # A definition caches beside its own file, which is not the working
    # directory of whatever loaded it, so the management functions cover both.
    @testset "management reaches a definition cached outside the working directory" begin
        mktempdir() do source
            file = joinpath(source, "analysis.jl")
            touch(file)
            site = QuartoTools.CallSite("summarising", @__MODULE__, file, "digest")
            mktempdir() do elsewhere
                cd(elsewhere) do
                    @test QuartoTools.cache_directory() != QuartoTools.site_directory(site)
                    @test QuartoTools.site_directory(site) in
                          QuartoTools.managed_directories()

                    QuartoTools.run_cached(site, sin, sin, (1.0,), NamedTuple())
                    @test isdir(joinpath(source, ".cache", "summarising"))

                    named(name) = filter(entry -> entry.name == name, QuartoTools.entries())
                    @test length(named("summarising")) == 1
                    @test [
                        group.name for group in QuartoTools.usage(named("summarising"))
                    ] == ["summarising"]
                    @test QuartoTools.prune!(;
                        name = "summarising",
                        older_than = Dates.Millisecond(0),
                    ) == 1
                    @test isempty(named("summarising"))
                end
            end
        end
    end
end

@testset "prune!" begin
    @testset "recent entries are kept" begin
        with_cache_directory() do directory
            reading(1)
            @test QuartoTools.prune!(; older_than = Dates.Day(1)) == 0
            @test length(stored_files(directory)) == 1
        end
    end

    @testset "entries older than the cutoff go" begin
        with_cache_directory() do directory
            reading(1)
            reading(2)
            @test QuartoTools.prune!(; older_than = Dates.Millisecond(0)) == 2
            @test isempty(stored_files(directory))
        end
    end

    @testset "keep retains the most recently used" begin
        with_cache_directory() do directory
            reading(1)
            sleep(0.01)
            reading(2)
            sleep(0.01)
            newest = reading(3)
            @test QuartoTools.prune!(; keep = 1) == 2
            @test length(stored_files(directory)) == 1
            # The survivor is the one used most recently.
            @test newest == reading(3)
        end
    end

    @testset "metadata goes with the entry it describes" begin
        with_cache_directory() do directory
            reading(1)
            QuartoTools.prune!(; older_than = Dates.Millisecond(0))
            @test isempty(readdir(joinpath(directory, "reading")))
        end
    end

    @testset "max_size drops the least recently used" begin
        with_cache_directory() do directory
            reading(1)
            reading(2)
            reading(3)
            found = QuartoTools.entries()
            for (index, entry) in enumerate(found)
                set_last_used(entry.path, time() - 100 * index)
            end
            oldest = last(found)
            budget = sum(entry -> entry.bytes, found) - oldest.bytes
            @test QuartoTools.prune!(; max_size = budget) == 1
            @test length(QuartoTools.entries()) == 2
            @test !isfile(oldest.path)
        end
    end

    @testset "max_size drops an entry that overruns the budget alone" begin
        with_cache_directory() do directory
            reading(1)
            entry = only(QuartoTools.entries())
            @test QuartoTools.prune!(; max_size = entry.bytes - 1) == 1
            @test isempty(QuartoTools.entries())
        end
    end

    @testset "a criterion given is the only one that applies" begin
        with_cache_directory() do directory
            reading(1)
            reading(2)
            reading(3)
            for entry in QuartoTools.entries()
                set_last_used(entry.path, time() - 60 * 24 * 3600)
            end
            # Asking to keep five hundred keeps all three, however old they are.
            @test QuartoTools.prune!(; keep = 500) == 0
            @test length(stored_files(directory)) == 3
            @test QuartoTools.prune!(; max_size = 1024^3) == 0
            @test length(stored_files(directory)) == 3
            # Naming no criterion falls back to dropping what has gone unused.
            @test QuartoTools.prune!() == 3
            @test isempty(stored_files(directory))
        end
    end

    @testset "a period is a span of seconds" begin
        @test QuartoTools.unused_span(Dates.Millisecond(0)) == 0
        @test QuartoTools.unused_span(Dates.Day(1)) == 86400
        # A calendar period has no fixed length, and a longer one is longer.
        @test QuartoTools.unused_span(Dates.Month(1)) >
              QuartoTools.unused_span(Dates.Day(27))
        @test QuartoTools.unused_span(Dates.Year(1)) >
              QuartoTools.unused_span(Dates.Month(1))
    end

    # A file is stamped at a finer resolution than `time()` reports, so an entry
    # stored moments ago carries a modification time a fraction ahead of the
    # reading taken after it. It has gone unused for no time at all, which is
    # what a sweep of no age at all is asking for.
    @testset "an entry cannot have been used in the future" begin
        @test QuartoTools.unused_for(1.0e9, 1.0e9) == 0
        @test QuartoTools.unused_for(1.0e9, 1.0e9 + 0.0004) == 0
        @test QuartoTools.unused_for(1.0e9, 1.0e9 - 3600) == 3600
    end

    @testset "an entry stamped ahead of the clock is still swept" begin
        with_cache_directory() do directory
            reading(1)
            stored = only(QuartoTools.entries()).path
            # Where the stamp is finer than the clock, an entry stored moments
            # ago lands ahead of the reading taken after it. Setting the stamp
            # forward puts that in reach of a platform whose clocks agree.
            set_last_used(stored, time() + 0.005)
            @test QuartoTools.prune!(; older_than = Dates.Millisecond(0)) == 1
            @test isempty(QuartoTools.entries())
        end
    end

    @testset "a calendar period is a cutoff like any other" begin
        with_cache_directory() do directory
            reading(1)
            set_last_used(only(QuartoTools.entries()).path, time() - 60 * 24 * 3600)
            @test QuartoTools.prune!(; older_than = Dates.Year(1)) == 0
            @test QuartoTools.prune!(; older_than = Dates.Month(1)) == 1
            @test isempty(stored_files(directory))
        end
    end

    @testset "name restricts the sweep to one function" begin
        with_cache_directory() do directory
            reading(1)
            counting(2)
            swept =
                QuartoTools.prune!(; name = "reading", older_than = Dates.Millisecond(0))
            @test swept == 1
            @test [entry.name for entry in QuartoTools.entries()] == ["counting"]
        end
    end
end

@testset "entries" begin
    @testset "one entry per stored result" begin
        with_cache_directory() do directory
            reading(1)
            counting(2)
            found = QuartoTools.entries()
            @test length(found) == 2
            @test Set(entry.name for entry in found) == Set(["reading", "counting"])
            @test all(entry -> isfile(entry.path), found)
            @test all(entry -> entry.bytes > 0, found)
            @test all(entry -> startswith(entry.result_type, "Tuple"), found)
            @test all(entry -> entry.mod == string(@__MODULE__), found)
        end
    end

    @testset "the most recently used comes first" begin
        with_cache_directory() do directory
            reading(1)
            reading(2)
            first_path, second_path = (entry.path for entry in QuartoTools.entries())
            set_last_used(first_path, time() - 100)
            set_last_used(second_path, time())
            @test [entry.path for entry in QuartoTools.entries()] == [second_path, first_path]
        end
    end

    @testset "an entry whose metadata is gone is still listed" begin
        with_cache_directory() do directory
            reading(1)
            rm(QuartoTools.metadata_path(only(QuartoTools.entries()).path))
            entry = only(QuartoTools.entries())
            @test entry.name == "reading"
            @test entry.result_type == ""
            @test entry.created === nothing
        end
    end

    @testset "a directory holding nothing gives nothing" begin
        with_cache_directory() do directory
            @test isempty(QuartoTools.entries())
        end
    end
end

@testset "usage" begin
    with_cache_directory() do directory
        reading(1)
        reading(2)
        counting(3)
        grouped = QuartoTools.usage()
        @test [group.name for group in grouped] == ["reading", "counting"]
        reading_usage = first(grouped)
        @test reading_usage.entries == 2
        @test reading_usage.bytes ==
              sum(entry.bytes for entry in QuartoTools.entries() if entry.name == "reading")
        @test reading_usage.oldest <= reading_usage.newest

        # Grouping a list of entries covers part of a directory.
        picked = filter(entry -> entry.name == "counting", QuartoTools.entries())
        @test [group.name for group in QuartoTools.usage(picked)] == ["counting"]
    end
end

@testset "drop!" begin
    with_cache_directory() do directory
        reading(1)
        entry = only(QuartoTools.entries())
        @test QuartoTools.drop!(entry)
        @test isempty(QuartoTools.entries())
        @test !isfile(QuartoTools.metadata_path(entry.path))
        # Dropping what has already gone reports that there was nothing to do.
        @test !QuartoTools.drop!(entry)
    end
end

end # module

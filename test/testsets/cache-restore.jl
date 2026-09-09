module CacheRestoreTests

using Test

import QuartoTools
import Serialization

# `Serialization` cannot look a gensym-named type up by name, so a stored value
# holding a closure comes back as an instance of a type it rebuilds under a
# module of its own. A cache key that changed because of that would recompute
# and store a second entry on the first call that read the first entry back.

@testset "restored values" begin
    @testset "the module holding rebuilt types is tracked" begin
        @test QuartoTools.is_tracked(Serialization.__deserialized_types__)
    end

    @testset "a restored value keys the same as a live one" begin
        mktempdir() do directory
            script = """
            import QuartoTools

            QuartoTools.cache_directory!(raw"__DIRECTORY__")

            module Held
            struct Box{F}
                transform::F
            end
            # `map` dispatches on the closure, so the walk reaches it only
            # through the type of the box.
            apply(box::Box, values) = sum(map(box.transform, values))
            end

            QuartoTools.@cache build(factor) = Held.Box(x -> x * factor)

            box = build(3)
            argtypes = Tuple{typeof(box),Vector{Int}}
            print(bytes2hex(QuartoTools.dependency_digest(Held.apply, argtypes)))
            """
            script = replace(script, "__DIRECTORY__" => directory)

            function run_script()
                return read(
                    `$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) -e $script`,
                    String,
                )
            end

            # The first process builds the box and stores it. The second reads
            # that entry back, so its box carries a rebuilt type.
            live = run_script()
            restored = run_script()

            @test !isempty(live)
            @test live == restored
        end
    end
end

end # module

import Pkg

# For local development when QuartoNotebookRunner local changes need to be
# tested.
function develop(path)
    if isdir(path)
        Pkg.develop(Pkg.PackageSpec(; path))
    else
        @warn "Directory does not exist" path
    end
end
develop(joinpath(@__DIR__, "..", "..", "QuartoNotebookRunner"))

function instantiate(project)
    if isdir(project)
        script = joinpath(@__DIR__, "instantiate.jl")
        run(`$(Base.julia_cmd()) --project=$(project) $(script)`)
    else
        error("Project directory not found: $project")
    end
end
instantiate(joinpath(@__DIR__, "notebooks", "environments", "QuartoToolsEnv"))
instantiate(joinpath(@__DIR__, "notebooks", "environments", "Serialize"))

import QuartoTools
import QuartoNotebookRunner

using Test

@testset "QuartoTools" begin
    include("testsets/serialization.jl")
    include("testsets/caching.jl")
    include("testsets/implicit-caching.jl")
    include("testsets/expandables.jl")
    include("testsets/reading-time.jl")
end

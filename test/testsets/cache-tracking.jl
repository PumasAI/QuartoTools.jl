module CacheTrackingTests

using Test

import QuartoTools
import Serialization

module Vendored end

# The project is read afresh whenever the sum of the two mtimes changes, so the
# stamp is set rather than waited for.
function set_mtime(path, when)
    file = Base.Filesystem.open(path, Base.Filesystem.JL_O_RDWR)
    try
        Base.Filesystem.futime(file, when, when)
    finally
        close(file)
    end
    return nothing
end

# A package outside the active project, ready to be named by its manifest.
function outside_package(directory, name, uuid)
    package = joinpath(directory, name)
    mkpath(joinpath(package, "src"))
    write(
        joinpath(package, "Project.toml"),
        """
        name = "$(name)"
        uuid = "$(uuid)"
        version = "0.1.0"
        """,
    )
    write(joinpath(package, "src", "$(name).jl"), "module $(name)\nend\n")
    push!(LOAD_PATH, directory)
    try
        return Base.require(Main, Symbol(name))
    finally
        pop!(LOAD_PATH)
    end
end

@testset "the default boundary" begin
    @testset "code pinned by VERSION is not tracked" begin
        @test !QuartoTools.is_tracked(Base)
        @test !QuartoTools.is_tracked(Core)
        @test !QuartoTools.is_tracked(Base.Iterators)
        if isdefined(Base, :Compiler)
            # A module with a package identity and no source cannot change.
            @test !QuartoTools.is_tracked(Base.Compiler)
        end
    end

    @testset "code pinned by the manifest is not tracked" begin
        @test !QuartoTools.is_tracked(QuartoTools.Preferences)
    end

    @testset "the package does not track itself" begin
        @test !QuartoTools.is_tracked(QuartoTools)
    end

    @testset "code being worked on is tracked" begin
        @test QuartoTools.is_tracked(Main)
        @test QuartoTools.is_tracked(@__MODULE__)
        @test QuartoTools.is_tracked(Vendored)
    end

    # A package loaded from somewhere else on the load path, a development tool
    # in a shared environment being the usual one, can reach cached code by
    # replacing something it uses. `stdout` is how that happens in practice.
    # Its own state decides nothing about a result, so the walk stops there.
    @testset "a package the project does not depend on is not tracked" begin
        mktempdir() do directory
            outside = outside_package(
                directory,
                "OutsideTheProject",
                "6f0a1c3e-9d4b-4e2a-8f77-1c0a5b3d2e64",
            )
            @test !QuartoTools.is_tracked(outside)
        end
    end

    # The decision is kept per root module, and a manifest that gains a
    # dependency mid-session moves the boundary. The decision moves with it.
    @testset "a package the project gains becomes tracked" begin
        mktempdir() do directory
            name = "AddedToTheProject"
            uuid = "5b1d6e02-7a3c-4f18-9e55-2d0b8c4a1f37"
            added = outside_package(directory, name, uuid)

            environment = joinpath(directory, "environment")
            mkpath(environment)
            write(joinpath(environment, "Project.toml"), "")
            manifest = joinpath(environment, "Manifest.toml")
            write(manifest, "manifest_format = \"2.0\"\n")

            previous = Base.ACTIVE_PROJECT[]
            Base.ACTIVE_PROJECT[] = joinpath(environment, "Project.toml")
            try
                @test !QuartoTools.is_tracked(added)

                write(
                    manifest,
                    """
                    manifest_format = "2.0"

                    [[deps.$(name)]]
                    uuid = "$(uuid)"
                    version = "0.1.0"
                    """,
                )
                set_mtime(manifest, mtime(manifest) + 10)
                @test QuartoTools.is_tracked(added)
            finally
                Base.ACTIVE_PROJECT[] = previous
                QuartoTools.reset_tracking!()
            end
        end
    end
end

@testset "overrides" begin
    @testset "a submodule can be excluded on its own" begin
        QuartoTools.untrack!(Vendored)
        try
            @test !QuartoTools.is_tracked(Vendored)
            # Its neighbours are unaffected.
            @test QuartoTools.is_tracked(@__MODULE__)
        finally
            QuartoTools.reset_tracking!()
        end
        @test QuartoTools.is_tracked(Vendored)
    end

    @testset "a package can be included" begin
        QuartoTools.track!(QuartoTools.Preferences)
        try
            @test QuartoTools.is_tracked(QuartoTools.Preferences)
        finally
            QuartoTools.reset_tracking!()
        end
        @test !QuartoTools.is_tracked(QuartoTools.Preferences)
    end

    @testset "the module holding rebuilt types is tracked" begin
        # Reading a stored closure rebuilds its type under a module of
        # `Serialization`'s own. The code such a type carries is not a standard
        # library's, so a call over a restored value keys like the live one.
        @test QuartoTools.is_tracked(Serialization.__deserialized_types__)
    end
end

end # module

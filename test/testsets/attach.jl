@testset "attach discovery" begin
    qnr_uuid = "4c0109c6-14e9-4c88-93f0-2b974d3468f4"

    # A minimal on-disk layout that looks like a QuartoNotebookRunner package:
    # the UUID in its Project.toml plus a `src/QuartoNotebookWorker/Project.toml`.
    function make_fake_runner(dir)
        mkpath(joinpath(dir, "src", "QuartoNotebookWorker"))
        write(
            joinpath(dir, "Project.toml"),
            "name = \"QuartoNotebookRunner\"\nuuid = \"$qnr_uuid\"\nversion = \"0.0.0\"\n",
        )
        touch(joinpath(dir, "src", "QuartoNotebookRunner.jl"))
        touch(joinpath(dir, "src", "QuartoNotebookWorker", "Project.toml"))
        return dir
    end

    # `runner` points straight at the package directory.
    mktempdir() do dir
        qnr = make_fake_runner(joinpath(dir, "QNR"))
        @test QuartoTools._worker_source(qnr) ==
              joinpath(qnr, "src", "QuartoNotebookWorker")
    end

    # `runner` points at an environment that declares QuartoNotebookRunner.
    mktempdir() do dir
        qnr = make_fake_runner(joinpath(dir, "QNR"))
        env = joinpath(dir, "env")
        mkpath(env)
        Pkg.activate(() -> Pkg.develop(Pkg.PackageSpec(path = qnr)), env)
        @test QuartoTools._worker_source(env) ==
              joinpath(qnr, "src", "QuartoNotebookWorker")
    end

    # Auto-discovery resolves QUARTO_JULIA_PROJECT.
    mktempdir() do dir
        qnr = make_fake_runner(joinpath(dir, "QNR"))
        env = joinpath(dir, "env")
        mkpath(env)
        Pkg.activate(() -> Pkg.develop(Pkg.PackageSpec(path = qnr)), env)
        withenv("QUARTO_JULIA_PROJECT" => env) do
            @test QuartoTools._worker_source(nothing) ==
                  joinpath(qnr, "src", "QuartoNotebookWorker")
        end
    end

    # A clear error when nothing resolves.
    @test_throws ErrorException QuartoTools._worker_source(joinpath(mktempdir(), "nope"))
end

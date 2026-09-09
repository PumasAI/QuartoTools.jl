module CacheInterfaceTests

using Test

import QuartoTools

module Globals

setting = 1
const buffer = [1, 2, 3]

combine(x) = x * setting + sum(buffer)

end # module

mutable struct Handle
    url::String
    live::Bool
end

QuartoTools.deconstruct(handle::Handle) = ("handle", handle.url)
QuartoTools.reconstruct(pair::Tuple{String,String}) = Handle(pair[2], true)

QuartoTools.@cache reads_globals(x) = (Globals.combine(x), rand())
QuartoTools.@cache opens(handle::Handle) = (handle.url, rand())
QuartoTools.@cache returns_handle(url) = Handle(url, true)
QuartoTools.@cache declares_dependency(x) = (x, rand())

const EXTRA = Ref(1)
QuartoTools.dependencies(::typeof(declares_dependency)) = (EXTRA[],)

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

@testset "globals" begin
    @testset "assigning to a global invalidates" begin
        with_cache_directory() do directory
            before = reads_globals(1)
            @eval Globals setting = 5
            @test before != reads_globals(1)
        end
    end

    @testset "mutating a constant global invalidates" begin
        with_cache_directory() do directory
            before = reads_globals(2)
            push!(Globals.buffer, 4)
            @test before != reads_globals(2)
            pop!(Globals.buffer)
        end
    end

    @testset "an ignored global stops taking part" begin
        with_cache_directory() do directory
            QuartoTools.ignore_global!(Globals, :setting)
            try
                before = reads_globals(3)
                @eval Globals setting = 99
                @test before == Base.@invokelatest reads_globals(3)
            finally
                QuartoTools.watch_global!(Globals, :setting)
            end
        end
    end
end

@testset "deconstruct and reconstruct" begin
    @testset "an argument is keyed by what it deconstructs to" begin
        with_cache_directory() do directory
            first_handle = Handle("postgres://example", true)
            second_handle = Handle("postgres://example", false)
            # `live` is process-local state that `deconstruct` drops, so both
            # handles key alike.
            @test opens(first_handle) == opens(second_handle)
            @test opens(first_handle) != opens(Handle("postgres://other", true))
        end
    end

    @testset "a result round-trips through reconstruct" begin
        with_cache_directory() do directory
            stored = returns_handle("postgres://example")
            loaded = returns_handle("postgres://example")
            @test loaded isa Handle
            @test loaded.url == stored.url
        end
    end
end

@testset "dependencies" begin
    @testset "a declared dependency takes part in the key" begin
        with_cache_directory() do directory
            before = declares_dependency(1)
            EXTRA[] = 2
            @test before != declares_dependency(1)
        end
    end
end

# Code in a notebook is evaluated inside a submodule of `Main`, while the same
# code in a script is evaluated in `Main` itself. Mapping the two modules onto
# each other lets one read what the other wrote.

# A notebook is recognised by the modules its worker puts in `Main`, and the
# default `storage_module` and `runtime_module` do the mapping, so neither
# script below defines a hook of its own.

const IN_NOTEBOOK = """
import QuartoTools
QuartoTools.cache_directory!(raw"__DIRECTORY__")
module NotebookInclude end
module Notebook
import QuartoTools
struct Reading
    value::Int
end
QuartoTools.@cache measure(x) = (Reading(x * 2), rand())
end
print(last(Main.Notebook.measure(3)))
"""

const IN_SCRIPT = """
import QuartoTools
QuartoTools.cache_directory!(raw"__DIRECTORY__")
struct Reading
    value::Int
end
QuartoTools.@cache measure(x) = (Reading(x * 2), rand())
print(last(measure(3)))
"""

function run_script(source, directory)
    code = replace(source, "__DIRECTORY__" => directory)
    return read(
        `$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) -e $code`,
        String,
    )
end

@testset "module mapping" begin
    @testset "a script reads what a notebook wrote" begin
        mktempdir() do directory
            written = run_script(IN_NOTEBOOK, directory)
            @test !isempty(written)
            @test run_script(IN_SCRIPT, directory) == written
        end
    end

    @testset "a notebook reads what a script wrote" begin
        mktempdir() do directory
            written = run_script(IN_SCRIPT, directory)
            @test !isempty(written)
            @test run_script(IN_NOTEBOOK, directory) == written
        end
    end
end

end # module

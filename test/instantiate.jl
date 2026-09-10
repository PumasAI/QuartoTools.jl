pushfirst!(LOAD_PATH, "@stdlib")
import Pkg
popfirst!(LOAD_PATH)

# The package under test, plus any path given on the command line.
paths = [joinpath(@__DIR__, ".."); ARGS]
Pkg.develop([Pkg.PackageSpec(; path) for path in paths])
Pkg.precompile()

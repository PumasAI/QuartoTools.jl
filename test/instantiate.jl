pushfirst!(LOAD_PATH, "@stdlib")
import Pkg
popfirst!(LOAD_PATH)

Pkg.develop(Pkg.PackageSpec(; path = joinpath(@__DIR__, "..")))
Pkg.precompile()

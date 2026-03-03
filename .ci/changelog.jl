import Pkg
Pkg.instantiate()
import Changelog

cd(dirname(@__DIR__)) do
    Changelog.generate(
        Changelog.CommonMark(),
        "CHANGELOG.md";
        repo = "PumasAI/QuartoTools.jl",
    )
end

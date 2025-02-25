default:
    just -l

changelog:
    julia --project=.ci .ci/changelog.jl

docs:
    julia --project=docs docs/make.jl

format:
    julia --project=.ci .ci/format.jl

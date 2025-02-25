using Documenter
using QuartoTools

makedocs(sitename = "QuartoTools", format = Documenter.HTML(), modules = [QuartoTools])

deploydocs(repo = "github.com/PumasAI/QuartoTools.jl.git", push_preview = true)

@testset "serialization.jl" begin
    server = QuartoNotebookRunner.Server()
    json = QuartoNotebookRunner.run!(
        server,
        joinpath(@__DIR__, "..", "notebooks", "serialization.qmd"),
    )

    cell = json.cells[8]
    @test cell.outputs[1].data["text/plain"] == "1"

    cell = json.cells[10]
    @test contains(cell.outputs[1].data["text/plain"], "DataFrame")

    cell = json.cells[12]
    @test !isempty(cell.outputs[1].data["image/png"])

    text = json.cells[16].outputs[1].text
    @test contains(text, "is_func = true")
    @test contains(text, "is_df = true")
    @test contains(text, "is_fig = true")
end

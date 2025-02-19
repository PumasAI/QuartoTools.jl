@testset "expandables.jl" begin
    server = QuartoNotebookRunner.Server()
    json = QuartoNotebookRunner.run!(
        server,
        joinpath(@__DIR__, "..", "notebooks", "expandables.qmd"),
    )

    cells = json.cells

    @test cells[5].source[1] == "#| some_option: true\n"
    @test cells[5].outputs[1].data["text/plain"] == "123"

    test_asis_no_echo(cell) =
        @test cell.source == ["#| output: \"asis\"\n", "#| echo: false\n"]
    test_no_echo(cell) = @test cell.source == ["#| echo: false\n"]
    markdown(cell) = cell.outputs[1].data["text/markdown"]
    plaintext(cell) = cell.outputs[1].data["text/plain"]

    test_asis_no_echo(cells[8])
    @test markdown(cells[8]) == "::: {#someid .classA .classB somekey=\"somevalue\"}"

    test_no_echo(cells[9])
    @test plaintext(cells[9]) == "123"

    test_asis_no_echo(cells[10])
    @test markdown(cells[10]) == ":::"

    test_asis_no_echo(cells[13])
    @test markdown(cells[13]) == "::: {.panel-tabset}"

    test_asis_no_echo(cells[14])
    @test markdown(cells[14]) == "# Tab1"

    test_no_echo(cells[15])
    @test plaintext(cells[15]) == "123"

    test_asis_no_echo(cells[16])
    @test markdown(cells[16]) == "# Tab2"

    test_asis_no_echo(cells[17])
    @test markdown(cells[17]) == "hello"

    test_asis_no_echo(cells[18])
    @test markdown(cells[18]) == ":::"

    test_asis_no_echo(cells[21])
    @test markdown(cells[21]) == "one"

    test_asis_no_echo(cells[22])
    @test markdown(cells[22]) == "two"
end

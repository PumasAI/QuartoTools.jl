@testset "reading-time" begin
    html = sprint(show, "text/html", QuartoTools.reading_time())
    @test contains(html, "minute reading time.")
    html = sprint(
        show,
        "text/html",
        QuartoTools.reading_time(;
            reading_time_template = minutes ->
                "This should take you $minutes minutes to read.",
        ),
    )
    @test contains(html, "This should take you")
end

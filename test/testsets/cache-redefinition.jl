# Several tests replace a method to show that the cache notices. A runtime
# asked to report an overwrite writes that report to stderr, which the `Pkg`
# shipped with Julia 1.10 and later asks for and older ones do not. Capturing
# it keeps the test output clean, and checking it, where it was asked for,
# confirms the definition landed on the method the test means to change instead
# of adding a second one alongside it.

function redefine(target, definition)
    report = mktemp() do path, io
        redirect_stderr(io) do
            Core.eval(target, definition)
            # The runtime queues its report on whichever stream is `stderr` at
            # the time, so it has to go out before the redirect is restored.
            flush(stderr)
        end
        read(path, String)
    end
    if Base.JLOptions().warn_overwrite == 1
        @test occursin("overwritten", report)
    end
    return nothing
end

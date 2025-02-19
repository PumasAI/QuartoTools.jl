
"""
    struct Cell

    Cell(content::Function; code = nothing, options = Dict{String,Any}(), lazy = true)
    Cell(content; code = nothing, options = Dict{String,Any}(), lazy = false)

The most basic expandable object, representing a single code cell with output.

If `code === nothing`, the code cell will be hidden by default using the quarto
option `echo: false`. Note that `code` is never evaluated, merely displayed in
code cell style.  Only `content` determines the actual cell output.

All `options` are written into the YAML options header of the code cell, this
way you can use any cell option commonly available in code cells for your
generated cells. For example, `options = Dict("echo" => false)` will splice `#|
echo: false` into the code cell's options header.

If `lazy === true`, the `output` will be treated as a thunk, which has to be
executed by QuartoNotebookRunner to get the actual output object that should
have `display` called on it. Accordingly, you will get an error if the `output`
object is not a `Base.Callable`. If `lazy === false`, the `output` will be used
as the actual output object directly by QuartoNotebookRunner. As an example, if
you generate a hundred plot output cells, it is probably better to generate the
plots using lazy functions, rather than storing all of them in memory at once.
The `lazy` option is set to `true` by default when a `Function` is passed to the
convenience constructor, and to `false` otherwise.
"""
struct Cell
    thunk::Base.Callable
    code::Union{Nothing,String}
    options::Dict{String,Any}

    function Cell(
        content;
        code::Union{Nothing,AbstractString} = nothing,
        options::Dict = Dict(),
        lazy::Bool = isa(content, Function),
    )
        if lazy && !(content isa Base.Callable)
            throw(
                ArgumentError(
                    "`lazy = true` cannot be set because `output` is not a `Base.Callable` but `$(typeof(content))`",
                ),
            )
        end
        return new(lazy ? content : Returns(content), code, options)
    end
end

"""
    struct Div

    Div(children::Vector; id=[], class=[], attributes=Dict())
    Div(child; kwargs...)

Construct a `Div` which is an expandable that wraps its child cells with two
markdown fence cells to create a pandoc div using `:::` as the fence delimiters.
`Div` optionally allows to specify one or more ids, classes and key-value
attributes for the div.

`id` and `class` should each be either one `AbstractString` or an
`AbstractVector` of those. `attributes` should be convertible to a
`Dict{String,String}`.

## Examples

```julia
Div(Cell(123))
Div(
    [Cell(123), Cell("ABC")];
    id = "someid",
    class = ["classA", "classB"],
    attributes = Dict("somekey" => "somevalue"),
)
```
"""
struct Div
    children::Vector
    id::Vector{String}
    class::Vector{String}
    attributes::Dict{String,String}

    function Div(children::Vector; id = [], class = [], attributes = Dict())
        id = id isa AbstractString ? String[id] : id
        class = class isa AbstractString ? String[class] : class
        return new(children, id, class, attributes)
    end
    Div(child; kwargs...) = Div([child]; kwargs...)
end

"""
    struct Expand

    Expand(expandables::AbstractVector)

Construct an `Expand` which is an expandable that wraps a vector of other
expandable. This allows to create multiple output cells using a single return
value in an expanded quarto cell.

## Example

```julia
Expand([Cell(123), Cell("ABC")])
```
"""
struct Expand
    children::Vector
end

"""
    struct Tabset

    Tabset(pairs; group = nothing)

Construct a `Tabset` which is an expandable that expands into multiple cells
representing one quarto tabset (using the `::: {.panel-tabset}` syntax).

`pairs` should be convertible to a `Vector{Pair{String,Any}}`. Each `Pair` in
`pairs` describes one tab in the tabset. The first element in the pair is its
title and the second element its content.

You can optionally pass some group id as a `String` to the `group` keyword which
enables quarto's grouped tabset feature where multiple tabsets with the same id
are switched together.

## Example

```julia
Tabset([
    "Tab 1" => Cell(123),
    "Tab 2" => Cell("ABC")
])
```
"""
struct Tabset
    tabs::Vector{Pair{String,Any}}
    group::Union{Nothing,String}

    Tabset(tabs::Vector; group = nothing) = new(tabs, group)
end

struct Markdown
    s::String
end

Base.show(io::IO, ::MIME"text/markdown", m::Markdown) = print(io, m.s)

"""
    MarkdownCell(s::String)

A convenience function which constructs a `Cell` that will be rendered by quarto
with the `output: asis` option. The string `s` will be interpreted as markdown
syntax, so the output will look as if `s` had been written into the quarto
notebook's markdown source directly.
"""
MarkdownCell(s::String) = Cell(Markdown(s); options = Dict("output" => "asis"))

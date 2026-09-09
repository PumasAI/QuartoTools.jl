# Which module a stored result belongs to.
#
# Julia's serialization records a value's type by module and name, and a cache
# key records the module a call was made from, so the same source evaluated in
# two places has to agree on one name for that place. A notebook evaluates in a
# module of its own and a script evaluates in `Main`, and both sides of that
# mapping run through here: the pair below decides what a stored entry records
# and what this process reads it back as.

"""
    storage_module(mod::Module) -> Module

The module to record in place of `mod` when storing a result or keying a call.

A notebook evaluates its cells in a module of its own, and a script evaluates
in `Main`, which on its own is enough to stop one from reading what the other
wrote. The default maps a notebook's module onto `Main` so that the two agree.
Override it to map another pair of modules onto each other, and pair every
mapping with the inverse in [`runtime_module`](@ref):

```julia
QuartoTools.storage_module(m::Module) = m === Main.Analysis ? Main : m
QuartoTools.runtime_module(m::Module) = m === Main ? Main.Analysis : m
```
"""
function storage_module(mod::Module)
    return mod === notebook_module() ? Main : mod
end

"""
    runtime_module(mod::Module) -> Module

The module to use in this process in place of the `mod` that was recorded when
a result was stored. The inverse of [`storage_module`](@ref), and the default
maps `Main` back onto the module a notebook evaluates in.
"""
function runtime_module(mod::Module)
    mod === Main || return mod
    notebook = notebook_module()
    return notebook === nothing ? Main : notebook
end

"""
    notebook_module() -> Union{Module,Nothing}

The module a notebook evaluates its cells in, or `nothing` outside one.
"""
function notebook_module()
    mod = _notebook_module()
    mod === nothing || return mod
    # The older worker gives no module to ask for, and names it instead.
    isdefined(Main, :Notebook) && isa(Main.Notebook, Module) && return Main.Notebook
    return nothing
end

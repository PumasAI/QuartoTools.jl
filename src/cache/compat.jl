# Differences between the Julia versions this package supports.
#
# Each shim carries the version that made it unnecessary, so that a later
# raise of the floor in `Project.toml` says which of these can go.

# `Base.ismutabletype` arrived in 1.7.
if isdefined(Base, :ismutabletype)
    is_mutable_type(@nospecialize(T)) = Base.ismutabletype(T)
else
    is_mutable_type(@nospecialize(T)) = isa(T, DataType) && T.mutable
end

# `Core.TypeofVararg` arrived in 1.7. Before it, a `Vararg` in a signature is
# an ordinary `UnionAll` over `Vararg{T,N}`, which the type walk already
# descends, so nothing needs to match on it.
if isdefined(Core, :TypeofVararg)
    is_vararg(@nospecialize(T)) = isa(T, Core.TypeofVararg)
else
    is_vararg(@nospecialize(T)) = false
end

# `getglobal` arrived in 1.9. Before it, reading a global went through
# `getfield` on the module.
if isdefined(Base, :getglobal)
    get_global(mod::Module, name::Symbol) = getglobal(mod, name)
else
    get_global(mod::Module, name::Symbol) = getfield(mod, name)
end

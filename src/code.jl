module Code

export toexpr, Assignment, (←), Let, Func, DeStructArgs,
       SetArray, MakeArray, MakeSparseArray, MakeTuple

import ..SymbolicUtils
import SymbolicUtils: @matchable, Sym, Term, istree, operation, arguments

##== state management ==##

struct NameState
    symbolify::Set
    destructed_args::Dict
end
NameState() = NameState(Set{Any}(), IdDict())

struct LazyState
    ref::Ref{Any}
end
LazyState() = LazyState(Ref{Any}(nothing))

function Base.get(st::LazyState)
    s = getfield(st, :ref)[]
    s === nothing ? getfield(st, :ref)[] = NameState() : s
end

@inline Base.getproperty(st::LazyState, f::Symbol) = getproperty(get(st), f)

##========================##

toexpr(x) = toexpr(x, LazyState())
toexpr(s::Sym, st) = nameof(s)
toexpr(x, st) = x

@matchable struct Assignment
    lhs
    rhs
end

const (←) = Assignment

Base.convert(::Type{Assignment}, p::Pair) = Assignment(pair[1], pair[2])

toexpr(a::Assignment, st) = :($(toexpr(a.lhs, st)) = $(toexpr(a.rhs, st)))

function toexpr(O, st)
    !istree(O) && return O
    op = operation(O)
    args = arguments(O)
    if op === (^) && length(args) == 2 && args[2] isa Number && args[2] < 0
        ex = args[1]
        if args[2] == -1
            return toexpr(Term{Any}(inv, [ex]), st)
        else
            return toexpr(Term{Any}(^, [Term{Any}(inv, [ex]), -args[2]]), st)
        end
    elseif op === (SymbolicUtils.cond)
        return :($(toexpr(args[1], st)) ? $(toexpr(args[2], st)) : $(toexpr(args[3], st)))
    elseif op isa Sym && O in st.symbolify
        return Symbol(string(O))
    end
    return Expr(:call, toexpr(op, st), map(x->toexpr(x, st), args)...)
end

@matchable struct Let
    pairs::Vector{Assignment} # an iterator of pairs, ordered
    body
end

function toexpr(l::Let, st)
    assignments = Expr(:block,
                       [:($k = $v) for (k, v) in l.pairs]...)

    Expr(:let, assignments, toexpr(l.expr, st))
end

### Experimental
@matchable struct BasicBlock
    pairs::Vector{Assignment} # Iterator of ordered pairs
    # TODO: check uniqueness of LHS on construction
end

function toexpr(l::BasicBlock, st)
    stmts = [:($(toexpr(k, st)) = $(toexpr(v, st))) for (k, v) in l.pairs]
    Expr(:block, stmts)
end

# Call elements of vector arguments by their name.
@matchable struct DeStructArgs
    elems
end

function toexpr(args::DeStructArgs, st)
    st.destructed_args[args] = gensym("arg")
end

@matchable struct Func
    args
    kwargs
    body
end

function toexpr(f::Func, st)
    quote
        function ($(map(x->toexpr(x, st), f.args)...),; $(map(x->toexpr(x, st), f.kwargs)...))
            $(toexpr(f.body, st))
        end
    end
end


@matchable struct SetArray
    inbounds::Bool
    arr::Sym
    elems  # Either iterator of Pairs or just an iterator
end

@matchable struct AtIndex
    i::Int
    elem
end

function toexpr(a::AtIndex, st)
    toexpr(a.elem, st)
end

function toexpr(s::SetArray, st)
    ex = quote
        $([:($(toexpr(s.arr, st))[$(ex isa AtIndex ? ex.i : i)] = $(toexpr(ex, st)))
           for (i, ex) in enumerate(s.elems)]...)
        nothing
    end
    s.inbounds ? :(@inbounds begin $ex end) : ex
end

@matchable struct MakeArray{A<:AbstractArray} # Could be StaticArray
    elems::A
end

function toexpr(a::MakeArray, st)
    :([$(toexpr.(a.elems, (st,))...)])
end

using SparseArrays

## We use a separate type for Sparse Arrays to sidestep the need for
## iszero to be defined on the expression type
@matchable struct MakeSparseArray
    sparsity::SparseMatrixCSC
    V
end

function MakeSparseArray(I, J, V)
end

function toexpr(a::MakeArray, st)
    sp = a.sparsity
    :(SparseMatrixCSC(sp.m, sp.n, sp.colptr, sp.rowval, [$(toexpr.(a.elems, (st,))...)]))
end

@matchable struct MakeTuple
    elems
end

function toexpr(a::MakeTuple, st)
    :(($(toexpr.(a.elems, (st,))...),))
end

end

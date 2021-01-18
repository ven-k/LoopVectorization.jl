
"""
`vstorent!` (non-temporal store) requires data to be aligned.
`alignstores!` will align `y` in preparation for the non-temporal maps.
"""
function setup_vmap!(
    f::F, y::AbstractArray{T}, ::Val{true},
    args::Vararg{AbstractArray,A}
) where {F, T <: Base.HWReal, A}
    N = length(y)
    ptry = VectorizationBase.zstridedpointer(y)
    ptrargs = VectorizationBase.zstridedpointer.(args)
    V = VectorizationBase.pick_vector_width_val(T)
    W = unwrap(V)
    zero_index = MM{W}(Static(0))
    uintptry = reinterpret(UInt, pointer(ptry))
    @assert iszero(uintptry & (sizeof(T) - 1)) "The destination vector (`dest`) must be aligned to `sizeof(eltype(dest)) == $(sizeof(T))` bytes."
    alignment = uintptry & (VectorizationBase.REGISTER_SIZE - 1)
    if alignment > 0
        i = reinterpret(Int, W - (alignment >>> VectorizationBase.intlog2(sizeof(T))))
        m = mask(T, i)
        if N < i
            m &= mask(T, N & (W - 1))
        end
        vnoaliasstore!(ptry, f(vload.(ptrargs, ((zero_index,),), m)...), (zero_index,), m)
        gesp(ptry, (i,)), gesp.(ptrargs, ((i,),)), N - i
    else
        ptry, ptrargs, N
    end
end

@inline function setup_vmap!(f, y, ::Val{false}, args::Vararg{AbstractArray,A}) where {A}
    N = length(y)
    ptry = VectorizationBase.zstridedpointer(y)
    ptrargs = VectorizationBase.zstridedpointer.(args)
    ptry, ptrargs, N
end

function vmap_singlethread!(
    f::F, y::AbstractArray{T},
    ::Val{NonTemporal},
    args::Vararg{AbstractArray,A}
) where {F,T <: Base.HWReal, A, NonTemporal}
    ptry, ptrargs, N = setup_vmap!(f, y, Val{NonTemporal}(), args...)
    vmap_singlethread!(f, ptry, Zero(), N, Val{NonTemporal}(), ptrargs)
    y
end
function vmap_singlethread!(
    f::F, ptry::AbstractStridedPointer{T},
    start, N, ::Val{NonTemporal},
    ptrargs::Tuple{Vararg{AbstractStridedPointer,A}}
) where {F, T, NonTemporal, A}
    i = convert(Int, start)
    V = VectorizationBase.pick_vector_width_val(T)
    W = unwrap(V)
    st = VectorizationBase.static_sizeof(T)
    UNROLL = 4
    LOG2UNROLL = 2
    while i < N - ((W << LOG2UNROLL) - 1)

        index = VectorizationBase.Unroll{1,1,UNROLL,1,W,0x0000000000000000}((i,))
        v = f(vload.(ptrargs, index)...)
        if NonTemporal
            vstorent!(ptry, v, index)
        else
            vnoaliasstore!(ptry, v, index)
        end
        i = vadd_fast(i, StaticInt{UNROLL}() * W)
    end
    # if Base.libllvm_version ≥ v"11" # this seems to be slower
    #     Nm1 = vsub_fast(N, 1)
    #     while i < N # stops at 16 when
    #         m = mask(V, i, Nm1)
    #         vnoaliasstore!(ptry, f(vload.(ptrargs, ((MM{W}(i),),), m)...), (MM{W}(i,),), m)
    #         i = vadd_fast(i, W)
    #     end
    # else
    while i < N - (W - 1) # stops at 16 when
        vᵣ = f(vload.(ptrargs, ((MM{W}(i),),))...)
        if NonTemporal
            vstorent!(ptry, vᵣ, (MM{W}(i),))
        else
            vnoaliasstore!(ptry, vᵣ, (MM{W}(i),))
        end
        i = vadd_fast(i, W)
    end
    if i < N
        m = mask(T, N & (W - 1))
        vnoaliasstore!(ptry, f(vload.(ptrargs, ((MM{W}(i),),), m)...), (MM{W}(i,),), m)
    end
    # end
    nothing
end

abstract type AbstractVmapClosure{NonTemporal,F,D,N,A<:Tuple{Vararg{StridedPointer,N}}} <: Function end
struct VmapClosure{NonTemporal,F,D,N,A} <: AbstractVmapClosure{NonTemporal,F,D,N,A}
    f::F
    function VmapClosure{NonTemporal}(f::F, ::D, ::A) where {NonTemporal,F,D,N,A<:Tuple{Vararg{StridedPointer,N}}}
        new{NonTemporal,F,D,N,A}(f)
    end
end
# struct VmapKnownClosure{NonTemporal,F,D,N,A} <: AbstractVmapClosure{NonTemporal,F,D,N,A} end

@inline function _vmap_thread_call!(
    f::F, p::Ptr{UInt}, ::Type{D}, ::Type{A}, ::Val{NonTemporal}
) where {F,D,A,NonTemporal}
    (offset, dest) = ThreadingUtilities._atomic_load(p, D, 1)
    (offset, args) = ThreadingUtilities._atomic_load(p, A, offset)
    
    (offset, start) = ThreadingUtilities._atomic_load(p, Int, offset)
    (offset, stop ) = ThreadingUtilities._atomic_load(p, Int, offset)
        
    vmap_singlethread!(f, dest, start, stop, Val{NonTemporal}(), args)
    nothing
end
# @generated function (::VmapKnownClosure{NonTemporal,F,D,N,A})(p::Ptr{UInt})  where {NonTemporal,F,D,N,A}
#     :(_vmap_thread_call!($(F.instance), p, $D, $A, Val{$NonTemporal}()))
# end
function (m::VmapClosure{NonTemporal,F,D,N,A})(p::Ptr{UInt}) where {NonTemporal,F,D,N,A}
    _vmap_thread_call!(m.f, p, D, A, Val{NonTemporal}())
end

@inline function _get_fptr(cfunc::Base.CFunction)
    Base.unsafe_convert(Ptr{Cvoid}, cfunc)
end
# @generated function _get_fptr(cfunc::F) where {F<:VmapKnownClosure}
#     precompile(F(), (Ptr{UInt},))
#     quote
#         $(Expr(:meta,:inline))
#         @cfunction($(F()), Cvoid, (Ptr{UInt},))
#     end
# end

@inline function setup_thread_vmap!(
    p, cfunc, ptry, ptrargs, start, stop
)
    fptr = _get_fptr(cfunc)
    offset = ThreadingUtilities._atomic_store!(p, fptr, 0)
    offset = ThreadingUtilities._atomic_store!(p, ptry, offset)
    offset = ThreadingUtilities._atomic_store!(p, ptrargs, offset)
    offset = ThreadingUtilities._atomic_store!(p, start, offset)
    offset = ThreadingUtilities._atomic_store!(p, stop, offset)
    nothing
end
@inline function launch_thread_vmap!(tid, cfunc, ptry, ptrargs, start, stop)
    p = ThreadingUtilities.taskpointer(tid)
    while true
        if ThreadingUtilities._atomic_cas_cmp!(p, ThreadingUtilities.SPIN, ThreadingUtilities.STUP)
            setup_thread_vmap!(p, cfunc, ptry, ptrargs, start, stop)
            @assert ThreadingUtilities._atomic_cas_cmp!(p, ThreadingUtilities.STUP, ThreadingUtilities.TASK)
            return
        elseif ThreadingUtilities._atomic_cas_cmp!(p, ThreadingUtilities.WAIT, ThreadingUtilities.STUP)
            setup_thread_vmap!(p, cfunc, ptry, ptrargs, start, stop)
            @assert ThreadingUtilities._atomic_cas_cmp!(p, ThreadingUtilities.STUP, ThreadingUtilities.LOCK)
            ThreadingUtilities.wake_thread!(tid % UInt)
            return
        end
        ThreadingUtilities.pause()
    end        
end

@inline function vmap_closure(f::F, ptry::D, ptrargs::A, ::Val{NonTemporal}) where {F,D<:StridedPointer,N,A<:Tuple{Vararg{StridedPointer,N}},NonTemporal}
    vmc = VmapClosure{NonTemporal}(f, ptry, ptrargs)
    @cfunction($vmc, Cvoid, (Ptr{UInt},))
end
# @inline function _cfunc_closure(f, ptry, ptrargs, ::Val{NonTemporal}) where {NonTemporal}
#     vmc = VmapClosure{NonTemporal}(f, ptry, ptrargs)
#     @cfunction($vmc, Cvoid, (Ptr{UInt},))
# end
# @generated function vmap_closure(f::F, ptry::D, ptrargs::A, ::Val{NonTemporal}) where {F,D<:StridedPointer,N,A<:Tuple{Vararg{StridedPointer,N}},NonTemporal}
#     # fsym = get(FUNCTIONSYMBOLS, F, Symbol("##NOTFOUND##"))
#      # fsym === Symbol("##NOTFOUND##")
#     if false# iszero(sizeof(F))
#         quote
#             $(Expr(:meta,:inline))
#             VmapKnownClosure{$NonTemporal,$F,$D,$N,$A}()
#         end
#     else
#         quote
#             $(Expr(:meta,:inline))
#             _cfunc_closure(f, ptry, ptrargs, Val{$NonTemporal}())
#         end
#     end
# end

function vmap_multithread!(
    f::F,
    y::AbstractArray{T},
    ::Val{NonTemporal},
    args::Vararg{AbstractArray,A}
) where {F,T,A,NonTemporal}
    W, Wshift = VectorizationBase.pick_vector_width_shift(T)
    ptry, ptrargs, N = setup_vmap!(f, y, Val{NonTemporal}(), args...)
    # nt = min(Threads.nthreads(), VectorizationBase.SYS_CPU_THREADS, N >> (Wshift + 3))
    nt = min(Threads.nthreads(), VectorizationBase.NUM_CORES, N >> (Wshift + 5))

    if !((nt > 1) && iszero(ccall(:jl_in_threaded_region, Cint, ())))
          vmap_singlethread!(f, ptry, Zero(), N, Val{NonTemporal}(), ptrargs)
          return y
    end

    cfunc = vmap_closure(f, ptry, ptrargs, Val{NonTemporal}())
    vmc = VmapClosure{NonTemporal}(f, ptry, ptrargs)
    Nveciter = (N + (W-1)) >> Wshift
    Nd, Nr = divrem(Nveciter, nt)
    NdW = Nd << Wshift
    NdWr = NdW + W
    GC.@preserve cfunc begin
        start = 0
        for tid ∈ 1:nt-1
            stop = start + ifelse(tid ≤ Nr, NdWr, NdW)
            launch_thread_vmap!(tid, cfunc, ptry, ptrargs, start, stop)
            start = stop
        end
        vmap_singlethread!(f, ptry, start, N, Val{NonTemporal}(), ptrargs)
        for tid ∈ 1:nt-1
            ThreadingUtilities.__wait(tid)
        end
    end
    y
end

Base.@pure _all_dense(::ArrayInterface.DenseDims{D}) where {D} = all(D)
@inline all_dense() = true
@inline all_dense(A::AbstractArray) = _all_dense(ArrayInterface.dense_dims(A))
@inline all_dense(A::AbstractArray, B::AbstractArray, C::Vararg{AbstractArray,K}) where {K} = all_dense(A) && all_dense(B, C...)

"""
    vmap!(f, destination, a::AbstractArray)
    vmap!(f, destination, a::AbstractArray, b::AbstractArray, ...)

Vectorized-`map!`, applying `f` to each element of `a` (or paired elements of `a`, `b`, ...)
and storing the result in `destination`.
"""
function vmap!(
    f::F, y::AbstractArray, args::Vararg{AbstractArray,A}
) where {F,A}
    if check_args(y, args...) && all_dense(y, args...)
        vmap_singlethread!(f, y, Val{false}(), args...)
    else
        map!(f, y, args...)
    end
end


"""
    vmapt!(::Function, dest, args...)

Like `vmap!` (see `vmap!`), but uses `Threads.@threads` for parallel execution.
"""
function vmapt!(
    f::F, y::AbstractArray, args::Vararg{AbstractArray,A}
) where {F,A}
    if check_args(y, args...) && all_dense(y, args...)
        vmap_multithread!(f, y, Val{false}(), args...)
    else
        map!(f, y, args...)
    end
end


"""
    vmapnt!(::Function, dest, args...)


This is a vectorized map implementation using nontemporal store operations. This means that the write operations to the destination will not go to the CPU's cache.
If you will not immediately be reading from these values, this can improve performance because the writes won't pollute your cache. This can especially be the case if your arguments are very long.

```julia
julia> using LoopVectorization, BenchmarkTools

julia> x = rand(10^8); y = rand(10^8); z = similar(x);

julia> f(x,y) = exp(-0.5abs2(x - y))
f (generic function with 1 method)

julia> @benchmark map!(f, \$z, \$x, \$y)
BenchmarkTools.Trial:
  memory estimate:  0 bytes
  allocs estimate:  0
  --------------
  minimum time:     439.613 ms (0.00% GC)
  median time:      440.729 ms (0.00% GC)
  mean time:        440.695 ms (0.00% GC)
  maximum time:     441.665 ms (0.00% GC)
  --------------
  samples:          12
  evals/sample:     1

julia> @benchmark vmap!(f, \$z, \$x, \$y)
BenchmarkTools.Trial:
  memory estimate:  0 bytes
  allocs estimate:  0
  --------------
  minimum time:     178.147 ms (0.00% GC)
  median time:      178.381 ms (0.00% GC)
  mean time:        178.430 ms (0.00% GC)
  maximum time:     179.054 ms (0.00% GC)
  --------------
  samples:          29
  evals/sample:     1

julia> @benchmark vmapnt!(f, \$z, \$x, \$y)
BenchmarkTools.Trial:
  memory estimate:  0 bytes
  allocs estimate:  0
  --------------
  minimum time:     144.183 ms (0.00% GC)
  median time:      144.338 ms (0.00% GC)
  mean time:        144.349 ms (0.00% GC)
  maximum time:     144.641 ms (0.00% GC)
  --------------
  samples:          35
  evals/sample:     1
```
"""
function vmapnt!(
    f::F, y::AbstractArray, args::Vararg{AbstractArray,A}
) where {F,A}
    if check_args(y, args...) && all_dense(y, args...)
        vmap_singlethread!(f, y, Val{true}(), args...)
    else
        map!(f, y, args...)
    end
end

"""
    vmapntt!(::Function, dest, args...)

Like `vmapnt!` (see `vmapnt!`), but uses `Threads.@threads` for parallel execution.
"""
function vmapntt!(
    f::F, y::AbstractArray, args::Vararg{AbstractArray,A}
) where {F,A}
    if check_args(y, args...) && all_dense(y, args...)
        vmap_multithread!(f, y, Val{true}(), args...)
    else
        map!(f, y, args...)
    end
end

# generic fallbacks
@inline vmap!(f, args...) = map!(f, args...)
@inline vmapt!(f, args...) = map!(f, args...)
@inline vmapnt!(f, args...) = map!(f, args...)
@inline vmapntt!(f, args...) = map!(f, args...)

function vmap_call(f::F, vm!::V, args::Vararg{Any,N}) where {V,F,N}
    T = Base._return_type(f, Base.Broadcast.eltypes(args))
    dest = similar(first(args), T)
    vm!(f, dest, args...)
end

"""
    vmap(f, a::AbstractArray)
    vmap(f, a::AbstractArray, b::AbstractArray, ...)

SIMD-vectorized `map`, applying `f` to each element of `a` (or paired elements of `a`, `b`, ...)
and returning a new array.
"""
vmap(f::F, args::Vararg{Any,N}) where {F,N} = vmap_call(f, vmap!, args...)

"""
    vmapt(f, a::AbstractArray)
    vmapt(f, a::AbstractArray, b::AbstractArray, ...)

A threaded variant of [`vmap`](@ref).
"""
vmapt(f::F, args::Vararg{Any,N}) where {F,N} = vmap_call(f, vmapt!, args...)

"""
    vmapnt(f, a::AbstractArray)
    vmapnt(f, a::AbstractArray, b::AbstractArray, ...)

A "non-temporal" variant of [`vmap`](@ref). This can improve performance in cases where
`destination` will not be needed soon.
"""
vmapnt(f::F, args::Vararg{Any,N}) where {F,N} = vmap_call(f, vmapnt!, args...)

"""
    vmapntt(f, a::AbstractArray)
    vmapntt(f, a::AbstractArray, b::AbstractArray, ...)

A threaded variant of [`vmapnt`](@ref).
"""
vmapntt(f::F, args::Vararg{Any,N}) where {F,N} = vmap_call(f, vmapntt!, args...)


# @inline vmap!(f, y, x...) = @avx y .= f.(x...)
# @inline vmap(f, x...) = @avx f.(x...)

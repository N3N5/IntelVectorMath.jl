import MKL_jll
# import LinearAlgebra:Transpose,Adjoint

struct VMLAccuracy
    mode::UInt
end

const VML_LA = VMLAccuracy(0x00000001)
const VML_HA = VMLAccuracy(0x00000002)
const VML_EP = VMLAccuracy(0x00000003)

Base.show(io::IO, m::VMLAccuracy) = print(io, m == VML_LA ? "VML_LA" :
                                              m == VML_HA ? "VML_HA" : "VML_EP")

vml_get_mode() = ccall((:vmlGetMode, MKL_jll.libmkl_rt), Cuint, ())
vml_set_mode(mode::Integer) = (ccall((:vmlSetMode, MKL_jll.libmkl_rt), Cuint, (UInt,), mode); nothing)

vml_set_accuracy(m::VMLAccuracy) = vml_set_mode((vml_get_mode() & ~0x03) | m.mode)
vml_get_accuracy() = VMLAccuracy(vml_get_mode() & 0x3)

function vml_check_error()
    vml_error = ccall((:vmlClearErrStatus, MKL_jll.libmkl_rt), Cint, ())
    if vml_error != 0
        if vml_error == 1
            throw(DomainError(-1, "This function does not support arguments outside its domain"))
        elseif vml_error == 2 || vml_error == 3 || vml_error == 4
            # Singularity, overflow, or underflow
            # I don't think Base throws on these
        elseif vml_error == 1000
            warn("IntelVectorMath does not support $(vml_get_accuracy); lower accuracy used instead")
        else
            error("an unexpected error occurred in IntelVectorMath ($vml_error)")
        end
    end
end

function vml_prefix(t::DataType)
    if t == Float32
        return "vs"
    elseif t == Float64
        return "vd"
    elseif t == Complex{Float32}
        return "vc"
    elseif t == Complex{Float64}
        return "vz"
    end
    error("unknown type $t")
end

#AbstractArray input check
memorycheck(A::Array) = true
memorycheck(A::Base.ReshapedArray) = memorycheck(parent(A))
memorycheck(A::Base.FastContiguousSubArray) = memorycheck(parent(A))
memorycheck(A::Base.ReinterpretArray) = memorycheck(parent(A))
# memorycheck(A::Transpose) = min(size(A)...) == 1 && memorycheck(parent(A))
# memorycheck(A::Adjoint{<:Real}) = min(size(A)...) == 1 && memorycheck(parent(A))
memorycheck(A) = false
memorycheck(A,As...) = memorycheck(A) && memorycheck(As...)

function def_unary_op(tin, tout, jlname, jlname!, mklname;
        vmltype = tin)
    mklfn = Base.Meta.quot(Symbol("$(vml_prefix(vmltype))$mklname"))
    exports = Symbol[]
    (@isdefined jlname) || push!(exports, jlname)
    (@isdefined jlname!) || push!(exports, jlname!)
    @eval begin
        function ($jlname!)(out::AbstractArray{$tout}, A::AbstractArray{$tin})
            memorycheck(out,A) || throw(ArgumentError("Input arrays need to be contiguous in memory"))
            size(out) == size(A) || throw(DimensionMismatch("Input array and output need to have the same size"))
            ccall(($mklfn, MKL_jll.libmkl_rt), Nothing, (Int, Ptr{$tin}, Ptr{$tout}), length(A), A, out)
            vml_check_error()
            return out
        end
        $(if tin == tout
            quote
                function $(jlname!)(A::AbstractArray{$tin})
                    memorycheck(A) || throw(ArgumentError("Input array needs to be contiguous in memory"))
                    ccall(($mklfn, MKL_jll.libmkl_rt), Nothing, (Int, Ptr{$tin}, Ptr{$tout}), length(A), A, A)
                    vml_check_error()
                    return A
                end
            end
        end)
        function ($jlname)(A::AbstractArray{$tin})
            memorycheck(A) || throw(ArgumentError("Input array needs to be contiguous in memory"))
            out = Array{$tout}(undef, size(A)) #force array output for Transpose and Adjoint
            ccall(($mklfn, MKL_jll.libmkl_rt), Nothing, (Int, Ptr{$tin}, Ptr{$tout}), length(A), A, out)
            vml_check_error()
            return out
        end
        $(isempty(exports) ? nothing : Expr(:export, exports...))
    end
end

function def_binary_op(tin, tout, jlname, jlname!, mklname, broadcast)
    mklfn = Base.Meta.quot(Symbol("$(vml_prefix(tin))$mklname"))
    exports = Symbol[]
    (@isdefined jlname) || push!(exports, jlname)
    (@isdefined jlname!) || push!(exports, jlname!)
    @eval begin
        $(isempty(exports) ? nothing : Expr(:export, exports...))
        function ($jlname!)(out::AbstractArray{$tout}, A::AbstractArray{$tin}, B::AbstractArray{$tin})
            memorycheck(out, A, B) || throw(ArgumentError("Input arrays and output array need to be contiguous in memory"))
            size(out) == size(A) == size(B) || throw(DimensionMismatch("Input arrays and output array need to have the same size"))
            ccall(($mklfn, MKL_jll.libmkl_rt), Nothing, (Int, Ptr{$tin}, Ptr{$tin}, Ptr{$tout}), length(A), A, B, out)
            vml_check_error()
            return out
        end
        function ($jlname)(A::Array{$tin}, B::Array{$tin})
            memorycheck(A, B) || throw(ArgumentError("Input arrays need to be contiguous in memory"))
            size(A) == size(B) || throw(DimensionMismatch("Input arrays need to have the same size"))
            out = Array{$tout}(undef, size(A)) #force array output for Transpose and Adjoint
            ccall(($mklfn, MKL_jll.libmkl_rt), Nothing, (Int, Ptr{$tin}, Ptr{$tin}, Ptr{$tout}), length(A), A, B, out)
            vml_check_error()
            return out
        end
    end
end

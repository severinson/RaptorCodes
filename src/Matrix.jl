# matrix primitives and concrete row types

export BRow, QRow

doc"Sparse binary row."
struct BRow <: Row
    indices::Vector{Int} # sorted list of initial non-zero indices.
    inactive::BitVector # dense binary part
    function BRow(active::Vector{Int})
        return new(sort!(copy(active)), falses(64))
    end
    function BRow(active::Vector{Int}, inactive::BitVector)
        return new(sort!(copy(active)), inactive)
    end
end

function row(::Type{BRow}, s::BSymbol)
    return BRow(s.neighbours)
end

@inline function degree(r::BRow)
    return length(r.indices)
end

@inline function inactive_degree(r::BRow)
    return sum(r.inactive)
end

@inline function neighbours(r::BRow)
    return r.indices
end

@inline function coefficients(r::BRow)
    return trues(length(r.indices))
end

@inline function coefficient(r::BRow, cpi::Int)
    return true
end

doc"in-place XOR of two bit-vectors."
function xor!(a::BitVector, b::BitVector)
    la, lb = length(a.chunks), length(b.chunks)
    @inbounds begin
        @simd for i in 1:min(la, lb)
            a.chunks[i] = xor(a.chunks[i], b.chunks[i])
        end
    end
    if lb > la
        append!(a.chunks, view(b.chunks, (la+1):lb))
    end
    a.len = 64*length(a.chunks)
    return a
end

@inline function subtract!(b::BRow, a::BRow, coef::Bool)
    @assert coef "coef must be true, but is $coef"
    xor!(b.inactive, a.inactive)
    return b
end

doc"get the index of any non-zero inactive element"
@inline function getinactive(r::BRow)
    return findfirst(r.inactive)
end

doc"set an element of the dense part of the matrix."
@inline function setdense!(row::BRow, upi::Int, v::Bool)
    if !v && upi > length(row.inactive) # unallocated elements are implicitly zero
        return row
    end
    while upi > length(row.inactive) # dynamically grow the array
        append!(row.inactive, falses(max(1, length(row.inactive))))
    end
    row.inactive[upi] = v
    return row
end

doc"get an element from the dense part of the matrix."
@inline function getdense(row::BRow, upi::Int) :: Bool
    if upi > length(row.inactive)
        return false
    end
    return row.inactive[upi]
end

doc"matrix row with arbitrary coefficients"
struct QRow{CT} <: Row
    indices::Vector{Int} # sorted list of initial non-zero indices.
    values::Vector{CT} # initial non-zero values for indices
    dense::Vector{CT} # dense part of the row
    function QRow{CT}(indices::Vector{Int}, values::Vector{CT}) where CT
        p = sortperm(indices)
        return new(copy(indices)[p], copy(values)[p], Vector{CT}())
    end
    # function QRow{CT}(indices::Vector{Int}, values::Vector{CT}, dense::BitVector) where CT
    #     p = sortperm(indices)
    #     return new(copy(indices)[p], copy(values)[p], copy(dense))
    # end
    function QRow{CT}(indices::Vector{Int}, values::Vector{CT}, dense::Vector{CT}) where CT
        p = sortperm(indices)
        return new(copy(indices)[p], copy(values)[p], copy(dense))
    end
end

function QRow{CT}(indices::Vector{Int}, values::Vector{CT}, dense::Vector{CT})
    return QRow{CT}(indices::Vector{Int}, values::Vector{CT}, dense::Vector{CT})
end

function row{CT}(::Type{QRow{CT}}, s::BSymbol)
    return QRow{CT}(s.neighbours, ones(CT, length(s.neighbours)))
end

function row{CT,VT}(::Type{QRow{CT}}, s::QSymbol{VT,CT})
    return QRow{CT}(s.neighbours, s.coefficients)
end

@inline function degree(r::QRow)
    return length(r.indices)
end

@inline function inactive_degree{CT}(r::QRow{CT}) :: Int
    if length(r.dense) == 0
        return 0
    end
    return sum(!iszero(v) for v in r.dense)
end

@inline function neighbours(r::QRow)
    return r.indices
end

@inline function coefficients(r::QRow)
    return r.values
end

@inline function coefficient(r::QRow, cpi::Int)
    range = searchsorted(r.indices, cpi)
    @assert length(range) == 1 "tried to find-non-existing or duplicate index $cpi in row $r"
    i = range[1]
    return r.values[i]
end

doc"convert a binary array to a q-ary array"
function qary_from_binary(b::BitVector) :: Array{GF256}
    indices = find(b)
    qary = zeros(GF256, maximum(indices))
    for i in indices
        qary[i] = one(GF256)
    end
    return qary
end

doc"in-place XOR of two UInt8-vectors."
function xor!(a::Vector{GF256}, b::Vector{GF256})
    la, lb = length(a), length(b)
    @simd for i in 1:min(la, lb)
        a[i] = xor(a[i], b[i])
    end
    if lb > la
        append!(a, view(b, (la+1):lb))
    end
    return a
end

@inline function subtract!{CT}(b::QRow{CT}, a::QRow{CT}, coef::CT) ::QRow
    if length(a.dense) == 0
        return b
    end
    xor!(b.dense, coef.*a.dense)
    return b
end

@inline function subtract!{CT<:Float64}(b::QRow{CT}, a::QRow{CT}, coef::CT) ::QRow
    lb, la = length(b.dense), length(a.dense)
    if iszero(a.dense) || iszero(coef)
        return b
    elseif lb == 0
        return QRow{CT}(b.indices, b.values, -coef.*a.dense)
    else
        @simd for i in 1:min(lb, la)
            b.dense[i] -= coef * a.dense[i]
        end
        if la > lb
            append!(b.dense, -coef*view(a.dense, (lb+1):la))
        end
    end
    return b
end

doc"get the index of any non-zero inactive element"
@inline function getinactive(r::QRow)
    return findfirst(r.dense)
end

doc"set an element of the dense part of the matrix."
@inline function setdense!{CT}(row::QRow{CT}, upi::Int, v::CT)
    @assert !iszero(v) "v must be non-zero"
    while upi > length(row.dense)
        append!(row.dense, zeros(CT, max(1, length(row.dense))))
    end
    row.dense[upi] = v
    return row
end

doc"get an element from the dense part of the matrix."
@inline function getdense{CT}(row::QRow{CT}, upi::Int)
    if upi <= length(row.dense)
        return row.dense[upi]
    end
    return zero(CT)
end

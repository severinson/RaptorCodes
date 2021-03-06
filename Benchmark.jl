using FountainCodes
using Random
using StatsBase
using PyPlot
using Distributions
using SparseArrays
using LinearAlgebra
using SolitonDistribution

function benchmark_r10(K=1000, r=1200, m=256, n=100)
    r10 = R10(K)
    src = [GF256(i % 256) for i in 1:K]
    inter = precode(src, r10)
    Vs = [zero(inter[1]) for _ in 1:(r10.S+r10.H)] # parity symbol values
    append!(Vs, [get_value(r10, X, inter) for X in 0:r-1]) # LT symbol values
    Xs = -(r10.S+r10.H):r-1 # ESIs incl. parity symbols
    t = 0.0
    for _ in 1:n
        t += @elapsed decode(r10, Xs, Vs)
    end
    t /= n
    println(r10)
    println("Decoding time: $t s")
end

function benchmark_lt(K=600, r=615, nsamples=100, M=40, δ=1e-6)
    dd = Soliton(K, M, δ)
    println(mean(dd))
    lt = LT(K, dd)
    src = [rand(Bool) for _ in 1:K]
    Xs = zeros(Int, r)
    t = 0.0
    nfailures = 0.0
    for _ in 1:nsamples
        Xs .= sample(10000:100000, r, replace=false) # Received ESIs
        Vs = [get_value(lt, X, src) for X in Xs]
        try
            decoder = Decoder{Bool}(K)
            t += @elapsed decode(lt, Xs, Vs, decoder=decoder)
        catch
            nfailures += 1
        end
    end
    nfailures /= nsamples
    t /= nsamples
    println(lt)
    println("Decoding time: $t s")
    println("Failure rate: $nfailures")
end

function benchmark_ltq(K=600, r=615, nsamples=100, M=40, δ=1e-6)
    dd = Soliton(K, M, δ)
    lt = LTQ{GF256}(K, dd)
    src = [Vector{GF256}([i % 256]) for i in 1:K]
    Xs = zeros(Int, r)
    t = 0.0
    nfailures = 0.0
    for _ in 1:nsamples
        Xs .= sample(10000:100000, r, replace=false) # Received ESIs
        Vs = [get_value(lt, X, src) for X in Xs]
        try
            decoder = Decoder{GF256}(K)
            t += @elapsed decode(lt, Xs, Vs, decoder=decoder)
        catch
            println("Decoding failed")
            nfailures += 1
        end
    end
    nfailures /= nsamples
    t /= nsamples
    println(lt)
    println("Decoding time: $t s")
    println("Failure rate: $nfailures")
end

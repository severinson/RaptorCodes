using Primes, Distributions

export LTParameters, QLTParameters

doc"LT code parameters."
struct LTParameters{T <: Sampleable{Univariate, Discrete}} <: FountainCode
    K::Integer # number of source symbols
    L::Integer # number of intermediate symbols
    Lp::Integer
    dd::T # degree distribution
    function LTParameters{T}(K::Integer, dd::T) where T
        Lp = Primes.nextprime(K)
        new(K, K, Lp, dd)
    end
end

LTParameters(K::Integer, dd::T) where {T <: Sampleable{Univariate, Discrete}} = LTParameters{T}(K, dd)

Base.repr(p::LTParameters) = "LTParameters($(p.K), $(repr(p.dd)))"

doc"q-ary LT code parameters."
struct QLTParameters{DT <: Sampleable{Univariate, Discrete},
                     CT <: Sampleable{Univariate}} <: FountainCode
    K::Integer # number of source symbols
    L::Integer # number of intermediate symbols
    Lp::Integer
    dd::DT # degree distribution
    cd::CT # coefficient distribution
    function QLTParameters{DT, CT}(K::Integer, dd::DT, cd::CT) where {DT, CT}
        Lp = Primes.nextprime(K)
        new(K, K, Lp, dd, cd)
    end
end

function QLTParameters(K::Integer, dd::DT, cd::CT) where {DT <: Sampleable{Univariate, Discrete},
                                                          CT <: Sampleable{Univariate}}
    QLTParameters{DT, CT}(K, dd, cd)
end

doc"Map a number 0 <= v <= 1 to a degree."
function deg(v::Real, p::FountainCode) :: Int
    return quantile(p.dd, v)
end 

doc"Maps an encoding symbol ID X to a triple (d, a, b)"
function trip(X::Int, p::FountainCode)
    Q = 65521 # the largest prime smaller than 2^16
    JK = J[p.K+1]
    A = (53591 + JK*997) % Q
    B = 10267*(JK+1) % Q
    Y = (B + X*A) % Q
    v = r10_rand(Y, 0, 2<<19) / (2<<19)
    d = deg(v, p)
    a = 1 + r10_rand(Y, 1, p.Lp-1)
    b = r10_rand(Y, 2, p.Lp)
    return d, a, b
end

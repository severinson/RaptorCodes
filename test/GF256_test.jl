@test GF256(2) + GF256(10) - GF256(10) == GF256(2)
@test GF256(2) * GF256(10) / GF256(10) == GF256(2)
@test GF256(1) + GF256(2) * GF256(10) - GF256(10) - GF256(10) == GF256(21)
@test GF256(13) * GF256(1) == GF256(13)
@test GF256(13) / GF256(1) == GF256(13)
@test GF256(0) * GF256(1) == GF256(0)
@test GF256(0) / GF256(1) == GF256(0)
@test [GF256(i) for i in 0:255].*zero(GF256) == zeros(GF256, 256)
@test [GF256(i) for i in 0:255].*one(GF256) == [GF256(i) for i in 0:255]
@test [GF256(i) for i in 0:255].*GF256(2) == [GF256(2)*GF256(i) for i in 0:255]
@test GF256(11) + false == GF256(11)
@test GF256(11) + true == GF256(11) + GF256(1)
@test GF256(11) * false == GF256(0)
@test GF256(11) * true == GF256(11)
@test GF256(11) / true == GF256(11)
@test GF256(123)^0 == GF256(1)
@test GF256(123)^1 == GF256(123)
@test GF256(123)^2 == GF256(123) * GF256(123)
@test GF256(46)^3 == GF256(46) * GF256(46) * GF256(46)
@test GF256(10)^20 == reduce(*, (GF256(10) for _ in 1:20))
@test GF256(56)^30 == reduce(*, (GF256(56) for _ in 1:30))
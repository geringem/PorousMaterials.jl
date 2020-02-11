###
#   Coordinates: Fractional and Cartesian
###
abstract type Coords end

struct Frac<:Coords
    xf::Array{Float64, 2}
end
Base.isapprox(c1::Frac, c2::Frac; atol::Real=0) = isapprox(c1.xf, c2.xf, atol=atol)
Base.hcat(c1::Frac, c2::Frac) = Frac(hcat(c1.xf, c2.xf))

struct Cart<:Coords
    x::Array{Float64, 2}
end
Base.isapprox(c1::Cart, c2::Cart; atol::Real=0) = isapprox(c1.x, c2.x, atol=atol)
Base.hcat(c1::Cart, c2::Cart) = Cart(hcat(c1.x, c2.x))

# helpers for single vectors
Frac(xf::Array{Float64, 1}) = Frac(reshape(xf, (3, 1)))
Cart(x::Array{Float64, 1}) = Cart(reshape(x, (3, 1)))

"""
    wrap!(f::Frac)
    wrap!(crystal::Crystal)

wrap fractional coordinates to [0, 1] via `mod(⋅, 1.0)`.
e.g. -0.1 --> 0.9 and 1.1 -> 0.1
"""
function wrap!(f::Frac)
    f.xf .= mod.(f.xf, 1.0)
end

###
#   Atoms
###
# c is either Cart or Frac
struct Atoms{T}
    n::Int # how many atoms?
    species::Array{Symbol, 1} # list of species
    coords::T # coordinates
end
Atoms(species::Array{Symbol, 1}, coords::Coords) = Atoms(length(species), species, coords)
# safe pre-allocation
Atoms(n::Int) = Atoms([:blah for a = 1:n], [NaN for i = 1:3, a = 1:n])

Base.isapprox(a1::Atoms, a2::Atoms; atol::Real=0) = (a1.species == a2.species) && isapprox(a1.coords, a2.coords, atol=atol)
Base.:+(a1::Atoms, a2::Atoms) = Atoms(a1.n + a2.n, [a1.species; a2.species], hcat(a1.coords, a2.coords))


###
#   Charges
###
struct Charges{T}
    n::Int
    q::Array{Float64, 1}
    coords::T
end
Charges(q::Array{Float64, 1}, coords::Coords) = Charges(length(q), q, coords)
Charges(n::Int) = Atoms([NaN for a = 1:n], [NaN for i = 1:3, a = 1:n])

Base.isapprox(c1::Charges, c2::Charges; atol::Real=0) = isapprox(c1.q, c2.q) && isapprox(c1.coords, c2.coords, atol=atol)
Base.:+(c1::Charges, c2::Charges) = Charges(c1.n + c2.n, [c1.q; c2.q], hcat(c1.coords, c2.coords))

"""
    nc = net_charge(charges)
    nc = net_charge(crystal)

find the sum of charges in `charges::Charges` or `crystal.charges` where `crystal::Crystal`.
"""
net_charge(charges::Charges) = sum(charges.q)

"""
    neutral(charges, tol) # true or false. default tol = 1e-5
    neutral(crystal, tol) # true or false. default tol = 1e-5

determine if a set of `charges::Charges` (`charges.q`) sum to an absolute value less than `tol::Float64`. if `crystal::Crystal` is passed, the function looks at the `crystal.charges`. i.e. determine the absolute value of the net charge is less than `tol`.
"""
neutral(charges::Charges, tol::Float64=1e-5) = abs(net_charge(charges)) < tol
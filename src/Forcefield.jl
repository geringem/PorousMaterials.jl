using DataFrames

"""
	ljforcefield = LennardJonesForceField(cutoffradius_squared, epsilon_dict, sigma_dict, atom_to_id, epsilons, sigmas_squared)

Data structure for a Lennard Jones forcefield, read from a file containing UFF parameters.

# Arguments
- `pure_sigmas::Dict{AbstractString, Float64}`: Dictionary that connects element acronyms to a σ, which is the finite distance where the potential between atoms goes to zero
- `pure_epsilons::Dict{AbstractString, Float64}`: Dictionary that connects element acronyms to an ϵ, which is the depth of a Lennard Jones potential well
- `epsilons::Dict{AbstractString, Dict{AbstractString, Float64}}`: Lennard Jones ϵ (units: K) for cross-interactions. Example use is `epsilons["He"]["C"]`
- `sigmas_squared::Dict{AbstractString, Dict{AbstractString, Float64}}`: Lennard Jones σ^2 (units: A^2) for cross-interactions. Example use is `sigmas_squared["He"]["C"]`
- `cutoffradius_squared::Float64`: The square of the cut-off radius beyond which we define the potential energy to be zero (units: Angstrom^2)
"""
struct LennardJonesForceField
	pure_sigmas::Dict{AbstractString, Float64}
	pure_epsilons::Dict{AbstractString, Float64}

	sigmas_squared::Dict{AbstractString, Dict{AbstractString, Float64}}
	epsilons::Dict{AbstractString, Dict{AbstractString, Float64}}

	cutoffradius_squared::Float64
end

"""
	ljforcefield = read_forcefield_file("filename.csv")

Read a .csv file containing Lennard Jones parameters (with the following columns: `atom,sigma,epsilon` and constructs a LennardJonesForceField object.
"""
function read_forcefield_file(filename::AbstractString; cutoffradius::Float64=14.0, mixing_rules::AbstractString="Lorentz-Berthelot")
    if ! (mixing_rules in ["Lorentz-Berthelot"])
        error(@sprintf("%s mixing rules not implemented...\n", mixing_rules))
    end

    df = readtable(PATH_TO_DATA * "forcefields/" * filename, allowcomments=true) # from DataFrames
    # assert that all atoms in the force field are unique (i.e. no duplicates)
    @assert(length(unique(df[:atom])) == size(df, 1), 
        @sprintf("Duplicate atoms found in force field file %s\n", filename))
    
    # pure X-X interactions (X = (pseudo)atom)
    pure_sigmas = Dict{AbstractString, Float64}()
    pure_epsilons = Dict{AbstractString, Float64}()
    for row in eachrow(df)
        pure_sigmas[row[:atom]] = row[:sigma]
        pure_epsilons[row[:atom]] = row[:epsilon]
    end
    
    # cross X-Y interactions (X, Y = generally different (pseduo)atoms)
    epsilons = Dict{AbstractString, Dict{AbstractString, Float64}}()
    sigmas_squared = Dict{AbstractString, Dict{AbstractString, Float64}}()
	for atom in keys(pure_sigmas)
        epsilons[atom] = Dict{AbstractString, Float64}()
        sigmas_squared[atom] = Dict{AbstractString, Float64}()
        for other_atom in keys(pure_sigmas)
			epsilons[atom][other_atom] = sqrt(pure_epsilons[atom] * pure_epsilons[other_atom])
			# Store sigma as sigma squared so we can compare it with r^2. r^2 is faster to compute than r
			sigmas_squared[atom][other_atom] = ((pure_sigmas[atom] + pure_sigmas[other_atom]) / 2.0)^2
		end
	end

	return LennardJonesForceField(pure_sigmas, pure_epsilons, sigmas_squared, epsilons, cutoffradius^2)
end # read_forcefield_file end

"""
	repfactors = replication_factors(unitcell::Box, cutoff::Float64)

Find the replication factors needed to make a supercell big enough to fit a sphere with the specified cutoff radius.
In PorousMaterials.jl, rather than replicating the atoms in the home unit cell to build the supercell that
serves as a simulation box, we replicate the home unit cell to form the supercell (simulation box) in a for loop.
This function ensures enough replication factors such that the nearest image convention can be applied.

Returns tuple of replication factors in the a, b, c directions.

# TODO comment on whether it starts at 0 or 1.. like, repfactors = [0, 0, 0] is that possible?
"""
function replication_factors(unitcell::Box, cutoff::Float64)
	# Unit vectors used to transform from fractional coordinates to cartesian coordinates. We'll be
	a = box.f_to_C[:, 1]
	b = box.f_to_C[:, 2]
	c = box.f_to_C[:, 3]

	n_ab = cross(a, b)
	n_ac = cross(a, c)
	n_bc = cross(b, c)

	# c0 defines a center in the unit cell
	c0 = [a b c] * [.5, .5, .5]

	rep = [1, 1, 1]

	# Repeat for `a`
	# |n_bc ⋅ c0|/|n_bc| defines the distance from the end of the supercell and the center. As long as that distance is less than the cutoff radius, we need to increase it
	while abs(dot(n_bc, c0)) / vecnorm(n_bc) < cutoff
		rep[1] += 1
		a += box.f_to_C[:,1]
		c0 = [a b c] * [.5, .5, .5]
	end

	# Repeat for `b`
	while abs(dot(n_ac, c0)) / vecnorm(n_ac) < cutoff
		rep[2] += 1
		b += box.f_to_C[:,2]
		c0 = [a b c] * [.5, .5, .5]
	end

	# Repeat for `c`
	while abs(dot(n_ab, c0)) / vecnorm(n_ab) < cutoff
		rep[3] += 1
		c += box.f_to_C[:,3]
		c0 = [a b c] * [.5, .5, .5]
	end

	return (rep[1], rep[2], rep[3])::Tuple{Int, Int, Int}
end # end rep_factors

"""
    check_forcefield_coverage(framework::Framework, ljforcefield::LennardJonesForceField; verbose::Bool=true)

Check that the force field contains parameters for every atom present in the framework.
returns true or false; prints which atoms are missing by default if `verbose=true`.
"""
function check_forcefield_coverage(framework::Framework, ljforcefield::LennardJonesForceField, verbose::Bool=true)
    framework_atoms = unique(framework.atoms)
    forcefield_atoms = keys(ljforcefield.pure_epsilons)

    full_coverage = true

    for atom in framework_atoms
        if !(atom in forcefield_atoms)
            @printf("[Pseudo]atom type \"%s\" in framework is not covered by the forcefield.\n", atom)
            full_coverage = false
        end
    end
    return full_coverage
end
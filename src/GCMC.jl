# δ (units: Angstrom) is the maximal distance a particle is perturbed in a given coordinate during
#  particle translations
const δ = 0.1

"""
Keep track of statistics during a grand-canonical Monte Carlo simultion

* `n` is the number of molecules
* `U` is the potential energy
* `g` refers to guest (the adsorbate molecule)
* `h` refers to host (the crystalline framework)
"""
type GCMCstats
    n_samples::Int

    n::Int
    n²::Int

    U_gh::Float64
    U_gh²::Float64

    U_gg::Float64
    U_gg²::Float64

    U_ggU_gh::Float64
end

"""
Keep track of Markov chain transitions (proposals and acceptances) during a grand-canonical
Monte Carlo simulation.
"""
type MarkovCounts
    n_proposed::Array{Int, 1}
    n_accepted::Array{Int, 1}
end

"""
    insert_molecule!(molecules, simulation_box, adsorbate)

Inserts an additional molecule into the system and then checks the metropolis
hastings acceptance rules to find whether the proposed insertion is accepted or
rejected. Function then returns the new list of molecules
"""
function insert_molecule!(molecules::Array{Molecule}, simulation_box::Box, adsorbate::String)
    #TODO create template to handle more complex molecules
    x_new = simulation_box.f_to_c * [rand(), rand(), rand()]
    new_molecule = Molecule(1, [adsorbate], x_new[:, :], [0.0])
    push!(molecules, new_molecule)
end

"""
    delete_molecule!(molecule_id, molecules)

Removes a random molecule from the current molecules in the framework.
molecule_id decides which molecule will be deleted, for a simulation, it must
    be a randomly generated value
"""
function delete_molecule!(molecule_id::Int, molecules::Array{Molecule})
    deleteat!(molecules, molecule_id)
end

"""
    translate_molecule(molecule_id, molecules, simulation_box)

Translates a random molecule a random amount in the given array and simulation
box
reflects if entire molecule goes outside in any cartesian direction
"""
function translate_molecule!(molecule_id::Int, molecules::Array{Molecule}, simulation_box::Box)
    # store old coordinates and return at the end for possible restoration of old coords
    x_old = deepcopy(molecules[molecule_id].x)
    # peturb in Cartesian coords in a random cube centered at current coords.
    dx = [δ * (rand() - 0.5) for i = 1:3]
    # change coordinates of molecule
    molecules[molecule_id].x .+= dx
    # compute its fractional coords
    xf_molecule = simulation_box.c_to_f * molecules[molecule_id].x
    outside_box = false
    # apply periodic boundary conditions if molecule goes outside of box.
    for xyz = 1:3 # loop over x, y, z coordinates
        # if all atoms of the molecule have x, y, or z > 1.0, shift down
        if sum(xf_molecule[xyz, :] .<= 1.0) == 0
            outside_box = true
            xf_molecule[xyz, :] -= 1.0
        # if all atoms of the molecule have x, y, or z < 0.0, shift up
        elseif sum(xf_molecule[xyz, :] .>= 0.0) == 0
            outside_box = true
            xf_molecule[xyz, :] += 1.0
        end
    end
    # update the cartesian coordinate if had to apply PBCs
    if outside_box
        molecules[molecule_id].x = simulation_box.c_to_f * xf_molecule
    end

    return x_old # in case we need to restore
end

"""
    proposal_energy = guest_guest_vdw_energy(molecule_id, molecules,
        ljforcefield, simulation_box)

Calculates energy of a single adsorbate in the system. This can be used to find
the change in energy after an accepted proposal

Code copied from Arni's Energetics.jl with minor adjustments to calculate
    interactions between the adsorbates as well as the framework
"""
function guest_guest_vdw_energy(molecule_id::Int, molecules::Array{Molecule},
                        ljforcefield::LennardJonesForceField,
                        simulation_box::Box)
    #start energy at 0 and add to it as comparisons are made
    energy = 0.0
    #Loop over all atoms in the given molecule
    for atom_id = 1:molecules[molecule_id].n_atoms
        xf_molecule_atom = mod.(simulation_box.c_to_f *
            molecules[molecule_id].x[:, atom_id], 1.0)

        #loop over other adsorbate atoms leading up to central atom in array
        for other_molecule_id = 1:length(molecules)
            #molecule cannot interact with itself
            if other_molecule_id == molecule_id
                continue
            end #if statement prevents molecule from interacting with itself
            #loop over every atom in second molecules
            for other_atom_id = 1:molecules[other_molecule_id].n_atoms
                xf_other_molecule_atom = mod.(simulation_box.c_to_f *
                    molecules[other_molecule_id].x[:, other_atom_id], 1.0)
                dxf = xf_molecule_atom - xf_other_molecule_atom

                #runs nearest image convention and adjusts accordingly
                nearest_image!(dxf, (1, 1, 1))
                #converts fractional distance to cartesian distance
                dx = simulation_box.f_to_c * dxf

                r_squared = dot(dx, dx)
                if r_squared < R_OVERLAP_squared
                    return Inf
                elseif r_squared < ljforcefield.cutoffradius_squared
                    # TODO test whether it is more efficient to store this as a variable up top
                    energy += lennard_jones(r_squared,
                        ljforcefield.sigmas_squared[molecules[other_molecule_id].atoms[other_atom_id]][molecules[molecule_id].atoms[atom_id]],
                        ljforcefield.epsilons[molecules[other_molecule_id].atoms[other_atom_id]][molecules[molecule_id].atoms[atom_id]])
                end
            end #for loop to check all atoms in other molecule
        end #for loop to go over all other molecules
    end #for loop for every atom in test molecule
    return energy #units are the same as in ϵ for forcefield (Kelvin)
end

"""
    results = gcmc_simulation(framework, temperature, pressure, adsorbate, ljforcefield)

runs a monte carlo simulation using the given framework and adsorbate.
runs at the given temperature and pressure
"""
#will pass in molecules::Array{Molecule} later
function gcmc_simulation(framework::Framework, temperature::Float64, fugacity::Float64,
                         adsorbate::String, ljforcefield::LennardJonesForceField; n_sample_cycles::Int=100000,
                         n_burn_cycles::Int=10000, sample_frequency::Int=25, verbose::Bool=false)
    if verbose
        print("Simulating adsorption of ")
        print_with_color(:green, adsorbate)
        print(" in ")
        print_with_color(:green, framework.name)
        print(" at ")
        print_with_color(:green, @sprintf("%f K", temperature))
        print(" and ")
        print_with_color(:green, @sprintf("%f Pa", fugacity))
        print(" (fugacity).")
    end

    const KB = 1.38064852e7 # Boltmann constant (Pa-m3/K --> Pa-A3/K)
    const repfactors = replication_factors(framework.box, ljforcefield)
    const simulation_box = replicate_box(framework.box, repfactors)

    current_energy_gg = 0.0 # only true if starting with 0 molecules
    current_energy_gh = 0.0
    gcmc_stats = GCMCstats(0, 0, 0, 0.0, 0.0, 0.0, 0.0, 0.0)

    molecules = Molecule[]
    
    # move encodings (i.e. if `which_move` is this, tells us which move to attempt)
    const PROPOSAL_ENCODINGS = Dict(1 => "insertion", 2 => "deletion", 3 => "translation")
    const INSERTION = 1
    const DELETION = 2
    const TRANSLATION = 3

    markov_counts = MarkovCounts([0 for i = 1:length(PROPOSAL_ENCODINGS)], [0 for i = 1:length(PROPOSAL_ENCODINGS)])
    
    # (n_burn_cycles + n_sample_cycles) is # of outer cycles; for each outer cycle, peform max(20, # molecules in the system) 
    #  Markov chain proposals.
    markov_chain_time = 0
    for outer_cycle = 1:(n_burn_cycles + n_sample_cycles), inner_cycle = 1:max(20, length(molecules))
        markov_chain_time += 1
        
        # choose move randomly; keep track of proposals
        which_move = rand(1:3)
        markov_counts.n_proposed[which_move] += 1
        
        if which_move == INSERTION
            insert_molecule!(molecules, framework.box, adsorbate)

            U_gg = guest_guest_vdw_energy(length(molecules), molecules, ljforcefield, simulation_box)
            U_gh = vdw_energy(framework, molecules[end], ljforcefield, repfactors)

            #Metropolis Hastings Acceptance for Insertion
            if rand() < fugacity * simulation_box.Ω / (length(molecules) * KB *
                    temperature) * exp(-(U_gh + U_gg) / temperature)
                # accept the move, adjust current_energy
                markov_counts.n_accepted[which_move] += 1

                current_energy_gg += U_gg
                current_energy_gh += U_gh
            else
                # reject the move, remove the inserted molecule
                pop!(molecules)
            end
        elseif (which_move == DELETION) && (length(molecules) != 0)
            # propose which molecule to delete
            molecule_id = rand(1:length(molecules))

            U_gg = guest_guest_vdw_energy(molecule_id, molecules, ljforcefield,
                simulation_box)
            U_gh = vdw_energy(framework, molecules[molecule_id], ljforcefield,
                repfactors)

            # Metropolis Hastings Acceptance for Deletion
            if rand() < fugacity * simulation_box.Ω / (length(molecules) * KB *
                    temperature) * exp((U_gh + U_gg) / temperature)
                # accept the deletion, delete molecule, adjust current_energy
                markov_counts.n_accepted[which_move] += 1

                delete_molecule!(molecule_id, molecules)

                current_energy_gg -= U_gg
                current_energy_gh -= U_gh
            end
        elseif (which_move == TRANSLATION) && (length(molecules) != 0)
            # propose which molecule whose coordinates we should perturb
            molecule_id = rand(1:length(molecules))

            # energy of the molecule before it was translated
            U_gg_old = guest_guest_vdw_energy(molecule_id, molecules,
                ljforcefield, simulation_box)
            U_gh_old = vdw_energy(framework, molecules[molecule_id],
                ljforcefield, repfactors)

            x_old = translate_molecule!(molecule_id, molecules, simulation_box)

            # energy of the molecule after it is translated
            U_gg_new = guest_guest_vdw_energy(molecule_id, molecules,
                ljforcefield, simulation_box)
            U_gh_new = vdw_energy(framework, molecules[molecule_id],
                ljforcefield, repfactors)

            # Metropolis Hastings Acceptance for translation
            if rand() < exp(-((U_gg_new + U_gh_new) - (U_gg_old + U_gh_old))
                / temperature)
                # accept the move, adjust current energy
                markov_counts.n_accepted[which_move] += 1

                current_energy_gg += U_gg_new - U_gg_old
                current_energy_gh += U_gh_new - U_gh_old
            else
                # reject the move, reset the molecule at molecule_id
                molecules[molecule_id].x = x_old
            end
        end # which move the code executes

        # sample the current configuration
        if (outer_cycle > n_burn_cycles && markov_chain_time % sample_frequency == 0)
            gcmc_stats.n_samples += 1

            gcmc_stats.n += length(molecules)
            gcmc_stats.n² += length(molecules) ^ 2

            gcmc_stats.U_gh += current_energy_gh
            gcmc_stats.U_gh² += current_energy_gh ^ 2

            gcmc_stats.U_gg += current_energy_gg
            gcmc_stats.U_gg² += current_energy_gg ^ 2

            gcmc_stats.U_ggU_gh += current_energy_gg * current_energy_gh
        end

    end #finished markov chain proposal moves

    results = Dict{String, Union{Int, Float64}}()
    results["# samples"] = gcmc_stats.n_samples
    results["⟨N⟩ (molecules)"] = gcmc_stats.n / gcmc_stats.n_samples
    results["⟨N⟩ (molecules/unit cell)"] = results["⟨N⟩ (molecules)"] /
        (repfactors[1] * repfactors[2] * repfactors[3])
    # (molecules/unit cell) * (mol/6.02 * 10^23 molecules) * (1000 mmol/mol) *
    #    (unit cell/framework amu) * (amu/ 1.66054 * 10^-24)
    results["⟨N⟩ (mmol/g)"] = results["⟨N⟩ (molecules/unit cell)"] * 1000 /
        (6.022140857e23 * molecular_weight(framework) * 1.66054e-24)
    results["⟨U_gg⟩ (K)"] = gcmc_stats.U_gg / gcmc_stats.n_samples
    results["⟨U_gh⟩ (K)"] = gcmc_stats.U_gh / gcmc_stats.n_samples
    results["⟨Energy⟩ (K)"] = (gcmc_stats.U_gg + gcmc_stats.U_gh) /
        gcmc_stats.n_samples
    #variances
    results["var(N)"] = (gcmc_stats.n² / gcmc_stats.n_samples) -
        (results["⟨N⟩ (molecules)"] ^ 2)
    results["var(U_gg)"] = (gcmc_stats.U_gg² / gcmc_stats.n_samples) -
        (results["⟨U_gg⟩ (K)"] ^ 2)
    results["var⟨U_gh⟩"] = (gcmc_stats.U_gh² / gcmc_stats.n_samples) -
        (results["⟨U_gh⟩ (K)"] ^ 2)
    results["var(Energy)"] = ((gcmc_stats.U_gg² + gcmc_stats.U_gh² + 2 *
        gcmc_stats.U_ggU_gh) / gcmc_stats.n_samples) -
        (results["⟨Energy⟩ (K)"] ^ 2)
    # move states
    for (proposal_id, proposal_description) in PROPOSAL_ENCODINGS
        results[@sprintf("Total # %s proposals", proposal_description)] = markov_counts.n_proposed[proposal_id]
        results[@sprintf("Fraction of %s proposals accepted", proposal_description)] = markov_counts.n_accepted[proposal_id] / markov_counts.n_proposed[proposal_id]
    end

    if verbose
        for (key, value) in results
            println(key * ": ", value)
        end
    end
    
    return results
end # gcmc_simulation

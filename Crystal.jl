"""All things crystal structures"""
module Crystal

export Framework, readcssr, replicate_to_xyz, correct_cssr_line, atom_error_check

global PATH_TO_STRUCTURE_FILES = homedir() * "/Dropbox/Code/PorousMaterials.jl/cssrFiles"

using Base.Test

"""
    framework = Framework(a, b, c, α, β, γ, N, atoms, f_coords, f_to_c, c_to_f)

Data structure for a 3D crystal structure.

# Arguments
- `a,b,c::Float64`: unit cell dimensions (units: Angstroms)
- `α,β,γ::Float64`: unit cell angles (units: degrees)
- `n_atoms::Int64`: number of atoms in a unit cell
- `Ω::Float64`: volume of the unit cell (units: cubic Angtroms)
- `atoms::Array{String,1}`: list of atoms composing crystal unit cell, in strict order
- `f_coords::Array{Float64,2}`: a 2D array of fractional coordinates of the atoms, in strict order;
    f_coords[:, 1] is first atom's fractional coords
- `f_to_c::Array{Float64,2}`: is a 3x3 matrix used to convert fractional coordinates to cartesian coordinates
- `c_to_f::Array{Float64,2}`: is a 3x3 matrix used to convert cartesian coordinates to fractional coordinates
"""
struct Framework
    a::Float64
    b::Float64
    c::Float64

    α::Float64
    β::Float64
    γ::Float64

    Ω::Float64

    n_atoms::Int64
    atoms::Array{String, 1}
    f_coords::Array{Float64, 2}

    f_to_C::Array{Float64, 2}
    C_to_f::Array{Float64, 2}
end

"""
    framework = readcssr("filename.cssr")

Read a .cssr file and construct a Framework object
"""
function readcssr(cssrfilename::String)
    f = open(cssrfilename, "r")
    lines = readlines(f)

    n_atoms = length(lines) - 5
    a, b, c, α, β, γ = Array{Float64}(6)
    x = Array{Float64}(n_atoms) # fractional
    y = similar(x)
    z = similar(x)
    atoms = Array{String}(n_atoms)

    for (i,line) in enumerate(lines)
        str = split(line)
        if (i == 1)
            a, b, c = map(x->parse(Float64, x), str[end-2:end])
        elseif (i == 2)
            α, β, γ = map(x->parse(Float64, x), str[3:5]).*π/180
        elseif (i > 5)
	    str = correct_cssr_line(str)
            atoms[i - 5] = str[2]
            x[i - 5], y[i - 5], z[i - 5] = map(x->parse(Float64, x), str[3:5])./[a, b, c]
        end
    end
    close(f)

    Ω = a * b * c * sqrt(1 - cos(α) ^ 2 - cos(β) ^ 2 - cos(γ) ^ 2 + 2 * cos(α) * cos(β) * cos(γ))
    f_to_C = [[a, b * cos(γ), c * cos(β)] [0, b * sin(γ), c * (cos(α) - cos(β) * cos(γ)) / sin(γ)] [0, 0, Ω / (a * b * sin(γ))]]
    C_to_f = [[1/a, -cos(γ)/(a*sin(γ)), b*c*(cos(α)*cos(γ)-cos(β))/(Ω*sin(γ))] [0, 1/(b*sin(γ)), a*c*(cos(β)*cos(γ)-cos(α))/(Ω*sin(γ))] [0, 0, a*b*sin(γ)/Ω]]
    @test f_to_C * C_to_f ≈ eye(3) 
    return Framework(a, b, c, α, β, γ, Ω, n_atoms, atoms, ([x y z]), f_to_C, C_to_f)
end

"""
    replicate_to_xyz(framework, xyzfilename, comment="")

Write a .xyz file from a Framework object. Write an optional comment to the .xyz file if desired.
Extend the structure in the x-,y- or z-direction by changing nx, ny or nz respectively.
A value of 1 replicates the structure once in the desired direction
"""
function replicate_to_xyz(framework::Framework, xyzfilename::String; comment::String="", nx::Int=0, ny::Int=0, nz::Int=0)
    f = open(xyzfilename, "w")
    @printf(f, "%d\n%s\n", framework.n_atoms * (nx + 1) * (ny + 1) * (nz + 1), comment)

    for i = 0:nx, j = 0:ny, k = 0:nz
        f_coords = framework.f_coords .+ [i j k]
        c_coords = framework.f_to_C * f_coords'
        for ii = 1:size(c_coords, 2)
            @printf(f, "%s\t%.4f\t%.4f\t%.4f\n", framework.atoms[ii], c_coords[1, ii], c_coords[2, ii], c_coords[3, ii])
        end
    end
    close(f)

    println("See ", xyzfilename)
    return
end

"""
	correct_cssr_line(str)

Take an array of string values and correct an error from the openbabel python module.
The error merges two values together if the element abbreviation contains two letters,
such as Zn, Cl and so on.
"""
function correct_cssr_line(str)
    if (length(str) == 14)
		tempbool = Array{Bool}(length(str[1]),1)
		for (k,ch) in enumerate(str[1])
			tempbool[k] = isdigit(ch)
		end

		ind = findfirst(tempbool,false);
		unshift!(str,str[1][1:ind-1])
		str[2] = str[2][ind:end]
	end
	for (k,ch) in enumerate(str[2])
		if isdigit(ch)
			str[2] = str[2][1:k-1]
			break
		end
    end
    return str
end

"""
	atom_error_check(frame)

Check if any two atoms are lying on top of each other by calculating the 2-norm distance
between every two atoms.
"""
function atom_error_check(framework::Framework)
	for i = 1:framework.n_atoms
		for k = i+1:framework.n_atoms
			distvec = [framework.f_coords[i,1]-framework.f_coords[k,1] framework.f_coords[i,2]-framework.f_coords[k,2] framework.f_coords[i,3]-framework.f_coords[k,3]].*[framework.a, framework.b, framework.c] 
			if (norm(distvec) < 0.1)
				error("At least two atoms are too close to each other (<0.1 Å)")
			end
		end
	end
	@printf("No atoms are on top of each other!")
	return
end

end # end module

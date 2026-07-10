using Pkg
using TOML

repository = get(ENV, "SATSIM_REPOSITORY", "/opt/SatelliteSimJulia")
root_project = TOML.parsefile(joinpath(repository, "Project.toml"))
test_project = TOML.parsefile(joinpath(repository, "test", "Project.toml"))
source_paths = root_project["sources"]

package_paths = String[]
for name in keys(test_project["deps"])
    if name == root_project["name"]
        push!(package_paths, repository)
    elseif haskey(source_paths, name)
        push!(package_paths, joinpath(repository, source_paths[name]["path"]))
    end
end

test_environment = mktempdir()
cp(
    joinpath(repository, "test", "Project.toml"),
    joinpath(test_environment, "Project.toml"),
)
Pkg.activate(test_environment)
Pkg.develop([Pkg.PackageSpec(path=path) for path in package_paths])
Pkg.instantiate()
Pkg.precompile()

# One-time setup of the sysimage build environment (sysimage/Project.toml + Manifest.toml):
# a copy of the repo's own Project/Manifest with the package identity (name/uuid/version/authors)
# removed, so Pkg treats it as a plain environment rather than a package with no source module.
# Re-run it whenever the repo's Project.toml/Manifest.toml change, then rebuild the image.
#
#   julia sysimage/setup_env.jl
using Pkg

const REPO = normpath(joinpath(@__DIR__, ".."))
const ENVDIR = joinpath(REPO, "sysimage")

cp(joinpath(REPO, "Manifest.toml"), joinpath(ENVDIR, "Manifest.toml"); force=true)
lines = readlines(joinpath(REPO, "Project.toml"))
write(joinpath(ENVDIR, "Project.toml"), join(filter(l -> !occursin(r"^(name|uuid|version|authors)\s*=", l), lines), "\n") * "\n")

Pkg.activate(ENVDIR)
Pkg.resolve()
Pkg.instantiate()
Pkg.status()

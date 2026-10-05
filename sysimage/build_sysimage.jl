# Builds sysimage/tos_sysimage.<dll|so|dylib> - a custom Julia system image with the heavy
# dependencies (JuMP, MathOptInterface, HiGHS, Gurobi, DataFrames, XLSX, YAML, CSV,
# Distributions) compiled in, so `using ...` costs essentially nothing at startup. The
# project's own src/lib modules are `include`d scripts, not a package, so they are still
# compiled on first use.
#
# Measured on a 16 GB Windows machine, Julia 1.12 (packages-only image, -O1):
#   startup through first solves: ~97 s -> ~32 s; memory footprint is NOT reduced.
#
# Setup + build (from the repo root; needs ~9 GB of free RAM for the compile step - close other
# apps and Julia sessions, and expect 5-10 min):
#   julia sysimage/setup_env.jl                              # once, and after Project/Manifest change
#   julia --project=sysimage sysimage/build_sysimage.jl
#
# Use it with:  julia -J sysimage/tos_sysimage.dll --project=. ...
# The image is machine- and Julia-version-specific and is git-ignored, so each machine builds
# its own. The first run after building can be slow while other packages re-precompile.
using PackageCompiler, Libdl

const REPO = normpath(joinpath(@__DIR__, ".."))
const IMAGE = joinpath(REPO, "sysimage", "tos_sysimage." * Libdl.dlext)
cd(REPO)   # warmup.jl uses repo-relative config/profile paths

# TOS_SYSIMAGE_WORKLOAD selects what gets precompiled besides the packages themselves:
#   none (default) - just the packages' own precompile statements. Tested: builds in ~9 GB.
#   full           - also trace warmup.jl (a short HiGHS + Gurobi scan). On a 16 GB machine
#                    the image-compile step passed 8.4 GB and did not finish at -O1 or higher;
#                    only worth trying with much more RAM.
const WORKLOAD = get(ENV, "TOS_SYSIMAGE_WORKLOAD", "none")
# TOS_SYSIMAGE_OPT sets the LLVM optimization level for the image compile (0-3, default 1).
# Lower levels use less RAM in the compile step, at the cost of somewhat slower compiled code
# (a 6-auction scan took ~0.4 min with the image vs ~0.3 min without; not yet re-measured).
const OPT = get(ENV, "TOS_SYSIMAGE_OPT", "1")
kwargs = merge(
    (; sysimage_build_args=`-O$OPT`),
    WORKLOAD == "full" ? (; precompile_execution_file=joinpath(REPO, "sysimage", "warmup.jl")) : (;),
)

create_sysimage(
    [:JuMP, :MathOptInterface, :HiGHS, :Gurobi, :DataFrames, :XLSX, :YAML, :CSV, :Distributions];
    sysimage_path=IMAGE,
    project=joinpath(REPO, "sysimage"),
    kwargs...,
)
println("built ", IMAGE, " (", round(filesize(IMAGE) / 2^20, digits=0), " MB)")

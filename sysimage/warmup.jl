# Workload PackageCompiler traces while building the sysimage (precompile_execution_file).
# It exercises the code paths a normal run uses - config loading (YAML/CSV/XLSX), model build,
# HiGHS and Gurobi solves, DataFrames/XLSX output - so those get compiled into the image.
# Must run with the repo root as the working directory (configs/profiles use relative paths);
# build_sysimage.jl takes care of that.
using JuMP, HiGHS, Gurobi, CSV, XLSX, DataFrames, YAML, Distributions

include(joinpath(pwd(), "src/lib/diagnostics/degeneracy_scan.jl"))

const WARMUP_CONFIG = "src/configs/experiments/rolling_36_no_cap_1d_spinup_wind_tiebreak.yaml"

# HiGHS path: ~26 clearings + 2 analysed auctions (writes per-auction + summary .xlsx)
DegeneracyScan.RunScan(WARMUP_CONFIG, "sysimage_warmup_highs", 24:25;
    solver="highs", max_workers=1, exclude_prefixes=["Qd_adj["])

# Gurobi path: same, one analysed auction
DegeneracyScan.RunScan(WARMUP_CONFIG, "sysimage_warmup_gurobi", 24:24;
    solver="gurobi", max_workers=1, exclude_prefixes=["Qd_adj["])

# generic helpers the notebooks use
df = DataFrame(a=1:10, b=rand(10), c=string.(1:10))
combine(groupby(df, :c), :b => sum)
XLSX.writetable(joinpath(mktempdir(), "warmup.xlsx"), "data" => df)

for d in ("sysimage_warmup_highs", "sysimage_warmup_gurobi")
    rm(joinpath("results", d); recursive=true, force=true)
end
println("warmup done")

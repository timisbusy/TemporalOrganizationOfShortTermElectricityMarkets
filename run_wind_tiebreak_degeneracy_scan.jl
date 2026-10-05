include("src/lib/diagnostics/degeneracy_scan.jl")

DegeneracyScan.RunScan(
    "src/configs/experiments/rolling_36_no_cap_1d_spinup_wind_tiebreak.yaml",
    "degeneracy_full_period_rolling_36_wind_tiebreak",
    :full_period; solver="highs", max_workers=4, exclude_prefixes=["Qd_adj["],
)

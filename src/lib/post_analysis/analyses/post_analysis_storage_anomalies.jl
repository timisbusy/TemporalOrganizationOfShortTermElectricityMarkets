# Storage anomaly frequency/magnitude compared across all eight market designs (Fixed/Rolling
# 36h/48h/72h, regular and high-storage agent config variants) - one row per design, counting how
# many decision-variable rows in that run's own anomalies/storage_anomalies_*.xlsx table had the
# battery simultaneously charging and discharging, plus the total MWh of that overlap.
#
# MarketDataStorage.WriteStorageAnomalies (market_data_storage.jl) only writes
# "anomalies/storage_anomalies_<name>.xlsx" when its accumulated StorageAnomalies DataFrame has
# n > 0 rows - a case directory with no such file (or no anomalies/ directory at all) therefore
# means zero storage anomalies were recorded for that run, not that the export was skipped or
# missing data. LoadStorageAnomalies below treats both cases as (0 instances, 0.0 MWh) accordingly.
#
# Each row of that table is one MTU's decision variables from one market clearing where
# StorageCharge > 0 and StorageDischarge > 0 simultaneously (see AddStorageAnomalies! in
# market_data_storage.jl); "overlapping energy" for a row is min(StorageCharge, StorageDischarge) -
# the MWh that was charged and discharged in the same MTU and so nets to zero physically, which is
# the actual anomalous quantity (unlike, say, their product, which isn't dimensionally MWh).

module PostAnalysisStorageAnomalies

using XLSX, DataFrames, Latexify

include("../post_analysis_common.jl")

# label -> single-design run directory, one per market design - same shape as
# PostAnalysisCommon.DEFAULT_CASE_PATHS/PostAnalysisConventionalGenerationCost.DEFAULT_CASE_PATHS,
# just spanning all eight designs those two suites split across PostAnalysisRunner/
# PostAnalysisWindowLengthRunner/PostAnalysisHighStorageWindowLengthRunner. Sourced from the same
# no_cap_1d_spinup run batch those runners default to.
const DEFAULT_CASE_PATHS = Dict{String,String}(
	"Fixed 36h" => "results/1789748124_fixed_36_no_cap_1d_spinup",
	"Rolling 36h" => "results/1789748169_rolling_36_no_cap_1d_spinup",
	"Rolling 48h" => "results/1789748204_rolling_48_no_cap_1d_spinup",
	"Rolling 72h" => "results/1789748246_rolling_72_no_cap_1d_spinup",
	"Fixed 36h (High Storage)" => "results/1789748824_fixed_36_no_cap_1d_spinup_high_storage",
	"Rolling 36h (High Storage)" => "results/1789748893_rolling_36_no_cap_1d_spinup_high_storage",
	"Rolling 48h (High Storage)" => "results/1789748945_rolling_48_no_cap_1d_spinup_high_storage",
	"Rolling 72h (High Storage)" => "results/1789749015_rolling_72_no_cap_1d_spinup_high_storage",
)
const DEFAULT_CASES = [
	"Fixed 36h", "Rolling 36h", "Rolling 48h", "Rolling 72h",
	"Fixed 36h (High Storage)", "Rolling 36h (High Storage)", "Rolling 48h (High Storage)", "Rolling 72h (High Storage)",
]

# kept short (not e.g. joining all eight case names) for the same Windows MAX_PATH reason as
# PostAnalysisConventionalGenerationCost.DefaultLabel - the full case_paths are still recorded
# verbatim in metadata.yaml by NewAnalysisOutputDir.
const DEFAULT_LABEL = "storage_anomalies_eight_market_designs"

# instances + total overlapping MWh for one case, scoped to time_range on the anomaly's own
# delivery MTU (not ClearingMTU) - matching how every other table in this suite scopes to
# PostAnalysisCommon.DEFAULT_TIME_RANGE via final_dispatch_decisions' own `mtu` column, so this
# table excludes the same spin-up/tail MTUs the rest of the suite does.
function LoadStorageAnomalies(case_path, time_range)
	anomalies_dir = joinpath(case_path, "anomalies")
	isdir(anomalies_dir) || return (0, 0.0)

	files = filter(f -> startswith(f, "storage_anomalies_") && endswith(f, ".xlsx"), readdir(anomalies_dir))
	isempty(files) && return (0, 0.0)

	anomalies = vcat([PostAnalysisCommon.LoadFile(joinpath(anomalies_dir, f)) for f in files]...)
	anomalies = anomalies[time_range.start .<= anomalies.mtu .<= time_range.stop, :]
	isempty(anomalies) && return (0, 0.0)

	instances = nrow(anomalies)
	overlap_mwh = sum(min.(anomalies.StorageCharge, anomalies.StorageDischarge))
	return (instances, round(overlap_mwh; digits=2))
end

function PerformAnalysis(case_paths=DEFAULT_CASE_PATHS; cases=DEFAULT_CASES, output_base=PostAnalysisCommon.NewAnalysisOutputDir(case_paths; label=DEFAULT_LABEL), time_range=PostAnalysisCommon.DEFAULT_TIME_RANGE)
	analysis_dir_path = "$output_base/storage_anomalies"
	PostAnalysisCommon.CleanDirectory(analysis_dir_path)

	df = DataFrame("Market Design" => String[], "Instances" => Int[], "Overlapping Charge/Discharge Energy (MWh)" => Float64[])
	for case in cases
		haskey(case_paths, case) || continue
		instances, overlap_mwh = LoadStorageAnomalies(case_paths[case], time_range)
		push!(df, [case, instances, overlap_mwh])
	end

	println(df)

	XLSX.writetable("$analysis_dir_path/storage_anomalies.xlsx", "data" => df; overwrite=true)

	tex = latexify(PostAnalysisCommon.EscapeForLatex(df); env=:table, booktabs=true, snakecase=true, latex=false)
	open("$analysis_dir_path/storage_anomalies.tex", "w") do io
		println(io, tex)
	end

	return df
end

end;

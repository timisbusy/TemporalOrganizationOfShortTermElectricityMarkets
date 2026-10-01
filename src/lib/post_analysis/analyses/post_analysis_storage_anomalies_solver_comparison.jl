# Storage-anomaly (simultaneous charge+discharge) frequency compared across every solver/method
# permutation (HiGHS/Gurobi x simplex/ipm/dual_simplex) for the Fixed36h/Rolling36h validation
# runs. PostAnalysisStorageAnomalies' own eight-market-design comparison doesn't vary solver/method
# at all - each of its eight cases is pinned to whatever solver its own experiment config already
# specifies - so this adds that axis using the exact same result directories (and so the exact same
# solver/method permutations) as PostAnalysisSolverComparison's trading-volume comparison, reusing
# PostAnalysisStorageAnomalies' own LoadStorageAnomalies for the counting logic. Every directory
# already has storage-anomaly detection baked into every ClearMarket run (see AddStorageAnomalies!/
# WriteStorageAnomalies in market_data_storage.jl), so this adds no new simulation runs.

module PostAnalysisStorageAnomaliesSolverComparison

using XLSX, DataFrames, Plots, Latexify

include("../post_analysis_common.jl")
include("./post_analysis_storage_anomalies.jl")
include("./post_analysis_solver_comparison.jl")

# same solver/method categories as PostAnalysisSolverComparison, minus its Laura reference row -
# Laura's raw per-clearing reference files aren't our own ClearMarket runs, so they carry no
# anomalies/storage_anomalies_*.xlsx to load.
const CATEGORIES = PostAnalysisSolverComparison.CategoriesFor(false)

# matches PostAnalysisSolverComparison's own time_range exactly, since this reuses its exact
# result directories (the validate_laura_*_36 validation runs) - not
# PostAnalysisCommon.DEFAULT_TIME_RANGE, which scopes a different (no_cap_1d_spinup) dataset.
const DEFAULT_TIME_RANGE = PostAnalysisSolverComparison.time_range

const DEFAULT_LABEL = "storage_anomalies_solver_comparison"

# instances + total overlapping MWh per solver/method category for one case, as a DataFrame - both
# the plot's source data and what gets exported to xlsx/tex.
function AnomaliesDataFrame(case, result_dirs, time_range)
	println("computing storage anomaly frequency for case: $case")

	df = DataFrame("Case" => String[], "Configuration" => String[], "Instances" => Int[], "Overlapping Charge/Discharge Energy (MWh)" => Float64[])
	for config_label in CATEGORIES
		dir = result_dirs[config_label]
		println("  loading: $config_label ($dir)")
		instances, overlap_mwh = PostAnalysisStorageAnomalies.LoadStorageAnomalies(dir, time_range)
		push!(df, [case, config_label, instances, overlap_mwh])
	end
	return df
end

# Bar chart of instance counts per solver/method category - the "frequency" question this
# comparison is asked for. The overlapping-MWh figure (a very different unit/scale) is kept in the
# table outputs only, not force-fit onto the same axis.
function PlotAnomalyFrequency(case, df)
	p = bar(
		1:nrow(df), df.Instances,
		xticks = (1:nrow(df), df.Configuration),
		xrotation = 20,
		ylabel = "Simultaneous charge/discharge instances",
		title = "$case 36h - storage anomaly frequency by solver / method",
		label = false,
		color = "#2a78d6",
		size = (900, 550),
		left_margin = 10Plots.mm,
		bottom_margin = 20Plots.mm,
	)
	return p
end

function PerformAnalysis(; time_range=DEFAULT_TIME_RANGE, output_base=PostAnalysisCommon.NewAnalysisOutputDir(PostAnalysisSolverComparison.AllResultDirs(); label=DEFAULT_LABEL))
	analysis_dir_path = "$output_base/storage_anomalies_solver_comparison"
	PostAnalysisCommon.CleanDirectory(analysis_dir_path)

	fixed_df = AnomaliesDataFrame("Fixed", PostAnalysisSolverComparison.fixed_result_dirs, time_range)
	p_fixed = PlotAnomalyFrequency("Fixed", fixed_df)
	savefig(p_fixed, "$analysis_dir_path/storage_anomalies_fixed36h.png")
	println("saved: $analysis_dir_path/storage_anomalies_fixed36h.png")

	rolling_df = AnomaliesDataFrame("Rolling", PostAnalysisSolverComparison.rolling_result_dirs, time_range)
	p_rolling = PlotAnomalyFrequency("Rolling", rolling_df)
	savefig(p_rolling, "$analysis_dir_path/storage_anomalies_rolling36h.png")
	println("saved: $analysis_dir_path/storage_anomalies_rolling36h.png")

	combined_df = vcat(fixed_df, rolling_df)
	println(combined_df)
	XLSX.writetable("$analysis_dir_path/storage_anomalies_solver_comparison.xlsx", "data" => combined_df; overwrite=true)
	println("saved: $analysis_dir_path/storage_anomalies_solver_comparison.xlsx")

	tex = latexify(PostAnalysisCommon.EscapeForLatex(combined_df); env=:table, booktabs=true, snakecase=true, latex=false)
	open("$analysis_dir_path/storage_anomalies_solver_comparison.tex", "w") do io
		println(io, tex)
	end
	println("saved: $analysis_dir_path/storage_anomalies_solver_comparison.tex")

	return (p_fixed, p_rolling, combined_df, output_base)
end

end;

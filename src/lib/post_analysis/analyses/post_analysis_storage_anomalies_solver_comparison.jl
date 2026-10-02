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
include("../../data_importer.jl")
include("../../market_clearers/market_sequence.jl")

# same solver/method categories as PostAnalysisSolverComparison, minus its Laura reference row -
# Laura's raw per-clearing reference files aren't our own ClearMarket runs, so they carry no
# anomalies/storage_anomalies_*.xlsx to load.
const CATEGORIES = PostAnalysisSolverComparison.CategoriesFor(false)

# matches PostAnalysisSolverComparison's own time_range exactly, since this reuses its exact
# result directories (the validate_laura_*_36 validation runs) - not
# PostAnalysisCommon.DEFAULT_TIME_RANGE, which scopes a different (no_cap_1d_spinup) dataset.
const DEFAULT_TIME_RANGE = PostAnalysisSolverComparison.time_range

const DEFAULT_LABEL = "storage_anomalies_solver_comparison"

# the experiment config that produced each case's result directories (fixed_result_dirs/
# rolling_result_dirs) - confirmed by skipEarlyAuctions=12/lastAuctionMTU=672 matching
# PostAnalysisSolverComparison.time_range exactly. Solver/method is the only thing that differs
# between the 5 directories within a case, so the auction schedule (and so the denominator below)
# is identical across all 5 by construction - computed once per case, not once per directory.
const EXPERIMENT_CONFIG_FOR_CASE = Dict{String,String}(
	"Fixed" => "src/configs/experiments/validate_laura_fixed_36.yaml",
	"Rolling" => "src/configs/experiments/validate_laura_rolling_36.yaml",
)

# Total count of (auction, delivery-MTU-in-window) pairs for every auction whose own clearing MTU
# falls in time_range - i.e. the sum of each scheduled auction's own optimizationWindow length.
# This is the "potential transactions" denominator for the percentage plot: every such pair is one
# decision-variable slot that could, in principle, have shown a simultaneous charge+discharge
# anomaly. Fixed's 24 sub-markets (fixed_laura.yaml) have window lengths shrinking from 36 down to
# 13 as the day progresses rather than Rolling's constant 36, so this is computed from the real
# market schedule (MarketSequence, the same scheduling code ClearMarket itself uses) rather than
# assumed to be a flat auction_count * window_length.
function TotalPotentialTransactions(experiment_config_path, time_range)
	config = DataImporter.load_input_data(experiment_config_path)
	marketSequence = MarketSequence.GenerateMarketSequence(config[:marketSequence], 0:time_range.stop)
	return sum(sum(mkt[:optimizationWindow] for mkt in MarketSequence.GetMarketsForMTU(marketSequence, t); init=0) for t in time_range)
end

# instances + total overlapping MWh + instances as a % of potential transactions, per solver/method
# category for one case, as a DataFrame - both the plots' source data and what gets exported to
# xlsx/tex.
function AnomaliesDataFrame(case, result_dirs, time_range, potential_transactions)
	println("computing storage anomaly frequency for case: $case")

	df = DataFrame("Case" => String[], "Configuration" => String[], "Instances" => Int[], "Overlapping Charge/Discharge Energy (MWh)" => Float64[], "Instances (% of Potential Transactions)" => Float64[])
	for config_label in CATEGORIES
		dir = result_dirs[config_label]
		println("  loading: $config_label ($dir)")
		instances, overlap_mwh = PostAnalysisStorageAnomalies.LoadStorageAnomalies(dir, time_range)
		pct = round(100 * instances / potential_transactions; digits=4)
		push!(df, [case, config_label, instances, overlap_mwh, pct])
	end
	return df
end

# shared across Fixed/Rolling so the two plots are directly comparable at a glance - 5000 covers
# both cases' tallest bar (Rolling's Gurobi+IPM, ~4565) with a little headroom.
const Y_MAX_INSTANCES = 5000

# Bar chart of instance counts per solver/method category - the "frequency" question this
# comparison is asked for. The overlapping-MWh figure (a very different unit/scale) is kept in the
# table outputs only, not force-fit onto the same axis.
function PlotAnomalyFrequency(case, df)
	p = bar(
		1:nrow(df), df.Instances,
		xticks = (1:nrow(df), df.Configuration),
		xrotation = 20,
		ylabel = "Simultaneous charge/discharge instances",
		ylims = (0, Y_MAX_INSTANCES),
		title = "$case 36h - storage anomaly frequency by solver / method",
		label = false,
		color = "#2a78d6",
		size = (900, 550),
		left_margin = 10Plots.mm,
		bottom_margin = 20Plots.mm,
		top_margin = 8Plots.mm,
	)
	return p
end

# Bar chart of instance counts as a percentage of potential transactions (see
# TotalPotentialTransactions) - normalizes away Fixed/Rolling's difference in total auction x
# window-length volume so the two cases' solver/method patterns sit on the same 0-100% scale.
# Kept alongside PlotAnomalyFrequency's raw-count view (not a replacement for it) - the two answer
# different questions.
function PlotAnomalyFrequencyPercent(case, df)
	p = bar(
		1:nrow(df), df[!, "Instances (% of Potential Transactions)"],
		xticks = (1:nrow(df), df.Configuration),
		xrotation = 20,
		ylabel = "Simultaneous charge/discharge instances\n(% of potential transactions)",
		ylims = (0, 100),
		title = "$case 36h - storage anomaly frequency (%) by solver / method",
		label = false,
		color = "#2a78d6",
		size = (900, 550),
		left_margin = 14Plots.mm,
		bottom_margin = 20Plots.mm,
		top_margin = 8Plots.mm,
	)

	# fixed offset (not proportional to bar height) so the label for a near-zero bar (e.g. HiGHS +
	# simplex, ~0.02%) stays legibly above it rather than sitting on/under it.
	for (i, pct) in enumerate(df[!, "Instances (% of Potential Transactions)"])
		annotate!(p, i, pct + 2.5, text("$(round(pct, digits=2))%", 9, :black, :center))
	end

	return p
end

function PerformAnalysis(; time_range=DEFAULT_TIME_RANGE, output_base=PostAnalysisCommon.NewAnalysisOutputDir(PostAnalysisSolverComparison.AllResultDirs(); label=DEFAULT_LABEL))
	analysis_dir_path = "$output_base/storage_anomalies_solver_comparison"
	PostAnalysisCommon.CleanDirectory(analysis_dir_path)

	fixed_potential = TotalPotentialTransactions(EXPERIMENT_CONFIG_FOR_CASE["Fixed"], time_range)
	rolling_potential = TotalPotentialTransactions(EXPERIMENT_CONFIG_FOR_CASE["Rolling"], time_range)
	println("potential transactions (sum of optimization window length across all auctions): Fixed=$fixed_potential, Rolling=$rolling_potential")

	fixed_df = AnomaliesDataFrame("Fixed", PostAnalysisSolverComparison.fixed_result_dirs, time_range, fixed_potential)
	p_fixed = PlotAnomalyFrequency("Fixed", fixed_df)
	savefig(p_fixed, "$analysis_dir_path/storage_anomalies_fixed36h.png")
	println("saved: $analysis_dir_path/storage_anomalies_fixed36h.png")

	p_fixed_pct = PlotAnomalyFrequencyPercent("Fixed", fixed_df)
	savefig(p_fixed_pct, "$analysis_dir_path/storage_anomalies_fixed36h_pct.png")
	println("saved: $analysis_dir_path/storage_anomalies_fixed36h_pct.png")

	rolling_df = AnomaliesDataFrame("Rolling", PostAnalysisSolverComparison.rolling_result_dirs, time_range, rolling_potential)
	p_rolling = PlotAnomalyFrequency("Rolling", rolling_df)
	savefig(p_rolling, "$analysis_dir_path/storage_anomalies_rolling36h.png")
	println("saved: $analysis_dir_path/storage_anomalies_rolling36h.png")

	p_rolling_pct = PlotAnomalyFrequencyPercent("Rolling", rolling_df)
	savefig(p_rolling_pct, "$analysis_dir_path/storage_anomalies_rolling36h_pct.png")
	println("saved: $analysis_dir_path/storage_anomalies_rolling36h_pct.png")

	combined_df = vcat(fixed_df, rolling_df)
	println(combined_df)
	XLSX.writetable("$analysis_dir_path/storage_anomalies_solver_comparison.xlsx", "data" => combined_df; overwrite=true)
	println("saved: $analysis_dir_path/storage_anomalies_solver_comparison.xlsx")

	tex = latexify(PostAnalysisCommon.EscapeForLatex(combined_df); env=:table, booktabs=true, snakecase=true, latex=false)
	open("$analysis_dir_path/storage_anomalies_solver_comparison.tex", "w") do io
		println(io, tex)
	end
	println("saved: $analysis_dir_path/storage_anomalies_solver_comparison.tex")

	return (p_fixed, p_rolling, p_fixed_pct, p_rolling_pct, combined_df, output_base)
end

end;

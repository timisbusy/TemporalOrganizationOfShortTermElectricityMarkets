# Same aggregate economic KPIs as PostAnalysisSEW (SEW, DemandUtility, ProductionCosts,
# ProducerSurplus, ConsumerSurplus, StorageRevenue, ImbalanceEnergy via
# PostAnalysisCommon.CalculateCaseIndicators, plus Wind Curtailed and Mean Final Auction Price -
# see PostAnalysisCommon.WindCurtailed/LoadMeanFinalAuctionPrice, shared with PostAnalysisSEW so
# the two can't drift apart), but compared across the three rolling-horizon optimization-window-
# length cases (36h/48h/72h) instead of PostAnalysisSEW's Fixed/Rolling pair - same shape/defaults
# as PostAnalysisConventionalGenerationCost and PostAnalysisPriceByHour. Adds a percent-difference
# column between each pair of adjacent window lengths (48h vs 36h, 72h vs 48h) rather than a single
# "vs the other case" column, since there are three cases here, not two.

module PostAnalysisWindowLengthKPIs

using XLSX, DataFrames, Latexify, Statistics

include("../post_analysis_common.jl")
include("./post_analysis_conventional_generation_cost.jl")

const DEFAULT_CASE_PATHS = PostAnalysisConventionalGenerationCost.DEFAULT_CASE_PATHS
const DEFAULT_CASES = PostAnalysisConventionalGenerationCost.DEFAULT_CASES

# Mean Final Auction Price is already an intensive €/MWh average (like
# PostAnalysisWindowLengthStorageKPIs' Avg Charging/Discharging Price), not a total over
# time_range, so it passes through the daily_average sheet unscaled rather than being divided by
# days like every other (extensive) indicator in this table.
const INTENSIVE_INDICATORS = Set([PostAnalysisCommon.MEAN_FINAL_AUCTION_PRICE_INDICATOR])

# "Name (Unit)" -> "Name (Unit/day)" for the daily-average table, so its row labels can't be
# mistaken for the same totals reported in the "totals" sheet just by glancing at the Indicator
# column - INTENSIVE_INDICATORS (already a rate, not scaled by day count) are left unchanged.
function DailyIndicatorLabel(indicator)
	indicator in INTENSIVE_INDICATORS && return indicator
	m = match(r"^(.*)\(([^()]*)\)$", indicator)
	m === nothing && return "$indicator (per day)"
	return "$(m.captures[1])($(m.captures[2])/day)"
end

function PerformAnalysis(case_paths=DEFAULT_CASE_PATHS; cases=DEFAULT_CASES, output_base=PostAnalysisCommon.NewAnalysisOutputDir(case_paths; label=PostAnalysisConventionalGenerationCost.DefaultLabel(case_paths, cases)), time_range=PostAnalysisCommon.DEFAULT_TIME_RANGE)

	length(cases) == 3 || throw("PostAnalysisWindowLengthKPIs compares exactly 3 window lengths (for the adjacent-pair %% difference columns); got $(length(cases)): $cases")
	short, mid, long = cases

	analysis_dir_path = "$output_base/window_length_kpis"
	PostAnalysisCommon.CleanDirectory(analysis_dir_path)

	# fresh per-case (economic_indicators, agent_indicators, transactions, final_dispatch_decisions,
	# mtu_economic_indicators) - see PostAnalysisCommon.CalculateCaseIndicators for why this is
	# computed on demand rather than read from a pre-aggregated economic_indicators.xlsx
	indicators_by_case = Dict(case => PostAnalysisCommon.CalculateCaseIndicators(case_paths, case; time_range=time_range, imbalance_agents=PostAnalysisCommon.DEFAULT_IMBALANCE_AGENTS) for case in cases)

	mid_vs_short_col = "$mid vs $short"
	long_vs_mid_col = "$long vs $mid"

	final_indicators_df = DataFrame("Indicator"=>String[], short=>Float64[], mid=>Float64[], long=>Float64[], mid_vs_short_col=>String[], long_vs_mid_col=>String[])

	economic_indicators_by_case = Dict(case => indicators_by_case[case].economic_indicators for case in cases)
	for indicator in names(economic_indicators_by_case[short])
		short_v = economic_indicators_by_case[short][1, indicator]
		mid_v = economic_indicators_by_case[mid][1, indicator]
		long_v = economic_indicators_by_case[long][1, indicator]
		push!(final_indicators_df, [indicator, short_v, mid_v, long_v, PostAnalysisCommon.PercentDiffString(mid_v, short_v), PostAnalysisCommon.PercentDiffString(long_v, mid_v)])
	end

	curtailed_by_case = Dict(case => PostAnalysisCommon.WindCurtailed(indicators_by_case[case].final_dispatch_decisions) for case in cases)
	push!(final_indicators_df, [PostAnalysisCommon.WIND_CURTAILED_INDICATOR, curtailed_by_case[short], curtailed_by_case[mid], curtailed_by_case[long],
		PostAnalysisCommon.PercentDiffString(curtailed_by_case[mid], curtailed_by_case[short]),
		PostAnalysisCommon.PercentDiffString(curtailed_by_case[long], curtailed_by_case[mid])])

	mean_price_by_case = Dict(case => PostAnalysisCommon.LoadMeanFinalAuctionPrice(case_paths[case], time_range) for case in cases)
	push!(final_indicators_df, [PostAnalysisCommon.MEAN_FINAL_AUCTION_PRICE_INDICATOR, mean_price_by_case[short], mean_price_by_case[mid], mean_price_by_case[long],
		PostAnalysisCommon.PercentDiffString(mean_price_by_case[mid], mean_price_by_case[short]),
		PostAnalysisCommon.PercentDiffString(mean_price_by_case[long], mean_price_by_case[mid])])

	println(final_indicators_df)

	# average daily value = total / MTU count in time_range * 24 (MTU per day) - %% differences are
	# unchanged from the totals table since all three sides scale by the same factor; only the
	# reported magnitudes differ.
	mtu_count = length(time_range)
	days = mtu_count / 24

	daily_avg_df = DataFrame("Indicator"=>String[], short=>Float64[], mid=>Float64[], long=>Float64[], mid_vs_short_col=>String[], long_vs_mid_col=>String[])
	for row in eachrow(final_indicators_df)
		scale = row.Indicator in INTENSIVE_INDICATORS ? 1.0 : 24 / mtu_count
		push!(daily_avg_df, [DailyIndicatorLabel(row.Indicator), row[short] * scale, row[mid] * scale, row[long] * scale, row[mid_vs_short_col], row[long_vs_mid_col]])
	end
	push!(daily_avg_df, ["Days in Test Range", days, days, days, "—", "—"])

	# Imbalance Energy (MWh)/days rarely lands on a clean number - round it to the hundredths place
	# on this daily table specifically (the totals table's own whole-MWh Imbalance Energy is left
	# as-is).
	daily_imbalance_energy_label = DailyIndicatorLabel("Imbalance Energy (MWh)")
	PostAnalysisCommon.RoundIndicatorRow!(daily_avg_df, daily_imbalance_energy_label, [short, mid, long])

	println(daily_avg_df)

	XLSX.writetable("$analysis_dir_path/window_length_kpis.xlsx", "totals" => final_indicators_df, "daily_average" => daily_avg_df; overwrite=true)

	totals_tex_df = PostAnalysisCommon.FormatIndicatorRowForLatex(PostAnalysisCommon.EscapeForLatex(final_indicators_df), PostAnalysisCommon.MEAN_FINAL_AUCTION_PRICE_INDICATOR, [short, mid, long])
	daily_avg_tex_df = PostAnalysisCommon.FormatIndicatorRowsForLatex(PostAnalysisCommon.EscapeForLatex(daily_avg_df), [PostAnalysisCommon.MEAN_FINAL_AUCTION_PRICE_INDICATOR, daily_imbalance_energy_label], [short, mid, long])
	totals_tex = latexify(totals_tex_df; env = :table, booktabs = true, snakecase=true, latex=false, fmt="%'\''d\n")
	daily_avg_tex = latexify(daily_avg_tex_df; env = :table, booktabs = true, snakecase=true, latex=false, fmt="%'\''d\n")

	open("$analysis_dir_path/window_length_kpis.tex", "w") do io
		println(io, totals_tex)
		println(io)
		println(io, daily_avg_tex)
	end

	return (final_indicators_df, daily_avg_df)
end

end;

# Same aggregate economic KPIs as PostAnalysisSEW (SEW, DemandUtility, ProductionCosts,
# ProducerSurplus, ConsumerSurplus, StorageRevenue, ImbalanceEnergy via
# PostAnalysisCommon.CalculateCaseEnergyIndicators (energy segment only; Imbalance Energy is omitted; wind spillage is reported separately by
# PostAnalysisSpillage), but compared across the three rolling-horizon optimization-window-
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

# "Name (Unit)" -> "Name (Unit/day)" for the daily-average table, so its row labels can't be
# mistaken for the same totals reported in the "totals" sheet just by glancing at the Indicator
# column.
function DailyIndicatorLabel(indicator)
	m = match(r"^(.*)\(([^()]*)\)$", indicator)
	m === nothing && return "$indicator (per day)"
	return "$(m.captures[1])($(m.captures[2])/day)"
end

function PerformAnalysis(case_paths=DEFAULT_CASE_PATHS; cases=DEFAULT_CASES, output_base=PostAnalysisCommon.NewAnalysisOutputDir(case_paths; label=PostAnalysisConventionalGenerationCost.DefaultLabel(case_paths, cases)), time_range=nothing)
	println("starting analysis: window length KPIs")
	# nothing: the window the runs' own configs define (see PostAnalysisCommon.ResolveTimeRange)
	time_range = PostAnalysisCommon.ResolveTimeRange(time_range, case_paths, cases; output_base=output_base)

	length(cases) == 3 || throw("PostAnalysisWindowLengthKPIs compares exactly 3 window lengths (for the adjacent-pair %% difference columns); got $(length(cases)): $cases")
	short, mid, long = cases

	analysis_dir_path = "$output_base/window_length_kpis"
	PostAnalysisCommon.CleanDirectory(analysis_dir_path)

	# fresh per-case (economic_indicators, agent_indicators, transactions, final_dispatch_decisions,
	# mtu_economic_indicators) - see PostAnalysisCommon.CalculateCaseIndicators for why this is
	# computed on demand rather than read from a pre-aggregated economic_indicators.xlsx
	# Energy segment only (energy-only final dispatch decisions + Segment == Energy transactions); see
	# PostAnalysisCommon.CalculateCaseEnergyIndicators.
	indicators_by_case = Dict(case => PostAnalysisCommon.CalculateCaseEnergyIndicators(case_paths, case; time_range=time_range, imbalance_agents=PostAnalysisCommon.DEFAULT_IMBALANCE_AGENTS) for case in cases)

	mid_vs_short_col = "$mid vs $short"
	long_vs_mid_col = "$long vs $mid"

	final_indicators_df = DataFrame("Indicator"=>String[], short=>Float64[], mid=>Float64[], long=>Float64[], mid_vs_short_col=>String[], long_vs_mid_col=>String[])

	economic_indicators_by_case = Dict(case => indicators_by_case[case].economic_indicators for case in cases)
	for indicator in names(economic_indicators_by_case[short])
		# always 0 on the energy segment (same-hour adjustments are balancing transactions) - left out for now
		indicator == "Imbalance Energy (MWh)" && continue
		short_v = economic_indicators_by_case[short][1, indicator]
		mid_v = economic_indicators_by_case[mid][1, indicator]
		long_v = economic_indicators_by_case[long][1, indicator]
		push!(final_indicators_df, [indicator, short_v, mid_v, long_v, PostAnalysisCommon.PercentDiffString(mid_v, short_v), PostAnalysisCommon.PercentDiffString(long_v, mid_v)])
	end

	println(final_indicators_df)

	# average daily value = total / MTU count in time_range * 24 (MTU per day) - %% differences are
	# unchanged from the totals table since all three sides scale by the same factor; only the
	# reported magnitudes differ.
	mtu_count = length(time_range)
	days = mtu_count / 24

	daily_avg_df = DataFrame("Indicator"=>String[], short=>Float64[], mid=>Float64[], long=>Float64[], mid_vs_short_col=>String[], long_vs_mid_col=>String[])
	for row in eachrow(final_indicators_df)
		scale = 24 / mtu_count
		push!(daily_avg_df, [DailyIndicatorLabel(row.Indicator), row[short] * scale, row[mid] * scale, row[long] * scale, row[mid_vs_short_col], row[long_vs_mid_col]])
	end
	push!(daily_avg_df, ["Days in Test Range", days, days, days, "—", "—"])

	println(daily_avg_df)

	XLSX.writetable("$analysis_dir_path/window_length_kpis.xlsx", "totals" => final_indicators_df, "daily_average" => daily_avg_df; overwrite=true)

	totals_tex_df = PostAnalysisCommon.EscapeForLatex(final_indicators_df)
	daily_avg_tex_df = PostAnalysisCommon.EscapeForLatex(daily_avg_df)
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

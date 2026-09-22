module PostAnalysisSEW

using XLSX, DataFrames, Plots, Statistics, Latexify

include("../post_analysis_common.jl")

# All of CalculateCaseIndicators' own indicators are extensive (totals over time_range), so this is
# currently empty - kept for parity with PostAnalysisWindowLengthKPIs/StorageKPIs (whose own
# Average Final Auction Price/Avg Charging/Discharging Price are already €/MWh rates) in case an
# intensive indicator is ever added here too.
const INTENSIVE_INDICATORS = Set{String}()

# "Name (Unit)" -> "Name (Unit/day)" for the daily-average table, so its row labels can't be
# mistaken for the same totals reported in the "totals" sheet just by glancing at the Indicator
# column - see PostAnalysisWindowLengthKPIs.DailyIndicatorLabel, which this mirrors exactly.
function DailyIndicatorLabel(indicator)
	indicator in INTENSIVE_INDICATORS && return indicator
	m = match(r"^(.*)\(([^()]*)\)$", indicator)
	m === nothing && return "$indicator (per day)"
	return "$(m.captures[1])($(m.captures[2])/day)"
end

# cases is (case_a, case_b) - any two case_paths keys, not just the module-default "Fixed
# Horizon"/"Rolling Horizon" pair. % Difference is case_b relative to case_a, matching the previous
# hardcoded "Rolling Horizon % Difference" (relative to Fixed Horizon) behavior.
function PerformAnalysis(case_paths; cases=("Fixed Horizon", "Rolling Horizon"), output_base=PostAnalysisCommon.NewAnalysisOutputDir(case_paths), time_range=PostAnalysisCommon.DEFAULT_TIME_RANGE)

	case_a, case_b = cases

	analysis_dir_path = "$output_base/post_analysis_SEW"

	println("starting analysis")
	PostAnalysisCommon.CleanDirectory(analysis_dir_path)

	# fresh per-case (economic_indicators, agent_indicators, transactions, finalDispatchDecisions,
	# mtu_economic_indicators) - see PostAnalysisCommon.CalculateCaseIndicators for why this is
	# computed on demand rather than read from a pre-aggregated economic_indicators.xlsx
	indicators_by_case = Dict(case => PostAnalysisCommon.CalculateCaseIndicators(case_paths, case; time_range=time_range, imbalance_agents=PostAnalysisCommon.DEFAULT_IMBALANCE_AGENTS) for case in cases)

	a = indicators_by_case[case_a].economic_indicators
	b = indicators_by_case[case_b].economic_indicators

	diff_col = "$case_b % Difference"
	final_indicators_df = DataFrame("Indicator"=>String[], case_a=>Float64[], case_b=>Float64[], diff_col=>String[])

	for indicator in names(a)
		a_v = a[1, indicator]
		b_v = b[1, indicator]
		pct_diff = PostAnalysisCommon.PercentDiffString(b_v, a_v)
		push!(final_indicators_df, [indicator, a_v, b_v, pct_diff])
	end

	# Wind Curtailment, matching Laura's "Total Wind Curtailed (MWh)" (see
	# post_analysis_laura_kpis.jl): Q_6G_Wind is the model's available-capacity time series for
	# wind (m.ext[:timeseries][:Q_gen], exported via helper_model_results.jl's "Q_$agent" column -
	# NOT the dispatched quantity), so Q_6G_Wind - 6G_Wind is exactly how much available wind went
	# undispatched each MTU. final_dispatch_decisions is already scoped to time_range by
	# CalculateCaseIndicators/CalculateEconomicIndicators.
	WindCurtailed(case) = sum(indicators_by_case[case].final_dispatch_decisions[!, Symbol("Q_6G_Wind")] .- indicators_by_case[case].final_dispatch_decisions[!, Symbol("6G_Wind")])
	a_curtailed = WindCurtailed(case_a)
	b_curtailed = WindCurtailed(case_b)
	push!(final_indicators_df, ["Wind Curtailed (MWh)", a_curtailed, b_curtailed, PostAnalysisCommon.PercentDiffString(b_curtailed, a_curtailed)])

	println(final_indicators_df)

	# average daily value = total / MTU count in time_range * 24 (MTU per day) - % difference is
	# unchanged from the totals table since both sides scale by the same factor; only the reported
	# magnitudes differ.
	mtu_count = length(time_range)
	days = mtu_count / 24

	daily_avg_df = DataFrame("Indicator"=>String[], case_a=>Float64[], case_b=>Float64[], diff_col=>String[])
	for row in eachrow(final_indicators_df)
		scale = row.Indicator in INTENSIVE_INDICATORS ? 1.0 : 24 / mtu_count
		push!(daily_avg_df, [DailyIndicatorLabel(row.Indicator), row[Symbol(case_a)] * scale, row[Symbol(case_b)] * scale, row[Symbol(diff_col)]])
	end
	push!(daily_avg_df, ["Days in Test Range", days, days, "—"])

	println(daily_avg_df)

	XLSX.writetable("$analysis_dir_path/sew_details.xlsx", "totals" => final_indicators_df, "daily_average" => daily_avg_df; overwrite=true)

	totals_tex = latexify(PostAnalysisCommon.EscapeForLatex(final_indicators_df); env = :table, booktabs = true, snakecase=true, latex=false,fmt="%'\''d\n")
	daily_avg_tex = latexify(PostAnalysisCommon.EscapeForLatex(daily_avg_df); env = :table, booktabs = true, snakecase=true, latex=false,fmt="%'\''d\n")

	open("$analysis_dir_path/sew_details.tex", "w") do io
		println(io, totals_tex)
		println(io)
		println(io, daily_avg_tex)
	end

end

end;

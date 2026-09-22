module PostAnalysisSEW

using XLSX, DataFrames, Plots, Statistics, Latexify

include("../post_analysis_common.jl")

# cases is (case_a, case_b) - any two case_paths keys, not just the module-default "Fixed
# Horizon"/"Rolling Horizon" pair. % Difference is case_b relative to case_a, matching the previous
# hardcoded "Rolling Horizon % Difference" (relative to Fixed Horizon) behavior.
function PerformAnalysis(case_paths; cases=("Fixed Horizon", "Rolling Horizon"), output_base=PostAnalysisCommon.NewAnalysisOutputDir(case_paths), time_range=PostAnalysisCommon.DEFAULT_TIME_RANGE)

	case_a, case_b = cases

	analysis_dir_path = "$output_base/post_analysis_SEW"

	println("starting analysis")
	PostAnalysisCommon.CleanDirectory(analysis_dir_path)

	# fresh per-case economic indicators (one row each) - see PostAnalysisCommon.CalculateCaseIndicators
	# for why this is computed on demand rather than read from a pre-aggregated economic_indicators.xlsx
	economic_indicators_by_case = Dict(case => PostAnalysisCommon.CalculateCaseIndicators(case_paths, case; time_range=time_range, imbalance_agents=PostAnalysisCommon.DEFAULT_IMBALANCE_AGENTS)[1] for case in cases)

	a = economic_indicators_by_case[case_a]
	b = economic_indicators_by_case[case_b]

	diff_col = "$case_b % Difference"
	final_indicators_df = DataFrame("Indicator"=>String[], case_a=>Float64[], case_b=>Float64[], diff_col=>String[])

	for indicator in names(a)
		a_v = a[1, indicator]
		b_v = b[1, indicator]
		pct_diff = PostAnalysisCommon.PercentDiffString(b_v, a_v)
		push!(final_indicators_df, [indicator, a_v, b_v, pct_diff])
	end

	println(final_indicators_df)

	# average daily value = total / MTU count in time_range * 24 (MTU per day) - % difference is
	# unchanged from the totals table since both sides scale by the same factor; only the reported
	# magnitudes differ.
	mtu_count = length(time_range)
	days = mtu_count / 24

	daily_avg_df = DataFrame("Indicator"=>String[], case_a=>Float64[], case_b=>Float64[], diff_col=>String[])
	for row in eachrow(final_indicators_df)
		push!(daily_avg_df, [row.Indicator, row[Symbol(case_a)] / mtu_count * 24, row[Symbol(case_b)] / mtu_count * 24, row[Symbol(diff_col)]])
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

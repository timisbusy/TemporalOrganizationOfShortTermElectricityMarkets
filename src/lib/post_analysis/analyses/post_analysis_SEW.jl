module PostAnalysisSEW

using XLSX, DataFrames, Plots, Statistics, Latexify

include("../post_analysis_common.jl")

CASES = PostAnalysisCommon.CASES

function PerformAnalysis(case_paths; output_base=PostAnalysisCommon.NewAnalysisOutputDir(case_paths), time_range=PostAnalysisCommon.DEFAULT_TIME_RANGE)

	analysis_dir_path = "$output_base/post_analysis_SEW"

	println("starting analysis")
	PostAnalysisCommon.CleanDirectory(analysis_dir_path)

	# fresh per-case economic indicators (one row each) - see PostAnalysisCommon.CalculateCaseIndicators
	# for why this is computed on demand rather than read from a pre-aggregated economic_indicators.xlsx
	economic_indicators_by_case = Dict(case => PostAnalysisCommon.CalculateCaseIndicators(case_paths, case; time_range=time_range, imbalance_agents=PostAnalysisCommon.DEFAULT_IMBALANCE_AGENTS)[1] for case in CASES)

	fixed = economic_indicators_by_case["Fixed Horizon"]
	rolling = economic_indicators_by_case["Rolling Horizon"]

	final_indicators_df = DataFrame("Indicator"=>String[], "Fixed Horizon"=>Float64[], "Rolling Horizon"=>Float64[], "Rolling Horizon % Difference"=>String[])

	for indicator in names(fixed)
		fixed_v = fixed[1, indicator]
		rolling_v = rolling[1, indicator]
		pct_diff = PostAnalysisCommon.PercentDiffString(rolling_v, fixed_v)
		push!(final_indicators_df, [indicator, fixed_v, rolling_v, pct_diff])
	end

	println(final_indicators_df)

	# average daily value = total / MTU count in time_range * 24 (MTU per day) - % difference is
	# unchanged from the totals table since both sides scale by the same factor; only the reported
	# magnitudes differ.
	mtu_count = length(time_range)
	days = mtu_count / 24

	daily_avg_df = DataFrame("Indicator"=>String[], "Fixed Horizon"=>Float64[], "Rolling Horizon"=>Float64[], "Rolling Horizon % Difference"=>String[])
	for row in eachrow(final_indicators_df)
		push!(daily_avg_df, [row.Indicator, row[Symbol("Fixed Horizon")] / mtu_count * 24, row[Symbol("Rolling Horizon")] / mtu_count * 24, row[Symbol("Rolling Horizon % Difference")]])
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

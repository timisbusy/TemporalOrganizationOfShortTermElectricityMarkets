module PostAnalysisSEW

using XLSX, DataFrames, Plots, Statistics, Latexify, Printf

include("./post_analysis_common.jl")

CASES = PostAnalysisCommon.CASES

percent_format = Ref(Printf.Format("%0.3f%%"))

# latexify passes string-column content straight through, unescaped - a bare "%" starts a LaTeX
# comment, silently swallowing the rest of that row. Only needed for the .tex output; the xlsx
# sheet wants the plain "%".
EscapePercentForLatex(s) = replace(s, "%" => "\\%")

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
		pct_diff = Printf.format(percent_format[], 100*(rolling_v - fixed_v)/fixed_v)
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

	pct_col = Symbol("Rolling Horizon % Difference")
	totals_tex_df = transform(final_indicators_df, pct_col => ByRow(EscapePercentForLatex) => pct_col)
	totals_tex = latexify(totals_tex_df; env = :table, booktabs = true, snakecase=true, latex=false,fmt="%'\''d\n")
	daily_avg_tex_df = transform(daily_avg_df, pct_col => ByRow(EscapePercentForLatex) => pct_col)
	daily_avg_tex = latexify(daily_avg_tex_df; env = :table, booktabs = true, snakecase=true, latex=false,fmt="%'\''d\n")

	open("$analysis_dir_path/sew_details.tex", "w") do io
		println(io, totals_tex)
		println(io)
		println(io, daily_avg_tex)
	end

end

end;

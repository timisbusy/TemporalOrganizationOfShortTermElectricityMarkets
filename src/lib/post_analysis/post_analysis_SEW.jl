module PostAnalysisSEW

using XLSX, DataFrames, Plots, Statistics, Latexify, Printf

include("./post_analysis_common.jl")

CASES = PostAnalysisCommon.CASES

function PerformAnalysis(case_paths)

	analysis_dir_path = "$(PostAnalysisCommon.ANALYSIS_OUTPUT_BASE)/post_analysis_SEW"

	println("starting analysis")
	PostAnalysisCommon.CleanDirectory(analysis_dir_path)

	# fresh per-case economic indicators (one row each) - see PostAnalysisCommon.CalculateCaseIndicators
	# for why this is computed on demand rather than read from a pre-aggregated economic_indicators.xlsx
	economic_indicators_by_case = Dict(case => PostAnalysisCommon.CalculateCaseIndicators(case_paths, case)[1] for case in CASES)

	fixed = economic_indicators_by_case["Fixed Horizon"]
	rolling = economic_indicators_by_case["Rolling Horizon"]

	percent_format = Ref(Printf.Format("%0.3f%%"))

	final_indicators_df = DataFrame("Indicator"=>String[], "Fixed Horizon"=>Float64[], "Rolling Horizon"=>Float64[], "Rolling Horizon % Difference"=>String[])

	for indicator in names(fixed)
		fixed_v = fixed[1, indicator]
		rolling_v = rolling[1, indicator]
		pct_diff = Printf.format(percent_format[], 100*(rolling_v - fixed_v)/fixed_v)
		push!(final_indicators_df, [indicator, fixed_v, rolling_v, pct_diff])
	end

	println(final_indicators_df)

	XLSX.writetable("$analysis_dir_path/sew_details.xlsx", "data" => final_indicators_df; overwrite=true)

	sew_analysis_tex = latexify(final_indicators_df; env = :table, booktabs = true, snakecase=true, latex=false,fmt="%'\''d\n")
	write("$analysis_dir_path/sew_details.tex",sew_analysis_tex)

end

end;

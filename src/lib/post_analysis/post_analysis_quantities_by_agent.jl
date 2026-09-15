module PostAnalysisQuantitiesByAgent

using XLSX, DataFrames, Plots, Statistics, Latexify, Printf

include("./post_analysis_common.jl")

CASES = PostAnalysisCommon.CASES

agent_names = ["1D_HighBid","2D_ModerateBid","3G_Base","4G_Shoulder","5G_Peak","6G_Wind","7G_Solar"]

quantitySymbol = Symbol("Quantity (MWh)")
surplusSymbol = Symbol("Surplus (€)")

percent_format = Ref(Printf.Format("%0.3f%%"))

function PerformAnalysis(case_paths)

	analysis_dir_path = "$(PostAnalysisCommon.ANALYSIS_OUTPUT_BASE)/post_analysis_quantities_by_agent"

	println("starting analysis")
	PostAnalysisCommon.CleanDirectory(analysis_dir_path)

	# fresh per-case agent indicators - see PostAnalysisCommon.CalculateCaseIndicators for why this
	# is computed on demand rather than read from a pre-aggregated agent_indicators.xlsx
	agent_indicators_by_case = Dict(case => PostAnalysisCommon.CalculateCaseIndicators(case_paths, case)[2] for case in CASES)

	AnalyzeQuantities(agent_indicators_by_case, analysis_dir_path)
	AnalyzeSurpluses(agent_indicators_by_case, analysis_dir_path)

end

function ValueForAgent(agent_indicators, agent, symbol)
	return agent_indicators[agent_indicators.Agent .== agent, symbol][1]
end

function AnalyzeQuantities(agent_indicators_by_case, analysis_dir_path)

	renamed_agent_ind_df = DataFrame("Agent"=>String[], "Fixed Horizon Quantity (GWh)"=>Float64[], "Rolling Horizon Quantity (GWh)"=>Float64[], "Rolling Horizon % Diff"=>String[])

	for agent in agent_names
		fixed_q = ValueForAgent(agent_indicators_by_case["Fixed Horizon"], agent, quantitySymbol)
		rolling_q = ValueForAgent(agent_indicators_by_case["Rolling Horizon"], agent, quantitySymbol)
		pct_diff = Printf.format(percent_format[], 100*(rolling_q - fixed_q)/fixed_q)
		push!(renamed_agent_ind_df, [agent, fixed_q/1000, rolling_q/1000, pct_diff])
	end

	println(renamed_agent_ind_df)

	XLSX.writetable("$analysis_dir_path/agent_quantities_details.xlsx", "data" => renamed_agent_ind_df; overwrite=true)

	agent_quantities_analysis_tex = latexify(renamed_agent_ind_df; env = :table, booktabs = true, snakecase=true, latex=false,fmt="%'\''d\n")
	write("$analysis_dir_path/agent_quantities.tex",agent_quantities_analysis_tex)
end

function AnalyzeSurpluses(agent_indicators_by_case, analysis_dir_path)

	renamed_agent_ind_df = DataFrame("Agent"=>String[], "Fixed Horizon Surplus (M€)"=>Float64[], "Rolling Horizon Surplus (M€)"=>Float64[], "Rolling Horizon % Diff"=>String[])

	for agent in agent_names
		fixed_s = ValueForAgent(agent_indicators_by_case["Fixed Horizon"], agent, surplusSymbol)
		rolling_s = ValueForAgent(agent_indicators_by_case["Rolling Horizon"], agent, surplusSymbol)
		pct_diff = Printf.format(percent_format[], 100*(rolling_s - fixed_s)/fixed_s)
		push!(renamed_agent_ind_df, [agent, fixed_s/1e6, rolling_s/1e6, pct_diff])
	end

	println(renamed_agent_ind_df)

	XLSX.writetable("$analysis_dir_path/agent_surplus_details.xlsx", "data" => renamed_agent_ind_df; overwrite=true)

	agent_surplus_analysis_tex = latexify(renamed_agent_ind_df; env = :table, booktabs = true, snakecase=true, latex=false,fmt="%'\''0.3f\n")
	write("$analysis_dir_path/agent_surpluses.tex",agent_surplus_analysis_tex)
end

end;

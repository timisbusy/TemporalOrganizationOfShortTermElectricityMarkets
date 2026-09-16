module PostAnalysisQuantitiesByAgent

using XLSX, DataFrames, Plots, Statistics, Latexify, Printf

include("./post_analysis_common.jl")

CASES = PostAnalysisCommon.CASES

agent_names = ["1D_HighBid","2D_ModerateBid","3G_Base","4G_Shoulder","5G_Peak","6G_Wind","7G_Solar"]
generator_names = ["3G_Base","4G_Shoulder","5G_Peak","6G_Wind","7G_Solar"]

quantitySymbol = Symbol("Quantity (MWh)")
surplusSymbol = Symbol("Surplus (€)")

percent_format = Ref(Printf.Format("%0.3f%%"))

# latexify passes string-column content straight through, unescaped - a bare "%" starts a LaTeX
# comment, silently swallowing the rest of that row. Only needed for .tex output.
EscapePercentForLatex(s) = replace(s, "%" => "\\%")

function PerformAnalysis(case_paths; output_base=PostAnalysisCommon.NewAnalysisOutputDir(case_paths), time_range=PostAnalysisCommon.DEFAULT_TIME_RANGE)

	analysis_dir_path = "$output_base/post_analysis_quantities_by_agent"

	println("starting analysis")
	PostAnalysisCommon.CleanDirectory(analysis_dir_path)

	# fresh per-case agent indicators - see PostAnalysisCommon.CalculateCaseIndicators for why this
	# is computed on demand rather than read from a pre-aggregated agent_indicators.xlsx
	agent_indicators_by_case = Dict(case => PostAnalysisCommon.CalculateCaseIndicators(case_paths, case; time_range=time_range)[2] for case in CASES)

	AnalyzeQuantities(agent_indicators_by_case, analysis_dir_path)
	AnalyzeSurpluses(agent_indicators_by_case, analysis_dir_path)
	AnalyzeGrossTradedVolume(case_paths, time_range, analysis_dir_path)

end

function ValueForAgent(agent_indicators, agent, symbol)
	return agent_indicators[agent_indicators.Agent .== agent, symbol][1]
end

function WriteComparisonTable(df, xlsx_path, tex_path)
	println(df)

	XLSX.writetable(xlsx_path, "data" => df; overwrite=true)

	pct_col = Symbol("Rolling Horizon % Diff")
	tex_df = transform(df, pct_col => ByRow(EscapePercentForLatex) => pct_col)
	tex = latexify(tex_df; env = :table, booktabs = true, snakecase=true, latex=false,fmt="%'\''d\n")
	write(tex_path, tex)
end

function AnalyzeQuantities(agent_indicators_by_case, analysis_dir_path)

	renamed_agent_ind_df = DataFrame("Agent"=>String[], "Fixed Horizon Quantity (MWh)"=>Float64[], "Rolling Horizon Quantity (MWh)"=>Float64[], "Rolling Horizon % Diff"=>String[])

	for agent in agent_names
		fixed_q = ValueForAgent(agent_indicators_by_case["Fixed Horizon"], agent, quantitySymbol)
		rolling_q = ValueForAgent(agent_indicators_by_case["Rolling Horizon"], agent, quantitySymbol)
		pct_diff = Printf.format(percent_format[], 100*(rolling_q - fixed_q)/fixed_q)
		push!(renamed_agent_ind_df, [agent, fixed_q, rolling_q, pct_diff])
	end

	WriteComparisonTable(renamed_agent_ind_df, "$analysis_dir_path/agent_quantities_details.xlsx", "$analysis_dir_path/agent_quantities.tex")
end

function AnalyzeSurpluses(agent_indicators_by_case, analysis_dir_path)

	renamed_agent_ind_df = DataFrame("Agent"=>String[], "Fixed Horizon Surplus (M€)"=>Float64[], "Rolling Horizon Surplus (M€)"=>Float64[], "Rolling Horizon % Diff"=>String[])

	for agent in agent_names
		fixed_s = ValueForAgent(agent_indicators_by_case["Fixed Horizon"], agent, surplusSymbol)
		rolling_s = ValueForAgent(agent_indicators_by_case["Rolling Horizon"], agent, surplusSymbol)
		pct_diff = Printf.format(percent_format[], 100*(rolling_s - fixed_s)/fixed_s)
		push!(renamed_agent_ind_df, [agent, fixed_s/1e6, rolling_s/1e6, pct_diff])
	end

	WriteComparisonTable(renamed_agent_ind_df, "$analysis_dir_path/agent_surplus_details.xlsx", "$analysis_dir_path/agent_surpluses.tex")
end

# Gross Traded Volume: sum(|quantity|) across every adjustment leg from every clearing that
# touched a delivered MTU, i.e. including the speculative, never-delivered tail of each clearing's
# own look-ahead window - matches Laura's calculate_generator_revenues_full (costs.jl), the same
# definition post_analysis_laura_kpis.jl uses. That module gets away with summing the whole
# transactions.xlsx unfiltered only because lastAuctionMTU bounded the entire file to time_range
# already; scoped here to time_range explicitly by Market Time Unit (the delivered MTU, not
# Clearing MTU) so it stays consistent with every other metric in this suite regardless of whether
# the run being analyzed has that cap.
function AnalyzeGrossTradedVolume(case_paths, time_range, analysis_dir_path)
	quantity_symbol = Symbol("Quantity (MWh)")
	mtu_symbol = Symbol("Market Time Unit")

	gross_traded = Dict{String,Dict{String,Float64}}()
	for case in CASES
		transactions = PostAnalysisCommon.LoadCaseFile(case_paths, case, "transactions.xlsx")
		scoped = transactions[time_range.start .<= transactions[!, mtu_symbol] .<= time_range.stop, :]
		gross_traded[case] = Dict(agent => sum(abs.(scoped[scoped.Agent .== agent, quantity_symbol])) for agent in generator_names)
	end

	renamed_agent_ind_df = DataFrame("Agent"=>String[], "Fixed Horizon Gross Traded Volume (MWh)"=>Float64[], "Rolling Horizon Gross Traded Volume (MWh)"=>Float64[], "Rolling Horizon % Diff"=>String[])
	for agent in generator_names
		fixed_v = gross_traded["Fixed Horizon"][agent]
		rolling_v = gross_traded["Rolling Horizon"][agent]
		pct_diff = Printf.format(percent_format[], 100*(rolling_v - fixed_v)/fixed_v)
		push!(renamed_agent_ind_df, [agent, fixed_v, rolling_v, pct_diff])
	end

	WriteComparisonTable(renamed_agent_ind_df, "$analysis_dir_path/agent_gross_traded_volume_details.xlsx", "$analysis_dir_path/agent_gross_traded_volume.tex")
end

end;

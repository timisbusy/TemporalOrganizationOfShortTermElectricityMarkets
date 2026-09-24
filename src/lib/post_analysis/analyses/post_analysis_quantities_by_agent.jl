module PostAnalysisQuantitiesByAgent

using XLSX, DataFrames, Plots, Statistics, Latexify

include("../post_analysis_common.jl")
include("../agent_renaming.jl")

agent_names = ["1D_HighBid","2D_ModerateBid","3G_Base","4G_Shoulder","5G_Peak","6G_Wind","7G_Solar"]
generator_names = ["3G_Base","4G_Shoulder","5G_Peak","6G_Wind","7G_Solar"]

quantitySymbol = Symbol("Quantity (MWh)")
surplusSymbol = Symbol("Surplus (€)")

function PerformAnalysis(case_paths; cases=PostAnalysisCommon.CASES, output_base=PostAnalysisCommon.NewAnalysisOutputDir(case_paths), time_range=PostAnalysisCommon.DEFAULT_TIME_RANGE)

	analysis_dir_path = "$output_base/post_analysis_quantities_by_agent"

	println("starting analysis")
	PostAnalysisCommon.CleanDirectory(analysis_dir_path)

	# fresh per-case agent indicators - see PostAnalysisCommon.CalculateCaseIndicators for why this
	# is computed on demand rather than read from a pre-aggregated agent_indicators.xlsx
	agent_indicators_by_case = Dict(case => PostAnalysisCommon.CalculateCaseIndicators(case_paths, case; time_range=time_range).agent_indicators for case in cases)

	AnalyzeQuantities(agent_indicators_by_case, cases, analysis_dir_path)
	AnalyzeSurpluses(agent_indicators_by_case, cases, analysis_dir_path)
	AnalyzeGrossTradedVolume(case_paths, cases, time_range, analysis_dir_path)

end

function ValueForAgent(agent_indicators, agent, symbol)
	return agent_indicators[agent_indicators.Agent .== agent, symbol][1]
end

function WriteComparisonTable(df, xlsx_path, tex_path)
	println(df)

	XLSX.writetable(xlsx_path, "data" => df; overwrite=true)

	tex = latexify(PostAnalysisCommon.EscapeForLatex(df); env = :table, booktabs = true, snakecase=true, latex=false,fmt="%'\''d\n")
	write(tex_path, tex)
end

# One row per agent: "{case} {metric_label}" for every case, then "{case} % Diff" for every
# non-baseline case (cases[1] is the baseline every %Diff is measured against, matching this
# suite's existing Rolling-relative-to-Fixed convention) - `value_for` is (case, agent) -> Float64.
# Shared by AnalyzeQuantities/AnalyzeSurpluses/AnalyzeGrossTradedVolume below, which differ only in
# their agent list and per-case value source.
function BuildAgentComparisonTable(agents, cases, metric_label, value_for)
	baseline = cases[1]
	pairs = Any["Agent" => String[]]
	append!(pairs, ["$case $metric_label" => Float64[] for case in cases])
	append!(pairs, ["$case % Diff" => String[] for case in cases[2:end]])
	df = DataFrame(pairs...)

	for agent in agents
		values = Dict(case => value_for(case, agent) for case in cases)
		row = Any[AgentRenaming.DisplayName(agent)]
		append!(row, [values[case] for case in cases])
		append!(row, [PostAnalysisCommon.PercentDiffString(values[case], values[baseline]) for case in cases[2:end]])
		push!(df, row)
	end

	return df
end

function AnalyzeQuantities(agent_indicators_by_case, cases, analysis_dir_path)
	df = BuildAgentComparisonTable(agent_names, cases, "Quantity (MWh)",
		(case, agent) -> ValueForAgent(agent_indicators_by_case[case], agent, quantitySymbol))
	WriteComparisonTable(df, "$analysis_dir_path/agent_quantities_details.xlsx", "$analysis_dir_path/agent_quantities.tex")
end

function AnalyzeSurpluses(agent_indicators_by_case, cases, analysis_dir_path)
	df = BuildAgentComparisonTable(agent_names, cases, "Surplus (€)",
		(case, agent) -> ValueForAgent(agent_indicators_by_case[case], agent, surplusSymbol))
	WriteComparisonTable(df, "$analysis_dir_path/agent_surplus_details.xlsx", "$analysis_dir_path/agent_surpluses.tex")
end

# Gross Traded Volume: sum(|quantity|) across every adjustment leg from every clearing that
# touched a final-auction MTU, i.e. including the speculative, never-delivered tail of each clearing's
# own look-ahead window - matches Laura's calculate_generator_revenues_full (costs.jl), the same
# definition post_analysis_laura_kpis.jl uses. That module gets away with summing the whole
# transactions.xlsx unfiltered only because lastAuctionMTU bounded the entire file to time_range
# already; scoped here to time_range explicitly by Market Time Unit (the final-auction MTU, not
# Clearing MTU) so it stays consistent with every other metric in this suite regardless of whether
# the run being analyzed has that cap.
function AnalyzeGrossTradedVolume(case_paths, cases, time_range, analysis_dir_path)
	quantity_symbol = Symbol("Quantity (MWh)")
	mtu_symbol = Symbol("Market Time Unit")

	gross_traded = Dict{String,Dict{String,Float64}}()
	for case in cases
		transactions = PostAnalysisCommon.LoadCaseFile(case_paths, case, "transactions.xlsx")
		scoped = transactions[time_range.start .<= transactions[!, mtu_symbol] .<= time_range.stop, :]
		gross_traded[case] = Dict(agent => sum(abs.(scoped[scoped.Agent .== agent, quantity_symbol])) for agent in generator_names)
	end

	df = BuildAgentComparisonTable(generator_names, cases, "Gross Traded Volume (MWh)",
		(case, agent) -> gross_traded[case][agent])
	WriteComparisonTable(df, "$analysis_dir_path/agent_gross_traded_volume_details.xlsx", "$analysis_dir_path/agent_gross_traded_volume.tex")
end

end;

# Per-agent surplus (the agent_surpluses table of post_analysis_quantities_by_agent.jl) split into the energy
# and balancing markets, the same way balancing_energy_sew.jl splits the aggregate indicators:
#
#   Total      - the existing per-agent Surplus (€) from CalculateEconomicIndicators.
#   Energy     - the same calculation on the energy-only final dispatch decisions and the Energy transactions.
#   Balancing  - read directly from the balancing side: for a demand agent, demand utility minus payments; for
#                a generator, revenue minus fuel cost, with utility and fuel cost the balancing adjustment valued
#                at the agent's bid price (see BalancingEnergySEW.BalancingTerms).
#
# Per agent, Energy + Balancing = Total is checked (a mismatch throws). Storage is not listed, as in the
# existing table: its surplus is storage revenue, which does not split additively (see balancing_energy_sew.jl).
# % Diff columns are given for Total and Energy only - balancing surpluses are small and can change sign between
# cases, which makes a percentage misleading.

module BalancingEnergySurpluses

using XLSX, DataFrames

include("balancing_energy_sew.jl")
using .BalancingEnergySEW
const BalancingEnergySplit = BalancingEnergySEW.BalancingEnergySplit
const PostAnalysisCommon = BalancingEnergySEW.PostAnalysisCommon
const MarketDataStorage = BalancingEnergySEW.MarketDataStorage
const HelperModelResults = BalancingEnergySEW.HelperModelResults

include("../agent_renaming.jl")

const SEGMENTS = BalancingEnergySEW.SEGMENTS
const SURPLUS_COLUMN = Symbol("Surplus (€)")

# the existing table's agents (storage excluded, see above)
const DEFAULT_AGENTS = ["1D_HighBid", "2D_ModerateBid", "3G_Base", "4G_Shoulder", "5G_Peak", "6G_Wind", "7G_Solar"]

# agent => segment => surplus (€)
function AgentSurplusBySegment(final_dispatch_decisions, energy_final_dispatch_decisions, transactions, agent_map, time_range; agents=DEFAULT_AGENTS)
	hasproperty(transactions, BalancingEnergySplit.SEGMENT_COLUMN) || throw("transactions have no \"$(BalancingEnergySplit.SEGMENT_COLUMN)\" column - this run predates the balancing/energy split and is not supported (rerun it)")
	hasproperty(final_dispatch_decisions, :Segment) || throw("final dispatch decisions have no \"Segment\" column - this run predates the balancing/energy split and is not supported (rerun it)")

	total = MarketDataStorage.CalculateEconomicIndicators(copy(final_dispatch_decisions), copy(transactions), agent_map, time_range).agent_indicators
	energy_transactions = transactions[transactions[!, BalancingEnergySplit.SEGMENT_COLUMN] .== BalancingEnergySplit.ENERGY, :]
	energy = MarketDataStorage.CalculateEconomicIndicators(copy(energy_final_dispatch_decisions), energy_transactions, agent_map, time_range).agent_indicators
	(; bid_valued, cash) = BalancingEnergySEW.BalancingTerms(final_dispatch_decisions, transactions, time_range)

	surplus_of(indicators, agent) = Float64(indicators[indicators.Agent .== agent, SURPLUS_COLUMN][1])
	demand_agents = agent_map[HelperModelResults.AGENT_DEMAND]

	result = Dict{String,Dict{String,Float64}}()
	for agent in agents
		balancing = MarketDataStorage.snap0(agent in demand_agents ? bid_valued(agent) - cash(agent) : cash(agent) - bid_valued(agent))
		result[agent] = Dict("Total" => surplus_of(total, agent), "Energy" => surplus_of(energy, agent), "Balancing" => balancing)
		isapprox(result[agent]["Energy"] + balancing, result[agent]["Total"]; atol=1e-3, rtol=1e-9) ||
			throw("$agent: energy surplus ($(result[agent]["Energy"])) + balancing surplus ($balancing) does not equal total ($(result[agent]["Total"]))")
	end
	return result
end

# (also used for the quantity tables of balancing_energy_quantities.jl via metric_label)
# Agent | per case: Total, Energy, Balancing | "{subject} vs {base} Total/Energy/Balancing % Diff" for each base
# case (cases[end] is the subject, as in post_analysis_quantities_by_agent.jl); the Balancing % Diff is "—".
function SurplusTable(cases, results; agents=DEFAULT_AGENTS, metric_label="Surplus (€)")
	subject = cases[end]
	base_cases = cases[1:end-1]
	pairs = Any["Agent" => String[]]
	append!(pairs, ["$case $segment $metric_label" => Float64[] for case in cases for segment in SEGMENTS])
	append!(pairs, ["$subject vs $base $segment % Diff" => String[] for base in base_cases for segment in SEGMENTS])
	table = DataFrame(pairs...)

	for agent in agents
		row = Any[get(AgentRenaming.AgentToDisplayName, agent, agent)] # unknown agents keep their own name
		append!(row, [results[case][agent][segment] for case in cases for segment in SEGMENTS])
		for base in base_cases, segment in SEGMENTS
			push!(row, segment == "Balancing" ? "—" : PostAnalysisCommon.PercentDiffString(results[subject][agent][segment], results[base][agent][segment]))
		end
		push!(table, row)
	end
	return table
end

function InterpretationTable()
	return DataFrame(
		Segment=["Total", "Energy", "Balancing", "% Diff"],
		Interpretation=[
			"The existing agent surplus: final dispatch decisions and all transactions.",
			"The same calculation on final_dispatch_decisions_energy and the Energy-segment transactions.",
			"Read directly from the agent's balancing transactions and the bid prices of the balancing rows. Energy + Balancing = Total for every agent (checked). Zero for the generators the restrict_mtu1_trading lock pins (base, shoulder, solar).",
			"Subject case vs each base case, for Total and Energy; not given for Balancing (small values that can change sign).",
		],
	)
end

# case_paths: case name => results folder of a run made with the Segment column and final_dispatch_decisions_energy.xlsx
function PerformAnalysis(case_paths; cases=collect(keys(case_paths)), output_base=PostAnalysisCommon.NewAnalysisOutputDir(case_paths), time_range=PostAnalysisCommon.DEFAULT_TIME_RANGE, agent_map=PostAnalysisCommon.DEFAULT_AGENT_MAP, agents=DEFAULT_AGENTS)
	analysis_dir_path = "$output_base/post_analysis_balancing_energy_surpluses"
	PostAnalysisCommon.CleanDirectory(analysis_dir_path)

	results = Dict(c => AgentSurplusBySegment(
		PostAnalysisCommon.LoadCaseFile(case_paths, c, "final_dispatch_decisions.xlsx"),
		PostAnalysisCommon.LoadCaseFile(case_paths, c, "final_dispatch_decisions_energy.xlsx"),
		PostAnalysisCommon.LoadCaseFile(case_paths, c, "transactions.xlsx"),
		agent_map, time_range; agents=agents) for c in cases)

	table = SurplusTable(cases, results; agents=agents)
	println(table)
	XLSX.writetable("$analysis_dir_path/agent_surplus_by_segment.xlsx", "data" => table, "interpretation" => InterpretationTable(); overwrite=true)
	return table
end

end

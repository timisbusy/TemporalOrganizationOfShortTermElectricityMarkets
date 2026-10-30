# The agent quantity and gross traded volume tables of post_analysis_quantities_by_agent.jl split into the energy
# and balancing markets, with the same Total / Energy / Balancing layout as the surplus table
# (balancing_energy_surpluses.jl):
#
#   Quantity (MWh)            - delivered dispatch per agent. Total: sum of the final dispatch decisions. Energy: sum
#                               of the energy-only final dispatch decisions (the plan before the balancing market).
#                               Balancing: the net adjustment, read directly from the agent's balancing transactions.
#                               Energy + Balancing = Total per agent (checked).
#   Gross Traded Volume (MWh) - sum of |quantity| over the generator's transactions, as in the existing table;
#                               Energy and Balancing are the sums over the Segment == Energy / Balancing
#                               transactions, which partition the total (checked).
#
# % Diff columns are given for Total and Energy only, as in the surplus table.

module BalancingEnergyQuantities

using XLSX, DataFrames

include("balancing_energy_surpluses.jl")
using .BalancingEnergySurpluses
const BalancingEnergySEW = BalancingEnergySurpluses.BalancingEnergySEW
const BalancingEnergySplit = BalancingEnergySurpluses.BalancingEnergySplit
const PostAnalysisCommon = BalancingEnergySurpluses.PostAnalysisCommon
const MarketDataStorage = BalancingEnergySurpluses.MarketDataStorage

const QUANTITY_COLUMN = Symbol("Quantity (MWh)")
const DEFAULT_AGENTS = BalancingEnergySurpluses.DEFAULT_AGENTS
const DEFAULT_GENERATORS = ["3G_Base", "4G_Shoulder", "5G_Peak", "6G_Wind", "7G_Solar"]

in_range(transactions, time_range) = transactions[time_range.start .<= transactions[!, BalancingEnergySplit.MTU_COLUMN] .<= time_range.stop, :]

# agent => segment => delivered quantity (MWh)
function AgentQuantityBySegment(final_dispatch_decisions, energy_final_dispatch_decisions, transactions, agent_map, time_range; agents=DEFAULT_AGENTS)
	hasproperty(transactions, BalancingEnergySplit.SEGMENT_COLUMN) || throw("transactions have no \"$(BalancingEnergySplit.SEGMENT_COLUMN)\" column - this run predates the balancing/energy split and is not supported (rerun it)")
	hasproperty(final_dispatch_decisions, :Segment) || throw("final dispatch decisions have no \"Segment\" column - this run predates the balancing/energy split and is not supported (rerun it)")

	total = MarketDataStorage.CalculateEconomicIndicators(copy(final_dispatch_decisions), copy(transactions), agent_map, time_range).agent_indicators
	energy_transactions = transactions[transactions[!, BalancingEnergySplit.SEGMENT_COLUMN] .== BalancingEnergySplit.ENERGY, :]
	energy = MarketDataStorage.CalculateEconomicIndicators(copy(energy_final_dispatch_decisions), energy_transactions, agent_map, time_range).agent_indicators
	balancing_transactions = in_range(transactions[transactions[!, BalancingEnergySplit.SEGMENT_COLUMN] .== BalancingEnergySplit.BALANCING, :], time_range)

	quantity_of(indicators, agent) = Float64(indicators[indicators.Agent .== agent, QUANTITY_COLUMN][1])
	result = Dict{String,Dict{String,Float64}}()
	for agent in agents
		balancing = MarketDataStorage.snap0(sum(balancing_transactions[balancing_transactions.Agent .== agent, BalancingEnergySplit.QUANTITY_COLUMN]; init=0.0))
		result[agent] = Dict("Total" => quantity_of(total, agent), "Energy" => quantity_of(energy, agent), "Balancing" => balancing)
		isapprox(result[agent]["Energy"] + balancing, result[agent]["Total"]; atol=1e-3, rtol=1e-9) ||
			throw("$agent: energy quantity ($(result[agent]["Energy"])) + balancing quantity ($balancing) does not equal total ($(result[agent]["Total"]))")
	end
	return result
end

# generator => segment => sum of |quantity| over its transactions in time_range (by delivery MTU)
function GrossTradedVolumeBySegment(transactions, time_range; generators=DEFAULT_GENERATORS)
	hasproperty(transactions, BalancingEnergySplit.SEGMENT_COLUMN) || throw("transactions have no \"$(BalancingEnergySplit.SEGMENT_COLUMN)\" column - this run predates the balancing/energy split and is not supported (rerun it)")
	scoped = in_range(transactions, time_range)
	gross(rows, agent) = MarketDataStorage.snap0(sum(abs, rows[rows.Agent .== agent, BalancingEnergySplit.QUANTITY_COLUMN]; init=0.0))
	result = Dict{String,Dict{String,Float64}}()
	for agent in generators
		by_segment = Dict(
			"Total" => gross(scoped, agent),
			"Energy" => gross(scoped[scoped[!, BalancingEnergySplit.SEGMENT_COLUMN] .== BalancingEnergySplit.ENERGY, :], agent),
			"Balancing" => gross(scoped[scoped[!, BalancingEnergySplit.SEGMENT_COLUMN] .== BalancingEnergySplit.BALANCING, :], agent),
		)
		isapprox(by_segment["Energy"] + by_segment["Balancing"], by_segment["Total"]; atol=1e-3, rtol=1e-9) ||
			throw("$agent: energy + balancing gross traded volume does not equal the total")
		result[agent] = by_segment
	end
	return result
end

function InterpretationTable()
	return DataFrame(
		Sheet=["quantities", "gross_traded_volume", "% Diff"],
		Interpretation=[
			"Delivered dispatch per agent. Energy is the energy-only final dispatch (the plan before the balancing market); Balancing is the net adjustment from the agent's balancing transactions; Energy + Balancing = Total (checked).",
			"Sum of |quantity| over the generator's transactions (including every clearing's look-ahead adjustments), split by the transactions' Segment; Energy + Balancing = Total.",
			"Subject case vs each base case, for Total and Energy; not given for Balancing.",
		],
	)
end

# case_paths: case name => results folder of a run made with the Segment column and final_dispatch_decisions_energy.xlsx
function PerformAnalysis(case_paths; cases=collect(keys(case_paths)), output_base=PostAnalysisCommon.NewAnalysisOutputDir(case_paths), time_range=PostAnalysisCommon.DEFAULT_TIME_RANGE, agent_map=PostAnalysisCommon.DEFAULT_AGENT_MAP, agents=DEFAULT_AGENTS, generators=DEFAULT_GENERATORS)
	analysis_dir_path = "$output_base/post_analysis_balancing_energy_quantities"
	PostAnalysisCommon.CleanDirectory(analysis_dir_path)

	quantities = Dict{String,Any}()
	gross_traded = Dict{String,Any}()
	for c in cases
		final = PostAnalysisCommon.LoadCaseFile(case_paths, c, "final_dispatch_decisions.xlsx")
		energy = PostAnalysisCommon.LoadCaseFile(case_paths, c, "final_dispatch_decisions_energy.xlsx")
		transactions = PostAnalysisCommon.LoadCaseFile(case_paths, c, "transactions.xlsx")
		quantities[c] = AgentQuantityBySegment(final, energy, transactions, agent_map, time_range; agents=agents)
		gross_traded[c] = GrossTradedVolumeBySegment(transactions, time_range; generators=generators)
	end

	quantity_table = BalancingEnergySurpluses.SurplusTable(cases, quantities; agents=agents, metric_label="Quantity (MWh)")
	gross_table = BalancingEnergySurpluses.SurplusTable(cases, gross_traded; agents=generators, metric_label="Gross Traded Volume (MWh)")
	println(quantity_table)
	println(gross_table)
	XLSX.writetable("$analysis_dir_path/agent_quantities_by_segment.xlsx", "quantities" => quantity_table, "gross_traded_volume" => gross_table, "interpretation" => InterpretationTable(); overwrite=true)
	return (quantities=quantity_table, gross_traded_volume=gross_table)
end

end

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
#   Storage charge / discharge (MWh) - sum of the final dispatch's StorageCharge / StorageDischarge over the range.
#                               Total: overall (all markets, i.e. after balancing). Energy: as dispatched by the
#                               energy markets (the energy-only final dispatch). No Balancing column.
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

const STORAGE_FLOWS = ["Discharge", "Charge"]
const STORAGE_SEGMENTS = ["Total", "Energy"]

# flow ("Discharge"/"Charge") => segment => MWh over time_range
function StorageFlowsBySegment(final_dispatch_decisions, energy_final_dispatch_decisions, time_range)
	hasproperty(final_dispatch_decisions, :Segment) || throw("final dispatch decisions have no \"Segment\" column - this run predates the balancing/energy split and is not supported (rerun it)")
	scoped(df) = df[time_range.start .<= df.mtu .<= time_range.stop, :]
	total, energy = scoped(final_dispatch_decisions), scoped(energy_final_dispatch_decisions)
	flow(df, f) = MarketDataStorage.snap0(sum(skipmissing(df[!, Symbol("Storage$f")]); init=0.0))
	return Dict(f => Dict("Total" => flow(total, f), "Energy" => flow(energy, f)) for f in STORAGE_FLOWS)
end

# Flow | per case: Total, Energy | "{subject} vs {base} Total/Energy % Diff" for each base case
function StorageFlowTable(cases, results)
	subject = cases[end]
	base_cases = cases[1:end-1]
	pairs = Any["Flow" => String[]]
	append!(pairs, ["$case $segment Storage (MWh)" => Float64[] for case in cases for segment in STORAGE_SEGMENTS])
	append!(pairs, ["$subject vs $base $segment % Diff" => String[] for base in base_cases for segment in STORAGE_SEGMENTS])
	table = DataFrame(pairs...)
	for f in STORAGE_FLOWS
		row = Any["Storage $(lowercase(f))d"]
		append!(row, [results[case][f][segment] for case in cases for segment in STORAGE_SEGMENTS])
		for base in base_cases, segment in STORAGE_SEGMENTS
			push!(row, PostAnalysisCommon.PercentDiffString(results[subject][f][segment], results[base][f][segment]))
		end
		push!(table, row)
	end
	return table
end

function InterpretationTable()
	return DataFrame(
		Sheet=["quantities", "gross_traded_volume", "storage_flows", "% Diff"],
		Interpretation=[
			"Delivered dispatch per agent. Energy is the energy-only final dispatch (the plan before the balancing market); Balancing is the net adjustment from the agent's balancing transactions; Energy + Balancing = Total (checked).",
			"Sum of |quantity| over the generator's transactions (including every clearing's look-ahead adjustments), split by the transactions' Segment; Energy + Balancing = Total.",
			"Storage discharge and charge summed over the range. Total: the final dispatch (overall). Energy: the energy-only final dispatch (as dispatched by the energy markets, before the balancing market). No Balancing column.",
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
	storage_flows = Dict{String,Any}()
	for c in cases
		final = PostAnalysisCommon.LoadCaseFile(case_paths, c, "final_dispatch_decisions.xlsx")
		energy = PostAnalysisCommon.LoadCaseFile(case_paths, c, "final_dispatch_decisions_energy.xlsx")
		transactions = PostAnalysisCommon.LoadCaseFile(case_paths, c, "transactions.xlsx")
		quantities[c] = AgentQuantityBySegment(final, energy, transactions, agent_map, time_range; agents=agents)
		gross_traded[c] = GrossTradedVolumeBySegment(transactions, time_range; generators=generators)
		storage_flows[c] = StorageFlowsBySegment(final, energy, time_range)
	end

	quantity_table = BalancingEnergySurpluses.SurplusTable(cases, quantities; agents=agents, metric_label="Quantity (MWh)")
	gross_table = BalancingEnergySurpluses.SurplusTable(cases, gross_traded; agents=generators, metric_label="Gross Traded Volume (MWh)")
	storage_table = StorageFlowTable(cases, storage_flows)
	println(quantity_table)
	println(gross_table)
	println(storage_table)
	XLSX.writetable("$analysis_dir_path/agent_quantities_by_segment.xlsx", "quantities" => quantity_table, "gross_traded_volume" => gross_table, "storage_flows" => storage_table, "interpretation" => InterpretationTable(); overwrite=true)
	return (quantities=quantity_table, gross_traded_volume=gross_table, storage_flows=storage_table)
end

end

# SEW and the other economic indicators of post_analysis_SEW.jl, split into the energy and balancing
# markets (see balancing_energy_split.jl for how the two are defined):
#
#   Total      - today's indicators: final dispatch decisions + every transaction, unchanged.
#   Energy     - the same calculation (MarketDataStorage.CalculateEconomicIndicators) on the energy-only final
#                dispatch decisions (final_dispatch_decisions_energy.xlsx: per MTU, the last clearing that
#                traded it as an energy MTU) and the Segment == Energy transactions.
#   Balancing  - read directly from the balancing side: the Segment == Balancing transactions give each agent's
#                adjustment per MTU, valued at that MTU's bid price from the matching balancing row of the
#                final dispatch decisions (demand utility = sum adjustment * bid, production costs likewise);
#                payments, revenues and storage revenue come from the same transactions.
#
# Total = Energy + Balancing holds for SEW, demand utility, production costs and both surpluses, and is
# checked (a mismatch throws). It does not hold for storage revenue: Total values the final storage dispatch
# at the final auction price, while Energy and Balancing are each valued at their own clearing's price, so the
# repricing of the energy position is in neither. Imbalance energy (defined on same-hour adjustments), wind
# curtailed (available wind differs between the two dispatch tables, as the forecast updates) and the mean
# price (an average) have no additive balancing part and are reported where they are defined only.
#
# None of the existing KPI code is changed by this - whether a KPI should become energy-only is decided later.

module BalancingEnergySEW

using XLSX, DataFrames, Statistics

include("balancing_energy_split.jl")
using .BalancingEnergySplit
const PostAnalysisCommon = BalancingEnergySplit.PostAnalysisCommon
const MarketDataStorage = PostAnalysisCommon.MarketDataStorage
const HelperModelResults = PostAnalysisCommon.HelperModelResults

const SEGMENTS = ["Total", "Energy", "Balancing"]

# indicators of economic_indicators (after header renaming) with an additive balancing part, in column order
const ADDITIVE_INDICATOR_POSITIONS = [1, 2, 3, 4, 5] # SEW, demand utility, production costs, producer and consumer surplus
const STORAGE_REVENUE_POSITION = 6
const IMBALANCE_POSITION = 7

# Balancing-side SEW, surpluses and storage revenue, read from the balancing transactions and the balancing
# rows of final_dispatch_decisions (restricted to time_range, by delivery MTU).
function BalancingIndicators(final_dispatch_decisions, transactions, agent_map, time_range)
	in_range(mtus) = time_range.start .<= mtus .<= time_range.stop
	balancing_rows = final_dispatch_decisions[in_range(final_dispatch_decisions.mtu) .& (final_dispatch_decisions.Segment .== BalancingEnergySplit.BALANCING), :]
	balancing_tx = transactions[in_range(transactions[!, BalancingEnergySplit.MTU_COLUMN]) .& (transactions[!, BalancingEnergySplit.SEGMENT_COLUMN] .== BalancingEnergySplit.BALANCING), :]
	row_of_mtu = Dict(mtu => i for (i, mtu) in enumerate(balancing_rows.mtu))

	# sum of (adjustment quantity) * (bid price at that MTU) for one agent's balancing transactions
	function bid_valued(agent)
		tx = balancing_tx[balancing_tx.Agent .== agent, :]
		total = 0.0
		for r in eachrow(tx)
			haskey(row_of_mtu, r[BalancingEnergySplit.MTU_COLUMN]) || throw("balancing transaction of $agent at MTU $(r[BalancingEnergySplit.MTU_COLUMN]) has no balancing row in the final dispatch decisions")
			total += r[BalancingEnergySplit.QUANTITY_COLUMN] * Float64(balancing_rows[row_of_mtu[r[BalancingEnergySplit.MTU_COLUMN]], "P_$agent"])
		end
		return total
	end
	cash(agent) = sum(tx -> tx[BalancingEnergySplit.QUANTITY_COLUMN] * tx[BalancingEnergySplit.PRICE_COLUMN], eachrow(balancing_tx[balancing_tx.Agent .== agent, :]); init=0.0)

	demand_utility = sum(bid_valued, agent_map[HelperModelResults.AGENT_DEMAND]; init=0.0)
	production_costs = sum(bid_valued, agent_map[HelperModelResults.AGENT_GENERATOR]; init=0.0)
	payments = sum(cash, agent_map[HelperModelResults.AGENT_DEMAND]; init=0.0)
	revenue = sum(cash, agent_map[HelperModelResults.AGENT_GENERATOR]; init=0.0)
	return (
		sew=demand_utility - production_costs,
		demand_utility=demand_utility,
		production_costs=production_costs,
		producer_surplus=revenue - production_costs,
		consumer_surplus=demand_utility - payments,
		storage_revenue=cash("Storage"),
	)
end

# case's indicators per segment: values[indicator][segment] => Float64 or missing (not defined for that segment)
function SewBySegment(final_dispatch_decisions, energy_final_dispatch_decisions, transactions, agent_map, time_range; imbalance_agents=nothing)
	hasproperty(transactions, BalancingEnergySplit.SEGMENT_COLUMN) || throw("transactions have no \"$(BalancingEnergySplit.SEGMENT_COLUMN)\" column - this run predates the balancing/energy split and is not supported (rerun it)")
	hasproperty(final_dispatch_decisions, :Segment) || throw("final dispatch decisions have no \"Segment\" column - this run predates the balancing/energy split and is not supported (rerun it)")

	total = MarketDataStorage.CalculateEconomicIndicators(copy(final_dispatch_decisions), copy(transactions), agent_map, time_range; imbalance_agents=imbalance_agents)
	energy_transactions = transactions[transactions[!, BalancingEnergySplit.SEGMENT_COLUMN] .== BalancingEnergySplit.ENERGY, :]
	energy = MarketDataStorage.CalculateEconomicIndicators(copy(energy_final_dispatch_decisions), energy_transactions, agent_map, time_range)
	balancing = BalancingIndicators(final_dispatch_decisions, transactions, agent_map, time_range)
	balancing_values = [balancing.sew, balancing.demand_utility, balancing.production_costs, balancing.producer_surplus, balancing.consumer_surplus, balancing.storage_revenue]

	indicator_names = names(total.economic_indicators)
	values = Dict{String,Dict{String,Union{Float64,Missing}}}()
	for (i, name) in enumerate(indicator_names)
		values[name] = Dict{String,Union{Float64,Missing}}(
			"Total" => Float64(total.economic_indicators[1, i]),
			"Energy" => i == IMBALANCE_POSITION ? missing : Float64(energy.economic_indicators[1, i]),
			"Balancing" => i <= length(balancing_values) ? balancing_values[i] : missing,
		)
	end

	# the additive indicators must add up - this is what catches a wrongly built energy table or a lost transaction
	for i in ADDITIVE_INDICATOR_POSITIONS
		v = values[indicator_names[i]]
		isapprox(v["Energy"] + v["Balancing"], v["Total"]; atol=1e-3, rtol=1e-9) ||
			throw("$(indicator_names[i]): energy ($(v["Energy"])) + balancing ($(v["Balancing"])) does not equal total ($(v["Total"]))")
	end

	in_range(df) = df[time_range.start .<= df.mtu .<= time_range.stop, :]
	total_range, energy_range = in_range(final_dispatch_decisions), in_range(energy_final_dispatch_decisions)
	extra_indicators = String[]
	# WindCurtailed is written for the wind agent of the experiment agent configs ("6G_Wind"); skip it for others
	if hasproperty(total_range, Symbol("Q_6G_Wind"))
		push!(extra_indicators, PostAnalysisCommon.WIND_CURTAILED_INDICATOR)
		values[PostAnalysisCommon.WIND_CURTAILED_INDICATOR] = Dict{String,Union{Float64,Missing}}(
			"Total" => Float64(PostAnalysisCommon.WindCurtailed(total_range)), "Energy" => Float64(PostAnalysisCommon.WindCurtailed(energy_range)), "Balancing" => missing)
	end
	push!(extra_indicators, PostAnalysisCommon.MEAN_FINAL_AUCTION_PRICE_INDICATOR)
	values[PostAnalysisCommon.MEAN_FINAL_AUCTION_PRICE_INDICATOR] = Dict{String,Union{Float64,Missing}}(
		"Total" => round(mean(total_range.FinalAuctionPrice); digits=2), "Energy" => round(mean(energy_range.FinalAuctionPrice); digits=2), "Balancing" => missing)
	return (indicator_names=vcat(indicator_names, extra_indicators), values=values)
end

# rows: indicator x segment; one column per case
function SummaryTable(cases, results)
	table = DataFrame("Indicator" => String[], "Segment" => String[])
	for c in cases
		table[!, c] = Union{Float64,Missing}[]
	end
	for indicator in results[first(cases)].indicator_names, segment in SEGMENTS
		push!(table, (indicator, segment, [results[c].values[indicator][segment] for c in cases]...))
	end
	return table
end

function InterpretationTable()
	return DataFrame(
		Segment=["Total", "Energy", "Balancing", "(empty)"],
		Interpretation=[
			"The existing indicator: final dispatch decisions and all transactions.",
			"The same calculation on final_dispatch_decisions_energy (per MTU, the last clearing that traded it as an energy MTU) and the Energy-segment transactions.",
			"Read directly from the balancing transactions (adjustment quantities, payments, revenues) and the balancing rows' bid prices. For SEW, demand utility, production costs and the surpluses, Energy + Balancing = Total (checked). Storage revenue is the balancing transactions' revenue; Total is the final storage dispatch at the final auction price, so Energy + Balancing does not equal it.",
			"Not defined for that segment: imbalance energy is a same-hour adjustment measure (Total only); wind curtailed and the mean price have no additive balancing part.",
		],
	)
end

# case_paths: case name => results folder of a run made with the Segment column and final_dispatch_decisions_energy.xlsx
function PerformAnalysis(case_paths; cases=collect(keys(case_paths)), output_base=PostAnalysisCommon.NewAnalysisOutputDir(case_paths), time_range=PostAnalysisCommon.DEFAULT_TIME_RANGE, agent_map=PostAnalysisCommon.DEFAULT_AGENT_MAP, imbalance_agents=PostAnalysisCommon.DEFAULT_IMBALANCE_AGENTS)
	analysis_dir_path = "$output_base/post_analysis_balancing_energy_sew"
	PostAnalysisCommon.CleanDirectory(analysis_dir_path)

	results = Dict(c => SewBySegment(
		PostAnalysisCommon.LoadCaseFile(case_paths, c, "final_dispatch_decisions.xlsx"),
		PostAnalysisCommon.LoadCaseFile(case_paths, c, "final_dispatch_decisions_energy.xlsx"),
		PostAnalysisCommon.LoadCaseFile(case_paths, c, "transactions.xlsx"),
		agent_map, time_range; imbalance_agents=imbalance_agents) for c in cases)

	totals = SummaryTable(cases, results)
	println(totals)

	# average daily value, as in post_analysis_SEW.jl; the mean price is an intensive indicator and stays unscaled
	scale = 24 / length(time_range)
	daily = copy(totals)
	extensive = daily.Indicator .!= PostAnalysisCommon.MEAN_FINAL_AUCTION_PRICE_INDICATOR
	for c in cases
		daily[extensive, c] = [ismissing(v) ? missing : v * scale for v in daily[extensive, c]]
	end

	XLSX.writetable("$analysis_dir_path/sew_by_segment.xlsx", "totals" => totals, "daily_average" => daily, "interpretation" => InterpretationTable(); overwrite=true)
	return totals
end

end

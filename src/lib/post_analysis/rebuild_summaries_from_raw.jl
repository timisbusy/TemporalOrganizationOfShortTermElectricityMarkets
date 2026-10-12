# Rebuilds a finished run's end-of-run summary exports (economic_indicators.xlsx, agent_indicators.xlsx,
# final_dispatch_decisions.xlsx, mtu_economic_results.xlsx and transactions.xlsx/.csv) from its
# per-clearing RAW exports (RAW/decisionvariables_*_<mtu>.xlsx and RAW/transactions_*_<mtu>.xlsx) -
# without re-solving anything. Meant for a run whose simulation completed but whose final export step
# (PlotBaselineOutcomes.plot) failed, e.g. the full-year 2025 rolling 72h run, whose transaction table
# exceeded Excel's row limit before PlotBaselineOutcomes.write_transactions existed.
#
# It reloads each clearing's RAW tables into a MarketResultContainer, in clearing order, and runs the same
# MarketDataStorage.GetEconomicIndicatorsForRange PlotBaselineOutcomes.plot runs on a live run - so the
# final-dispatch dedup (by mtu, keeping the last; price -> FinalAuctionPrice), the transaction
# concatenation and the indicators all come from MarketDataStorage rather than a copy of it here.
#
# Validate on a run whose summaries did get written before trusting it on another one: Rebuild its
# RAW into a different `output_dir` and compare against the original files.

module RebuildSummariesFromRaw

using XLSX, DataFrames, CSV

include("./post_analysis_common.jl")
include("../output_data/interpretations.jl")

const EXCEL_MAX_DATA_ROWS = 1048575

# clearing MTUs with a RAW decision variables export, ascending (= the order the clearings ran in)
function ClearingMTUs(raw_dir)
	mtus = Int[]
	for f in readdir(raw_dir)
		m = match(r"^decisionvariables_.+_(\d+)\.xlsx$", f)
		m === nothing || push!(mtus, parse(Int, m.captures[1]))
	end
	return sort(mtus)
end

function Rebuild(result_dir; test_range, output_dir=result_dir, imbalance_agents=("6G_Wind", "5G_Peak"), agent_map=PostAnalysisCommon.DEFAULT_AGENT_MAP)
	raw_dir = joinpath(result_dir, "RAW")
	dv_prefix = PostAnalysisCommon.DiscoverRawDispatchPrefix(result_dir)
	tx_prefix = joinpath(raw_dir, replace(basename(dv_prefix), "decisionvariables_" => "transactions_"; count=1))
	mtus = ClearingMTUs(raw_dir)
	println("rebuilding summaries for $result_dir from $(length(mtus)) clearings (MTU $(first(mtus)):$(last(mtus))), analysis range $test_range")

	# Refill a MarketResultContainer with just the fields the aggregation reads (TimeCleared,
	# AgentMap, DecisionVariables, Transactions) and let MarketDataStorage do the rest, so the
	# final-dispatch dedup, transaction concatenation and indicator calculation are the very same
	# code PlotBaselineOutcomes.plot runs on a live run's container - no copy to drift out of sync.
	MDS = PostAnalysisCommon.MarketDataStorage
	container = MDS.MakeMarketResultContainer()
	for (i, mtu) in enumerate(mtus)
		mr = MDS.MarketResult()
		mr.TimeCleared = mtu
		mr.AgentMap = agent_map
		mr.DecisionVariables = DataFrame(XLSX.readtable("$(dv_prefix)$(mtu).xlsx", "data"))
		mr.Transactions = DataFrame(XLSX.readtable("$(tx_prefix)$(mtu).xlsx", "data"))
		push!(container.Results, mr)
		i % 500 == 0 && println("  read $i / $(length(mtus)) clearings")
	end

	(indicators, agent_indicators, transactions, final_dispatch_decisions, mtu_economic_outcomes) =
		MDS.GetEconomicIndicatorsForRange(container, test_range; imbalance_agents=imbalance_agents)
	container = nothing

	mkpath(output_dir)
	XLSX.writetable(joinpath(output_dir, "economic_indicators.xlsx"), "data" => indicators, "interpretation" => Interpretations.EconomicIndicatorsInterpretation; overwrite=true)
	XLSX.writetable(joinpath(output_dir, "agent_indicators.xlsx"), "data" => agent_indicators, "interpretation" => Interpretations.AgentIndicatorsInterpretation; overwrite=true)
	XLSX.writetable(joinpath(output_dir, "final_dispatch_decisions.xlsx"), "data" => final_dispatch_decisions, "interpretation" => Interpretations.DecisionVariablesInterpretation; overwrite=true)
	XLSX.writetable(joinpath(output_dir, "mtu_economic_results.xlsx"), "data" => mtu_economic_outcomes; overwrite=true)
	# same rule as PlotBaselineOutcomes.write_transactions
	if nrow(transactions) > EXCEL_MAX_DATA_ROWS
		println("$(nrow(transactions)) transactions exceed Excel's $(EXCEL_MAX_DATA_ROWS) row limit - writing transactions.csv")
		CSV.write(joinpath(output_dir, "transactions.csv"), transactions)
	else
		XLSX.writetable(joinpath(output_dir, "transactions.xlsx"), "data" => transactions, "interpretation" => Interpretations.TransactionsInterpretation; overwrite=true)
	end
	println("done: wrote summaries to $output_dir")
	return (indicators=indicators, agent_indicators=agent_indicators)
end

end;

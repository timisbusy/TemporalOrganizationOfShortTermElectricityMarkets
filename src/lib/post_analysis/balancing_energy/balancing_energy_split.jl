# Splits a run's transactions into the balancing market (the first MTU of a clearing whose
# restrict_mtu1_trading lock was applied - see MarketDataStorage / HelperModelResults.TransactionSegment)
# and the energy market (every other transaction). The split is read from the "Segment" column the
# simulation wrote, never re-derived here, so it can't disagree with the lock the model actually applied;
# runs from before that column existed are rejected rather than guessed at.
#
# Writes the two halves as transactions_balancing / transactions_energy (derived exports - the run's own
# transactions.xlsx stays the single source of truth) plus a summary table whose Total rows are checked
# against the unsplit transactions. Kept apart from the older post-analysis modules on purpose: none of
# the existing KPIs are changed by this, whether they should become energy-only is decided per KPI later.

module BalancingEnergySplit

using XLSX, DataFrames, CSV

include("../post_analysis_common.jl")

const SEGMENT_COLUMN = "Segment"
const BALANCING = "Balancing"
const ENERGY = "Energy"

const QUANTITY_COLUMN = "Quantity (MWh)"
const PRICE_COLUMN = "Price (€/MWh)"
const MTU_COLUMN = "Market Time Unit"

# same Excel sheet limit PlotBaselineOutcomes.write_transactions works around
const EXCEL_MAX_DATA_ROWS = 1048575

# Partition of `transactions` by its Segment column: every row lands in exactly one of the two results.
# `time_range`, if given, restricts both halves to those delivery MTUs ("Market Time Unit").
function SplitSegments(transactions; time_range=nothing)
	hasproperty(transactions, SEGMENT_COLUMN) || throw("transactions have no \"$SEGMENT_COLUMN\" column - this run predates the balancing/energy split and is not supported (rerun it)")
	unknown = setdiff(unique(transactions[!, SEGMENT_COLUMN]), [BALANCING, ENERGY])
	isempty(unknown) || throw("unknown $SEGMENT_COLUMN values in transactions: $unknown")
	if time_range !== nothing
		transactions = transactions[time_range.start .<= transactions[!, MTU_COLUMN] .<= time_range.stop, :]
	end
	balancing = transactions[transactions[!, SEGMENT_COLUMN] .== BALANCING, :]
	energy = transactions[transactions[!, SEGMENT_COLUMN] .== ENERGY, :]
	nrow(balancing) + nrow(energy) == nrow(transactions) || throw("balancing and energy transactions do not partition the transactions")
	return (balancing, energy)
end

function WriteTransactions(path_without_extension, transactions)
	if nrow(transactions) > EXCEL_MAX_DATA_ROWS
		CSV.write("$path_without_extension.csv", transactions)
	else
		XLSX.writetable("$path_without_extension.xlsx", "data" => transactions; overwrite=true)
	end
end

const AGENT_TYPE_COLUMN = "Agent Type"
const TOTALS_FIELDS = (:rows, :net_mwh, :gross_mwh, :net_payments)

# Rows, net and gross (sum of |quantity|) traded MWh, and net payments (sum of quantity * price) for one set
# of transactions. Only meaningful within one agent type: generator, demand and storage quantities carry
# different meanings and must not be added together.
function SegmentTotals(transactions)
	return (
		rows=nrow(transactions),
		net_mwh=sum(transactions[!, QUANTITY_COLUMN]; init=0.0),
		gross_mwh=sum(abs, transactions[!, QUANTITY_COLUMN]; init=0.0),
		net_payments=sum(transactions[!, QUANTITY_COLUMN] .* transactions[!, PRICE_COLUMN]; init=0.0),
	)
end

const NO_TRANSACTIONS = (rows=0, net_mwh=0.0, gross_mwh=0.0, net_payments=0.0)

# agent type => totals, for the agent types present in `agent_types`
TotalsByAgentType(transactions, agent_types) = Dict(t => SegmentTotals(transactions[transactions[!, AGENT_TYPE_COLUMN] .== t, :]) for t in agent_types)

# results[case][segment][agent type] => totals. Row counts are also reported over all agent types ("All");
# the quantity and payment indicators only per agent type.
function SummaryTable(cases, results)
	indicators = ["Transactions", "Net traded (MWh)", "Gross traded (MWh)", "Net payments (€)"]
	table = DataFrame("Indicator" => String[], "Agent Type" => String[], "Segment" => String[])
	for c in cases
		table[!, c] = Float64[]
	end
	agent_types = sort(unique(vcat([collect(keys(results[c]["Total"])) for c in cases]...)))
	for agent_type in vcat("All", agent_types), (indicator, field) in zip(indicators, TOTALS_FIELDS)
		agent_type == "All" && field != :rows && continue
		for segment in (BALANCING, ENERGY, "Total")
			case_values = map(cases) do c
				by_type = results[c][segment]
				agent_type == "All" ? Float64(sum(t.rows for t in values(by_type); init=0)) : Float64(getproperty(get(by_type, agent_type, NO_TRANSACTIONS), field))
			end
			push!(table, (indicator, agent_type, segment, case_values...))
		end
	end
	return table
end

function InterpretationTable()
	return DataFrame(
		DataPoint=["Balancing", "Energy", "Total", "transactions_balancing / transactions_energy"],
		Interpretation=[
			"Transactions in the first MTU of a clearing whose restrict_mtu1_trading lock was applied, as tagged by the model that cleared it.",
			"Every other transaction, including all of the first clearing and of markets that override the lock.",
			"All transactions in the range; checked to equal Balancing + Energy for every indicator.",
			"The two halves of the run's transactions, as separate derived tables. The run's own transactions file is unchanged.",
		],
	)
end

# case_paths: case name => results folder of a run made with the Segment column; time_range: delivery MTUs
# to include (nothing = all)
function PerformAnalysis(case_paths; cases=collect(keys(case_paths)), output_base=PostAnalysisCommon.NewAnalysisOutputDir(case_paths), time_range=nothing)
	analysis_dir_path = "$output_base/post_analysis_balancing_energy_split"
	PostAnalysisCommon.CleanDirectory(analysis_dir_path)

	results = Dict{String,Any}()
	for c in cases
		transactions = PostAnalysisCommon.LoadCaseFile(case_paths, c, "transactions.xlsx")
		(balancing, energy) = SplitSegments(transactions; time_range=time_range)
		slug = PostAnalysisCommon.CaseSlug(c)
		WriteTransactions("$analysis_dir_path/transactions_balancing_$slug", balancing)
		WriteTransactions("$analysis_dir_path/transactions_energy_$slug", energy)
		# the total comes from the unsplit transactions, so the check below can actually catch a lost or doubled row
		in_range = time_range === nothing ? transactions : transactions[time_range.start .<= transactions[!, MTU_COLUMN] .<= time_range.stop, :]
		agent_types = unique(in_range[!, AGENT_TYPE_COLUMN])
		results[c] = Dict(BALANCING => TotalsByAgentType(balancing, agent_types), ENERGY => TotalsByAgentType(energy, agent_types), "Total" => TotalsByAgentType(in_range, agent_types))
		for agent_type in agent_types, field in TOTALS_FIELDS
			split_sum = getproperty(results[c][BALANCING][agent_type], field) + getproperty(results[c][ENERGY][agent_type], field)
			isapprox(split_sum, getproperty(results[c]["Total"][agent_type], field); atol=1e-6, rtol=1e-9) ||
				throw("$c: balancing + energy $field for $agent_type does not equal the total")
		end
	end

	summary = SummaryTable(cases, results)
	println(summary)
	XLSX.writetable("$analysis_dir_path/balancing_energy_summary.xlsx", "summary" => summary, "interpretation" => InterpretationTable(); overwrite=true)
	return summary
end

end

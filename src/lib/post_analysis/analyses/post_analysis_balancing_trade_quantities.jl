# Trade quantities by agent in the balancing segment only: what each agent traded in the locked (balancing)
# MTUs of the clearings, read from the Segment == Balancing transactions (see
# balancing_energy/balancing_energy_split.jl for how the two segments are defined). Per agent, over the analysis
# time_range (transactions bucketed by delivery MTU, like every other metric in this suite):
#
#   Net traded (MWh)     - sum of the signed transaction quantities
#   Gross traded (MWh)   - sum of |quantity|
#   Increases (MWh)      - sum of the positive quantities
#   Decreases (MWh)      - sum of the negative quantities (reported as a negative number)
#
# Quantities are adjustments to what the agent had already traded in earlier clearings, so net traded is the
# agent's net change from balancing and gross traded how much it moved. One row per agent and metric, one
# column per case, then MWh difference columns (compared minus base, not percentages): by default "{case} vs {previous case}" for each adjacent pair
# (the window-length suite: 48h vs 36h, 72h vs 48h), or with compare_to_subject=true "{last case} vs {base}" for
# every other case (the fixed vs rolling suite's convention: cases[end] is the subject, see PostAnalysisSEW). For
# two cases the two are identical.

module PostAnalysisBalancingTradeQuantities

using XLSX, DataFrames, Latexify

include("../post_analysis_common.jl")
include("../agent_renaming.jl")

const AGENTS = ["1D_HighBid", "2D_ModerateBid", "3G_Base", "4G_Shoulder", "5G_Peak", "6G_Wind", "7G_Solar", "Storage"]
const BALANCING_SEGMENT = "Balancing"

const NET = "Net traded (MWh)"
const GROSS = "Gross traded (MWh)"
const INCREASES = "Increases (MWh)"
const DECREASES = "Decreases (MWh)"
const METRICS = [NET, GROSS, INCREASES, DECREASES]

const SEGMENT_COLUMN = Symbol("Segment")
const MTU_COLUMN = Symbol("Market Time Unit")
const QUANTITY_COLUMN = Symbol("Quantity (MWh)")

DisplayName(agent) = agent == "Storage" ? "Storage" : AgentRenaming.DisplayName(agent)

# near-zero float noise (e.g. a generator the lock pins, summed over thousands of transactions) reported as exactly 0.0
snap(x) = PostAnalysisCommon.MarketDataStorage.snap0(x)

# metric => value for one agent's balancing quantities
function TradeQuantities(quantities)
	return Dict(
		NET => snap(sum(quantities; init=0.0)),
		GROSS => snap(sum(abs, quantities; init=0.0)),
		INCREASES => snap(sum(q -> max(q, 0.0), quantities; init=0.0)),
		DECREASES => snap(sum(q -> min(q, 0.0), quantities; init=0.0)),
	)
end

# agent => metric => value, from one case's transactions restricted to time_range and the balancing segment
function BalancingTradeQuantities(transactions, time_range; agents=AGENTS)
	hasproperty(transactions, SEGMENT_COLUMN) || throw("transactions have no \"$SEGMENT_COLUMN\" column - this run predates the balancing/energy split; rerun it")
	in_range = time_range.start .<= transactions[!, MTU_COLUMN] .<= time_range.stop
	balancing = transactions[in_range .& (transactions[!, SEGMENT_COLUMN] .== BALANCING_SEGMENT), :]
	return Dict(agent => TradeQuantities(Float64.(balancing[balancing.Agent .== agent, QUANTITY_COLUMN])) for agent in agents)
end

# rows: agent x metric; columns: Agent, Metric, one per case, then "{case} vs {previous case} (MWh)" (the difference)
function BuildTable(quantities_by_case, cases; agents=AGENTS, compare_to_subject=false)
	# (compared, base) index pairs of the MWh difference columns
	comparisons = compare_to_subject ? [(length(cases), i) for i in 1:length(cases)-1] : [(i, i-1) for i in 2:length(cases)]
	pairs = Any["Agent" => String[], "Metric" => String[]]
	append!(pairs, [case => Float64[] for case in cases])
	append!(pairs, ["$(cases[c]) vs $(cases[b]) (MWh)" => Float64[] for (c, b) in comparisons])
	df = DataFrame(pairs...)
	for agent in agents, metric in METRICS
		values = [quantities_by_case[case][agent][metric] for case in cases]
		row = Any[DisplayName(agent), metric]
		append!(row, values)
		append!(row, [snap(values[c] - values[b]) for (c, b) in comparisons])
		push!(df, row)
	end
	return df
end

# The LaTeX table is a reduced view of the full table (which the xlsx keeps): Net traded only, labelled "Net energy
# traded (MWh)", plus Energy increases / decreases for storage; Base, Shoulder and Solar are left out since the lock
# keeps them from trading in the balancing segment.
const TEX_EXCLUDED_AGENTS = ["3G_Base", "4G_Shoulder", "7G_Solar"]
const TEX_METRIC_LABELS = Dict(NET => "Net energy traded (MWh)", INCREASES => "Energy increases (MWh)", DECREASES => "Energy decreases (MWh)")
const TEX_STORAGE_ONLY_METRICS = [INCREASES, DECREASES]

function TexTable(df)
	excluded = DisplayName.(TEX_EXCLUDED_AGENTS)
	storage = DisplayName("Storage")
	keep = [!(row.Agent in excluded) && (row.Metric == NET || (row.Agent == storage && row.Metric in TEX_STORAGE_ONLY_METRICS)) for row in eachrow(df)]
	out = df[keep, :]
	out[!, :Metric] = [TEX_METRIC_LABELS[m] for m in out.Metric]
	return out
end

function InterpretationTable()
	return DataFrame(
		Metric=METRICS,
		Interpretation=[
			"Sum of the signed Segment == Balancing transaction quantities of the agent: its net change from balancing.",
			"Sum of the absolute quantities: how much the agent moved in the balancing segment.",
			"Sum of the positive quantities.",
			"Sum of the negative quantities (a negative number).",
		],
	)
end

# cases is any N case_paths keys; time_range nothing is the window the runs' own configs define
# (see PostAnalysisCommon.ResolveTimeRange)
function PerformAnalysis(case_paths; cases=PostAnalysisCommon.CASES, output_base=PostAnalysisCommon.NewAnalysisOutputDir(case_paths), time_range=nothing, compare_to_subject=false)
	println("starting analysis: balancing trade quantities")
	time_range = PostAnalysisCommon.ResolveTimeRange(time_range, case_paths, cases; output_base=output_base)

	analysis_dir_path = "$output_base/balancing_trade_quantities"
	PostAnalysisCommon.CleanDirectory(analysis_dir_path)

	quantities_by_case = Dict(case => BalancingTradeQuantities(PostAnalysisCommon.LoadCaseFile(case_paths, case, "transactions.xlsx"), time_range) for case in cases)
	df = BuildTable(quantities_by_case, cases; compare_to_subject=compare_to_subject)
	println(df)

	XLSX.writetable("$analysis_dir_path/balancing_trade_quantities.xlsx", "data" => df, "interpretation" => InterpretationTable(); overwrite=true)
	write("$analysis_dir_path/balancing_trade_quantities.tex",
		latexify(PostAnalysisCommon.EscapeForLatex(TexTable(df)); env=:table, booktabs=true, snakecase=true, latex=false, fmt="%'\''d\n"))
	return df
end

end;

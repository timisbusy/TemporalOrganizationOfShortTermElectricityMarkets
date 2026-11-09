# The balancing/energy split tables (src/lib/post_analysis/balancing_energy/) for the optimization-window-length
# comparison: the same fields as the fixed vs rolling versions - SEW and the other economic indicators, per-agent
# surplus, agent quantities, generator gross traded volume and storage charge/discharge, each split into Total,
# Energy and Balancing (see balancing_energy_split.jl for how the segments are defined) - but with the cases being
# rolling-horizon window lengths (36h/48h/72h) and compared pairwise: "{case} vs {previous case}" for each adjacent
# pair (48h vs 36h, 72h vs 48h).
#
# The comparison columns are differences in the metric's own unit (EUR, MWh, EUR/MWh for the mean price), compared
# minus base, not percentages, and are given for every segment - including Balancing, where percentages are
# misleading because the values are small and change sign. A difference is missing where either value is (a metric
# not defined for that segment, e.g. imbalance energy outside Total). The per-case columns are unchanged from the
# existing tables, so Energy + Balancing = Total still holds in each case (checked by the underlying calculations).
#
# Output (into {output_base}/balancing_energy/balancing_energy.xlsx): sheets "sew" (totals over the analysed range)
# and "sew_daily" (average per day, the mean price unscaled), "surplus", "quantities", "gross_traded_volume",
# "storage_flows" (Total and Energy only: storage has no balancing part) and "interpretation".

module PostAnalysisWindowLengthBalancingEnergy

using XLSX, DataFrames

include("../balancing_energy/balancing_energy_quantities.jl")
const Quantities = BalancingEnergyQuantities
const Surpluses = BalancingEnergyQuantities.BalancingEnergySurpluses
const SEW = BalancingEnergyQuantities.BalancingEnergySEW
const PostAnalysisCommon = Quantities.PostAnalysisCommon
const AgentRenaming = Surpluses.AgentRenaming

const SEGMENTS = Surpluses.SEGMENTS # Total, Energy, Balancing
const STORAGE_SEGMENTS = Quantities.STORAGE_SEGMENTS # Total, Energy

# cases are compared pairwise: (compared, base) index pairs of adjacent cases
AdjacentPairs(cases) = [(i, i - 1) for i in 2:length(cases)]

Difference(compared, base) = (ismissing(compared) || ismissing(base)) ? missing : Surpluses.MarketDataStorage.snap0(Float64(compared) - Float64(base))

# Rows: item x segment. Columns: item_label, Segment, one per case, then "{case} vs {previous case} (difference)".
# value(case, item, segment) -> Float64 or missing.
function BuildTable(cases, items, segments, value; item_label)
	pairs = Any[item_label => String[], "Segment" => String[]]
	append!(pairs, [case => Union{Float64,Missing}[] for case in cases])
	append!(pairs, ["$(cases[c]) vs $(cases[b]) (difference)" => Union{Float64,Missing}[] for (c, b) in AdjacentPairs(cases)])
	table = DataFrame(pairs...)
	for item in items, segment in segments
		values = [value(case, item, segment) for case in cases]
		push!(table, Any[item, segment, values..., [Difference(values[c], values[b]) for (c, b) in AdjacentPairs(cases)]...])
	end
	return table
end

AgentLabel(agent) = get(AgentRenaming.AgentToDisplayName, agent, agent)

# SEW table (totals) from the per-case SewBySegment results; the daily sheet scales every indicator but the mean price
function SewTables(cases, results, time_range)
	items = results[first(cases)].indicator_names
	value(case, indicator, segment) = results[case].values[indicator][segment]
	totals = BuildTable(cases, items, SEGMENTS, value; item_label = "Indicator")
	scale = 24 / length(time_range)
	daily = copy(totals)
	extensive = daily.Indicator .!= PostAnalysisCommon.MEAN_FINAL_AUCTION_PRICE_INDICATOR
	for column in names(daily)[3:end], i in findall(extensive)
		ismissing(daily[i, column]) || (daily[i, column] *= scale)
	end
	return (totals = totals, daily = daily)
end

function InterpretationTable()
	return DataFrame(
		Sheet = ["sew / sew_daily", "surplus", "quantities", "gross_traded_volume", "storage_flows", "(difference) columns"],
		Interpretation = [
			"SEW, demand utility, production costs, producer/consumer surplus, storage revenue (and imbalance energy, wind curtailed, mean price where defined) split into Total / Energy / Balancing; Energy + Balancing = Total. sew_daily is the average per day.",
			"Per-agent surplus (EUR) split into Total / Energy / Balancing.",
			"Delivered dispatch per agent (MWh): Total, the energy-only plan, and the balancing adjustment.",
			"Sum of |quantity| over the generator's transactions (MWh), split by the transactions' segment.",
			"Storage charge and discharge (MWh): Total (after balancing) and Energy (energy-only dispatch); no Balancing part.",
			"Compared window length minus the previous window length, in the unit of the row (EUR, MWh; EUR/MWh for the mean price), for each adjacent pair. Missing where either value is not defined.",
		],
	)
end

# case_paths: window length => results folder of a run made with the Segment column and final_dispatch_decisions_energy.xlsx.
# cases are the window lengths in ascending order; time_range nothing is the window the runs' own configs define
function PerformAnalysis(case_paths; cases = sort(collect(keys(case_paths))), output_base = PostAnalysisCommon.NewAnalysisOutputDir(case_paths), time_range = nothing,
		agent_map = PostAnalysisCommon.DEFAULT_AGENT_MAP, agents = Surpluses.DEFAULT_AGENTS, generators = Quantities.DEFAULT_GENERATORS,
		imbalance_agents = PostAnalysisCommon.DEFAULT_IMBALANCE_AGENTS)
	println("starting analysis: window length balancing energy")
	time_range = PostAnalysisCommon.ResolveTimeRange(time_range, case_paths, cases; output_base = output_base)
	analysis_dir_path = "$output_base/balancing_energy"
	PostAnalysisCommon.CleanDirectory(analysis_dir_path)

	sew, surplus, quantities, gross, flows = (Dict{String,Any}() for _ in 1:5)
	for c in cases
		final = PostAnalysisCommon.LoadCaseFile(case_paths, c, "final_dispatch_decisions.xlsx")
		energy = PostAnalysisCommon.LoadCaseFile(case_paths, c, "final_dispatch_decisions_energy.xlsx")
		transactions = PostAnalysisCommon.LoadCaseFile(case_paths, c, "transactions.xlsx")
		sew[c] = SEW.SewBySegment(final, energy, transactions, agent_map, time_range; imbalance_agents = imbalance_agents)
		surplus[c] = Surpluses.AgentSurplusBySegment(final, energy, transactions, agent_map, time_range; agents = agents)
		quantities[c] = Quantities.AgentQuantityBySegment(final, energy, transactions, agent_map, time_range; agents = agents)
		gross[c] = Quantities.GrossTradedVolumeBySegment(transactions, time_range; generators = generators)
		flows[c] = Quantities.StorageFlowsBySegment(final, energy, time_range)
	end

	sew_tables = SewTables(cases, sew, time_range)
	agent_names(list) = [AgentLabel(a) for a in list]
	# BuildTable items are display names; map them back to the agent ids for the lookups
	lookup(results, list) = let ids = Dict(AgentLabel(a) => a for a in list)
		(case, name, segment) -> results[case][ids[name]][segment]
	end
	surplus_table = BuildTable(cases, agent_names(agents), SEGMENTS, lookup(surplus, agents); item_label = "Agent")
	quantity_table = BuildTable(cases, agent_names(agents), SEGMENTS, lookup(quantities, agents); item_label = "Agent")
	gross_table = BuildTable(cases, agent_names(generators), SEGMENTS, lookup(gross, generators); item_label = "Agent")
	flow_table = BuildTable(cases, ["Discharge", "Charge"], STORAGE_SEGMENTS, (case, flow, segment) -> flows[case][flow][segment]; item_label = "Storage Flow")
	for table in (sew_tables.totals, surplus_table, quantity_table, gross_table, flow_table)
		println(table)
	end

	XLSX.writetable("$analysis_dir_path/balancing_energy.xlsx",
		"sew" => sew_tables.totals, "sew_daily" => sew_tables.daily, "surplus" => surplus_table, "quantities" => quantity_table,
		"gross_traded_volume" => gross_table, "storage_flows" => flow_table, "interpretation" => InterpretationTable(); overwrite = true)
	return (sew = sew_tables.totals, surplus = surplus_table, quantities = quantity_table, gross_traded_volume = gross_table, storage_flows = flow_table)
end

end;

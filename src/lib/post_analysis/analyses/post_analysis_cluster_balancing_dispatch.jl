# Which technologies are dispatched in the balancing segment, across the experiment clusters: for each cluster, the net
# quantity (MWh) each agent/technology traded in the balancing segment (Segment == Balancing transactions, see
# PostAnalysisBalancingTradeQuantities) over the analysed range, as one grouped bar per technology, with the clusters
# grouped by season (SEASON_GROUPS: winter 3,6,7,8; Spring/Summer 1,2,4,5) like PostAnalysisClusterFixedVsRolling.
# Positive = the technology was dispatched up (more generation/charging-out, or more demand served), negative = down,
# i.e. the net of its balancing adjustments to what it had traded in earlier clearings. Technologies the lock keeps out
# of the balancing segment (all zero in every cluster) are left out of the plot but kept in the xlsx.
#
# One figure per design (fixed_36, rolling_36) and storage variant (regular, high), plus one per storage variant of the
# difference (rolling - fixed) in net balancing quantity (balancing_traded_quantity_rolling_minus_fixed_*.png). The xlsx has,
# per design and storage variant (and per difference), one sheet with the net, gross, increase and decrease quantities
# of every agent and cluster.
# Results are looked up as the latest results/{timestamp}_Cluster<n>_{design}_{range}[_high_storage] directory.
# Writes into {output_base}/cluster_balancing_traded_quantity/.

module PostAnalysisClusterBalancingDispatch

using DataFrames, XLSX, Plots

include("../post_analysis_common.jl")
include("./post_analysis_balancing_trade_quantities.jl")

const CLUSTER_RANGES = [
	"20240726_20240731", "20240919_20240924", "20241104_20241109", "20250304_20250309",
	"20250506_20250511", "20251031_20251105", "20251103_20251108", "20251106_20251111",
]
const DESIGNS = ["fixed_36" => "Fixed 36h", "rolling_36" => "Rolling 36h"]
const STORAGE_VARIANTS = ["regular" => "", "high" => "_high_storage"]
const SEASON_GROUPS = ["Winter" => [3, 6, 7, 8], "Spring/Summer" => [1, 2, 4, 5]]
const DEFAULT_TIME_RANGE = 24:167 # the 6 analysed days of the cluster experiments (1 day spin-up)

function LatestResultsDir(experiment_name; results_dir = "results")
	pattern = Regex("^\\d+_" * experiment_name * "\$")
	candidates = sort(filter(d -> occursin(pattern, d), readdir(results_dir)); by = d -> parse(Int, first(split(d, "_"))))
	isempty(candidates) && throw("no results directory for experiment $experiment_name under $results_dir")
	return joinpath(results_dir, last(candidates))
end

# agent => metric => MWh for one cluster, design and storage variant
function ClusterQuantities(cluster, design, suffix; time_range = DEFAULT_TIME_RANGE, results_dir = "results")
	path = LatestResultsDir("Cluster$(cluster)_$(design)_$(CLUSTER_RANGES[cluster])$suffix"; results_dir = results_dir)
	transactions = PostAnalysisCommon.LoadCaseFile(Dict("case" => path), "case", "transactions.xlsx")
	return PostAnalysisBalancingTradeQuantities.BalancingTradeQuantities(transactions, time_range)
end

# long table: Cluster, Agent, one column per metric
function QuantitiesTable(quantities_by_cluster, clusters)
	metrics = PostAnalysisBalancingTradeQuantities.METRICS
	table = DataFrame(Cluster = String[], Agent = String[])
	foreach(m -> table[!, m] = Float64[], metrics)
	for c in clusters, agent in PostAnalysisBalancingTradeQuantities.AGENTS
		push!(table, Any["Cluster$c", PostAnalysisBalancingTradeQuantities.DisplayName(agent), [quantities_by_cluster[c][agent][m] for m in metrics]...])
	end
	return table
end

# one fixed colour per agent, so a technology looks the same in every figure whichever agents the figure shows
const AGENT_COLORS = Dict(zip(PostAnalysisBalancingTradeQuantities.AGENTS, Plots.palette(:tab10)[1:length(PostAnalysisBalancingTradeQuantities.AGENTS)]))

# agents with a non-zero net balancing quantity in any of the given figures' quantities (agent order of AGENTS)
function ActiveAgents(all_quantities)
	net = PostAnalysisBalancingTradeQuantities.NET
	return [a for a in PostAnalysisBalancingTradeQuantities.AGENTS if any(qs -> any(q -> abs(q[a][net]) > 1e-6, values(qs)), all_quantities)]
end

# (ymin, ymax) shared by every figure: covers all nets of all figures, with room for the group labels below
function SharedYLimits(all_quantities, agents)
	net = PostAnalysisBalancingTradeQuantities.NET
	all_values = [q[a][net] for qs in all_quantities for q in values(qs) for a in agents]
	span = maximum(all_values) - minimum(all_values) + 1
	margin = 0.08 * span
	return min(0.0, minimum(all_values)) - margin - 0.07 * span, max(0.0, maximum(all_values)) + margin, span
end

# quantities_by_cluster: cluster => agent => metric => MWh; agents and ylims are shared across the figures
function PlotDispatch(quantities_by_cluster, title, ylabel, analysis_dir_path, file_name, agents, (ymin, ymax, span))
	net = PostAnalysisBalancingTradeQuantities.NET
	groups = filter(g -> !isempty(g[2]), [(label, filter(c -> haskey(quantities_by_cluster, c), members)) for (label, members) in SEASON_GROUPS])
	positions = Dict{Int,Float64}()
	slot = 0.0
	group_centres = Float64[]
	for (_, members) in groups
		first_slot = slot + 1
		for c in members
			slot += 1
			positions[c] = slot
		end
		push!(group_centres, (first_slot + slot) / 2)
		slot += 1 # gap between the groups
	end
	ordered = [c for (_, members) in groups for c in members]
	width = 0.8 / length(agents)
	p = Plots.plot(ylabel = ylabel, title = title,
		xticks = (getindex.(Ref(positions), ordered), ["C$c" for c in ordered]), xlims = (0.4, slot - 0.4),
		ylims = (ymin, ymax), legend = :outertopright, size = (1100, 550),
		left_margin = 10Plots.mm, bottom_margin = 8Plots.mm)
	for (k, agent) in enumerate(agents)
		Plots.bar!(p, [positions[c] + (k - (length(agents) + 1) / 2) * width for c in ordered],
			[quantities_by_cluster[c][agent][net] for c in ordered]; bar_width = width, color = AGENT_COLORS[agent],
			label = PostAnalysisBalancingTradeQuantities.DisplayName(agent))
	end
	Plots.hline!(p, [0.0]; color = :black, label = "")
	for ((label, _), centre) in zip(groups, group_centres)
		Plots.annotate!(p, centre, ymin + 0.035 * span, Plots.text(label, 11, :bold))
	end
	savefig(p, joinpath(analysis_dir_path, file_name))
	return p
end

function PerformAnalysis(; clusters = 1:length(CLUSTER_RANGES), time_range = DEFAULT_TIME_RANGE, results_dir = "results",
		output_base = PostAnalysisCommon.NewAnalysisOutputDir(Dict("results_dir" => results_dir); label = "cluster_balancing_traded_quantity"))
	analysis_dir_path = joinpath(output_base, "cluster_balancing_traded_quantity")
	mkpath(analysis_dir_path)
	sheets = Pair{String,DataFrame}[]
	variants = [(design, design_label, storage, suffix) for (design, design_label) in DESIGNS for (storage, suffix) in STORAGE_VARIANTS]
	quantities_by_variant = [Dict(c => ClusterQuantities(c, design, suffix; time_range = time_range, results_dir = results_dir) for c in clusters) for (design, _, _, suffix) in variants]
	agents = ActiveAgents(quantities_by_variant) # the same technologies and y range in every figure, so they can be compared
	if !isempty(agents)
		ylimits = SharedYLimits(quantities_by_variant, agents)
		for ((design, design_label, storage, _), quantities) in zip(variants, quantities_by_variant)
			display(PlotDispatch(quantities, "Balancing Traded Quantity by Technology, $design_label, $(titlecase(storage)) Storage",
				"Net Balancing Quantity (MWh)", analysis_dir_path, "balancing_traded_quantity_$(design)_$(storage).png", agents, ylimits))
		end
	end
	for ((design, _, storage, _), quantities) in zip(variants, quantities_by_variant)
		push!(sheets, "$design $storage" => QuantitiesTable(quantities, clusters))
	end

	# rolling - fixed, per storage variant, in the same format (own shared y range: the differences are on a different scale)
	by_variant = Dict((design, storage) => q for ((design, _, storage, _), q) in zip(variants, quantities_by_variant))
	differences = [storage => Dict(c => Dict(a => Dict(m => by_variant[("rolling_36", storage)][c][a][m] - by_variant[("fixed_36", storage)][c][a][m]
					for m in PostAnalysisBalancingTradeQuantities.METRICS) for a in PostAnalysisBalancingTradeQuantities.AGENTS) for c in clusters)
				for (storage, _) in STORAGE_VARIANTS]
	diff_agents = ActiveAgents(last.(differences))
	if !isempty(diff_agents)
		diff_ylimits = SharedYLimits(last.(differences), diff_agents)
		for (storage, diffs) in differences
			display(PlotDispatch(diffs, "Balancing Traded Quantity: Rolling 36h - Fixed 36h, $(titlecase(storage)) Storage",
				"Rolling - Fixed Net Balancing Quantity (MWh)", analysis_dir_path, "balancing_traded_quantity_rolling_minus_fixed_$(storage).png", diff_agents, diff_ylimits))
		end
	end
	for (storage, diffs) in differences
		push!(sheets, "rolling - fixed $storage" => QuantitiesTable(diffs, clusters))
	end
	XLSX.writetable(joinpath(analysis_dir_path, "cluster_balancing_traded_quantity.xlsx"), sheets...)
	println("cluster balancing dispatch plots written to $analysis_dir_path")
	return output_base
end

end;

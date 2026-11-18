# Rolling horizon window length across the experiment clusters: the 72h rolling-horizon runs compared with the 36h ones
# (rolling_72 - rolling_36), in the same difference-plot formats as the fixed-vs-rolling ones:
#   - balancing traded quantity by technology (PostAnalysisClusterBalancingDispatch): the difference in net balancing
#     quantity (MWh) per agent, one grouped bar per agent per cluster; one figure per storage variant sharing one y range;
#   - SEW, production costs and demand utility (PostAnalysisClusterFixedVsRolling): the % change ((72h - 36h) / |36h|),
#     for the energy-only and total (energy + balancing) KPI views, per storage variant.
# Clusters are grouped by season (Winter 3,6,7,8; Spring/Summer 1,2,4,5). Positive bars mean the 72h window is higher;
# a higher production cost is a worse outcome, unlike SEW and demand utility. Results are looked up as the latest
# results/{timestamp}_Cluster<n>_{rolling_36,rolling_72}_{range}[_high_storage] directory.
# Writes into {output_base}/cluster_window_length/: the PNGs plus cluster_window_length.xlsx (the KPI % changes and euro
# differences per view and storage variant, and the balancing quantity differences per storage variant).

module PostAnalysisClusterWindowLength

using DataFrames, XLSX, Plots

include("./post_analysis_cluster_balancing_dispatch.jl")
include("./post_analysis_cluster_fixed_vs_rolling.jl")

const B = PostAnalysisClusterBalancingDispatch
const K = PostAnalysisClusterFixedVsRolling
const BASE, SUBJECT = "rolling_36", "rolling_72"

function BalancingDifferences(clusters, suffix, time_range, results_dir)
	metrics = B.PostAnalysisBalancingTradeQuantities.METRICS
	agents = B.PostAnalysisBalancingTradeQuantities.AGENTS
	base = Dict(c => B.ClusterQuantities(c, BASE, suffix; time_range = time_range, results_dir = results_dir) for c in clusters)
	subject = Dict(c => B.ClusterQuantities(c, SUBJECT, suffix; time_range = time_range, results_dir = results_dir) for c in clusters)
	return Dict(c => Dict(a => Dict(m => subject[c][a][m] - base[c][a][m] for m in metrics) for a in agents) for c in clusters)
end

function PerformAnalysis(; clusters = 1:length(B.CLUSTER_RANGES), time_range = B.DEFAULT_TIME_RANGE, results_dir = "results",
		output_base = B.PostAnalysisCommon.NewAnalysisOutputDir(Dict("results_dir" => results_dir); label = "cluster_window_length"))
	analysis_dir_path = joinpath(output_base, "cluster_window_length")
	mkpath(analysis_dir_path)
	sheets = Pair{String,DataFrame}[]

	# balancing traded quantity: rolling_72 - rolling_36 per technology
	balancing = [storage => BalancingDifferences(clusters, suffix, time_range, results_dir) for (storage, suffix) in B.STORAGE_VARIANTS]
	agents = B.ActiveAgents(last.(balancing))
	if !isempty(agents)
		ylimits = B.SharedYLimits(last.(balancing), agents)
		for (storage, diffs) in balancing
			display(B.PlotDispatch(diffs, "Balancing Traded Quantity: Rolling 72h - Rolling 36h, $(titlecase(storage)) Storage",
				"72h - 36h Net Balancing Quantity (MWh)", analysis_dir_path, "balancing_traded_quantity_rolling_72_minus_36_$(storage).png", agents, ylimits))
		end
	end
	for (storage, diffs) in balancing
		push!(sheets, "balancing 72-36 $storage" => B.QuantitiesTable(diffs, clusters))
	end

	# SEW / production costs / demand utility: % change of the 72h window vs the 36h one
	for view in K.VIEWS, (storage, suffix) in K.STORAGE_VARIANTS
		diffs = [K.Differences(c, suffix, view; time_range = time_range, results_dir = results_dir, base_design = BASE, subject_design = SUBJECT) for c in clusters]
		display(K.PlotDifferences(Dict(zip(clusters, diffs)), storage, view, analysis_dir_path; comparison = "Rolling 72h vs Rolling 36h", file_prefix = "rolling_72_vs_36"))
		table = DataFrame(Cluster = ["Cluster$c" for c in clusters])
		for (name, _) in K.KPIS
			table[!, "$name (% change)"] = [d[name][2] for d in diffs]
		end
		for (name, _) in K.KPIS
			table[!, "$name (€ difference)"] = [d[name][1] for d in diffs]
		end
		push!(sheets, "KPIs $view $storage" => table)
	end

	XLSX.writetable(joinpath(analysis_dir_path, "cluster_window_length.xlsx"), sheets...)
	println("cluster window length plots written to $analysis_dir_path")
	return output_base
end

end;

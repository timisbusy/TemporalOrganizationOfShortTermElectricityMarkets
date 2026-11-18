# Agent surpluses from energy trading, fixed vs rolling horizon, across the experiment clusters: for each cluster, the
# surplus (€) each agent earned in the energy segment (the "Surplus (€)" of PostAnalysisCommon.CalculateCaseEnergyIndicators,
# the same figures as PostAnalysisQuantitiesByAgent's surplus table; storage's is its transaction-based revenue) over the
# analysed range, and the difference rolling_36 - fixed_36 as one grouped bar per agent, clusters grouped by season
# (Winter 3,6,7,8; Spring/Summer 1,2,4,5) in the same format, colours and layout as
# PostAnalysisClusterBalancingDispatch (whose plotting it reuses).
# Positive bars mean the agent's surplus is higher under the rolling horizon. Energy segment only: balancing-segment
# trades are not part of these surpluses.
#
# One difference figure per storage variant (regular, high), sharing one y range. The xlsx has, per storage variant,
# the surplus of every agent under both designs and the difference, per cluster. Results are looked up as the latest
# results/{timestamp}_Cluster<n>_{fixed_36,rolling_36}_{range}[_high_storage] directory.
# Writes into {output_base}/cluster_agent_surplus/.

module PostAnalysisClusterAgentSurplus

using DataFrames, XLSX, Plots

include("./post_analysis_cluster_balancing_dispatch.jl")

const M = PostAnalysisClusterBalancingDispatch
const SURPLUS = Symbol("Surplus (€)")
const AGENTS = M.PostAnalysisBalancingTradeQuantities.AGENTS

# agent => surplus (€) for one cluster, design and storage variant
function ClusterSurpluses(cluster, design, suffix; time_range = M.DEFAULT_TIME_RANGE, results_dir = "results")
	path = M.LatestResultsDir("Cluster$(cluster)_$(design)_$(M.CLUSTER_RANGES[cluster])$suffix"; results_dir = results_dir)
	indicators = M.PostAnalysisCommon.CalculateCaseEnergyIndicators(Dict("case" => path), "case"; time_range = time_range).agent_indicators
	return Dict(agent => Float64(indicators[indicators.Agent .== agent, SURPLUS][1]) for agent in AGENTS)
end

function PerformAnalysis(; clusters = 1:length(M.CLUSTER_RANGES), time_range = M.DEFAULT_TIME_RANGE, results_dir = "results",
		output_base = M.PostAnalysisCommon.NewAnalysisOutputDir(Dict("results_dir" => results_dir); label = "cluster_agent_surplus"))
	analysis_dir_path = joinpath(output_base, "cluster_agent_surplus")
	mkpath(analysis_dir_path)
	net = M.PostAnalysisBalancingTradeQuantities.NET # the plotting code reads this key; here it holds the surplus difference
	sheets = Pair{String,DataFrame}[]
	differences = Pair{String,Any}[]
	for (storage, suffix) in M.STORAGE_VARIANTS
		fixed = Dict(c => ClusterSurpluses(c, "fixed_36", suffix; time_range = time_range, results_dir = results_dir) for c in clusters)
		rolling = Dict(c => ClusterSurpluses(c, "rolling_36", suffix; time_range = time_range, results_dir = results_dir) for c in clusters)
		table = DataFrame(Cluster = String[], Agent = String[], Fixed = Float64[], Rolling = Float64[], Difference = Float64[], PercentChange = Float64[])
		for c in clusters, agent in AGENTS
			f, r = fixed[c][agent], rolling[c][agent]
			push!(table, Any["Cluster$c", M.PostAnalysisBalancingTradeQuantities.DisplayName(agent), f, r, r - f, f == 0 ? NaN : 100 * (r - f) / abs(f)])
		end
		rename!(table, "Fixed" => "Fixed 36h Surplus (€)", "Rolling" => "Rolling 36h Surplus (€)", "Difference" => "Rolling - Fixed (€)", "PercentChange" => "% Change")
		push!(sheets, storage => table)
		push!(differences, storage => Dict(c => Dict(a => Dict(net => rolling[c][a] - fixed[c][a]) for a in AGENTS) for c in clusters))
	end
	# the same agents (colour per agent) and one y range in both figures
	agents = M.ActiveAgents(last.(differences))
	if !isempty(agents)
		ylimits = M.SharedYLimits(last.(differences), agents)
		for (storage, diffs) in differences
			display(M.PlotDispatch(diffs, "Energy-Trading Surplus: Rolling 36h - Fixed 36h, $(titlecase(storage)) Storage",
				"Rolling - Fixed Surplus (€)", analysis_dir_path, "agent_surplus_rolling_minus_fixed_$(storage).png", agents, ylimits))
		end
	end
	XLSX.writetable(joinpath(analysis_dir_path, "cluster_agent_surplus.xlsx"), sheets...)
	println("cluster agent surplus plots written to $analysis_dir_path")
	return output_base
end

end;

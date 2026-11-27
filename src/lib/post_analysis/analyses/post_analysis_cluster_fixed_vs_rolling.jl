# Fixed vs rolling horizon (rolling_36 vs fixed_36) across the experiment clusters: the % change of socioeconomic welfare,
# production costs and demand utility ((rolling - fixed) / |fixed|), one bar per KPI per cluster, with the clusters
# grouped by season (SEASON_GROUPS: winter 3,6,7,8; Spring/Summer 1,2,4,5).
# One figure per storage variant (regular, high) and per KPI view:
#   - "energy": the energy-only KPIs (final_dispatch_decisions_energy.xlsx), the default KPI export;
#   - "total":  the KPIs of the total (delivered) dispatch, energy + balancing.
# The two views can differ noticeably (the energy-only plan is not a physical dispatch for storage - see
# the balancing/energy split notes), so both are written. Positive bars mean rolling is higher than fixed; note that a
# higher production cost is a worse outcome, unlike SEW and demand utility.
#
# Results are looked up as the latest results/{timestamp}_{Cluster<n>_{fixed_36,rolling_36}_{range}[_high_storage]}
# directory of each experiment (override with `results_dir`). Writes into {output_base}/cluster_fixed_vs_rolling/:
# the PNGs and cluster_fixed_vs_rolling.xlsx (the % changes and the euro differences, one sheet per view and storage variant).

module PostAnalysisClusterFixedVsRolling

using DataFrames, XLSX, Plots

include("../post_analysis_common.jl")

const CLUSTER_RANGES = [
	"20240726_20240731", "20240919_20240924", "20241104_20241109", "20250304_20250309",
	"20250506_20250511", "20251031_20251105", "20251103_20251108", "20251106_20251111",
]
const STORAGE_VARIANTS = ["regular" => "", "high" => "_high_storage"]
const VIEWS = ["energy", "total"]
const KPIS = [
	("Socioeconomic Welfare", Symbol("Socioeconomic Welfare (€)")),
	("Production Costs", Symbol("Production Costs (€)")),
	("Demand Utility", Symbol("Demand Utility (€)")),
]
const SEASON_GROUPS = ["Winter" => [3, 6, 7, 8], "Spring/Summer" => [1, 2, 4, 5]]
const DEFAULT_TIME_RANGE = 24:167 # the 6 analysed days of the cluster experiments (1 day spin-up)

function LatestResultsDir(experiment_name; results_dir = "results")
	pattern = Regex("^\\d+_" * experiment_name * "\$")
	candidates = sort(filter(d -> occursin(pattern, d), readdir(results_dir)); by = d -> parse(Int, first(split(d, "_"))))
	isempty(candidates) && throw("no results directory for experiment $experiment_name under $results_dir")
	return joinpath(results_dir, last(candidates))
end

# KPI => (rolling - fixed in EUR, % change vs fixed) for one cluster, storage suffix and view
function Differences(cluster, suffix, view; time_range = DEFAULT_TIME_RANGE, results_dir = "results")
	range = CLUSTER_RANGES[cluster]
	case_paths = Dict(
		"Fixed Horizon" => LatestResultsDir("Cluster$(cluster)_fixed_36_$(range)$suffix"; results_dir = results_dir),
		"Rolling Horizon" => LatestResultsDir("Cluster$(cluster)_rolling_36_$(range)$suffix"; results_dir = results_dir),
	)
	indicators(case) = view == "energy" ?
		PostAnalysisCommon.CalculateCaseEnergyIndicators(case_paths, case; time_range = time_range).economic_indicators :
		PostAnalysisCommon.CalculateCaseIndicators(case_paths, case; time_range = time_range).economic_indicators
	fixed, rolling = indicators("Fixed Horizon"), indicators("Rolling Horizon")
	result = Dict{String,Tuple{Float64,Float64}}()
	for (name, symbol) in KPIS
		f, r = Float64(fixed[1, symbol]), Float64(rolling[1, symbol])
		result[name] = (r - f, f == 0 ? NaN : 100 * (r - f) / abs(f))
	end
	return result
end

# clusters laid out group by group (a one-slot gap between groups); diffs_by_cluster: cluster => Differences result
function PlotDifferences(diffs_by_cluster, storage, view, analysis_dir_path)
	width = 0.25 # one bar per KPI, centred on the cluster's tick
	groups = [(label, filter(c -> haskey(diffs_by_cluster, c), members)) for (label, members) in SEASON_GROUPS]
	groups = filter(g -> !isempty(g[2]), groups)
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
		slot += 1 # gap
	end
	ordered = [c for (_, members) in groups for c in members]
	all_values = [diffs_by_cluster[c][name][2] for c in ordered for (name, _) in KPIS]
	span = maximum(all_values) - minimum(all_values) + 1
	margin = 0.08 * span
	ymin, ymax = min(0.0, minimum(all_values)) - margin - 0.07 * span, max(0.0, maximum(all_values)) + margin
	p = Plots.plot(ylabel = "Rolling vs Fixed 36h (% Change)",
		title = "Rolling vs Fixed 36h, $(titlecase(storage)) Storage ($(view == "energy" ? "Energy-Only" : "Total Delivered") KPIs)",
		xticks = (getindex.(Ref(positions), ordered), ["C$c" for c in ordered]), xlims = (0.4, slot - 0.4),
		ylims = (ymin, ymax), legend = :outertopright, size = (1100, 550),
		left_margin = 10Plots.mm, bottom_margin = 8Plots.mm)
	for (k, (name, _)) in enumerate(KPIS)
		Plots.bar!(p, [positions[c] + (k - (length(KPIS) + 1) / 2) * width for c in ordered],
			[diffs_by_cluster[c][name][2] for c in ordered]; bar_width = width, label = name)
	end
	Plots.hline!(p, [0.0]; color = :black, label = "")
	for ((label, _), centre) in zip(groups, group_centres)
		Plots.annotate!(p, centre, ymin + 0.035 * span, Plots.text(label, 11, :bold))
	end
	savefig(p, joinpath(analysis_dir_path, "fixed_vs_rolling_$(storage)_$(view).png"))
	return p
end

function PerformAnalysis(; clusters = 1:length(CLUSTER_RANGES), time_range = DEFAULT_TIME_RANGE, results_dir = "results",
		output_base = PostAnalysisCommon.NewAnalysisOutputDir(Dict("results_dir" => results_dir); label = "cluster_fixed_vs_rolling"))
	analysis_dir_path = joinpath(output_base, "cluster_fixed_vs_rolling")
	mkpath(analysis_dir_path)
	sheets = Pair{String,DataFrame}[]
	for view in VIEWS, (storage, suffix) in STORAGE_VARIANTS
		diffs = [Differences(c, suffix, view; time_range = time_range, results_dir = results_dir) for c in clusters]
		display(PlotDifferences(Dict(zip(clusters, diffs)), storage, view, analysis_dir_path))
		table = DataFrame(Cluster = ["Cluster$c" for c in clusters])
		for (name, _) in KPIS
			table[!, "$name (% change)"] = [d[name][2] for d in diffs]
		end
		for (name, _) in KPIS
			table[!, "$name (€ difference)"] = [d[name][1] for d in diffs]
		end
		push!(sheets, "$view $storage" => table)
	end
	XLSX.writetable(joinpath(analysis_dir_path, "cluster_fixed_vs_rolling.xlsx"), sheets...)
	println("cluster fixed vs rolling plots written to $analysis_dir_path")
	return output_base
end

end;

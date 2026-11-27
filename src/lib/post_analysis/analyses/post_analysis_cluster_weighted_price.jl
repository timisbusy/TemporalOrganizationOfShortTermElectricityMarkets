# Volume-weighted price statistics, fixed vs rolling horizon, across the experiment clusters: for each cluster and
# storage variant, the per-MTU volume-weighted price of the energy-segment transactions
# (PostAnalysisWeightedPrice.WeightedPriceByMTU) over the analysed range, summarised as mean, median, standard deviation,
# maximum and minimum (PostAnalysisWeightedPrice.SummaryTable - every MTU with a price counts once, whatever its volume).
#
# One figure per storage variant (small, large), sharing one y range: per cluster, a dot at the mean price of each
# design with whiskers of +/- one standard deviation. The xlsx has one sheet per storage variant with every statistic per
# cluster and design. Results are looked up as the latest
# results/{timestamp}_Cluster<n>_{fixed_36,rolling_36}_{range}[_high_storage][_lock_demand] directory; lock_demand=true
# uses the runs with demand locked in the balancing MTU. A cluster whose run is missing or has no transactions.xlsx
# (a failed run) is skipped with a warning.
# Writes into {output_base}/cluster_weighted_price[_demand_locked]/.

module PostAnalysisClusterWeightedPrice

using DataFrames, XLSX, Plots

include("./post_analysis_cluster_balancing_dispatch.jl")
include("./post_analysis_weighted_price.jl")

const M = PostAnalysisClusterBalancingDispatch
const W = PostAnalysisWeightedPrice
const DESIGNS = ["fixed_36" => "Fixed Horizon", "rolling_36" => "Rolling Horizon"]
const MEAN = W.SUMMARY_STATISTICS[1]
const STD = W.SUMMARY_STATISTICS[3]

# design label => summary column vector (W.SUMMARY_STATISTICS order) for one cluster and storage variant, or nothing if a run is missing
function ClusterSummary(cluster, suffix; time_range = M.DEFAULT_TIME_RANGE, results_dir = "results")
	paths = Dict{String,String}()
	for (design, label) in DESIGNS
		name = "Cluster$(cluster)_$(design)_$(M.CLUSTER_RANGES[cluster])$suffix"
		try
			paths[label] = M.LatestResultsDir(name; results_dir = results_dir)
			isfile(joinpath(paths[label], "transactions.xlsx")) || error("no transactions") # a failed run leaves a directory without results
		catch
			@warn "no complete results directory for $name - cluster $cluster skipped"
			return nothing
		end
	end
	prices = Dict(label => W.WeightedPriceByMTU(M.PostAnalysisCommon.LoadCaseFile(paths, label, "transactions.xlsx"), time_range, :energy)
		for (_, label) in DESIGNS)
	summary = W.SummaryTable(prices, last.(DESIGNS))
	return Dict(label => summary[!, Symbol(label)] for (_, label) in DESIGNS)
end

function PerformAnalysis(; clusters = 1:length(M.CLUSTER_RANGES), time_range = M.DEFAULT_TIME_RANGE, results_dir = "results", lock_demand = false,
		output_base = M.PostAnalysisCommon.NewAnalysisOutputDir(Dict("results_dir" => results_dir);
			label = "cluster_weighted_price" * (lock_demand ? "_demand_locked" : "")))
	folder = "cluster_weighted_price" * (lock_demand ? "_demand_locked" : "")
	analysis_dir_path = joinpath(output_base, folder)
	mkpath(analysis_dir_path)
	lock_suffix = lock_demand ? "_lock_demand" : ""
	tables = Pair{String,DataFrame}[]
	for (storage, suffix) in M.STORAGE_VARIANTS
		table = DataFrame(Cluster = Int[], Design = String[])
		for stat in W.SUMMARY_STATISTICS
			table[!, stat] = Union{Missing,Float64}[]
		end
		for c in clusters
			summary = ClusterSummary(c, suffix * lock_suffix; time_range = time_range, results_dir = results_dir)
			summary === nothing && continue
			for (_, label) in DESIGNS
				push!(table, vcat(Any[c, label], summary[label]))
			end
		end
		push!(tables, storage => table)
	end
	println(tables)

	# one y range in both figures so the storage variants can be compared
	all_rows = vcat(last.(tables)...)
	ok = .!ismissing.(all_rows[!, MEAN]) .& .!ismissing.(all_rows[!, STD])
	ymax = any(ok) ? 1.08 * maximum(all_rows[ok, MEAN] .+ all_rows[ok, STD]) : 1.0
	for (storage, table) in tables
		display(PlotMeanStd(table, storage, lock_demand, ymax, joinpath(analysis_dir_path, "weighted_price_mean_std_$(storage)_storage.png")))
	end
	XLSX.writetable(joinpath(analysis_dir_path, "cluster_weighted_price.xlsx"), ["$storage storage" => t for (storage, t) in tables]...; overwrite = true)
	println("cluster weighted price results written to $analysis_dir_path")
	return output_base
end

function PlotMeanStd(table, storage, lock_demand, ymax, path)
	clusters = sort(unique(table.Cluster))
	title = "Volume-weighted price per MTU: mean ± 1 standard deviation ($storage storage" * (lock_demand ? ", demand locked" : "") * ")"
	p = Plots.plot(title = title, xlabel = "Cluster", ylabel = "Volume-weighted price (€/MWh)",
		xticks = (1:length(clusters), string.(clusters)), ylims = (0, ymax), legend = :topright,
		size = (1100, 500), left_margin = 10Plots.mm, bottom_margin = 8Plots.mm,
		background_color = W.SURFACE, foreground_color_axis = W.AXIS_COLOR, foreground_color_border = W.AXIS_COLOR,
		foreground_color_text = W.TEXT_PRIMARY, foreground_color_guide = W.TEXT_PRIMARY, foreground_color_legend = W.SURFACE,
		gridcolor = W.GRID_COLOR, gridalpha = 1.0, tickfontcolor = W.TEXT_MUTED, titlefontsize = 12)
	for (i, ((_, label), offset)) in enumerate(zip(DESIGNS, (-0.12, 0.12)))
		rows = [only(eachrow(table[(table.Cluster .== c) .& (table.Design .== label), :])) for c in clusters]
		means = [coalesce(r[MEAN], NaN) for r in rows]
		stds = [coalesce(r[STD], 0.0) for r in rows]
		Plots.scatter!(p, (1:length(clusters)) .+ offset, means; yerror = stds, color = W.LINE_COLORS[i], markersize = 7,
			markerstrokecolor = W.LINE_COLORS[i], markerstrokewidth = 2, label = "$label (mean ± std)")
	end
	M.PostAnalysisCommon.SaveFigure(p, path)
	return p
end

end;

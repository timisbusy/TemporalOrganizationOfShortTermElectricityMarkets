# Residual demand (total demand minus variable generation) over the analysed hours of each experiment cluster.
#
# Unlike the other post-analyses this one does not read a results directory: it only needs the experiment's input
# data, so it takes the experiment config files (default: the regular-storage Cluster1-8 fixed_36 configs - the
# analysed range is the same for every design and storage variant of a cluster). For each config it resolves the
# agent config's demand segments and variable generators, reads their profiles from the input CSVs for the
# experiment's startDate, and keeps the analysed hours: the clearForDays horizon minus samplePeriodExcludeSpinUp
# days at the start and samplePeriodExcludeEnd days at the end (the same trim as the other analyses' time_range).
#
# - Demand = sum of all demand segments (quantity profile x conversionFactor).
# - Variable generation = sum of all variable generators (wind + solar), as the available (input) profile
#   x conversionFactor, i.e. before the simulation's wind forecast noise.
# - Residual demand = demand - variable generation (negative when wind + solar exceed demand).
#
# Output (into {output_base}/residual_demand/): one PNG per cluster (demand, variable generation and residual
# demand), one combined PNG of the residual demand of all clusters against the hour of the analysed range, and
# residual_demand.xlsx with the hourly values (one sheet per cluster plus a combined "Residual demand" sheet).

module PostAnalysisResidualDemand

using YAML, DataFrames, Dates, XLSX, Plots, Statistics, CSV

include("../post_analysis_common.jl")

const EXPERIMENT_DIR = "src/configs/experiments"
const DEFAULT_CONFIGS = [
	"Cluster1_fixed_36_20240726_20240731.yaml",
	"Cluster2_fixed_36_20240919_20240924.yaml",
	"Cluster3_fixed_36_20241104_20241109.yaml",
	"Cluster4_fixed_36_20250304_20250309.yaml",
	"Cluster5_fixed_36_20250506_20250511.yaml",
	"Cluster6_fixed_36_20251031_20251105.yaml",
	"Cluster7_fixed_36_20251103_20251108.yaml",
	"Cluster8_fixed_36_20251106_20251111.yaml",
]

# "Cluster3_fixed_36_20241104_20241109" -> "Cluster3"; falls back to the whole name
ClusterLabel(config_name) = String(first(split(config_name, "_")))

ResolveConfigPath(path) = isfile(path) ? path : joinpath(EXPERIMENT_DIR, path)

# hourly MW series (one value per hour from start_time, `hours` values) of the sum of the given profile files
# scaled by conversion_factor. Throws if the files do not cover the whole range.
function HourlySeries(files, start_time::DateTime, hours::Int, conversion_factor)
	total = zeros(hours)
	stop_time = start_time + Dates.Hour(hours)
	for file in files
		data = DataFrame(CSV.File(file, dateformat = "y-mm-dd H:M:S")) # same read as HelperInputData.ImportDataFromCSV
		in_range = (start_time .<= data[!, "validfrom (UTC)"]) .& (data[!, "validfrom (UTC)"] .< stop_time)
		values = data[in_range, "volume (kWh)"]
		length(values) == hours || throw("$file has $(length(values)) hourly rows from $start_time, expected $hours")
		total .+= values
	end
	return total .* conversion_factor
end

# the profile files of an agent entry (profile_file or profile_files)
ProfileFiles(entry) = haskey(entry, "profile_files") ? entry["profile_files"] : [entry["profile_file"]]

# DataFrame (hour, Demand, VariableGeneration, ResidualDemand) over the analysed range of one experiment config
function ResidualDemandForConfig(config_path)
	cfg = YAML.load_file(config_path)
	agents = YAML.load_file(joinpath("src/configs/agents", cfg["agentConfig"]))
	cfg["timePeriodsPerDay"] == 24 || throw("$config_path: residual demand plots expect hourly MTUs (timePeriodsPerDay: 24)")

	spin_up = Int(round(24 * get(cfg, "samplePeriodExcludeSpinUp", 2)))
	exclude_end = Int(round(24 * get(cfg, "samplePeriodExcludeEnd", 2)))
	hours = 24 * Int(cfg["clearForDays"]) - spin_up - exclude_end
	hours > 0 || throw("$config_path: no analysed hours left after the spin-up/end exclusions")
	start_time = DateTime(cfg["startDate"]) + Dates.Hour(spin_up)

	demand = zeros(hours)
	for (_, segment) in agents["demand"]["segments"]
		demand .+= HourlySeries(ProfileFiles(segment), start_time, hours, segment["conversionFactor"])
	end
	variable_generation = zeros(hours)
	for (_, generator) in agents["variableGenerators"]
		variable_generation .+= HourlySeries(ProfileFiles(generator), start_time, hours, generator["conversionFactor"])
	end
	return DataFrame(
		Hour = 0:(hours-1),
		Time = [start_time + Dates.Hour(h) for h in 0:(hours-1)],
		Demand = demand,
		VariableGeneration = variable_generation,
		ResidualDemand = demand .- variable_generation,
	)
end

# x ticks every 24 hours of the analysed range, labelled with the day
function DayTicks(hours)
	ticks = collect(0:24:hours)
	return (ticks, ["day $(t ÷ 24)" for t in ticks])
end

function PlotCluster(df, label, analysis_dir_path)
	hours = nrow(df)
	p = Plots.plot(xlabel = "Hour of analysed range (starts $(Date(df.Time[1])))", ylabel = "MW",
		title = "$label - demand, variable generation and residual demand",
		xticks = DayTicks(hours), legend = :outertopright, size = (1100, 550),
		left_margin = 10Plots.mm, bottom_margin = 8Plots.mm)
	Plots.hline!(p, [0.0]; color = :gray, linestyle = :dash, label = "")
	Plots.plot!(p, df.Hour, df.Demand; label = "Demand", linewidth = 2)
	Plots.plot!(p, df.Hour, df.VariableGeneration; label = "Variable generation (wind + solar)", linewidth = 2)
	Plots.plot!(p, df.Hour, df.ResidualDemand; label = "Residual demand", linewidth = 3, color = :black)
	savefig(p, joinpath(analysis_dir_path, "residual_demand_$label.png"))
	return p
end

function PlotCombined(dfs_by_label, labels, analysis_dir_path)
	hours = maximum(nrow(dfs_by_label[l]) for l in labels)
	p = Plots.plot(xlabel = "Hour of analysed range", ylabel = "Residual demand (MW)",
		title = "Residual demand by cluster", xticks = DayTicks(hours), legend = :outertopright,
		size = (1100, 550), left_margin = 10Plots.mm, bottom_margin = 8Plots.mm)
	Plots.hline!(p, [0.0]; color = :gray, linestyle = :dash, label = "")
	colors = Plots.palette(:tab10)
	for (i, label) in enumerate(labels)
		df = dfs_by_label[label]
		Plots.plot!(p, df.Hour, df.ResidualDemand; label = "$label ($(Date(df.Time[1])))", linewidth = 2, color = colors[mod1(i, length(colors))])
	end
	savefig(p, joinpath(analysis_dir_path, "residual_demand_all_clusters.png"))
	return p
end

# season colour families: shades of blue for winter, of orange/red for spring/summer
const SEASON_COLORS = Dict(
	"Winter" => (clusters = [3, 6, 7, 8], colors = [:navy, :royalblue, :dodgerblue, :deepskyblue]),
	"Spring/Summer" => (clusters = [1, 2, 4, 5], colors = [:firebrick, :darkorange, :goldenrod, :sienna]),
)

function SeasonOf(label)
	n = tryparse(Int, replace(label, "Cluster" => ""))
	for (season, spec) in SEASON_COLORS
		i = findfirst(==(n), spec.clusters)
		i === nothing || return (season, spec.colors[i])
	end
	return ("Other", :gray)
end

function PlotCombinedHighlighted(dfs_by_label, labels, analysis_dir_path; highlight = ["Cluster1", "Cluster3"])
	hours = maximum(nrow(dfs_by_label[l]) for l in labels)
	p = Plots.plot(xlabel = "Hour of Analysed Range", ylabel = "Residual Demand (MW)",
		title = "Residual Demand by Cluster (Clusters $(join([replace(h, "Cluster" => "") for h in highlight], " and ")) Highlighted)",
		xticks = DayTicks(hours), legend = :outertopright, size = (1100, 550),
		left_margin = 10Plots.mm, bottom_margin = 8Plots.mm)
	Plots.hline!(p, [0.0]; color = :gray, linestyle = :dash, label = "")
	# legend order = draw order: grouped by season, then by cluster number; the highlighted clusters are then
	# redrawn (unlabelled) so they sit on top of the faded ones
	ordered = sort(labels; by = l -> (findfirst(==(SeasonOf(l)[1]), ["Spring/Summer", "Winter"]), parse(Int, replace(l, "Cluster" => ""))))
	function DrawCluster!(label, show_label)
		df = dfs_by_label[label]
		season, color = SeasonOf(label)
		emphasised = label in highlight
		Plots.plot!(p, df.Hour, df.ResidualDemand; color = color, linewidth = emphasised ? 2 : 1,
			alpha = emphasised ? 1.0 : 0.5, label = show_label ? "$season - $label ($(Date(df.Time[1])))" : "")
	end
	foreach(l -> DrawCluster!(l, true), ordered)
	foreach(l -> DrawCluster!(l, false), intersect(ordered, highlight))
	savefig(p, joinpath(analysis_dir_path, "residual_demand_all_clusters_highlighted.png"))
	return p
end

function WriteTables(dfs_by_label, labels, analysis_dir_path)
	combined = DataFrame(Hour = dfs_by_label[labels[1]].Hour)
	for label in labels
		df = dfs_by_label[label]
		combined[!, label] = df.ResidualDemand[1:min(nrow(df), nrow(combined))] |> v -> vcat(v, fill(missing, nrow(combined) - length(v)))
	end
	XLSX.writetable(joinpath(analysis_dir_path, "residual_demand.xlsx"),
		"Residual demand" => combined,
		[label => dfs_by_label[label] for label in labels]...)
end

function PerformAnalysis(config_paths = DEFAULT_CONFIGS; output_base = PostAnalysisCommon.NewAnalysisOutputDir(Dict(basename(c) => c for c in config_paths); label = "residual_demand"))
	analysis_dir_path = joinpath(output_base, "residual_demand")
	mkpath(analysis_dir_path)
	labels = String[]
	dfs_by_label = Dict{String,DataFrame}()
	for config in config_paths
		path = ResolveConfigPath(config)
		label = ClusterLabel(splitext(basename(path))[1])
		haskey(dfs_by_label, label) && throw("two configs share the label \"$label\" - pass one config per cluster")
		dfs_by_label[label] = ResidualDemandForConfig(path)
		push!(labels, label)
		display(PlotCluster(dfs_by_label[label], label, analysis_dir_path))
	end
	display(PlotCombined(dfs_by_label, labels, analysis_dir_path))
	display(PlotCombinedHighlighted(dfs_by_label, labels, analysis_dir_path))
	WriteTables(dfs_by_label, labels, analysis_dir_path)
	println("residual demand plots written to $analysis_dir_path")
	return dfs_by_label
end

end;

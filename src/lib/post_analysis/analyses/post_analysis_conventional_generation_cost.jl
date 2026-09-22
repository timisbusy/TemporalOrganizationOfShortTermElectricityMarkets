# Average hourly-of-day cost of the three conventional (dispatchable) generators - Base, Shoulder,
# Peak - compared across rolling-horizon runs with different optimization window lengths (36h/48h/
# 72h). Cost per generator per MTU is its own bidPrice (EUR/MWh, read from each case's own copied
# agent configuration under Config/ rather than hardcoded, since that's the actual "offer price"
# the market clears against) times its dispatched quantity (MWh) from that case's
# final_dispatch_decisions.xlsx - MTU duration is 1 hour (timePeriodsPerDay: 24), so quantity
# (MWh) times price (EUR/MWh) is already EUR with no further conversion. Costs are summed across
# the three generators per MTU, then averaged across all analyzed days for each hour-of-day
# (0-23) - the same MTU % 24 grouping AddDayAndHour! uses elsewhere in this suite - so the result
# is a single "typical day" cost profile per window length, over the same MTU 24:695 window this
# suite otherwise reports (see PostAnalysisCommon.DEFAULT_TIME_RANGE).

module PostAnalysisConventionalGenerationCost

using Plots, DataFrames, XLSX, YAML, Statistics

include("../post_analysis_common.jl")
include("./post_analysis_daily.jl")

# Base/Shoulder/Peak only - Wind/Solar are zero-bid variable generators, excluded from
# "conventional generator cost" here.
CONVENTIONAL_GENERATORS = ["3G_Base", "4G_Shoulder", "5G_Peak"]

# label -> single-design run directory, one per optimization-window length being compared - same
# shape as PostAnalysisCommon.DEFAULT_CASE_PATHS, but keyed by window length rather than Fixed/
# Rolling since that's what this analysis varies. cases below fixes the draw/legend order, since
# Dict iteration order isn't guaranteed and "36h, 48h, 72h" reads far better than an arbitrary one.
const DEFAULT_CASE_PATHS = Dict{String,String}(
	"36h" => "results/1789748169_rolling_36_no_cap_1d_spinup",
	"48h" => "results/1789748204_rolling_48_no_cap_1d_spinup",
	"72h" => "results/1789748246_rolling_72_no_cap_1d_spinup",
)
const DEFAULT_CASES = ["36h", "48h", "72h"]

# PostAnalysisCommon.DefaultAnalysisLabel only knows the Fixed/Rolling Horizon case names, so it
# silently produces an empty label against this module's own 36h/48h/72h-keyed case_paths - build
# our own straight from the case labels instead (they're short and already descriptive, unlike
# the Fixed/Rolling Horizon pair's arbitrary run directory names, so no need to fall back to
# those - which would run this suite's already-long {timestamp}_{label} output_base straight into
# Windows' 260-char MAX_PATH once a filename is added on top, three window lengths deep).
DefaultLabel(case_paths, cases) = join([c for c in cases if haskey(case_paths, c)], "_vs_")

function PerformAnalysis(case_paths=DEFAULT_CASE_PATHS; cases=DEFAULT_CASES, output_base=PostAnalysisCommon.NewAnalysisOutputDir(case_paths; label=DefaultLabel(case_paths, cases)), time_range=PostAnalysisCommon.DEFAULT_TIME_RANGE)
	# kept short ("gen_cost", not "conventional_generation_cost") for the same MAX_PATH reason -
	# see PostAnalysisPhysicalIndicators' analysis_dir_path comment.
	analysis_dir_path = "$output_base/gen_cost"
	PostAnalysisCommon.CleanDirectory(analysis_dir_path)

	hourly_avg_cost = Dict{String,Vector{Float64}}()
	for case in cases
		dd = PostAnalysisCommon.LoadFile(joinpath(case_paths[case], "final_dispatch_decisions.xlsx"))
		dd = dd[time_range.start .<= dd.mtu .<= time_range.stop, :]

		bid_prices = LoadGeneratorBidPrices(case_paths[case])
		dd[!, :TotalCost] = sum(bid_prices[g] .* dd[!, g] for g in CONVENTIONAL_GENERATORS)

		PostAnalysisDaily.AddDayAndHour!(dd, Symbol("mtu"))
		hourly = sort(combine(groupby(dd, :Hour), :TotalCost => mean => :AvgTotalCost), :Hour)
		hourly_avg_cost[case] = hourly.AvgTotalCost
	end

	PlotHourlyCost(hourly_avg_cost, cases, analysis_dir_path)
	WriteHourlyCostTable(hourly_avg_cost, cases, analysis_dir_path)

	return hourly_avg_cost
end

# Reads bidPrice (EUR/MWh) for each conventional generator from the run's own copied agent
# configuration under Config/ (see ClearMarket.CopyConfigFiles!) - discovered by content rather
# than a fixed filename, since the copy is named after whatever agentConfig the experiment
# actually referenced (e.g. "validate_laura_agents.yaml").
function LoadGeneratorBidPrices(case_path; generators=CONVENTIONAL_GENERATORS)
	config_dir = joinpath(case_path, "Config")
	for f in readdir(config_dir)
		endswith(f, ".yaml") || continue
		data = YAML.load_file(joinpath(config_dir, f))
		haskey(data, "dispatchableGenerators") || continue
		gens = data["dispatchableGenerators"]
		all(haskey(gens, g) for g in generators) || continue
		return Dict(g => Float64(gens[g]["bidPrice"]) for g in generators)
	end
	throw("no agent configuration with dispatchableGenerators found in $config_dir")
end

function PlotHourlyCost(hourly_avg_cost, cases, analysis_dir_path)
	p = Plots.plot(xlabel="Hour of Day", ylabel="Avg. Conventional Generation Cost (€)",
					title="Base + Shoulder + Peak Cost by Hour of Day",
					xticks=0:2:23, legend=:topleft,
					size=(1000, 600), left_margin=10Plots.mm, bottom_margin=8Plots.mm)
	for case in cases
		Plots.plot!(p, 0:23, hourly_avg_cost[case], label=case, marker=:circle, markersize=3, linewidth=2)
	end
	display(p)
	savefig(p, "$analysis_dir_path/hourly_cost.png")
end

function WriteHourlyCostTable(hourly_avg_cost, cases, analysis_dir_path)
	df = DataFrame(Hour = 0:23)
	for case in cases
		df[!, Symbol(case)] = hourly_avg_cost[case]
	end
	XLSX.writetable("$analysis_dir_path/hourly_cost.xlsx", "data" => df; overwrite=true)
end

end;

# Average hourly-of-day FinalAuctionPrice compared across rolling-horizon runs with different
# optimization window lengths (36h/48h/72h) - same shape as PostAnalysisConventionalGenerationCost,
# but averaging each case's own FinalAuctionPrice (EUR/MWh) per MTU
# by hour-of-day (0-23, the same MTU % 24 grouping AddDayAndHour! uses elsewhere in this suite)
# instead of summing a generation cost, over the same MTU 24:695 window this suite otherwise
# reports (see PostAnalysisCommon.DEFAULT_TIME_RANGE).
#
# segment selects which price is reported:
#   :energy    (default) - the energy markets' price: final_dispatch_decisions_energy.xlsx (per MTU, the last
#              clearing that traded it as an energy MTU)
#   :balancing - the balancing price: the Segment == Balancing rows of final_dispatch_decisions.xlsx (per MTU,
#              the clearing in which it was a locked MTU)

module PostAnalysisPriceByHour

using Plots, DataFrames, XLSX, Statistics

include("../post_analysis_common.jl")
include("./post_analysis_daily.jl")
include("./post_analysis_conventional_generation_cost.jl")

# same case_paths/cases as PostAnalysisConventionalGenerationCost - a single shared source rather
# than each window-length submodule hardcoding its own copy of the same defaults (which drift
# independently otherwise - see PostAnalysisWindowLengthKPIs/StorageKPIs/ResidenceTime, which
# already follow this pattern).
const DEFAULT_CASE_PATHS = PostAnalysisConventionalGenerationCost.DEFAULT_CASE_PATHS
const DEFAULT_CASES = PostAnalysisConventionalGenerationCost.DEFAULT_CASES

function PerformAnalysis(case_paths=DEFAULT_CASE_PATHS; cases=DEFAULT_CASES, output_base=PostAnalysisCommon.NewAnalysisOutputDir(case_paths; label=PostAnalysisConventionalGenerationCost.DefaultLabel(case_paths, cases)), time_range=nothing, segment::Symbol=:energy)
	segment in (:energy, :balancing) || throw("segment must be :energy or :balancing, got :$segment")
	println("starting analysis: price by hour ($segment)")
	# nothing: the window the runs' own configs define (see PostAnalysisCommon.ResolveTimeRange)
	time_range = PostAnalysisCommon.ResolveTimeRange(time_range, case_paths, cases; output_base=output_base)
	# kept short for the same MAX_PATH reason as PostAnalysisConventionalGenerationCost's gen_cost.
	analysis_dir_path = "$output_base/price_by_hour_$segment"
	PostAnalysisCommon.CleanDirectory(analysis_dir_path)

	hourly_avg_price = Dict{String,Vector{Float64}}()
	for case in cases
		dd = LoadSegmentDispatch(case_paths[case], segment)
		dd = dd[time_range.start .<= dd.mtu .<= time_range.stop, :]

		PostAnalysisDaily.AddDayAndHour!(dd, Symbol("mtu"))
		hourly = sort(combine(groupby(dd, :Hour), :FinalAuctionPrice => mean => :AvgFinalAuctionPrice), :Hour)
		hourly_avg_price[case] = hourly.AvgFinalAuctionPrice
	end

	PlotHourlyPrice(hourly_avg_price, cases, analysis_dir_path, segment)
	WriteHourlyPriceTable(hourly_avg_price, cases, analysis_dir_path)

	return hourly_avg_price
end

# the per-MTU dispatch rows whose FinalAuctionPrice is the price of the requested segment (see the header)
function LoadSegmentDispatch(case_path, segment)
	if segment == :energy
		return PostAnalysisCommon.LoadFile(joinpath(case_path, "final_dispatch_decisions_energy.xlsx"))
	end
	dd = PostAnalysisCommon.LoadFile(joinpath(case_path, "final_dispatch_decisions.xlsx"))
	hasproperty(dd, :Segment) || throw("final dispatch decisions in $case_path have no \"Segment\" column - this run predates the balancing/energy split; rerun it")
	return dd[dd.Segment .== "Balancing", :]
end

function PlotHourlyPrice(hourly_avg_price, cases, analysis_dir_path, segment)
	p = Plots.plot(xlabel="Hour of Day", ylabel="Avg. $(titlecase(String(segment))) Price (€/MWh)",
					title="$(titlecase(String(segment))) Price by Hour of Day",
					xticks=0:2:23, legend=:topleft,
					size=(1000, 600), left_margin=10Plots.mm, bottom_margin=8Plots.mm)
	for case in cases
		Plots.plot!(p, 0:23, hourly_avg_price[case], label=case, marker=:circle, markersize=3, linewidth=2)
	end
	display(p)
	savefig(p, "$analysis_dir_path/hourly_price.png")
end

function WriteHourlyPriceTable(hourly_avg_price, cases, analysis_dir_path)
	df = DataFrame(Hour = 0:23)
	for case in cases
		df[!, Symbol(case)] = hourly_avg_price[case]
	end
	XLSX.writetable("$analysis_dir_path/hourly_price.xlsx", "data" => df; overwrite=true)
end

end;

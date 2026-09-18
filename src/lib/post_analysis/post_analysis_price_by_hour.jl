# Average hourly-of-day FinalAuctionPrice compared across rolling-horizon runs with different
# optimization window lengths (36h/48h/72h) - same shape as PostAnalysisConventionalGenerationCost,
# but averaging each case's own final_dispatch_decisions.xlsx FinalAuctionPrice (EUR/MWh) per MTU
# by hour-of-day (0-23, the same MTU % 24 grouping AddDayAndHour! uses elsewhere in this suite)
# instead of summing a generation cost, over the same MTU 24:695 window this suite otherwise
# reports (see PostAnalysisCommon.DEFAULT_TIME_RANGE).

module PostAnalysisPriceByHour

using Plots, DataFrames, XLSX, Statistics

include("./post_analysis_common.jl")
include("./post_analysis_daily.jl")

# label -> single-design run directory, one per optimization-window length being compared - same
# shape/defaults as PostAnalysisConventionalGenerationCost.DEFAULT_CASE_PATHS.
const DEFAULT_CASE_PATHS = Dict{String,String}(
	"36h" => "results/1789572958_rolling_36_no_cap_1d_spinup",
	"48h" => "results/1789663548_rolling_48_no_cap_1d_spinup",
	"72h" => "results/1789663548_rolling_72_no_cap_1d_spinup",
)
const DEFAULT_CASES = ["36h", "48h", "72h"]

DefaultLabel(case_paths, cases) = join([c for c in cases if haskey(case_paths, c)], "_vs_")

function PerformAnalysis(case_paths=DEFAULT_CASE_PATHS; cases=DEFAULT_CASES, output_base=PostAnalysisCommon.NewAnalysisOutputDir(case_paths; label=DefaultLabel(case_paths, cases)), time_range=PostAnalysisCommon.DEFAULT_TIME_RANGE)
	# kept short for the same MAX_PATH reason as PostAnalysisConventionalGenerationCost's gen_cost.
	analysis_dir_path = "$output_base/price_by_hour"
	PostAnalysisCommon.CleanDirectory(analysis_dir_path)

	hourly_avg_price = Dict{String,Vector{Float64}}()
	for case in cases
		dd = PostAnalysisCommon.LoadFile(joinpath(case_paths[case], "final_dispatch_decisions.xlsx"))
		dd = dd[time_range.start .<= dd.mtu .<= time_range.stop, :]

		PostAnalysisDaily.AddDayAndHour!(dd, Symbol("mtu"))
		hourly = sort(combine(groupby(dd, :Hour), :FinalAuctionPrice => mean => :AvgFinalAuctionPrice), :Hour)
		hourly_avg_price[case] = hourly.AvgFinalAuctionPrice
	end

	PlotHourlyPrice(hourly_avg_price, cases, analysis_dir_path)
	WriteHourlyPriceTable(hourly_avg_price, cases, analysis_dir_path)

	return hourly_avg_price
end

function PlotHourlyPrice(hourly_avg_price, cases, analysis_dir_path)
	p = Plots.plot(xlabel="Hour of Day", ylabel="Avg. Final Auction Price (€/MWh)",
					title="Final Auction Price by Hour of Day",
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

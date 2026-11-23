# Price against traded volume, one point per MTU: the y value is the MTU's volume-weighted average price and the
# x value its traded volume, both exactly as PostAnalysisWeightedPrice defines them (all transactions of the
# delivery MTU, weight = |Quantity|; x is the MTU's traded volume counting one side of each trade, i.e. half the
# sum of those weights, over every clearing that traded the MTU). One colour per case (up to 3), over the window the runs' own configs define.
#
# segment selects the transactions, as in PostAnalysisWeightedPrice: :energy (default), :all or :balancing.
#
# Output: $output_base/price_volume_scatter_$segment/price_volume_scatter.png and .xlsx (mtu, price and volume per case)

module PostAnalysisPriceVolumeScatter

using Plots, DataFrames, XLSX

include("../post_analysis_common.jl")
include("./post_analysis_weighted_price.jl")

# categorical slots 1-3 of the dataviz reference palette (blue, orange, aqua); first three validate for every pair
const POINT_COLORS = PostAnalysisWeightedPrice.LINE_COLORS
const SURFACE = PostAnalysisWeightedPrice.SURFACE
const AXIS_COLOR = PostAnalysisWeightedPrice.AXIS_COLOR
const GRID_COLOR = PostAnalysisWeightedPrice.GRID_COLOR
const TEXT_PRIMARY = PostAnalysisWeightedPrice.TEXT_PRIMARY
const TEXT_MUTED = PostAnalysisWeightedPrice.TEXT_MUTED

function PerformAnalysis(case_paths=PostAnalysisCommon.DEFAULT_CASE_PATHS; cases=PostAnalysisCommon.CASES, output_base=PostAnalysisCommon.NewAnalysisOutputDir(case_paths; label=PostAnalysisCommon.DefaultAnalysisLabel(case_paths, cases)), time_range=nothing, segment::Symbol=:energy)
	PostAnalysisCommon.SetPlotMark!(case_paths, cases)
	segment in (:all, :energy, :balancing) || throw("segment must be :all, :energy or :balancing, got :$segment")
	length(cases) <= length(POINT_COLORS) || throw("at most $(length(POINT_COLORS)) cases can be drawn, got $(length(cases))")
	println("starting analysis: price vs traded volume scatter ($segment)")
	time_range = PostAnalysisCommon.ResolveTimeRange(time_range, case_paths, cases; output_base=output_base)
	analysis_dir_path = "$output_base/price_volume_scatter_$segment"
	PostAnalysisCommon.CleanDirectory(analysis_dir_path)

	points = Dict{String,DataFrame}()
	for case in cases
		transactions = PostAnalysisCommon.LoadCaseFile(case_paths, case, "transactions.xlsx")
		df = PostAnalysisWeightedPrice.WeightedPriceByMTU(transactions, time_range, segment)
		points[case] = df[.!ismissing.(df.price), :] # an MTU with no traded volume has no price, so no point
	end

	PlotScatter(points, cases, segment, "$analysis_dir_path/price_volume_scatter.png")
	WriteTable(points, cases, "$analysis_dir_path/price_volume_scatter.xlsx")
	return points
end

function PlotScatter(points, cases, segment, path)
	segment_label = segment == :all ? "" : " ($(segment) transactions)"
	p = Plots.plot(xlabel="Traded volume per MTU, one side of each trade (MWh)", ylabel="Volume-weighted price (€/MWh)",
					title="Price vs traded volume, one point per MTU$segment_label",
					legend=:topright, xformatter=x -> string(round(Int, x)),
					size=(1000, 640), left_margin=16Plots.mm, right_margin=8Plots.mm, bottom_margin=10Plots.mm, top_margin=6Plots.mm,
					background_color=SURFACE, foreground_color_axis=AXIS_COLOR, foreground_color_border=AXIS_COLOR,
					foreground_color_text=TEXT_PRIMARY, foreground_color_guide=TEXT_PRIMARY, foreground_color_legend=SURFACE,
					gridcolor=GRID_COLOR, gridalpha=1.0, gridlinewidth=0.5, tickfontcolor=TEXT_MUTED, tickfontsize=10, guidefontsize=11, titlefontsize=12)
	for (i, case) in enumerate(cases)
		df = points[case]
		# 2px surface ring keeps overlapping points of different cases apart
		Plots.scatter!(p, df.volume, Float64.(df.price), label=case, color=POINT_COLORS[i], markersize=6, markeralpha=0.85,
			markerstrokecolor=SURFACE, markerstrokewidth=2)
	end
	display(p)
	PostAnalysisCommon.SaveFigure(p, path)
end

function WriteTable(points, cases, path)
	sheets = Pair{String,DataFrame}[]
	for case in cases
		df = DataFrame(mtu=points[case].mtu, price=Float64.(points[case].price), traded_volume_one_side=points[case].volume)
		push!(sheets, first(case, 31) => df) # Excel sheet names are capped at 31 characters
	end
	XLSX.writetable(path, sheets...; overwrite=true)
end

end;

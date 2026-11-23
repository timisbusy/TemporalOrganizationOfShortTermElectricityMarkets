# Volume-weighted average price of every transaction in an MTU, over the run's analysis window.
#
# For each delivery MTU (the transactions' "Market Time Unit") all of its transactions - from every clearing that
# traded it, every agent - are averaged with the traded volume as the weight:
#
#     price(mtu) = sum(|Quantity| * Price) / sum(|Quantity|)
#
# The weight is the absolute quantity because a transaction's quantity is signed (a storage charge, or a later
# clearing buying back an earlier sale, is negative) but any of them is traded volume. An MTU with no traded volume
# has no price and is left as a gap in the line.
#
# The traded volume reported next to the price (table, and the x axis of the price/volume scatter) counts one side
# of each trade: every trade appears twice in the transactions (seller and buyer), so it is sum(|Quantity|) / 2.
# That halving does not change the price - both sides of a trade share its price.
#
# segment selects which transactions are averaged:
#   :energy    (default) - Segment == "Energy" only
#   :all       - the energy and the balancing transactions together
#   :balancing - Segment == "Balancing" only (see balancing_energy_split.jl)
#
# One line per case (up to 3), over the window the runs' own configs define (PostAnalysisCommon.ResolveTimeRange).

module PostAnalysisWeightedPrice

using Plots, DataFrames, XLSX, Statistics

include("../post_analysis_common.jl")

const TRANSACTION_PRICE = "Price (€/MWh)"
const TRANSACTION_QUANTITY = "Quantity (MWh)"
const TRANSACTION_MTU = "Market Time Unit"

# categorical slots 1 and 2 of the dataviz reference palette (blue, orange), light surface
const LINE_COLORS = ["#2a78d6", "#eb6834", "#1baf7a"]   # slot 3 (aqua): the first three slots validate for every pair
const SURFACE = "#fcfcfb"
const AXIS_COLOR = "#c3c2b7"
const GRID_COLOR = "#e1e0d9"
const TEXT_PRIMARY = "#0b0b0b"
const TEXT_MUTED = "#898781"

function PerformAnalysis(case_paths=PostAnalysisCommon.DEFAULT_CASE_PATHS; cases=PostAnalysisCommon.CASES, output_base=PostAnalysisCommon.NewAnalysisOutputDir(case_paths; label=PostAnalysisCommon.DefaultAnalysisLabel(case_paths, cases)), time_range=nothing, segment::Symbol=:energy)
	PostAnalysisCommon.SetPlotMark!(case_paths, cases)
	segment in (:all, :energy, :balancing) || throw("segment must be :all, :energy or :balancing, got :$segment")
	length(cases) <= length(LINE_COLORS) || throw("at most $(length(LINE_COLORS)) cases can be drawn, got $(length(cases))")
	println("starting analysis: volume-weighted price ($segment)")
	time_range = PostAnalysisCommon.ResolveTimeRange(time_range, case_paths, cases; output_base=output_base)
	analysis_dir_path = "$output_base/weighted_price_$segment"
	PostAnalysisCommon.CleanDirectory(analysis_dir_path)

	prices = Dict{String,DataFrame}()
	for case in cases
		transactions = PostAnalysisCommon.LoadCaseFile(case_paths, case, "transactions.xlsx")
		prices[case] = WeightedPriceByMTU(transactions, time_range, segment)
	end

	PlotWeightedPrice(prices, cases, time_range, analysis_dir_path, segment)
	WritePriceTable(prices, cases, time_range, analysis_dir_path)
	return prices
end

# One row per MTU of time_range: its volume-weighted price (missing if nothing was traded) and its traded volume.
function WeightedPriceByMTU(transactions, time_range, segment)
	if segment == :energy && !hasproperty(transactions, PostAnalysisCommon.SEGMENT_COLUMN)
		# runs from before the balancing/energy split have no Segment column: use every transaction
		@warn "transactions have no \"$(PostAnalysisCommon.SEGMENT_COLUMN)\" column (run predates the balancing/energy split) - averaging all transactions"
	elseif segment != :all
		hasproperty(transactions, PostAnalysisCommon.SEGMENT_COLUMN) || throw("transactions have no \"$(PostAnalysisCommon.SEGMENT_COLUMN)\" column - this run predates the balancing/energy split; rerun it")
		wanted = segment == :energy ? PostAnalysisCommon.ENERGY_SEGMENT : "Balancing"
		transactions = transactions[transactions[!, PostAnalysisCommon.SEGMENT_COLUMN] .== wanted, :]
	end
	transactions = transactions[time_range.start .<= transactions[!, TRANSACTION_MTU] .<= time_range.stop, :]

	weight = abs.(transactions[!, TRANSACTION_QUANTITY])
	by_mtu = combine(groupby(DataFrame(mtu=transactions[!, TRANSACTION_MTU], value=transactions[!, TRANSACTION_PRICE] .* weight, volume=weight), :mtu),
		:value => sum => :value, :volume => sum => :volume)

	out = leftjoin(DataFrame(mtu=collect(time_range)), by_mtu; on=:mtu)
	out.volume = coalesce.(out.volume, 0.0)
	out.price = [v > 0 ? value / v : missing for (value, v) in zip(out.value, out.volume)]
	out.volume = out.volume ./ 2 # one side of each trade (see the header); the price above already used the full weights
	return sort(select(out, :mtu, :price, :volume), :mtu)
end

function PlotWeightedPrice(prices, cases, time_range, analysis_dir_path, segment)
	multiple = length(cases) > 1
	segment_label = segment == :all ? "" : " ($(segment) transactions)"
	p = Plots.plot(xlabel="MTU", ylabel="Volume-weighted price (€/MWh)",
					title=multiple ? "Volume-weighted price per MTU$segment_label" : "Volume-weighted price per MTU$segment_label - $(cases[1])",
					legend=multiple ? :topleft : false,
					xticks=first(time_range):24:last(time_range),
					size=(1280, 450), left_margin=16Plots.mm, bottom_margin=10Plots.mm, top_margin=6Plots.mm,
					background_color=SURFACE, foreground_color_axis=AXIS_COLOR, foreground_color_border=AXIS_COLOR,
					foreground_color_text=TEXT_PRIMARY, foreground_color_guide=TEXT_PRIMARY, foreground_color_legend=SURFACE,
					gridcolor=GRID_COLOR, gridalpha=1.0, gridlinewidth=0.5, tickfontcolor=TEXT_MUTED, tickfontsize=10, guidefontsize=11, titlefontsize=12)
	for (i, case) in enumerate(cases)
		df = prices[case]
		# missing -> NaN so the line breaks at an MTU with no trades instead of bridging it
		Plots.plot!(p, df.mtu, [ismissing(x) ? NaN : x for x in df.price], label=case, color=LINE_COLORS[i], linewidth=2)
	end
	display(p)
	PostAnalysisCommon.SaveFigure(p, "$analysis_dir_path/weighted_price.png")
end

function WritePriceTable(prices, cases, time_range, analysis_dir_path)
	df = DataFrame(mtu=collect(time_range))
	for case in cases
		df[!, Symbol("$(case) price (€/MWh)")] = prices[case].price
		df[!, Symbol("$(case) traded volume, one side (MWh)")] = prices[case].volume
	end
	XLSX.writetable("$analysis_dir_path/weighted_price.xlsx", "data" => df; overwrite=true)
end

end;

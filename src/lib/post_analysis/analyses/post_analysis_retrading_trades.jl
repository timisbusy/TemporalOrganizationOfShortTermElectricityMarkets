# One agent's trades for one delivery MTU across every auction that traded it, and what retrading did for that
# agent's surplus.
#
# Retrading surplus follows PlotRetradingImpacts: over the agent's transactions with Times Cleared > 1 (every
# clearing after the first one that touched the MTU), a generator's surplus change is
#     sum(Quantity * (Price - bid price))      (revenue - quantity * marginal cost)
# so selling at the bid price gains nothing, and buying a previous sale back below it gains the difference.
# FindRetradingGains lists the delivery MTUs in the analysis window by that gain; PerformAnalysis plots the
# best one (or the `mtu` you give) per case.
#
# Plot: the x axis is the auction (clearing) MTU shared by two stacked panels - top the price of each trade (markers only,
# auctions in between did not trade this MTU for the agent) with
# the agent's bid price as a dashed reference, bottom the volume traded (positive = sold, negative = bought back;
# a generator's quantities are signed this way in the transactions). Balancing-segment trades are drawn as
# hollow markers/bars.
#
# Output: $output_base/retrading_trades/retrading_<agent>_mtu<mtu>_<case slug>.png and .xlsx (the trades)

module PostAnalysisRetradingTrades

using Plots, DataFrames, XLSX

include("../post_analysis_common.jl")

const TRANSACTION_MTU = "Market Time Unit"
const CLEARING_MTU = "Clearing MTU"
const QUANTITY = "Quantity (MWh)"
const PRICE = "Price (€/MWh)"
const TIMES_CLEARED = "Times Cleared"

const PRICE_COLOR = "#2a78d6"   # categorical slot 1
const VOLUME_COLOR = "#eb6834"  # categorical slot 2
const SURFACE = "#fcfcfb"
const AXIS_COLOR = "#c3c2b7"
const GRID_COLOR = "#e1e0d9"
const TEXT_PRIMARY = "#0b0b0b"
const TEXT_MUTED = "#898781"

# bid price of a generator from the run's copied agent config
function GeneratorBidPrice(case_path, agent)
	agent_cfg = PostAnalysisCommon.LoadCaseConfigsByRole(case_path)[3]
	agent_cfg === nothing && throw("$case_path has no agent config copy - cannot read $agent's bid price")
	for section in ("dispatchableGenerators", "variableGenerators")
		generators = get(agent_cfg, section, nothing)
		generators !== nothing && haskey(generators, agent) && return Float64(generators[agent]["bidPrice"])
	end
	throw("$agent is not a generator in $case_path's agent config")
end

# DataFrame (mtu, retrading_surplus, retraded_quantity, n_retrades) of the delivery MTUs in time_range where the
# agent has retrading transactions, best gain first.
function FindRetradingGains(transactions, agent, bid_price, time_range)
	own = transactions[(transactions.Agent .== agent) .& (time_range.start .<= transactions[!, TRANSACTION_MTU] .<= time_range.stop) .& (transactions[!, TIMES_CLEARED] .> 1), :]
	nrow(own) == 0 && return DataFrame(mtu=Int[], retrading_surplus=Float64[], retraded_quantity=Float64[], n_retrades=Int[])
	own = copy(own)
	own.gain = own[!, QUANTITY] .* (own[!, PRICE] .- bid_price)
	gains = combine(groupby(own, TRANSACTION_MTU), :gain => sum => :retrading_surplus, QUANTITY => sum => :retraded_quantity, nrow => :n_retrades)
	rename!(gains, TRANSACTION_MTU => :mtu)
	return sort(gains, :retrading_surplus; rev=true)
end

function PerformAnalysis(case_paths=PostAnalysisCommon.DEFAULT_CASE_PATHS; cases=PostAnalysisCommon.CASES, output_base=PostAnalysisCommon.NewAnalysisOutputDir(case_paths; label=PostAnalysisCommon.DefaultAnalysisLabel(case_paths, cases)), time_range=nothing, agent="5G_Peak", mtu=nothing)
	PostAnalysisCommon.SetPlotMark!(case_paths, cases)
	println("starting analysis: retrading trades of $agent")
	time_range = PostAnalysisCommon.ResolveTimeRange(time_range, case_paths, cases; output_base=output_base)
	analysis_dir_path = "$output_base/retrading_trades"
	PostAnalysisCommon.CleanDirectory(analysis_dir_path)

	results = Dict{String,Any}()
	for case in cases
		transactions = PostAnalysisCommon.LoadCaseFile(case_paths, case, "transactions.xlsx")
		bid_price = GeneratorBidPrice(case_paths[case], agent)
		gains = FindRetradingGains(transactions, agent, bid_price, time_range)
		println("$case: top retrading gains for $agent (bid price $bid_price):")
		println(first(gains, 5))
		chosen = mtu === nothing ? (nrow(gains) > 0 && gains.retrading_surplus[1] > 0 ? gains.mtu[1] : nothing) : mtu
		if chosen === nothing
			println("$case: $agent gains no surplus from retrading in $time_range - nothing plotted")
			continue
		end
		trades = TradesForMTU(transactions, agent, chosen)
		surplus = sum(gains[gains.mtu .== chosen, :retrading_surplus]; init=0.0)
		slug = PostAnalysisCommon.CaseSlug(case)
		PlotTrades(trades, case, agent, chosen, bid_price, surplus, "$analysis_dir_path/retrading_$(agent)_mtu$(chosen)_$slug.png")
		XLSX.writetable("$analysis_dir_path/retrading_$(agent)_mtu$(chosen)_$slug.xlsx", "trades" => trades, "ranking" => gains; overwrite=true)
		results[case] = (mtu=chosen, surplus=surplus, trades=trades, gains=gains)
	end
	return results
end

# the agent's transactions for one delivery MTU, in auction order
function TradesForMTU(transactions, agent, mtu)
	trades = transactions[(transactions.Agent .== agent) .& (transactions[!, TRANSACTION_MTU] .== mtu), :]
	has_segment = hasproperty(trades, PostAnalysisCommon.SEGMENT_COLUMN)
	return sort(DataFrame(clearing_mtu=trades[!, CLEARING_MTU], quantity=Float64.(trades[!, QUANTITY]), price=Float64.(trades[!, PRICE]),
		times_cleared=trades[!, TIMES_CLEARED], segment=has_segment ? String.(trades[!, PostAnalysisCommon.SEGMENT_COLUMN]) : fill("Energy", nrow(trades))), :clearing_mtu)
end

function PlotTrades(trades, case, agent, mtu, bid_price, surplus, path)
	chrome = (background_color=SURFACE, foreground_color_axis=AXIS_COLOR, foreground_color_border=AXIS_COLOR,
		foreground_color_text=TEXT_PRIMARY, foreground_color_guide=TEXT_PRIMARY, foreground_color_legend=SURFACE,
		gridcolor=GRID_COLOR, gridalpha=1.0, gridlinewidth=0.5, tickfontcolor=TEXT_MUTED, tickfontsize=10, guidefontsize=11,
		left_margin=16Plots.mm)
	energy = trades[trades.segment .== "Energy", :]
	balancing = trades[trades.segment .!= "Energy", :]
	xs = minimum(trades.clearing_mtu):maximum(trades.clearing_mtu)
	xlims = (first(xs) - 1, last(xs) + 1)
	ticks = first(xs):2:last(xs)

	top = Plots.plot(; ylabel="Price (€/MWh)", legend=:top, legend_columns=3, ylims=(min(minimum(trades.price), bid_price) - 5, max(maximum(trades.price), bid_price) + 0.16 * (max(maximum(trades.price), bid_price) - min(minimum(trades.price), bid_price) + 10)), xticks=(ticks, fill("", length(ticks))), xlims=xlims,
		title="$agent, delivery MTU $mtu: trades by auction MTU - $case (retrading surplus $(round(Int, surplus)) €)", titlefontsize=11, top_margin=6Plots.mm, chrome...)
	Plots.hline!(top, [bid_price]; label="bid price $(round(Int, bid_price))", color=TEXT_MUTED, linestyle=:dash, linewidth=1.5)
	Plots.scatter!(top, energy.clearing_mtu, energy.price; label="energy trade", color=PRICE_COLOR, markersize=7, markerstrokecolor=SURFACE, markerstrokewidth=2)
	nrow(balancing) > 0 && Plots.scatter!(top, balancing.clearing_mtu, balancing.price; label="balancing trade", color=SURFACE, markersize=7, markerstrokecolor=PRICE_COLOR, markerstrokewidth=2)

	bottom = Plots.plot(; ylabel="Volume traded (MWh)", xlabel="Auction MTU (clearing)", legend=false, xticks=ticks, xlims=xlims, ylims=(min(0.0, minimum(trades.quantity)) * 1.08, max(0.0, maximum(trades.quantity)) * 1.08),
		bottom_margin=10Plots.mm, yformatter=y -> string(round(Int, y)), chrome...)
	Plots.hline!(bottom, [0.0]; label=false, color=AXIS_COLOR, linewidth=1)
	Plots.bar!(bottom, energy.clearing_mtu, energy.quantity; color=VOLUME_COLOR, bar_width=0.7, linewidth=0)
	nrow(balancing) > 0 && Plots.bar!(bottom, balancing.clearing_mtu, balancing.quantity; color=SURFACE, bar_width=0.7, linecolor=VOLUME_COLOR, linewidth=2)

	p = Plots.plot(top, bottom; layout=Plots.grid(2, 1; heights=[0.55, 0.45]), link=:x, size=(1280, 760), background_color=SURFACE,
		plot_title="") # keeps the mark's title slot predictable
	display(p)
	PostAnalysisCommon.SaveFigure(p, path)
end

end;

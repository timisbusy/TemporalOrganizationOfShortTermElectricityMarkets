# Illustrates the mechanism behind Gross Traded Volume (see post_analysis_solver_comparison.jl /
# post_analysis_price_bucket_comparison.jl) at the level of a single auction: one clearing's own
# RAW per-clearing export already contains both its new dispatch plan and the "_adj" delta from
# whatever was previously planned, for every MTU in its look-ahead window. sum(|adjustment|)
# across that one auction's whole window is exactly that auction's own contribution to Gross
# Traded Volume - every one of the ~661 auctions in a run produces a vector like this, and the
# metric sums |adjustment| across every one of them, so a single delivery hour accumulates volume
# from every earlier auction that ever revised its plan for that hour, not just the one that
# finally executes it.

module PostAnalysisSingleAuctionAdjustment

using XLSX, DataFrames, Plots, StatsPlots

results_path_base = "results/analysis"

# the canonical validated rolling-case baseline run (not a solver-permutation comparison run -
# this illustration is about the mechanism itself, not about solver differences)
result_dir = "results/1788950636_laura_final_check_rolling"
raw_prefix = "decisionvariables_validate_laura_rolling_36_"

clearing_mtu = 165 # the auction being illustrated

generators = ["3G_Base", "4G_Shoulder", "5G_Peak", "6G_Wind", "7G_Solar"]
gen_labels = ["Base", "Shoulder", "Peak", "Wind", "Solar"]
gen_colors = [RGB(0.55, 0.45, 0.10), RGB(0.75, 0.55, 0.20), RGB(0.55, 0.20, 0.20), RGB(0.20, 0.55, 0.80), RGB(0.90, 0.70, 0.15)]

function CleanDirectory(path)
	mkpath(path)
end

function PerformAnalysis()
	CleanDirectory(results_path_base)

	path = joinpath(result_dir, "RAW", "$(raw_prefix)$(clearing_mtu).xlsx")
	df = DataFrame(XLSX.readtable(path, "data"))
	sort!(df, :mtu)

	h = df.mtu .- clearing_mtu .+ 1 # 1 = the executed hour, 36 = the far end of the look-ahead window

	adj_mat = zeros(length(h), length(generators))
	for (j, gen) in enumerate(generators)
		adj_mat[:, j] = df[!, Symbol("$(gen)_adj")]
	end

	p1 = groupedbar(
		adj_mat,
		bar_position = :stack,
		label = reshape(gen_labels, 1, :),
		color = reshape(gen_colors, 1, :),
		xticks = (1:5:length(h), string.(h[1:5:end])),
		xlabel = "Look-ahead step h (h=1 is the hour this auction executes)",
		ylabel = "Adjustment (MW)\n(new plan - previous plan)",
		title = "Rolling 36h - one auction's adjustment vs. the previous plan, clearing at MTU $clearing_mtu",
		titlefontsize = 11,
		legend = :outertop,
		legendcolumns = 5,
		size = (950, 400),
		left_margin = 8Plots.mm,
		bottom_margin = 6Plots.mm,
	)
	hline!(p1, [0], color = :black, linewidth = 1, label = "")

	total_volume_by_gen = [sum(abs.(adj_mat[:, j])) for j in 1:length(generators)]
	p2 = bar(
		1:length(generators),
		total_volume_by_gen,
		xticks = (1:length(generators), gen_labels),
		ylabel = "This auction's contribution\nto Gross Traded Volume (MW)",
		title = "Rolling 36h - sum(|adjustment|) across the whole window, by generator",
		titlefontsize = 10,
		legend = false,
		color = gen_colors,
		size = (950, 350),
		left_margin = 8Plots.mm,
		bottom_margin = 6Plots.mm,
	)

	combined = plot(p1, p2, layout = (2, 1), size = (950, 750))
	savefig(combined, "$results_path_base/single_auction_adjustment_example.png")
	println("saved: $results_path_base/single_auction_adjustment_example.png")

	println("total |adjustment| this auction contributes to Gross Traded Volume, by generator:")
	for (label, v) in zip(gen_labels, total_volume_by_gen)
		println("  $label: ", round(v, digits=1), " MW")
	end
	println("  TOTAL: ", round(sum(total_volume_by_gen), digits=1), " MW")

	return combined
end

end;

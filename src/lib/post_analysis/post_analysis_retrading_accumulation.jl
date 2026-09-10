# Illustrates how the different solver/method permutations retrade and accumulate adjustments
# differently for a fixed set of delivery MTUs, across the sequence of successive auctions that
# touch them - the auction-by-auction mechanism behind the divergence
# post_analysis_price_bucket_comparison.jl shows in aggregate per price bucket.
#
# For a chosen MTU range, gathers every (Clearing MTU, target MTU) adjustment leg from
# transactions.xlsx, sums |adjustment| per Clearing MTU, and plots the CUMULATIVE sum as the
# auction sequence progresses (x = Clearing MTU) - one line per solver/method permutation - plus
# a second panel showing each permutation's cumulative volume minus the HiGHS+simplex baseline,
# since the absolute curves can be nearly indistinguishable when the total spread is small.
#
# Two examples are generated:
#   - MTU 165:170 (a "sometimes-zero" plateau, constant executed price = €50/MWh): permutations
#     diverge early (by clearing MTU ~135-142) and then track EXACTLY PARALLEL to the baseline
#     the rest of the way - once the gap opens, every permutation agrees on all further
#     adjustments. Total spread across permutations is small (~2%).
#   - The longest MTU run that is "always-zero-price" in EVERY permutation, auto-discovered
#     below (capped to a comparable ~6-MTU length): here the gap keeps WIDENING continuously
#     across nearly every single auction in the sequence, never flattening - because at an
#     always-zero MTU, every touching auction re-encounters the same Wind/Solar/storage tie, not
#     just a handful of early speculative ones. Total spread is dramatically larger (~9x between
#     the lowest and highest permutation for the discovered block).

module PostAnalysisRetradingAccumulation

using XLSX, DataFrames, Plots

results_path_base = "results/analysis"

time_range = 12:672
atol = 1e-6

# same 5 rolling-case solver/method permutations as post_analysis_price_bucket_comparison.jl's
# rolling_result_dirs
result_dirs = [
	"HiGHS + simplex" => "results/1789038789_solvercmp_rolling_highs_simplex",
	"HiGHS + IPM" => "results/1789038858_solvercmp_rolling_highs_ipm",
	"Gurobi + simplex" => "results/1789038907_solvercmp_rolling_gurobi_simplex",
	"Gurobi + dual_simplex" => "results/1789038954_solvercmp_rolling_gurobi_dualsimplex",
	"Gurobi + IPM" => "results/1789038992_solvercmp_rolling_gurobi_ipm",
]

generator_agent_names = ["3G_Base", "4G_Shoulder", "5G_Peak", "6G_Wind", "7G_Solar"]
colors = [:dodgerblue, :orangered, :seagreen, :purple, :goldenrod]

clearing_sym = Symbol("Clearing MTU")
mtu_sym = Symbol("Market Time Unit")
price_sym = Symbol("Price (€/MWh)")
quantity_sym = Symbol("Quantity (MWh)")

function CleanDirectory(path)
	mkpath(path)
end

# every target MTU that is always-zero-price (strict unanimity, matching
# post_analysis_price_bucket_comparison.jl's ClassifyMTUsByPrice) for this one permutation's
# transactions.xlsx
function AlwaysZeroMTUs(tx_capped)
	price_lists = Dict{Int,Vector{Float64}}()
	for row in eachrow(tx_capped)
		m = Int(round(row[mtu_sym]))
		push!(get!(price_lists, m, Float64[]), Float64(row[price_sym]))
	end
	return Set(m for (m, ps) in price_lists if all(abs.(ps) .< atol))
end

# the longest contiguous run of MTUs that are always-zero-price in EVERY permutation, capped to
# a comparable length to the 165:170 example
function FindCommonAlwaysZeroBlock(tx_cache, max_length)
	always_zero_sets = Dict{String,Set{Int}}()
	for (label, tx) in tx_cache
		tx_capped = tx[(time_range.start .<= tx[!, clearing_sym] .<= time_range.stop), :]
		always_zero_sets[label] = AlwaysZeroMTUs(tx_capped)
	end
	common = intersect(values(always_zero_sets)...)

	sorted_mtus = sort(collect(common))
	runs = Tuple{Int,Int}[]
	i = 1
	n = length(sorted_mtus)
	while i <= n
		j = i
		while j < n && sorted_mtus[j+1] == sorted_mtus[j] + 1
			j += 1
		end
		push!(runs, (sorted_mtus[i], sorted_mtus[j]))
		i = j + 1
	end
	sort!(runs, by = r -> -(r[2] - r[1]))

	s, e = runs[1]
	if (e - s + 1) > max_length
		e = s + max_length - 1
	end
	return s:e
end

# builds and saves the two-panel (absolute + baseline-relative) accumulated-retrading plot for
# one target MTU range
function PlotAccumulatedRetrading(tx_cache, target_mtus, title_suffix, out_filename)
	s, e = target_mtus.start, target_mtus.stop
	clearing_axis = (s - 35):e # earliest clearing that could reach mtu s (window=36) through e

	p1 = plot(
		ylabel = "Cumulative |adjustment|\nacross MTUs $s:$e (MWh)",
		title = "Rolling 36h - accumulated retrading for MTUs $s:$e ($title_suffix), by solver / method",
		titlefontsize = 10,
		legend = :topleft,
		legendfontsize = 7,
	)
	p2 = plot(
		xlabel = "Clearing MTU (the auction that produced this adjustment)",
		ylabel = "Cumulative |adjustment|\nminus HiGHS+simplex baseline (MWh)",
		titlefontsize = 10,
		legend = false,
	)

	baseline = nothing
	final_totals = Dict{String,Float64}()
	for (i, (label, dir)) in enumerate(result_dirs)
		tx = tx_cache[label]
		sub = tx[in.(tx[!, mtu_sym], Ref(Set(target_mtus))) .& in.(tx.Agent, Ref(Set(generator_agent_names))), :]

		by_clearing = combine(groupby(sub, clearing_sym), quantity_sym => (q -> sum(abs.(q))) => :Volume)
		volume_by_clearing = Dict(row[clearing_sym] => row.Volume for row in eachrow(by_clearing))
		volumes = [get(volume_by_clearing, c, 0.0) for c in clearing_axis]
		cumulative = cumsum(volumes)
		final_totals[label] = cumulative[end]

		if i == 1
			baseline = cumulative
		end

		plot!(p1, clearing_axis, cumulative,
			label = label, color = colors[i], linewidth = 2, marker = :circle, markersize = 2)
		plot!(p2, clearing_axis, cumulative .- baseline,
			label = label, color = colors[i], linewidth = 2, marker = :circle, markersize = 2)
	end

	vline!(p1, [s, e], color = [:black :gray], linestyle = :dash, linewidth = 1, label = "")
	vline!(p2, [s, e], color = [:black :gray], linestyle = :dash, linewidth = 1, label = "")
	hline!(p2, [0], color = :black, linewidth = 1, label = "")

	combined = plot(p1, p2, layout = (2, 1), size = (950, 750), left_margin = 10Plots.mm, bottom_margin = 8Plots.mm)
	savefig(combined, "$results_path_base/$out_filename")
	println("saved: $results_path_base/$out_filename")

	println("final cumulative volume per permutation:")
	for (label, dir) in result_dirs
		println("  $label: ", round(final_totals[label], digits=1), " MWh")
	end

	return combined
end

function PerformAnalysis()
	CleanDirectory(results_path_base)

	tx_cache = Dict{String,DataFrame}()
	for (label, dir) in result_dirs
		tx_cache[label] = DataFrame(XLSX.readtable(joinpath(dir, "transactions.xlsx"), "data"))
	end

	println("=== MTU 165:170 (sometimes-zero plateau, €50/MWh) ===")
	p_sometimes_zero = PlotAccumulatedRetrading(tx_cache, 165:170, "sometimes-zero-price", "mtu_retrading_accumulation_165_170.png")

	println("\n=== discovering the longest common always-zero-price block ===")
	always_zero_block = FindCommonAlwaysZeroBlock(tx_cache, 6)
	println("using block: MTU $(always_zero_block.start):$(always_zero_block.stop)")
	p_always_zero = PlotAccumulatedRetrading(tx_cache, always_zero_block, "always-zero-price", "mtu_retrading_accumulation_always_zero.png")

	return (p_sometimes_zero, p_always_zero)
end

end;

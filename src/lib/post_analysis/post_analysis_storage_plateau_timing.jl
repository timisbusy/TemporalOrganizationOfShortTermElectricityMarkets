# Illustrates one concrete instance of the storage-timing-shuffle theory investigated alongside
# post_analysis_price_bucket_comparison.jl: within a run of consecutive MTUs sharing the same
# executed price, is storage's charge/discharge TIMING solver-dependent even when its plateau
# TOTAL isn't? For MTU 165:170 (rolling case, constant executed price = €50/MWh - one of the
# "sometimes-zero" plateaus, not an always-zero one), per-MTU storage net discharge varies
# wildly across solver/method permutations while the plateau's total net discharge stays within
# ~2.4% across all five - a smaller, but real, analog of the always-zero-bucket degeneracy at a
# genuinely non-zero, non-tied price level.
#
# Checked systematically (not just this one example) across every qualifying constant-price
# plateau in the rolling case: the median ratio of (plateau-total spread) to (mean per-MTU spread
# within that plateau) is ~2.7, and only ~8.5% of plateaus show the "total far more stable than
# individual hours" signature this example happens to show cleanly - so this is a real,
# demonstrable phenomenon, but not the dominant driver of never-zero-bucket variability; most of
# the time the aggregate over a plateau varies across solvers too, not just its timing.

module PostAnalysisStoragePlateauTiming

using XLSX, DataFrames, Plots, StatsPlots

results_path_base = "results/analysis"

# same 5 rolling-case solver/method permutations as post_analysis_price_bucket_comparison.jl's
# rolling_result_dirs
result_dirs = [
	"HiGHS + simplex" => "results/1789038789_solvercmp_rolling_highs_simplex",
	"HiGHS + IPM" => "results/1789038858_solvercmp_rolling_highs_ipm",
	"Gurobi + simplex" => "results/1789038907_solvercmp_rolling_gurobi_simplex",
	"Gurobi + dual_simplex" => "results/1789038954_solvercmp_rolling_gurobi_dualsimplex",
	"Gurobi + IPM" => "results/1789038992_solvercmp_rolling_gurobi_ipm",
]

target_mtus = 165:170 # the illustrative plateau: constant executed price = €50/MWh

function CleanDirectory(path)
	mkpath(path)
end

function PerformAnalysis()
	CleanDirectory(results_path_base)

	data = Dict{String,Vector{Float64}}()
	for (label, dir) in result_dirs
		fd = DataFrame(XLSX.readtable(joinpath(dir, "final_dispatch_decisions.xlsx"), "data"))
		fd = fd[(target_mtus.start .<= fd.mtu .<= target_mtus.stop), :]
		sort!(fd, :mtu)
		data[label] = fd.StorageDischarge .- fd.StorageCharge
	end

	labels = [l for (l, d) in result_dirs]
	mtus = collect(target_mtus)

	mat = zeros(length(mtus), length(labels))
	for (j, label) in enumerate(labels)
		mat[:, j] = data[label]
	end

	p1 = groupedbar(
		mat,
		bar_position = :dodge,
		label = reshape(labels, 1, :),
		xticks = (1:length(mtus), string.(mtus)),
		xlabel = "MTU (delivery hour)",
		ylabel = "Storage Net Discharge (MW)\n(discharge - charge)",
		title = "Rolling 36h - per-MTU storage dispatch, MTU $(target_mtus.start):$(target_mtus.stop) (constant executed price = €50/MWh)",
		titlefontsize = 10,
		legend = :outertop,
		legendcolumns = 3,
		size = (950, 400),
		left_margin = 8Plots.mm,
		bottom_margin = 6Plots.mm,
	)

	totals = [sum(data[label]) for label in labels]
	p2 = bar(
		1:length(labels),
		totals,
		xticks = (1:length(labels), labels),
		xrotation = 20,
		ylabel = "Plateau TOTAL Net Discharge (MW)",
		title = "Rolling 36h - same plateau's TOTAL, per permutation",
		titlefontsize = 10,
		legend = false,
		color = RGB(0.16, 0.47, 0.84),
		size = (950, 350),
		left_margin = 8Plots.mm,
		bottom_margin = 18Plots.mm,
	)

	combined = plot(p1, p2, layout = (2, 1), size = (950, 750))
	savefig(combined, "$results_path_base/storage_plateau_timing_example.png")
	println("saved: $results_path_base/storage_plateau_timing_example.png")

	println("plateau totals per permutation:")
	for (label, t) in zip(labels, totals)
		println("  $label: ", round(t, digits=1), " MW")
	end

	return combined
end

end;

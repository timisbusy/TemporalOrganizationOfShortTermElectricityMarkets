# Solver/method trading-volume comparison for the fixed36/rolling36 validation runs.
#
# Recreates, as native Julia plots, the charts previously published as HTML/JS artifacts
# comparing generator trading volume across every solver/method permutation (HiGHS/Gurobi x
# simplex/ipm/dual_simplex) against Laura's own reference data. Uses the Gross Traded Volume
# definition validated against her economic_summary.xlsx (Clearing MTU capped to 12:672,
# matching calculate_generator_revenues_full in her costs.jl) - see post_analysis_laura_kpis.jl
# and the Clearing-MTU fix in MarketDataStorage.CalculateEconomicIndicators for the full story.
#
# PerformAnalysis writes into its own results/post_analysis/{timestamp}_{label}/solver_comparison/
# directory (see PostAnalysisCommon.NewAnalysisOutputDir), same never-overwritten convention as
# the rest of this suite, rather than the fixed results/analysis/ path this module used to write.
# Pass include_reference=false to drop Laura's own reference data (GrossTradedVolumeForLaura) from
# every table/plot, leaving just our own solver/method permutations.

module PostAnalysisSolverComparison

using XLSX, DataFrames, Plots, StatsPlots, Statistics

include("../post_analysis_common.jl")

# result directories for each solver/method permutation, keyed by config label.
# All Fixed runs are pinned to demand_adjust=false, ex_post_transactions=false so this case is
# on equal footing with Rolling (whose own default is already false/false) - the original Fixed
# dirs used fixed_36's default demand_adjust=true, which is harmless for the HiGHS rows (proven
# exactly 0.000% sensitive to demand_adjust for this case) but shifted the 3 Gurobi rows by a
# real, solver-dependent amount via LP-degeneracy sensitivity - see the demand_adjust/
# ex_post_transactions isolation investigation.
fixed_result_dirs = Dict{String,String}(
	"HiGHS + simplex" => "results/1789119039_fixed_highs_simplex_both_false",
	"HiGHS + IPM" => "results/1789119090_fixed_highs_ipm_both_false",
	"Gurobi + simplex" => "results/1789116424_toggle_fixed_gurobi_simplex_da_false_ept_false",
	"Gurobi + dual_simplex" => "results/1789116515_toggle_fixed_gurobi_dualsimplex_da_false_ept_false",
	"Gurobi + IPM" => "results/1789116611_toggle_fixed_gurobi_ipm_da_false_ept_false",
)

rolling_result_dirs = Dict{String,String}(
	"HiGHS + simplex" => "results/1788873621_laura_noexpost_rolling_highs_simplex",
	"HiGHS + IPM" => "results/1788873807_laura_noexpost_rolling_highs_ipm",
	"Gurobi + simplex" => "results/1788874020_laura_noexpost_rolling_gurobi_simplex",
	"Gurobi + dual_simplex" => "results/1788874132_laura_noexpost_rolling_gurobi_dualsimplex",
	"Gurobi + IPM" => "results/1788873913_laura_noexpost_rolling_gurobi_ipm",
)

laura_data_dir = "../DATA/_laura_data_w_adj"
laura_file_prefix = Dict{String,String}(
	"Fixed" => "decisionvariables_Fixed36h_",
	"Rolling" => "decisionvariables_Rolling36h_",
)

generators = ["Base", "Shoulder", "Peak", "Wind", "Solar"]
generator_agent_names = Dict{String,String}(
	"Base" => "3G_Base", "Shoulder" => "4G_Shoulder", "Peak" => "5G_Peak",
	"Wind" => "6G_Wind", "Solar" => "7G_Solar",
)

time_range = 12:672

const REFERENCE_LABEL = "Reference (HiGHS + default)"

# x-axis ordering: Laura first, then HiGHS variants, then Gurobi variants
category_order = [REFERENCE_LABEL, "HiGHS + simplex", "HiGHS + IPM", "Gurobi + simplex", "Gurobi + dual_simplex", "Gurobi + IPM"]

# category_order with the Laura reference row dropped when include_reference=false - shared by
# every function below that iterates categories, so the "exclude reference" option can't drift
# between the volume table, the ratio table, and either plot.
CategoriesFor(include_reference) = include_reference ? category_order : filter(!=(REFERENCE_LABEL), category_order)

# Fixed + Rolling result dirs merged into one case_paths-shaped dict (prefixed by case so the two
# sets of solver/method labels don't collide) purely for PostAnalysisCommon.NewAnalysisOutputDir's
# metadata.yaml provenance - this module doesn't otherwise have a single case_paths dict the way
# the rest of the suite does, since it compares two independent dicts (Fixed/Rolling) rather than
# one dict keyed by case.
AllResultDirs() = merge(
	Dict("Fixed - $k" => v for (k, v) in fixed_result_dirs),
	Dict("Rolling - $k" => v for (k, v) in rolling_result_dirs),
)

DefaultLabel(include_reference) = include_reference ? "solver_comparison" : "solver_comparison_no_reference"

# Gross Traded Volume for one of our own runs: sum(|adjustment|) across every clearing in
# time_range (by Clearing MTU, not delivery MTU), for every generator - matches Laura's
# calculate_generator_revenues_full, which sums every hour of every clearing's full
# look-ahead window with no cap on the delivery MTU itself.
function GrossTradedVolumeForRun(result_dir)
	tx = DataFrame(XLSX.readtable(joinpath(result_dir, "transactions.xlsx"), "data"))
	tx_capped = tx[(time_range.start .<= tx[!, "Clearing MTU"] .<= time_range.stop), :]

	quantity_symbol = Symbol("Quantity (MWh)")
	volumes = Dict{String,Float64}()
	for gen in generators
		rows = tx_capped[tx_capped.Agent .== generator_agent_names[gen], :]
		volumes[gen] = sum(abs.(rows[!, quantity_symbol]))
	end
	return volumes
end

# Gross Traded Volume for Laura's raw per-clearing reference data: sum(|adjustment|) across
# every row of every clearing file 12:672 - no filtering by delivery mtu, since her own
# calculate_generator_revenues_full loops over every h in every clearing's window.
function GrossTradedVolumeForLaura(case)
	prefix = laura_file_prefix[case]

	volumes = Dict{String,Float64}(gen => 0.0 for gen in generators)
	for mtu_cleared in time_range
		path = joinpath(laura_data_dir, "$(prefix)$(mtu_cleared).xlsx")
		isfile(path) || continue
		df = DataFrame(XLSX.readtable(path, "data"))
		for gen in generators
			volumes[gen] += sum(abs.(df[!, Symbol("$(gen)_adj")]))
		end
	end
	return volumes
end

# Gathers Gross Traded Volume (MWh, full precision) for every category (Laura + each
# solver/method permutation) for one case, as a DataFrame with one row per category and
# one column per generator plus a Total - this is both the plot's source data and what
# gets exported to xlsx.
function TradingVolumeDataFrame(case, result_dirs; include_reference=true)
	println("computing gross traded volume for case: $case")

	all_volumes = Dict{String,Dict{String,Float64}}()

	if include_reference
		println("  loading: Laura (reference)")
		all_volumes[REFERENCE_LABEL] = GrossTradedVolumeForLaura(case)
	end

	for (config_label, dir) in result_dirs
		println("  loading: $config_label ($dir)")
		all_volumes[config_label] = GrossTradedVolumeForRun(dir)
	end

	df = DataFrame(Case = String[], Configuration = String[])
	for gen in generators
		df[!, Symbol(gen)] = Float64[]
	end
	df[!, :Total] = Float64[]

	for cat in CategoriesFor(include_reference)
		volumes = all_volumes[cat]
		row = Any[case, cat]
		for gen in generators
			push!(row, volumes[gen])
		end
		push!(row, sum(values(volumes)))
		push!(df, row)
	end

	return df
end

# Rolling vs Fixed Total Gross Traded Volume, per solver/method category (plus the Laura
# reference row) - both the raw Fixed/Rolling totals, their difference (Rolling - Fixed), and
# their ratio (Rolling/Fixed), so the question "does the rolling/fixed relationship hold
# uniformly, or is it itself solver-sensitive" can be read directly off one column. Per-generator
# ratio columns are included alongside the Total ratio for the same reason - a consistent Total
# ratio could still hide generator-level divergence that only shows up solver-by-solver.
function TradingVolumeRatioDataFrame(fixed_df, rolling_df; include_reference=true)
	pairs = Any["Configuration" => String[], "Fixed Total (MWh)" => Float64[], "Rolling Total (MWh)" => Float64[],
		"Difference (MWh)" => Float64[], "Ratio (Rolling/Fixed)" => Float64[]]
	append!(pairs, ["$gen Ratio (Rolling/Fixed)" => Float64[] for gen in generators])
	df = DataFrame(pairs...)

	for cat in CategoriesFor(include_reference)
		fixed_row = fixed_df[fixed_df.Configuration .== cat, :][1, :]
		rolling_row = rolling_df[rolling_df.Configuration .== cat, :][1, :]

		fixed_total = fixed_row.Total
		rolling_total = rolling_row.Total
		difference = rolling_total - fixed_total
		ratio = fixed_total > 0 ? rolling_total / fixed_total : NaN

		row = Any[cat, fixed_total, rolling_total, difference, ratio]
		for gen in generators
			gsym = Symbol(gen)
			push!(row, fixed_row[gsym] > 0 ? rolling_row[gsym] / fixed_row[gsym] : NaN)
		end
		push!(df, row)
	end

	return df
end

# Bar chart of the Total Ratio (Rolling/Fixed) per solver/method category, with a dashed line at
# the mean ratio across categories - the visual read for "is the ratio consistent across
# variations": bars hugging the line say yes, a wide spread says the fixed/rolling relationship is
# itself solver-dependent.
function PlotTradingVolumeRatio(ratio_df)
	ratios = ratio_df[!, "Ratio (Rolling/Fixed)"]
	mean_ratio = mean(ratios)

	p = bar(
		1:nrow(ratio_df), ratios,
		xticks = (1:nrow(ratio_df), ratio_df.Configuration),
		xrotation = 20,
		ylabel = "Total Trading Volume Ratio (Rolling / Fixed)",
		title = "Rolling vs Fixed 36h trading volume ratio by solver / method",
		label = "Ratio",
		size = (900, 550),
		left_margin = 10Plots.mm,
		bottom_margin = 20Plots.mm,
	)
	hline!(p, [mean_ratio], linestyle = :dash, color = :red, linewidth = 2,
		label = "mean = $(round(mean_ratio, digits=4))", legend = :outertopright)

	return p
end

function PlotTradingVolumeComparison(case, df)
	# groupedbar's :stack draws the first column on top and the last column at the bottom,
	# so feed columns in reverse of the desired bottom-to-top order (Base, Shoulder, Peak,
	# Wind, Solar - matching the 3G/4G/5G/6G/7G generator numbering) to get that stacking.
	stack_order = reverse(generators)

	# matrix layout expected by groupedbar: rows = categories, columns = generators
	data = zeros(nrow(df), length(stack_order))
	for (i, row) in enumerate(eachrow(df))
		for (j, gen) in enumerate(stack_order)
			data[i, j] = row[Symbol(gen)] / 1e6 # MWh -> million MWh
		end
	end

	p = groupedbar(
		data,
		bar_position = :stack,
		label = reshape(stack_order, 1, :),
		xticks = (1:nrow(df), df.Configuration),
		xrotation = 20,
		ylabel = "Gross Traded Volume (million MWh)",
		title = "$case 36h - generator trading volume by solver / method",
		legend = :outertopright,
		size = (900, 550),
		left_margin = 10Plots.mm,
		bottom_margin = 20Plots.mm,
	)

	return p
end

function PerformAnalysis(; include_reference::Bool=true, output_base=PostAnalysisCommon.NewAnalysisOutputDir(AllResultDirs(); label=DefaultLabel(include_reference)))
	analysis_dir_path = "$output_base/solver_comparison"
	PostAnalysisCommon.CleanDirectory(analysis_dir_path)

	fixed_df = TradingVolumeDataFrame("Fixed", fixed_result_dirs; include_reference=include_reference)
	p_fixed = PlotTradingVolumeComparison("Fixed", fixed_df)
	savefig(p_fixed, "$analysis_dir_path/trading_volume_fixed36h.png")
	println("saved: $analysis_dir_path/trading_volume_fixed36h.png")

	rolling_df = TradingVolumeDataFrame("Rolling", rolling_result_dirs; include_reference=include_reference)
	p_rolling = PlotTradingVolumeComparison("Rolling", rolling_df)
	savefig(p_rolling, "$analysis_dir_path/trading_volume_rolling36h.png")
	println("saved: $analysis_dir_path/trading_volume_rolling36h.png")

	combined_df = vcat(fixed_df, rolling_df)
	XLSX.writetable("$analysis_dir_path/trading_volume_details.xlsx", "data" => combined_df; overwrite=true)
	println("saved: $analysis_dir_path/trading_volume_details.xlsx")

	ratio_df = TradingVolumeRatioDataFrame(fixed_df, rolling_df; include_reference=include_reference)
	println(ratio_df)
	ratios = ratio_df[!, "Ratio (Rolling/Fixed)"]
	println("Total ratio (Rolling/Fixed) across solver/method permutations: mean=$(round(mean(ratios), digits=4)), std=$(round(std(ratios), digits=4)), min=$(round(minimum(ratios), digits=4)), max=$(round(maximum(ratios), digits=4))")

	p_ratio = PlotTradingVolumeRatio(ratio_df)
	savefig(p_ratio, "$analysis_dir_path/trading_volume_ratio_rolling_vs_fixed.png")
	println("saved: $analysis_dir_path/trading_volume_ratio_rolling_vs_fixed.png")

	XLSX.writetable("$analysis_dir_path/trading_volume_ratio_rolling_vs_fixed.xlsx", "data" => ratio_df; overwrite=true)
	println("saved: $analysis_dir_path/trading_volume_ratio_rolling_vs_fixed.xlsx")

	return (p_fixed, p_rolling, combined_df, p_ratio, ratio_df, output_base)
end

end;

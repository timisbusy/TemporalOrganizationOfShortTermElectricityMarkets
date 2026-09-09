# Solver/method trading-volume comparison for the fixed36/rolling36 validation runs.
#
# Recreates, as native Julia plots, the charts previously published as HTML/JS artifacts
# comparing generator trading volume across every solver/method permutation (HiGHS/Gurobi x
# simplex/ipm/dual_simplex) against Laura's own reference data. Uses the Gross Traded Volume
# definition validated against her economic_summary.xlsx (Clearing MTU capped to 12:672,
# matching calculate_generator_revenues_full in her costs.jl) - see post_analysis_laura_kpis.jl
# and the Clearing-MTU fix in MarketDataStorage.CalculateEconomicIndicators for the full story.

module PostAnalysisSolverComparison

using XLSX, DataFrames, Plots, StatsPlots

results_path_base = "results/analysis"

# result directories for each solver/method permutation, keyed by config label
fixed_result_dirs = Dict{String,String}(
	"HiGHS + simplex" => "results/1788868302_laura_solar_mtu1_lock_fixed",
	"HiGHS + IPM" => "results/1788869518_laura_solar_mtu1_lock_fixed_highs_ipm",
	"Gurobi + simplex" => "results/1788869144_laura_solar_mtu1_lock_fixed_gurobi_simplex",
	"Gurobi + dual_simplex" => "results/1788869609_laura_solar_mtu1_lock_fixed_gurobi_dualsimplex",
	"Gurobi + IPM" => "results/1788868826_laura_solar_mtu1_lock_fixed_gurobi_ipm",
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

# x-axis ordering: Laura first, then HiGHS variants, then Gurobi variants
category_order = ["Laura (reference)", "HiGHS + simplex", "HiGHS + IPM", "Gurobi + simplex", "Gurobi + dual_simplex", "Gurobi + IPM"]

function CleanDirectory(path)
	mkpath(path)
end

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
function TradingVolumeDataFrame(case, result_dirs)
	println("computing gross traded volume for case: $case")

	all_volumes = Dict{String,Dict{String,Float64}}()

	println("  loading: Laura (reference)")
	all_volumes["Laura (reference)"] = GrossTradedVolumeForLaura(case)

	for (config_label, dir) in result_dirs
		println("  loading: $config_label ($dir)")
		all_volumes[config_label] = GrossTradedVolumeForRun(dir)
	end

	df = DataFrame(Case = String[], Configuration = String[])
	for gen in generators
		df[!, Symbol(gen)] = Float64[]
	end
	df[!, :Total] = Float64[]

	for cat in category_order
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

function PerformAnalysis()
	CleanDirectory(results_path_base)

	fixed_df = TradingVolumeDataFrame("Fixed", fixed_result_dirs)
	p_fixed = PlotTradingVolumeComparison("Fixed", fixed_df)
	savefig(p_fixed, "$results_path_base/trading_volume_fixed36h.png")
	println("saved: $results_path_base/trading_volume_fixed36h.png")

	rolling_df = TradingVolumeDataFrame("Rolling", rolling_result_dirs)
	p_rolling = PlotTradingVolumeComparison("Rolling", rolling_df)
	savefig(p_rolling, "$results_path_base/trading_volume_rolling36h.png")
	println("saved: $results_path_base/trading_volume_rolling36h.png")

	combined_df = vcat(fixed_df, rolling_df)
	XLSX.writetable("$results_path_base/trading_volume_details.xlsx", "data" => combined_df; overwrite=true)
	println("saved: $results_path_base/trading_volume_details.xlsx")

	return (p_fixed, p_rolling, combined_df)
end

end;

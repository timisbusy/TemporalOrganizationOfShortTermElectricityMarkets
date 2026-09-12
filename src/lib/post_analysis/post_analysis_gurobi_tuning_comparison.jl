# Gurobi tuning-knob comparison: does Presolve=0 / Crossover=0 narrow the cross-solver trading
# volume divergence found in post_analysis_solver_comparison.jl?
#
# Background: Wind and Solar are the only two generators that share a bid price (both €0/MWh -
# see validate_laura_agents.yaml), so at every clearing where both have surplus available
# capacity, the welfare-maximizing LP is degenerate between them - any split is equally optimal.
# Gurobi's default settings resolve that tie very differently from HiGHS across every rerun,
# producing 60-170% inflated Gross Traded Volume on Wind/Solar relative to HiGHS+simplex (see
# post_analysis_solver_comparison.jl). Two Gurobi-specific settings directly affect how that tie
# gets resolved:
#   - Presolve=0 disables Gurobi's own problem restructuring before solving - a source of
#     divergence from HiGHS's own presolve that's independent of the LP relaxation itself.
#   - Crossover=0 (barrier/IPM method only) skips pushing the interior-point method's raw
#     interior-of-the-optimal-face solution to an arbitrary vertex, which is otherwise exactly
#     the kind of pivot-rule tie-break that diverges from HiGHS.
#
# Finding: Presolve=0 substantially narrows the Wind/Solar gap under every Gurobi method (roughly
# 3-10x smaller divergence from HiGHS+simplex) and, specifically for Method=0 (simplex), also
# narrows Base/Shoulder/Peak - the only tested variant that improves nearly every generator at
# once. Crossover=0 alone is weaker and less consistent (worsens Base/Shoulder while helping
# Wind/Solar/Peak); combining it with Presolve=0 doesn't clearly beat Presolve=0 alone. None of
# this eliminates the divergence - it's a genuine LP-degeneracy/algorithm-choice effect, not a
# bug - but Method=0 + Presolve=0 is a meaningfully better Gurobi configuration than the default
# if Gurobi has to be used instead of HiGHS.

module PostAnalysisGurobiTuningComparison

using XLSX, DataFrames, Plots, StatsPlots

include("./analysis_output.jl")
using .AnalysisOutput

# result directories per case, keyed by config label. All runs: demand_adjust=false,
# ex_post_transactions=false (matching post_analysis_solver_comparison.jl's baseline), with the
# stored-adjustment rounding from the round-adjustment-precision experiment also active (shown
# separately not to materially affect cross-solver spread, so it's a neutral constant here).
fixed_result_dirs = Dict{String,String}(
	"HiGHS + simplex" => "results/1789192945_rounded_fixed_highs_simplex",
	"HiGHS + IPM" => "results/1789193003_rounded_fixed_highs_ipm",
	"Gurobi + simplex" => "results/1789193041_rounded_fixed_gurobi_simplex",
	"Gurobi + simplex, Presolve=0" => "results/1789198034_fixed_gurobi_simplex_presolve0",
	"Gurobi + dual_simplex" => "results/1789193072_rounded_fixed_gurobi_dualsimplex",
	"Gurobi + dual_simplex, Presolve=0" => "results/1789198060_fixed_gurobi_dualsimplex_presolve0",
	"Gurobi + IPM" => "results/1789193097_rounded_fixed_gurobi_ipm",
	"Gurobi + IPM, Presolve=0" => "results/1789197970_fixed_gurobi_ipm_presolve0",
	"Gurobi + IPM, Crossover=0" => "results/1789197925_fixed_gurobi_ipm_crossover0",
	"Gurobi + IPM, Crossover=0+Presolve=0" => "results/1789197997_fixed_gurobi_ipm_crossover0_presolve0",
)

rolling_result_dirs = Dict{String,String}(
	"HiGHS + simplex" => "results/1789193125_rounded_rolling_highs_simplex",
	"HiGHS + IPM" => "results/1789193161_rounded_rolling_highs_ipm",
	"Gurobi + simplex" => "results/1789193201_rounded_rolling_gurobi_simplex",
	"Gurobi + simplex, Presolve=0" => "results/1789198221_rolling_gurobi_simplex_presolve0",
	"Gurobi + dual_simplex" => "results/1789193232_rounded_rolling_gurobi_dualsimplex",
	"Gurobi + dual_simplex, Presolve=0" => "results/1789198256_rolling_gurobi_dualsimplex_presolve0",
	"Gurobi + IPM" => "results/1789193262_rounded_rolling_gurobi_ipm",
	"Gurobi + IPM, Presolve=0" => "results/1789198126_rolling_gurobi_ipm_presolve0",
	"Gurobi + IPM, Crossover=0" => "results/1789198085_rolling_gurobi_ipm_crossover0",
	"Gurobi + IPM, Crossover=0+Presolve=0" => "results/1789198166_rolling_gurobi_ipm_crossover0_presolve0",
)

generators = ["Base", "Shoulder", "Peak", "Wind", "Solar"]
generator_agent_names = Dict{String,String}(
	"Base" => "3G_Base", "Shoulder" => "4G_Shoulder", "Peak" => "5G_Peak",
	"Wind" => "6G_Wind", "Solar" => "7G_Solar",
)

time_range = 12:672

# x-axis ordering: HiGHS first (the stable reference), then each Gurobi method grouped with its
# own Presolve=0/Crossover=0 variants immediately alongside it
category_order = [
	"HiGHS + simplex", "HiGHS + IPM",
	"Gurobi + simplex", "Gurobi + simplex, Presolve=0",
	"Gurobi + dual_simplex", "Gurobi + dual_simplex, Presolve=0",
	"Gurobi + IPM", "Gurobi + IPM, Presolve=0", "Gurobi + IPM, Crossover=0", "Gurobi + IPM, Crossover=0+Presolve=0",
]

# Gross Traded Volume: sum(|adjustment|) across every clearing in time_range (by Clearing MTU,
# not delivery MTU), for every generator - same definition as post_analysis_solver_comparison.jl.
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

# Gathers Gross Traded Volume (MWh, full precision) for every category for one case, as a
# DataFrame with one row per category and one column per generator plus a Total, plus each
# generator's % difference from the HiGHS + simplex baseline - this is both the plot's source
# data and what gets exported to xlsx.
function TradingVolumeDataFrame(case, result_dirs)
	println("computing gross traded volume for case: $case")

	all_volumes = Dict{String,Dict{String,Float64}}()
	for (config_label, dir) in result_dirs
		println("  loading: $config_label ($dir)")
		all_volumes[config_label] = GrossTradedVolumeForRun(dir)
	end

	baseline = all_volumes["HiGHS + simplex"]

	df = DataFrame(Case = String[], Configuration = String[])
	for gen in generators
		df[!, Symbol(gen)] = Float64[]
	end
	for gen in generators
		df[!, Symbol("$(gen)PctVsBaseline")] = Float64[]
	end
	df[!, :Total] = Float64[]

	for cat in category_order
		volumes = all_volumes[cat]
		row = Any[case, cat]
		for gen in generators
			push!(row, volumes[gen])
		end
		for gen in generators
			b = baseline[gen]
			pct = b == 0 ? NaN : 100 * (volumes[gen] - b) / b
			push!(row, pct)
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
		xrotation = 30,
		xtickfontsize = 7,
		ylabel = "Gross Traded Volume (million MWh)",
		title = "$case 36h - does Presolve=0 / Crossover=0 narrow the Gurobi/HiGHS gap?",
		titlefontsize = 11,
		legend = :outertopright,
		size = (1150, 600),
		left_margin = 10Plots.mm,
		bottom_margin = 30Plots.mm,
	)

	return p
end

function PerformAnalysis()
	output_dir = AnalysisOutput.NewOutputDir("gurobi_tuning_comparison")

	fixed_df = TradingVolumeDataFrame("Fixed", fixed_result_dirs)
	p_fixed = PlotTradingVolumeComparison("Fixed", fixed_df)
	savefig(p_fixed, "$output_dir/gurobi_tuning_comparison_fixed36h.png")
	println("saved: $output_dir/gurobi_tuning_comparison_fixed36h.png")

	rolling_df = TradingVolumeDataFrame("Rolling", rolling_result_dirs)
	p_rolling = PlotTradingVolumeComparison("Rolling", rolling_df)
	savefig(p_rolling, "$output_dir/gurobi_tuning_comparison_rolling36h.png")
	println("saved: $output_dir/gurobi_tuning_comparison_rolling36h.png")

	combined_df = vcat(fixed_df, rolling_df)
	XLSX.writetable("$output_dir/gurobi_tuning_comparison_details.xlsx", "data" => combined_df; overwrite=true)
	println("saved: $output_dir/gurobi_tuning_comparison_details.xlsx")

	sources = merge(
		Dict("Fixed: $k" => v for (k, v) in fixed_result_dirs),
		Dict("Rolling: $k" => v for (k, v) in rolling_result_dirs),
	)
	AnalysisOutput.WriteManifest(output_dir, sources)
	AnalysisOutput.UpdateLatestIndex("gurobi_tuning_comparison", output_dir)

	return (p_fixed, p_rolling, combined_df)
end

end;

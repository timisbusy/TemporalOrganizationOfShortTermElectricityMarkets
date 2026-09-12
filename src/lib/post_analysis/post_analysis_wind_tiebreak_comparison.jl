# Does nudging Wind's bid price 0.01 EUR/MWh above Solar's (breaking their exact zero-price tie)
# narrow the cross-solver Gross Traded Volume divergence found in
# post_analysis_solver_comparison.jl?
#
# Background: Wind and Solar are the only two generators that share a bid price (both €0/MWh -
# see validate_laura_agents.yaml), so at every clearing where both have surplus capacity, the
# welfare-maximizing LP is degenerate between them - any split is equally optimal, and Gurobi's
# default settings resolve that tie very differently from HiGHS across every rerun (see
# post_analysis_solver_comparison.jl and post_analysis_gurobi_tuning_comparison.jl). This module
# tests the most direct fix: eliminate the tie itself, by giving Wind a bid price
# (validate_laura_agents_wind_tiebreak.yaml, bidPrice: 0.01) that's no longer exactly equal to
# Solar's.
#
# Finding: this is the single most effective mitigation tested so far, but it's not free.
#   - Solar's cross-solver divergence nearly vanishes (Fixed, gurobi_ipm vs HiGHS+simplex:
#     +127.0% -> +0.6%) - once Solar is no longer tied with anything, it's uniquely determined by
#     the merit order and every solver agrees.
#   - Wind's own divergence shrinks substantially but doesn't vanish (+68.6% -> +6.8% for the
#     same comparison) - it likely still ties with something else at zero marginal cost (storage
#     charging is the obvious candidate - see the price-bucket module's own notes on this).
#   - Shoulder and Peak did NOT uniformly improve - for gurobi_ipm specifically, Shoulder's
#     cross-solver gap roughly DOUBLED (-32.7% -> -44.5% Fixed, -33.8% -> -40.7% Rolling).
#     Breaking one degenerate tie appears to relocate rather than eliminate the LP's remaining
#     slack.
#   - Unlike the rounding/Presolve/Crossover experiments, this is a genuine change to model input
#     data, not a numerical tweak - every solver's OWN dispatch shifts meaningfully from this
#     price change alone (see the "same-solver effect" table logged by PerformAnalysis), so using
#     it for real would need to be justified as a legitimate modeling assumption, not just a
#     stability hack.

module PostAnalysisWindTiebreakComparison

using XLSX, DataFrames, Plots, StatsPlots, Printf

include("./analysis_output.jl")
using .AnalysisOutput

# result directories per case, keyed by config label. All runs: demand_adjust=false,
# ex_post_transactions=false (matching post_analysis_solver_comparison.jl's baseline). "no
# tie-break" runs also have the stored-adjustment rounding from the round-adjustment-precision
# experiment active (shown separately not to materially affect cross-solver spread, so it's a
# neutral constant here); "with tie-break" runs do not, since that experiment predates this one -
# also shown not to matter much, so the two are still comparable.
fixed_result_dirs = Dict{String,String}(
	"HiGHS + simplex, no tie-break" => "results/1789192945_rounded_fixed_highs_simplex",
	"HiGHS + simplex, tie-break" => "results/1789216471_windtiebreak_fixed_highs_simplex",
	"HiGHS + IPM, no tie-break" => "results/1789193003_rounded_fixed_highs_ipm",
	"HiGHS + IPM, tie-break" => "results/1789216505_windtiebreak_fixed_highs_ipm",
	"Gurobi + simplex, no tie-break" => "results/1789193041_rounded_fixed_gurobi_simplex",
	"Gurobi + simplex, tie-break" => "results/1789216534_windtiebreak_fixed_gurobi_simplex",
	"Gurobi + dual_simplex, no tie-break" => "results/1789193072_rounded_fixed_gurobi_dualsimplex",
	"Gurobi + dual_simplex, tie-break" => "results/1789216560_windtiebreak_fixed_gurobi_dualsimplex",
	"Gurobi + IPM, no tie-break" => "results/1789193097_rounded_fixed_gurobi_ipm",
	"Gurobi + IPM, tie-break" => "results/1789216586_windtiebreak_fixed_gurobi_ipm",
)

rolling_result_dirs = Dict{String,String}(
	"HiGHS + simplex, no tie-break" => "results/1789193125_rounded_rolling_highs_simplex",
	"HiGHS + simplex, tie-break" => "results/1789216614_windtiebreak_rolling_highs_simplex",
	"HiGHS + IPM, no tie-break" => "results/1789193161_rounded_rolling_highs_ipm",
	"HiGHS + IPM, tie-break" => "results/1789216650_windtiebreak_rolling_highs_ipm",
	"Gurobi + simplex, no tie-break" => "results/1789193201_rounded_rolling_gurobi_simplex",
	"Gurobi + simplex, tie-break" => "results/1789216692_windtiebreak_rolling_gurobi_simplex",
	"Gurobi + dual_simplex, no tie-break" => "results/1789193232_rounded_rolling_gurobi_dualsimplex",
	"Gurobi + dual_simplex, tie-break" => "results/1789216730_windtiebreak_rolling_gurobi_dualsimplex",
	"Gurobi + IPM, no tie-break" => "results/1789193262_rounded_rolling_gurobi_ipm",
	"Gurobi + IPM, tie-break" => "results/1789216767_windtiebreak_rolling_gurobi_ipm",
)

generators = ["Base", "Shoulder", "Peak", "Wind", "Solar"]
generator_agent_names = Dict{String,String}(
	"Base" => "3G_Base", "Shoulder" => "4G_Shoulder", "Peak" => "5G_Peak",
	"Wind" => "6G_Wind", "Solar" => "7G_Solar",
)

time_range = 12:672

# x-axis ordering: each solver/method grouped with its own no-tie-break/tie-break pair, so the
# effect of the price nudge is directly comparable bar-to-bar within each pair
category_order = [
	"HiGHS + simplex, no tie-break", "HiGHS + simplex, tie-break",
	"HiGHS + IPM, no tie-break", "HiGHS + IPM, tie-break",
	"Gurobi + simplex, no tie-break", "Gurobi + simplex, tie-break",
	"Gurobi + dual_simplex, no tie-break", "Gurobi + dual_simplex, tie-break",
	"Gurobi + IPM, no tie-break", "Gurobi + IPM, tie-break",
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

function TradingVolumeDataFrame(case, result_dirs)
	println("computing gross traded volume for case: $case")

	all_volumes = Dict{String,Dict{String,Float64}}()
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
	stack_order = reverse(generators)

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
		title = "$case 36h - does breaking the Wind/Solar price tie narrow the cross-solver gap?",
		titlefontsize = 11,
		legend = :outertopright,
		size = (1150, 600),
		left_margin = 10Plots.mm,
		bottom_margin = 30Plots.mm,
	)

	return p
end

# Prints, per solver/method, each generator's % change from the price nudge alone (same solver,
# no-tie-break vs tie-break) - this is a genuine dispatch shift caused by the input data change
# itself, not solver-choice noise, and is logged so it's not mistaken for the cross-solver effect
# the chart shows.
function PrintSameSolverEffect(case, result_dirs)
	println("--- $case: same-solver effect of the price nudge alone ---")
	solvers = ["HiGHS + simplex", "HiGHS + IPM", "Gurobi + simplex", "Gurobi + dual_simplex", "Gurobi + IPM"]
	for solver in solvers
		no_tb = GrossTradedVolumeForRun(result_dirs["$solver, no tie-break"])
		tb = GrossTradedVolumeForRun(result_dirs["$solver, tie-break"])
		println("  $solver:")
		for gen in generators
			pct = no_tb[gen] == 0 ? NaN : 100 * (tb[gen] - no_tb[gen]) / no_tb[gen]
			@printf("    %-10s no_tiebreak=%14.1f  tiebreak=%14.1f  diff%%=%9.3f\n", gen, no_tb[gen], tb[gen], pct)
		end
	end
end

function PerformAnalysis()
	output_dir = AnalysisOutput.NewOutputDir("wind_tiebreak_comparison")

	PrintSameSolverEffect("Fixed", fixed_result_dirs)
	PrintSameSolverEffect("Rolling", rolling_result_dirs)

	fixed_df = TradingVolumeDataFrame("Fixed", fixed_result_dirs)
	p_fixed = PlotTradingVolumeComparison("Fixed", fixed_df)
	savefig(p_fixed, "$output_dir/wind_tiebreak_comparison_fixed36h.png")
	println("saved: $output_dir/wind_tiebreak_comparison_fixed36h.png")

	rolling_df = TradingVolumeDataFrame("Rolling", rolling_result_dirs)
	p_rolling = PlotTradingVolumeComparison("Rolling", rolling_df)
	savefig(p_rolling, "$output_dir/wind_tiebreak_comparison_rolling36h.png")
	println("saved: $output_dir/wind_tiebreak_comparison_rolling36h.png")

	combined_df = vcat(fixed_df, rolling_df)
	XLSX.writetable("$output_dir/wind_tiebreak_comparison_details.xlsx", "data" => combined_df; overwrite=true)
	println("saved: $output_dir/wind_tiebreak_comparison_details.xlsx")

	sources = merge(
		Dict("Fixed: $k" => v for (k, v) in fixed_result_dirs),
		Dict("Rolling: $k" => v for (k, v) in rolling_result_dirs),
	)
	AnalysisOutput.WriteManifest(output_dir, sources;
		notes = "tie-break runs use validate_laura_agents_wind_tiebreak.yaml (Wind bidPrice 0.01); no-tie-break runs use validate_laura_agents.yaml (Wind bidPrice 0)")
	AnalysisOutput.UpdateLatestIndex("wind_tiebreak_comparison", output_dir)

	return (p_fixed, p_rolling, combined_df)
end

end;

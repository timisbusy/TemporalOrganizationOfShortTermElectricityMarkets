# Generation & demand stack of the energy segment only: the post-analysis counterpart of
# PlotGenerationStack.plot (lib/plots/market_results/plot_generation_stack.jl), drawn from each case's
# final_dispatch_decisions_energy.xlsx so it shows what the energy (non-balancing) segment dispatched.
#
# Stacked areas: every generator (agent columns "<n>G_<name>", stacked in agent-number order) plus the storage
# discharge when it is ever above 0.1 MWh; dashed black line: total demand plus storage charging. One chart per
# case, over every MTU in the case's energy dispatch file - i.e. the whole test range, spin-up and tail included
# if the file holds them - unless time_range is given.
#
# Output: $output_base/generation_stack_energy/generation_stack_energy_<case slug>.png

module PostAnalysisEnergyGenerationStack

using Plots, DataFrames

include("../post_analysis_common.jl")

const DISPATCH_FILE = "final_dispatch_decisions_energy.xlsx"
const GENERATOR_COLUMN = r"^[0-9]+G_(?!.*_adj$)"   # "<n>G_<name>" but not its "_adj" companion column
const DEMAND_COLUMN = r"^[0-9]+D_(?!.*_adj$)"
const STORAGE_DISCHARGE_MIN = 0.1 # same threshold as PlotGenerationStack

# categorical slots 1-6 of the dataviz reference palette, in fixed order (generators by agent number, then storage)
const STACK_COLORS = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300", "#6250d6", "#e34948"]
const SURFACE = "#fcfcfb"
const AXIS_COLOR = "#c3c2b7"
const GRID_COLOR = "#e1e0d9"
const TEXT_PRIMARY = "#0b0b0b"
const TEXT_MUTED = "#898781"

AgentNumber(name) = parse(Int, match(r"^[0-9]+", name).match)

function PerformAnalysis(case_paths=PostAnalysisCommon.DEFAULT_CASE_PATHS; cases=PostAnalysisCommon.CASES, output_base=PostAnalysisCommon.NewAnalysisOutputDir(case_paths; label=PostAnalysisCommon.DefaultAnalysisLabel(case_paths, cases)), time_range=nothing)
	println("starting analysis: energy-segment generation stack")
	analysis_dir_path = "$output_base/generation_stack_energy"
	PostAnalysisCommon.CleanDirectory(analysis_dir_path)

	for case in cases
		dispatch = PostAnalysisCommon.LoadCaseFile(case_paths, case, DISPATCH_FILE)
		if time_range !== nothing
			dispatch = dispatch[time_range.start .<= dispatch.mtu .<= time_range.stop, :]
		end
		dispatch = sort(dispatch, :mtu)
		PlotStack(dispatch, case, "$analysis_dir_path/generation_stack_energy_$(PostAnalysisCommon.CaseSlug(case)).png")
	end
end

# Stack rows (label => values, bottom to top) and the demand + charging line for one case's dispatch table.
function StackSeries(dispatch)
	generators = sort(filter(n -> occursin(GENERATOR_COLUMN, n), names(dispatch)); by=AgentNumber)
	demands = filter(n -> occursin(DEMAND_COLUMN, n), names(dispatch))
	isempty(generators) && throw("no generator columns (\"<n>G_<name>\") in the energy dispatch file")
	series = Pair{String,Vector{Float64}}[g => Float64.(dispatch[!, g]) for g in generators]
	discharge = Float64.(dispatch[!, "StorageDischarge"])
	maximum(discharge) > STORAGE_DISCHARGE_MIN && push!(series, "Storage Discharge" => discharge)
	demand_line = sum(Float64.(dispatch[!, d]) for d in demands) .+ Float64.(dispatch[!, "StorageCharge"])
	return series, demand_line
end

function PlotStack(dispatch, case, path)
	series, demand_line = StackSeries(dispatch)
	length(series) <= length(STACK_COLORS) || throw("more than $(length(STACK_COLORS)) stacked series")
	mtus = dispatch.mtu
	top = maximum(max.(demand_line, sum(last.(series))))

	p = Plots.plot(xlabel="MTU", ylabel="Dispatched energy (MWh)", title="Generation & demand stack, energy segment - $case",
					legend=:outerright, yformatter=y -> string(round(Int, y)), xticks=first(mtus):24:last(mtus), ylims=(0, top * 1.08),
					size=(1400, 520), left_margin=16Plots.mm, bottom_margin=10Plots.mm, top_margin=6Plots.mm,
					background_color=SURFACE, foreground_color_axis=AXIS_COLOR, foreground_color_border=AXIS_COLOR,
					foreground_color_text=TEXT_PRIMARY, foreground_color_guide=TEXT_PRIMARY, foreground_color_legend=SURFACE,
					gridcolor=GRID_COLOR, gridalpha=1.0, gridlinewidth=0.5, tickfontcolor=TEXT_MUTED, tickfontsize=10, guidefontsize=11, titlefontsize=12)
	cumulative = zeros(length(mtus))
	for (i, (label, values)) in enumerate(series)
		upper = cumulative .+ values
		Plots.plot!(p, mtus, upper, fillrange=cumulative, label=label, color=STACK_COLORS[i], fillalpha=0.85, linewidth=0)
		cumulative = upper
	end
	Plots.plot!(p, mtus, demand_line, label="Demand + charging", color=TEXT_PRIMARY, linewidth=2, linestyle=:dash)
	display(p)
	savefig(p, path)
end

end;

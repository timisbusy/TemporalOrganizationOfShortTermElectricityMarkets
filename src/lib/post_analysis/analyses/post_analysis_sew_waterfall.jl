# Waterfall of the socioeconomic welfare (SEW) from the energy segment to the total (delivered) SEW, one chart per case:
# the energy-segment SEW (PostAnalysisCommon.CalculateCaseEnergyIndicators), then one step per agent for what the
# balancing trades change in the agent's contribution, ending at the total SEW (CalculateCaseIndicators: energy +
# balancing final dispatch).
#
# SEW = demand utility - production costs, each valued on the final dispatch quantities (quantity x the agent's
# marginal utility / cost), so the balancing trades move it only through the agents' final quantities:
#   - a demand agent's step is its change in load utility (total - energy);
#   - a generator's step is minus its change in fuel cost (total - energy), so a generator dispatching more is a
#     negative step and one dispatching less a positive one.
# Storage has no utility or cost in SEW (its balancing trades act through the other agents' quantities), so it has no
# step of its own. The steps sum exactly to total SEW - energy SEW (checked, see StepsFor).
# Green steps raise SEW, red ones lower it. Since the steps are small next to the SEW itself the y axis is truncated
# (it does not start at zero); the two total bars start at the bottom of the axis.
#
# Writes into {output_base}/sew_waterfall/: sew_waterfall_{case}.png per case and sew_waterfall.xlsx (the steps per case).

module PostAnalysisSEWWaterfall

using XLSX, DataFrames, Plots

include("../post_analysis_common.jl")
include("../agent_renaming.jl")

const SEW = Symbol("Socioeconomic Welfare (€)")
const UTILITY = Symbol("Load Utility (€)")
const COST = Symbol("Fuel Cost (€)")
const AGENT = :Agent
const STORAGE = "Storage"

DisplayName(agent) = AgentRenaming.DisplayName(agent)

# compact signed label: 4.18e8 -> "418.2M" (3 decimals, so the truncated axis' ticks differ), -3.1e6 -> "-3.1M", 2.5e4 -> "25k"
function Compact(v; signed = false)
	a = abs(v)
	s = a >= 1e6 ? string(round(a / 1e6; digits = a >= 1e8 ? 3 : 2), "M") : a >= 1e3 ? string(round(a / 1e3; digits = 1), "k") : string(round(a; digits = 1))
	return (v < 0 ? "-" : signed ? "+" : "") * s
end

# (energy SEW, total SEW, steps) where steps is a DataFrame(Agent, Step (€)) of the agents' SEW contributions
# total - energy, in the agent indicators' order
function StepsFor(case_paths, case, time_range)
	energy = PostAnalysisCommon.CalculateCaseEnergyIndicators(case_paths, case; time_range = time_range)
	total = PostAnalysisCommon.CalculateCaseIndicators(case_paths, case; time_range = time_range)
	energy_sew = Float64(energy.economic_indicators[1, SEW])
	total_sew = Float64(total.economic_indicators[1, SEW])
	steps = DataFrame(Agent = String[], Step = Float64[])
	for agent in energy.agent_indicators[!, AGENT]
		agent == STORAGE && continue
		e = energy.agent_indicators[energy.agent_indicators[!, AGENT] .== agent, :]
		t = total.agent_indicators[total.agent_indicators[!, AGENT] .== agent, :]
		push!(steps, [agent, (Float64(t[1, UTILITY]) - Float64(e[1, UTILITY])) - (Float64(t[1, COST]) - Float64(e[1, COST]))])
	end
	abs(sum(steps.Step) - (total_sew - energy_sew)) <= 1e-6 * max(1.0, abs(total_sew)) ||
		throw("waterfall steps ($(sum(steps.Step))) do not add up to total SEW - energy SEW ($(total_sew - energy_sew)) for $case")
	return energy_sew, total_sew, steps
end

# the agents whose balancing step is not zero (an agent the balancing trades don't move has no step)
ShownSteps(steps) = steps[abs.(steps.Step) .> 1e-6, :]

# (ymin, ymax) shared by the waterfalls of one run (results: (energy_sew, total_sew, steps) per case): covers every level
# of every case, with room above for the labels and a generous gap below the lowest level - the total bars start at the
# bottom of the axis, so the larger the gap the more clearly the axis reads as truncated
function SharedYLimits(results)
	levels = [l for (energy_sew, total_sew, steps) in results for l in [energy_sew; energy_sew .+ cumsum(ShownSteps(steps).Step); total_sew]]
	lo, hi = minimum(levels), maximum(levels)
	range = max(hi - lo, 1.0)
	return lo - 0.6 * range, hi + 0.2 * range
end

function PlotWaterfall(case, energy_sew, total_sew, steps, analysis_dir_path, (ymin, ymax))
	shown = ShownSteps(steps)
	labels = ["Energy SEW"; DisplayName.(shown.Agent); "Total SEW"]
	levels = [energy_sew; energy_sew .+ cumsum(shown.Step)] # SEW after each step; ends at total_sew
	n = length(labels)
	p = Plots.plot(title = "SEW: Energy Segment to Total (Balancing Adjustments), $case", ylabel = "Socioeconomic Welfare (€, axis truncated)",
		xticks = (1:n, labels), xlims = (0.4, n + 0.6), ylims = (ymin, ymax), yformatter = v -> Compact(v), legend = false, size = (1100, 550),
		left_margin = 12Plots.mm, bottom_margin = 8Plots.mm, xrotation = 20, titlefontsize = 11)
	rectangle(x, y0, y1; color) = Plots.plot!(p, Plots.Shape([x - 0.35, x + 0.35, x + 0.35, x - 0.35], [y0, y0, y1, y1]); color = color, linecolor = :black, label = "")
	rectangle(1, ymin, energy_sew; color = :steelblue)
	Plots.annotate!(p, 1, energy_sew + 0.04 * (ymax - ymin), Plots.text(Compact(energy_sew), 9, :black))
	for (i, step) in enumerate(shown.Step)
		before, after = levels[i], levels[i+1]
		rectangle(i + 1, before, after; color = step >= 0 ? :seagreen : :firebrick)
		Plots.plot!(p, [i + 0.35, i + 1 - 0.35], [before, before]; color = :gray, linestyle = :dot, label = "") # connector from the previous bar
		Plots.annotate!(p, i + 1, max(before, after) + 0.04 * (ymax - ymin), Plots.text(Compact(step; signed = true), 9, :black))
	end
	Plots.plot!(p, [n - 0.65, n - 0.35 + 0.0], [levels[end], levels[end]]; color = :gray, linestyle = :dot, label = "")
	rectangle(n, ymin, total_sew; color = :slategray)
	Plots.annotate!(p, n, total_sew + 0.04 * (ymax - ymin), Plots.text(Compact(total_sew), 9, :black))
	PostAnalysisCommon.SaveFigure(p, joinpath(analysis_dir_path, "sew_waterfall_$(replace(case, " " => "_")).png"))
	return p
end

# case_paths/cases: any N cases; one waterfall per case. time_range nothing = the window the runs' own configs define.
function PerformAnalysis(case_paths; cases = PostAnalysisCommon.CASES, output_base = PostAnalysisCommon.NewAnalysisOutputDir(case_paths), time_range = nothing)
	PostAnalysisCommon.SetPlotMark!(case_paths, cases)
	println("starting analysis: SEW waterfall")
	time_range = PostAnalysisCommon.ResolveTimeRange(time_range, case_paths, cases; output_base = output_base)
	analysis_dir_path = "$output_base/sew_waterfall"
	PostAnalysisCommon.CleanDirectory(analysis_dir_path)
	sheets = Pair{String,DataFrame}[]
	results = Dict(case => StepsFor(case_paths, case, time_range) for case in cases)
	ylimits = SharedYLimits(collect(values(results))) # one y range for all the run's waterfalls, so they can be compared
	for case in cases
		energy_sew, total_sew, steps = results[case]
		display(PlotWaterfall(case, energy_sew, total_sew, steps, analysis_dir_path, ylimits))
		table = DataFrame(Item = ["Energy SEW (€)"; DisplayName.(steps.Agent) .* " (€)"; "Total SEW (€)"], Value = [energy_sew; steps.Step; total_sew])
		push!(sheets, case => table)
	end
	XLSX.writetable("$analysis_dir_path/sew_waterfall.xlsx", sheets...; overwrite = true)
	return output_base
end

end;

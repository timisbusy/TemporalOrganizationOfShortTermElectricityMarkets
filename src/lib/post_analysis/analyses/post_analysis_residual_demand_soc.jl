# Residual demand over storage state of charge, two stacked panels on one shared MTU axis over the test range.
#
#   top panel    - residual demand (MW) = demand - variable generation (wind + solar), from the runs' input
#                  profiles exactly as PostAnalysisResidualDemand defines it (negative when wind + solar exceed
#                  demand). It is an input of the experiment, so one line serves every case.
#   bottom panel - storage state of charge (MWh) from each case's final_dispatch_decisions_energy.xlsx, one line
#                  per case (up to 3).
#
# The x axis is the MTU, over the window the runs' own configs define (PostAnalysisCommon.ResolveTimeRange); the
# residual demand is read from the first case's experiment config (the run's Config/ copy), so all cases must
# share the same demand/generation inputs - true for the Fixed/Rolling/window-length comparisons.
#
# Output: $output_base/residual_demand_soc/residual_demand_soc.png and residual_demand_soc.xlsx

module PostAnalysisResidualDemandSOC

using Plots, DataFrames, XLSX

include("../post_analysis_common.jl")
include("./post_analysis_residual_demand.jl")

const DISPATCH_FILE = "final_dispatch_decisions_energy.xlsx"

# categorical slots 1-3 of the dataviz reference palette (blue, orange, aqua); the residual demand line is ink
const LINE_COLORS = ["#2a78d6", "#eb6834", "#1baf7a"]
const SURFACE = "#fcfcfb"
const AXIS_COLOR = "#c3c2b7"
const GRID_COLOR = "#e1e0d9"
const TEXT_PRIMARY = "#0b0b0b"
const TEXT_MUTED = "#898781"

function PerformAnalysis(case_paths=PostAnalysisCommon.DEFAULT_CASE_PATHS; cases=PostAnalysisCommon.CASES, output_base=PostAnalysisCommon.NewAnalysisOutputDir(case_paths; label=PostAnalysisCommon.DefaultAnalysisLabel(case_paths, cases)), time_range=nothing)
	PostAnalysisCommon.SetPlotMark!(case_paths, cases)
	length(cases) <= length(LINE_COLORS) || throw("at most $(length(LINE_COLORS)) cases can be drawn, got $(length(cases))")
	println("starting analysis: residual demand and state of charge")
	time_range = PostAnalysisCommon.ResolveTimeRange(time_range, case_paths, cases; output_base=output_base)
	analysis_dir_path = "$output_base/residual_demand_soc"
	PostAnalysisCommon.CleanDirectory(analysis_dir_path)

	residual = ResidualDemand(case_paths, cases[1], time_range)
	soc = Dict{String,DataFrame}()
	for case in cases
		dispatch = PostAnalysisCommon.LoadCaseFile(case_paths, case, DISPATCH_FILE)
		dispatch = sort(dispatch[time_range.start .<= dispatch.mtu .<= time_range.stop, :], :mtu)
		soc[case] = DataFrame(mtu=dispatch.mtu, soc=Float64.(dispatch.SOC))
	end

	PlotResidualDemandAndSOC(residual, soc, cases, time_range, "$analysis_dir_path/residual_demand_soc.png")
	WriteTable(residual, soc, cases, "$analysis_dir_path/residual_demand_soc.xlsx")
	return (residual=residual, soc=soc)
end

# DataFrame (mtu, ResidualDemand) over time_range, from the case's experiment config. The residual-demand
# series starts at the first hour after the config's spin-up, i.e. at first(time_range) for a default window.
function ResidualDemand(case_paths, case, time_range)
	config_path = PostAnalysisCommon.ExperimentConfigPath(case_paths[case])
	config_path === nothing && throw("$case has no experiment config copy under $(case_paths[case])/Config - cannot derive its residual demand")
	df = PostAnalysisResidualDemand.ResidualDemandForConfig(config_path)
	out = DataFrame(mtu=first(time_range) .+ df.Hour, ResidualDemand=df.ResidualDemand)
	out = out[time_range.start .<= out.mtu .<= time_range.stop, :]
	nrow(out) == length(time_range) || throw("residual demand covers $(nrow(out)) MTUs but the analysis window has $(length(time_range)) - pass a time_range matching the config's analysed hours")
	return out
end

function PlotResidualDemandAndSOC(residual, soc, cases, time_range, path)
	chrome = (background_color=SURFACE, foreground_color_axis=AXIS_COLOR, foreground_color_border=AXIS_COLOR,
		foreground_color_text=TEXT_PRIMARY, foreground_color_guide=TEXT_PRIMARY, foreground_color_legend=SURFACE,
		gridcolor=GRID_COLOR, gridalpha=1.0, gridlinewidth=0.5, tickfontcolor=TEXT_MUTED, tickfontsize=10, guidefontsize=11,
		left_margin=16Plots.mm)
	ticks = first(time_range):24:last(time_range)

	top = Plots.plot(residual.mtu, residual.ResidualDemand; label=false, color=TEXT_PRIMARY, linewidth=2,
		ylabel="Residual demand (MW)", yformatter=y -> string(round(Int, y)), title="Residual demand and storage state of charge", titlefontsize=12,
		xticks=(ticks, fill("", length(ticks))), top_margin=6Plots.mm, chrome...)
	Plots.hline!(top, [0.0]; label=false, color=AXIS_COLOR, linewidth=1)

	multiple = length(cases) > 1
	bottom = Plots.plot(; xlabel="MTU", ylabel="State of charge (MWh)", yformatter=y -> string(round(Int, y)), xticks=ticks, bottom_margin=10Plots.mm,
		legend=multiple ? :topright : false, chrome...)
	for (i, case) in enumerate(cases)
		Plots.plot!(bottom, soc[case].mtu, soc[case].soc; label=case, color=LINE_COLORS[i], linewidth=2)
	end

	p = Plots.plot(top, bottom; layout=Plots.grid(2, 1; heights=[0.5, 0.5]), link=:x, size=(1280, 760), xlims=(first(time_range), last(time_range)), background_color=SURFACE)
	display(p)
	PostAnalysisCommon.SaveFigure(p, path)
end

function WriteTable(residual, soc, cases, path)
	df = copy(residual)
	for case in cases
		df[!, Symbol("SOC $case (MWh)")] = soc[case].soc
	end
	XLSX.writetable(path, "data" => df; overwrite=true)
end

end;

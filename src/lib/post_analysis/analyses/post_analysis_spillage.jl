# Wind and solar spillage of the balancing dispatch: how much of the available wind and solar went undispatched in the LAST
# dispatch of each MTU, i.e. the Segment == Balancing rows of final_dispatch_decisions.xlsx (per MTU, the final
# clearing, in which the MTU was one of the locked balancing MTUs - see balancing_energy/balancing_energy_split.jl).
# Q_6G_Wind / Q_7G_Solar are the model's available-capacity time series for the variable generators (exported via
# helper_model_results.jl's "Q_$agent" column - not the dispatched quantity), so Q_6G_Wind - 6G_Wind is the
# available wind left undispatched in that MTU (likewise for solar), and the metric is its sum over the analysis
# time_range. It is the only spillage this suite reports: the SEW, window-length KPI and monthly tables no
# longer carry it.
#
# Reported per case, for wind and for solar: available, spilled and the spilled share of the available (totals over
# time_range, plus a daily average sheet), with % difference columns - by default "{case} vs {previous case}"
# for each adjacent pair (the window-length suite), or with compare_to_subject=true "{last case} vs {base}" for
# every other case (the fixed vs rolling suite's convention, see PostAnalysisSEW). For two cases the two are the
# same.

module PostAnalysisSpillage

using XLSX, DataFrames, Latexify

include("../post_analysis_common.jl")

# (label, agent) of the variable generators whose spillage is reported
const SOURCES = [("Wind", "6G_Wind"), ("Solar", "7G_Solar")]

available_label(label) = "$label Available (MWh)"
spillage_label(label) = "$label Spillage (MWh)"
share_label(label) = "$label Spillage (% of available)"
const METRICS = vcat([[available_label(l), spillage_label(l), share_label(l)] for (l, _) in SOURCES]...)
const EXTENSIVE_METRICS = filter(m -> !occursin("%", m), METRICS) # totals over time_range, scaled per day in the daily sheet

const BALANCING_SEGMENT = "Balancing"

# the case's balancing dispatch rows within time_range (one per MTU)
function BalancingDispatch(final_dispatch_decisions, time_range)
	hasproperty(final_dispatch_decisions, :Segment) || throw("final dispatch decisions have no \"Segment\" column - this run predates the balancing/energy split; rerun it")
	for (_, agent) in SOURCES
		hasproperty(final_dispatch_decisions, Symbol("Q_$agent")) || throw("final dispatch decisions have no \"Q_$agent\" column - spillage needs the agent \"$agent\"")
	end
	in_range = time_range.start .<= final_dispatch_decisions.mtu .<= time_range.stop
	return final_dispatch_decisions[in_range .& (final_dispatch_decisions.Segment .== BALANCING_SEGMENT), :]
end

# metric => value for one case
function Spillage(final_dispatch_decisions, time_range)
	dd = BalancingDispatch(final_dispatch_decisions, time_range)
	result = Dict{String,Float64}()
	for (label, agent) in SOURCES
		available = Float64(sum(dd[!, Symbol("Q_$agent")]; init=0.0))
		spilled = PostAnalysisCommon.MarketDataStorage.snap0(Float64(sum(dd[!, Symbol("Q_$agent")] .- dd[!, Symbol(agent)]; init=0.0)))
		result[available_label(label)] = available
		result[spillage_label(label)] = spilled
		result[share_label(label)] = available > 0 ? 100 * spilled / available : 0.0
	end
	return result
end

# rows: metric; columns: Indicator, one per case, then the % difference columns. scale multiplies the extensive
# metrics (24 / MTU count for the daily average); the share is a ratio and stays unscaled.
function BuildTable(results_by_case, cases; compare_to_subject=false, scale=1.0)
	comparisons = compare_to_subject ? [(length(cases), i) for i in 1:length(cases)-1] : [(i, i-1) for i in 2:length(cases)]
	pairs = Any["Indicator" => String[]]
	append!(pairs, [case => Float64[] for case in cases])
	append!(pairs, ["$(cases[c]) vs $(cases[b])" => String[] for (c, b) in comparisons])
	df = DataFrame(pairs...)
	for metric in METRICS
		factor = metric in EXTENSIVE_METRICS ? scale : 1.0
		values = [results_by_case[case][metric] * factor for case in cases]
		row = Any[metric in EXTENSIVE_METRICS && scale != 1.0 ? DailyLabel(metric) : metric]
		append!(row, values)
		append!(row, [PostAnalysisCommon.PercentDiffString(values[c], values[b]) for (c, b) in comparisons])
		push!(df, row)
	end
	return df
end

# "Name (MWh)" -> "Name (MWh/day)"
DailyLabel(metric) = replace(metric, r"\(([^()]*)\)$" => s"(\1/day)")

function InterpretationTable()
	interpretations = String[]
	for (label, agent) in SOURCES, kind in 1:3
		push!(interpretations, [
			"Sum of Q_$agent (the available $(lowercase(label))) over the balancing dispatch rows (the last dispatch of each MTU) in the analysis range.",
			"Sum of Q_$agent - $agent over the same rows: the available $(lowercase(label)) left undispatched.",
			"Spilled as a percentage of the available $(lowercase(label)).",
		][kind])
	end
	return DataFrame(Indicator=METRICS, Interpretation=interpretations)
end

# cases is any N case_paths keys; time_range nothing is the window the runs' own configs define
# (see PostAnalysisCommon.ResolveTimeRange)
function PerformAnalysis(case_paths; cases=PostAnalysisCommon.CASES, output_base=PostAnalysisCommon.NewAnalysisOutputDir(case_paths), time_range=nothing, compare_to_subject=false)
	println("starting analysis: wind and solar spillage (balancing)")
	time_range = PostAnalysisCommon.ResolveTimeRange(time_range, case_paths, cases; output_base=output_base)

	analysis_dir_path = "$output_base/spillage"
	PostAnalysisCommon.CleanDirectory(analysis_dir_path)

	results_by_case = Dict(case => Spillage(PostAnalysisCommon.LoadCaseFile(case_paths, case, "final_dispatch_decisions.xlsx"), time_range) for case in cases)
	totals = BuildTable(results_by_case, cases; compare_to_subject=compare_to_subject)
	daily = BuildTable(results_by_case, cases; compare_to_subject=compare_to_subject, scale=24 / length(time_range))
	println(totals)

	XLSX.writetable("$analysis_dir_path/spillage.xlsx", "totals" => totals, "daily_average" => daily, "interpretation" => InterpretationTable(); overwrite=true)
	# the shares keep their decimals; EscapeForLatex has turned "%" into "\%" in the indicator names, so match those
	share_rows = [replace(share_label(label), "%" => "\\%") for (label, _) in SOURCES]
	tex_table = PostAnalysisCommon.FormatIndicatorRowsForLatex(PostAnalysisCommon.EscapeForLatex(totals), share_rows, cases)
	write("$analysis_dir_path/spillage.tex",
		latexify(tex_table; env=:table, booktabs=true, snakecase=true, latex=false, fmt="%'\''d\n"))
	return totals
end

end;

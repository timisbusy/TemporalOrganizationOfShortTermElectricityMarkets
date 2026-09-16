module PostAnalysisPhysicalIndicators

using Plots, DataFrames

include("./post_analysis_common.jl")
include("./post_analysis_daily.jl")

CASES = PostAnalysisCommon.CASES

# raw MTU-level dispatch decisions to compare - SOC and each of the three agents whose adjustments
# matter most for the fixed/rolling comparison (wind forecast error, the moderate-bid demand
# segment, and the shoulder generator that often absorbs the difference)
PHYSICAL_INDICATORS = [Symbol("SOC"), Symbol("6G_Wind"), Symbol("2D_ModerateBid"), Symbol("4G_Shoulder")]

# (column, display label, filename-safe label) for the by-day line/diff-bar charts
INTERVAL_INDICATORS = [
	(symbol=Symbol("Socioeconomic Welfare (€)"), label="Socioeconomic Welfare (€)", file="sew"),
	(symbol=Symbol("Storage Revenue (€)"), label="Storage Revenue (€)", file="storage_revenue"),
	(symbol=Symbol("Imbalance Energy (MWh)"), label="Imbalance Energy (MWh)", file="imbalance_energy"),
]

function PerformAnalysis(case_paths; output_base=PostAnalysisCommon.NewAnalysisOutputDir(case_paths), time_range=PostAnalysisCommon.DEFAULT_TIME_RANGE, imbalance_agents=PostAnalysisCommon.DEFAULT_IMBALANCE_AGENTS)

	# kept short ("physical_indicators", not "post_analysis_physical_indicators") - this nests under
	# an already long {timestamp}_{label} output_base, and Windows' 260-char MAX_PATH doesn't leave
	# much room once a descriptive filename is added on top (see FullRange below, and PlotByDay/
	# PlotDiffByDay's file_label args).
	analysis_dir_path = "$output_base/physical_indicators"

	PostAnalysisCommon.CleanDirectory(analysis_dir_path)

	dispatch_decision_paths = Dict(case => joinpath(case_paths[case], "final_dispatch_decisions.xlsx") for case in CASES)
	dds = PostAnalysisDaily.GetDispatchDecisions(CASES, dispatch_decision_paths)

	for indicator in PHYSICAL_INDICATORS
		PostAnalysisDaily.plotPhysicalIndicator(dds, time_range, indicator, CASES, "FullRange", analysis_dir_path)
	end

	mtu_economic_indicators = Dict{String,DataFrame}()
	for case in CASES
		(economic_indicators, agent_indicators, transactions, finalDispatchDecisions, mtu_ei) = PostAnalysisCommon.CalculateCaseIndicators(case_paths, case; time_range=time_range, imbalance_agents=imbalance_agents)
		PostAnalysisDaily.AddDayAndHour!(mtu_ei, Symbol("MTU"))
		mtu_economic_indicators[case] = mtu_ei
	end

	for ind in INTERVAL_INDICATORS
		daily_values = Dict(case => DailyValue(mtu_economic_indicators, case, ind.symbol) for case in CASES)
		PlotByDay(daily_values, ind.label, ind.symbol, ind.file, analysis_dir_path)
		PlotDiffByDay(daily_values, ind.label, ind.symbol, ind.file, analysis_dir_path; sorted=false)
		PlotDiffByDay(daily_values, ind.label, ind.symbol, ind.file, analysis_dir_path; sorted=true)
	end
end

function DailyValue(mtu_economic_indicators, case, value_symbol)
	daily = groupby(mtu_economic_indicators[case], :Day)
	return combine(daily, value_symbol => sum => value_symbol)
end

function PlotByDay(daily_values, label, value_symbol, file_label, analysis_dir_path)
	p = Plots.plot(xlabel="Day", ylabel=label, title="Comparing $label by day")
	for case in CASES
		Plots.plot!(p, daily_values[case].Day, daily_values[case][!, value_symbol], label=case)
	end
	display(p)
	savefig(p, "$analysis_dir_path/by_day_$(file_label).png")
end

function PlotDiffByDay(daily_values, label, value_symbol, file_label, analysis_dir_path; sorted=false)
	diff_df = PostAnalysisDaily.DiffByDay(daily_values["Rolling Horizon"], daily_values["Fixed Horizon"], value_symbol)
	diffs = diff_df.Diff
	x = diff_df.Day
	if sorted
		diffs = sort(diffs, rev=true)
		x = 1:length(diffs)
	end

	p = Plots.plot(xlabel = sorted ? "Rank" : "Day", ylabel=label,
					title="$label: Rolling Horizon - Fixed Horizon")
	Plots.plot!(p, x, diffs, label="Difference in $label", t=:bar)
	display(p)
	savefig(p, "$analysis_dir_path/diff_by_day_$(sorted ? "sorted_" : "")$(file_label).png")
end

end;

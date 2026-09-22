# Rolling-horizon churn comparison: for the 36h/48h/72h rolling-horizon optimizationWindow
# configs, compares each generator's Gross Traded Volume (sum(|quantity|) across every
# adjustment leg from every clearing that touched a delivered MTU, including the speculative,
# never-delivered tail of each clearing's own look-ahead window - see
# PostAnalysisQuantitiesByAgent.AnalyzeGrossTradedVolume for the same definition) against its
# Delivered Energy Volume (the quantity actually dispatched at delivery), and reports the
# difference as Churn: volume that got traded/re-traded across successive rolling-horizon
# clearings but never became delivered energy. A longer optimizationWindow gives later clearings
# more opportunity to revise earlier commitments, so Churn is expected to grow with the window.
#
# Both figures come straight out of PostAnalysisCommon.CalculateCaseIndicators's agent_indicators
# ("Traded Volume (MWh)" and "Quantity (MWh)" respectively - see AgentEconomicMetrics in
# market_data_storage.jl), scoped to time_range exactly like the rest of this suite, so no
# transactions/final_dispatch_decisions re-filtering is needed here.

module PostAnalysisRollingHorizonChurn

using XLSX, DataFrames, Latexify

include("../post_analysis_common.jl")
include("../agent_renaming.jl")

generator_names = ["3G_Base", "4G_Shoulder", "5G_Peak", "6G_Wind", "7G_Solar"]

quantitySymbol = Symbol("Quantity (MWh)")
tradedVolumeSymbol = Symbol("Traded Volume (MWh)")

const CASES = ["Rolling 36h", "Rolling 48h", "Rolling 72h"]

# latest validated rolling_36/48/72_no_cap_1d_spinup triple - same agent config and D1-D28
# analysis window (MTU 24:695, see PostAnalysisCommon.DEFAULT_TIME_RANGE) despite each config's
# own clearForDays/samplePeriodExcludeEnd being sized differently to give its own optimizationWindow
# enough runway (see each run's Config/*_no_cap_1d_spinup.yaml).
const DEFAULT_CASE_PATHS = Dict{String,String}(
	"Rolling 36h" => "results/1789748169_rolling_36_no_cap_1d_spinup",
	"Rolling 48h" => "results/1789748204_rolling_48_no_cap_1d_spinup",
	"Rolling 72h" => "results/1789748246_rolling_72_no_cap_1d_spinup",
)

# same "{trailing dir name, own leading timestamp stripped}, joined" convention as
# PostAnalysisCommon.DefaultAnalysisLabel, generalized to an arbitrary (not just the hardcoded
# 2-case Fixed/Rolling Horizon) `cases` list, since this module compares three named cases.
function DefaultLabel(case_paths, cases)
	names = [replace(basename(case_paths[c]), r"^\d+_" => "") for c in cases if haskey(case_paths, c)]
	return join(names, "_vs_")
end

function PerformAnalysis(case_paths=DEFAULT_CASE_PATHS; cases=CASES, output_base=PostAnalysisCommon.NewAnalysisOutputDir(case_paths; label=DefaultLabel(case_paths, cases)), time_range=PostAnalysisCommon.DEFAULT_TIME_RANGE)

	analysis_dir_path = "$output_base/rolling_horizon_churn"
	PostAnalysisCommon.CleanDirectory(analysis_dir_path)

	# fresh per-case agent indicators - see PostAnalysisCommon.CalculateCaseIndicators for why this
	# is computed on demand rather than read from a pre-aggregated agent_indicators.xlsx
	agent_indicators_by_case = Dict(case => PostAnalysisCommon.CalculateCaseIndicators(case_paths, case; time_range=time_range).agent_indicators for case in cases)

	df = BuildChurnTable(agent_indicators_by_case, cases)

	WriteComparisonTable(df, "$analysis_dir_path/rolling_horizon_churn.xlsx", "$analysis_dir_path/rolling_horizon_churn.tex")

	totals_df = BuildTotalsTable(df, cases)

	WriteComparisonTable(totals_df, "$analysis_dir_path/rolling_horizon_churn_totals.xlsx", "$analysis_dir_path/rolling_horizon_churn_totals.tex")

	return df, totals_df
end

function ValueForAgent(agent_indicators, agent, symbol)
	return agent_indicators[agent_indicators.Agent .== agent, symbol][1]
end

# one row per generator plus a Total row, grouped by case: {case} Gross Traded Volume (MWh),
# {case} Delivered Energy Volume (MWh), {case} Churn (MWh) - Churn is Gross Traded minus
# Delivered, so the Total row's Churn is consistent whether it's computed from the total columns
# or summed from the per-generator Churn column.
function BuildChurnTable(agent_indicators_by_case, cases)
	columns = ["Agent"]
	for case in cases
		append!(columns, ["$case Gross Traded Volume (MWh)", "$case Delivered Energy Volume (MWh)", "$case Churn (MWh)"])
	end
	df = DataFrame([col => (col == "Agent" ? String[] : Float64[]) for col in columns])

	for agent in generator_names
		row = Any[AgentRenaming.DisplayName(agent)]
		for case in cases
			gross = ValueForAgent(agent_indicators_by_case[case], agent, tradedVolumeSymbol)
			delivered = ValueForAgent(agent_indicators_by_case[case], agent, quantitySymbol)
			append!(row, [gross, delivered, gross - delivered])
		end
		push!(df, row)
	end

	total_row = Any["Total"]
	for case in cases
		gross_total = sum(ValueForAgent(agent_indicators_by_case[case], agent, tradedVolumeSymbol) for agent in generator_names)
		delivered_total = sum(ValueForAgent(agent_indicators_by_case[case], agent, quantitySymbol) for agent in generator_names)
		append!(total_row, [gross_total, delivered_total, gross_total - delivered_total])
	end
	push!(df, total_row)

	return df
end

# transpose of BuildChurnTable's own "Total" row (summed across all generators) - metrics as rows,
# window length as columns, pulled straight from that row rather than re-summed here so the two
# tables can never drift apart.
function BuildTotalsTable(df, cases)
	metric_labels = ["Gross Traded Volume (MWh)", "Delivered Energy Volume (MWh)", "Churn (MWh)"]
	total_row = df[df.Agent .== "Total", :][1, :]

	columns = vcat(["Metric"], cases)
	out = DataFrame([col => (col == "Metric" ? String[] : Float64[]) for col in columns])

	for metric in metric_labels
		row = Any[metric]
		for case in cases
			push!(row, total_row[Symbol("$case $metric")])
		end
		push!(out, row)
	end

	return out
end

function WriteComparisonTable(df, xlsx_path, tex_path)
	println(df)

	XLSX.writetable(xlsx_path, "data" => df; overwrite=true)

	tex = latexify(PostAnalysisCommon.EscapeForLatex(df); env = :table, booktabs = true, snakecase=true, latex=false, fmt="%'\''d\n")
	write(tex_path, tex)
end

end;

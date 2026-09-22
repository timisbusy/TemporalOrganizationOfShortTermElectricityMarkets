# Runs the same optimization-window-length comparison suite as PostAnalysisWindowLengthRunner
# (36h/48h/72h rolling-horizon runs, keyed by window length) but against the high-storage battery
# variant of those three runs (validate_laura_agents_high_storage.yaml - energyCapacity 96000 MWh/
# powerCapacity 4000 MW vs. the regular 6000 MWh/2000 MW) instead of
# PostAnalysisConventionalGenerationCost.DEFAULT_CASE_PATHS' regular-storage runs. Every submodule
# here is generic over its case_paths/cases arguments already, so this only needs its own
# DEFAULT_CASE_PATHS - no submodule changes were needed.

module PostAnalysisHighStorageWindowLengthRunner

include("./post_analysis_common.jl")
include("./analyses/post_analysis_conventional_generation_cost.jl")
include("./analyses/post_analysis_price_by_hour.jl")
include("./analyses/post_analysis_window_length_kpis.jl")
include("./analyses/post_analysis_window_length_storage_kpis.jl")
include("./analyses/post_analysis_window_length_residence_time.jl")
include("./analyses/post_analysis_rolling_horizon_churn.jl")
include("./analyses/post_analysis_wind_forecast_error.jl")

const DEFAULT_CASE_PATHS = Dict{String,String}(
	"36h" => "results/1789748893_rolling_36_no_cap_1d_spinup_high_storage",
	"48h" => "results/1789748945_rolling_48_no_cap_1d_spinup_high_storage",
	"72h" => "results/1789749015_rolling_72_no_cap_1d_spinup_high_storage",
)
const DEFAULT_CASES = ["36h", "48h", "72h"]

DefaultLabel(case_paths, cases) = "high_storage_" * PostAnalysisConventionalGenerationCost.DefaultLabel(case_paths, cases)

function Run(case_paths=DEFAULT_CASE_PATHS; cases=DEFAULT_CASES, label=DefaultLabel(case_paths, cases))
	output_base = PostAnalysisCommon.NewAnalysisOutputDir(case_paths; label=label)

	PostAnalysisConventionalGenerationCost.PerformAnalysis(case_paths; cases=cases, output_base=output_base)
	PostAnalysisPriceByHour.PerformAnalysis(case_paths; cases=cases, output_base=output_base)
	PostAnalysisWindowLengthKPIs.PerformAnalysis(case_paths; cases=cases, output_base=output_base)
	PostAnalysisWindowLengthStorageKPIs.PerformAnalysis(case_paths; cases=cases, output_base=output_base)
	PostAnalysisWindowLengthResidenceTime.PerformAnalysis(case_paths; cases=cases, output_base=output_base)
	PostAnalysisRollingHorizonChurn.PerformAnalysis(case_paths; cases=cases, output_base=output_base)
	PostAnalysisWindForecastError.PerformAnalysis(case_paths; cases=cases, output_base=output_base)

	return output_base
end

end;

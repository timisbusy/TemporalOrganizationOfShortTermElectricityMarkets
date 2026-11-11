# Runs the optimization-window-length comparison suite (36h/48h/72h rolling-horizon runs, keyed by
# window length rather than PostAnalysisRunner's Fixed/Rolling Horizon pair) - currently
# PostAnalysisConventionalGenerationCost, PostAnalysisPriceByHour, PostAnalysisWindowLengthKPIs,
# PostAnalysisStorage (same as the fixed/rolling suite), PostAnalysisWindowLengthResidenceTime,
# PostAnalysisRollingHorizonChurn, PostAnalysisQuantitiesByAgent, PostAnalysisBalancingTradeQuantities, PostAnalysisSpillage, and PostAnalysisWindForecastError, all of which already share
# the same DEFAULT_CASE_PATHS/DEFAULT_CASES/DefaultLabel shape (the latter two default to their own
# separately re-run case_paths - see their own module comments - but are fully generic over
# whatever case_paths/cases this Run call is given, same as every other submodule here). Mirrors
# PostAnalysisRunner.Run: one shared, never-overwritten results/post_analysis/{timestamp}_{label}/
# output directory per Run call, with each submodule writing into its own subdirectory under it.

module PostAnalysisWindowLengthRunner

include("./post_analysis_common.jl")
include("./analyses/post_analysis_conventional_generation_cost.jl")
include("./analyses/post_analysis_price_by_hour.jl")
include("./analyses/post_analysis_window_length_kpis.jl")
include("./analyses/post_analysis_storage.jl")
include("./analyses/post_analysis_window_length_residence_time.jl")
include("./analyses/post_analysis_rolling_horizon_churn.jl")
include("./analyses/post_analysis_quantities_by_agent.jl")
include("./analyses/post_analysis_balancing_trade_quantities.jl")
include("./analyses/post_analysis_spillage.jl")
include("./analyses/post_analysis_wind_forecast_error.jl")

const DEFAULT_CASE_PATHS = PostAnalysisConventionalGenerationCost.DEFAULT_CASE_PATHS
const DEFAULT_CASES = PostAnalysisConventionalGenerationCost.DEFAULT_CASES

function Run(case_paths=DEFAULT_CASE_PATHS; cases=DEFAULT_CASES, label=PostAnalysisConventionalGenerationCost.DefaultLabel(case_paths, cases))
	output_base = PostAnalysisCommon.NewAnalysisOutputDir(case_paths; label=label)

	PostAnalysisConventionalGenerationCost.PerformAnalysis(case_paths; cases=cases, output_base=output_base)
	PostAnalysisPriceByHour.PerformAnalysis(case_paths; cases=cases, output_base=output_base)
	PostAnalysisWindowLengthKPIs.PerformAnalysis(case_paths; cases=cases, output_base=output_base)
	# the same storage metrics as the fixed/rolling suite (per-day charge/discharge/net/throughput + hourly net discharge plots), compared across adjacent window lengths
	PostAnalysisStorage.PerformAnalysis(case_paths; cases=cases, output_base=output_base, compare_to_subject=false)
	PostAnalysisWindowLengthResidenceTime.PerformAnalysis(case_paths; cases=cases, output_base=output_base)
	PostAnalysisRollingHorizonChurn.PerformAnalysis(case_paths; cases=cases, output_base=output_base)
	PostAnalysisQuantitiesByAgent.PerformAnalysis(case_paths; cases=cases, output_base=output_base, compare_to_subject=false)
	PostAnalysisBalancingTradeQuantities.PerformAnalysis(case_paths; cases=cases, output_base=output_base)
	PostAnalysisSpillage.PerformAnalysis(case_paths; cases=cases, output_base=output_base)
	PostAnalysisWindForecastError.PerformAnalysis(case_paths; cases=cases, output_base=output_base)

	return output_base
end

end;

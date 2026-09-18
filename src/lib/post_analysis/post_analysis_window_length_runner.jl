# Runs the optimization-window-length comparison suite (36h/48h/72h rolling-horizon runs, keyed by
# window length rather than PostAnalysisRunner's Fixed/Rolling Horizon pair) - currently
# PostAnalysisConventionalGenerationCost, PostAnalysisPriceByHour, PostAnalysisWindowLengthKPIs,
# PostAnalysisWindowLengthStorageKPIs, and PostAnalysisWindowLengthResidenceTime, all of which
# already share the same DEFAULT_CASE_PATHS/DEFAULT_CASES/DefaultLabel shape. Mirrors
# PostAnalysisRunner.Run: one shared, never-overwritten results/post_analysis/{timestamp}_{label}/
# output directory per Run call, with each submodule writing into its own subdirectory under it.

module PostAnalysisWindowLengthRunner

include("./post_analysis_common.jl")
include("./post_analysis_conventional_generation_cost.jl")
include("./post_analysis_price_by_hour.jl")
include("./post_analysis_window_length_kpis.jl")
include("./post_analysis_window_length_storage_kpis.jl")
include("./post_analysis_window_length_residence_time.jl")

const DEFAULT_CASE_PATHS = PostAnalysisConventionalGenerationCost.DEFAULT_CASE_PATHS
const DEFAULT_CASES = PostAnalysisConventionalGenerationCost.DEFAULT_CASES

function Run(case_paths=DEFAULT_CASE_PATHS; cases=DEFAULT_CASES, label=PostAnalysisConventionalGenerationCost.DefaultLabel(case_paths, cases))
	output_base = PostAnalysisCommon.NewAnalysisOutputDir(case_paths; label=label)

	PostAnalysisConventionalGenerationCost.PerformAnalysis(case_paths; cases=cases, output_base=output_base)
	PostAnalysisPriceByHour.PerformAnalysis(case_paths; cases=cases, output_base=output_base)
	PostAnalysisWindowLengthKPIs.PerformAnalysis(case_paths; cases=cases, output_base=output_base)
	PostAnalysisWindowLengthStorageKPIs.PerformAnalysis(case_paths; cases=cases, output_base=output_base)
	PostAnalysisWindowLengthResidenceTime.PerformAnalysis(case_paths; cases=cases, output_base=output_base)

	return output_base
end

end;

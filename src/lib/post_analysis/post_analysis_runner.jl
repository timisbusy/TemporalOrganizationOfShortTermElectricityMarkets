module PostAnalysisRunner

include("./post_analysis_common.jl")
include("./post_analysis_lead_time.jl")
include("./post_analysis_quantities_by_agent.jl")
include("./post_analysis_SEW.jl")
include("./post_analysis_storage.jl")
include("./post_analysis_prices.jl")
include("./post_analysis_daily.jl")
include("./post_analysis_physical_indicators.jl")

# case_paths maps "Fixed Horizon"/"Rolling Horizon" to each design's own single-design run
# directory (see PostAnalysisCommon.DEFAULT_CASE_PATHS) - defaults to the latest validated
# fixed_36/rolling_36 pair. All six modules write into one shared, never-overwritten
# results/post_analysis/{timestamp}_{label}/ directory for this Run call (see
# PostAnalysisCommon.NewAnalysisOutputDir) - label defaults to one derived from case_paths itself.
function Run(case_paths=PostAnalysisCommon.DEFAULT_CASE_PATHS; label=PostAnalysisCommon.DefaultAnalysisLabel(case_paths))
	output_base = PostAnalysisCommon.NewAnalysisOutputDir(case_paths; label=label)

	PostAnalysisLeadTime.PerformAnalysis(case_paths; output_base=output_base)

	PostAnalysisQuantitiesByAgent.PerformAnalysis(case_paths; output_base=output_base)
	PostAnalysisSEW.PerformAnalysis(case_paths; output_base=output_base)
	PostAnalysisDaily.PerformAnalysis(case_paths; output_base=output_base)
	PostAnalysisPrices.PerformAnalysis(case_paths; output_base=output_base)
	PostAnalysisStorage.PerformAnalysis(case_paths; output_base=output_base)
	PostAnalysisPhysicalIndicators.PerformAnalysis(case_paths; output_base=output_base)

	return output_base
end

end;

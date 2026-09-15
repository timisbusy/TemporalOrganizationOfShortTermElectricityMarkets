module PostAnalysisRunner

include("./post_analysis_common.jl")
include("./post_analysis_lead_time.jl")
include("./post_analysis_quantities_by_agent.jl")
include("./post_analysis_SEW.jl")
include("./post_analysis_storage.jl")
include("./post_analysis_prices.jl")
include("./post_analysis_daily.jl")

# case_paths maps "Fixed Horizon"/"Rolling Horizon" to each design's own single-design run
# directory (see PostAnalysisCommon.DEFAULT_CASE_PATHS) - defaults to the latest validated
# fixed_36/rolling_36 pair.
function Run(case_paths=PostAnalysisCommon.DEFAULT_CASE_PATHS)
	PostAnalysisLeadTime.PerformAnalysis(case_paths)

	PostAnalysisQuantitiesByAgent.PerformAnalysis(case_paths)
	PostAnalysisSEW.PerformAnalysis(case_paths)
	PostAnalysisDaily.PerformAnalysis(case_paths)
	PostAnalysisPrices.PerformAnalysis(case_paths)
	PostAnalysisStorage.PerformAnalysis(case_paths)
end

end;

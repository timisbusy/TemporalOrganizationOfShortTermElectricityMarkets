module PostAnalysisRunner

include("./post_analysis_lead_time.jl")
include("./post_analysis_quantities_by_agent.jl")
include("./post_analysis_SEW.jl")
include("./post_analysis_storage.jl")
include("./post_analysis_prices.jl")
include("./post_analysis_daily.jl")

function Run(results_path_base)
	PostAnalysisLeadTime.PerformAnalysis(results_path_base)
	
	PostAnalysisQuantitiesByAgent.PerformAnalysis(results_path_base)
	PostAnalysisSEW.PerformAnalysis(results_path_base)
	PostAnalysisDaily.PerformAnalysis(results_path_base)
	PostAnalysisPrices.PerformAnalysis(results_path_base)
	PostAnalysisStorage.PerformAnalysis(results_path_base)
end

end;
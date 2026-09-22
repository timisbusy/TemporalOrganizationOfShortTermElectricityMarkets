module PostAnalysisRunner

include("./post_analysis_common.jl")
include("./analyses/post_analysis_lead_time.jl")
include("./analyses/post_analysis_quantities_by_agent.jl")
include("./analyses/post_analysis_SEW.jl")
include("./analyses/post_analysis_storage.jl")
include("./analyses/post_analysis_prices.jl")
include("./analyses/post_analysis_daily.jl")
include("./analyses/post_analysis_physical_indicators.jl")
include("./analyses/post_analysis_auction_snapshots.jl")
include("./analyses/post_analysis_storage_revenue_reconciliation.jl")

# Fixed 36h/Rolling 36h high-storage counterpart of PostAnalysisCommon.DEFAULT_CASE_PATHS - same
# no_cap_1d_spinup runs, re-run with the high-storage agent config. Lets Run's `case_paths` be
# swapped wholesale for a "high-storage" suite invocation.
const HIGH_STORAGE_CASE_PATHS = Dict{String,String}(
	"Fixed Horizon" => "results/1789748824_fixed_36_no_cap_1d_spinup_high_storage",
	"Rolling Horizon" => "results/1789748893_rolling_36_no_cap_1d_spinup_high_storage",
)

# PostAnalysisStorageRevenueReconciliation.DEFAULT_CASE_PATHS spans both storage levels at once (it
# needs a Fixed Horizon case alongside Rolling 36h/48h/72h, which is why it's wired in here rather
# than into PostAnalysisWindowLengthRunner/PostAnalysisHighStorageWindowLengthRunner - those only
# compare rolling-horizon window lengths against each other, with no Fixed Horizon case at all).
# Split here so each Run call's own storage-revenue slice matches the storage level of its other
# analyses instead of redundantly reconciling both levels every time Run is called.
const REGULAR_STORAGE_REVENUE_CASE_PATHS = Dict{String,String}(k => v for (k, v) in PostAnalysisStorageRevenueReconciliation.DEFAULT_CASE_PATHS if !occursin("high storage", k))
const HIGH_STORAGE_STORAGE_REVENUE_CASE_PATHS = Dict{String,String}(k => v for (k, v) in PostAnalysisStorageRevenueReconciliation.DEFAULT_CASE_PATHS if occursin("high storage", k))

# case_paths maps "Fixed Horizon"/"Rolling Horizon" to each design's own single-design run
# directory (see PostAnalysisCommon.DEFAULT_CASE_PATHS) - defaults to the latest validated
# fixed_36/rolling_36 pair. storage_revenue_case_paths defaults to the matching regular-storage
# quadruple for the storage-revenue-reconciliation analysis - pass HIGH_STORAGE_CASE_PATHS/
# HIGH_STORAGE_STORAGE_REVENUE_CASE_PATHS (or your own) for a high-storage suite run instead. All
# modules write into one shared, never-overwritten results/post_analysis/{timestamp}_{label}/
# directory for this Run call (see PostAnalysisCommon.NewAnalysisOutputDir) - label defaults to one
# derived from case_paths itself.
function Run(case_paths=PostAnalysisCommon.DEFAULT_CASE_PATHS; label=PostAnalysisCommon.DefaultAnalysisLabel(case_paths),
	storage_revenue_case_paths=REGULAR_STORAGE_REVENUE_CASE_PATHS)
	output_base = PostAnalysisCommon.NewAnalysisOutputDir(case_paths; label=label)

	PostAnalysisLeadTime.PerformAnalysis(case_paths; output_base=output_base)

	PostAnalysisQuantitiesByAgent.PerformAnalysis(case_paths; output_base=output_base)
	PostAnalysisSEW.PerformAnalysis(case_paths; output_base=output_base)
	PostAnalysisDaily.PerformAnalysis(case_paths; output_base=output_base)
	PostAnalysisPrices.PerformAnalysis(case_paths; output_base=output_base)
	PostAnalysisStorage.PerformAnalysis(case_paths; output_base=output_base)
	PostAnalysisPhysicalIndicators.PerformAnalysis(case_paths; output_base=output_base)
	PostAnalysisAuctionSnapshots.PerformAnalysis(case_paths; output_base=output_base)
	PostAnalysisStorageRevenueReconciliation.PerformAnalysis(storage_revenue_case_paths; output_base=output_base)

	return output_base
end

end;

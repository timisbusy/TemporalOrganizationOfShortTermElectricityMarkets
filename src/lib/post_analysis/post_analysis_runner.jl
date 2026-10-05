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

# High-storage counterpart of THREE_WAY_CASE_PATHS below - same three no_cap_1d_spinup designs,
# re-run with the high-storage agent config (validate_laura_agents_high_storage.yaml via
# auction_only_no_cap_1d_spinup_high_storage.yaml, matching how HIGH_STORAGE_CASE_PATHS' own Fixed/
# Rolling entries were produced). Use with THREE_WAY_CASES for `cases`, same as the regular-storage
# three-way run.
const HIGH_STORAGE_THREE_WAY_CASE_PATHS = Dict{String,String}(
	"Fixed Horizon" => "results/1789748824_fixed_36_no_cap_1d_spinup_high_storage",
	"Rolling Horizon" => "results/1789748893_rolling_36_no_cap_1d_spinup_high_storage",
	"Auction Only" => "results/1790787155_auction_only_no_cap_1d_spinup_high_storage",
)

# Fixed/Rolling/Auction Only - the third, historical "status quo" market design (status_quo.yaml:
# once-daily DayAhead + Intraday1/2/3, no rolling re-clearing) brought back alongside the Fixed/
# Rolling Horizon pair. Rolling Horizon is the design under study throughout this suite: it's
# compared against every other case as its own alternative base case (Fixed Horizon, Auction Only,
# ...) rather than all cases being pooled against one shared baseline - see
# PostAnalysisSEW.PerformAnalysis for the convention (cases[end] is the "subject", every preceding
# case its own "base case") and RollingSubjectCases below for how Run gets `cases` into that shape
# regardless of the order its own `cases` argument was given in. PostAnalysisSEW,
# PostAnalysisQuantitiesByAgent, PostAnalysisStorage, PostAnalysisDaily, PostAnalysisLeadTime, and
# PostAnalysisPhysicalIndicators are wired to RollingSubjectCases(cases) below;
# PostAnalysisAuctionSnapshots produces one independent plot per case with no cross-case comparison
# or ordering to get right, so it's wired to the shared `cases` unchanged.
# PostAnalysisStorageRevenueReconciliation still only knows about "Fixed Horizon"/"Rolling Horizon"
# internally - passing THREE_WAY_CASE_PATHS as `case_paths` without a matching `cases` override
# leaves Auction Only silently absent from that specific table rather than erroring (the extra dict
# key is simply never looked up). PostAnalysisPrices is deliberately excluded even when `cases` is
# overridden - see the comment on its own call in Run for why.
const THREE_WAY_CASE_PATHS = Dict{String,String}(
	"Fixed Horizon" => "results/1789748124_fixed_36_no_cap_1d_spinup",
	"Rolling Horizon" => "results/1789748169_rolling_36_no_cap_1d_spinup",
	"Auction Only" => "results/1790178290_auction_only_no_cap_1d_spinup",
)
const THREE_WAY_CASES = ["Fixed Horizon", "Rolling Horizon", "Auction Only"]

# Moves "Rolling Horizon" to the end of `cases` regardless of where Run's own `cases` list puts it
# (e.g. THREE_WAY_CASES has it in the middle), so it lands there as the "subject" for every module
# using the subject-relative convention (see the comment above); every other case keeps its given
# relative order as the "base cases" it's compared against (e.g. THREE_WAY_CASES ->
# ["Fixed Horizon", "Auction Only", "Rolling Horizon"]). A `cases` with no "Rolling Horizon" entry
# (e.g. a future non-Rolling comparison) is passed through unchanged.
RollingSubjectCases(cases) = "Rolling Horizon" in cases ? [filter(!=("Rolling Horizon"), cases); "Rolling Horizon"] : cases

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
function Run(case_paths=PostAnalysisCommon.DEFAULT_CASE_PATHS; cases=PostAnalysisCommon.CASES, label=PostAnalysisCommon.DefaultAnalysisLabel(case_paths, cases),
	storage_revenue_case_paths=REGULAR_STORAGE_REVENUE_CASE_PATHS)
	output_base = PostAnalysisCommon.NewAnalysisOutputDir(case_paths; label=label)

	PostAnalysisLeadTime.PerformAnalysis(case_paths; cases=RollingSubjectCases(cases), output_base=output_base)

	PostAnalysisQuantitiesByAgent.PerformAnalysis(case_paths; cases=RollingSubjectCases(cases), output_base=output_base)
	PostAnalysisSEW.PerformAnalysis(case_paths; cases=RollingSubjectCases(cases), output_base=output_base)
	PostAnalysisDaily.PerformAnalysis(case_paths; cases=RollingSubjectCases(cases), output_base=output_base)
	# PostAnalysisPrices is deliberately NOT given `cases` here - its "5 evolving forecast vintages
	# for the same delivery period" concept assumes a near-every-MTU clearing cadence (true for
	# Fixed/Rolling) with no meaningful analog for a sparser design like Auction Only (4 clearings/
	# day), so it always runs against its own default 2-case pair regardless of what `cases` this
	# Run call was given.
	PostAnalysisPrices.PerformAnalysis(case_paths; output_base=output_base)
	PostAnalysisStorage.PerformAnalysis(case_paths; cases=RollingSubjectCases(cases), output_base=output_base)
	PostAnalysisPhysicalIndicators.PerformAnalysis(case_paths; cases=RollingSubjectCases(cases), output_base=output_base)
	PostAnalysisAuctionSnapshots.PerformAnalysis(case_paths; cases=cases, output_base=output_base)
	PostAnalysisStorageRevenueReconciliation.PerformAnalysis(storage_revenue_case_paths; output_base=output_base)

	return output_base
end

end;

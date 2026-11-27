module PostAnalysisRunner

using Dates

include("./post_analysis_common.jl")
include("./analyses/post_analysis_lead_time.jl")
include("./analyses/post_analysis_quantities_by_agent.jl")
include("./analyses/post_analysis_SEW.jl")
include("./analyses/post_analysis_balancing_trade_quantities.jl")
include("./analyses/post_analysis_spillage.jl")
include("./analyses/post_analysis_storage.jl")
include("./analyses/post_analysis_prices.jl")
include("./analyses/post_analysis_daily.jl")
include("./analyses/post_analysis_monthly.jl")
include("./analyses/post_analysis_physical_indicators.jl")
include("./analyses/post_analysis_auction_snapshots.jl")

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
# PostAnalysisQuantitiesByAgent, PostAnalysisBalancingTradeQuantities, PostAnalysisSpillage, PostAnalysisStorage, PostAnalysisDaily,
# PostAnalysisLeadTime, and PostAnalysisPhysicalIndicators are wired to RollingSubjectCases(cases) below;
# PostAnalysisAuctionSnapshots produces one independent plot per case with no cross-case comparison
# or ordering to get right, so it's wired to the shared `cases` unchanged.
# PostAnalysisPrices is deliberately excluded even when `cases` is
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

# Run keyword arguments for the full-year 2025 fixed_36/rolling_36 pair (rolling_36_full_year_2025.yaml/
# fixed_36_full_year_2025.yaml: startDate 2024-12-29, so day index 3 = 2025-01-01 and MTU 72 = its first
# hour; analysis window = all of 2025). Use as
#   PostAnalysisRunner.Run(my_case_paths; FullYear2025Window...)
# Highlighted days are 2025-01-15 and 2025-07-15; auction snapshots are day-ahead-aligned clearings
# (MTU % 24 == 12) on those same days.
const FullYear2025Window = (
	time_range = 72:8831,
	day_range = 3:367,
	storage_day_range = 3:367,
	highlight_days = [("Jan 15", 17), ("Jul 15", 17 + 181)],
	illustrative_day = 17,
	clearing_mtus = [17*24 - 12, 17*24 - 11, 17*24 - 10, 198*24 - 12, 198*24 - 11, 198*24 - 10],
	monthly_start_date = Date(2024, 12, 29),
)

# case_paths maps "Fixed Horizon"/"Rolling Horizon" to each design's own single-design run
# directory (see PostAnalysisCommon.DEFAULT_CASE_PATHS) - defaults to the latest validated
# fixed_36/rolling_36 pair - pass HIGH_STORAGE_CASE_PATHS (or your own) for a high-storage suite run
# instead. All modules write into one shared, never-overwritten results/post_analysis/{timestamp}_{label}/
# directory for this Run call (see PostAnalysisCommon.NewAnalysisOutputDir) - label defaults to one
# derived from case_paths itself.
# The window keywords default to nothing: the MTU window is derived from the runs' own configs
# (samplePeriodExcludeSpinUp/End - see PostAnalysisCommon.ResolveTimeRange), and the day ranges from
# that window. Pass them to override - see FullYear2025Window below for the full-year 2025 runs:
#   time_range - MTU analysis window
#   day_range - delivery-day indices for the lead-time analysis (default: the days time_range covers)
#   storage_day_range - the same for the storage analysis
#   highlight_days - (label, day index) pairs PostAnalysisDaily plots hour-by-hour
#   illustrative_day - day PostAnalysisPrices plots price evolution for (nothing = its own default)
#   clearing_mtus - clearings PostAnalysisAuctionSnapshots plots
#   monthly_start_date - the experiment's startDate; when given, also runs PostAnalysisMonthly
#     (month-by-month roll-up) - left as nothing for the 31-day runs, which span a single month
function Run(case_paths=PostAnalysisCommon.DEFAULT_CASE_PATHS; cases=PostAnalysisCommon.CASES, label=PostAnalysisCommon.DefaultAnalysisLabel(case_paths, cases),
	time_range=nothing, day_range=nothing, storage_day_range=nothing, highlight_days=[("May 4", 3), ("May 5", 4)],
	illustrative_day=nothing, clearing_mtus=PostAnalysisAuctionSnapshots.DEFAULT_CLEARING_MTUS, monthly_start_date=nothing)
	output_base = PostAnalysisCommon.NewAnalysisOutputDir(case_paths; label=label)
	time_range = PostAnalysisCommon.ResolveTimeRange(time_range, case_paths, cases; output_base=output_base)
	day_range = day_range === nothing ? PostAnalysisCommon.DayRange(time_range) : day_range
	storage_day_range = storage_day_range === nothing ? PostAnalysisCommon.DayRange(time_range) : storage_day_range

	PostAnalysisLeadTime.PerformAnalysis(case_paths; cases=RollingSubjectCases(cases), output_base=output_base, day_range=day_range)

	PostAnalysisQuantitiesByAgent.PerformAnalysis(case_paths; cases=RollingSubjectCases(cases), output_base=output_base, time_range=time_range)
	PostAnalysisSEW.PerformAnalysis(case_paths; cases=RollingSubjectCases(cases), output_base=output_base, time_range=time_range)
	PostAnalysisBalancingTradeQuantities.PerformAnalysis(case_paths; cases=RollingSubjectCases(cases), output_base=output_base, time_range=time_range, compare_to_subject=true)
	PostAnalysisSpillage.PerformAnalysis(case_paths; cases=RollingSubjectCases(cases), output_base=output_base, time_range=time_range, compare_to_subject=true)
	PostAnalysisDaily.PerformAnalysis(case_paths; cases=RollingSubjectCases(cases), output_base=output_base, time_range=time_range, highlight_days=highlight_days)
	# PostAnalysisPrices is deliberately NOT given `cases` here - its "5 evolving forecast vintages
	# for the same delivery period" concept assumes a near-every-MTU clearing cadence (true for
	# Fixed/Rolling) with no meaningful analog for a sparser design like Auction Only (4 clearings/
	# day), so it always runs against its own default 2-case pair regardless of what `cases` this
	# Run call was given.
	PostAnalysisPrices.PerformAnalysis(case_paths; output_base=output_base, illustrative_day=illustrative_day)
	PostAnalysisStorage.PerformAnalysis(case_paths; cases=RollingSubjectCases(cases), output_base=output_base, day_range=storage_day_range)
	PostAnalysisPhysicalIndicators.PerformAnalysis(case_paths; cases=RollingSubjectCases(cases), output_base=output_base, time_range=time_range)
	PostAnalysisAuctionSnapshots.PerformAnalysis(case_paths; cases=cases, output_base=output_base, clearing_mtus=clearing_mtus)
	if monthly_start_date !== nothing
		PostAnalysisMonthly.PerformAnalysis(case_paths; cases=RollingSubjectCases(cases), output_base=output_base, time_range=time_range, start_date=monthly_start_date)
	end

	return output_base
end

end;

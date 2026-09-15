# Shared conventions for the fixed_36/rolling_36 post-analysis suite: the two cases are each a
# separate single-design run directory (produced by ClearSimple/TestExperiment.RunBasic), not a
# single ClearMarketComparisonForConfig run with case-suffixed files - that's the shape the older
# post-analysis modules (pre-dating post_analysis_laura_kpis.jl) were built for, and it's why they
# don't work unmodified against fixed_36/rolling_36 results. "Auction Only" is deliberately absent
# here: it's a third design those older comparison-run configs included, out of scope for this
# fixed_36/rolling_36 pair.

module PostAnalysisCommon

using XLSX, DataFrames

include("../helpers.jl")
using .Helpers.HelperModelResults

include("../output_data/market_data_storage.jl")

const CASES = ["Fixed Horizon", "Rolling Horizon"]

# latest validated fixed_36/rolling_36 runs - same pair post_analysis_laura_kpis.jl points at.
# Exported after GetFinalDispatchDecisions started carrying FinalAuctionPrice through, so
# CalculateCaseIndicators' RAW backfill is a no-op for these.
const DEFAULT_CASE_PATHS = Dict{String,String}(
	"Fixed Horizon" => "results/1789484690_fresh_validate_fixed_36",
	"Rolling Horizon" => "results/1789484741_fresh_validate_rolling_36",
)

const DEFAULT_AGENT_MAP = Dict{HelperModelResults.AgentTypeEnum,Vector{String}}(
	AGENT_GENERATOR => ["3G_Base", "4G_Shoulder", "5G_Peak", "6G_Wind", "7G_Solar"],
	AGENT_DEMAND => ["1D_HighBid", "2D_ModerateBid"],
)

# D0.5-D28 delivered-MTU window, excluding spin-up/tail clearings - the same range used throughout
# the Laura KPI validation (post_analysis_laura_kpis.jl), so every module in this suite stays
# comparable to the KPI tables and to each other.
const DEFAULT_TIME_RANGE = 12:672

const ANALYSIS_OUTPUT_BASE = "results/validation_results/additional_analysis"

# per-clearing RAW decision-variable export prefix for the default fixed_36/rolling_36 pair -
# filenames are "decisionvariables_<experiment name>_<mtu>.xlsx", so the prefix is tied to each
# run's own experiment name rather than derivable from its directory path.
const DEFAULT_RAW_DISPATCH_PREFIX = Dict{String,String}(
	"Fixed Horizon" => "$(DEFAULT_CASE_PATHS["Fixed Horizon"])/RAW/decisionvariables_validate_laura_fixed_36_",
	"Rolling Horizon" => "$(DEFAULT_CASE_PATHS["Rolling Horizon"])/RAW/decisionvariables_validate_laura_rolling_36_",
)

function CleanDirectory(path)
	mkpath(path)
end

function LoadFile(filepath)
	return DataFrame(XLSX.readtable(filepath, "data"))
end

function LoadCaseFile(case_paths, case, filename)
	return LoadFile(joinpath(case_paths[case], filename))
end

# Fresh per-case economic/agent indicators, computed directly from each case's own
# final_dispatch_decisions.xlsx + transactions.xlsx via MarketDataStorage.CalculateEconomicIndicators
# - there is no pre-aggregated multi-case economic_indicators.xlsx/agent_indicators.xlsx with a
# "Market Configuration" column to filter here (that shape only exists for
# ClearMarketComparisonForConfig runs), so each case's indicators are computed on demand instead.
function CalculateCaseIndicators(case_paths, case; agent_map=DEFAULT_AGENT_MAP, time_range=DEFAULT_TIME_RANGE, raw_dispatch_prefix=DEFAULT_RAW_DISPATCH_PREFIX)
	final_dispatch_decisions = LoadCaseFile(case_paths, case, "final_dispatch_decisions.xlsx")
	transactions = LoadCaseFile(case_paths, case, "transactions.xlsx")
	# older exports predate GetFinalDispatchDecisions carrying FinalAuctionPrice through - backfill
	# it from each MTU's own per-clearing RAW export in that case. A fresh run's export already has
	# the column, so this is skipped entirely for those.
	hasproperty(final_dispatch_decisions, :FinalAuctionPrice) || MarketDataStorage.AddFinalAuctionPriceFromRAW!(final_dispatch_decisions, raw_dispatch_prefix[case])
	return MarketDataStorage.CalculateEconomicIndicators(final_dispatch_decisions, transactions, agent_map, time_range)
end

end;

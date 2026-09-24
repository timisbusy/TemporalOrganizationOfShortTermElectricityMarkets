# Shared conventions for the fixed_36/rolling_36 post-analysis suite: the two cases are each a
# separate single-design run directory (produced by ClearSimple/TestExperiment.RunBasic), not a
# single ClearMarketComparisonForConfig run with case-suffixed files - that's the shape the older
# post-analysis modules (pre-dating post_analysis_laura_kpis.jl) were built for, and it's why they
# don't work unmodified against fixed_36/rolling_36 results. "Auction Only" is deliberately absent
# here: it's a third design those older comparison-run configs included, out of scope for this
# fixed_36/rolling_36 pair.

module PostAnalysisCommon

using XLSX, DataFrames, YAML, Dates, Printf, Statistics

include("../helpers.jl")
using .Helpers.HelperModelResults

include("../output_data/market_data_storage.jl")

const CASES = ["Fixed Horizon", "Rolling Horizon"]

# fixed_36/rolling_36 with lastAuctionMTU removed (clearForDays: 31, so there's room for the
# day-28 price-analysis window - see post_analysis_prices.jl) and a full day of spin-up excluded
# (samplePeriodExcludeSpinUp: 1, not 0 - see DEFAULT_TIME_RANGE below). Exported after
# GetFinalDispatchDecisions started carrying FinalAuctionPrice through, so
# CalculateCaseIndicators' RAW backfill is a no-op for these.
const DEFAULT_CASE_PATHS = Dict{String,String}(
	"Fixed Horizon" => "results/1789572958_fixed_36_no_cap_1d_spinup",
	"Rolling Horizon" => "results/1789572958_rolling_36_no_cap_1d_spinup",
)

const DEFAULT_AGENT_MAP = Dict{HelperModelResults.AgentTypeEnum,Vector{String}}(
	AGENT_GENERATOR => ["3G_Base", "4G_Shoulder", "5G_Peak", "6G_Wind", "7G_Solar"],
	AGENT_DEMAND => ["1D_HighBid", "2D_ModerateBid"],
)

# (variable generator, balancing generator) pair for MarketDataStorage.CounterbalancedImbalance -
# Peak absorbs Wind's forecast-error adjustments in this agent config. Not passed by default (see
# CalculateCaseIndicators) since most callers in this suite don't need imbalance at all.
const DEFAULT_IMBALANCE_AGENTS = ("6G_Wind", "5G_Peak")

# D1-D28 final-auction-MTU window: a clean 28 days, excluding a full day of spin-up at the start and
# the samplePeriodExcludeEnd=2 days of tail clearings at the end (MTU 24*1 to 24*(31-2)-1). This
# used to be 12:672 (D0.5-D28, matching the Laura KPI validation's own comparable_delivery_hours
# range exactly) before samplePeriodExcludeSpinUp moved from 0 to 1 day, so this suite's own
# tables/plots no longer line up 1:1 against post_analysis_laura_kpis.jl's 12:672 window.
const DEFAULT_TIME_RANGE = 24:695

function CleanDirectory(path)
	mkpath(path)
end

# case name -> trailing directory name, own leading "{unix_timestamp}_" stripped (it's already
# redundant with NewAnalysisOutputDir's own timestamp prefix, and every extra character here
# tightens the margin against Windows' 260-char MAX_PATH once a deeply-nested output file name is
# built on top of it), in CASES order, joined - e.g. "fresh_validate_fixed_36_vs_fresh_validate_rolling_36"
function DefaultAnalysisLabel(case_paths)
	names = [replace(basename(case_paths[c]), r"^\d+_" => "") for c in CASES if haskey(case_paths, c)]
	return join(names, "_vs_")
end

# Windows caps a full path at 260 characters (MAX_PATH) unless long-path support has been
# explicitly opted into system-wide, which this repo doesn't rely on. The deepest relative path any
# post-analysis module currently writes under an output_base is
# post_analysis_quantities_by_agent/agent_gross_traded_volume_details.xlsx (~73 chars); this margin
# reserves comfortably more than that so future filenames have room to grow without silently
# reviving this problem.
const WINDOWS_MAX_PATH = 260
const OUTPUT_SUBPATH_MARGIN = 85

# Truncates `label` (at a "_" boundary where possible, for readability) if
# "$base_dir/$timestamp_prefix$label" plus OUTPUT_SUBPATH_MARGIN would exceed WINDOWS_MAX_PATH -
# a label built from long case_paths basenames (e.g. a "high storage" run pair) would otherwise
# only fail once some later module tries to write a file under it, deep inside XLSX.writetable with
# an opaque "No such file or directory". The full, untruncated label is still recorded in
# metadata.yaml for provenance.
function TruncateLabelForPath(label, base_dir, timestamp_prefix)
	budget = WINDOWS_MAX_PATH - length(abspath(base_dir)) - 1 - length(timestamp_prefix) - OUTPUT_SUBPATH_MARGIN
	length(label) <= budget && return label
	budget = max(budget, 10)
	cut = findlast('_', label[1:min(end, budget)])
	truncated = label[1:(cut === nothing ? budget : cut - 1)]
	println("warning: analysis label truncated to fit Windows MAX_PATH: \"$label\" -> \"$truncated\"")
	return truncated
end

# Gives each PostAnalysisRunner.Run call (or a standalone submodule PerformAnalysis) its own
# permanent, never-overwritten output directory under results/post_analysis/, the same
# {timestamp}_{name} convention TestExperiment.RunBasic uses for simulation runs - the suite used
# to always write into one fixed, silently-overwritten location regardless of which case_paths
# were actually analyzed. Also drops a metadata.yaml recording what was analyzed, the same
# provenance role ClearMarket.CopyConfigFiles! plays for a simulation run's own Config/ copy.
function NewAnalysisOutputDir(case_paths; label=DefaultAnalysisLabel(case_paths))
	base_dir = "results/post_analysis"
	timestamp_prefix = "$(round(Int, datetime2unix(now())))_"
	label = TruncateLabelForPath(label, base_dir, timestamp_prefix)
	dir = "$base_dir/$timestamp_prefix$label"
	mkpath(dir)
	YAML.write_file(joinpath(dir, "metadata.yaml"), Dict(
		"label" => label,
		"generated_at" => string(now()),
		"case_paths" => case_paths,
	))
	return dir
end

# Per-clearing RAW decision-variable exports are named "decisionvariables_<experiment
# name>_<mtu>.xlsx" - the experiment name is whatever the run's own config[:name] was, not
# derivable from the run directory's own (possibly unrelated) name, so discover it by reading one
# filename out of the case's RAW/ directory instead of requiring every caller to know/hardcode it.
function DiscoverRawDispatchPrefix(case_path)
	raw_dir = joinpath(case_path, "RAW")
	for f in readdir(raw_dir)
		m = match(r"^decisionvariables_(.+)_(\d+)\.xlsx$", f)
		m === nothing && continue
		return joinpath(raw_dir, "decisionvariables_$(m.captures[1])_")
	end
	throw("no decisionvariables_*.xlsx files found in $raw_dir")
end

function DiscoverRawDispatchPrefixes(case_paths)
	return Dict(case => DiscoverRawDispatchPrefix(path) for (case, path) in case_paths)
end

# latexify passes column headers and string cell values straight through unescaped - a bare "%"
# starts a LaTeX comment, silently truncating that line (and anything after it in the table). Call
# this on the copy of a DataFrame that's about to be handed to latexify() for a .tex export - it
# escapes "%" -> "\%" in every column name and every String-typed column's values. Not needed for
# xlsx output, which wants the plain "%".
function EscapeForLatex(df)
	escaped = rename(df, [name => replace(name, "%" => "\\%") for name in names(df)])
	for col in names(escaped)
		if eltype(escaped[!, col]) <: AbstractString
			escaped[!, col] = replace.(escaped[!, col], "%" => "\\%")
		end
	end
	return escaped
end

# Some tables in this suite latexify with a single table-wide integer fmt (e.g. "%'d", thousands-
# separated - suits big €/€-per-day totals) that would truncate a smaller-magnitude intensive
# indicator row (a €/MWh price, say) to a bare integer, since Latexify's PrintfNumberFormatter
# applies the same fmt to every Number cell with no per-row override (latextabular.jl:
# `x isa Number ? formatter(x) : x`). Since a non-Number cell passes through untouched, this
# pre-formats just the named row's case-value cells as "%.2f" strings on a copy - never the
# original df - sidestepping the shared fmt for that row without touching any other row's display.
function FormatIndicatorRowForLatex(df, indicator, case_columns)
	out = copy(df)
	row_idx = findfirst(==(indicator), out.Indicator)
	row_idx === nothing && return out
	for col in case_columns
		out[!, col] = Vector{Any}(out[!, col])
		out[row_idx, col] = Printf.@sprintf("%.2f", df[row_idx, col])
	end
	return out
end

# FormatIndicatorRowForLatex for several indicator rows at once, folding the copy-and-reformat over
# each in turn.
function FormatIndicatorRowsForLatex(df, indicators, case_columns)
	out = df
	for indicator in indicators
		out = FormatIndicatorRowForLatex(out, indicator, case_columns)
	end
	return out
end

# Rounds the named row's case-value cells to `digits` places, in place - for a daily-average
# indicator whose raw division rarely lands on a clean number (e.g. Imbalance Energy (MWh)/days).
# Complements FormatIndicatorRowForLatex, which only fixes the LaTeX-only truncation problem for a
# row like this; this actually changes the stored value, so console/xlsx output round the same way.
function RoundIndicatorRow!(df, indicator, case_columns; digits=2)
	row_idx = findfirst(==(indicator), df.Indicator)
	row_idx === nothing && return df
	for col in case_columns
		df[row_idx, col] = round(df[row_idx, col]; digits=digits)
	end
	return df
end

const PERCENT_FORMAT = Ref(Printf.Format("%0.3f%%"))

# "rolling vs fixed" percent-difference string, formatted like "12.345%" - or "—" when fixed is
# zero, since dividing by it gives NaN/Inf rather than a meaningful percentage (Printf happily
# renders those as the literal strings "NaN%"/"Inf%", which is worse than just saying there's no
# ratio to report).
function PercentDiffString(rolling, fixed)
	fixed == 0 && return "—"
	return Printf.format(PERCENT_FORMAT[], 100*(rolling - fixed)/fixed)
end

function LoadFile(filepath)
	return DataFrame(XLSX.readtable(filepath, "data"))
end

function LoadCaseFile(case_paths, case, filename)
	return LoadFile(joinpath(case_paths[case], filename))
end

# shared by PostAnalysisSEW and PostAnalysisWindowLengthKPIs so their two copies can't drift apart
# the way PostAnalysisConventionalGenerationCost/PriceByHour's own case_paths defaults once did.
const MEAN_FINAL_AUCTION_PRICE_INDICATOR = "Mean Final Auction Price (€/MWh)"

# Mean Final Auction Price (€/MWh) over time_range for one case - rounded to the hundredths place,
# since it's a price meant to read like one, not a many-significant-figure aggregate like the
# totals it's usually reported alongside.
function LoadMeanFinalAuctionPrice(case_path, time_range)
	dd = LoadFile(joinpath(case_path, "final_dispatch_decisions.xlsx"))
	dd = dd[time_range.start .<= dd.mtu .<= time_range.stop, :]
	return round(mean(dd.FinalAuctionPrice); digits=2)
end

const WIND_CURTAILED_INDICATOR = "Wind Curtailed (MWh)"

# Wind Curtailment over time_range for one case, matching Laura's "Total Wind Curtailed (MWh)"
# (see post_analysis_laura_kpis.jl): Q_6G_Wind is the model's available-capacity time series for
# wind (m.ext[:timeseries][:Q_gen], exported via helper_model_results.jl's "Q_$agent" column - NOT
# the dispatched quantity), so Q_6G_Wind - 6G_Wind is exactly how much available wind went
# undispatched each MTU. `final_dispatch_decisions` should already be scoped to time_range (e.g.
# CalculateCaseIndicators' own return value) so this is just the sum, not a re-filter.
function WindCurtailed(final_dispatch_decisions)
	return sum(final_dispatch_decisions[!, Symbol("Q_6G_Wind")] .- final_dispatch_decisions[!, Symbol("6G_Wind")])
end

# Fresh per-case economic/agent indicators, computed directly from each case's own
# final_dispatch_decisions.xlsx + transactions.xlsx via MarketDataStorage.CalculateEconomicIndicators
# - there is no pre-aggregated multi-case economic_indicators.xlsx/agent_indicators.xlsx with a
# "Market Configuration" column to filter here (that shape only exists for
# ClearMarketComparisonForConfig runs), so each case's indicators are computed on demand instead.
function CalculateCaseIndicators(case_paths, case; agent_map=DEFAULT_AGENT_MAP, time_range=DEFAULT_TIME_RANGE, raw_dispatch_prefix=nothing, imbalance_agents::Union{Nothing,Tuple{String,String}}=nothing)
	final_dispatch_decisions = LoadCaseFile(case_paths, case, "final_dispatch_decisions.xlsx")
	transactions = LoadCaseFile(case_paths, case, "transactions.xlsx")
	# older exports predate GetFinalDispatchDecisions carrying FinalAuctionPrice through - backfill
	# it from each MTU's own per-clearing RAW export in that case, discovering the prefix from the
	# RAW/ directory itself unless the caller supplied one. A fresh run's export already has the
	# column, so this (and the discovery) is skipped entirely for those.
	if !hasproperty(final_dispatch_decisions, :FinalAuctionPrice)
		prefix = raw_dispatch_prefix === nothing ? DiscoverRawDispatchPrefix(case_paths[case]) : raw_dispatch_prefix[case]
		MarketDataStorage.AddFinalAuctionPriceFromRAW!(final_dispatch_decisions, prefix)
	end
	return MarketDataStorage.CalculateEconomicIndicators(final_dispatch_decisions, transactions, agent_map, time_range; imbalance_agents=imbalance_agents)
end

end;

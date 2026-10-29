# Per-MTU comparison of the wind generator's bids and contracted quantities between the Fixed and
# Rolling Horizon designs: for every final-auction MTU in time_range, the wind bid quantity and
# contracted quantity in the final auction (the clearing whose own TimeCleared equals the MTU - the
# one GetFinalDispatchDecisions keeps), the same two quantities as of the previous auction that
# covered that MTU, and the adjustment quantity the final auction made on top of the previous
# contracted quantity. Each is reported for Fixed, Rolling, and Rolling minus Fixed.
#
# Everything is read straight from the per-clearing RAW decisionvariables_* exports rather than
# final_dispatch_decisions.xlsx, since the previous auction's values only exist there:
#   Q_{wind}     - bid quantity (the noisy wind forecast offered into that clearing)
#   {wind}       - contracted quantity after that clearing (cumulative across clearings)
#   {wind}_adj   - that clearing's adjustment to the previously contracted quantity
# "Previous auction" for an MTU is the latest clearing before the final one whose window still
# included that MTU - clearing MTU-1 for both designs in the 36h configs, but searched for rather
# than assumed so a design with a gap between clearings still resolves correctly.

module PostAnalysisWindBidComparison

using XLSX, DataFrames, Statistics

include("../post_analysis_common.jl")
include("../agent_renaming.jl")

const CASES = ["Fixed Horizon", "Rolling Horizon"]

# latest fixed_36/rolling_36_no_cap_1d_spinup pair (model: latest, D1-D28 analysis window)
const DEFAULT_CASE_PATHS = Dict{String,String}(
	"Fixed Horizon" => "results/1792504918_fixed_36_no_cap_1d_spinup",
	"Rolling Horizon" => "results/1792504983_rolling_36_no_cap_1d_spinup",
)

const DEFAULT_WIND_AGENT = "6G_Wind"

# how many clearings back to look for a previous auction that still covered an MTU - comfortably
# more than the longest optimizationWindow in the suite (72)
const MAX_PREVIOUS_LOOKBACK = 96

const METRICS = [
	"Final Bid Quantity (MWh)",
	"Previous Auction Bid Quantity (MWh)",
	"Final Contracted Quantity (MWh)",
	"Previous Auction Contracted Quantity (MWh)",
	"Final Auction Adjustment Quantity (MWh)",
	"Final Auction SOC (MWh)",
	"Previous Auction SOC (MWh)",
	"Final Auction Price (€/MWh)",
]

# (RAW decision-variable column, display label) for every agent whose last-auction adjustment is
# tabulated, in column order: demands, storage, then peak/wind/solar, then the remaining dispatchable
# generators. Each adjustment is the final auction's value minus the previous auction's value for the
# same MTU. That is computed from the dispatch columns themselves rather than read from "{agent}_adj":
# with demand_adjust: false the demand "_adj" variables are unconstrained and always report 0 (see the
# note in HelperModelResults.Transactions), and storage has no "_adj" column at all - its adjustment
# is the change in its charge and discharge plans. For generators this equals "{agent}_adj".
const ADJUSTMENT_AGENTS = [
	("1D_HighBid", "$(AgentRenaming.DisplayName("1D_HighBid")) Demand"),
	("2D_ModerateBid", "$(AgentRenaming.DisplayName("2D_ModerateBid")) Demand"),
	("StorageCharge", "Storage Charge"),
	("StorageDischarge", "Storage Discharge"),
	("5G_Peak", AgentRenaming.DisplayName("5G_Peak")),
	("6G_Wind", AgentRenaming.DisplayName("6G_Wind")),
	("7G_Solar", AgentRenaming.DisplayName("7G_Solar")),
	("3G_Base", AgentRenaming.DisplayName("3G_Base")),
	("4G_Shoulder", AgentRenaming.DisplayName("4G_Shoulder")),
]

# Differences of two LP solutions carry solver noise (~1e-12 MWh, e.g. on generators that never really
# move) - anything below this is reported as 0 so "MTUs adjusted" counts real adjustments only
const ADJUSTMENT_NOISE_TOLERANCE = 1e-6
SnapNoise(x) = abs(x) < ADJUSTMENT_NOISE_TOLERANCE ? 0.0 : x

AdjustmentMetric(label) = "$label Adjustment (MWh)"
const ADJUSTMENT_METRICS = [AdjustmentMetric(label) for (_, label) in ADJUSTMENT_AGENTS]

# the market clearing price of each MTU's final auction (the settlement price), as in METRICS
const PRICE_METRIC = "Final Auction Price (€/MWh)"

# adjustment quantity x that design's own final auction price, per agent, per MTU. Positive means more
# energy bought (demand, storage charge) or sold (generators, storage discharge) at the final price.
AdjustmentValueMetric(label) = "$label Adjustment Value (€)"
const ADJUSTMENT_VALUE_METRICS = [AdjustmentValueMetric(label) for (_, label) in ADJUSTMENT_AGENTS]

# "Wind availability" for an MTU is the wind bid quantity, so its change is the forecast revision
# between the previous auction and the final auction: an Increase when the final bid is above the
# previous auction's bid, a Decrease when below. The adjustments table marks each MTU with it, and
# the by_wind_direction summary compares agent adjustments across the two segments.
const WIND_DIRECTIONS = ["Increase", "Decrease"]

const SUMMARY_STATS = [
	"Mean Adjustment (MWh)" => v -> isempty(v) ? missing : mean(v),
	"Total Adjustment (MWh)" => v -> sum(v),
	"Total Absolute Adjustment (MWh)" => v -> sum(abs, v),
	"MTUs Adjusted" => v -> Float64(count(!iszero, v)),
	"MTUs Adjusted Up" => v -> Float64(count(>(0), v)),
	"MTUs Adjusted Down" => v -> Float64(count(<(0), v)),
]

WindAvailabilityChange(wind_table) = wind_table[!, "Final Bid Quantity (MWh)"] .- wind_table[!, "Previous Auction Bid Quantity (MWh)"]

WindDirection(change) = [ismissing(c) ? "No previous auction" : c > 0 ? "Increase" : c < 0 ? "Decrease" : "No change" for c in change]

function PerformAnalysis(case_paths=DEFAULT_CASE_PATHS; cases=CASES, wind_agent=DEFAULT_WIND_AGENT, output_base=PostAnalysisCommon.NewAnalysisOutputDir(case_paths; label=PostAnalysisCommon.DefaultAnalysisLabel(case_paths, cases)), time_range=nothing)

	analysis_dir_path = "$output_base/wind_bid_comparison"
	PostAnalysisCommon.CleanDirectory(analysis_dir_path)

	# nothing: the window the runs' own configs define (see PostAnalysisCommon.ResolveTimeRange)
	time_range = PostAnalysisCommon.ResolveTimeRange(time_range, case_paths, cases; output_base=output_base)

	case_tables = Dict(case => BuildCaseTables(case_paths[case], time_range, wind_agent) for case in cases)

	wind_tables = Dict(case => case_tables[case].wind for case in cases)
	df = BuildComparisonTable(wind_tables, cases, METRICS)

	xlsx_path = "$analysis_dir_path/wind_bid_comparison.xlsx"
	XLSX.writetable(xlsx_path, "data" => df, "interpretation" => InterpretationTable(cases, wind_agent, time_range); overwrite=true)
	println("wrote $xlsx_path")

	adjustments_df = BuildComparisonTable(Dict(case => case_tables[case].adjustments for case in cases), cases, ADJUSTMENT_METRICS)

	# one marker for both designs: the wind bids are the same noisy forecast in each, so the revision
	# should be too - refuse to pick one design's marker if they ever disagree
	changes = Dict(case => WindAvailabilityChange(case_tables[case].wind) for case in cases)
	directions = Dict(case => WindDirection(changes[case]) for case in cases)
	base, other = cases
	directions[base] == directions[other] || throw("wind availability direction differs between $base and $other for MTUs $(adjustments_df.MTU[directions[base] .!= directions[other]]) - a single marker per MTU isn't defined")
	insertcols!(adjustments_df, 2, "Wind Availability Change (MWh)" => changes[base], "Wind Availability Direction" => directions[base])

	# the final auction price of each MTU under each design (the designs can settle at different prices),
	# right after the direction marker
	price_df = BuildComparisonTable(wind_tables, cases, [PRICE_METRIC])
	insertcols!(adjustments_df, 4, (name => price_df[!, name] for name in names(price_df)[2:end])...)

	summary_df = BuildDirectionSummary(Dict(case => case_tables[case].adjustments for case in cases), directions[base], cases)

	value_df = BuildAdjustmentValueTable(Dict(case => case_tables[case].adjustments for case in cases), wind_tables, cases)

	adjustments_path = "$analysis_dir_path/final_auction_adjustments.xlsx"
	XLSX.writetable(adjustments_path, "data" => adjustments_df, "by_wind_direction" => summary_df, "adjustment_value" => value_df, "interpretation" => AdjustmentInterpretationTable(cases, time_range); overwrite=true)
	println("wrote $adjustments_path")

	return df, adjustments_df, summary_df, value_df
end

# one row per MTU: for each agent, {case1}, {case2} and Difference ({case2} - {case1}) of that agent's
# adjustment quantity x the final auction price of the same design and MTU (missing where the adjustment is)
function BuildAdjustmentValueTable(adjustment_tables, wind_tables, cases)
	value_tables = Dict(case => DataFrame(
		"MTU" => adjustment_tables[case].MTU,
		(AdjustmentValueMetric(label) => adjustment_tables[case][!, AdjustmentMetric(label)] .* wind_tables[case][!, PRICE_METRIC] for (_, label) in ADJUSTMENT_AGENTS)...,
	) for case in cases)
	return BuildComparisonTable(value_tables, cases, ADJUSTMENT_VALUE_METRICS)
end

# one row per agent and wind-availability direction (agent-major, so an agent's Increase and Decrease
# rows sit together): how many MTUs are in the segment, then each SUMMARY_STATS for {case1}, {case2}
# and Difference ({case2} - {case1}), over that segment's MTUs
function BuildDirectionSummary(adjustment_tables, directions, cases)
	base, other = cases
	columns = ["Agent", "Wind Availability", "MTUs"]
	for (stat, _) in SUMMARY_STATS
		append!(columns, ["$base $stat", "$other $stat", "Difference $stat ($other - $base)"])
	end
	out = DataFrame([c => (c in ("Agent", "Wind Availability") ? String[] : c == "MTUs" ? Int[] : Union{Float64,Missing}[]) for c in columns])

	for (_, label) in ADJUSTMENT_AGENTS, direction in WIND_DIRECTIONS
		mask = directions .== direction
		row = Dict{String,Any}("Agent" => label, "Wind Availability" => direction, "MTUs" => count(mask))
		values = Dict(case => collect(skipmissing(adjustment_tables[case][mask, AdjustmentMetric(label)])) for case in cases)
		for (stat, f) in SUMMARY_STATS
			base_value, other_value = f(values[base]), f(values[other])
			row["$base $stat"] = base_value
			row["$other $stat"] = other_value
			row["Difference $stat ($other - $base)"] = other_value - base_value
		end
		push!(out, row)
	end

	return out
end

# one row per MTU in time_range, for a single case, as two tables read in one pass over its RAW
# clearings: `wind` holds the METRICS (in METRICS order) and `adjustments` holds the
# ADJUSTMENT_METRICS (in ADJUSTMENT_AGENTS order). Previous-auction values and adjustments are
# missing when no earlier clearing covered the MTU.
function BuildCaseTables(case_path, time_range, wind_agent)
	prefix = PostAnalysisCommon.DiscoverRawDispatchPrefix(case_path)
	bid_col, contracted_col, adj_col = "Q_$wind_agent", wind_agent, "$(wind_agent)_adj"

	# clearing MTU -> its decision-variable DataFrame (or nothing if that clearing wasn't exported);
	# each clearing is read at most twice (as a final auction, then as someone's previous auction)
	cache = Dict{Int,Union{Nothing,DataFrame}}()
	load(clearing_mtu) = get!(cache, clearing_mtu) do
		path = "$prefix$clearing_mtu.xlsx"
		isfile(path) ? PostAnalysisCommon.LoadFile(path) : nothing
	end
	row_for(clearing_mtu, mtu) = begin
		dvs = load(clearing_mtu)
		dvs === nothing && return nothing
		rows = dvs[dvs.mtu .== mtu, :]
		nrow(rows) == 0 ? nothing : rows[1, :]
	end

	out = DataFrame(
		"MTU" => Int[],
		(m => Union{Float64,Missing}[] for m in METRICS)...,
	)
	adjustments_out = DataFrame(
		"MTU" => Int[],
		(m => Union{Float64,Missing}[] for m in ADJUSTMENT_METRICS)...,
	)

	for mtu in time_range
		final = row_for(mtu, mtu)
		final === nothing && throw("no final-auction RAW export covering MTU $mtu under $case_path")

		previous = nothing
		for clearing_mtu in (mtu - 1):-1:(mtu - MAX_PREVIOUS_LOOKBACK)
			previous = row_for(clearing_mtu, mtu)
			previous !== nothing && break
		end

		push!(out, (
			mtu,
			final[bid_col],
			previous === nothing ? missing : previous[bid_col],
			final[contracted_col],
			previous === nothing ? missing : previous[contracted_col],
			final[adj_col],
			final["SOC"],
			previous === nothing ? missing : previous["SOC"],
			final["price"],
		))
		push!(adjustments_out, (
			mtu,
			(previous === nothing ? missing : SnapNoise(final[col] - previous[col]) for (col, _) in ADJUSTMENT_AGENTS)...,
		))
		# bound memory: a clearing older than the lookback can't be anyone's previous auction again
		delete!(cache, mtu - MAX_PREVIOUS_LOOKBACK - 1)
	end

	return (wind=out, adjustments=adjustments_out)
end

# MTU, then for each of `metrics`: {case1}, {case2}, Difference ({case2} - {case1}) - for the default
# CASES that's Fixed, Rolling, Rolling minus Fixed
function BuildComparisonTable(tables, cases, metrics)
	base, other = cases
	df = DataFrame("MTU" => tables[base].MTU)
	for metric in metrics
		df[!, "$base $metric"] = tables[base][!, metric]
		df[!, "$other $metric"] = tables[other][!, metric]
		df[!, "Difference $metric ($other - $base)"] = tables[other][!, metric] .- tables[base][!, metric]
	end
	return df
end

function AdjustmentInterpretationTable(cases, time_range)
	base, other = cases
	return DataFrame(
		"DataPoint" => ["MTU"; "Wind Availability Change (MWh)"; "Wind Availability Direction"; PRICE_METRIC; ADJUSTMENT_METRICS; "Difference"; "Solver noise"; "by_wind_direction sheet"; "adjustment_value sheet"; "Analysis time range"],
		"Interpretation" => [
			"Market time unit in which auction is held, counted from beginning of experiment period (0 indexed)";
			"Wind bid quantity in the first MTU of this auction minus its bid quantity in the previous auction that covered it (MWh) - the forecast revision; identical in both designs";
			"Increase if Wind Availability Change is above 0, Decrease if below 0, No change if exactly 0, No previous auction if none covered this MTU";
			"Market clearing price (€/MWh) for this MTU in its final auction (the settlement price) under each design";
			[
				"Change in the $label quantity for this MTU made in its final auction (final auction value - previous auction value, MWh)" *
				(startswith(col, "Storage") ? "; storage charge and discharge are the planned charge/discharge energy in that MTU" : "") *
				"; blank if no earlier auction covered this MTU"
				for (col, label) in ADJUSTMENT_AGENTS
			];
			"$other value minus $base value for the metric named in the column header";
			"Adjustments smaller than $(ADJUSTMENT_NOISE_TOLERANCE) MWh in absolute value are solver noise and are reported as 0";
			"Per agent, compares MTUs where wind availability increased against MTUs where it decreased (MTUs with no change or no previous auction are in neither): MTUs = MTUs in the segment; Mean Adjustment = average adjustment per MTU; Total Adjustment = net sum (signed); Total Absolute Adjustment = sum of |adjustment|; MTUs Adjusted = MTUs with a nonzero adjustment; MTUs Adjusted Up / Down = MTUs where the agent's adjustment is above / below 0 (Up + Down = MTUs Adjusted)";
			"Per agent and MTU, the final-auction adjustment quantity (MWh) times that design's final auction price for the MTU (€/MWh), in €; positive = more energy bought (demand, storage charge) or sold (generators, storage discharge) at the final price";
			time_range_description(time_range)
		],
	)
end

time_range_description(time_range) = "MTUs $(first(time_range)) to $(last(time_range)) - one row per MTU; derived from the runs' experiment configs (samplePeriodExcludeSpinUp/End) unless a time_range was passed explicitly"

function InterpretationTable(cases, wind_agent, time_range)
	base, other = cases
	return DataFrame(
		"DataPoint" => [
			"MTU",
			"Final Bid Quantity",
			"Previous Auction Bid Quantity",
			"Final Contracted Quantity",
			"Previous Auction Contracted Quantity",
			"Final Auction Adjustment Quantity",
			"Final Auction SOC",
			"Previous Auction SOC",
			"Final Auction Price",
			"Difference",
			"Analysis time range",
		],
		"Interpretation" => [
			"Market time unit in which auction is held, counted from beginning of experiment period (0 indexed)",
			"$wind_agent bid quantity for this MTU",
			"$wind_agent bid quantity for this MTU in the latest earlier auction whose window still included it (blank if none)",
			"$wind_agent quantity contracted for this MTU after its final auction, i.e. its final dispatch",
			"$wind_agent quantity contracted for this MTU after the previous auction (blank if none)",
			"$wind_agent adjustment made to the previously contracted quantity in the final auction (Final Contracted - Previous Auction Contracted)",
			"Storage state of charge at the end of this MTU as planned in its final auction (MWh)",
			"Storage state of charge at the end of this MTU as planned in the previous auction (blank if none)",
			"Market clearing price (€/MWh) for this MTU in its final auction",
			"$other value minus $base value for the metric named in the column header",
			time_range_description(time_range),
		],
	)
end

end;

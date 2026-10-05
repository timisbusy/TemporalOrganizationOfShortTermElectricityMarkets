module PostAnalysisSEW

using XLSX, DataFrames, Plots, Statistics, Latexify

include("../post_analysis_common.jl")

# Mean Final Auction Price is already an intensive €/MWh average (like
# PostAnalysisWindowLengthStorageKPIs' Avg Charging/Discharging Price), not a total over
# time_range, so it passes through the daily_average sheet unscaled rather than being divided by
# days like every other (extensive) indicator in this table.
const INTENSIVE_INDICATORS = Set([PostAnalysisCommon.MEAN_FINAL_AUCTION_PRICE_INDICATOR])

# "Name (Unit)" -> "Name (Unit/day)" for the daily-average table, so its row labels can't be
# mistaken for the same totals reported in the "totals" sheet just by glancing at the Indicator
# column - see PostAnalysisWindowLengthKPIs.DailyIndicatorLabel, which this mirrors exactly.
function DailyIndicatorLabel(indicator)
	indicator in INTENSIVE_INDICATORS && return indicator
	m = match(r"^(.*)\(([^()]*)\)$", indicator)
	m === nothing && return "$indicator (per day)"
	return "$(m.captures[1])($(m.captures[2])/day)"
end

# cases is any N case_paths keys (not just the module-default "Fixed Horizon"/"Rolling Horizon"
# pair) - cases[end] is the "subject" design (e.g. Rolling Horizon) being evaluated, and every
# preceding case is an alternative base case it's compared against in turn - the original
# case_a/case_b (baseline, subject) pairwise convention generalized to N cases: for N=2 this is
# unchanged (cases[1] the sole base case, cases[2] the subject), while for N>2 the subject is
# compared against EVERY other case individually rather than all of them sharing one baseline (see
# PostAnalysisDaily/PostAnalysisQuantitiesByAgent for that other, baseline-first convention). One
# value column per case (in `cases` order), then one "{subject} vs {base}" String column per base
# case.
function PerformAnalysis(case_paths; cases=PostAnalysisCommon.CASES, output_base=PostAnalysisCommon.NewAnalysisOutputDir(case_paths), time_range=PostAnalysisCommon.DEFAULT_TIME_RANGE)

	subject = cases[end]
	base_cases = cases[1:end-1]
	diff_cols = ["$subject vs $base" for base in base_cases]

	# "Indicator", one Float64 column per case, then one String "% Difference" column per
	# non-baseline case - called separately for final_indicators_df/daily_avg_df below so they each
	# get their own backing arrays (DataFrame(pairs...) does not copy the empty arrays in `pairs`,
	# so reusing one literal `pairs` value for both tables would have them silently share columns).
	function empty_indicators_table()
		pairs = Any["Indicator"=>String[]]
		append!(pairs, [case=>Float64[] for case in cases])
		append!(pairs, [col=>String[] for col in diff_cols])
		return DataFrame(pairs...)
	end

	analysis_dir_path = "$output_base/post_analysis_SEW"

	println("starting analysis")
	PostAnalysisCommon.CleanDirectory(analysis_dir_path)

	# fresh per-case (economic_indicators, agent_indicators, transactions, finalDispatchDecisions,
	# mtu_economic_indicators) - see PostAnalysisCommon.CalculateCaseIndicators for why this is
	# computed on demand rather than read from a pre-aggregated economic_indicators.xlsx
	indicators_by_case = Dict(case => PostAnalysisCommon.CalculateCaseIndicators(case_paths, case; time_range=time_range, imbalance_agents=PostAnalysisCommon.DEFAULT_IMBALANCE_AGENTS) for case in cases)
	economic_indicators_by_case = Dict(case => indicators_by_case[case].economic_indicators for case in cases)

	final_indicators_df = empty_indicators_table()

	function push_indicator_row!(indicator, values_by_case)
		row = Any[indicator]
		append!(row, [values_by_case[case] for case in cases])
		append!(row, [PostAnalysisCommon.PercentDiffString(values_by_case[subject], values_by_case[base]) for base in base_cases])
		push!(final_indicators_df, row)
	end

	for indicator in names(economic_indicators_by_case[subject])
		push_indicator_row!(indicator, Dict(case => economic_indicators_by_case[case][1, indicator] for case in cases))
	end

	push_indicator_row!(PostAnalysisCommon.WIND_CURTAILED_INDICATOR,
		Dict(case => PostAnalysisCommon.WindCurtailed(indicators_by_case[case].final_dispatch_decisions) for case in cases))

	push_indicator_row!(PostAnalysisCommon.MEAN_FINAL_AUCTION_PRICE_INDICATOR,
		Dict(case => PostAnalysisCommon.LoadMeanFinalAuctionPrice(case_paths[case], time_range) for case in cases))

	println(final_indicators_df)

	# average daily value = total / MTU count in time_range * 24 (MTU per day) - % difference is
	# unchanged from the totals table since every case scales by the same factor; only the reported
	# magnitudes differ.
	mtu_count = length(time_range)
	days = mtu_count / 24

	daily_avg_df = empty_indicators_table()
	for row in eachrow(final_indicators_df)
		scale = row.Indicator in INTENSIVE_INDICATORS ? 1.0 : 24 / mtu_count
		new_row = Any[DailyIndicatorLabel(row.Indicator)]
		append!(new_row, [row[Symbol(case)] * scale for case in cases])
		append!(new_row, [row[Symbol(col)] for col in diff_cols])
		push!(daily_avg_df, new_row)
	end
	push!(daily_avg_df, ["Days in Test Range"; [days for _ in cases]; ["—" for _ in diff_cols]])

	# Imbalance Energy (MWh)/days rarely lands on a clean number - round it to the hundredths place
	# on this daily table specifically (the totals table's own whole-MWh Imbalance Energy is left
	# as-is), same treatment as PostAnalysisWindowLengthKPIs.
	daily_imbalance_energy_label = DailyIndicatorLabel("Imbalance Energy (MWh)")
	PostAnalysisCommon.RoundIndicatorRow!(daily_avg_df, daily_imbalance_energy_label, cases)

	println(daily_avg_df)

	XLSX.writetable("$analysis_dir_path/sew_details.xlsx", "totals" => final_indicators_df, "daily_average" => daily_avg_df; overwrite=true)

	totals_tex_df = PostAnalysisCommon.FormatIndicatorRowForLatex(PostAnalysisCommon.EscapeForLatex(final_indicators_df), PostAnalysisCommon.MEAN_FINAL_AUCTION_PRICE_INDICATOR, cases)
	daily_avg_tex_df = PostAnalysisCommon.FormatIndicatorRowsForLatex(PostAnalysisCommon.EscapeForLatex(daily_avg_df), [PostAnalysisCommon.MEAN_FINAL_AUCTION_PRICE_INDICATOR, daily_imbalance_energy_label], cases)
	totals_tex = latexify(totals_tex_df; env = :table, booktabs = true, snakecase=true, latex=false,fmt="%'\''d\n")
	daily_avg_tex = latexify(daily_avg_tex_df; env = :table, booktabs = true, snakecase=true, latex=false,fmt="%'\''d\n")

	open("$analysis_dir_path/sew_details.tex", "w") do io
		println(io, totals_tex)
		println(io)
		println(io, daily_avg_tex)
	end

end

end;

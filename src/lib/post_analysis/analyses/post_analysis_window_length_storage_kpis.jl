# Storage economics compared across the three rolling-horizon optimization-window-length cases
# (36h/48h/72h) - same table shape as PostAnalysisWindowLengthKPIs (totals + daily_average sheets,
# a %% difference column between each pair of adjacent window lengths), but for storage-specific
# indicators computed directly from each case's own final_dispatch_decisions.xlsx (StorageCharge/
# StorageDischarge/FinalAuctionPrice) rather than PostAnalysisCommon.CalculateCaseIndicators'
# aggregate economic indicators - Storage Revenue there uses the same net-revenue definition as
# this module's Net Revenue (discharge-minus-charge, each priced at its own MTU's
# FinalAuctionPrice - the realized settlement price for that MTU, matching MarketDataStorage.
# CalculateEconomicIndicators' storage_revenue), just computed independently here so this analysis
# doesn't need transactions.xlsx or an agent map.

module PostAnalysisWindowLengthStorageKPIs

using XLSX, DataFrames, Latexify

include("../post_analysis_common.jl")
include("./post_analysis_conventional_generation_cost.jl")

const DEFAULT_CASE_PATHS = PostAnalysisConventionalGenerationCost.DEFAULT_CASE_PATHS
const DEFAULT_CASES = PostAnalysisConventionalGenerationCost.DEFAULT_CASES

const INDICATOR_NAMES = ["Charge Energy (MWh)", "Discharge Energy (MWh)", "Throughput (MWh)", "Net Revenue (€)", "Avg Charging Price (€/MWh)", "Avg Discharging Price (€/MWh)"]

# indicators that are extensive totals over time_range (MWh or €), so the daily_average table
# divides them by the number of days - the two average-price indicators are already intensive
# (€/MWh, independent of how many days they're averaged over) and pass through unscaled.
const PER_DAY_INDICATORS = Set(["Charge Energy (MWh)", "Discharge Energy (MWh)", "Throughput (MWh)", "Net Revenue (€)"])

# "Name (Unit)" -> "Name (Unit/day)" for the daily-average table, so its row labels can't be
# mistaken for the same totals reported in the "totals" sheet just by glancing at the Indicator
# column - the two average-price indicators (already a rate, not scaled by day count) are left
# unchanged.
function DailyIndicatorLabel(indicator)
	indicator in PER_DAY_INDICATORS || return indicator
	m = match(r"^(.*)\(([^()]*)\)$", indicator)
	m === nothing && return "$indicator (per day)"
	return "$(m.captures[1])($(m.captures[2])/day)"
end

function PerformAnalysis(case_paths=DEFAULT_CASE_PATHS; cases=DEFAULT_CASES, output_base=PostAnalysisCommon.NewAnalysisOutputDir(case_paths; label=PostAnalysisConventionalGenerationCost.DefaultLabel(case_paths, cases)), time_range=PostAnalysisCommon.DEFAULT_TIME_RANGE)

	length(cases) == 3 || throw("PostAnalysisWindowLengthStorageKPIs compares exactly 3 window lengths (for the adjacent-pair %% difference columns); got $(length(cases)): $cases")
	short, mid, long = cases

	analysis_dir_path = "$output_base/storage_kpis"
	PostAnalysisCommon.CleanDirectory(analysis_dir_path)

	storage_kpis_by_case = Dict(case => CalculateStorageKPIs(case_paths[case], time_range) for case in cases)

	mid_vs_short_col = "$mid vs $short % Difference"
	long_vs_mid_col = "$long vs $mid % Difference"

	final_indicators_df = DataFrame("Indicator"=>String[], short=>Float64[], mid=>Float64[], long=>Float64[], mid_vs_short_col=>String[], long_vs_mid_col=>String[])

	for indicator in INDICATOR_NAMES
		short_v = storage_kpis_by_case[short][indicator]
		mid_v = storage_kpis_by_case[mid][indicator]
		long_v = storage_kpis_by_case[long][indicator]
		push!(final_indicators_df, [indicator, short_v, mid_v, long_v, PostAnalysisCommon.PercentDiffString(mid_v, short_v), PostAnalysisCommon.PercentDiffString(long_v, mid_v)])
	end

	println(final_indicators_df)

	# extensive indicators (energy/€ totals) are divided by days for a daily rate, same as
	# PostAnalysisWindowLengthKPIs - the two average-price indicators are left unscaled since
	# they're already a per-MWh average, not a total. %% differences are unaffected either way.
	mtu_count = length(time_range)
	days = mtu_count / 24

	daily_avg_df = DataFrame("Indicator"=>String[], short=>Float64[], mid=>Float64[], long=>Float64[], mid_vs_short_col=>String[], long_vs_mid_col=>String[])
	for row in eachrow(final_indicators_df)
		scale = row.Indicator in PER_DAY_INDICATORS ? 24 / mtu_count : 1.0
		push!(daily_avg_df, [DailyIndicatorLabel(row.Indicator), row[short] * scale, row[mid] * scale, row[long] * scale, row[mid_vs_short_col], row[long_vs_mid_col]])
	end
	push!(daily_avg_df, ["Days in Test Range", days, days, days, "—", "—"])

	println(daily_avg_df)

	XLSX.writetable("$analysis_dir_path/storage_kpis.xlsx", "totals" => final_indicators_df, "daily_average" => daily_avg_df; overwrite=true)

	totals_tex = latexify(PostAnalysisCommon.EscapeForLatex(final_indicators_df); env = :table, booktabs = true, snakecase=true, latex=false, fmt="%'\''d\n")
	daily_avg_tex = latexify(PostAnalysisCommon.EscapeForLatex(daily_avg_df); env = :table, booktabs = true, snakecase=true, latex=false, fmt="%'\''d\n")

	open("$analysis_dir_path/storage_kpis.tex", "w") do io
		println(io, totals_tex)
		println(io)
		println(io, daily_avg_tex)
	end

	return (final_indicators_df, daily_avg_df)
end

# Charge/Discharge Energy: total MWh over time_range. Throughput: their sum. Net Revenue: discharge
# revenue minus charge cost, each MTU priced at its own FinalAuctionPrice (the realized settlement
# price for that MTU - see MarketDataStorage.CalculateEconomicIndicators' storage_revenue for the
# same definition). Avg Charging/Discharging Price: quantity-weighted average FinalAuctionPrice
# over MTUs where the corresponding flow is nonzero, i.e. total €paid-or-earned / total MWh.
function CalculateStorageKPIs(case_path, time_range)
	dd = PostAnalysisCommon.LoadFile(joinpath(case_path, "final_dispatch_decisions.xlsx"))
	dd = dd[time_range.start .<= dd.mtu .<= time_range.stop, :]

	charge_energy = sum(dd.StorageCharge)
	discharge_energy = sum(dd.StorageDischarge)
	throughput = charge_energy + discharge_energy

	charge_cost = sum(dd.StorageCharge .* dd.FinalAuctionPrice)
	discharge_revenue = sum(dd.StorageDischarge .* dd.FinalAuctionPrice)
	net_revenue = discharge_revenue - charge_cost

	avg_charging_price = charge_energy > 0 ? charge_cost / charge_energy : 0.0
	avg_discharging_price = discharge_energy > 0 ? discharge_revenue / discharge_energy : 0.0

	return Dict(
		"Charge Energy (MWh)" => charge_energy,
		"Discharge Energy (MWh)" => discharge_energy,
		"Throughput (MWh)" => throughput,
		"Net Revenue (€)" => net_revenue,
		"Avg Charging Price (€/MWh)" => avg_charging_price,
		"Avg Discharging Price (€/MWh)" => avg_discharging_price,
	)
end

end;

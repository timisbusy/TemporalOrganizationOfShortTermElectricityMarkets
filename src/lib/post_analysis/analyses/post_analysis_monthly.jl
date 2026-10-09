# Month-by-month roll-up for long (multi-month) runs such as the full-year 2025 fixed_36/rolling_36
# pair - the daily analysis (post_analysis_daily.jl) gives one point per day, which is too fine to
# read off a year; this aggregates the same final_dispatch_decisions/mtu_economic_results data per
# calendar month instead, so seasonal effects (winter wind vs. summer solar, storage cycling, price
# spreads) are visible.
#
# Months are derived from each MTU's own calendar date, start_date + (mtu ÷ MTUs per day) days - pass
# the experiment's own startDate (default 2024-12-29, the full-year 2025 runs'). Days follow the
# experiment's own (UTC) day convention, so a month's boundaries are UTC midnights.

module PostAnalysisMonthly

using XLSX, DataFrames, Plots, Statistics, Dates, Latexify

include("../post_analysis_common.jl")

const SEW = Symbol("Socioeconomic Welfare (€)")
const IMBALANCE = Symbol("Imbalance Energy (MWh)")
const PRODUCTION_COSTS = Symbol("Production Costs (€)")
const SHOULDER_PEAK = Symbol("Shoulder + Peak Dispatch (MWh)")
const GROSS_TRADED = Symbol("Gross Traded Volume (MWh)")

# generators whose |transaction quantity| makes up Gross Traded Volume - the same definition and
# agent list as PostAnalysisQuantitiesByAgent.AnalyzeGrossTradedVolume (hardcoded, like every other
# module in this suite, rather than read from PostAnalysisCommon.DEFAULT_AGENT_MAP)
const GENERATOR_NAMES = ["3G_Base", "4G_Shoulder", "5G_Peak", "6G_Wind", "7G_Solar"]

# metrics the monthly comparison tables report a subject-minus-base difference for, besides SEW
const COMPARED_METRICS = [
	Symbol("Mean Final Price (€/MWh)"),
	Symbol("Wind Curtailed (MWh)"),
	Symbol("Storage Throughput (MWh)"),
	IMBALANCE,
	SHOULDER_PEAK,
	GROSS_TRADED,
	PRODUCTION_COSTS,
]

# "2025-01" etc. for one MTU
MonthLabel(start_date, mtu, mtus_per_day) = Dates.format(start_date + Dates.Day(mtu ÷ mtus_per_day), "yyyy-mm")

# one row per month for one case. final_dispatch_decisions/mtu_economic_indicators/transactions should
# already be scoped to the analysis time_range (CalculateCaseIndicators' own return values are);
# transactions are bucketed by their delivery MTU ("Market Time Unit"), like every other metric here.
function MonthlyIndicators(final_dispatch_decisions, mtu_economic_indicators, transactions, start_date, mtus_per_day)
	dd = copy(final_dispatch_decisions)
	dd[!, :Month] = [MonthLabel(start_date, m, mtus_per_day) for m in dd.mtu]
	dd[!, :WindCurtailed] = dd[!, Symbol("Q_6G_Wind")] .- dd[!, Symbol("6G_Wind")]
	dd[!, :SolarCurtailed] = dd[!, Symbol("Q_7G_Solar")] .- dd[!, Symbol("7G_Solar")]
	dd[!, :ShoulderPeak] = dd[!, Symbol("4G_Shoulder")] .+ dd[!, Symbol("5G_Peak")]

	monthly_dd = combine(groupby(dd, :Month),
		:mtu => length => Symbol("MTUs"),
		:FinalAuctionPrice => mean => Symbol("Mean Final Price (€/MWh)"),
		:FinalAuctionPrice => std => Symbol("Price Std Dev (€/MWh)"),
		:FinalAuctionPrice => (p -> count(<=(0), p)) => Symbol("MTUs Price ≤ 0"),
		:FinalAuctionPrice => (p -> count(>=(150), p)) => Symbol("MTUs Price ≥ 150"),
		:WindCurtailed => sum => Symbol("Wind Curtailed (MWh)"),
		:SolarCurtailed => sum => Symbol("Solar Curtailed (MWh)"),
		:ShoulderPeak => sum => Symbol("Shoulder + Peak Dispatch (MWh)"),
		[:StorageCharge, :StorageDischarge] => ((c, d) -> sum(c) + sum(d)) => Symbol("Storage Throughput (MWh)"),
	)

	mei = copy(mtu_economic_indicators)
	mei[!, :Month] = [MonthLabel(start_date, m, mtus_per_day) for m in mei.MTU]
	monthly_mei = combine(groupby(mei, :Month),
		SEW => sum => SEW,
		IMBALANCE => sum => IMBALANCE,
		PRODUCTION_COSTS => sum => PRODUCTION_COSTS,
	)

	tx = transactions[in.(transactions.Agent, Ref(GENERATOR_NAMES)), :]
	tx = DataFrame(Month = [MonthLabel(start_date, m, mtus_per_day) for m in tx[!, Symbol("Market Time Unit")]], Quantity = tx[!, Symbol("Quantity (MWh)")])
	monthly_tx = combine(groupby(tx, :Month), :Quantity => (q -> sum(abs.(q))) => GROSS_TRADED)

	return sort(innerjoin(monthly_dd, monthly_mei, monthly_tx, on=:Month), :Month)
end

# case_paths/cases/output_base as in the other post-analysis modules - cases[end] is the "subject"
# design (e.g. Rolling Horizon) compared against each preceding case, matching PostAnalysisSEW/Daily.
function PerformAnalysis(case_paths; cases=PostAnalysisCommon.CASES, output_base=PostAnalysisCommon.NewAnalysisOutputDir(case_paths), time_range=PostAnalysisCommon.DEFAULT_TIME_RANGE, start_date=Date(2024, 12, 29), mtus_per_day=24)

	analysis_dir_path = "$output_base/post_analysis_monthly"
	PostAnalysisCommon.CleanDirectory(analysis_dir_path)

	monthly_by_case = Dict{String,DataFrame}()
	for case in cases
		(economic_indicators, agent_indicators, transactions, final_dispatch_decisions, mtu_economic_indicators) = PostAnalysisCommon.CalculateCaseIndicators(case_paths, case; time_range=time_range, imbalance_agents=PostAnalysisCommon.DEFAULT_IMBALANCE_AGENTS)
		monthly_by_case[case] = MonthlyIndicators(final_dispatch_decisions, mtu_economic_indicators, transactions, start_date, mtus_per_day)
		println("$case monthly indicators:")
		println(monthly_by_case[case])
	end

	subject = cases[end]
	comparison_sheets = Pair{String,DataFrame}[]
	for base in cases[1:end-1]
		cmp = DataFrame(
			Month = monthly_by_case[subject].Month,
			Subject = monthly_by_case[subject][!, SEW],
		)
		cmp[!, :Base] = monthly_by_case[base][!, SEW]
		cmp[!, Symbol("Δ SEW (€)")] = cmp.Subject .- cmp.Base
		cmp[!, Symbol("Δ SEW (%)")] = [b == 0 ? missing : 100 * (s - b) / b for (s, b) in zip(cmp.Subject, cmp.Base)]
		for metric in COMPARED_METRICS
			cmp[!, Symbol("Δ $metric")] = monthly_by_case[subject][!, metric] .- monthly_by_case[base][!, metric]
		end
		rename!(cmp, :Subject => Symbol("SEW $subject (€)"), :Base => Symbol("SEW $base (€)"))
		push!(comparison_sheets, "vs_$(PostAnalysisCommon.CaseSlug(base))"[1:min(end, 31)] => cmp)
		println("$subject - $base monthly comparison:")
		println(cmp)
		write("$analysis_dir_path/monthly_comparison_$(PostAnalysisCommon.CaseSlug(base)).tex",
			latexify(PostAnalysisCommon.EscapeForLatex(cmp); env=:table, booktabs=true, snakecase=true, latex=false, fmt="%'\''d\n"))
		PlotMonthlyDifference(cmp, subject, base, analysis_dir_path)
	end

	case_sheets = [case[1:min(end, 31)] => monthly_by_case[case] for case in cases] # xlsx sheet names are capped at 31 chars
	XLSX.writetable("$analysis_dir_path/monthly_indicators.xlsx", case_sheets..., comparison_sheets...; overwrite=true)

	PlotMonthlyPrices(monthly_by_case, cases, analysis_dir_path)
	PlotMonthlyStorage(monthly_by_case, cases, analysis_dir_path)

	return monthly_by_case
end

function PlotMonthlyDifference(cmp, subject, base, analysis_dir_path)
	p = bar(cmp.Month, cmp[!, Symbol("Δ SEW (€)")]; legend=false, xlabel="Month", ylabel="$subject - $base Δ SEW [EUR]",
		title="Monthly SEW difference: $subject - $base", xrotation=45, bottom_margin=8Plots.mm, left_margin=8Plots.mm)
	hline!(p, [0.0]; color=:grey, linestyle=:dash, label=false)
	display(p)
	savefig(p, "$analysis_dir_path/monthly_sew_diff_$(PostAnalysisCommon.CaseSlug(base)).png")
end

function PlotMonthlyPrices(monthly_by_case, cases, analysis_dir_path)
	p = plot(xlabel="Month", ylabel="Mean final auction price (EUR/MWh)", title="Monthly mean price", xrotation=45, legend=:topright, bottom_margin=8Plots.mm, left_margin=8Plots.mm)
	for case in cases
		df = monthly_by_case[case]
		plot!(p, df.Month, df[!, Symbol("Mean Final Price (€/MWh)")]; label=case, marker=:circle)
	end
	display(p)
	savefig(p, "$analysis_dir_path/monthly_mean_price.png")
end

function PlotMonthlyStorage(monthly_by_case, cases, analysis_dir_path)
	p = plot(xlabel="Month", ylabel="Storage throughput (MWh)", title="Monthly storage throughput", xrotation=45, legend=:topright, bottom_margin=8Plots.mm, left_margin=8Plots.mm)
	for case in cases
		df = monthly_by_case[case]
		plot!(p, df.Month, df[!, Symbol("Storage Throughput (MWh)")]; label=case, marker=:circle)
	end
	display(p)
	savefig(p, "$analysis_dir_path/monthly_storage_throughput.png")
end

end;

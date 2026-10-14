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
function PerformAnalysis(case_paths; cases=PostAnalysisCommon.CASES, output_base=PostAnalysisCommon.NewAnalysisOutputDir(case_paths), time_range=PostAnalysisCommon.DEFAULT_TIME_RANGE, start_date=Date(2024, 12, 29), mtus_per_day=24, storage_efficiency=nothing)

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

	if storage_efficiency !== nothing
		PerformResidualValueAnalysis(case_paths, cases, monthly_by_case, analysis_dir_path, start_date, mtus_per_day, time_range, storage_efficiency)
	end

	return monthly_by_case
end

# Residual-storage-value adjusted SEW, per calendar month fully inside time_range: SEW only counts
# what was traded in the month, so a design that ends the month with more energy in storage than it
# started with is under-credited (and one that drew storage down is over-credited). The adjustment
# values that SOC change at the month's discharge-weighted mean final price (Σ price·discharge /
# Σ discharge, from this case's own prices; the month's plain mean price if storage never
# discharged), times the discharge efficiency since SOC is stored energy and only η of it is
# deliverable. SOC[t] is the end-of-MTU-t state, so a month's opening SOC is the SOC at the MTU before
# its first one - read from the unscoped dispatch table, since it can fall just outside time_range.
function RawSettledSOC(case_path, mtu)
	raw_dir = joinpath(case_path, "RAW")
	prefix = basename(PostAnalysisCommon.DiscoverRawDispatchPrefix(case_path))
	starts = Int[]
	for f in readdir(raw_dir)
		m = match(r"^decisionvariables_.+_(\d+)\.xlsx$", f)
		m !== nothing && parse(Int, m.captures[1]) <= mtu && push!(starts, parse(Int, m.captures[1]))
	end
	for s in sort(starts; rev=true) # the latest clearing covering the MTU is the one whose value settled
		d = DataFrame(XLSX.readtable(joinpath(raw_dir, "$prefix$s.xlsx"), "data"))
		rows = d[d.mtu .== mtu, :]
		nrow(rows) > 0 && return rows.SOC[1]
	end
	throw("no RAW clearing in $raw_dir covers MTU $mtu")
end

function ResidualStorageValue(final_dispatch_decisions_all, start_date, mtus_per_day, time_range, storage_efficiency, monthly_sew, case_path)
	dd = final_dispatch_decisions_all
	soc_at = Dict(zip(dd.mtu, dd.SOC))
	# the exported dispatch starts at time_range.start, so the SOC just before it (and before any
	# later month, which is in soc_at) comes from the RAW clearings: the latest one covering that MTU
	soc_before(mtu) = haskey(soc_at, mtu) ? soc_at[mtu] : RawSettledSOC(case_path, mtu)
	rows = NamedTuple[]
	for label in monthly_sew.Month
		month_start = Date(label * "-01")
		first_mtu = Dates.value(month_start - start_date) * mtus_per_day
		last_mtu = Dates.value(month_start + Dates.Month(1) - start_date) * mtus_per_day - 1
		(first_mtu >= time_range.start && last_mtu <= time_range.stop) || continue # partial month
		m = dd[first_mtu .<= dd.mtu .<= last_mtu, :]
		discharge = m.StorageDischarge
		price = sum(discharge) > 0 ? sum(m.FinalAuctionPrice .* discharge) / sum(discharge) : mean(m.FinalAuctionPrice)
		soc_begin = first_mtu == 0 ? 0.0 : soc_before(first_mtu - 1) # initialSOC is 0 in these agent configs
		soc_end = soc_at[last_mtu]
		value = price * storage_efficiency * (soc_end - soc_begin)
		sew = monthly_sew[monthly_sew.Month .== label, SEW][1]
		push!(rows, (Month=label, SEW=sew, SOCBegin=soc_begin, SOCEnd=soc_end, Price=price, Value=value, Adjusted=sew + value))
	end
	return DataFrame(
		Month = [r.Month for r in rows],
		var"SEW (€)" = [r.SEW for r in rows],
		var"SOC Begin (MWh)" = [r.SOCBegin for r in rows],
		var"SOC End (MWh)" = [r.SOCEnd for r in rows],
		var"Mean Discharge Price (€/MWh)" = [r.Price for r in rows],
		var"Residual Storage Value (€)" = [r.Value for r in rows],
		var"Adjusted SEW (€)" = [r.Adjusted for r in rows],
	)
end

# writes monthly_sew_adjusted.xlsx/.tex-per-comparison/.png alongside the unadjusted monthly outputs
function PerformResidualValueAnalysis(case_paths, cases, monthly_by_case, analysis_dir_path, start_date, mtus_per_day, time_range, storage_efficiency)
	adjusted_by_case = Dict{String,DataFrame}()
	for case in cases
		dd_all = PostAnalysisCommon.LoadCaseFile(case_paths, case, "final_dispatch_decisions.xlsx")
		adjusted_by_case[case] = ResidualStorageValue(dd_all, start_date, mtus_per_day, time_range, storage_efficiency, monthly_by_case[case], case_paths[case])
		println("$case residual-value adjusted monthly SEW:")
		println(adjusted_by_case[case])
	end

	subject = cases[end]
	adjusted = Symbol("Adjusted SEW (€)")
	sheets = Pair{String,DataFrame}[case[1:min(end, 31)] => adjusted_by_case[case] for case in cases]
	totals = DataFrame(Case = String[], var"SEW (€)" = Float64[], var"Residual Storage Value (€)" = Float64[], var"Adjusted SEW (€)" = Float64[])
	for case in cases
		df = adjusted_by_case[case]
		push!(totals, (case, sum(df[!, Symbol("SEW (€)")]), sum(df[!, Symbol("Residual Storage Value (€)")]), sum(df[!, adjusted])))
	end
	push!(sheets, "totals" => totals)
	for base in cases[1:end-1]
		s, b = adjusted_by_case[subject], adjusted_by_case[base]
		cmp = DataFrame(Month = s.Month)
		cmp[!, Symbol("SEW $subject (€)")] = s[!, Symbol("SEW (€)")]
		cmp[!, Symbol("SEW $base (€)")] = b[!, Symbol("SEW (€)")]
		cmp[!, Symbol("Δ SEW (€)")] = s[!, Symbol("SEW (€)")] .- b[!, Symbol("SEW (€)")]
		cmp[!, Symbol("Δ Residual Storage Value (€)")] = s[!, Symbol("Residual Storage Value (€)")] .- b[!, Symbol("Residual Storage Value (€)")]
		cmp[!, Symbol("Δ Adjusted SEW (€)")] = s[!, adjusted] .- b[!, adjusted]
		push!(sheets, "vs_$(PostAnalysisCommon.CaseSlug(base))"[1:min(end, 31)] => cmp)
		println("$subject - $base adjusted monthly comparison:")
		println(cmp)
		write("$analysis_dir_path/monthly_sew_adjusted_comparison_$(PostAnalysisCommon.CaseSlug(base)).tex",
			latexify(PostAnalysisCommon.EscapeForLatex(cmp); env=:table, booktabs=true, snakecase=true, latex=false, fmt="%'\''d\n"))
		p = plot(cmp.Month, cmp[!, Symbol("Δ SEW (€)")]; label="Δ SEW", marker=:circle, xlabel="Month",
			ylabel="$subject - $base [EUR]", title="Monthly SEW difference, residual-value adjusted", titlefontsize=11,
			xrotation=45, legend=:topright, bottom_margin=8Plots.mm, left_margin=8Plots.mm)
		plot!(p, cmp.Month, cmp[!, Symbol("Δ Adjusted SEW (€)")]; label="Δ Adjusted SEW", marker=:square)
		hline!(p, [0.0]; color=:grey, linestyle=:dash, label=false)
		display(p)
		savefig(p, "$analysis_dir_path/monthly_sew_adjusted_diff_$(PostAnalysisCommon.CaseSlug(base)).png")
	end
	XLSX.writetable("$analysis_dir_path/monthly_sew_adjusted.xlsx", sheets...; overwrite=true)
	return adjusted_by_case
end

function PlotMonthlyDifference(cmp, subject, base, analysis_dir_path)
	p = bar(cmp.Month, cmp[!, Symbol("Δ SEW (€)")]; legend=false, xlabel="Month", ylabel="$subject - $base Δ SEW [EUR]",
		title="Monthly SEW difference: $subject - $base", titlefontsize=11, guidefontsize=9, xrotation=45, bottom_margin=8Plots.mm, left_margin=8Plots.mm)
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

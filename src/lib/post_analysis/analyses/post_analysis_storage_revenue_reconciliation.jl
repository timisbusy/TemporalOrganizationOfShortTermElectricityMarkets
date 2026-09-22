# Compares two different definitions of "storage revenue" against each other, across an arbitrary
# set of named cases (not the fixed "Fixed Horizon"/"Rolling Horizon" pair the rest of this
# directory is built around - storage revenue accounting doesn't depend on that comparison, only on
# how many times a market re-clears before an MTU has its final auction, so this is written to take
# any Dict{String,String} of case name -> run directory).
#
# Background: MarketDataStorage.CalculateEconomicIndicators' "Storage Revenue (€)" values storage's
# entire net position for an MTU (StorageDischarge - StorageCharge, from whichever clearing last
# touched it) at that MTU's single FinalAuctionPrice - a deliberate choice (see the comment above
# storage_revenue in market_data_storage.jl) made for parity with an external validation reference,
# not to represent what storage actually earned. Storage in a rolling design gets its position
# revised at every clearing that includes an MTU in its look-ahead window, each revision settled at
# THAT clearing's own price via the transactions table (same convention as generators). Summing
# those real per-clearing trades ("true cumulative" here) is what storage actually got paid; the
# final-price convention discards that whole trading history and prices only the last net position.
#
# The two can diverge a lot, and the divergence grows with look-ahead distance, because a longer
# look-ahead means more re-clearings touch each MTU before final delivery, i.e. more chances for
# storage to lock in a trade at one price while the market keeps moving for unrelated reasons before
# that MTU is finally settled. See MostDivergentMTUs below for the per-MTU drill-down that makes
# this concrete (e.g. a single MTU where storage traded once, early, at a low price, then the market
# drifted to a much higher final settlement price without storage ever trading again).
#
# This reconciliation only works if storage's OWN transactions are actually recorded - which
# requires the fix in helper_model_results.jl's Transactions() (demand_adjust:false no longer
# leaves Qd_adj/Qg_adj-style bookkeeping broken) to be in place; it doesn't affect storage's own
# transactions directly, but the cases this module defaults to were re-run after that fix so the
# whole-market money-balance identity (demand payments == generator revenue + true cumulative
# storage revenue) can be cross-checked at the same time - see TrueCumulativeStorageRevenue's use
# below and PostAnalysisSEW/PostAnalysisCommon.CalculateCaseIndicators for the demand/generator side.

module PostAnalysisStorageRevenueReconciliation

using XLSX, DataFrames, Plots, Printf

include("../post_analysis_common.jl")

# The 8 no_cap_1d_spinup designs (4 market designs x standard/high storage) re-run after the
# demand-transaction fix (see git history around "Add a reusable row-level cross-run validation
# module" and the session that added this file) - a convenience default, not the only thing this
# module can analyze. Pass your own case_paths for any other set of runs.
const DEFAULT_CASE_PATHS = Dict{String,String}(
	"Fixed 36h" => "results/1789748124_fixed_36_no_cap_1d_spinup",
	"Rolling 36h" => "results/1789748169_rolling_36_no_cap_1d_spinup",
	"Rolling 48h" => "results/1789748204_rolling_48_no_cap_1d_spinup",
	"Rolling 72h" => "results/1789748246_rolling_72_no_cap_1d_spinup",
	"Fixed 36h (high storage)" => "results/1789748824_fixed_36_no_cap_1d_spinup_high_storage",
	"Rolling 36h (high storage)" => "results/1789748893_rolling_36_no_cap_1d_spinup_high_storage",
	"Rolling 48h (high storage)" => "results/1789748945_rolling_48_no_cap_1d_spinup_high_storage",
	"Rolling 72h (high storage)" => "results/1789749015_rolling_72_no_cap_1d_spinup_high_storage",
)

# order DEFAULT_CASE_PATHS prints/plots in - Dict iteration order isn't insertion order-guaranteed
# once cases come from a caller-supplied Dict, so any case_paths gets sorted by this preferred
# ordering where possible, falling back to alphabetical for names it doesn't recognize.
const DEFAULT_CASE_ORDER = ["Fixed 36h", "Rolling 36h", "Rolling 48h", "Rolling 72h", "Fixed 36h (high storage)", "Rolling 36h (high storage)", "Rolling 48h (high storage)", "Rolling 72h (high storage)"]

function OrderedCases(case_paths)
	known = [c for c in DEFAULT_CASE_ORDER if haskey(case_paths, c)]
	unknown = sort([c for c in keys(case_paths) if !(c in DEFAULT_CASE_ORDER)])
	return [known; unknown]
end

# final_dispatch_decisions/transactions for one case, both filtered to time_range by their own MTU
# column ("mtu" / "Market Time Unit") - matches MarketDataStorage.CalculateEconomicIndicators' own
# scoping so the two storage-revenue numbers are directly comparable.
function LoadCaseData(case_paths, case, time_range)
	fdd = PostAnalysisCommon.LoadCaseFile(case_paths, case, "final_dispatch_decisions.xlsx")
	tx = PostAnalysisCommon.LoadCaseFile(case_paths, case, "transactions.xlsx")
	fdd = fdd[(time_range.start .<= fdd.mtu .<= time_range.stop), :]
	tx = tx[(time_range.start .<= tx[!, "Market Time Unit"] .<= time_range.stop), :]
	return (fdd, tx)
end

# MarketDataStorage.CalculateEconomicIndicators' own definition, reproduced directly against
# final_dispatch_decisions rather than by calling it, since that function also recomputes several
# other indicators (agent quantities, SEW, ...) this module has no use for.
FinalPriceConventionRevenue(fdd) = sum(skipmissing((fdd.StorageDischarge .- fdd.StorageCharge) .* fdd.FinalAuctionPrice))

# Sum of every recorded Storage transaction's own Payments/Revenues (€) - each one already priced
# at whatever that specific clearing's own settlement price was, so this is genuinely what storage
# was paid/charged across its whole trading history for these MTUs, not an approximation.
TrueCumulativeStorageRevenue(tx) = sum(tx[tx.Agent .== "Storage", "Payments/Revenues (€)"])

function Reconcile(case_paths, case, time_range)
	(fdd, tx) = LoadCaseData(case_paths, case, time_range)
	storage_tx = tx[tx.Agent .== "Storage", :]

	final_price = FinalPriceConventionRevenue(fdd)
	true_cumulative = TrueCumulativeStorageRevenue(tx)
	net_final_position = sum(skipmissing(fdd.StorageDischarge .- fdd.StorageCharge))
	gross_traded_volume = sum(abs.(storage_tx[!, "Quantity (MWh)"]))

	return (
		Case=case,
		FinalPriceConventionRevenue=final_price,
		TrueCumulativeRevenue=true_cumulative,
		Delta=true_cumulative - final_price,
		DeltaPct=final_price == 0 ? NaN : 100 * (true_cumulative - final_price) / final_price,
		NetFinalPositionMWh=net_final_position,
		GrossTradedVolumeMWh=gross_traded_volume,
		NStorageTrades=nrow(storage_tx),
	)
end

# Per-MTU breakdown for one case, ranked by |true cumulative - final-price| descending - the
# concrete "why do these differ" evidence: a big positive delta means storage earned much more from
# its actual sequence of trades than the final settlement price alone would suggest (typical of
# longer look-aheads, where many re-clearings smooth out into a net-favorable trading history); a
# big negative delta (rare, but see the fixed_36 high-storage case) means the opposite - a large,
# early, capacity-capped trade got locked in at a price the market later drifted away from before
# that MTU had its final auction, with storage never getting the chance to trade again at the new
# price.
function MostDivergentMTUs(case_paths, case, time_range; top_n=15)
	(fdd, tx) = LoadCaseData(case_paths, case, time_range)
	storage_tx = tx[tx.Agent .== "Storage", :]

	by_mtu = combine(groupby(storage_tx, "Market Time Unit"),
		"Payments/Revenues (€)" => sum => :TrueCumulativeRevenue,
		"Quantity (MWh)" => (q -> sum(abs.(q))) => :GrossTradedVolumeMWh,
		nrow => :NTrades,
	)

	fdd_slim = rename(fdd[!, [:mtu, :FinalAuctionPrice, :StorageCharge, :StorageDischarge]], :mtu => "Market Time Unit")
	fdd_slim.FinalPriceConventionRevenue = (fdd_slim.StorageDischarge .- fdd_slim.StorageCharge) .* fdd_slim.FinalAuctionPrice
	fdd_slim.NetFinalPositionMWh = fdd_slim.StorageDischarge .- fdd_slim.StorageCharge

	merged = innerjoin(by_mtu, fdd_slim, on="Market Time Unit")
	merged.Delta = merged.TrueCumulativeRevenue .- merged.FinalPriceConventionRevenue

	sorted = sort(merged, :Delta, by=abs, rev=true)
	n = min(top_n, nrow(sorted))
	return sorted[1:n, ["Market Time Unit", "NTrades", "GrossTradedVolumeMWh", "NetFinalPositionMWh", "FinalAuctionPrice", "FinalPriceConventionRevenue", "TrueCumulativeRevenue", "Delta"]]
end

function SummaryPlot(summary_df, cases, analysis_dir_path)
	x = 1:length(cases)
	p = Plots.plot(xlabel="Case", ylabel="Storage Revenue (€)", title="Storage revenue: final-price convention vs true cumulative",
		xticks=(x, cases), xrotation=30, legend=:topright, size=(900, 550), left_margin=10Plots.mm, bottom_margin=25Plots.mm)
	Plots.bar!(p, x .- 0.15, summary_df.FinalPriceConventionRevenue, bar_width=0.3, label="Final-price convention")
	Plots.bar!(p, x .+ 0.15, summary_df.TrueCumulativeRevenue, bar_width=0.3, label="True cumulative (sum of actual trades)")
	display(p)
	savefig(p, "$analysis_dir_path/storage_revenue_reconciliation.png")
end

function PerformAnalysis(case_paths=DEFAULT_CASE_PATHS; time_range=PostAnalysisCommon.DEFAULT_TIME_RANGE, top_n_divergent=15, output_base=PostAnalysisCommon.NewAnalysisOutputDir(case_paths; label="storage_revenue_reconciliation"))

	analysis_dir_path = "$output_base/storage_revenue_reconciliation"
	PostAnalysisCommon.CleanDirectory(analysis_dir_path)

	cases = OrderedCases(case_paths)

	summary_df = DataFrame([Reconcile(case_paths, case, time_range) for case in cases])
	println(summary_df)

	divergent_sheets = Vector{Pair{String,DataFrame}}([("summary" => summary_df)])
	for case in cases
		# xlsx sheet names can't exceed 31 chars or contain most punctuation - keep it short and safe
		sheet_name = "mtu_" * replace(case, r"[^A-Za-z0-9]" => "_")[1:min(end, 27)]
		push!(divergent_sheets, sheet_name => MostDivergentMTUs(case_paths, case, time_range; top_n=top_n_divergent))
	end

	XLSX.writetable("$analysis_dir_path/storage_revenue_reconciliation.xlsx", divergent_sheets...; overwrite=true)
	println("saved: $analysis_dir_path/storage_revenue_reconciliation.xlsx")

	SummaryPlot(summary_df, cases, analysis_dir_path)

	return summary_df
end

end;

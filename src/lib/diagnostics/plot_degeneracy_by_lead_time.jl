# Plots a DegeneracyScan combined summary (degeneracy_summary.xlsx) pooled by lead_time (= the
# traded MTU minus the auction's own clearing MTU): one line per variable family plus an overall
# line, showing the non-unique rate at each lead time across every scanned auction. Generalizes
# the ad-hoc "degenerate rate by lead time" investigation (see
# results/ad_hoc/1790333971_degeneracy_and_alternate_optima_findings.txt, Finding 6) into a
# reusable module. Like PlotDegeneracyHeatmap, its x-axis is bounded by the market's window
# length regardless of how many auctions were scanned, so it's the one view in this set
# guaranteed to stay readable at any scale - the recommended companion view for a
# DegeneracyScan.RunScan :full_period scan. Same output shape as the other diagnostics plots: a
# PNG alongside an XLSX of the plotted values.

module PlotDegeneracyByLeadTime

using Plots, DataFrames, XLSX, Statistics

# fixed family -> color, consistent with PlotDegeneracySingleAuction's ENTITY_COLORS palette
# family (not asset) choices where they overlap
const FAMILY_COLORS = [
	"Qd" => "#008300",
	"Qg" => "#2a78d6",
	"Qg_adj" => "#6da7ec",
	"Qch" => "#4a3aa7",
	"Qdis" => "#e34948",
	"SOC" => "#eda100",
]
const OVERALL_COLOR = "#1a1a1a"

asint(x) = x isa AbstractString ? parse(Int, x) : Int(x)
asbool(x) = x isa AbstractString ? parse(Bool, x) : Bool(x)

function RatesByLeadTime(summary_path)
	df = DataFrame(XLSX.readtable(summary_path, "data"))
	df.non_unique = asbool.(df.non_unique)
	df.mtu = asint.(df.mtu)
	df.var_mtu = asint.(df.var_mtu)
	df.lead_time = df.var_mtu .- df.mtu

	overall = combine(groupby(df, :lead_time), :non_unique => mean => :rate, nrow => :n)
	overall.family .= "Overall"
	by_family = combine(groupby(df, [:family, :lead_time]), :non_unique => mean => :rate, nrow => :n)

	rates = sort(vcat(overall[:, [:family, :lead_time, :rate, :n]], by_family), [:family, :lead_time])
	n_auctions = length(unique(df.mtu))
	return (rates=rates, n_auctions=n_auctions)
end

function PerformAnalysis(summary_path, analysis_dir_path=dirname(summary_path))
	mkpath(analysis_dir_path)
	(rates, n_auctions) = RatesByLeadTime(summary_path)
	PlotRatesByLeadTime(rates, n_auctions, analysis_dir_path)
	WriteRatesTable(rates, analysis_dir_path)
	return rates
end

function PlotRatesByLeadTime(rates, n_auctions, analysis_dir_path)
	first_lt, last_lt = extrema(rates.lead_time)
	p = Plots.plot(xlabel="Lead time (MTU past the auction's own clearing MTU)", ylabel="Non-unique rate (%)",
					title="Non-Unique Rate by Lead Time - $n_auctions Auctions Pooled",
					xticks=first_lt:3:last_lt, ylims=(0, 100), legend=:outertopright,
					grid=:y, framestyle=:axes, size=(1100, 600), left_margin=10Plots.mm, bottom_margin=8Plots.mm)

	for (fam, color) in FAMILY_COLORS
		sub = sort(filter(r -> r.family == fam, rates), :lead_time)
		isempty(sub) && continue
		Plots.plot!(p, sub.lead_time, sub.rate .* 100, label=fam, color=color, linewidth=2, marker=:circle, markersize=3)
	end

	overall = sort(filter(r -> r.family == "Overall", rates), :lead_time)
	Plots.plot!(p, overall.lead_time, overall.rate .* 100, label="Overall", color=OVERALL_COLOR, linewidth=3, linestyle=:dash)

	savefig(p, "$analysis_dir_path/non_unique_rate_by_lead_time.png")
end

function WriteRatesTable(rates, analysis_dir_path)
	wide = unstack(rates, :lead_time, :family, :rate)
	sort!(wide, :lead_time)
	XLSX.writetable("$analysis_dir_path/non_unique_rate_by_lead_time.xlsx", "data" => wide, "long" => rates; overwrite=true)
end

end;

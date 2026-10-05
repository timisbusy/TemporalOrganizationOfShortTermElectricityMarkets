# Plots a DegeneracyScan combined summary (degeneracy_summary.xlsx) as a heatmap: auction
# clearing MTU on the x-axis, lead_time (= the traded MTU minus the auction's own clearing MTU,
# bounded by the market's window length regardless of how many auctions were scanned) on the
# y-axis, cell color = count of non-unique variables. Unlike PlotDegeneracyByMTU's one-line-per-
# auction view (which only stays legible for small scans), this generalizes to any scan length -
# it's the recommended view for a DegeneracyScan.RunScan :full_period scan. Same output shape as
# the other diagnostics plots: a PNG alongside an XLSX of the plotted values.

module PlotDegeneracyHeatmap

using Plots, DataFrames, XLSX

asint(x) = x isa AbstractString ? parse(Int, x) : Int(x)
asbool(x) = x isa AbstractString ? parse(Bool, x) : Bool(x)

function CountsByAuctionAndLeadTime(summary_path)
	df = DataFrame(XLSX.readtable(summary_path, "data"))
	df.non_unique = asbool.(df.non_unique)
	df.mtu = asint.(df.mtu)
	df.var_mtu = asint.(df.var_mtu)
	df.lead_time = df.var_mtu .- df.mtu
	counts = combine(groupby(df, [:mtu, :lead_time]), :non_unique => sum => :n_non_unique, nrow => :n_variables)
	return sort(counts, [:mtu, :lead_time])
end

function PerformAnalysis(summary_path, analysis_dir_path=dirname(summary_path))
	mkpath(analysis_dir_path)
	counts = CountsByAuctionAndLeadTime(summary_path)
	PlotHeatmap(counts, analysis_dir_path)
	WriteCountsTable(counts, analysis_dir_path)
	return counts
end

function PlotHeatmap(counts, analysis_dir_path)
	auctions = sort(unique(counts.mtu))
	lead_times = sort(unique(counts.lead_time))
	first_auction, last_auction = first(auctions), last(auctions)

	matrix = fill(NaN, length(lead_times), length(auctions))
	for r in eachrow(counts)
		i = findfirst(==(r.lead_time), lead_times)
		j = findfirst(==(r.mtu), auctions)
		matrix[i, j] = r.n_non_unique
	end

	width = max(1000, round(Int, 1.5 * length(auctions)))
	p = Plots.heatmap(auctions, lead_times, matrix,
					xlabel="Auction clearing MTU", ylabel="Lead time (MTU past the auction's own clearing MTU)",
					title="Non-Unique Variables by Auction x Lead Time - $(length(auctions)) Auctions (MTU $first_auction-$last_auction)",
					color=cgrad(:Blues), colorbar_title="Non-unique variables",
					size=(width, 600), left_margin=12Plots.mm, bottom_margin=8Plots.mm)
	savefig(p, "$analysis_dir_path/non_unique_variables_heatmap.png")
end

function WriteCountsTable(counts, analysis_dir_path)
	wide = unstack(counts, :lead_time, :mtu, :n_non_unique)
	rename!(wide, Dict(n => Symbol("auction_$n") for n in names(wide) if n != "lead_time"))
	sort!(wide, :lead_time)
	XLSX.writetable("$analysis_dir_path/non_unique_variables_heatmap.xlsx", "data" => wide; overwrite=true)
end

end;

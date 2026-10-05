# Plots a DegeneracyScan combined summary (degeneracy_summary.xlsx): one point per scanned auction
# showing its total count of non-unique variables, restricted to the same families as
# PlotDegeneracySingleAuction's single-auction plots (Qg, Qd, Qch, Qdis) so the two views agree -
# Qg_adj is excluded (tied to Qg by an equality constraint, so it would double count), and so is SOC
# (a state, not a traded quantity). Qd_adj is assumed already excluded from the summary itself (see
# DegeneracyScan.RunScan's exclude_prefixes). Same output shape as the post_analysis modules: a PNG
# alongside an XLSX of the plotted values.

module PlotDegeneracyByAuction

using Plots, DataFrames, XLSX

const TRADED_FAMILIES = ["Qg", "Qd", "Qch", "Qdis"]

asint(x) = x isa AbstractString ? parse(Int, x) : Int(x)
asbool(x) = x isa AbstractString ? parse(Bool, x) : Bool(x)

function CountsByAuction(summary_path)
	df = DataFrame(XLSX.readtable(summary_path, "data"))
	df.non_unique = asbool.(df.non_unique)
	df.mtu = asint.(df.mtu)
	df = df[in.(df.family, Ref(TRADED_FAMILIES)), :]
	counts = combine(groupby(df, :mtu), :non_unique => sum => :n_non_unique, nrow => :n_variables)
	return sort(counts, :mtu)
end

function PerformAnalysis(summary_path, analysis_dir_path=dirname(summary_path))
	mkpath(analysis_dir_path)
	counts = CountsByAuction(summary_path)
	PlotByAuction(counts, analysis_dir_path)
	WriteCountsTable(counts, analysis_dir_path)
	return counts
end

# Spaces xticks so a scan of any length (24 auctions for a one-day sample, ~700 for a
# full-period scan) ends up with roughly target_ticks labels instead of an unreadably dense
# (small scans) or absent (large scans, under the old hardcoded step of 2) set of ticks.
xtick_step(first_a, last_a; target_ticks=40) = max(2, round(Int, (last_a - first_a) / target_ticks))

function PlotByAuction(counts, analysis_dir_path)
	first_auction, last_auction = first(counts.mtu), last(counts.mtu)
	width = max(1000, 2 * length(counts.mtu))
	p = Plots.plot(counts.mtu, counts.n_non_unique,
					xlabel="Auction MTU", ylabel="Non-unique variables",
					title="Non-Unique Variables by Auction - MTU $first_auction-$last_auction",
					marker=:circle, markersize=4, linewidth=2, color="#2a78d6", label=false,
					xticks=first_auction:xtick_step(first_auction, last_auction):last_auction, ylims=(0, maximum(counts.n_non_unique) * 1.1),
					grid=:y, framestyle=:axes, size=(width, 600), left_margin=10Plots.mm, bottom_margin=8Plots.mm)
	savefig(p, "$analysis_dir_path/non_unique_variables_by_auction.png")
end

function WriteCountsTable(counts, analysis_dir_path)
	XLSX.writetable("$analysis_dir_path/non_unique_variables_by_auction.xlsx", "data" => counts; overwrite=true)
end

end;

# Plots a DegeneracyScan combined summary (degeneracy_summary.xlsx): one point per scanned auction
# showing its total count of degenerate variables, restricted to the same families as
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
	df.degenerate = asbool.(df.degenerate)
	df.mtu = asint.(df.mtu)
	df = df[in.(df.family, Ref(TRADED_FAMILIES)), :]
	counts = combine(groupby(df, :mtu), :degenerate => sum => :n_degenerate, nrow => :n_variables)
	return sort(counts, :mtu)
end

function PerformAnalysis(summary_path, analysis_dir_path=dirname(summary_path))
	mkpath(analysis_dir_path)
	counts = CountsByAuction(summary_path)
	PlotByAuction(counts, analysis_dir_path)
	WriteCountsTable(counts, analysis_dir_path)
	return counts
end

function PlotByAuction(counts, analysis_dir_path)
	first_auction, last_auction = first(counts.mtu), last(counts.mtu)
	p = Plots.plot(counts.mtu, counts.n_degenerate,
					xlabel="Auction MTU", ylabel="Degenerate variables",
					title="Degenerate Variables by Auction - MTU $first_auction-$last_auction",
					marker=:circle, markersize=4, linewidth=2, color="#2a78d6", label=false,
					xticks=first_auction:2:last_auction, ylims=(0, maximum(counts.n_degenerate) * 1.1),
					grid=:y, framestyle=:axes, size=(1000, 600), left_margin=10Plots.mm, bottom_margin=8Plots.mm)
	savefig(p, "$analysis_dir_path/degenerate_variables_by_auction.png")
end

function WriteCountsTable(counts, analysis_dir_path)
	XLSX.writetable("$analysis_dir_path/degenerate_variables_by_auction.xlsx", "data" => counts; overwrite=true)
end

end;

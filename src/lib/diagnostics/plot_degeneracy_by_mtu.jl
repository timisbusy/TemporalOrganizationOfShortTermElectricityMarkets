# Plots a DegeneracyScan combined summary (degeneracy_summary.xlsx): one line per scanned auction
# showing how many decision variables are non-unique (have alternate optimal values) for each MTU
# being traded (the MTU the variable's energy is for, not the auction's own clearing MTU), plus the
# mean across the auctions that cover each MTU. If a solar availability DataFrame (columns :mtu,
# :solar_mwh) is given it is
# drawn in a second panel sharing the x-axis - a separate panel rather than a second y-axis, since
# the two measures have different units. Same output shape as the post_analysis modules: a PNG
# alongside an XLSX of the plotted values.
#
# Best suited to small scans (roughly <=30 scanned auctions, e.g. the original one-day-sample
# use of DegeneracyScan.RunScan) - it draws one line per auction, and the 10-step AUCTION_RAMP
# color gradient can't visually discriminate many more than that. For a DegeneracyScan.RunScan
# :full_period scan (hundreds of auctions), use PlotDegeneracyHeatmap or
# PlotDegeneracyByLeadTime instead - both plot against lead_time (bounded by the market's
# window length) rather than one line per auction, so they stay readable at any scan length.

module PlotDegeneracyByMTU

using Plots, DataFrames, XLSX, Statistics

# blue sequential steps 250 -> 700, so the auctions read as an ordered series (earlier = lighter)
const AUCTION_RAMP = ["#86b6ef", "#6da7ec", "#5598e7", "#3987e5", "#2a78d6", "#256abf", "#1c5cab", "#184f95", "#104281", "#0d366b"]
const SOLAR_COLOR = "#eb6834"

asint(x) = x isa AbstractString ? parse(Int, x) : Int(x)
asbool(x) = x isa AbstractString ? parse(Bool, x) : Bool(x)

function CountsByTradedMTU(summary_path)
	df = DataFrame(XLSX.readtable(summary_path, "data"))
	df.non_unique = asbool.(df.non_unique)
	df.mtu = asint.(df.mtu)
	df.var_mtu = asint.(df.var_mtu)
	counts = combine(groupby(df, [:mtu, :var_mtu]), :non_unique => sum => :n_non_unique, nrow => :n_variables)
	return sort(counts, [:mtu, :var_mtu])
end

function PerformAnalysis(summary_path, analysis_dir_path=dirname(summary_path); solar=nothing)
	mkpath(analysis_dir_path)
	counts = CountsByTradedMTU(summary_path)
	PlotByTradedMTU(counts, analysis_dir_path; solar=solar)
	WriteCountsTable(counts, analysis_dir_path; solar=solar)
	return counts
end

function PlotByTradedMTU(counts, analysis_dir_path; solar=nothing)
	auctions = sort(unique(counts.mtu))
	first_auction, last_auction = first(auctions), last(auctions)
	first_traded, last_traded = extrema(counts.var_mtu)
	n_variables = maximum(counts.n_variables)
	with_solar = solar !== nothing

	p = Plots.plot(xlabel=with_solar ? "" : "MTU for which energy is traded",
					ylabel="Non-unique variables (of $n_variables per MTU)",
					title="Non-Unique Variables by Traded MTU - $(length(auctions)) Auctions (MTU $first_auction-$last_auction)",
					xticks=first_traded:6:last_traded, xlims=(first_traded - 0.5, last_traded + 0.5),
					yticks=0:3:n_variables, ylims=(0, n_variables), legend=:topright,
					left_margin=10Plots.mm, bottom_margin=with_solar ? 2Plots.mm : 8Plots.mm)

	for auction in auctions
		sub = filter(r -> r.mtu == auction, counts)
		Plots.plot!(p, sub.var_mtu, sub.n_non_unique, label=false, linewidth=2, alpha=0.85,
					line_z=fill(auction, nrow(sub)), color=cgrad(AUCTION_RAMP), clims=(first_auction, last_auction),
					colorbar_title="Auction clearing MTU")
	end

	mean_by_mtu = sort(combine(groupby(counts, :var_mtu), :n_non_unique => mean => :mean_non_unique), :var_mtu)
	Plots.plot!(p, mean_by_mtu.var_mtu, mean_by_mtu.mean_non_unique,
				label="Mean across auctions covering each MTU", color=:black, linewidth=3, linestyle=:dash)

	if with_solar
		window = solar[first_traded .<= solar.mtu .<= last_traded, :]
		p_solar = Plots.plot(window.mtu, window.solar_mwh, label=false, color=SOLAR_COLOR, linewidth=2, fillrange=0, fillalpha=0.25,
							xlabel="MTU for which energy is traded", ylabel="Available solar (MWh)",
							xticks=first_traded:6:last_traded, xlims=(first_traded - 0.5, last_traded + 0.5),
							left_margin=10Plots.mm, bottom_margin=8Plots.mm)
		# invisible colorbar (white-on-white, blank labels) so this panel reserves the same right-hand space as the top panel's real one and the two x-axes line up
		Plots.plot!(p_solar, [first_traded], [0.0], label=false, line_z=[0.0], color=cgrad([:white, :white]), clims=(0, 1),
					colorbar=true, colorbar_title=" ", colorbar_ticks=:none)
		p = Plots.plot(p, p_solar, layout=grid(2, 1, heights=[0.68, 0.32]), size=(1000, 850))
	else
		Plots.plot!(p, size=(1000, 600))
	end

	savefig(p, "$analysis_dir_path/non_unique_variables_by_traded_mtu$(with_solar ? "_with_solar" : "").png")
end

function WriteCountsTable(counts, analysis_dir_path; solar=nothing)
	wide = unstack(counts, :var_mtu, :mtu, :n_non_unique)
	rename!(wide, Dict(n => Symbol("auction_$n") for n in names(wide) if n != "var_mtu"))
	sort!(wide, :var_mtu)
	if solar === nothing
		XLSX.writetable("$analysis_dir_path/non_unique_variables_by_traded_mtu.xlsx", "data" => wide; overwrite=true)
	else
		XLSX.writetable("$analysis_dir_path/non_unique_variables_by_traded_mtu.xlsx", "data" => wide, "solar" => solar; overwrite=true)
	end
end

end;

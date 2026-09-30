# Plots one auction's DegeneracyScan sweep (degeneracy_{market}_{mtu}.xlsx): for each MTU being
# traded, one line per agent showing the single-variable range (hi - lo, MWh) of that agent's
# decision variable for that MTU - generators (Qg), demand segments (Qd), storage charge (Qch) and
# storage discharge (Qdis). SOC is excluded (it's a state, not a traded quantity), as is Qg_adj,
# which is tied to Qg by an equality constraint and always has the identical range as Qg. Same
# output shape as the post_analysis modules: a PNG alongside an XLSX of the plotted values.

module PlotDegeneracySingleAuction

using Plots, DataFrames, XLSX

include("../post_analysis/agent_renaming.jl")

const SURFACE = "#fcfcfb"
# fixed entity -> categorical slot (blue, orange, aqua, yellow, magenta, green, violet, red), so an agent keeps its color across auctions
const ENTITY_COLORS = [
	"3G_Base" => "#2a78d6",
	"4G_Shoulder" => "#eb6834",
	"5G_Peak" => "#1baf7a",
	"6G_Wind" => "#eda100",
	"7G_Solar" => "#e87ba4",
	"2D_ModerateBid" => "#008300",
	"Storage Charge" => "#4a3aa7",
	"Storage Discharge" => "#e34948",
	"1D_HighBid" => "#898781",
]

asint(x) = x isa AbstractString ? parse(Int, x) : Int(x)
asfloat(x) = x isa AbstractString ? parse(Float64, x) : Float64(x)

function EntityName(family, asset)
	family == "Qch" && return "Storage Charge"
	family == "Qdis" && return "Storage Discharge"
	return String(asset)
end

DisplayLabel(entity) = startswith(entity, "Storage") ? entity : AgentRenaming.DisplayName(entity)

function RangesByEntityAndMTU(auction_path)
	df = DataFrame(XLSX.readtable(auction_path, "data"))
	df = df[in.(df.family, Ref(["Qg", "Qd", "Qch", "Qdis"])), :]
	df.width = asfloat.(df.width)
	df.var_mtu = asint.(df.var_mtu)
	df.entity = [EntityName(f, a) for (f, a) in zip(df.family, df.asset)]
	df = df[.!isnan.(df.width), :]
	ranges = combine(groupby(df, [:var_mtu, :entity]), :width => sum => :range_mwh)
	return ranges, asint(first(DataFrame(XLSX.readtable(auction_path, "data")).mtu))
end

function PerformAnalysis(auction_path, analysis_dir_path=dirname(auction_path); value_tol=0.01)
	mkpath(analysis_dir_path)
	ranges, auction = RangesByEntityAndMTU(auction_path)
	mtus = sort(unique(ranges.var_mtu))
	entities = [e for (e, _) in ENTITY_COLORS if any(r -> r.entity == e && r.range_mwh > value_tol, eachrow(ranges))]
	if isempty(entities)
		println("no degenerate variables in auction $auction - nothing to plot")
		return ranges
	end

	matrix = zeros(length(mtus), length(entities))
	for r in eachrow(ranges)
		j = findfirst(==(r.entity), entities)
		j === nothing && continue
		matrix[findfirst(==(r.var_mtu), mtus), j] = r.range_mwh
	end

	PlotRangeLines(mtus, matrix, entities, auction, analysis_dir_path)
	WriteRangesTable(mtus, matrix, entities, auction, analysis_dir_path)
	return ranges
end

const Y_MAX_MWH = 12000

function PlotRangeLines(mtus, matrix, entities, auction, analysis_dir_path)
	p = Plots.plot(xlabel="MTU for which energy is traded", ylabel="Single-variable range (MWh)",
					title="Alternate-Optimal Range by Traded MTU - Auction at MTU $auction",
					xticks=first(mtus):3:last(mtus), ylims=(0, Y_MAX_MWH), yformatter=:plain,
					legend=:outertopright, grid=:y, framestyle=:axes,
					size=(1100, 600), left_margin=10Plots.mm, bottom_margin=8Plots.mm)
	for (j, e) in enumerate(entities)
		Plots.plot!(p, mtus, matrix[:, j], label=DisplayLabel(e), color=Dict(ENTITY_COLORS)[e],
					marker=:circle, markersize=3, linewidth=2)
	end
	savefig(p, "$analysis_dir_path/single_auction_ranges_mtu$(auction).png")
end

function WriteRangesTable(mtus, matrix, entities, auction, analysis_dir_path)
	df = DataFrame(traded_mtu=mtus)
	for (j, e) in enumerate(entities)
		df[!, Symbol(DisplayLabel(e))] = matrix[:, j]
	end
	XLSX.writetable("$analysis_dir_path/single_auction_ranges_mtu$(auction).xlsx", "data" => df; overwrite=true)
end

end;

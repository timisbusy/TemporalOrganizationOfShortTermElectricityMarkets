# Generation-stack plots for individual auctions, rather than the delivered/final dispatch that
# plot_generation_stack.jl (src/lib/plots/market_results/) charts. Each market clearing decides a
# dispatch plan for its own optimization window at the moment it's held - later clearings for the
# same delivered MTUs can revise that plan (see LatestMarketModel's Qg_adj/Qd_adj adjustments).
# This module snapshots a handful of specific clearings (by the MTU at which they were held) and
# plots exactly what each one decided over its own window, so a set of consecutive auctions'
# evolving plans for the same stretch of time can be compared side by side.

module PostAnalysisAuctionSnapshots

using Plots, DataFrames

include("./post_analysis_common.jl")
include("./agent_renaming.jl")

CASES = PostAnalysisCommon.CASES

# same stacking order/colors as PlotGenerationStack.plot (src/lib/plots/market_results/), and the
# same generator/demand agent lists as PostAnalysisCommon.DEFAULT_AGENT_MAP - hardcoded here
# (rather than reading DEFAULT_AGENT_MAP's own AgentTypeEnum-keyed dict) because that dict's keys
# come from PostAnalysisCommon's own include of helpers.jl; a second, separate include of
# helpers.jl in this module would define a distinct, non-`==` AgentTypeEnum instance and break the
# lookup. Every other module in this suite hardcodes these same lists for the same reason.
GENERATOR_STACK_ORDER = ["3G_Base", "4G_Shoulder", "5G_Peak", "6G_Wind", "7G_Solar"]
DEMAND_AGENTS = ["1D_HighBid", "2D_ModerateBid"]
# Solar and Storage Discharge were both warm/orange tones (:coral, :orange) and hard to tell apart
# in the stack - Solar is now :gold, Storage Discharge :purple, clearly distinct from each other
# and from Wind's pale :lightyellow.
GEN_COLORS = [:steelblue, :lightgreen, :red, :lightyellow, :gold, :purple]

# clearing MTUs to snapshot by default - two sets of three consecutive hourly clearings, each
# starting at a Fixed day-ahead auction (MTU % 24 == 12, the clockTimeBegin of Fixed1of24,
# fixed_laura.yaml's full 36-MTU window): MTU 84-86 (day 3) and MTU 660-662 (day 27).
DEFAULT_CLEARING_MTUS = [84, 85, 86, 660, 661, 662]

CaseSlug(case) = lowercase(replace(case, " " => "_"))

function PerformAnalysis(case_paths; output_base=PostAnalysisCommon.NewAnalysisOutputDir(case_paths), clearing_mtus=DEFAULT_CLEARING_MTUS)

	analysis_dir_path = "$output_base/auction_snapshots"
	PostAnalysisCommon.CleanDirectory(analysis_dir_path)

	raw_dispatch_prefixes = PostAnalysisCommon.DiscoverRawDispatchPrefixes(case_paths)

	for case in CASES
		prefix = raw_dispatch_prefixes[case]
		for clearing_mtu in clearing_mtus
			dvs = PostAnalysisCommon.LoadFile("$(prefix)$(clearing_mtu).xlsx")
			PlotAuctionStack(dvs, case, clearing_mtu, analysis_dir_path)
		end
	end
end

function PlotAuctionStack(dvs, case, clearing_mtu, analysis_dir_path)
	dvs = sort(dvs, :mtu)
	window = dvs.mtu

	stack_matrix = zeros(length(GENERATOR_STACK_ORDER), length(window))
	for (i, g) in enumerate(GENERATOR_STACK_ORDER)
		stack_matrix[i, :] = dvs[!, g]
	end

	discharge_vec = dvs[!, :StorageDischarge]
	if maximum(discharge_vec) > 0.1
		stack_matrix = vcat(stack_matrix, discharge_vec')
		labels = [AgentRenaming.DisplayName.(GENERATOR_STACK_ORDER); "Storage Discharge"]
	else
		labels = AgentRenaming.DisplayName.(GENERATOR_STACK_ORDER)
	end

	total_demand = sum(dvs[!, d] for d in DEMAND_AGENTS)
	charging_vec = dvs[!, :StorageCharge]
	max_y = maximum(total_demand .+ charging_vec) * 1.6

	p = Plots.plot(xlabel="MTU", ylabel="Dispatched Production (MWh)",
			title="$case - Auction Cleared at MTU $clearing_mtu",
			legend=:topright,
			ylims=(0, max_y), size=(1000,1000),
			left_margin=16Plots.mm, bottom_margin=10Plots.mm)

	for i in 1:size(stack_matrix, 1)
		if i == 1
			Plots.plot!(p, window, stack_matrix[i, :],
				fillrange=0, label=labels[i],
				color=GEN_COLORS[i], alpha=0.8, linewidth=0)
		else
			cumsum_prev = vec(sum(stack_matrix[1:i-1, :], dims=1))
			cumsum_curr = vec(sum(stack_matrix[1:i, :], dims=1))
			Plots.plot!(p, window, cumsum_curr,
				fillrange=cumsum_prev, label=labels[i],
				color=GEN_COLORS[i], alpha=0.8, linewidth=0)
		end
	end

	Plots.plot!(p, window, total_demand .+ charging_vec,
		label="Demand + Charging", color=:black, lw=3, ls=:dash)

	display(p)
	savefig(p, "$analysis_dir_path/auction_stack_$(CaseSlug(case))_mtu$(clearing_mtu).png")
end

end;

# Validation run with KPIs as defined by Laura


module PostAnalysisLauraKPIs

using Plots
using JuMP
using Statistics
using DataFrames
using XLSX
using Distributions
using Latexify

include("../helpers.jl")
using .Helpers.HelperModelResults

include("../output_data/market_data_storage.jl")


fixed_path_base = "results/1788950433_laura_final_check_fixed"
rolling_path_base = "results/1788950636_laura_final_check_rolling"
results_path_base = "results/validation_results"


analysis_dir_path = "$results_path_base/validation"

dispatch_decision_paths = Dict{String,String}(
    "Fixed Horizon" => "$fixed_path_base/final_dispatch_decisions.xlsx",
    "Rolling Horizon" => "$rolling_path_base/final_dispatch_decisions.xlsx",
)

mtu_economic_indicator_paths = Dict{String,String}(
    "Fixed Horizon" => "$fixed_path_base/mtu_economic_results.xlsx",
    "Rolling Horizon" => "$rolling_path_base/mtu_economic_results.xlsx",
)


transaction_paths = Dict{String,String}(
	"Fixed Horizon" => "$fixed_path_base/transactions.xlsx",
	"Rolling Horizon" => "$rolling_path_base/transactions.xlsx",
)

# per-clearing RAW export prefix, used to read the executed price for each real MTU directly
# (see ExecutedPriceByMTU) rather than via transactions.xlsx, which only records a leg when an
# agent's adjustment is nonzero - a meaningful fraction of MTUs have zero adjustment from every
# agent, so a transactions.xlsx-based price lookup silently drops those MTUs.
raw_dispatch_prefix = Dict{String,String}(
	"Fixed Horizon" => "$fixed_path_base/RAW/decisionvariables_validate_laura_fixed_36_",
	"Rolling Horizon" => "$rolling_path_base/RAW/decisionvariables_validate_laura_rolling_36_",
)

cases = ["Fixed Horizon", "Rolling Horizon"]

# helpers

function CleanDirectory(path)
	mkpath(path)
end

function LoadFile(filepath)
    df = DataFrame(XLSX.readtable(filepath, "data"))
    return df
end

# executed price per real MTU, read directly from each clearing's own RAW export (the row where
# mtu == mtu_cleared is the hour it executed). Price is a property of the clearing itself, not
# of any one transaction, so this stays complete even for MTUs where every agent's adjustment
# happened to be zero - unlike pulling price from transactions.xlsx (see raw_dispatch_prefix
# above).
function ExecutedPriceByMTU(case)
	prefix = raw_dispatch_prefix[case]
	mtu = Int[]
	price = Float64[]
	for mtu_cleared in 12:672
		path = "$prefix$mtu_cleared.xlsx"
		isfile(path) || continue
		df = DataFrame(XLSX.readtable(path, "data"))
		push!(mtu, mtu_cleared)
		push!(price, df[df.mtu .== mtu_cleared, :price][1])
	end
	return DataFrame(mtu=mtu, price=price)
end

function LoadFiles(type)
	d = Dict{String,DataFrames.DataFrame}()
	file_collection = type == "transactions" ? transaction_paths : type == "dispatch_decisions" ? dispatch_decision_paths : type == "mtu_economic_indicators" ? mtu_economic_indicator_paths : "unrecognized"
	file_collection == "unrecognized" && throw("unrecognized file type: $type")
	for case in cases
		filepath = file_collection[case]
		d[case] = LoadFile(filepath)
	end
	return d
end


# runner

function PerformAnalysis()
	CleanDirectory(analysis_dir_path)

	transaction_files = LoadFiles("transactions")
	println("got transactions: $(keys(transaction_files))")
	final_dispatch_decision_files = LoadFiles("dispatch_decisions")
	println("got dispatch_decisions: $(keys(final_dispatch_decision_files))")

	agent_map = Dict{HelperModelResults.AgentTypeEnum, Vector{String}}(
		AGENT_GENERATOR => ["3G_Base","4G_Shoulder","5G_Peak","6G_Wind","7G_Solar"],
		AGENT_DEMAND => ["1D_HighBid","2D_ModerateBid"],
	)

	time_range = 12:672 # executed-hours range matching Laura's comparable_delivery_hours_override
	# (661 clearings, 12:672) - MTU 12 = day 0.5, MTU 672 = day 28.0, inclusive of both endpoints

	normalized_days = (time_range.stop - time_range.start + 1)/24 # 661 MTUs (inclusive) / 24 =
	# 27.5417 days - matches Laura's own reported "27.542 normalized days" exactly

	println(normalized_days)

	# accumulators - one DataFrame per KPI section, filled in across both cases below and
	# written out as sheets in a single xlsx at the end of PerformAnalysis
	economic_indicators_all = DataFrame()
	agent_indicators_all = DataFrame()
	gross_traded_volume_all = DataFrame()
	financial_revenue_all = DataFrame()
	imbalance_all = DataFrame(Case=String[], ImbalanceEnergy=Float64[])
	storage_summary_all = DataFrame()
	storage_revenue_all = DataFrame()
	storage_soc_losses_all = DataFrame(Case=String[], SOCEndOfHorizon=Float64[], TotalLosses=Float64[])

	for case in cases

	# SEW
	# Production Cost
	# Demand Utility
		# println(transactions)
		println("get economic indicators for: $case")

		# final_dispatch_decision_files/transaction_files are loaded straight from the exported xlsx,
		# which cover every clearing the run produced - for a fixed-horizon market that's well past
		# Laura's comparable 12:672 range (her simulation stops 12 clearings earlier than ours).
		# CalculateEconomicIndicators scopes both inputs to time_range itself, so passing the raw
		# loaded files through here is enough to keep SEW/Demand Utility/Production Costs comparable
		# to her "SOCIAL WELFARE" figures - those come from finalDispatchDecisions and each agent's
		# own bid price, not from transactions. Payments/Revenue/Surplus in agent_indicators below
		# are NOT comparable to her "Producer Revenues (Executed-only)" though: they're summed from
		# transactions, which (like Traded Volume) nets every adjustment leg from every clearing
		# that touched a delivered MTU, not just the one that actually executed it - see the
		# Executed-only Revenue/Payments block further down for the figures that do match her sheet.
		(economic_indicators, agent_indicators, transactions, finalDispatchDecisions, mtu_economic_indicators) = MarketDataStorage.CalculateEconomicIndicators(final_dispatch_decision_files[case],transaction_files[case],agent_map,time_range)
		println(economic_indicators)

		println("per day")

		daily_economic_indicators = economic_indicators ./ normalized_days

		println(daily_economic_indicators)

		economic_indicators[!, :Case] .= case
		economic_indicators[!, :Period] .= "Total"
		daily_economic_indicators[!, :Case] .= case
		daily_economic_indicators[!, :Period] .= "Per Day"
		economic_indicators_all = vcat(economic_indicators_all, economic_indicators, daily_economic_indicators; cols=:union)

	# Trading Volume
	# Quantity Delivered
	# Revenue/Profit (surplus)

		println("agents")

		println(agent_indicators)

		agent_indicators[!, :Case] .= case
		agent_indicators_all = vcat(agent_indicators_all, agent_indicators; cols=:union)

		traded_volume_symbol = Symbol("Traded Volume (MWh)")

		total_traded_volume = combine((agent_indicators[ [a in agent_map[HelperModelResults.AGENT_GENERATOR] for a in agent_indicators[!, :Agent]], :]), traded_volume_symbol => sum)
		println("Traded Volume (delivered MTUs only, capped by delivery MTU $(time_range.start):$(time_range.stop), gross across all clearings that touched them): $total_traded_volume")

		# Gross Traded Volume, computed to match Laura's calculate_generator_revenues_full (costs.jl):
		# sum(|adjustment|) across every hour of every clearing's full look-ahead window - so it
		# includes the speculative, never-delivered tail of each clearing's own look-ahead window.
		# This is a genuinely different quantity from the "executed-only" Traded Volume above; both
		# are kept so results stay comparable to Laura's "Producer Revenues (Executed-only)" and
		# "Total Financial Revenue (incl financial repositions)" sections respectively.
		#
		# No Clearing MTU filter is needed here: the experiment configs set lastAuctionMTU: 672, so
		# the exported run itself never contains a clearing outside 12:672 to begin with (verified -
		# transactions.xlsx's "Clearing MTU" column ranges exactly 12:672, 661 distinct clearings).
		# If fixed_path_base/rolling_path_base above ever point at a run without that cap, this
		# would need the Clearing MTU filter added back.
		gross_traded_gen = transaction_files[case][[a in agent_map[HelperModelResults.AGENT_GENERATOR] for a in transaction_files[case][!, :Agent]], :]
		quantity_symbol = Symbol("Quantity (MWh)")
		gross_traded_volume = combine(groupby(gross_traded_gen, :Agent), quantity_symbol => (q -> sum(abs.(q))) => :GrossTradedVolume)
		println("Gross Traded Volume (all clearings $(time_range.start):$(time_range.stop), full look-ahead window):")
		println(gross_traded_volume)

		gross_traded_volume[!, :Case] .= case
		gross_traded_volume_all = vcat(gross_traded_volume_all, gross_traded_volume; cols=:union)

		# Total Financial Revenue, matching Laura's "TOTAL FINANCIAL REVENUE (incl financial
		# repositions -> sum(q*price))" section: Net Revenue = sum(q*price) and Net Traded =
		# sum(q), both signed (not sum of |q|), over the same transactions as Gross Traded Volume
		# above. This - not agent_indicators' "Revenue (€)" from the main CalculateEconomicIndicators
		# call, which caps by delivery MTU rather than including each clearing's full window - is
		# the figure comparable to her sheet.
		price_symbol = Symbol("Price (€/MWh)")
		financial_revenue = combine(groupby(gross_traded_gen, :Agent),
			[quantity_symbol, price_symbol] => ((q, p) -> sum(q .* p)) => :NetRevenue,
			quantity_symbol => sum => :NetTraded,
		)
		println("Total Financial Revenue (all clearings $(time_range.start):$(time_range.stop), full look-ahead window):")
		println(financial_revenue)

		financial_revenue[!, :Case] .= case
		financial_revenue_all = vcat(financial_revenue_all, financial_revenue; cols=:union)
	end

	

	# Imbalance
		# defined by Laura as:
		# for the auction held in t_0
		# wind_delta = (Wind[t_0] - Wind_prev[t_0])
		# peak_delta = (Peak[t_0] - Peak_prev[t_0])
		# if abs(wind_delta) > atol && abs(peak_delta) > atol && sign(wind_delta) == -sign(peak_delta)
		# 	return sign(peak_delta) * min(abs(peak_delta), abs(wind_delta))
		# else
		# 	return 0.0
		# end
	for case in cases
		println("get imbalance energy for case: $case")
		last_auction_mtu = 672
		atol = 1e-6
		mtu1_dvs = final_dispatch_decision_files[case][ final_dispatch_decision_files[case][!,:mtu] .<= last_auction_mtu, :]
		imbalance_energy = 0.0
		for row in eachrow(mtu1_dvs)
			wind_delta = row["6G_Wind_adj"]
			peak_delta = row["5G_Peak_adj"]

			if abs(wind_delta) > atol && abs(peak_delta) > atol && sign(wind_delta) == -sign(peak_delta)
				imbalance = sign(peak_delta) * min(abs(peak_delta), abs(wind_delta))
				# signed sum, matching Laura's own label ("MWh, +up / -down") and her
				# sum(all_results[:imbalance_energy]) - using abs() here double-counted the
				# (rare) negative entries as positive, inflating the total by ~2x their magnitude
				imbalance_energy += imbalance
			end
		end

		println("Imbalance for case $case : $imbalance_energy")

		push!(imbalance_all, (Case=case, ImbalanceEnergy=imbalance_energy))
	end

	# Storage Charge/Discharge/Net/Throughput

	for case in cases
		println("storage results for case: $case")

		last_auction_mtu = 672
		mtu1_dvs = final_dispatch_decision_files[case][ final_dispatch_decision_files[case][!,:mtu] .<= last_auction_mtu, :]

		charge_total = combine(mtu1_dvs,:StorageCharge => sum)[1,1]
		discharge_total = combine(mtu1_dvs, :StorageDischarge => sum)[1,1]
		net_discharge_total = discharge_total - charge_total
		total_throughput = discharge_total + charge_total

		storage_df = DataFrame(ChargeTotal=[charge_total],DischargeTotal=[discharge_total],NetDischargeTotal=[net_discharge_total],TotalThroughput=[total_throughput])
		println(storage_df)

		per_day_storage_df = storage_df ./ normalized_days
		println("per day: ")
		println(per_day_storage_df)

		storage_df[!, :Case] .= case
		storage_df[!, :Period] .= "Total"
		per_day_storage_df[!, :Case] .= case
		per_day_storage_df[!, :Period] .= "Per Day"
		storage_summary_all = vcat(storage_summary_all, storage_df, per_day_storage_df; cols=:union)

		# Storage revenue, matching Laura's calculate_storage_revenue (costs.jl): discharge_mw*price
		# and charge_mw*price summed over EXECUTED hours only, using the price the clearing that
		# executed each MTU actually settled at - not the "Storage Revenue (€)" figure from
		# CalculateEconomicIndicators above, which nets quantity*price across every adjustment leg
		# from every clearing that ever touched an MTU (the same executed-vs-gross distinction as
		# generator Traded Volume). final_dispatch_decisions.xlsx doesn't carry price (it's dropped
		# in GetFinalDispatchDecisions); pulling it from transactions.xlsx instead was tried first
		# but silently drops any MTU where every agent's adjustment happened to be exactly zero
		# (~17% of MTUs in the rolling case) - so read it straight from each clearing's own RAW
		# export instead, where price is always present regardless of what actually traded.
		executed_price = ExecutedPriceByMTU(case)

		priced = innerjoin(mtu1_dvs[!, [:mtu, :StorageCharge, :StorageDischarge]], executed_price, on = :mtu)

		discharge_revenue = sum(priced.StorageDischarge .* priced.price)
		charging_cost = sum(priced.StorageCharge .* priced.price)
		net_storage_revenue = discharge_revenue - charging_cost
		avg_discharge_price = discharge_total > 0 ? discharge_revenue / discharge_total : 0.0
		avg_charge_price = charge_total > 0 ? charging_cost / charge_total : 0.0

		revenue_df = DataFrame(
			DischargeRevenue = [discharge_revenue], ChargingCost = [charging_cost],
			NetStorageRevenue = [net_storage_revenue],
			AvgDischargePrice = [avg_discharge_price], AvgChargePrice = [avg_charge_price],
		)
		println(revenue_df)

		revenue_df[!, :Case] .= case
		storage_revenue_all = vcat(storage_revenue_all, revenue_df; cols=:union)

		# SOC end of horizon and total round-trip losses, matching Laura's own summary fields.
		# Initial SOC is 0 for every case here (batteryStorage.initialSOC in the shared agent
		# config), so total losses reduce to charge - discharge - SOC gained over the horizon.
		soc_end_vec = final_dispatch_decision_files[case][final_dispatch_decision_files[case].mtu .== last_auction_mtu, :SOC]
		soc_end = length(soc_end_vec) > 0 ? soc_end_vec[1] : 0.0
		initial_soc = 0.0
		total_losses = charge_total - discharge_total - (soc_end - initial_soc)

		soc_df = DataFrame(SOCEndOfHorizon = [soc_end], TotalLosses = [total_losses])
		println(soc_df)

		push!(storage_soc_losses_all, (Case=case, SOCEndOfHorizon=soc_end, TotalLosses=total_losses))
	end

	# write every KPI section out as a sheet in one xlsx, alongside the fixed36h.png/rolling36h.png
	# plots this module doesn't produce itself (see PostAnalysisSolverComparison for those)
	kpi_path = "$analysis_dir_path/laura_kpi_validation.xlsx"
	XLSX.writetable(kpi_path,
		"economic_indicators" => economic_indicators_all,
		"agent_indicators" => agent_indicators_all,
		"gross_traded_volume" => gross_traded_volume_all,
		"total_financial_revenue" => financial_revenue_all,
		"imbalance" => imbalance_all,
		"storage_summary" => storage_summary_all,
		"storage_revenue" => storage_revenue_all,
		"storage_soc_losses" => storage_soc_losses_all;
		overwrite=true,
	)
	println("saved: $kpi_path")

end


end;
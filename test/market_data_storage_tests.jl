using DataFrames
using JuMP

include("../src/lib/market_clearers/clear_market.jl")
using .ClearMarket.MarketDataStorage
using .ClearMarket.LatestMarketModel

@testset "Market Data Storage 1" begin

	# Build a small rolling-horizon sequence of real, solved market clearings via
	# LatestMarketModel.build + optimize! + AddMarketResult!, rather than hand-building
	# MarketResult structs directly, so this exercises the real production path.
	#
	# One generator "G" (bidPrice 50, capacity well above demand) and one demand "D"
	# (bidPrice 100) with no storage capacity, cleared with a 3-MTU optimization window
	# and no look-ahead, so successive clearings overlap by two MTUs.

	demand_profile = DataFrame(mtu=0:20, Value=fill(5.0, 21))

	data = Dict{Symbol,Any}(
		:dispatchableGenerators => Dict{String,Any}("G" => Dict{String,Any}("bidPrice" => 50.0, "capacity" => 10.0, "rampRate" => 100.0, "initialQuantity" => 0.0, "emissionFactor" => 500.0)),
		:variableGenerators => Dict{String,Any}(),
		:demandSegments => Dict{String,Any}("D" => Dict{String,Any}("bidPrice" => 100.0, "profile" => demand_profile)),
		:batteryStorage => Dict{String,Any}("energyCapacity" => 0.0, "powerCapacity" => 0.0, "efficiency" => 0.9, "initialSOC" => 0.0, "endSOC" => 0.0),
		:timePeriodsPerDay => 24,
		:windOffset => 0,
		:optimizationModelConfig => Dict{String,Any}("demand_adjust" => true, "ex_post_transactions" => false, "restrict_mtu1_trading" => false),
	)

	initialization = Dict(:SOC => 0.0, :Q_gen => Dict("G" => 0.0))

	market = Dict{Symbol,Any}(:name => "TestMarket", :lookAheadDistance => 0, :optimizationWindow => 3, :enforceRampRates => false)

	market_result_container = MarketDataStorage.MakeMarketResultContainer()

	clear_mtu! = t -> begin
		m = LatestMarketModel.build(t, market_result_container, initialization, data, market)
		optimize!(m)
		MarketDataStorage.AddMarketResult!(market_result_container, m, t, "TestMarket")
	end

	@testset "Test GetFinalDispatchDecisionsForRange" begin

		# GIVEN a clearing at t=0 covering mtu 0,1,2 at the initial demand of 5.0 throughout
		clear_mtu!(0)

		finalDispatch = MarketDataStorage.GetFinalDispatchDecisionsForRange(market_result_container, 0:2)
		@test nrow(finalDispatch) == 3
		@test all(isapprox.(finalDispatch.D, 5.0))
		@test all(isapprox.(finalDispatch.G, 5.0))

		# GIVEN demand at mtu 1 is revised upward before the next, overlapping clearing runs
		demand_profile[demand_profile.mtu .== 1, :Value] .= 9.0

		# WHEN a clearing at t=1 covers mtu 1,2,3, overlapping the t=0 clearing at mtu 1 and 2
		clear_mtu!(1)

		finalDispatch2 = MarketDataStorage.GetFinalDispatchDecisionsForRange(market_result_container, 0:3)

		# THEN the merged result has one row per mtu, with the later (t=1) clearing's
		# revised value winning at mtu 1 rather than the earlier (t=0) clearing's value
		@test nrow(finalDispatch2) == 4
		@test isapprox(finalDispatch2[finalDispatch2.mtu .== 0, :D][1], 5.0) # only ever cleared by t=0
		@test isapprox(finalDispatch2[finalDispatch2.mtu .== 1, :D][1], 9.0) # cleared by both; t=1's revised value wins
		@test isapprox(finalDispatch2[finalDispatch2.mtu .== 2, :D][1], 5.0) # cleared by both, unchanged
		@test isapprox(finalDispatch2[finalDispatch2.mtu .== 3, :D][1], 5.0) # only ever cleared by t=1

		# GIVEN the same accumulated results with a smaller query range, we get fewer rows out
		finalDispatchLimited = MarketDataStorage.GetFinalDispatchDecisionsForRange(market_result_container, 0:1)
		@test nrow(finalDispatchLimited) == 2

	end

	@testset "Test GetEmissionsForRange" begin

		# GIVEN the same accumulated clearings as above, generator "G" (emissionFactor 500
		# kgCO2e/MWh) dispatched a total of 5 + 9 + 5 + 5 = 24 MWh across mtu 0..3

		emissions = MarketDataStorage.GetEmissionsForRange(market_result_container, data, 0:3)

		@test nrow(emissions) == 1 # only dispatchable generators are included
		@test emissions.Generator[1] == "G"
		@test isapprox(emissions.Quantity[1], 24.0)
		@test isapprox(emissions.EmissionFactor[1], 500.0)
		@test isapprox(emissions.Emissions[1], 24.0 * 500.0 / 1000.0) # tCO2e
    
  end
  
	@testset "Test GetEconomicIndicatorsForRange" begin

		# GIVEN the same two accumulated clearings as above (mtu 0,2,3 at demand 5.0, mtu 1
		# revised to 9.0), with generator "G" (bidPrice 50) always marginal against demand
		# "D" (bidPrice 100) since its capacity is never binding, so every mtu clears at
		# price 50 - known, hand-computable economics to check GetEconomicIndicatorsForRange against

		(economic_indicators, agent_indicators, transactions, finalDispatchDecisions, mtu_economic_indicators) =
			MarketDataStorage.GetEconomicIndicatorsForRange(market_result_container, 0:3)

		# agent_indicators/economic_indicators/mtu_economic_indicators columns are renamed
		# to long display names (TableHeaderRenaming), e.g. SEW -> "Socioeconomic Welfare (€)"
		d_row = agent_indicators[agent_indicators.Agent .== "D", :]
		g_row = agent_indicators[agent_indicators.Agent .== "G", :]

		# total dispatched quantity across mtu 0,1,2,3 = 5 + 9 + 5 + 5 = 24
		@test isapprox(d_row[1, "Quantity (MWh)"], 24.0)
		@test isapprox(g_row[1, "Quantity (MWh)"], 24.0)
		@test isapprox(d_row[1, "Load Utility (€)"], 24.0 * 100.0) # demand bid price 100
		@test isapprox(g_row[1, "Fuel Cost (€)"], 24.0 * 50.0) # generator bid price 50
		@test isapprox(economic_indicators[1, "Socioeconomic Welfare (€)"], 24.0 * (100.0 - 50.0))

		# THEN the aggregate indicators (computed once, over the whole range) and the
		# per-mtu indicators (computed once per mtu) agree with each other - both now
		# derive from the same AgentEconomicMetrics call, so a per-mtu sum must equal
		# the aggregate rather than risk drifting apart the way two independently
		# hand-written versions of the same formula could
		@test nrow(mtu_economic_indicators) == 4
		@test isapprox(sum(mtu_economic_indicators[!, "Socioeconomic Welfare (€)"]), economic_indicators[1, "Socioeconomic Welfare (€)"])
		@test isapprox(sum(mtu_economic_indicators[!, "Demand Utility (€)"]), economic_indicators[1, "Demand Utility (€)"])
		@test isapprox(sum(mtu_economic_indicators[!, "Production Costs (€)"]), economic_indicators[1, "Production Costs (€)"])
		@test isapprox(sum(mtu_economic_indicators[!, "Consumer Surplus (€)"]), economic_indicators[1, "Consumer Surplus (€)"])
		@test isapprox(sum(mtu_economic_indicators[!, "Producer Surplus (€)"]), economic_indicators[1, "Producer Surplus (€)"])

	end

	@testset "Storage SOC change is measured against the SOC the range opens with" begin

		# GIVEN storage whose SOC at the end of MTUs 0..3 is 10, 20, 30, 40, and an analysis range of MTUs 1..2
		helper = MarketDataStorage.HelperModelResults
		agent_map = Dict(helper.AGENT_DEMAND => ["D"], helper.AGENT_GENERATOR => ["G"])
		final_dispatch = DataFrame(mtu=0:3, D=fill(1.0, 4), P_D=fill(100.0, 4), G=fill(1.0, 4), P_G=fill(50.0, 4), SOC=[10.0, 20.0, 30.0, 40.0],
			StorageCharge=zeros(4), StorageDischarge=zeros(4), FinalAuctionPrice=fill(50.0, 4))
		transactions = DataFrame(Agent=["Storage"], var"Quantity (MWh)"=[1.0], var"Price (€/MWh)"=[50.0], var"Market Time Unit"=[1])
		soc_change(result) = result.agent_indicators[result.agent_indicators.Agent .== "Storage", "SOC Change (MWh)"][1]

		# WHEN the table still holds the MTU before the range, THEN the change is end (30) - opening (10)
		@test soc_change(MarketDataStorage.CalculateEconomicIndicators(final_dispatch, transactions, agent_map, 1:2)) == 20.0

		# WHEN the table is already trimmed to the range (like a run's export) and the opening SOC is supplied
		trimmed = final_dispatch[1 .<= final_dispatch.mtu .<= 2, :]
		@test soc_change(MarketDataStorage.CalculateEconomicIndicators(trimmed, transactions, agent_map, 1:2; opening_soc=10.0)) == 20.0

		# WHEN it is trimmed and no opening SOC is available, THEN the change is missing, not end - 0.0
		@test ismissing(soc_change(MarketDataStorage.CalculateEconomicIndicators(trimmed, transactions, agent_map, 1:2)))

		# and the opening SOC is read from the MTU before the range
		@test MarketDataStorage.OpeningSOC(final_dispatch, 1:2) == 10.0
		@test MarketDataStorage.OpeningSOC(trimmed, 1:2) === nothing

	end

	@testset "Storage revenue is the sum of storage transactions (quantity * price)" begin

		# GIVEN storage that traded MTU 0 twice, charging 2 at 20 then discharging 3 at 60 (net position
		# +1 MWh, settled at a final price of 100), MTU 1 once (discharging 2 at 50), and MTU 2 - outside
		# the range - once (discharging 5 at 10)
		helper = MarketDataStorage.HelperModelResults
		agent_map = Dict(helper.AGENT_DEMAND => ["D"], helper.AGENT_GENERATOR => ["G"])
		final_dispatch = DataFrame(mtu=0:2, D=fill(1.0, 3), P_D=fill(100.0, 3), G=fill(1.0, 3), P_G=fill(50.0, 3), SOC=fill(0.0, 3),
			StorageCharge=[0.0, 0.0, 0.0], StorageDischarge=[1.0, 2.0, 5.0], FinalAuctionPrice=[100.0, 50.0, 10.0])
		transactions = DataFrame(Agent=["Storage", "Storage", "Storage", "Storage"], var"Quantity (MWh)"=[-2.0, 3.0, 2.0, 5.0],
			var"Price (€/MWh)"=[20.0, 60.0, 50.0, 10.0], var"Market Time Unit"=[0, 0, 1, 2])

		result = MarketDataStorage.CalculateEconomicIndicators(final_dispatch, transactions, agent_map, 0:1)

		# THEN the revenue is -2*20 + 3*60 + 2*50 = 240 - not the final-price valuation 1*100 + 2*50 = 200
		@test isapprox(result.economic_indicators[1, "Storage Revenue (€)"], 240.0)
		storage_row = result.agent_indicators[result.agent_indicators.Agent .== "Storage", :]
		@test isapprox(storage_row[1, "Revenue (€)"], 240.0)
		@test isapprox(storage_row[1, "Surplus (€)"], 240.0)
		# and the per-MTU values (MTU 0: -40 + 180, MTU 1: 100) sum to the whole-range value
		@test isapprox(result.mtu_economic_indicators[!, "Storage Revenue (€)"], [140.0, 100.0])
		@test isapprox(sum(result.mtu_economic_indicators[!, "Storage Revenue (€)"]), result.economic_indicators[1, "Storage Revenue (€)"])
		# the quantity column still reports the final dispatched discharge
		@test isapprox(storage_row[1, "Quantity (MWh)"], 3.0)

	end

end

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

end

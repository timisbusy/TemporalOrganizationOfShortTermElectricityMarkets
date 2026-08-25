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
		:dispatchableGenerators => Dict{String,Any}("G" => Dict{String,Any}("bidPrice" => 50.0, "capacity" => 10.0, "rampRate" => 100.0, "initialQuantity" => 0.0)),
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

end

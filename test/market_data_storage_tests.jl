using DataFrames

include("../src/lib/output_data/market_data_storage.jl")

@testset "Market Data Storage 1" begin

	# note: DecisionVariables always carries a "price" column in real usage; GetFinalDispatchDecisions drops it,
	# so it must be present here too even though these mock frames don't otherwise use it
	dfs = [DataFrame(mtu=1:6, price=zeros(6), val=1:6), DataFrame(mtu=2:7, price=zeros(6), val=1:6), DataFrame(mtu=3:8, price=zeros(6), val=1:6), DataFrame(mtu=4:9, price=zeros(6), val=1:6), DataFrame(mtu=8:12, price=zeros(5), val=1:5)]

	dfAdd = DataFrame(mtu=10:15, price=zeros(6), val=2:7)

	expectedVals = [1,1,1,1,2,3,4,1,2,3,4,5]
	expectedVals2 = [1,1,1,1,2,3,4,1,2,2,3,4]
	dfExpected = DataFrame(mtu=1:12, val=expectedVals)
	dfExpected2 = DataFrame(mtu=1:12, val=expectedVals2)

	market_result_container = MarketDataStorage.MakeMarketResultContainer()

	for df in dfs
		mr = MarketDataStorage.MarketResult()
		mr.DecisionVariables = df

		push!(market_result_container.Results, mr)
	end

	@testset "Test GetFinalDispatchDecisionsForRange" begin

		# GIVEN an initial set of marketresults with a known final dispatch (simple with val)

		# WHEN we get market results
		finalDispatch = MarketDataStorage.GetFinalDispatchDecisionsForRange(market_result_container, 1:12)

		# THEN we get the expected data frame with the expected length
		@test nrow(finalDispatch) == 12
		@test finalDispatch == dfExpected


		# GIVEN the same initial set, plus an additional result

		mrAdd = MarketDataStorage.MarketResult()
		mrAdd.DecisionVariables = dfAdd
		push!(market_result_container.Results, mrAdd)
		MarketDataStorage.CacheBust!(market_result_container) # Results was mutated directly, not via AddMarketResult!, so force a recompute

		# WHEN we get the market results again
		finalDispatch2 = MarketDataStorage.GetFinalDispatchDecisionsForRange(market_result_container, 1:12)

		# THEN we get the same length of final dispatch but different values
		@test nrow(finalDispatch2) == 12
		@test finalDispatch2 != dfExpected
		@test finalDispatch2 == dfExpected2


		# GIVEN the same initial set with a smaller query range, we get less results out


		# WHEN we get the market results again
		finalDispatchLimited = MarketDataStorage.GetFinalDispatchDecisionsForRange(market_result_container, 2:6)

		# THEN we get the same length of final dispatch but different values
		@test nrow(finalDispatchLimited) == 5

	end


end
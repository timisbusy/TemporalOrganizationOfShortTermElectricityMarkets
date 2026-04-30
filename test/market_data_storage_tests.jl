using DataFrames

include("../src/lib/output_data/market_data_storage.jl")

@testset "Market Data Storage 1" begin

	dfs = [DataFrame(mtu=1:6, val=1:6), DataFrame(mtu=2:7, val=1:6), DataFrame(mtu=3:8, val=1:6), DataFrame(mtu=4:9, val=1:6), DataFrame(mtu=8:12, val=1:5)]

	dfAdd = DataFrame(mtu=10:15,val=2:7)

	expectedVals = [1,1,1,1,2,3,4,1,2,3,4,5]
	expectedVals2 = [1,1,1,1,2,3,4,1,2,2,3,4]
	dfExpected = DataFrame(mtu=1:12, val=expectedVals)
	dfExpected2 = DataFrame(mtu=1:12, val=expectedVals2)

	marketresults = []

	for df in dfs
		mr = MarketDataStorage.MarketResult()
		mr.DecisionVariables = df

		push!(marketresults, mr)
	end

	@testset "Test GetMarketResultsForRange" begin

		# GIVEN an initial set of marketresults with a known final dispatch (simple with val)

		# WHEN we get market results
		finalDispatch = MarketDataStorage.GetMarketResultsForRange(marketresults, 1:12)

		# THEN we get the expected data frame with the expected length
		@test nrow(finalDispatch) == 12
		@test finalDispatch == dfExpected


		# GIVEN the same initial set, plus an additional result

		mrAdd = MarketDataStorage.MarketResult()
		mrAdd.DecisionVariables = dfAdd
		marketresults = push!(marketresults, mrAdd)

		# WHEN we get the market results again
		finalDispatch2 = MarketDataStorage.GetMarketResultsForRange(marketresults, 1:12)

		# THEN we get the same length of final dispatch but different values
		@test nrow(finalDispatch2) == 12
		@test finalDispatch2 != dfExpected
		@test finalDispatch2 == dfExpected2


		# GIVEN the same initial set with a smaller query range, we get less results out


		# WHEN we get the market results again
		finalDispatchLimited = MarketDataStorage.GetMarketResultsForRange(marketresults, 2:6)

		# THEN we get the same length of final dispatch but different values
		@test nrow(finalDispatchLimited) == 5

	end


end
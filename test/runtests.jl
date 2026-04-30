using Test
using TemporalOrganizationOfShortTermElectricityMarkets

include("../src/lib/helpers.jl")
using ..Helpers.HelperModelResults

@testset "First test" begin
	
	@test 1 + 1 == 2
end


@testset "MarketDataStorage Tests" begin
	include("market_data_storage_tests.jl")
end
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

@testset "TwoStageModel Tests" begin
	include("two_stage_model_tests.jl")
end

@testset "StorageMipModel Tests" begin
	include("storage_mip_model_tests.jl")
end

@testset "Solver selection Tests" begin
	include("solver_selection_tests.jl")
end

@testset "Time range Tests" begin
	include("time_range_tests.jl")
end

@testset "BalancingSegment Tests" begin
	include("balancing_segment_tests.jl")
end

@testset "MTU lock count Tests" begin
	include("helper_mtu_lock_tests.jl")
end

@testset "Market config lockedMTUs Tests" begin
	include("market_config_lock_tests.jl")
end

@testset "Data importer Tests" begin
	include("data_importer_tests.jl")
end

@testset "Window length config generator Tests" begin
	include("generate_window_length_configs_tests.jl")
end

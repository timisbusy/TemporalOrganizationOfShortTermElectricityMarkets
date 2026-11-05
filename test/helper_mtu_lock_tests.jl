using Test

if !isdefined(Main, :HelperMtuLock)
	include(joinpath(@__DIR__, "..", "src", "lib", "helpers", "helper_mtu_lock.jl"))
end
using .HelperMtuLock

@testset "LockedMTUCount" begin
	data(restrict) = Dict{Symbol,Any}(:optimizationModelConfig => Dict{String,Any}("restrict_mtu1_trading" => restrict))
	market(; kwargs...) = Dict{Symbol,Any}(:name => "M", :optimizationWindow => 5, kwargs...)

	@testset "legacy flags mean 0 or 1" begin
		@test LockedMTUCount(data(false), market()) == 0
		@test LockedMTUCount(data(true), market()) == 1
		@test LockedMTUCount(data(true), market(overrideMTU1Restriction=true)) == 0
		@test LockedMTUCount(Dict{Symbol,Any}(), market()) == 0
	end

	@testset "lockedMTUs states the count directly" begin
		for n in 0:5
			@test LockedMTUCount(data(false), market(lockedMTUs=n)) == n
		end
		@test LockedMTUCount(data(true), market(lockedMTUs=3)) == 3
		@test LockedMTUCount(data(true), market(lockedMTUs=0, overrideMTU1Restriction=true)) == 0
	end

	@testset "bad or conflicting settings are errors" begin
		@test_throws ErrorException LockedMTUCount(data(false), market(lockedMTUs=-1))
		@test_throws ErrorException LockedMTUCount(data(false), market(lockedMTUs=1.5))
		@test_throws ErrorException LockedMTUCount(data(false), market(lockedMTUs=6)) # longer than the window
		@test_throws ErrorException LockedMTUCount(data(true), market(lockedMTUs=0)) # restricted, yet no lock, and no override
	end

	@testset "range of locked MTUs" begin
		@test LockedMTURange(0, 7) === nothing
		@test LockedMTURange(1, 7) == 7:7
		@test LockedMTURange(3, 7) == 7:9
	end
end

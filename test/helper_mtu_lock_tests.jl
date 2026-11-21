using Test, JuMP, HiGHS

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

@testset "ApplyMTULock!" begin
	market(; kwargs...) = Dict{Symbol,Any}(:name => "M", kwargs...)
	gens = ["3G_Base", "4G_Shoulder", "5G_Peak", "7G_Solar"]
	dems = ["1D_HighBid", "2D_ModerateBid"]

	# one locked MTU (t=1) and one free MTU (t=2); previous dispatch: Base 10, demand 6 + 4
	function build(m_market; demand_total = 10.0)
		m = Model(HiGHS.Optimizer)
		set_silent(m)
		@variable(m, Qg[gens, 1:2] >= 0)
		@variable(m, Qg_adj[gens, 1:2])
		@variable(m, Qd[dems, 1:2] >= 0)
		Qg_prev = Dict((g, t) => (g == "3G_Base" ? 10.0 : 0.0) for g in gens, t in 1:2)
		Qd_prev = Dict((d, t) => (d == "1D_HighBid" ? 6.0 : 4.0) for d in dems, t in 1:2)
		@constraint(m, [g in gens, t in 1:2], Qg_adj[g,t] == Qg[g,t] - Qg_prev[(g,t)])
		@constraint(m, [t in 1:2], sum(Qg[g,t] for g in gens) == sum(Qd[d,t] for d in dems))
		@constraint(m, [d in dems, t in 1:2], Qd[d,t] <= 20)
		@objective(m, Max, sum(Qd))
		ApplyMTULock!(m, m_market, Qg_adj, Qd, Qd_prev, 1:1)
		return m, Qg, Qd
	end

	@testset "default locks generators only" begin
		m, Qg, Qd = build(market())
		@test LockDemand(market()) == false
		optimize!(m)
		@test termination_status(m) == MOI.OPTIMAL
		@test value(Qg["3G_Base", 1]) ≈ 10.0
		# demand is free to move in the locked MTU: Base is frozen at 10, so Peak supplies more
		@test sum(value(Qd[d, 1]) for d in dems) > 10.0 + 1e-6
	end

	@testset "lockDemand freezes every demand segment in the locked MTU only" begin
		m, Qg, Qd = build(market(lockDemand=true))
		@test LockDemand(market(lockDemand=true))
		optimize!(m)
		@test termination_status(m) == MOI.OPTIMAL
		@test value(Qd["1D_HighBid", 1]) ≈ 6.0
		@test value(Qd["2D_ModerateBid", 1]) ≈ 4.0
		@test value(Qd["1D_HighBid", 2]) + value(Qd["2D_ModerateBid", 2]) > 10.0 + 1e-6 # unlocked MTU still free
	end

	@testset "a lock with no feasible balance is a hard failure" begin
		# generators and demand both frozen, but previous dispatch is out of balance (10 supply vs 8 demand)
		m = Model(HiGHS.Optimizer)
		set_silent(m)
		@variable(m, Qg[["3G_Base", "4G_Shoulder", "7G_Solar"], 1:1] >= 0)
		@variable(m, Qg_adj[["3G_Base", "4G_Shoulder", "7G_Solar"], 1:1])
		@variable(m, Qd[["1D_HighBid"], 1:1] >= 0)
		@constraint(m, [g in ["3G_Base", "4G_Shoulder", "7G_Solar"]], Qg_adj[g, 1] == Qg[g, 1] - (g == "3G_Base" ? 10.0 : 0.0))
		@constraint(m, sum(Qg[g, 1] for g in ["3G_Base", "4G_Shoulder", "7G_Solar"]) == Qd["1D_HighBid", 1])
		ApplyMTULock!(m, market(lockDemand=true), Qg_adj, Qd, Dict(("1D_HighBid", 1) => 8.0), 1:1)
		optimize!(m)
		@test termination_status(m) != MOI.OPTIMAL
	end
end

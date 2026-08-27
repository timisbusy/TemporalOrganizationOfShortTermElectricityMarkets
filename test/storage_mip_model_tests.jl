using DataFrames
using JuMP
using MathOptInterface

# guard against re-including (and thereby redefining) ClearMarket when this file runs as part
# of runtests.jl after another test file has already loaded it - redefining it would leave
# Main with two conflicting bindings for names like MarketDataStorage
if !isdefined(Main, :ClearMarket)
	include("../src/lib/market_clearers/clear_market.jl")
end
using .ClearMarket.MarketDataStorage
using .ClearMarket.StorageMipMarketModel
using .ClearMarket.LatestMarketModel

@testset "Storage MIP Model" begin

	# Shared scenario for the tests below: one generator "G" (bidPrice 50, capacity 10) and
	# one demand "D" (bidPrice 100, quantity 10) exactly matched at every mtu, so both dispatch
	# fully regardless of storage - the energy balance then forces Qdis[t] == Qch[t] for any
	# mtu where storage is used at all. Storage starts empty (initialSOC 0) with no terminal
	# SOC constraint enforced, so there's no free-lunch arbitrage available either - this keeps
	# the scenario's true economic optimum hand-computable regardless of what storage does.
	#
	# efficiency controls whether a same-mtu charge/discharge "wash" would be merely unrewarded
	# under an LP (efficiency 1.0 - the round trip costs nothing, exactly the case
	# TwoStageMarketModel's tests show an LP can land on by accident) or actually infeasible
	# (efficiency < 1.0). StorageMipMarketModel's Big-M/binary formulation rules out the wash
	# outright at every mtu regardless of efficiency, so both values exercise the same guarantee.
	make_scenario(efficiency) = begin
		demand_profile = DataFrame(mtu=0:10, Value=fill(10.0, 11))
		data = Dict{Symbol,Any}(
			:dispatchableGenerators => Dict{String,Any}("G" => Dict{String,Any}("bidPrice" => 50.0, "capacity" => 10.0, "rampRate" => 100.0, "initialQuantity" => 0.0, "emissionFactor" => 500.0)),
			:variableGenerators => Dict{String,Any}(),
			:demandSegments => Dict{String,Any}("D" => Dict{String,Any}("bidPrice" => 100.0, "profile" => demand_profile)),
			:batteryStorage => Dict{String,Any}("energyCapacity" => 20.0, "powerCapacity" => 5.0, "efficiency" => efficiency, "initialSOC" => 0.0, "endSOC" => 0.0),
			:timePeriodsPerDay => 24,
			:windOffset => 0,
			:optimizationModelConfig => Dict{String,Any}("demand_adjust" => true, "ex_post_transactions" => false, "restrict_mtu1_trading" => false),
		)
		initialization = Dict(:SOC => 0.0, :Q_gen => Dict("G" => 0.0))
		market = Dict{Symbol,Any}(:name => "TestMarket", :lookAheadDistance => 0, :optimizationWindow => 3, :enforceRampRates => false)
		return (data, initialization, market)
	end

	clean_objective = (100.0 - 50.0) * 10.0 * 3 # (D price - G price) * quantity * 3 mtus

	# runs the shared 3-step pipeline (define_sets!/process_time_series_data!/process_parameters!)
	# and returns the unbuilt model, so tests can attach extra constraints (a pin) before calling
	# build_market_clearing! themselves - mirrors what StorageMipMarketModel.build() does
	# internally for the stage-1 MIP solve
	prepare_unbuilt(t, container, initialization, data, market) = begin
		m = Model(StorageMipMarketModel.select_optimizer(data))
		set_silent(m)
		StorageMipMarketModel.define_sets!(m, t, container, initialization, data, market)
		StorageMipMarketModel.process_time_series_data!(m, t, container, initialization, data, market)
		StorageMipMarketModel.process_parameters!(m, t, container, initialization, data, market)
		return m
	end

	@testset "Big-M constraint makes simultaneous charge/discharge infeasible" begin

		# GIVEN a stage-1 model (efficiency 1.0, so a wash would be free under an LP) where
		# mtu 1's charge and discharge are both pinned nonzero at once - exactly the pin
		# TwoStageMarketModel's LP happily accepts as a pointless-but-feasible wash
		pinned_mtu = 1
		k = 2.0

		(data, initialization, market) = make_scenario(1.0)
		container = MarketDataStorage.MakeMarketResultContainer()

		m1 = prepare_unbuilt(0, container, initialization, data, market)
		StorageMipMarketModel.build_market_clearing!(m1, 0, container, initialization, data, market)
		@constraint(m1, m1.ext[:variables][:Qch][pinned_mtu] == k)
		@constraint(m1, m1.ext[:variables][:Qdis][pinned_mtu] == k)
		optimize!(m1)

		# THEN the Big-M/binary exclusivity constraint (Qch[t] <= M*(1-z[t]), Qdis[t] <= M*z[t])
		# makes the pin infeasible outright, unlike the plain LP cut/TwoStageMarketModel
		@test termination_status(m1) in (MathOptInterface.INFEASIBLE, MathOptInterface.INFEASIBLE_OR_UNBOUNDED)

	end

	@testset "build() forces exclusivity at every MTU and preserves the objective" begin

		for efficiency in (1.0, 0.9)
			(data, initialization, market) = make_scenario(efficiency)
			container = MarketDataStorage.MakeMarketResultContainer()

			m = StorageMipMarketModel.build(0, container, initialization, data, market)
			optimize!(m)

			@test termination_status(m) == MathOptInterface.OPTIMAL
			@test isapprox(objective_value(m), clean_objective)

			OW = m.ext[:sets][:OW]
			tol = 1e-6
			for t in OW
				qch = value(m.ext[:variables][:Qch][t])
				qdis = value(m.ext[:variables][:Qdis][t])
				# THEN at most one side is nonzero at every mtu, guaranteed by construction
				# rather than by coincidence of the LP relaxation - the point of this model
				@test !(qch > tol && qdis > tol)
			end

			# AND the MIP objective and the fixed-bounds LP re-solve objective agree exactly,
			# since the MIP's own optimal solution is always feasible for (and optimal in) the
			# LP with its exclusivity decision baked in as fixed bounds
			@test haskey(m.ext, :storage_mip)
			@test isapprox(m.ext[:storage_mip][:objective_mip], m.ext[:storage_mip][:objective_fixed_lp])
		end

	end

	@testset "dual query throws on the raw MIP stage but succeeds after build()'s fixed-LP re-solve" begin

		(data, initialization, market) = make_scenario(1.0)
		container = MarketDataStorage.MakeMarketResultContainer()

		# GIVEN the raw stage-1 model (still a MIP - the binary z[t] has not been fixed away)
		m1 = prepare_unbuilt(0, container, initialization, data, market)
		StorageMipMarketModel.build_market_clearing!(m1, 0, container, initialization, data, market)
		optimize!(m1)
		@test termination_status(m1) == MathOptInterface.OPTIMAL

		# THEN querying the energy balance dual on the MIP itself errors - a MIP has no valid
		# LP duals, which is exactly why build() always re-solves a fixed-bounds LP afterwards
		@test_throws Exception dual.(m1.ext[:constraints][:energy_balance])

		# WHEN build() runs its full two-solve pattern (MIP, then fix-and-resolve as an LP)
		m2 = StorageMipMarketModel.build(0, container, initialization, data, market)
		optimize!(m2)

		# THEN the returned model is a pure LP and its energy_balance dual is a valid price -
		# here the marginal generator G (bidPrice 50) sets the price at every mtu
		OW = m2.ext[:sets][:OW]
		prices = dual.(m2.ext[:constraints][:energy_balance])
		for t in OW
			@test isapprox(prices[t], 50.0)
		end

	end

	@testset "build() populates m.ext[:storage_mip] and MarketDataStorage records per-MTU decisions" begin

		(data, initialization, market) = make_scenario(0.9)
		container = MarketDataStorage.MakeMarketResultContainer()

		m = StorageMipMarketModel.build(0, container, initialization, data, market)
		optimize!(m)
		OW = m.ext[:sets][:OW]

		MarketDataStorage.AddMarketResult!(container, m, 0, "TestMarket")
		mr = container.Results[end]

		@test mr.StorageMipInfo !== nothing
		@test isapprox(mr.StorageMipInfo[:objective_mip], mr.StorageMipInfo[:objective_fixed_lp])

		decisions = container.StorageMipDecisions
		@test decisions !== nothing
		@test nrow(decisions) == length(OW) # one row per mtu in the optimization window

		@test all(decisions.ClearingMTU .== 0)
		@test all(isapprox.(decisions.ObjectiveMip, mr.StorageMipInfo[:objective_mip]))
		@test all(isapprox.(decisions.ObjectiveFixedLP, mr.StorageMipInfo[:objective_fixed_lp]))
		@test all(in.(decisions.ForcedZero, Ref(["charge", "discharge"])))

		# AND the recorded per-mtu side matches what build() itself decided
		for t in OW
			row = decisions[decisions.mtu .== t, :][1, :]
			@test row.ForcedZero == mr.StorageMipInfo[:forced_zero][t]
		end

	end

	@testset "other models leave StorageMipInfo untouched" begin

		(data, initialization, market) = make_scenario(0.9)
		container = MarketDataStorage.MakeMarketResultContainer()

		m = LatestMarketModel.build(0, container, initialization, data, market)
		optimize!(m)
		MarketDataStorage.AddMarketResult!(container, m, 0, "TestMarket")

		@test container.Results[end].StorageMipInfo === nothing
		@test container.StorageMipDecisions === nothing

	end

end

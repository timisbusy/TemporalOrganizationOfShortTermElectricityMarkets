using DataFrames
using JuMP

# guard against re-including (and thereby redefining) ClearMarket when this file runs as part
# of runtests.jl after market_data_storage_tests.jl has already loaded it - redefining it would
# leave Main with two conflicting bindings for names like MarketDataStorage
if !isdefined(Main, :ClearMarket)
	include("../src/lib/market_clearers/clear_market.jl")
end
using .ClearMarket.MarketDataStorage
using .ClearMarket.TwoStageMarketModel
using .ClearMarket.LatestMarketModel

@testset "Two Stage Model 1" begin

	@testset "detect_simultaneous_charge_discharge" begin

		OW = 0:2

		# GIVEN mtu 0 has only charge, mtu 1 has both charge and discharge (charge larger),
		# mtu 2 has both at a tie
		Qch = Dict(0 => 3.0, 1 => 5.0, 2 => 2.0)
		Qdis = Dict(0 => 0.0, 1 => 1.0, 2 => 2.0)

		constrained = TwoStageMarketModel.detect_simultaneous_charge_discharge(Qch, Qdis, OW)

		# THEN only mtu 1 and 2 are flagged (mtu 0 has no discharge at all)
		@test nrow(constrained) == 2
		@test sort(constrained.mtu) == [1, 2]

		row1 = constrained[constrained.mtu .== 1, :][1, :]
		@test isapprox(row1.qch_stage1, 5.0)
		@test isapprox(row1.qdis_stage1, 1.0)
		@test row1.forced_zero == "discharge" # smaller of the two is zeroed, higher (charge) kept

		# a tie forces discharge to zero (keeps charge), as a deterministic tie-break
		row2 = constrained[constrained.mtu .== 2, :][1, :]
		@test row2.forced_zero == "discharge"

		# GIVEN values within tolerance of zero, they are not flagged as simultaneous
		Qch_tiny = Dict(0 => 1e-9, 1 => 3.0)
		Qdis_tiny = Dict(0 => 3.0, 1 => 1e-9)
		constrained_tiny = TwoStageMarketModel.detect_simultaneous_charge_discharge(Qch_tiny, Qdis_tiny, 0:1)
		@test nrow(constrained_tiny) == 0

	end

	# Shared scenario for the build()-level tests below: one generator "G" (bidPrice 50,
	# capacity 10) and one demand "D" (bidPrice 100, quantity 10) exactly matched at every
	# mtu, so both dispatch fully regardless of storage - the energy balance then forces
	# Qdis[t] == Qch[t] for any mtu where storage is used at all (Qg and Qd are already both
	# pinned at their caps, so any charge must be matched by equal discharge in the very same
	# mtu). Storage starts empty (initialSOC 0) with no terminal SOC constraint enforced, so
	# there's no free-lunch arbitrage available either - this keeps the scenario's true
	# economic optimum hand-computable regardless of what storage does.
	#
	# efficiency controls whether a same-mtu charge/discharge "wash" is merely unrewarded
	# (efficiency 1.0 - the round trip costs nothing, so it's a free but pointless choice the
	# solver may or may not happen to make - genuinely observed in practice while writing this
	# test, which is exactly the artifact this model exists to correct) or actually infeasible
	# (efficiency < 1.0 - from an empty starting SOC, any wash drives SOC negative, so Qch=Qdis=0
	# is the *only* feasible point, deterministically, regardless of solver internals).
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

	@testset "build() with no simultaneous charge/discharge (regression path)" begin

		# GIVEN efficiency < 1.0, so a same-mtu charge/discharge wash is infeasible (not just
		# uneconomical) from an empty starting SOC - deterministically ruling out the natural
		# solver degeneracy seen with efficiency 1.0 below
		(data, initialization, market) = make_scenario(0.9)
		container = MarketDataStorage.MakeMarketResultContainer()

		m = TwoStageMarketModel.build(0, container, initialization, data, market)
		optimize!(m)

		# THEN stage 2 is never triggered, and the model matches the single-stage optimum
		@test haskey(m.ext, :two_stage)
		@test m.ext[:two_stage][:was_constrained] == false
		@test nrow(m.ext[:two_stage][:constrained_mtus]) == 0
		@test isapprox(m.ext[:two_stage][:objective_stage1], m.ext[:two_stage][:objective_stage2])
		@test isapprox(objective_value(m), clean_objective)

		# AND MarketDataStorage records the two-stage info alongside the rest of the clearing
		MarketDataStorage.AddMarketResult!(container, m, 0, "TestMarket")
		mr = container.Results[end]
		@test mr.TwoStageInfo !== nothing
		@test mr.TwoStageInfo[:was_constrained] == false
		@test container.TwoStageConstrainedMTUs !== nothing
		@test nrow(container.TwoStageConstrainedMTUs) == 0

	end

	# runs the shared 3-step pipeline (define_sets!/process_time_series_data!/process_parameters!)
	# and returns the unbuilt model, so tests can attach extra constraints (a pin, or
	# m.ext[:two_stage_forced_zero]) before calling build_market_clearing! themselves - mirrors
	# what TwoStageMarketModel.build() does internally for each stage
	prepare_unbuilt(t, container, initialization, data, market) = begin
		m = Model(TwoStageMarketModel.select_optimizer(data))
		set_silent(m)
		TwoStageMarketModel.define_sets!(m, t, container, initialization, data, market)
		TwoStageMarketModel.process_time_series_data!(m, t, container, initialization, data, market)
		TwoStageMarketModel.process_parameters!(m, t, container, initialization, data, market)
		return m
	end

	@testset "build_market_clearing!() forces the higher of charge/discharge and preserves the objective" begin

		# GIVEN a stage-1 model where mtu 1's charge and discharge are both pinned to the same
		# nonzero value (a free "wash" under efficiency 1.0 - it changes neither the net storage
		# exchange nor the SOC trajectory, so it cannot make the true optimum worse), to
		# deterministically reproduce the simultaneous charge/discharge artifact this model exists
		# to correct, rather than relying on solver-specific degenerate-vertex behavior
		pinned_mtu = 1
		k = 2.0

		(data, initialization, market) = make_scenario(1.0)
		container = MarketDataStorage.MakeMarketResultContainer()

		m1 = prepare_unbuilt(0, container, initialization, data, market)
		TwoStageMarketModel.build_market_clearing!(m1, 0, container, initialization, data, market)
		@constraint(m1, m1.ext[:variables][:Qch][pinned_mtu] == k)
		@constraint(m1, m1.ext[:variables][:Qdis][pinned_mtu] == k)
		optimize!(m1)

		# THEN the pin does not change the optimal objective (it's a free wash)
		@test isapprox(objective_value(m1), clean_objective)

		OW = m1.ext[:sets][:OW]
		Qch1 = Dict(t => value(m1.ext[:variables][:Qch][t]) for t in OW)
		Qdis1 = Dict(t => value(m1.ext[:variables][:Qdis][t]) for t in OW)
		constrained = TwoStageMarketModel.detect_simultaneous_charge_discharge(Qch1, Qdis1, OW)

		@test nrow(constrained) == 1
		@test constrained.mtu[1] == pinned_mtu
		@test constrained.forced_zero[1] == "discharge" # tie at k == k

		# WHEN stage 2 forces the flagged (lower) side to zero via m.ext[:two_stage_forced_zero],
		# exactly as build() does - build_market_clearing! adds the restriction itself
		m2 = prepare_unbuilt(0, container, initialization, data, market)
		m2.ext[:two_stage_forced_zero] = Dict(row.mtu => row.forced_zero for row in eachrow(constrained))
		TwoStageMarketModel.build_market_clearing!(m2, 0, container, initialization, data, market)
		optimize!(m2)

		# THEN stage 2 lands on the truly clean solution (both sides at zero, not just the
		# forced one) and the objective is unchanged
		@test isapprox(objective_value(m1), objective_value(m2))
		@test isapprox(value(m2.ext[:variables][:Qch][pinned_mtu]), 0.0; atol=1e-6)
		@test isapprox(value(m2.ext[:variables][:Qdis][pinned_mtu]), 0.0; atol=1e-6)

		# AND MarketDataStorage accumulates the constrained-MTU row when a model carries two_stage info
		obj1 = objective_value(m1)
		obj2 = objective_value(m2)
		m2.ext[:two_stage] = Dict(:objective_stage1 => obj1, :objective_stage2 => obj2, :constrained_mtus => constrained, :was_constrained => true)

		MarketDataStorage.AddMarketResult!(container, m2, 0, "TestMarket")
		@test container.TwoStageConstrainedMTUs !== nothing
		@test nrow(container.TwoStageConstrainedMTUs) == 1
		@test container.TwoStageConstrainedMTUs.mtu[1] == pinned_mtu
		@test isapprox(container.TwoStageConstrainedMTUs.ObjectiveStage1[1], obj1)
		@test isapprox(container.TwoStageConstrainedMTUs.ObjectiveStage2[1], obj2)

	end

	@testset "other models leave TwoStageInfo untouched" begin

		(data, initialization, market) = make_scenario(0.9)
		container = MarketDataStorage.MakeMarketResultContainer()

		m = LatestMarketModel.build(0, container, initialization, data, market)
		optimize!(m)
		MarketDataStorage.AddMarketResult!(container, m, 0, "TestMarket")

		@test container.Results[end].TwoStageInfo === nothing
		@test container.TwoStageConstrainedMTUs === nothing

	end

end

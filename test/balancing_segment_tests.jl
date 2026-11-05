using DataFrames
using JuMP
using XLSX

# see two_stage_model_tests.jl for why ClearMarket is include-guarded
if !isdefined(Main, :ClearMarket)
	include("../src/lib/market_clearers/clear_market.jl")
end
using .ClearMarket.MarketDataStorage
using .ClearMarket.LatestMarketModel
using .ClearMarket.TwoStageMarketModel
using .ClearMarket.StorageMipMarketModel

# the restrict_mtu1_trading lock names these three generators, so the fixture has to define them
function balancing_segment_fixture(; restrict, override=false, look_ahead=0)
	demand_profile = DataFrame(mtu=0:20, Value=fill(8.0, 21))
	solar_profile = DataFrame(mtu=0:20, Value=fill(1.0, 21))
	data = Dict{Symbol,Any}(
		:dispatchableGenerators => Dict{String,Any}(
			"3G_Base" => Dict{String,Any}("bidPrice" => 20.0, "capacity" => 10.0, "rampRate" => 100.0, "initialQuantity" => 0.0, "emissionFactor" => 500.0),
			"4G_Shoulder" => Dict{String,Any}("bidPrice" => 50.0, "capacity" => 10.0, "rampRate" => 100.0, "initialQuantity" => 0.0, "emissionFactor" => 500.0),
			# not named in the lock, so it can cover the demand increase in a locked first MTU
			"5G_Peak" => Dict{String,Any}("bidPrice" => 80.0, "capacity" => 10.0, "rampRate" => 100.0, "initialQuantity" => 0.0, "emissionFactor" => 500.0),
		),
		:variableGenerators => Dict{String,Any}("7G_Solar" => Dict{String,Any}("bidPrice" => 0.0, "capacity" => 2.0, "profile" => solar_profile)),
		:demandSegments => Dict{String,Any}("D" => Dict{String,Any}("bidPrice" => 100.0, "profile" => demand_profile)),
		:batteryStorage => Dict{String,Any}("energyCapacity" => 0.0, "powerCapacity" => 0.0, "efficiency" => 0.9, "initialSOC" => 0.0, "endSOC" => 0.0),
		:timePeriodsPerDay => 24,
		:windOffset => 0,
		:optimizationModelConfig => Dict{String,Any}("demand_adjust" => true, "ex_post_transactions" => false, "restrict_mtu1_trading" => restrict),
	)
	initialization = Dict(:SOC => 0.0, :Q_gen => Dict("3G_Base" => 0.0, "4G_Shoulder" => 0.0, "5G_Peak" => 0.0, "7G_Solar" => 0.0))
	market = Dict{Symbol,Any}(:name => "TestMarket", :lookAheadDistance => look_ahead, :optimizationWindow => 3, :enforceRampRates => false, :overrideMTU1Restriction => override)
	return (data, initialization, market, demand_profile)
end

# clears t = 0, 1, 2 with the given model builder, returns the container. Demand rises at each later
# clearing's first MTU, which the locked generators can't follow - so something has to trade in the
# balancing MTU.
function clear_sequence(build, fixture; times=0:2)
	(data, initialization, market, demand_profile) = fixture
	container = MarketDataStorage.MakeMarketResultContainer()
	for t in times
		t > 0 && (demand_profile[demand_profile.mtu .== t, :Value] .= 12.0)
		m = build(t, container, initialization, data, market)
		optimize!(m)
		MarketDataStorage.AddMarketResult!(container, m, t, "TestMarket")
	end
	return container
end

models = [("LatestMarketModel", LatestMarketModel.build), ("TwoStageMarketModel", TwoStageMarketModel.build), ("StorageMipMarketModel", StorageMipMarketModel.build)]

for (model_name, build) in models
	@testset "Balancing/energy segment: $model_name" begin

		@testset "locked run tags the first MTU of every clearing after the first" begin
			fixture = balancing_segment_fixture(restrict=true)
			container = clear_sequence(build, fixture)

			# the first clearing has nothing to lock against; later ones lock their first MTU
			@test [mr.LockedMTU1 for mr in container.Results] == [nothing, 1, 2]

			tx = MarketDataStorage.GetTransactions(container)
			@test "Segment" in names(tx)
			@test names(tx)[end] == "Segment"
			@test Set(tx.Segment) <= Set(["Balancing", "Energy"])

			# Balancing is exactly the rows at the clearing MTU of a locked clearing
			balancing = tx[tx.Segment .== "Balancing", :]
			@test nrow(balancing) > 0
			@test all(balancing[!, "Market Time Unit"] .== balancing[!, "Clearing MTU"])
			@test all(balancing[!, "Clearing MTU"] .> 0)
			locked_rows = (tx[!, "Market Time Unit"] .== tx[!, "Clearing MTU"]) .& (tx[!, "Clearing MTU"] .> 0)
			@test (tx.Segment .== "Balancing") == locked_rows

			# the lock itself: the locked generators make no adjustment in their balancing rows
			@test !any(in.(balancing.Agent, Ref(["3G_Base", "4G_Shoulder", "7G_Solar"])))

			# partition: balancing and energy together are every transaction, none twice
			energy = tx[tx.Segment .== "Energy", :]
			@test nrow(balancing) + nrow(energy) == nrow(tx)
			@test sum(balancing[!, "Quantity (MWh)"]) + sum(energy[!, "Quantity (MWh)"]) ≈ sum(tx[!, "Quantity (MWh)"])
		end

		@testset "unlocked runs are all Energy" begin
			for fixture in (balancing_segment_fixture(restrict=false), balancing_segment_fixture(restrict=true, override=true))
				container = clear_sequence(build, fixture)
				@test all(isnothing, [mr.LockedMTU1 for mr in container.Results])
				@test all(MarketDataStorage.GetTransactions(container).Segment .== "Energy")
			end
		end

		@testset "a lock with a window that does not start at the clearing MTU fails loudly" begin
			fixture = balancing_segment_fixture(restrict=true, look_ahead=2)
			# the first clearing is never locked, so the failure comes with the second
			@test_throws ErrorException clear_sequence(build, fixture)
		end
	end
end

if !isdefined(Main, :BalancingEnergySplit)
	include("../src/lib/post_analysis/balancing_energy/balancing_energy_split.jl")
end

@testset "BalancingEnergySplit analysis" begin
	container = clear_sequence(LatestMarketModel.build, balancing_segment_fixture(restrict=true))
	tx = MarketDataStorage.GetTransactions(container)

	@testset "SplitSegments partitions the transactions" begin
		(balancing, energy) = BalancingEnergySplit.SplitSegments(tx)
		@test nrow(balancing) > 0 && nrow(energy) > 0
		@test nrow(balancing) + nrow(energy) == nrow(tx)
		@test all(balancing.Segment .== "Balancing") && all(energy.Segment .== "Energy")

		(b2, e2) = BalancingEnergySplit.SplitSegments(tx; time_range=1:1)
		@test all(vcat(b2, e2)[!, "Market Time Unit"] .== 1)
	end

	@testset "runs without a Segment column are rejected" begin
		@test_throws String BalancingEnergySplit.SplitSegments(select(tx, Not("Segment")))
	end

	@testset "PerformAnalysis writes the split tables and a summary" begin
		mktempdir() do dir
			case_path = joinpath(dir, "case")
			mkpath(case_path)
			XLSX.writetable(joinpath(case_path, "transactions.xlsx"), "data" => tx)
			output_base = joinpath(dir, "out")
			summary = BalancingEnergySplit.PerformAnalysis(Dict("Case A" => case_path); output_base=output_base)
			out = joinpath(output_base, "post_analysis_balancing_energy_split")
			@test isfile(joinpath(out, "transactions_balancing_case_a.xlsx"))
			@test isfile(joinpath(out, "transactions_energy_case_a.xlsx"))
			@test isfile(joinpath(out, "balancing_energy_summary.xlsx"))
			rows(segment) = summary[(summary.Indicator .== "Transactions") .& (summary."Agent Type" .== "All") .& (summary.Segment .== segment), "Case A"][1]
			@test rows("Balancing") + rows("Energy") == rows("Total") == nrow(tx)
		end
	end
end

if !isdefined(Main, :BalancingEnergySEW)
	include("../src/lib/post_analysis/balancing_energy/balancing_energy_sew.jl")
end

@testset "Energy-only final dispatch decisions and SEW by segment" begin
	container = clear_sequence(LatestMarketModel.build, balancing_segment_fixture(restrict=true))
	final = MarketDataStorage.GetFinalDispatchDecisions(container)
	energy = MarketDataStorage.GetEnergyFinalDispatchDecisions(container)
	tx = MarketDataStorage.GetTransactions(container)
	agents = ["D", "3G_Base", "4G_Shoulder", "5G_Peak", "7G_Solar"]

	@testset "decision variables carry the Segment of each row" begin
		# clearing t >= 1 locks its first MTU t, so the final row of every delivered MTU t >= 1 is a balancing row
		@test all(r.Segment == (r.mtu in (1, 2) ? "Balancing" : "Energy") for r in eachrow(final))
	end

	@testset "energy table has one row per MTU, none of them balancing" begin
		@test sort(energy.mtu) == sort(final.mtu)
		@test all(energy.Segment .== "Energy")
		@test "FinalAuctionPrice" in names(energy)
	end

	@testset "energy row of a balancing MTU is the dispatch from before the balancing clearing" begin
		for mtu in (1, 2), agent in agents
			@test energy[energy.mtu .== mtu, agent][1] ≈ final[final.mtu .== mtu, "Q_prev_$agent"][1]
		end
		# an MTU that was never a balancing MTU is unchanged
		for agent in agents
			@test energy[energy.mtu .== 0, agent][1] ≈ final[final.mtu .== 0, agent][1]
		end
	end

	@testset "an MTU with only balancing rows is rejected" begin
		only_balancing = [DataFrame(mtu=[5], price=[1.0], Segment=["Balancing"])]
		@test_throws String MarketDataStorage.EnergyFinalDispatchDecisions(only_balancing)
		@test_throws String MarketDataStorage.EnergyFinalDispatchDecisions([DataFrame(mtu=[5], price=[1.0])])
	end

	@testset "SEW by segment reconciles" begin
		E = BalancingEnergySEW
		agent_map = Dict(E.HelperModelResults.AGENT_DEMAND => ["D"], E.HelperModelResults.AGENT_GENERATOR => ["3G_Base", "4G_Shoulder", "5G_Peak", "7G_Solar"])
		result = E.SewBySegment(final, energy, tx, agent_map, 0:4) # throws if energy + balancing != total
		sew = result.values[result.indicator_names[1]]
		@test sew["Total"] ≈ sew["Energy"] + sew["Balancing"]
		# demand rises by 4 at each of the two balancing MTUs, bid 100, covered by the peaker at 80
		@test sew["Balancing"] ≈ 2 * 4 * (100 - 80)
		@test ismissing(result.values[result.indicator_names[7]]["Energy"]) && ismissing(result.values[result.indicator_names[7]]["Balancing"]) # imbalance energy: Total only
		@test ismissing(result.values["Mean Final Auction Price (€/MWh)"]["Balancing"])

		# runs from before the Segment column are rejected
		@test_throws String E.SewBySegment(select(final, Not(:Segment)), energy, tx, agent_map, 0:4)
	end
end

if !isdefined(Main, :BalancingEnergySurpluses)
	include("../src/lib/post_analysis/balancing_energy/balancing_energy_surpluses.jl")
end

@testset "Per-agent surplus by segment" begin
	S = BalancingEnergySurpluses
	container = clear_sequence(LatestMarketModel.build, balancing_segment_fixture(restrict=true))
	final = MarketDataStorage.GetFinalDispatchDecisions(container)
	energy = MarketDataStorage.GetEnergyFinalDispatchDecisions(container)
	tx = MarketDataStorage.GetTransactions(container)
	agent_map = Dict(S.HelperModelResults.AGENT_DEMAND => ["D"], S.HelperModelResults.AGENT_GENERATOR => ["3G_Base", "4G_Shoulder", "5G_Peak", "7G_Solar"])
	agents = ["D", "3G_Base", "4G_Shoulder", "5G_Peak", "7G_Solar"]

	result = S.AgentSurplusBySegment(final, energy, tx, agent_map, 0:4; agents=agents) # throws if energy + balancing != total per agent

	@testset "per-agent surpluses add up" begin
		for agent in agents
			@test result[agent]["Energy"] + result[agent]["Balancing"] ≈ result[agent]["Total"]
		end
	end

	@testset "the locked generators have no balancing surplus" begin
		for agent in ["3G_Base", "4G_Shoulder", "7G_Solar"]
			@test result[agent]["Balancing"] == 0.0
		end
	end

	@testset "demand gets the balancing welfare, the peaker is price-setting" begin
		# +4 MWh at bid 100 served by the peaker at 80, at two balancing MTUs; the peaker sets the 80 price
		@test result["D"]["Balancing"] ≈ 2 * 4 * (100 - 80)
		@test result["5G_Peak"]["Balancing"] ≈ 0.0 atol=1e-6
	end

	@testset "table has Total/Energy/Balancing per case and no Balancing % Diff" begin
		table = S.SurplusTable(["Base", "Subject"], Dict("Base" => result, "Subject" => result); agents=agents)
		@test nrow(table) == length(agents)
		@test "Subject vs Base Energy % Diff" in names(table)
		@test all(table[!, "Subject vs Base Balancing % Diff"] .== "—")
	end

	@testset "runs without a Segment column are rejected" begin
		@test_throws String S.AgentSurplusBySegment(select(final, Not(:Segment)), energy, tx, agent_map, 0:4; agents=agents)
	end
end

if !isdefined(Main, :BalancingEnergyQuantities)
	include("../src/lib/post_analysis/balancing_energy/balancing_energy_quantities.jl")
end

@testset "Quantity and gross traded volume by segment" begin
	Q = BalancingEnergyQuantities
	container = clear_sequence(LatestMarketModel.build, balancing_segment_fixture(restrict=true))
	final = MarketDataStorage.GetFinalDispatchDecisions(container)
	energy = MarketDataStorage.GetEnergyFinalDispatchDecisions(container)
	tx = MarketDataStorage.GetTransactions(container)
	agent_map = Dict(Q.BalancingEnergySEW.HelperModelResults.AGENT_DEMAND => ["D"], Q.BalancingEnergySEW.HelperModelResults.AGENT_GENERATOR => ["3G_Base", "4G_Shoulder", "5G_Peak", "7G_Solar"])
	agents = ["D", "3G_Base", "4G_Shoulder", "5G_Peak", "7G_Solar"]

	@testset "quantities add up and the balancing adjustment is the demand increase" begin
		q = Q.AgentQuantityBySegment(final, energy, tx, agent_map, 0:4; agents=agents) # throws if energy + balancing != total
		for agent in agents
			@test q[agent]["Energy"] + q[agent]["Balancing"] ≈ q[agent]["Total"]
		end
		# +4 MWh of demand at each of the two balancing MTUs, all supplied by the peaker
		@test q["D"]["Balancing"] ≈ 8.0
		@test q["5G_Peak"]["Balancing"] ≈ 8.0
		for agent in ["3G_Base", "4G_Shoulder", "7G_Solar"]
			@test q[agent]["Balancing"] == 0.0
		end
	end

	@testset "gross traded volume partitions by segment" begin
		g = Q.GrossTradedVolumeBySegment(tx, 0:4; generators=["3G_Base", "4G_Shoulder", "5G_Peak", "7G_Solar"])
		for (agent, by_segment) in g
			@test by_segment["Energy"] + by_segment["Balancing"] ≈ by_segment["Total"]
		end
		@test g["5G_Peak"]["Balancing"] ≈ 8.0
		@test g["3G_Base"]["Balancing"] == 0.0
	end

	@testset "runs without a Segment column are rejected" begin
		@test_throws String Q.AgentQuantityBySegment(select(final, Not(:Segment)), energy, tx, agent_map, 0:4; agents=agents)
		@test_throws String Q.GrossTradedVolumeBySegment(select(tx, Not("Segment")), 0:4; generators=["5G_Peak"])
	end
end

@testset "Storage by segment" begin
	Q = BalancingEnergyQuantities
	(data, initialization, market, demand_profile) = balancing_segment_fixture(restrict=true)
	data[:batteryStorage] = Dict{String,Any}("energyCapacity" => 20.0, "powerCapacity" => 5.0, "efficiency" => 0.9, "initialSOC" => 0.0, "endSOC" => 0.0)
	# cheap-then-dear demand (base at 20, then shoulder at 50) so that storage has something to arbitrage
	demand_profile[demand_profile.mtu .>= 2, :Value] .= 16.0
	container = clear_sequence(LatestMarketModel.build, (data, initialization, market, demand_profile))
	final = MarketDataStorage.GetFinalDispatchDecisions(container)
	energy = MarketDataStorage.GetEnergyFinalDispatchDecisions(container)
	tx = MarketDataStorage.GetTransactions(container)
	agent_map = Dict(Q.BalancingEnergySEW.HelperModelResults.AGENT_DEMAND => ["D"], Q.BalancingEnergySEW.HelperModelResults.AGENT_GENERATOR => ["3G_Base", "4G_Shoulder", "5G_Peak", "7G_Solar"])
	storage_tx = tx[tx.Agent .== "Storage", :]

	@testset "storage revenue partitions by segment" begin
		@test nrow(storage_tx) > 0 # otherwise this testset checks nothing
		result = Q.BalancingEnergySEW.SewBySegment(final, energy, tx, agent_map, 0:4) # throws if energy + balancing != total
		rev = result.values[result.indicator_names[6]] # storage revenue
		@test rev["Total"] ≈ rev["Energy"] + rev["Balancing"]
		@test rev["Total"] ≈ sum(storage_tx[0 .<= storage_tx[!, "Market Time Unit"] .<= 4, "Quantity (MWh)"] .* storage_tx[0 .<= storage_tx[!, "Market Time Unit"] .<= 4, "Price (€/MWh)"])
	end

	@testset "storage flows: total from the final dispatch, energy from the energy-only dispatch" begin
		flows = Q.StorageFlowsBySegment(final, energy, 0:4)
		@test flows["Discharge"]["Total"] ≈ sum(final[0 .<= final.mtu .<= 4, :StorageDischarge])
		@test flows["Charge"]["Energy"] ≈ sum(energy[0 .<= energy.mtu .<= 4, :StorageCharge])
		table = Q.StorageFlowTable(["Base", "Subject"], Dict("Base" => flows, "Subject" => flows))
		@test table.Flow == ["Storage discharged", "Storage charged"]
		@test "Subject vs Base Energy % Diff" in names(table)
		@test_throws String Q.StorageFlowsBySegment(select(final, Not(:Segment)), energy, 0:4)
	end
end

@testset "Float noise in segment values is reported as zero" begin
	noise = DataFrame("Quantity (MWh)" => [1.5, -1.5 + 1e-13, 2e-13], "Price (€/MWh)" => [40.0, 40.0, 40.0])
	totals = BalancingEnergySplit.SegmentTotals(noise)
	@test totals.net_mwh == 0.0
	@test totals.net_payments == 0.0
	@test totals.rows == 3
	@test totals.gross_mwh ≈ 3.0
end

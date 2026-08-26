module MarketDataStorage

using Dates, JuMP, MathOptInterface, DataFrames

# this library fetches data from a JuMP optimization model
using ..Helpers.HelperModelResults

include("./table_header_renaming.jl")

# Storage format for results of each market clearing 
# this is an update from ProcessData.ClearingData struct type with more explicit relation between MTUs and decision variables 
# removed fields here for WIP notes

mutable struct MarketResult
	# when stored
	Timestamp::DateTime

	# market definition
	MarketName::String
	TimeCleared::Int
	# BaseTimePeriod::Int
	OptimizationWindow::UnitRange{Int}
	AgentMap::Dict{HelperModelResults.AgentTypeEnum, Vector{String}}
	VariableGenerators::Vector{String}
	# model optimization outcome
	TerminationStatus::MathOptInterface.TerminationStatusCode
	ObjectiveValue::Number

	# detailed outcomes for market agents
	DecisionVariables::DataFrame
	Transactions::DataFrame

	MarketResult() = new()
end

# Storage for overall results with cache for faster data access

mutable struct MarketResultContainer

	Results::Vector{MarketResult}
	TransactionsCache::Union{DataFrame, Nothing}
	DecisionVariablesCache::Union{DataFrame, Nothing}
	DecisionVariablesCacheBust::Bool
	TransactionsCacheBust::Bool
	StorageAnomalies::Union{DataFrame, Nothing}
	AdjustmentAnomalies::Union{DataFrame, Nothing}

	MarketResultContainer() = new()
end

function MakeMarketResultContainer()
	mrc = MarketResultContainer()
	mrc.Results = Vector{MarketResult}()
	mrc.DecisionVariablesCacheBust = true
	mrc.TransactionsCacheBust = true
	mrc.TransactionsCache = nothing
	mrc.DecisionVariablesCache = nothing
	mrc.StorageAnomalies = nothing
	mrc.AdjustmentAnomalies = nothing
	return mrc
end



# generate a new MarketResult and add to MarketResultContainer, bust cache

function AddMarketResult!(market_result_container, model, time_cleared, market_name)
	optimization_window = HelperModelResults.OptimizationWindow(model)
	agent_map = HelperModelResults.AgentMap(model)


	mr = MarketResult()
	mr.Timestamp = Dates.now()
	mr.MarketName = market_name
	mr.TimeCleared = time_cleared # MTU
	mr.OptimizationWindow = optimization_window # range(MTU,MTU)
	mr.AgentMap = agent_map
	mr.VariableGenerators = HelperModelResults.VariableGenerators(model)
	mr.TerminationStatus = termination_status(model)
	mr.ObjectiveValue = objective_value(model)
	mr.DecisionVariables = HelperModelResults.DecisionVariables(optimization_window, agent_map, model) # todo: docs on this
	(transactions, adjustment_anomalies) = HelperModelResults.Transactions(mr, GetFinalDispatchDecisions(market_result_container), market_name, market_result_container.Results, model) # todo: docs on this
	mr.Transactions = transactions

	push!(market_result_container.Results, mr)
	AddDecisionVariablesToCache!(market_result_container, mr)
	AddTransactionsToCache!(market_result_container, mr)
	AddStorageAnomalies!(market_result_container, mr)
	AddAdjustmentAnomalies!(market_result_container, adjustment_anomalies)
	# CacheBust!(market_result_container)
end

function CacheBust!(market_result_container)
	market_result_container.DecisionVariablesCacheBust = true
	market_result_container.TransactionsCacheBust = true
end

# TODO: replicate helpers for data access from ProcessData
# TODO: Think of an elegant filter struct/approach

# Ideas for how to structure

# function FinalDispatchDecisions(resultset, filter)

# function SOCForMTU(resultset, mtu)
	# uses FinalDispatchDecisions

# function Prices(resultset)
	# uses FinalDispatchDecisions

# function Quantities(resultset, filter)
	# uses FinalDispatchDecisions

# function GenQuantities(resultset, filter)
	# uses FinalDispatchDecisions

function GenQuantities(market_result_container, mtu_range)
	mr = GetFinalDispatchDecisions(market_result_container)
	gens = market_result_container.Results[1].AgentMap[HelperModelResults.AGENT_GENERATOR]

	quantities = Dict{String,Vector{Float64}}()
	for gName in gens
		quantities[gName] = zeros(length(mtu_range))
		for (i, mtu) in enumerate(mtu_range)
			matches = mr[mr.mtu .== mtu, gName]
			quantities[gName][i] = length(matches) > 0 ? matches[1] : 0.0
		end
	end

	return quantities
end

# function Transactions(resultset, filter)

# function EconomicOutcomes(resultset, filter)
	# uses Transactions, FinalDispatchDecisions


# This function takes market_result_container and gets the latest decision variable of column_name for a particular mtu

function DecisionVariableValueForTimePeriod(market_result_container, column_name, mtu)
	previous_value = 0.0
	has_previous_value = false
	for marketresult in market_result_container.Results
		if mtu in marketresult.OptimizationWindow
			dvs = marketresult.DecisionVariables
			previous_value = dvs[dvs.mtu .== mtu, Symbol(column_name)][1]
			has_previous_value = true
		end
	end
	return (previous_value, has_previous_value)
end

function TransactionQuantitySumValueForMTU(market_result_container, agent_name, mtu)
	previous_value = 0.0
	has_previous_value = false
	length(market_result_container.Results) == 0 && return (previous_value, has_previous_value)
	transactions = GetTransactions(market_result_container)
	previous_value = combine(transactions[transactions[!, "Market Time Unit"] .== mtu .&& transactions[!, "Agent"] .== agent_name, :], Symbol("Quantity (MWh)") => sum)[1,1]
	return (previous_value, has_previous_value)
end

# This function takes market_result_container and gets the latest dispatch for a generator for a particular mtu

function GenPreviousDispatchDataForTimePeriod(market_result_container, generator, mtu)
	(previous_value, has_previous_value) = TransactionQuantitySumValueForMTU(market_result_container, generator, mtu)
	return previous_value
end

# This function takes market_result_container and gets the latest dispatch for a demand for a particular mtu

function DemPreviousDispatchDataForTimePeriod(market_result_container, demand, mtu)
	(previous_value, has_previous_value) = TransactionQuantitySumValueForMTU(market_result_container, demand, mtu)
	return previous_value
end

# This function takes market_result_container and gets the latest dispatch for a demand for a particular mtu

function StorageSOCForTimePeriod(market_result_container, mtu)
	return DecisionVariableValueForTimePeriod(market_result_container, "SOC", mtu)
end


# this function gets final dispatch decisions from decisionvariables and merges them into a single dataframe (or uses a cached version)
function GetFinalDispatchDecisions(market_result_container)
	if !market_result_container.DecisionVariablesCacheBust
		return market_result_container.DecisionVariablesCache
	end
	finalDispatchDecisions = DataFrame()

	if length(market_result_container.Results) == 0
		return finalDispatchDecisions
	end

	for marketresult in market_result_container.Results
		dvs = marketresult.DecisionVariables
		finalDispatchDecisions = vcat(finalDispatchDecisions, dvs)
	end

	finalDispatchDecisions = unique!(finalDispatchDecisions, "mtu"; keep=:last)

	select!(finalDispatchDecisions,Not(["price"]))
	market_result_container.DecisionVariablesCache = finalDispatchDecisions
	market_result_container.DecisionVariablesCacheBust = false
	return finalDispatchDecisions

end

# add new decision variables from latest market result to existing cached version for speedier update

function AddDecisionVariablesToCache!(market_result_container, mr)
	finalDispatchDecisions = something(market_result_container.DecisionVariablesCache, DataFrame())

	dvs = mr.DecisionVariables
	select!(dvs,Not(["price"]))
	finalDispatchDecisions = vcat(finalDispatchDecisions, dvs)
	finalDispatchDecisions = unique!(finalDispatchDecisions, "mtu"; keep=:last)

	market_result_container.DecisionVariablesCache = finalDispatchDecisions
	market_result_container.DecisionVariablesCacheBust = false
end

# this function gets all transactions and merges them into a single dataframe (or uses a cached version)

function GetTransactions(market_result_container)
	if !market_result_container.TransactionsCacheBust
		return market_result_container.TransactionsCache
	end
	all_transactions = DataFrame()

	if length(market_result_container.Results) == 0
		return all_transactions
	end

	for marketresult in market_result_container.Results
		transactions = marketresult.Transactions
		all_transactions = vcat(all_transactions, transactions)
	end
	market_result_container.TransactionsCache = all_transactions
	market_result_container.TransactionsCacheBust = false
	return all_transactions
end


# add new transactions from latest market result to existing cached version for speedier update

function AddTransactionsToCache!(market_result_container, mr)
	all_transactions = something(market_result_container.TransactionsCache, DataFrame())

	transactions = mr.Transactions
	all_transactions = vcat(all_transactions, transactions)

	market_result_container.TransactionsCache = all_transactions
	market_result_container.TransactionsCacheBust = false
end


# add new decision variables from latest market result to existing cached version for speedier update

function AddStorageAnomalies!(market_result_container, mr)
	storageAnomalies = something(market_result_container.StorageAnomalies, DataFrame())

	dvs = mr.DecisionVariables
	anomalies = filter(row -> row.StorageCharge > 0 && row.StorageDischarge > 0, dvs)
	anomalies.ClearingMTU .= mr.TimeCleared
	storageAnomalies = vcat(storageAnomalies, anomalies)
	
	market_result_container.StorageAnomalies = storageAnomalies
end

function PrintStorageAnomalies(market_result_container)
	println(market_result_container.StorageAnomalies)
end

# add adjustment irregularities (adjustment quantity disagreeing with dispatch - previous dispatch) from the latest market result to the existing cached version

function AddAdjustmentAnomalies!(market_result_container, adjustment_anomalies)
	existing = something(market_result_container.AdjustmentAnomalies, DataFrame())
	market_result_container.AdjustmentAnomalies = vcat(existing, adjustment_anomalies)
end

function PrintAdjustmentAnomalies(market_result_container)
	println(market_result_container.AdjustmentAnomalies)
end

# This function takes market_result_container and gets the final dispatch decisions over a range of mtus

function GetFinalDispatchDecisionsForRange(market_result_container,time_range)
	finalDispatchDecisions = GetFinalDispatchDecisions(market_result_container)
	if nrow(finalDispatchDecisions) == 0
		return finalDispatchDecisions
	end
	return finalDispatchDecisions[(time_range.start .<= finalDispatchDecisions.mtu .<= time_range.stop), :]
end

function GetTransactionsForRange(market_result_container,time_range)
	transactions = GetTransactions(market_result_container)
	if nrow(transactions) == 0
		return transactions
	end
	return transactions[(time_range.start .<= transactions[!, "Market Time Unit"] .<= time_range.stop), :]
end


# snaps values within atol of zero to exactly 0.0, so downstream near-zero float noise doesn't get reported as a nonzero indicator
function snap0(x, atol=1e-4)
	return isapprox(x, 0.0; atol=atol) ? 0.0 : x
end

# raw (unsnapped) quantity/utility/payments/revenue/fuel_cost/surplus for one agent, over
# whatever (already time-range-filtered) finalDispatchDecisions/transactions subset is passed in -
# shared by both the whole-range and per-mtu aggregations in GetEconomicIndicatorsForRange
function AgentEconomicMetrics(finalDispatchDecisions, transactions, a_type, agent, payrev_symbol)
	quantity = combine(finalDispatchDecisions, Symbol(agent) => sum)[1,1]
	load_utility = (a_type == HelperModelResults.AGENT_DEMAND) ? combine(finalDispatchDecisions, Symbol("utility_$agent") => sum)[1,1] : 0.0
	payments = (a_type == HelperModelResults.AGENT_DEMAND) ? combine((transactions[transactions.Agent .== agent, :]), payrev_symbol => sum)[1,1] : 0.0
	revenue = (a_type == HelperModelResults.AGENT_GENERATOR) ? combine((transactions[transactions.Agent .== agent, :]), payrev_symbol => sum)[1,1] : 0.0
	fuel_cost = (a_type == HelperModelResults.AGENT_GENERATOR) ? combine(finalDispatchDecisions, Symbol("fuelcost_$agent") => sum)[1,1] : 0.0
	surplus = (load_utility - payments) + (revenue - fuel_cost)
	return (quantity=quantity, load_utility=load_utility, payments=payments, revenue=revenue, fuel_cost=fuel_cost, surplus=surplus)
end

function GetEconomicIndicatorsForRange(market_result_container,time_range)

	economic_indicators = DataFrame(SEW=[], DemandUtility=[], ProductionCosts=[], ProducerSurplus=[],ConsumerSurplus=[],StorageRevenue=[])# , WeightedAveragePrice=[])
	agent_indicators = DataFrame(Agent=[],Quantity=[],LoadUtility=[],Payments=[],Revenue=[],FuelCost=[],Surplus=[],SOCChange=[])
	mtu_economic_indicators = DataFrame(MTU=[], SEW=[], DemandUtility=[], ProductionCosts=[], ProducerSurplus=[],ConsumerSurplus=[],StorageRevenue=[])

	# get data from market clearing
	finalDispatchDecisions = GetFinalDispatchDecisionsForRange(market_result_container,time_range)
	transactions = GetTransactionsForRange(market_result_container,time_range)

	if length(market_result_container.Results) < 1
		return (economic_indicators, agent_indicators, transactions, finalDispatchDecisions, mtu_economic_indicators)
	end

	# add calculated columns to transactions
	quantity_symbol = Symbol("Quantity (MWh)")
	price_symbol = Symbol("Price (€/MWh)")
	payrev_symbol = Symbol("Payments/Revenues (€)")
	mtu_symbol = Symbol("Market Time Unit")

	transactions[!, payrev_symbol] = transactions[!, quantity_symbol] .* transactions[!, price_symbol]

	# handle gens and demands
	agentMap = market_result_container.Results[1].AgentMap

	display_order = [HelperModelResults.AGENT_DEMAND, HelperModelResults.AGENT_GENERATOR]

	for a_type in display_order
		agents = agentMap[a_type] 
		for agent in agents
			# add some calculated columns
			if (a_type == HelperModelResults.AGENT_DEMAND)
				finalDispatchDecisions[!, Symbol("utility_$agent")] = finalDispatchDecisions[!, Symbol(agent)] .* finalDispatchDecisions[!, Symbol("P_$agent")]
			end
			if (a_type == HelperModelResults.AGENT_GENERATOR)
				finalDispatchDecisions[!, Symbol("fuelcost_$agent")] = finalDispatchDecisions[!, Symbol(agent)] .* finalDispatchDecisions[!, Symbol("P_$agent")]
			end
			metrics = AgentEconomicMetrics(finalDispatchDecisions, transactions, a_type, agent, payrev_symbol)

			push!(agent_indicators, [agent, snap0(metrics.quantity), snap0(metrics.load_utility), snap0(metrics.payments), snap0(metrics.revenue), snap0(metrics.fuel_cost), snap0(metrics.surplus), 0.0])

		end
	end
	# think more deeply about this - the storage charge should be treated differently? I think abs will behave improperly if the price is negative 
	#=
	total_exchanged_value = combine(transactions, payrev_symbol => (x -> sum(abs.(x))))[1,1]
	total_exchanged_quantity = combine(transactions, quantity_symbol => (x -> sum(abs.(x))))[1,1] 
	
	weighted_average_price = total_exchanged_value/total_exchanged_quantity
	=#
	# plus special handling for storage

	storage_revenue = combine((transactions[transactions.Agent .== "Storage", :]), payrev_symbol => sum)[1,1]
	# like this we report out the sum quantity of energy charged and discharged - the difference is also interesting
	storage_quantity = 	combine(finalDispatchDecisions, :StorageDischarge => sum)[1,1] # + combine(finalDispatchDecisions, :StorageCharge => sum)[1,1]
	



	(storage_soc_begin, has_soc_begin) = StorageSOCForTimePeriod(market_result_container, time_range.start - 1)

	(storage_soc_end, has_soc_end) = StorageSOCForTimePeriod(market_result_container, time_range.stop)

	if !has_soc_begin || !has_soc_end
		println("WARNING: SOC begin or end not found. change reported may be invalid.")
	end

	println("SOC BEGIN = $storage_soc_begin SOC END = $storage_soc_end")

	storage_soc_change = storage_soc_end - storage_soc_begin


	#=


	# which MTUs had storage charge and discharge quantities in their final dispatch 
	# TODO: think about how to approach MTUs where no charge or discharge appeared in final dispatch
	charge_mtus = finalDispatchDecisions[finalDispatchDecisions.StorageCharge .> 0.0, :].mtu
	discharge_mtus = finalDispatchDecisions[finalDispatchDecisions.StorageDischarge .> 0.0, :].mtu

	println("charge MTUs: $charge_mtus")
	println("discharge MTUs: $discharge_mtus")

	
	storage_discharge_transaction_quantity = combine(transactions[(transactions.Agent .== "Storage" .&& transactions[!, mtu_symbol] in discharge_mtus), :], quantity_symbol => sum)[1,1]

	storage_charge_transaction_quantity = combine(transactions[(transactions.Agent .== "Storage" .&& transactions[!, mtu_symbol] in charge_mtus), :], quantity_symbol => sum)[1,1]


	storage_avg_discharge_price = combine(transactions[(transactions.Agent .== "Storage" .&& transactions[!, payrev_symbol] .> 0.0), :], payrev_symbol => sum)[1,1] / combine(transactions[(transactions.Agent .== "Storage" .&& transactions[!, payrev_symbol] .> 0.0), :], quantity_symbol => sum)[1,1]

	storage_avg_charge_price = combine(transactions[(transactions.Agent .== "Storage" .&& transactions[!, payrev_symbol] .< 0.0), :], payrev_symbol => sum)[1,1] / combine(transactions[(transactions.Agent .== "Storage" .&& transactions[!, payrev_symbol] .< 0.0), :], quantity_symbol => sum)[1,1]


	println("discharge transaction quantity: ", storage_discharge_transaction_quantity)
	println("charge transaction quantity: ", storage_charge_transaction_quantity)

	println("avg discharge price: ", storage_avg_discharge_price)
	println("avg charge price: ", storage_avg_charge_price)

    =#

	storage_revenue = snap0(storage_revenue)
	storage_quantity = snap0(storage_quantity)
	
	# note that revenue here is also reported as SEW, assuming no costs
	push!(agent_indicators, ["Storage", storage_quantity, 0.0, 0.0, storage_revenue, 0.0, storage_revenue, storage_soc_change])
	
	demand_utility = combine((agent_indicators[ [a in agentMap[HelperModelResults.AGENT_DEMAND] for a in agent_indicators[!, :Agent]], :]), :LoadUtility => sum)[1,1]
	production_costs = combine((agent_indicators[ [a in agentMap[HelperModelResults.AGENT_GENERATOR] for a in agent_indicators[!, :Agent]], :]), :FuelCost => sum)[1,1]
	consumer_surplus = combine((agent_indicators[ [a in agentMap[HelperModelResults.AGENT_DEMAND] for a in agent_indicators[!, :Agent]], :]), :Surplus => sum)[1,1] 
	producer_surplus = combine((agent_indicators[ [a in agentMap[HelperModelResults.AGENT_GENERATOR] for a in agent_indicators[!, :Agent]], :]), :Surplus => sum)[1,1] 
	sew = demand_utility - production_costs
	push!(economic_indicators,[sew, demand_utility, production_costs, producer_surplus,consumer_surplus,storage_revenue]) #,weighted_average_price])

	for mtu in time_range
		mtu_storage_revenue = snap0(combine((transactions[transactions.Agent .== "Storage" .&& transactions[!, mtu_symbol] .== mtu, :]), payrev_symbol => sum)[1,1])
		mtu_consumer_surplus = 0.0
		mtu_producer_surplus = 0.0
		mtu_demand_utility = 0.0
		mtu_production_costs = 0.0
		mtu_finalDispatchDecisions = finalDispatchDecisions[finalDispatchDecisions.mtu .== mtu, :]
		mtu_transactions = transactions[transactions[!, mtu_symbol] .== mtu, :]
		for (a_type, agents) in agentMap
			for agent in agents
				metrics = AgentEconomicMetrics(mtu_finalDispatchDecisions, mtu_transactions, a_type, agent, payrev_symbol)
				mtu_load_utility = snap0(metrics.load_utility)
				mtu_fuel_cost = snap0(metrics.fuel_cost)
				mtu_surplus = snap0(metrics.surplus)

				# note: more per agent economic info here that is not being reported out yet

				if a_type == HelperModelResults.AGENT_DEMAND
					mtu_consumer_surplus += mtu_surplus
					mtu_demand_utility += mtu_load_utility
				else
					mtu_producer_surplus += mtu_surplus
					mtu_production_costs += mtu_fuel_cost
				end
			end
		end


		mtu_sew = mtu_demand_utility - mtu_production_costs
		push!(mtu_economic_indicators,[mtu, mtu_sew, mtu_demand_utility, mtu_production_costs,  mtu_producer_surplus,mtu_consumer_surplus,mtu_storage_revenue]) #,weighted_average_price])

	end

	TableHeaderRenaming.RenameDataFrameHeaders!(agent_indicators, "agent_indicators")
	TableHeaderRenaming.RenameDataFrameHeaders!(economic_indicators, "economic_indicators")
	TableHeaderRenaming.RenameDataFrameHeaders!(mtu_economic_indicators, "economic_indicators")


	return (economic_indicators, agent_indicators, transactions, finalDispatchDecisions, mtu_economic_indicators)
end

# CO2e emissions from conventional (dispatchable) generators over a range of mtus, based on
# each generator's configured emissionFactor (kgCO2e/MWh). Variable generators (wind, solar)
# have no emissionFactor in the agent configuration and are excluded, since they're zero-emission.
function GetEmissionsForRange(market_result_container, config, time_range)
	emissions = DataFrame(Generator=String[], Quantity=Float64[], EmissionFactor=Float64[], Emissions=Float64[])

	finalDispatchDecisions = GetFinalDispatchDecisionsForRange(market_result_container, time_range)
	if nrow(finalDispatchDecisions) == 0
		return emissions
	end

	for (gName, gConfig) in config[:dispatchableGenerators]
		quantity = combine(finalDispatchDecisions, Symbol(gName) => sum)[1,1] # MWh
		emission_factor = float(gConfig["emissionFactor"]) # kgCO2e/MWh
		generator_emissions = quantity * emission_factor / 1000.0 # tCO2e
		push!(emissions, [gName, quantity, emission_factor, generator_emissions])
	end

	return emissions
end

end;
module MarketDataStorage

using Dates, JuMP, MathOptInterface, DataFrames

# this library fetches data from a JuMP optimization model
using ..Helpers.HelperModelResults

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

	# model optimization outcome
	TerminationStatus::MathOptInterface.TerminationStatusCode
	ObjectiveValue::Number
	#=TimePeriods::Vector{Int}
	Prices::Vector{Number}
	GenData::Dict{String, Vector{Float64}}
	BidPrices::Dict{String, Vector{Float64}} # gens and demands
	DemandData::Dict{String, Vector{Float64}}
	StorageDischargeQuantities::Vector{Float64} # TODO: should rethink data format here for storage
	StorageChargeQuantities::Vector{Float64}
	StorageStateOfCharge::Vector{Float64} =#

	# detailed outcomes for market agents
	DecisionVariables::DataFrame
	Transactions::DataFrame

	MarketResult() = new()
end

# generate a new market result and add to resultset
# big TODO here: make the helper for making the DecisionVariables matrix and rebuild transaction generation

function AddMarketResult!(resultset, model, time_cleared, market_name)
	optimization_window = HelperModelResults.OptimizationWindow(model)
	agent_map = HelperModelResults.AgentMap(model)


	mr = MarketResult()
	mr.Timestamp = Dates.now()
	mr.MarketName = market_name
	mr.TimeCleared = time_cleared # MTU
	mr.OptimizationWindow = optimization_window # range(MTU,MTU)
	mr.AgentMap = agent_map
	mr.TerminationStatus = termination_status(model)
	mr.ObjectiveValue = objective_value(model)
	mr.DecisionVariables = HelperModelResults.DecisionVariables(optimization_window, agent_map, model) # todo: docs on this
	mr.Transactions = HelperModelResults.Transactions(mr, GetMarketResults(resultset), market_name) # todo: docs on this

	push!(resultset, mr)
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

# function Transactions(resultset, filter)

# function EconomicOutcomes(resultset, filter)
	# uses Transactions, FinalDispatchDecisions


# This function takes marketresults and gets the latest decision variable of column_name for a particular mtu

function DecisionVariableValueForTimePeriod(marketresults, column_name, mtu)
	previous_value = 0.0
	has_previous_value = false
	for marketresult in marketresults
		if mtu in marketresult.OptimizationWindow
			dvs = marketresult.DecisionVariables
			previous_value = dvs[dvs.mtu .== mtu, Symbol(column_name)][1]
			has_previous_value = true
		end
	end
	return (previous_value, has_previous_value)
end

# This function takes marketresults and gets the latest dispatch for a generator for a particular mtu

function GenPreviousDispatchDataForTimePeriod(marketresults, generator, mtu)
	(previous_value, has_previous_value) = DecisionVariableValueForTimePeriod(marketresults, generator, mtu)
	return previous_value
end

# This function takes marketresults and gets the latest dispatch for a demand for a particular mtu

function DemPreviousDispatchDataForTimePeriod(marketresults, demand, mtu)
	(previous_value, has_previous_value) = DecisionVariableValueForTimePeriod(marketresults, demand, mtu)
	return previous_value
end

# This function takes marketresults and gets the latest dispatch for a demand for a particular mtu

function StorageSOCForTimePeriod(marketresults, mtu)
	return DecisionVariableValueForTimePeriod(marketresults, "SOC", mtu)
end


# this function gets all market results from decisionvariables and merges them into a single dataframe
function GetMarketResults(marketresults)
	finalMarketResults = DataFrame()

	if length(marketresults) == 0
		return finalMarketResults
	end

	for marketresult in marketresults
		dvs = marketresult.DecisionVariables
		finalMarketResults = vcat(finalMarketResults, dvs)
	end

	finalMarketResults = unique!(finalMarketResults, "mtu"; keep=:last)


	return finalMarketResults

end

function GetTransactions(marketresults)
	all_transactions = DataFrame()

	if length(marketresults) == 0
		return all_transactions
	end

	for marketresult in marketresults
		transactions = marketresult.Transactions
		all_transactions = vcat(all_transactions, transactions)
	end
	return all_transactions
end

# This function takes marketresults and gets the latest dispatch over a range of mtus

function GetMarketResultsForRange(marketresults,time_range)
	finalMarketResults = GetMarketResults(marketresults)
	if nrow(finalMarketResults) == 0
		return finalMarketResults
	end
	return finalMarketResults[(time_range.start .<= finalMarketResults.mtu .<= time_range.stop), :]
end

function GetTransactionsForRange(marketresults,time_range)
	transactions = GetTransactions(marketresults)
	if nrow(transactions) == 0
		return transactions
	end
	return transactions[(time_range.start .<= transactions[!, "Market Time Unit"] .<= time_range.stop), :]
end


function GetEconomicIndicatorsForRange(marketresults,time_range)
	
	indicators = DataFrame(SEW=[],ProducerSurplus=[],ConsumerSurplus=[],StorageRevenue=[])# , WeightedAveragePrice=[])
	agent_indicators = DataFrame(Agent=[],Quantity=[],LoadUtility=[],Payments=[],Revenue=[],FuelCost=[],Surplus=[])

	if length(marketresults) < 1
		return (indicators, agent_indicators)
	end

	# get data from market clearing
	finalMarketResults = GetMarketResultsForRange(marketresults,time_range)
	transactions = GetTransactionsForRange(marketresults,time_range)

	# add calculated columns to transactions
	quantity_symbol = Symbol("Quantity (MWh)")
	price_symbol = Symbol("Price (€/MWh)")
	payrev_symbol = Symbol("Payments/Revenues (€)")

	transactions[!, payrev_symbol] = transactions[!, quantity_symbol] .* transactions[!, price_symbol]

	# handle gens and demands
	agentMap = marketresults[1].AgentMap

	for (a_type, agents) in agentMap 
		for agent in agents
			# add some calculated columns
			if (a_type == HelperModelResults.AGENT_DEMAND)
				finalMarketResults[!, Symbol("utility_$agent")] = finalMarketResults[!, Symbol(agent)] .* finalMarketResults[!, Symbol("P_$agent")]
			end
			if (a_type == HelperModelResults.AGENT_GENERATOR)
				finalMarketResults[!, Symbol("fuelcost_$agent")] = finalMarketResults[!, Symbol(agent)] .* finalMarketResults[!, Symbol("P_$agent")]
			end
			quantity = combine(finalMarketResults, Symbol(agent) => sum)[1,1]
			load_utility = (a_type == HelperModelResults.AGENT_DEMAND) ? combine(finalMarketResults, Symbol("utility_$agent") => sum)[1,1] : 0.0
			payments = (a_type == HelperModelResults.AGENT_DEMAND) ? combine((transactions[transactions.Agent .== agent, :]), payrev_symbol => sum)[1,1] : 0.0
			revenue = (a_type == HelperModelResults.AGENT_GENERATOR) ? combine((transactions[transactions.Agent .== agent, :]), payrev_symbol => sum)[1,1] : 0.0
			fuel_cost = (a_type == HelperModelResults.AGENT_GENERATOR) ? combine(finalMarketResults, Symbol("fuelcost_$agent") => sum)[1,1] : 0.0
			surplus = (load_utility - payments) + (revenue - fuel_cost)

			quantity = isapprox(quantity, 0.0, atol=1e-4) ? 0.0 : quantity
			load_utility = isapprox(load_utility, 0.0, atol=1e-4) ? 0.0 : load_utility
			payments = isapprox(payments, 0.0, atol=1e-4) ? 0.0 : payments
			revenue = isapprox(revenue, 0.0, atol=1e-4) ? 0.0 : revenue
			fuel_cost = isapprox(fuel_cost, 0.0, atol=1e-4) ? 0.0 : fuel_cost
			surplus = isapprox(surplus, 0.0, atol=1e-4) ? 0.0 : surplus
			

			push!(agent_indicators, [agent,quantity,load_utility,payments,revenue,fuel_cost,surplus])

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
	storage_quantity = 	combine(finalMarketResults, :StorageDischarge => sum)[1,1] + combine(finalMarketResults, :StorageCharge => sum)[1,1]
	

	storage_revenue = isapprox(storage_revenue, 0.0, atol=1e-4) ? 0.0 : storage_revenue
	storage_quantity = isapprox(storage_quantity, 0.0, atol=1e-4) ? 0.0 : storage_quantity
	
	# note that revenue here is also reported as SEW, assuming no costs
	push!(agent_indicators, ["Storage", storage_quantity, 0.0, 0.0, storage_revenue, 0.0, storage_revenue])
	
	consumer_surplus = combine((agent_indicators[ [a in agentMap[HelperModelResults.AGENT_DEMAND] for a in agent_indicators[!, :Agent]], :]), :Surplus => sum)[1,1] 
	producer_surplus = combine((agent_indicators[ [a in agentMap[HelperModelResults.AGENT_GENERATOR] for a in agent_indicators[!, :Agent]], :]), :Surplus => sum)[1,1] 
	sew = consumer_surplus + producer_surplus
	push!(indicators,[sew,producer_surplus,consumer_surplus,storage_revenue]) #,weighted_average_price])


	return (indicators, agent_indicators, transactions, finalMarketResults)
end

end;
module HelperModelResults

export AgentTypeEnum, AGENT_DEMAND, AGENT_GENERATOR, AGENT_STORAGE

using JuMP, DataFrames, MathOptInterface

@enum AgentTypeEnum AGENT_DEMAND AGENT_GENERATOR AGENT_STORAGE

# new helpers

# return a range with the start and end MTU of the model
function OptimizationWindow(m::Model)
	return m.ext[:sets][:OW]
end

function DecisionVariables(optimization_window::UnitRange{Int}, agent_map::Dict{AgentTypeEnum, Vector{String}}, m::Model)
	df = DataFrame(mtu=optimization_window, price=Prices(m), SOC=SOCValues_N(m, optimization_window), StorageCharge=StorageChargeQuantities(m, optimization_window), StorageDischarge=StorageDischargeQuantities(m, optimization_window)) 

	if termination_status(m) !== MathOptInterface.OPTIMAL
		
		println("non optimal solution: $(termination_status(m))")
		df = DataFrame(mtu=optimization_window, price=zeros(length(optimization_window)), SOC=zeros(length(optimization_window)), StorageCharge=zeros(length(optimization_window)), StorageDischarge=zeros(length(optimization_window)))

	end

	# add all other decision variables - the gens and demands

	# ramp_limit_up_duals = RampLimitUpDuals(m)
	# ramp_limit_down_duals = RampLimitDownDuals(m)
	

	explicitAgentMapOrder = AllAgents(m) # ["Base_D", "Flex", "Base", "Shoulder", "Peak", "Wind", "Solar"] # Note: this will ignore any new agents that are not in the list - TODO: fix this
	for agent in explicitAgentMapOrder
		if termination_status(m) !== MathOptInterface.OPTIMAL
			df[!,agent] = zeros(length(optimization_window))
		else
			a_type = in(agent, agent_map[AGENT_DEMAND]) ? AGENT_DEMAND : AGENT_GENERATOR
			agent_type_data = a_type == AGENT_DEMAND ? m.ext[:variables][:Qd] : a_type == AGENT_GENERATOR ? m.ext[:variables][:Qg] : throw("unknown agent type: $a_type")
			agent_adj_type_data = a_type == AGENT_DEMAND ? m.ext[:variables][:Qd_adj] : a_type == AGENT_GENERATOR ? m.ext[:variables][:Qg_adj] : throw("unknown agent type: $a_type")
			df[!,agent] = [value(agent_type_data[agent,t]) for t in optimization_window]
			if !m.ext[:data_storage][:ex_post_transactions]
				df[!,"$(agent)_adj"] = [value(agent_adj_type_data[agent,t]) for t in optimization_window]
			end
			#= if haskey(ramp_limit_up_duals, agent)
				df[!,"$(agent)_ramp_up_dual"] = ramp_limit_up_duals[agent]
				df[!,"$(agent)_ramp_down_dual"] = ramp_limit_down_duals[agent]
			end
			=#
		end
	end

	# add bid quantities and prices for validation - new loop so these appear later in the output - including these values also in cases of non-optimal optimization outcome

	for agent in explicitAgentMapOrder
		a_type = in(agent, agent_map[AGENT_DEMAND]) ? AGENT_DEMAND : AGENT_GENERATOR
		agent_type_price_data = a_type == AGENT_DEMAND ? m.ext[:timeseries][:Pr_dem] : a_type == AGENT_GENERATOR ? m.ext[:timeseries][:Pr_gen] : throw("unknown agent type: $a_type")
		agent_type_quantity_data = a_type == AGENT_DEMAND ? m.ext[:timeseries][:Q_dem] : a_type == AGENT_GENERATOR ? m.ext[:timeseries][:Q_gen] : throw("unknown agent type: $a_type")
		agent_type_prev_data = a_type == AGENT_DEMAND ? m.ext[:timeseries][:Q_prev_dem] : a_type == AGENT_GENERATOR ? m.ext[:timeseries][:Q_prev_gen] : throw("unknown agent type: $a_type")
		df[!,"Q_$agent"] =  [value(agent_type_quantity_data[agent,t]) for t in optimization_window]
		df[!,"Q_prev_$agent"] =  [value(agent_type_prev_data[agent,t]) for t in optimization_window]
		df[!,"P_$agent"] =  [value(agent_type_price_data[agent,t]) for t in optimization_window]
	end

	return df
end

function AgentMap(m::Model)
	am = Dict{AgentTypeEnum, Vector{String}}()
	am[AGENT_GENERATOR] = Generators(m)
	am[AGENT_DEMAND] = Demands(m)
	return am
end

function Generators(m::Model)
	return sort([g for g in m.ext[:sets][:IG]])
end

function VariableGenerators(m::Model)
	return sort([g for g in m.ext[:sets][:VG]])
end

function Demands(m::Model)
	return sort([d for d in m.ext[:sets][:ID]])
end

function AllAgents(m::Model)
	gens = Generators(m)
	dems = Demands(m)
	all_agents = [dems;gens]
	return all_agents
end


function StorageChargeQuantities(m, optimization_window)
	return [value.(m.ext[:variables][:Qch][t]) for t in optimization_window]
end

function StorageDischargeQuantities(m, optimization_window)
	return [value.(m.ext[:variables][:Qdis][t]) for t in optimization_window]
end

function SOCValues_N(m, optimization_window)
	return [value.(m.ext[:variables][:SOC][t]) for t in optimization_window]
end

function Prices(m::Model)
	# compute market-clearing prices for each time period as duals of the energy balance constraints
	return Lambdas(m)
end

function Lambdas(m::Model)
	OW = OptimizationWindow(m)
	λ  = dual.(m.ext[:constraints][:energy_balance])   # per MTU prices [EUR/MWh]
	# println("DUALS of ramp limits up $(RampLimitUpDuals(m))")
	# println("DUALS of ramp limits down $(RampLimitDownDuals(m))")
	return [λ[t] for t in OW]
end

function RampLimitUpDuals(m::Model)
	OW = OptimizationWindow(m)
	return zeros(length(OW))
	generators = Generators(m)
	rampDual  = dual.(m.ext[:constraints][:ramp_limits_up])   # per generator/MTU ramp up dual  [EUR/MWh]
	rampDualFirst  = dual.(m.ext[:constraints][:ramp_limits_up_first])   # per generator ramp up dual for first MTU [EUR/MWh]
	rampLimitUpDuals = Dict{String,Vector{Float64}}()
	for g in generators
		rampLimitUpDuals[g] = [(t == OW.start ? rampDualFirst[g,t] : rampDual[g,t]) for t in OW]
	end
	return rampLimitUpDuals
end

function RampLimitDownDuals(m::Model)
	OW = OptimizationWindow(m)
	return zeros(length(OW))
	generators = Generators(m)
	rampDual  = dual.(m.ext[:constraints][:ramp_limits_down])   # per generator/MTU ramp down dual  [EUR/MWh]
	rampDualFirst  = dual.(m.ext[:constraints][:ramp_limits_down_first])   # per generator ramp down dual for first MTU [EUR/MWh]
	rampLimitDownDuals = Dict{String,Vector{Float64}}()
	for g in generators
		rampLimitDownDuals[g] = [(t == OW.start ? rampDualFirst[g,t] : rampDual[g,t]) for t in OW]
	end
	return rampLimitDownDuals
end


# older helpers

#=
function BaseTimePeriod(m::Model)
	return TimePeriods(m)[1]
end

function TimePeriods(m::Model)
	# return the time periods cleared in this model
	return m.ext[:sets][:CH]
end


function BidPrices(m)
	time_periods = TimePeriods(m)
	IG = m.ext[:sets][:IG]
	ID = m.ext[:sets][:ID]
    bid_prices = Dict{String, Vector{Float64}}()
    for g in IG
        bid_prices[g] = [value(m.ext[:timeseries][:Pr_gen][g,t]) for t in time_periods]
    end
    for d in ID
        bid_prices[d] = [value(m.ext[:timeseries][:Pr_dem][d,t]) for t in time_periods]
    end
    return bid_prices
end

function StorageChargeQuantities(m)
	if m.ext[:parameters][:has_storage]
	    Qch_val = value.(m.ext[:variables][:Qch] * m.ext[:sets][:power_to_energy_scale])
	else
		return error("no storage")
	end
end

function StorageDischargeQuantities(m)
	if m.ext[:parameters][:has_storage]
	   	return Qdis_val = value.(m.ext[:variables][:Qdis] * m.ext[:sets][:power_to_energy_scale])
	else
		return error("no storage")
	end
end

function SOCValues(m)
	if m.ext[:parameters][:has_storage]
	   	return SOC_val = value.(m.ext[:variables][:SOC])
	else
		return error("no storage")
	end
end

function GenData(m)
	time_periods = TimePeriods(m)
	IG = m.ext[:sets][:IG]
    gen_data = Dict{String, Vector{Float64}}()
    for g in IG
        gen_data[g] = [value(m.ext[:variables][:Qg][g,t] * m.ext[:sets][:power_to_energy_scale]) for t in time_periods]
    end
    return gen_data
end


function DemandData(m)
	time_periods = TimePeriods(m)
	ID = m.ext[:sets][:ID]
    dem_data = Dict{String, Vector{Float64}}()
    for d in ID
        dem_data[d] = [value(m.ext[:variables][:Qd][d,t] * m.ext[:sets][:power_to_energy_scale]) for t in time_periods]
    end
    return dem_data
end

=#

mutable struct Transaction
	MarketName::String
	Agent::String
	Quantity::Float64
	Price::Float64
	MTU::Int
	ClearingMTU::Int
	TimesCleared::Int
	AgentType::AgentTypeEnum
	Transaction() = new()
end

function MakeTransaction(agent, quantity, price, mtu, clearing_mtu, times_cleared, agent_type, market_name) 
	t = Transaction()
	t.MarketName = market_name
	t.Agent = agent
	t.Quantity = quantity
	t.Price = price
	t.MTU = mtu
	t.ClearingMTU = clearing_mtu
	t.TimeCleared = times_cleared
	t.AgentType = agent_type
	return t
end

# compare clearing outcomes with previous clearings to generate a set of transactions


function mtu_times_cleared(resultset, mtu)
	times_cleared = 1
	for mr in resultset
		if mtu >= mr.OptimizationWindow.start && mtu <= mr.OptimizationWindow.stop
			times_cleared = times_cleared + 1
		end
	end
	return times_cleared
end

function Transactions(marketresult, previous_dispatch, market_name, resultset, m::Model)
	transaction_mtu = marketresult.TimeCleared

	transactions = []
	has_last_result = nrow(previous_dispatch) > 0 # special handling for first market
	# for each demand, in each mtu cleared
	for row in eachrow(marketresult.DecisionVariables)
		for d in marketresult.AgentMap[AGENT_DEMAND]
			times_cleared = has_last_result ? mtu_times_cleared(resultset, row["mtu"]) : 1
			if m.ext[:data_storage][:ex_post_transactions]
				last_qs_at_time = has_last_result ? previous_dispatch[previous_dispatch.mtu .== row["mtu"], d] : [] # if we don't have any old data
				adjust_from_q = length(last_qs_at_time) > 0 ? last_qs_at_time[1] : 0.0 # if we don't have data for this row
				adjustment_q = row[d] - adjust_from_q
			else
				adjustment_q = row["$(d)_adj"]
			end
			q_prev_key = "Q_prev_$d"
			if adjustment_q != row[d] - row[q_prev_key]
				println("adjustment mismatch: $(adjustment_q) $(row[d] - row[q_prev_key])")
			end


			if adjustment_q != 0.0
				transaction = Transaction()
				transaction.Agent = d
				transaction.Quantity = adjustment_q
				transaction.Price = row["price"]
				transaction.MTU = row["mtu"]
				transaction.ClearingMTU = transaction_mtu
				transaction.TimesCleared = times_cleared
				transaction.AgentType = AGENT_DEMAND
				transaction.MarketName = market_name
				push!(transactions, transaction)
			end
		end

		for g in marketresult.AgentMap[AGENT_GENERATOR]
			times_cleared = has_last_result ? mtu_times_cleared(resultset, row["mtu"]) : 1
			if m.ext[:data_storage][:ex_post_transactions]
				last_qs_at_time = has_last_result ? previous_dispatch[previous_dispatch.mtu .== row["mtu"], g] : [] # if we don't have any old data
				adjust_from_q = length(last_qs_at_time) > 0 ? last_qs_at_time[1] : 0.0 # if we don't have data for this row
				adjustment_q = row[g] - adjust_from_q
			else
				adjustment_q = row["$(g)_adj"]
			end

			q_prev_key = "Q_prev_$g"
			if adjustment_q != row[g] - row[q_prev_key]
				println("adjustment mismatch: $(adjustment_q) $(row[g] - row[q_prev_key])")
			end


			if adjustment_q != 0.0
				transaction = Transaction()
				transaction.Agent = g
				transaction.Quantity = adjustment_q
				transaction.Price = row["price"]
				transaction.MTU = row["mtu"]
				transaction.ClearingMTU = transaction_mtu
				transaction.TimesCleared = times_cleared
				transaction.AgentType = AGENT_GENERATOR
				transaction.MarketName = market_name
				push!(transactions, transaction)
			end
		end

		# Note assumption that we only have one storage agent here (and throughout)
		last_qs_at_time_storage_charge = has_last_result ? previous_dispatch[previous_dispatch.mtu .== row["mtu"], "StorageCharge"] : [] # if we don't have any old data
		adjust_from_q_storage_charge = length(last_qs_at_time_storage_charge) > 0 ? last_qs_at_time_storage_charge[1] : 0.0 # if we don't have data for this row
		
		last_qs_at_time_storage_discharge = has_last_result ? previous_dispatch[previous_dispatch.mtu .== row["mtu"], "StorageDischarge"] : [] # if we don't have any old data
		adjust_from_q_storage_discharge = length(last_qs_at_time_storage_discharge) > 0 ? last_qs_at_time_storage_discharge[1] : 0.0 # if we don't have data for this row

		# Discharge - Charge because positive means we're contributing energy to the system - acting more like a generator
		adjustment_q = (row["StorageDischarge"] - row["StorageCharge"]) - (adjust_from_q_storage_discharge - adjust_from_q_storage_charge)
		
		if adjustment_q != 0.0
			times_cleared = has_last_result ? mtu_times_cleared(resultset, row["mtu"]) : 1
			transaction = Transaction()
			transaction.Agent = "Storage"
			transaction.Quantity = adjustment_q
			transaction.Price = row["price"]
			transaction.MTU = row["mtu"]
			transaction.ClearingMTU = transaction_mtu
			transaction.TimesCleared = times_cleared
			transaction.AgentType = AGENT_STORAGE
			transaction.MarketName = market_name
			push!(transactions, transaction)
		end
	end

	transactions_df = DataFrame(MarketName=String[], Agent=String[], Quantity=Float64[], Price=Float64[], MTU=Int[], ClearingMTU=Int[], TimesCleared=Int[], AgentType=String[])
	for t in transactions
		push!(transactions_df, [t.MarketName, t.Agent, t.Quantity, t.Price, t.MTU, t.ClearingMTU, t.TimesCleared, string(Symbol(t.AgentType))])
	end

	long_names = ["Market Name", "Agent", "Quantity (MWh)", "Price (€/MWh)", "Market Time Unit", "Clearing MTU", "Times Cleared", "Agent Type"]
	short_names = ["MarketName", "Agent", "Quantity", "Price", "MTU", "ClearingMTU", "TimesCleared", "AgentType"]
	rename!(transactions_df, short_names .=> long_names)

	return transactions_df
end

end;
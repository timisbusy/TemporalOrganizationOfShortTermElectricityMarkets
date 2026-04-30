module PlotMarketEquilibriumForWindow

using Plots
using JuMP
using Statistics
using DataFrames

using ..Helpers.HelperModelResults
using ..Helpers.MarketDataStorage


function plot(marketresults, time_range::UnitRange{Int})
	if length(marketresults) < 1
		println("no results in market results")
		return
	end

	agentMap = marketresults[1].AgentMap
	dispatch_decisions = MarketDataStorage.GetMarketResultsForRange(marketresults,time_range) # working on this now

	# println(dispatch_decisions)

	for mtu in time_range
		# plot the latest demand/supply curves and the P/Q dispatched - what about storage too?
		if nrow(dispatch_decisions[dispatch_decisions.mtu .== mtu, :]) < 1
			println("there is no data for mtu: $mtu")
			continue # no data for this mtu
		end


		dispatched_quantity = 0.0
		dispatched_price = dispatch_decisions[dispatch_decisions.mtu .== mtu, "price"][1]

		supply_prices = Float64[]
		supply_quantities = Float64[]
		for gen in agentMap[HelperModelResults.AGENT_GENERATOR]
			push!(supply_prices,dispatch_decisions[dispatch_decisions.mtu .== mtu,"P_$(gen)"][1])
			push!(supply_quantities,dispatch_decisions[dispatch_decisions.mtu .== mtu, "Q_$(gen)"][1])
			dispatched_quantity += dispatch_decisions[dispatch_decisions.mtu .== mtu, "$(gen)"][1]
		end


		demand_prices = Float64[]
		demand_quantities = Float64[]

		for dem in agentMap[HelperModelResults.AGENT_DEMAND]
			push!(demand_prices,dispatch_decisions[dispatch_decisions.mtu .== mtu,"P_$(dem)"][1])
			push!(demand_quantities,dispatch_decisions[dispatch_decisions.mtu .== mtu,"Q_$(dem)"][1])
		end


		# println("supply prices: ", supply_prices)
		# println("supply quantities: ", supply_quantities)
		# println("demand prices: ", demand_prices)
		# println("demand quantities: ", demand_quantities)
		println("price: ", dispatched_price)

		# Sort supply by price (ascending - merit order)
	    supply_order = sortperm(supply_prices)
	    supply_prices = supply_prices[supply_order]
	    supply_quantities = supply_quantities[supply_order]
	    
	    # Sort demand by price (descending)
	    demand_order = sortperm(demand_prices, rev=true)
	    demand_prices = demand_prices[demand_order]
	    demand_quantities = demand_quantities[demand_order]
	    
	    # Create step functions for supply curve
	    supply_x = Float64[]
	    supply_y = Float64[]
	    cumsum_q = 0.0
	    for i in 1:length(supply_prices)
	        # Horizontal line at current price level
	        push!(supply_x, cumsum_q)
	        push!(supply_y, supply_prices[i])
	        cumsum_q += supply_quantities[i]
	        push!(supply_x, cumsum_q)
	        push!(supply_y, supply_prices[i])
	    end
	    
	    # Create step functions for demand curve
	    demand_x = Float64[]
	    demand_y = Float64[]
	    cumsum_q = 0.0
	    for i in 1:length(demand_prices)
	        # Horizontal line at current price level
	        push!(demand_x, cumsum_q)
	        push!(demand_y, demand_prices[i])
	        cumsum_q += demand_quantities[i]
	        push!(demand_x, cumsum_q)
	        push!(demand_y, demand_prices[i])
	    end

	    storage_x = [dispatched_quantity, (dispatched_quantity  + dispatch_decisions[dispatch_decisions.mtu .== mtu,"StorageDischarge"][1] - dispatch_decisions[dispatch_decisions.mtu .== mtu,"StorageCharge"][1])]
	    
	    # Plot
	    p = Plots.plot(xlabel="Quantity (MWh)", ylabel="Price (EUR/MWh)", 
	             title="Market Equilibrium - Market Time Unit $mtu", legend=:best, 
	             xlims = (0, maximum([supply_x; demand_x])), 
	             ylims = (0, maximum([supply_y; demand_y]) * 1.05))
	    
	    Plots.plot!(p, supply_x, supply_y, label="Supply", color=:blue, linewidth=2)
	    Plots.plot!(p, demand_x, demand_y, label="Demand", color=:red, linewidth=2)
	    Plots.plot!(p, storage_x, [dispatched_price,dispatched_price], label="Storage", color=:orange, linewidth=2)
	    Plots.scatter!(p, [dispatched_quantity], [dispatched_price], label="dispatch")
	    
	    display(p)
	end
end

end;
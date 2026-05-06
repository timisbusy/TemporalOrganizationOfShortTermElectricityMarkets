module PlotGenerationStack

using Plots
using JuMP
using Statistics

using ..Helpers

include("../../output_data/market_data_storage.jl")

function plot(marketresult, config, test_range, test_id)

    market_results = MarketDataStorage.GetMarketResultsForRange(marketresult,test_range)

    # Define consistent colors
    gen_colors = [:steelblue, :lightgreen, :red, :lightyellow, :coral, :orange]

    # Manual stacking order
    stack_order = ["Base", "Shoulder", "Peak", "Wind", "Solar"]

    # Build matrix for areaplot (each row is a generator, each column is an mtu)
    stack_matrix = zeros(length(stack_order), length(test_range))
    for (i, g) in enumerate(stack_order)
        stack_matrix[i, :] = market_results[:, g]
    end

    # Add storage discharge as another row
    discharge_vec = market_results[:, "StorageDischarge"]
    if maximum(discharge_vec) > 0.1
        stack_matrix = vcat(stack_matrix, discharge_vec')
        labels = [stack_order; "Storage Discharge"]
    else
        labels = stack_order
    end

    # Calculate max y for limits
    total_demand = [sum(market_results[market_results.mtu .== t, d] for d in marketresult[1].AgentMap[HelperModelResults.AGENT_DEMAND])[1,1] for t in test_range]
    charging_vec = market_results[:, "StorageCharge"]
    max_y = maximum(total_demand .+ charging_vec) * 1.6

    # Create stacked area plot
    p3 = Plots.plot(xlabel="MTU", ylabel="Dispatched Production (MWh)",
            title="Generation & Demand Stack",
            legend=:topright,
            ylims=(0, max_y),size=(1200,1200))

    # Stack manually using areaplot with seriestype
    for i in 1:size(stack_matrix, 1)
        if i == 1
            Plots.plot!(p3, test_range, stack_matrix[i, :],
                fillrange=0, label=labels[i], 
                color=gen_colors[i], alpha=0.8, linewidth=0)
        else
            cumsum_prev = vec(sum(stack_matrix[1:i-1, :], dims=1))
            cumsum_curr = vec(sum(stack_matrix[1:i, :], dims=1))
            Plots.plot!(p3, test_range, cumsum_curr,
                fillrange=cumsum_prev, label=labels[i],
                color=gen_colors[i], alpha=0.8, linewidth=0)
        end
    end

    # Add demand line on top
    Plots.plot!(p3, test_range, total_demand .+ charging_vec,
        label="Demand + Charging", color=:black, lw=3, ls=:dash)
    
    display(p3)
    savefig(p3, "../DATA/$(test_id)/generation_stack_$(test_id).png")
    return p3 
end

function plotCompare(market_results, config, test_range, test_id)
    
    # Define consistent colors
    gen_colors = [:purple4, :royalblue1, :seagreen1, :green2, :orangered, :deeppink]

    # Manual stacking order
    stack_order = ["Base", "Shoulder", "Peak", "Wind", "Solar"]

    marker_shapes = [:circle,:star5]

    stackMatrices = Dict{String, Any}()
    finalDispatchResults = Dict{String, Any}()
    maxY = 0.0
    labels = stack_order
    for (marketName, marketResult) in market_results
        finalDispatchResults[marketName] = MarketDataStorage.GetMarketResultsForRange(marketResult,test_range)

        # Build matrix for areaplot (each row is a generator, each column is an mtu)
        stack_matrix = zeros(length(stack_order), length(test_range))
        for (i, g) in enumerate(stack_order)
            stack_matrix[i, :] = finalDispatchResults[marketName][:, g]
        end

        # Add storage discharge as another row
        discharge_vec = finalDispatchResults[marketName][:, "StorageDischarge"]
        if maximum(discharge_vec) > 0.1
            stack_matrix = vcat(stack_matrix, discharge_vec')
            labels = [stack_order; "Storage Discharge"]
        end

        # Calculate max y for limits
        total_demand = [sum(finalDispatchResults[marketName][finalDispatchResults[marketName].mtu .== t, d] for d in marketResult[1].AgentMap[HelperModelResults.AGENT_DEMAND])[1,1] for t in test_range]
        charging_vec = finalDispatchResults[marketName][:, "StorageCharge"]
        max_y = maximum(total_demand .+ charging_vec) * 1.6
        maxY = maximum([max_y, maxY])
        stackMatrices[marketName] = stack_matrix
    end

    

    # Create stacked area plot
    p3 = Plots.plot(xlabel="MTU", ylabel="Dispatched Production (MWh)",
            title="Generation & Demand Stack",
            legend=:topright,
            ylims=(0, maxY),size=(1200,1200))

    markerIter = 1
    for (marketName, stack_matrix) in stackMatrices
        marker = marker_shapes[markerIter]
        markerIter += 1
        # Stack manually using areaplot with seriestype
        for i in 1:size(stack_matrix, 1)
            if i == 1
                Plots.plot!(p3, test_range, stack_matrix[i, :],
                     label="$(marketName): $(labels[i])" , 
                    fillrange=0, color=gen_colors[i], markershape=marker, alpha=0.6, linewidth=1)
            else
                cumsum_prev = vec(sum(stack_matrix[1:i-1, :], dims=1))
                cumsum_curr = vec(sum(stack_matrix[1:i, :], dims=1))
                Plots.plot!(p3, test_range, cumsum_curr,
                     label="$(marketName): $(labels[i])",
                    fillrange=cumsum_prev, color=gen_colors[i], markershape=marker, alpha=0.6, linewidth=1)
            end
        end

        #=
        # Add demand line on top
        Plots.plot!(p3, test_range, total_demand .+ charging_vec,
            label="Demand + Charging", color=:black, lw=3, ls=:dash)
        =#

    end



    plot_arr = Dict{Int,Any}()
    markerIter = 1
    for (marketName, stack_matrix) in stackMatrices
        marker = marker_shapes[markerIter]
        markerIter += 1

        plot_arr[markerIter] = Plots.plot(xlabel="MTU", ylabel="Dispatched Production (MWh)",
            title="Generation & Demand Stack for $marketName",
            legend=:topright,
            ylims=(0, maxY),size=(1200,1200))
        # Stack manually using areaplot with seriestype
        for i in 1:size(stack_matrix, 1)
            if i == 1
                Plots.plot!(plot_arr[markerIter], test_range, stack_matrix[i, :],
                     label="$(marketName): $(labels[i])" , 
                    fillrange=0, color=gen_colors[i], markershape=marker, alpha=0.6, linewidth=1)
            else
                cumsum_prev = vec(sum(stack_matrix[1:i-1, :], dims=1))
                cumsum_curr = vec(sum(stack_matrix[1:i, :], dims=1))
                Plots.plot!(plot_arr[markerIter], test_range, cumsum_curr,
                     label="$(marketName): $(labels[i])",
                    fillrange=cumsum_prev, color=gen_colors[i], markershape=marker, alpha=0.6, linewidth=1)
            end
        end

        #=
        # Add demand line on top
        Plots.plot!(p3, test_range, total_demand .+ charging_vec,
            label="Demand + Charging", color=:black, lw=3, ls=:dash)
        =#

        display(plot_arr[markerIter])

    end




 #=
    p4 = Plots.plot(xlabel="MTU", ylabel="Dispatched Production (MWh)",
            title="Generation & Demand Stacked Bars",
            legend=:topright,
            ylims=(0, maxY),size=(1200,1200))
    for (marketName, stack_matrix) in stackMatrices
        println(stack_matrix)
        Plots.plot!(p4, stack_matrix, t=:bar, bar_position=:stack, bar_width=0.7, label="$(marketName)")
    end
    display(p4)
=#
    # display(p3)
    savefig(p3, "../DATA/$(test_id)/generation_stack_$(test_id).png")
    return p3 
end


end;
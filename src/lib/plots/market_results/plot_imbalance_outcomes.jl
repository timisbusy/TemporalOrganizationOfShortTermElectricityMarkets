module PlotImbalanceOutcomes

using Plots
using JuMP
using Statistics
using DataFrames
using XLSX


using ..Helpers

include("../../output_data/market_data_storage.jl")


# Note: perhaps it would be best to make a helper function for getting the final dispatch, and realized energy production from ST market sequence?
function plotCompare(market_results, config, test_range, test_id, variableGeneratorProfiles, appendToName)
    # add curtailment to output
    spilled_df = DataFrame(MarketConfiguration=[], AgentName=[], Spilled=[], PositiveImbalance=[], NegativeImbalance=[], AbsoluteImbalance=[])
    dispatch_with_spilled = Dict{String,Any}()
    for (marketConfiguration, resultset) in market_results
        
        println("with curtailment for $marketConfiguration")
        dispatch = MarketDataStorage.GetFinalDispatchDecisionsForRange(resultset,test_range)
        # add curtailment calculated column and realized production
        for (gName, gProfile) in variableGeneratorProfiles
            dispatchKey = Symbol(gName)
            lastBidQuantityKey = Symbol("Q_$gName")
            spilledKey = Symbol("Spilled $gName")
            availableKey = Symbol("Available $gName")
            imbalanceKey = Symbol("Imbalance $gName")
            positiveImbalanceKey = Symbol("Positive Imbalance $gName")
            negativeImbalanceKey = Symbol("Negative Imbalance $gName")
            absoluteImbalanceKey = Symbol("Absolute Imbalance $gName")
            dispatch[!, spilledKey] = dispatch[!, lastBidQuantityKey] .- dispatch[!, dispatchKey]
            spilledForAgent = combine(dispatch, spilledKey => sum)[1,1]
            println("$gName spilled: $spilledForAgent")
            dispatch[!, availableKey] = zeros(nrow(dispatch)) 
            for mtu in test_range
                dispatch[dispatch.mtu .== mtu, availableKey] .= gProfile[gProfile.mtu .== mtu, Symbol("Value")][1,1] * config[:variableGenerators][gName]["capacity"] # the current version sets the original profile as the realized value - errors converge on the input profile
            end
            dispatch[!, imbalanceKey] .= dispatch[!, availableKey] .- (dispatch[!, spilledKey] .+ dispatch[!, dispatchKey])
            dispatch[!, positiveImbalanceKey] = clamp.(dispatch[!, availableKey] .- (dispatch[!, spilledKey] .+ dispatch[!, dispatchKey]), 0.0, 600000.0)
            dispatch[!, negativeImbalanceKey] = clamp.(dispatch[!, availableKey] .- (dispatch[!, spilledKey] .+ dispatch[!, dispatchKey]), -600000.0, 0.0)
            dispatch[!, absoluteImbalanceKey] = abs.(dispatch[!, availableKey] .- (dispatch[!, spilledKey] .+ dispatch[!, dispatchKey]))
            positiveImbalanceForAgent = combine(dispatch, positiveImbalanceKey => sum)[1,1]
            negativeImbalanceForAgent = combine(dispatch, negativeImbalanceKey => sum)[1,1]
            absoluteImbalanceForAgent = combine(dispatch, absoluteImbalanceKey => sum)[1,1]
            push!(spilled_df,[marketConfiguration,gName,spilledForAgent,positiveImbalanceForAgent,negativeImbalanceForAgent,absoluteImbalanceForAgent])
            
        end

        # println(dispatch)
        XLSX.writetable("results/$(test_id)/dispatch_with_spilled_$(marketConfiguration)_$appendToName.xlsx", "data" => dispatch) # TODO: interpretation here
        dispatch_with_spilled[marketConfiguration] = dispatch
    end

    XLSX.writetable("results/$(test_id)/spilled_$appendToName.xlsx", "data" => spilled_df) # TODO: interpretation here


    p4 = Plots.plot(xlabel="MTU", ylabel="VRES Imbalance (MWh)",
      title="Imbalance Quantities",
      linewidth=2,size=(800,800), legend=:topright, margin=2Plots.mm)

    # Plot totalimbalance indicators
    for (marketConfiguration, dispatch) in dispatch_with_spilled
        Plots.plot!(p4, test_range, dispatch[test_range.start .<= dispatch.mtu .<= test_range.stop, "Imbalance 6G_Wind"],
            label="Imbalance for wind in $marketConfiguration", alpha=0.8)
    end

    display(p4)
    savefig(p4, "results/$(test_id)/imbalance_$appendToName.png")

    p5 = Plots.plot(xlabel="MTU", ylabel="Absolute VRES Imbalance (MWh)",
      title="Absolute Imbalance Quantities",
      linewidth=2,size=(800,800), legend=:topright, margin=2Plots.mm)

   for (marketConfiguration, dispatch) in dispatch_with_spilled
        Plots.plot!(p5, test_range, dispatch[test_range.start .<= dispatch.mtu .<= test_range.stop, "Absolute Imbalance 6G_Wind"],
            label="Imbalance for wind in $marketConfiguration", alpha=0.8)
    end

    display(p5)
    savefig(p5, "results/$(test_id)/absimbalance_$appendToName.png")



    #=


    # compare the variable generator last dispatched quantity vs the variable generator last forecast value (after the last forecast, the energy production is assumed to be realized)
    realized_q = Dict{String,Vector{Float64}}()
    dispatched_q = Dict{String,Dict{String,Vector{Float64}}}()
    imbalance_q = Dict{String,Dict{String,Vector{Float64}}}()
    realized_q_total = Vector{Float64}()
    dispatched_q_total = Dict{String,Vector{Float64}}()
    imbalance_q_total = Dict{String,Vector{Float64}}()
    
    # println(variableGeneratorProfiles)

    for (gName, gData) in variableGeneratorProfiles
        realized_q[gName] = gData .* config[:variableGenerators][gName]["capacity"] # the current version sets the original profile as the realized value - errors converge on the input profile
        realized_q[gName] = realized_q[gName][2:end]
    end
    

    realized_length = length(realized_q[first(keys(realized_q))])

    for (marketConfiguration, resultset) in market_results
        gen_dispatch_data = MarketDataStorage.GenQuantities(resultset,1:realized_length)

        dispatched_length = length(gen_dispatch_data[first(keys(gen_dispatch_data))])

        dispatched_q[marketConfiguration] = Dict{String,Vector{Float64}}()
        imbalance_q[marketConfiguration] = Dict{String,Vector{Float64}}()
        dispatched_q_total[marketConfiguration] = zeros(dispatched_length)
        imbalance_q_total[marketConfiguration] = zeros(dispatched_length)
        
        for (gName, gData) in realized_q # ensure we have matching dispatchable generators

            dispatched_q[marketConfiguration][gName] = gen_dispatch_data[gName]
            dispatched_q_total[marketConfiguration] .+= gen_dispatch_data[gName]
            imbalance_q[marketConfiguration][gName] = realized_q[gName] - gen_dispatch_data[gName]
            imbalance_q_total[marketConfiguration] .+= imbalance_q[marketConfiguration][gName]

            dispatched_q[marketConfiguration][gName] = dispatched_q[marketConfiguration][gName][test_range]    # slice to match incoming time range
            imbalance_q[marketConfiguration][gName] = imbalance_q[marketConfiguration][gName][test_range]    # slice to match incoming time range
        end
        dispatched_q_total[marketConfiguration] = dispatched_q_total[marketConfiguration][test_range]    # slice to match incoming time range
        imbalance_q_total[marketConfiguration] = imbalance_q_total[marketConfiguration][test_range]    # slice to match incoming time range
    end


    realized_q_total = zeros(realized_length)
    for (gName, gData) in realized_q
        realized_q_total .+= realized_q[gName]
        realized_q[gName] = realized_q[gName][test_range]    # slice to match incoming time range
    end
    realized_q_total = realized_q_total[test_range]



    p3 = Plots.plot(xlabel="MTU", ylabel="VRES Imbalance (MWh)",
      title="VRES Production - Dispatched vs Realized",
      linewidth=2,size=(1200,1200), legend=:topright)

    for (name, dispatched_quantities) in dispatched_q_total
        Plots.plot!(p3, test_range, dispatched_q_total[name],
            label="Dispatched production total in $name", alpha=0.8)
    end
    Plots.plot!(p3, test_range, realized_q_total,
        label="Realized production total", alpha=0.8)

    p4 = Plots.plot(xlabel="MTU", ylabel="VRES Imbalance (MWh)",
      title="Imbalance Quantities",
      linewidth=2,size=(1200,1200), legend=:topright)

    # Plot totalimbalance indicators
    for (name, imbalance_q_t) in imbalance_q_total
        Plots.plot!(p4, test_range, imbalance_q_t,
            label="Imbalance total in $name", alpha=0.8)
    end

    display(p3)
    display(p4)
    savefig(p3, "results/$(test_id)/realized_v_dispatched.png")
    savefig(p4, "results/$(test_id)/imbalance.png")

    imbalance_df = DataFrame(MarketConfiguration=String[],PositiveImbalance=Float64[],NegativeImbalance=Float64[], AbsoluteImbalance=Float64[], Curtailment=Float64[])
    for (name, imbalance_q_t) in imbalance_q_total

        curtailment_for_market = curtailment_df[curtailment_df.MarketConfiguration .== name, :]
        curtailment_total = combine(curtailment_for_market, :Curtailment => sum)[1,1]
        push!(imbalance_df, [name, sum(clamp.(imbalance_q_t, 0.0, 60000.0)), sum(clamp.(imbalance_q_t, -60000.0, 0.0)), sum(abs.(imbalance_q_t)), curtailment_total])
    end


    imbalance_long_names = ["Market Configuration", "Positive Imbalance (MWh)", "Negative Imbalance (MWh)", "Absolute Imbalance (MWh)", "Curtailment (MWh)"]
    imbalance_short_names = ["MarketConfiguration", "PositiveImbalance", "NegativeImbalance", "AbsoluteImbalance", "Curtailment"]
    rename!(imbalance_df, imbalance_short_names .=> imbalance_long_names)

    println(imbalance_df)


    XLSX.writetable("results/$(test_id)/imbalance.xlsx", "data" => imbalance_df) # TODO: interpretation here


    =#
end


end;
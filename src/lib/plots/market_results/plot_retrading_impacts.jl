module PlotRetradingImpacts

using Plots
using JuMP
using Statistics
using DataFrames
using XLSX

using ..Helpers

include("../../output_data/market_data_storage.jl")
include("../../output_data/interpretations.jl")
include("../../output_data/table_header_renaming.jl")

function plot(marketresult, config, test_range, test_id)
    println("no single plot for retrading yet")
    return
    transactions = MarketDataStorage.GetTransactionsForRange(marketresult,test_range)
    println(transactions)
end

function BidOfferPriceForAgent(config, agent_name, agent_type)
    if agent_type == Helpers.HelperModelResults.AGENT_DEMAND
        return config[:demandSegments][agent_name]["bidPrice"]
    elseif agent_type == Helpers.HelperModelResults.AGENT_GENERATOR
        return haskey(config[:variableGenerators], agent_name) ? config[:variableGenerators][agent_name]["bidPrice"] : config[:dispatchableGenerators][agent_name]["bidPrice"]
    else
        throw("unrecognized agent type")
    end
end

function plotCompare(market_results, config, test_range, test_id)
    quantity_symbol = Symbol("Quantity (MWh)")
    price_symbol = Symbol("Price (€/MWh)")
    payrev_symbol = Symbol("Payments/Revenues (€)")
    
    for (marketConfiguration, marketresult) in market_results
        transactions = MarketDataStorage.GetTransactionsForRange(marketresult,test_range)
        retradeTransactions = transactions[transactions[!,Symbol("Times Cleared")] .> 1, :]
        println("retradeTransactions in test range for $marketConfiguration")
        # println(retradeTransactions)

        retradeTransactions[!, payrev_symbol] = retradeTransactions[!, quantity_symbol] .* retradeTransactions[!, price_symbol]
        retradingGainsOrLosses_df = DataFrame(Agent=[], Revenue=[], BidPrice=[], Quantity=[], UtilityChange=[], FuelCostChange=[], SurplusChange=[])

        agentMap = marketresult.Results[1].AgentMap
        for (agent_type, agent_names) in agentMap
            negate = agent_type == Helpers.HelperModelResults.AGENT_DEMAND ? -1 : 1
            for agent_name in agent_names
                agentBidPrice = BidOfferPriceForAgent(config, agent_name, agent_type)
                revenue = negate*combine(retradeTransactions[retradeTransactions.Agent .== agent_name, :], payrev_symbol => sum)[1,1]
                retradeQuantity = combine(retradeTransactions[retradeTransactions.Agent .== agent_name, :], quantity_symbol => sum)[1,1]
                retradeFuelCostChange = agent_type == Helpers.HelperModelResults.AGENT_DEMAND ? 0.0 : -1 * retradeQuantity * agentBidPrice
                retradeUtilityChange = agent_type == Helpers.HelperModelResults.AGENT_GENERATOR ? 0.0 : retradeQuantity * agentBidPrice
                retradeSurplusChange = revenue + retradeUtilityChange + retradeFuelCostChange
                push!(retradingGainsOrLosses_df,[agent_name, revenue, agentBidPrice, retradeQuantity, retradeUtilityChange, retradeFuelCostChange, retradeSurplusChange])
            end
        end

        # same for storage
        storageRevenue = combine(retradeTransactions[retradeTransactions.Agent .== "Storage", :], payrev_symbol => sum)[1,1]
        storageRetradeQuantity = combine(retradeTransactions[retradeTransactions.Agent .== "Storage", :], quantity_symbol => sum)[1,1]
                
        push!(retradingGainsOrLosses_df,["Storage", storageRevenue, 0.0, storageRetradeQuantity, 0.0, 0.0, storageRevenue]) # note missing value of residual storage here
        
        TableHeaderRenaming.RenameDataFrameHeaders!(retradingGainsOrLosses_df, "retrading")
        println(retradingGainsOrLosses_df)

        XLSX.writetable("results/$(test_id)/retrading_$marketConfiguration.xlsx", "data" => retradingGainsOrLosses_df, "interpretation" => Interpretations.RetradingInterpretation) # TODO: interpretation here

    end

end


end;
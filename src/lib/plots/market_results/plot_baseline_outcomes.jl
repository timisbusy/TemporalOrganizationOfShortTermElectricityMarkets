module PlotBaselineOutcomes

using Plots
using JuMP
using Statistics
using DataFrames
using XLSX

using ..Helpers

include("../../output_data/market_data_storage.jl")
include("../../output_data/interpretations.jl")

function plot(marketresult, config, test_range, test_id)
    (indicators, agent_indicators, transactions, final_market_results) = MarketDataStorage.GetEconomicIndicatorsForRange(marketresult, test_range)

    println(indicators)
    println(agent_indicators)

    XLSX.writetable("results/$(test_id)/economic_indicators.xlsx", "data" => indicators, "interpretation" => Interpretations.EconomicIndicatorsInterpretation)

    XLSX.writetable("results/$(test_id)/agent_indicators.xlsx", "data" => agent_indicators, "interpretation" => Interpretations.AgentIndicatorsInterpretation)

    XLSX.writetable("results/$(test_id)/transactions.xlsx", "data" => transactions, "interpretation" => Interpretations.TransactionsInterpretation)

    XLSX.writetable("results/$(test_id)/final_market_results.xlsx", "data" => final_market_results, "interpretation" => Interpretations.DecisionVariablesInterpretation)

end


function getMarketResultClearedInMTU(marketResult, clearing_mtu)
    for r in marketResult
        if r.TimeCleared == clearing_mtu # TODO: rename to clearing MTU for consistency
            return r
        end
    end
end

function plotCompare(market_results, config, test_range, test_id)
    combined_indicators = DataFrame()
    combined_agent_indicators = DataFrame()
    for (marketName, marketResult) in market_results
        println("calculating indicators for: $marketName")
        (indicators, agent_indicators, transactions, final_market_results, mtu_economic_outcomes) = MarketDataStorage.GetEconomicIndicatorsForRange(marketResult, test_range)
        indicators[!,Symbol("Market Name")] .= marketName
        combined_indicators = vcat(combined_indicators, indicators)
        agent_indicators[!,Symbol("Market Name")] .= marketName
        combined_agent_indicators = vcat(combined_agent_indicators, agent_indicators)


        XLSX.writetable("results/$(test_id)/transactions_$(marketName).xlsx", "data" => transactions, "interpretation" => Interpretations.TransactionsInterpretation)

        XLSX.writetable("results/$(test_id)/final_market_results_$(marketName).xlsx", "data" => final_market_results, "interpretation" => Interpretations.DecisionVariablesInterpretation)
        
        XLSX.writetable("results/$(test_id)/mtu_economic_results_$(marketName).xlsx", "data" => mtu_economic_outcomes) #, "interpretation" => Interpretations.DecisionVariablesInterpretation)

        println("MTU level results for $marketName")
        println(mtu_economic_outcomes)

        println(agent_indicators[!, "Agent"])

        for agent in agent_indicators[!, "Agent"] 
            for clearing_mtu in unique(transactions, "Clearing MTU")[!,"Clearing MTU"]
                if in(clearing_mtu, range(35,40))
                    # println("Agent: $agent in $clearing_mtu")

                    clearingMarketResult = getMarketResultClearedInMTU(marketResult, clearing_mtu)

                    # println(transactions[transactions.Agent .== agent .&& transactions[!, Symbol("Clearing MTU")] .== clearing_mtu, :])
                    window_length = length(clearingMarketResult.OptimizationWindow)
                    y_values = zeros(window_length)

                    if size(transactions[transactions.Agent .== agent .&& transactions[!, Symbol("Clearing MTU")] .== clearing_mtu, :], 1) < 1
                        continue
                    end

                    for t in eachrow(transactions[transactions.Agent .== agent .&& transactions[!, Symbol("Clearing MTU")] .== clearing_mtu, :])
                        surplus = haskey(config[:demandSegments],agent) ? (t["Quantity (MWh)"] * config[:demandSegments][agent]["bidPrice"])  - t["Payments/Revenues (€)"] : haskey(config[:dispatchableGenerators],agent) ? t["Payments/Revenues (€)"] - config[:dispatchableGenerators][agent]["bidPrice"]*t["Quantity (MWh)"] : 0.0
                        y_offset = t["Market Time Unit"] - clearingMarketResult.OptimizationWindow.start + 1
                        # println("Surplus in: $(y_offset) is $surplus")
                        y_values[y_offset] = surplus # t["Payments/Revenues (€)"]
                    end

                    p4 = Plots.plot(xlabel="MTU", ylabel="Surplus/Deficit (€) ",
                            title="Surplus/Deficit in $(clearing_mtu) for $(agent)",
                            legend=:none)

                    Plots.plot!(p4, clearingMarketResult.OptimizationWindow, y_values, t=:bar)
                    display(p4)

                end

            end
        end


    end
    println(combined_indicators)
    println(combined_agent_indicators)

    XLSX.writetable("results/$(test_id)/economic_indicators.xlsx", "data" => combined_indicators, "interpretation" => Interpretations.EconomicIndicatorsInterpretation)

    XLSX.writetable("results/$(test_id)/agent_indicators.xlsx", "data" => combined_agent_indicators, "interpretation" => Interpretations.AgentIndicatorsInterpretation)

end


end;
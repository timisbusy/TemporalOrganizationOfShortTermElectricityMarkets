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

    XLSX.writetable("../DATA/$(test_id)/economic_indicators.xlsx", "data" => indicators, "interpretation" => Interpretations.EconomicIndicatorsInterpretation)

    XLSX.writetable("../DATA/$(test_id)/agent_indicators.xlsx", "data" => agent_indicators, "interpretation" => Interpretations.AgentIndicatorsInterpretation)

    XLSX.writetable("../DATA/$(test_id)/transactions.xlsx", "data" => transactions, "interpretation" => Interpretations.TransactionsInterpretation)

    XLSX.writetable("../DATA/$(test_id)/final_market_results.xlsx", "data" => final_market_results, "interpretation" => Interpretations.DecisionVariablesInterpretation)

end


function plotCompare(market_results, config, test_range, test_id)
    combined_indicators = DataFrame()
    combined_agent_indicators = DataFrame()
    for (marketName, marketResult) in market_results
        (indicators, agent_indicators, transactions, final_market_results) = MarketDataStorage.GetEconomicIndicatorsForRange(marketResult, test_range)
        indicators[!,Symbol("Market Name")] .= marketName
        combined_indicators = vcat(combined_indicators, indicators)
        agent_indicators[!,Symbol("Market Name")] .= marketName
        combined_agent_indicators = vcat(combined_agent_indicators, agent_indicators)


        XLSX.writetable("../DATA/$(test_id)/transactions_$(marketName).xlsx", "data" => transactions, "interpretation" => Interpretations.TransactionsInterpretation)

        XLSX.writetable("../DATA/$(test_id)/final_market_results_$(marketName).xlsx", "data" => final_market_results, "interpretation" => Interpretations.DecisionVariablesInterpretation)

    end
    println(combined_indicators)
    println(combined_agent_indicators)

    XLSX.writetable("../DATA/$(test_id)/economic_indicators.xlsx", "data" => combined_indicators, "interpretation" => Interpretations.EconomicIndicatorsInterpretation)

    XLSX.writetable("../DATA/$(test_id)/agent_indicators.xlsx", "data" => combined_agent_indicators, "interpretation" => Interpretations.AgentIndicatorsInterpretation)

end


end;
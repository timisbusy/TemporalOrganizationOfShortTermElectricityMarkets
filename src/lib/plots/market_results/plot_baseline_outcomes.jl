module PlotBaselineOutcomes

using Plots
using JuMP
using Statistics
using DataFrames
using XLSX
using CSV

using ..Helpers

include("../../output_data/market_data_storage.jl")
include("../../output_data/interpretations.jl")

# Excel caps a sheet at 1,048,576 rows including the header. A long-window rolling run's transaction
# table can exceed that (the full-year 2025 rolling 72h run has ~1.47M rows), so it's written as
# `{name}.csv` instead of `{name}.xlsx` in that case - PostAnalysisCommon.LoadCaseFile reads either.
const EXCEL_MAX_DATA_ROWS = 1048575

# csv_above_rows lowers that threshold (config key transactionsCsvAboveRows; 0 = always CSV) - building a large
# .xlsx sheet in memory can exhaust RAM on full-year runs well below Excel's own limit, while CSV.write streams.
function write_transactions(path_without_extension, transactions; csv_above_rows=EXCEL_MAX_DATA_ROWS)
    csv_above_rows = min(csv_above_rows, EXCEL_MAX_DATA_ROWS)
    if nrow(transactions) > csv_above_rows
        println("$(nrow(transactions)) transactions exceed the $(csv_above_rows) row threshold (Excel's limit is $(EXCEL_MAX_DATA_ROWS)) - writing $(path_without_extension).csv instead of .xlsx")
        CSV.write("$(path_without_extension).csv", transactions)
    else
        XLSX.writetable("$(path_without_extension).xlsx", "data" => transactions, "interpretation" => Interpretations.TransactionsInterpretation)
    end
end

function plot(marketresult, config, test_range, test_id)
    # imbalance_agents hardcoded to the Wind/Peak agent config every current experiment uses -
    # revisit if/when a config with different generator names needs this too
    (indicators, agent_indicators, transactions, final_dispatch_decisions, mtu_economic_outcomes) = MarketDataStorage.GetEconomicIndicatorsForRange(marketresult, test_range; imbalance_agents=("6G_Wind", "5G_Peak"))

    println(indicators)
    println(agent_indicators)

    XLSX.writetable("results/$(test_id)/economic_indicators.xlsx", "data" => indicators, "interpretation" => Interpretations.EconomicIndicatorsInterpretation)

    XLSX.writetable("results/$(test_id)/agent_indicators.xlsx", "data" => agent_indicators, "interpretation" => Interpretations.AgentIndicatorsInterpretation)

    XLSX.writetable("results/$(test_id)/final_dispatch_decisions.xlsx", "data" => final_dispatch_decisions, "interpretation" => Interpretations.DecisionVariablesInterpretation)

    XLSX.writetable("results/$(test_id)/mtu_economic_results.xlsx", "data" => mtu_economic_outcomes)

    # written last: the only export that can exceed Excel's row limit (see write_transactions)
    write_transactions("results/$(test_id)/transactions", transactions; csv_above_rows=something(get(config, :transactionsCsvAboveRows, nothing), EXCEL_MAX_DATA_ROWS))

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
    for (marketConfiguration, marketResult) in market_results
        println("calculating indicators for: $marketConfiguration")
        (indicators, agent_indicators, transactions, final_dispatch_decisions, mtu_economic_outcomes) = MarketDataStorage.GetEconomicIndicatorsForRange(marketResult, test_range; imbalance_agents=("6G_Wind", "5G_Peak"))
        indicators[!,Symbol("Market Configuration")] .= marketConfiguration
        combined_indicators = vcat(combined_indicators, indicators)
        agent_indicators[!,Symbol("Market Configuration")] .= marketConfiguration
        combined_agent_indicators = vcat(combined_agent_indicators, agent_indicators)


        write_transactions("results/$(test_id)/RAW/transactions_$(marketConfiguration)", transactions)

        XLSX.writetable("results/$(test_id)/RAW/final_dispatch_decisions_$(marketConfiguration).xlsx", "data" => final_dispatch_decisions, "interpretation" => Interpretations.DecisionVariablesInterpretation)
        
        XLSX.writetable("results/$(test_id)/mtu_economic_results_$(marketConfiguration).xlsx", "data" => mtu_economic_outcomes) #, "interpretation" => Interpretations.DecisionVariablesInterpretation)

        # println("MTU level results for $marketConfiguration")
        # println(mtu_economic_outcomes)

        println(agent_indicators[!, "Agent"])

        #=
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
        =#

    end
    println(combined_indicators)
    # println(combined_agent_indicators)

    XLSX.writetable("results/$(test_id)/economic_indicators.xlsx", "data" => combined_indicators, "interpretation" => Interpretations.EconomicIndicatorsInterpretation)

    XLSX.writetable("results/$(test_id)/agent_indicators.xlsx", "data" => combined_agent_indicators, "interpretation" => Interpretations.AgentIndicatorsInterpretation)
end

end;
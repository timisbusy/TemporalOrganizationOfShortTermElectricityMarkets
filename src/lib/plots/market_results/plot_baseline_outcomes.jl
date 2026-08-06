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

function plotCompare(market_results, config, test_range, test_id, fast_mode)
    combined_indicators = DataFrame()
    combined_agent_indicators = DataFrame()
    for (marketConfiguration, marketResult) in market_results
        println("calculating indicators for: $marketConfiguration")
        (indicators, agent_indicators, transactions, final_dispatch_decisions, mtu_economic_outcomes) = MarketDataStorage.GetEconomicIndicatorsForRange(marketResult, test_range)
        indicators[!,Symbol("Market Configuration")] .= marketConfiguration
        combined_indicators = vcat(combined_indicators, indicators)
        agent_indicators[!,Symbol("Market Configuration")] .= marketConfiguration
        combined_agent_indicators = vcat(combined_agent_indicators, agent_indicators)


        XLSX.writetable("results/$(test_id)/RAW/transactions_$(marketConfiguration).xlsx", "data" => transactions, "interpretation" => Interpretations.TransactionsInterpretation)

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

    # TODO: add this to a different plot file

    if !fast_mode
        sew_assessment_interval = test_range# 9*24:13*24

        may_19_interval = 20*24:(21*24 - 1)
        may_20_interval = 21*24:(22*24 - 1)
        may_21_interval = 22*24:(23*24 - 1)

        print_cases = ["Fixed", "Rolling","FixedSQ"]

        plotInRangeByIntervalLength(market_results, sew_assessment_interval, config[:timePeriodsPerDay], Symbol("Socioeconomic Welfare (€)"))
        plotInRangeByIntervalLength(market_results, sew_assessment_interval, config[:timePeriodsPerDay], Symbol("Storage Revenue (€)"))
        plotDiffInRangeByIntervalLength(market_results, sew_assessment_interval, config[:timePeriodsPerDay], Symbol("Socioeconomic Welfare (€)"), true, ["Rolling", "Fixed"])
        plotDiffInRangeByIntervalLength(market_results, sew_assessment_interval, config[:timePeriodsPerDay], Symbol("Socioeconomic Welfare (€)"), false, ["Rolling", "Fixed"])
        plotDiffInRangeByIntervalLength(market_results, sew_assessment_interval, config[:timePeriodsPerDay], Symbol("Storage Revenue (€)"), true, ["Rolling", "Fixed"])
        plotPhysicalIndicator(market_results, sew_assessment_interval, Symbol("SOC"), print_cases)
        plotPhysicalIndicator(market_results, sew_assessment_interval, Symbol("6G_Wind"), print_cases)
        plotPhysicalIndicator(market_results, sew_assessment_interval, Symbol("2D_ModerateBid"), print_cases)

        println("MAY 19 RESULTS")

        plotPhysicalIndicator(market_results, may_19_interval, Symbol("SOC"), print_cases)
        plotPhysicalIndicator(market_results, may_19_interval, Symbol("6G_Wind"), print_cases)
        plotPhysicalIndicator(market_results, may_19_interval, Symbol("2D_ModerateBid"), print_cases)
        plotPhysicalIndicator(market_results, may_19_interval, Symbol("4G_Shoulder"), print_cases)

        println("MAY 20 RESULTS")

        plotPhysicalIndicator(market_results, may_20_interval, Symbol("SOC"), print_cases)
        plotPhysicalIndicator(market_results, may_20_interval, Symbol("6G_Wind"), print_cases)
        plotPhysicalIndicator(market_results, may_20_interval, Symbol("2D_ModerateBid"), print_cases)
        plotPhysicalIndicator(market_results, may_20_interval, Symbol("4G_Shoulder"), print_cases)

        println("MAY 21 RESULTS")

        plotPhysicalIndicator(market_results, may_21_interval, Symbol("SOC"), print_cases)
        plotPhysicalIndicator(market_results, may_21_interval, Symbol("6G_Wind"), print_cases)
        plotPhysicalIndicator(market_results, may_21_interval, Symbol("2D_ModerateBid"), print_cases)
        plotPhysicalIndicator(market_results, may_21_interval, Symbol("4G_Shoulder"), print_cases)
    end
end


function plotDiffInRangeByIntervalLength(market_results, test_range, interval_length, indicator, sorted, comparison_and_base_names)
    intervalData = []

    intervals = []

    for i in test_range.start / interval_length :((test_range.stop +1) / interval_length) - 1
        interval = UnitRange{Int}(Int(i*interval_length), Int((i+1)*interval_length - 1))
        push!(intervals, interval)
    end

    intervalIndicatorData = Dict{String, Any}()
    # daily_indicators = Dict{String, Any}()
    for (marketConfiguration, marketResult) in market_results
        intervalIndicatorData[marketConfiguration] = []
        for interval in intervals
            # println("data for range:", interval)
            (economic_indicators, agent_indicators, transactions, final_market_results) = MarketDataStorage.GetEconomicIndicatorsForRange(marketResult, interval)
            push!(intervalIndicatorData[marketConfiguration], economic_indicators[!,indicator][1,1])
        end
    end
    # println(intervalIndicatorData)

    diffs = intervalIndicatorData[comparison_and_base_names[1]] .- intervalIndicatorData[comparison_and_base_names[2]]

    xPlotIndicator = ["$interval" for interval in intervals]
    if sorted 
        sort!(diffs, rev=true)
        xPlotIndicator = 1:length(diffs)
    end

    pIndicator = Plots.plot(xlabel="Day", ylabel="$indicator",
                            title="$indicator: $(comparison_and_base_names[1]) - $(comparison_and_base_names[2])")

    Plots.plot!(pIndicator, xPlotIndicator, diffs, label="Difference in $indicator", t=:bar)
    display(pIndicator)
end

function plotInRangeByIntervalLength(market_results, test_range, interval_length, indicator)
    intervalData = []

    intervals = []

    for i in test_range.start / interval_length :((test_range.stop +1) / interval_length) - 1
        interval = UnitRange{Int}(Int(i*interval_length), Int((i+1)*interval_length - 1))
        push!(intervals, interval)
    end

    intervalIndicatorData = Dict{String, Any}()
    # daily_indicators = Dict{String, Any}()
    for (marketConfiguration, marketResult) in market_results
        intervalIndicatorData[marketConfiguration] = []
        for interval in intervals
            # println("data for range:", interval)
            (economic_indicators, agent_indicators, transactions, final_market_results) = MarketDataStorage.GetEconomicIndicatorsForRange(marketResult, interval)
            push!(intervalIndicatorData[marketConfiguration], economic_indicators[!,indicator][1,1])
        end
    end
    # println(intervalIndicatorData)
    xPlotIndicator = ["$interval" for interval in intervals]
    pIndicator = Plots.plot(xlabel="MTU", ylabel="$indicator",
                            title="Comparing $indicator by $interval_length MTU interval")

    for (marketConfiguration, indicator_by_interval) in intervalIndicatorData   
        Plots.plot!(pIndicator, xPlotIndicator, indicator_by_interval, label=marketConfiguration)
    end
    display(pIndicator)
end


marketConfigurationDisplayNames = Dict{String, String}(
    "Fixed" => "Fixed Horizon", 
    "Rolling" =>  "Rolling Horizon",
    "FixedSQ" => "Auction Only",
)

function plotPhysicalIndicator(market_results, test_range, indicator, print_cases)

    indicatorData = Dict{String, Any}()
    # daily_indicators = Dict{String, Any}()
    for marketConfiguration in print_cases
        marketResult = market_results[marketConfiguration]
        indicatorData[marketConfiguration] = []
        (economic_indicators, agent_indicators, transactions, final_market_results) = MarketDataStorage.GetEconomicIndicatorsForRange(marketResult, test_range)
        push!(indicatorData[marketConfiguration], final_market_results[test_range.start .<= final_market_results.mtu .<= test_range.stop,indicator])
    end
    # println(intervalIndicatorData)
    xPlotIndicator = test_range
    pIndicator = Plots.plot(xlabel="MTU", ylabel="$indicator",
                            title="Comparing $indicator")

    for (marketConfiguration, indicatorSeries) in indicatorData   
        Plots.plot!(pIndicator, xPlotIndicator, indicatorSeries, label=marketConfigurationDisplayNames[marketConfiguration])
    end
    display(pIndicator)
end

end;
module PlotPriceDispersionByMTU

using Plots
using JuMP
using Statistics
using DataFrames
using XLSX

using ..Helpers

include("../../output_data/market_data_storage.jl")
include("../../output_data/interpretations.jl")

function plot(marketresult, config, test_range, test_id)
    println("no single plot for price dispersion yet")
    return
    transactions = MarketDataStorage.GetTransactionsForRange(marketresult,test_range)
    println(transactions)
end


function plotCompare(market_results, config, test_range, test_id)
    quantity_symbol = Symbol("Quantity (MWh)")
    price_symbol = Symbol("Price (€/MWh)")
    payrev_symbol = Symbol("Payments/Revenues (€)")
    mtu_symbol = Symbol("Market Time Unit")
    
    for (marketConfiguration, marketresult) in market_results
        transactions = MarketDataStorage.GetTransactionsForRange(marketresult,test_range)
        price_range_total = 0.0
        price_std_squared_total = 0.0
        price_range_count = 0
        price_mean = mean(transactions[:,price_symbol])
        for mtu in test_range
            prices_for_mtu = transactions[transactions[!,mtu_symbol] .== mtu,price_symbol]
            max_price = maximum(prices_for_mtu)
            min_price = minimum(prices_for_mtu)
            price_std = std(prices_for_mtu, corrected=false)
            price_range = max_price - min_price
            # println("MTU $mtu max price: $max_price min_price: $min_price range: $price_range")
            price_range_total += price_range
            price_std_squared_total += price_std^2
            price_range_count += 1
        end
        average_price_range = price_range_total/price_range_count
        pooled_price_std = sqrt(price_std_squared_total/price_range_count)

        println("for $marketConfiguration the average price range was: $average_price_range and the pooled standard deviation was: $pooled_price_std")
        println("for $marketConfiguration the average price was: $price_mean")
        
    end

end


end;
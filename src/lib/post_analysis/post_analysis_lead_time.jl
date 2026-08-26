module PostAnalysisLeadTime

using XLSX, DataFrames, Plots, Statistics, StatsPlots, Latexify


mtuSymbol = Symbol("Market Time Unit")
clearingMTUSymbol = Symbol("Clearing MTU")
timesClearedSymbol = Symbol("Times Cleared")

quantitySymbol = Symbol("Quantity (MWh)")
priceSymbol = Symbol("Price (€/MWh)")


colors =  [:steelblue3 :darkorange2 :red]

function CleanDirectory(path)
	mkpath(path)
end

function PerformAnalysis(results_path_base_in)

	if results_path_base_in != ""
		results_path_base = results_path_base_in

		analysis_dir_path = "$results_path_base/additional_analysis/lead_time_analysis"

		dispatch_decision_paths = Dict{String,String}(
			"Fixed" => "$results_path_base/RAW/final_dispatch_decisions_Fixed.xlsx",
			"Rolling" => "$results_path_base/RAW/final_dispatch_decisions_Rolling.xlsx",
		)

		transaction_paths = Dict{String,String}(
			"Fixed Horizon" => "$results_path_base/RAW/transactions_Fixed.xlsx",
			"Rolling Horizon" => "$results_path_base/RAW/transactions_Rolling.xlsx",
			"Auction Only" => "$results_path_base/RAW/transactions_AuctionOnly.xlsx",
		)
	end

	println("starting analysis")
	CleanDirectory(analysis_dir_path)

	transactions_by_case = Dict{String,DataFrame}()


	start_day = 2
	end_day = 30

	for(case, path) in transaction_paths
		ts = LoadFile(path)
		ts[!,Symbol("Hour")] = ts[!,mtuSymbol] .% 24
		ts[!,Symbol("Day")] = (ts[!,mtuSymbol] .- ts[!,Symbol("Hour")]) ./ 24
		transactions_by_case[case] = ts[start_day .<= ts[!,Symbol("Day")] .<= end_day,:]
		println("$case rows: $(nrow(transactions_by_case[case]))")
	end

	metrics = ["Gross Traded [MWh]","Net Delivered [MWh]"]

	transaction_details_df = DataFrame()
	for (case, ts) in transactions_by_case
		agent_trading_by_case = GetTransactionDetails(case, ts)
		println(agent_trading_by_case)
		if nrow(transaction_details_df) != 0
			transaction_details_df = leftjoin(transaction_details_df, agent_trading_by_case,on=:Agent)
		else
			transaction_details_df = agent_trading_by_case
		end
		# transaction_details_df[!,Symbol(case)] = [charge_per_day,discharge_per_day,charge_per_day-discharge_per_day,charge_per_day+discharge_per_day]
	end

	# transaction_details_df[!, Symbol("Change")] = transaction_details_df[!, Symbol("Rolling")] .- transaction_details_df[!, Symbol("Fixed")]
	# transaction_details_df[!, Symbol("% Change")] = transaction_details_df[!, Symbol("Change")] ./ transaction_details_df[!, Symbol("Fixed")]
	transaction_details_df = transaction_details_df[transaction_details_df[!,:Agent] .!= "Storage",:]
	transaction_details_df = transaction_details_df[transaction_details_df[!,:Agent] .!= "1D_HighBid",:]
	transaction_details_df = transaction_details_df[transaction_details_df[!,:Agent] .!= "2D_ModerateBid",:]
	transaction_details_df = sort(transaction_details_df,[:Agent])
	push!(transaction_details_df,["Total",sum(transaction_details_df[!,2]),sum(transaction_details_df[!,3]),sum(transaction_details_df[!,4]),sum(transaction_details_df[!,5]),sum(transaction_details_df[!,6]),sum(transaction_details_df[!,7])])
	println(transaction_details_df)
	XLSX.writetable("$analysis_dir_path/transaction_details.xlsx", "data" => transaction_details_df; overwrite=true)

	transaction_details_tex = latexify(transaction_details_df; env = :table, booktabs = true, snakecase=true, latex=false,fmt="%'\''d\n")
	write("$analysis_dir_path/transaction_details.tex",transaction_details_tex)

	AgentSellPriceByLeadTime(transactions_by_case, "3G_Base", analysis_dir_path)
	AgentSellPriceByLeadTime(transactions_by_case, "6G_Wind", analysis_dir_path)

	SellAndBuybackPrices(transactions_by_case, analysis_dir_path)
end

function GetTransactionDetails(case, ts)
	agent_trading_by_case = DataFrame()

	gross_traded_symbol = Symbol("Gross traded - $case [MWh]")
	net_delivered_symbol = Symbol("Net delivered - $case [MWh]")

	by_agent_ts = groupby(ts,:Agent)
	gross_traded = combine(by_agent_ts, quantitySymbol => (q -> sum(abs.(q))) => gross_traded_symbol)
	net_delivered = combine(by_agent_ts, quantitySymbol => (q -> sum(q)) => net_delivered_symbol)
	
	println("Transaction info for $case")
	println("gross_traded: $gross_traded")
	println("net_delivered: $net_delivered")

	details = leftjoin(gross_traded,net_delivered,on=:Agent)
	return details
end

function AgentSellPriceByLeadTime(transactions_by_case,agent, analysis_dir_path)
	CASES =  ["Fixed Horizon","Rolling Horizon", "Auction Only"]
	groupRanges = [1:12, 13:24, 25:36]
	groupNames = ["1-12", "13-24", "25-36"]


    volume = zeros(Float64, length(groupNames), length(CASES))
    price = zeros(Float64, length(groupNames), length(CASES))

    
    for (i,groupName) in enumerate(groupNames), (j, case) in enumerate(CASES)
		case_ts = transactions_by_case[case]
		case_ts = case_ts[(case_ts.Agent .== agent .&& case_ts[!,quantitySymbol] .>= 0),:]
		case_ts[:,:LeadTime] = case_ts[!,mtuSymbol] .- case_ts[!,clearingMTUSymbol] 
		case_ts_in_group = case_ts[groupRanges[i].start .<= case_ts[!,:LeadTime] .<= groupRanges[i].stop,:]
		
		volume_in_group = combine(case_ts_in_group, quantitySymbol => sum )[1,1]
		print("Volume for $groupName in $case: $volume_in_group")
		price_in_group = combine(case_ts_in_group, [priceSymbol,quantitySymbol] => ( (p,q) -> sum(p .* q)/sum(q) ) )[1,1]
		print("Price for $groupName in $case: $price_in_group")

		volume[i,j] = volume_in_group / 1e6
		price[i,j] = price_in_group
		
	end



    agentSalesLeadTime = plot(groupedbar(
        groupNames,
        volume,
        label = reshape(CASES, 1, :),
        bar_position = :dodge,
        color = colors,
        ylabel = "Sold volume (m MWh)",
        title = "$agent Sales by Lead Time",
        legend = :topleft,
        grid = :y,
        framestyle = :box,
        ylims = (0, maximum(volume) * 1.22),
        # left_margin = 16mm,
        # bottom_margin = 14mm,
    ))

    agentSellPrice = plot(groupedbar(
        groupNames,
        price,
        label = reshape(CASES, 1, :),
        bar_position = :dodge,
        color = colors,
        ylabel = "Avg sell price (EUR/MWh)",
        title = "$agent Sell Price by Lead Time",
        legend = :topleft,
        grid = :y,
        framestyle = :box,
        ylims = (0, maximum(price) * 1.20),
        # left_margin = 16mm,
        # bottom_margin = 14mm,
    ))

    display(agentSalesLeadTime)
    display(agentSellPrice)
	savefig(agentSalesLeadTime, "$analysis_dir_path/$(agent)_sales_lead_time.png")
	savefig(agentSellPrice, "$analysis_dir_path/$(agent)_sell_price.png")
    
end




function SellAndBuybackPrices(transactions_by_case, analysis_dir_path)
	CASES =  ["Fixed Horizon","Rolling Horizon", "Auction Only"]
	agents = ["3G_Base","6G_Wind","7G_Solar"]


    sell_prices = zeros(Float64, length(agents), length(CASES))
    buyback_prices = zeros(Float64, length(agents), length(CASES))

    for (i,agent) in enumerate(agents), (j, case) in enumerate(CASES)
		case_ts = transactions_by_case[case]
		case_ts = case_ts[(case_ts.Agent .== agent),:]
		sales_ts = case_ts[case_ts[!,quantitySymbol] .> 0,:]
		buyback_ts = case_ts[case_ts[!,quantitySymbol] .< 0,:]
		sales_price_for_agent = combine(sales_ts, [priceSymbol,quantitySymbol] => ( (p,q) -> sum(p .* q)/sum(q) ) )[1,1]
		buyback_price_for_agent = combine(buyback_ts, [priceSymbol,quantitySymbol] => ( (p,q) -> sum(p .* q)/sum(q) ) )[1,1]
		# sales_price_for_agent = combine(sales_ts, [priceSymbol,quantitySymbol] => ( (p,q) -> mean(p) ) )[1,1]
		# buyback_price_for_agent = combine(buyback_ts, [priceSymbol,quantitySymbol] => ( (p,q) -> mean(p) ) )[1,1]
		sell_prices[i,j] = sales_price_for_agent
		buyback_prices[i,j] = buyback_price_for_agent
	end

    ymax = maximum(vcat(vec(sell_prices), vec(buyback_prices)))

    p = plot(
        title = "Average Sell and Buyback Prices",
        ylabel = "EUR/MWh",
        xticks = (1:length(agents), agents),
        xlims = (0.45, length(agents) + 0.55),
        ylims = (-2, ymax * 1.22),
        legend = :topright,
        grid = :y,
        framestyle = :box,
        size = (1400, 760),
        # left_margin = 16mm,
        # bottom_margin = 14mm,
    )

    offsets = [-0.18, 0.0, 0.18]
    for (j, case_name) in enumerate(CASES)
        xpos = (1:length(agents)) .+ offsets[j]
        scatter!(p, xpos, sell_prices[:, j], marker=:circle, markersize=10,
                 color=colors[j], label="$case_name sell")
        scatter!(p, xpos, buyback_prices[:, j], marker=:utriangle, markersize=10,
                 color=colors[j], label="$case_name buyback")
        for i in 1:length(agents)
            plot!(p, [xpos[i], xpos[i]], [buyback_prices[i, j], sell_prices[i, j]],
                  color=colors[j], alpha=0.55, label=false)
        end
    end
    display(p)
	savefig(p, "$analysis_dir_path/sell_and_buyback_prices.png")
    
end

function LoadFile(filepath)
	# filepath = GenerateFilepath(result_id, set_id)

    df = DataFrame(XLSX.readtable(filepath, "data"))
    return df
end



end;
module MarketSequence



# TODO: tests around these functions, they are important.


function marketMatch(t, market, timePeriodsPerDay)
	# determine if a market should operate in this moment based on time of day
	if ((t - market[:clockTimeBegin]) % market[:clearingInterval] == 0) # if the offset between this period and the time we begin is zero, or a multiple of the interval, this period should hold a market
		return true
	end
	return false
end

# use configuration (data) and the time period in question (1 to end of window in which to consider clearing) to determine if a market should be cleared in this time period, returning a set of any markets that match

function generateMarketSetForTimePeriod(t, data)
	markets = []

	for market in data
		if marketMatch(t, market, market[:timePeriodsPerDay])
			push!(markets, market)
		end
	end
	

	return markets
end

function GenerateMarketSequence(config, time_range)
	println(config)
	marketSequence = []
	# generate the sequence of markets - one entry for each t, empty if no markets to be run at that time, otherwise, a list of markets to clear at that time
    for t in time_range
    	push!(marketSequence ,generateMarketSetForTimePeriod(t,config)) # note, this will be 1 indexed, so we are off by one on MTUs and need a getter that accounts for this
    end
    return marketSequence
end

function GetMarketsForMTU(marketSequence, mtu)
	if mtu < 0 || mtu >= length(marketSequence)
		println("WARN: GetMarketsForMTU with mtu out of range: $mtu")
		return []
	end
	return marketSequence[mtu + 1]
end

end;
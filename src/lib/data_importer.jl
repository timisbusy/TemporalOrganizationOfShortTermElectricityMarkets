module DataImporter

using YAML, Dates


# create a market configuration object from a file

function load_market_configuration(path::String, expTimePeriodsPerDay::Int)
    marketCfg = YAML.load_file(path)

    # ensure that the market configuration matches with the experiment configuration
    marketTimePeriodsPerDay = get(marketCfg,"timePeriodsPerDay", Int) 
    expTimePeriodsPerDay == marketTimePeriodsPerDay || throw("market and experiment configurations do not match: $(marketTimePeriodsPerDay) !== $(expTimePeriodsPerDay)")

    marketSequence = []
    for (name, market) in get(marketCfg,"marketSequence",Dict())
        addMarket = Dict{Symbol,Any}()
        addMarket[:name] = name
        addMarket[:timePeriodsPerDay] = expTimePeriodsPerDay
        addMarket[:clearingInterval] = get(market,"clearingInterval", Int) # number of time periods between market clearing/optimization rounds
        addMarket[:optimizationWindow] = get(market,"optimizationWindow", Int) # number of time periods to consider in each round
        addMarket[:lookAheadDistance] = get(market,"lookAheadDistance", Int) # window under consideration starts lookAheadDistance time periods ahead
        addMarket[:clockTimeBegin] = get(market,"clockTimeBegin", Int) # expressed in market clearing periods - how long from the beginning of the day should this sequence begin?
        addMarket[:enforceRampRates] = haskey(marketCfg, "enforceRampRates") ? get(marketCfg,"enforceRampRates", Bool) : true # default to true. if false, ramp rates for conventional generators will be disabled in this market
        push!(marketSequence, addMarket)
    end

    return marketSequence
end

# compile and validate incoming configuration data

function load_input_data(path::String)
    # Read the YAML file into a nested Julia Dict/Array structure
    cfg = YAML.load_file(path)

    # Internal data dictionary that we pass to the other functions
    data = Dict{Symbol,Any}()

    # give the experiment a descriptive name
    data[:name] = String(cfg["name"])

    data[:clearForDays] = Int(cfg["clearForDays"])
    data[:timePeriodsPerDay] = Int(cfg["timePeriodsPerDay"]) # number of time periods (timesteps) in each day
    data[:noiseLevel] = float(cfg["noiseLevel"])
    data[:startDate] = haskey(cfg,"startDate") ? cfg["startDate"] : Date(2026,1,1) 
    data[:endDate] = data[:startDate] + Dates.Day(data[:clearForDays])

    if haskey(cfg, "compare") && cfg["compare"] == "market"
        data[:marketSequences] = Dict{String,Any}()
        for (marketName, marketConfigFilepath) in cfg["marketConfigs"]
            data[:marketSequences][String(marketName)] = load_market_configuration("src/configs/markets/$(marketConfigFilepath)", data[:timePeriodsPerDay])
        end

    else
        # if we're not comparing markets, add the single market config
        data[:marketSequence] = load_market_configuration("src/configs/markets/$(cfg["marketConfig"])", data[:timePeriodsPerDay])
    end

    agentCfg = YAML.load_file("src/configs/agents/$(cfg["agentConfig"])")

    # generators: separate blocks for dispatchable and variable generators
    data[:dispatchableGenerators] = agentCfg["dispatchableGenerators"]
    data[:variableGenerators]     = get(agentCfg, "variableGenerators", Dict())

    # demand segments: Base and Flex demand, each with a bid and hourly quantities
    data[:demandSegments] = agentCfg["demand"]["segments"]

    # storage parameters
    data[:batteryStorage] = get(agentCfg, "batteryStorage", nothing)


    return data
end


end;
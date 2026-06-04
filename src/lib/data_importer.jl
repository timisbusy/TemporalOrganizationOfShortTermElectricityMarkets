module DataImporter

using YAML, Dates, DataFrames, XLSX

CONFIG_PATH =  "src/configs" # "../configs"

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


function load_market_configuration_xlsx(path::String, expTimePeriodsPerDay::Int)
    marketCfg_df = DataFrame(XLSX.readtable(path, "Validation"))
    marketSequence_df = DataFrame(XLSX.readtable(path, "MarketSequence"))

    # ensure that the market configuration matches with the experiment configuration
    marketTimePeriodsPerDay = Int(marketCfg_df[!,"MTU Per Day"][1]) 
    expTimePeriodsPerDay == marketTimePeriodsPerDay || throw("market and experiment configurations do not match: $(marketTimePeriodsPerDay) !== $(expTimePeriodsPerDay)")

    marketSequence = []
    for marketDef in eachrow(marketSequence_df)
        addMarket = Dict{Symbol,Any}()
        addMarket[:name] = String(marketDef["Market Name"])
        addMarket[:timePeriodsPerDay] = expTimePeriodsPerDay
        addMarket[:clearingInterval] = Int(marketDef["Clearing Interval"]) # number of time periods between market clearing/optimization rounds
        addMarket[:optimizationWindow] = Int(marketDef["Optimization Window"]) # number of time periods to consider in each round
        addMarket[:lookAheadDistance] = Int(marketDef["Look Ahead Distance"]) # window under consideration starts lookAheadDistance time periods ahead
        addMarket[:clockTimeBegin] = Int(marketDef["Clock Time Begin"]) # expressed in market clearing periods - how long from the beginning of the day should this sequence begin?
        addMarket[:enforceRampRates] = hasproperty(marketDef, "Enforce Ramp Rates") ? Bool(marketDef["Enforce Ramp Rates"]) : true # default to true. if false, ramp rates for conventional generators will be disabled in this market
        push!(marketSequence, addMarket)
    end

    return marketSequence
end

# compile and validate incoming configuration data

function load_input_data(path::String)
    if occursin("xlsx", path) # otherwise, the assumption is that it's yaml
        return load_input_data_xlsx(path)
    end
    # Read the YAML file into a nested Julia Dict/Array structure
    cfg = YAML.load_file(path)
    # println(cfg)
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
            data[:marketSequences][String(marketName)] = load_market_configuration("$(CONFIG_PATH)/markets/$(marketConfigFilepath)", data[:timePeriodsPerDay])
        end

    else
        # if we're not comparing markets, add the single market config
        data[:marketSequence] = load_market_configuration("$(CONFIG_PATH)/markets/$(cfg["marketConfig"])", data[:timePeriodsPerDay])
    end

    agentCfg = YAML.load_file("$(CONFIG_PATH)/agents/$(cfg["agentConfig"])")

    # generators: separate blocks for dispatchable and variable generators
    data[:dispatchableGenerators] = agentCfg["dispatchableGenerators"]
    data[:variableGenerators]     = get(agentCfg, "variableGenerators", Dict())

    # demand segments: Base and Flex demand, each with a bid and hourly quantities
    data[:demandSegments] = agentCfg["demand"]["segments"]

    # storage parameters
    data[:batteryStorage] = get(agentCfg, "batteryStorage", nothing)


    return data
end

function load_input_data_xlsx(path::String)
    # Read the YAML file into a nested Julia Dict/Array structure
    cfg_df = DataFrame(XLSX.readtable(path, "data"))
    # cfg = YAML.load_file(path)
    # println(cfg_df)
    # Internal data dictionary that we pass to the other functions
    data = Dict{Symbol,Any}()

    # give the experiment a descriptive name
    data[:name] = String(cfg_df[!,"Name"][1])

    data[:clearForDays] = Int(cfg_df[!,"Clear for Days"][1])
    data[:timePeriodsPerDay] = Int(cfg_df[!,"MTU per Day"][1]) # number of MTU in each day
    data[:noiseLevel] = float(cfg_df[!,"Noise Level"][1])
    data[:startDate] = hasproperty(cfg_df,"Start Date") && cfg_df[!,"Start Date"][1] != "" ? cfg_df[!,"Start Date"][1] : Date(2026,1,1) 
    data[:endDate] = data[:startDate] + Dates.Day(data[:clearForDays])

    if hasproperty(cfg_df,"Compare") && cfg_df[!,"Compare"][1] == "market"
        data[:marketSequences] = Dict{String,Any}()
        for (marketName, marketConfigFilepath) in cfg_df[!,"Market Configs"][1]
            data[:marketSequences][String(marketName)] = load_market_configuration("$(CONFIG_PATH)/xlsx/markets/$(marketConfigFilepath)", data[:timePeriodsPerDay])
        end

    else
        # if we're not comparing markets, add the single market config
        data[:marketSequence] = load_market_configuration_xlsx("$(CONFIG_PATH)/xlsx/markets/$(cfg_df[!,"Market Configuration"][1])", data[:timePeriodsPerDay])
    end


    genCfg = DataFrame(XLSX.readtable("$(CONFIG_PATH)/xlsx/agents/$(cfg_df[!,"Agent Configuration"][1])", "Generators"))
    demandCfg = DataFrame(XLSX.readtable("$(CONFIG_PATH)/xlsx/agents/$(cfg_df[!,"Agent Configuration"][1])", "Demands"))
    storageCfg = DataFrame(XLSX.readtable("$(CONFIG_PATH)/xlsx/agents/$(cfg_df[!,"Agent Configuration"][1])", "Storage"))

    dispatchableGenCfg = genCfg[genCfg[!,"Type"] .== "Dispatchable",:]
    variableGenCfg = genCfg[genCfg[!,"Type"] .== "Variable",:]

    # generators: separate dictionaries for dispatchable and variable generators
    data[:dispatchableGenerators] = Dict{String, Any}()

    for genRow in eachrow(dispatchableGenCfg)
        gen = Dict{String, Any}(
            "bidPrice" => genRow["Bid Price"],
            "capacity" => genRow["Capacity"],
            "rampRate" => genRow["Ramp Rate"],
            "initialQuantity" => genRow["Initial Quantity"],
            "emissionFactor" => genRow["Emission Factor"],
        )
        gen["conversionFactor"] = .001
        data[:dispatchableGenerators][String(genRow["Name"])] = gen
    end

    data[:variableGenerators] = Dict{String, Any}()

    for genRow in eachrow(variableGenCfg)
        gen = Dict{String, Any}(
            "bidPrice" => genRow["Bid Price"],
            "capacity" => genRow["Capacity"],
        )

        genRow["Profile"] !== missing ? gen["profile"] = parse.(Float64,split(strip(genRow["Profile"],['"','[',']']),',')) : false
        genRow["Profile File"] !== missing ? gen["profile_file"] = genRow["Profile File"] : false
        genRow["Profile Type"] !== missing ? gen["profile_type"] = genRow["Profile Type"] : false
        gen["conversionFactor"] = .001
        data[:variableGenerators][String(genRow["Name"])] = gen
    end
    
    # demand segments: Base and Flex demand, each with a bid and hourly quantities
    data[:demandSegments] = Dict{String, Any}()

    for dRow in eachrow(demandCfg)
        dem = Dict{String, Any}(
            "bidPrice" => dRow["Bid Price"],
        )
        dRow["Profile"] !== missing ? dem["profile"] = parse.(Float64,split(strip(dRow["Profile"],['"','[',']']),',')) : false
        dRow["Profile File"] !== missing ? dem["profile_file"] = dRow["Profile File"] : false
        dRow["Profile Type"] !== missing ? dem["profile_type"] = dRow["Profile Type"] : false
        dem["conversionFactor"] = .001
        
        data[:demandSegments][String(dRow["Name"])] = dem
    end
    
    # storage parameters
    data[:batteryStorage] = Dict{String, Any}(
        "energyCapacity" => Float64(storageCfg[!,"Energy Capacity"][1]),
        "powerCapacity" => Float64(storageCfg[!,"Power Capacity"][1]),
        "efficiency" => Float64(storageCfg[!,"Efficiency"][1]),
        "initialSOC" => Float64(storageCfg[!,"Initial SOC"][1]),
        "endSOC" => Float64(storageCfg[!,"End SOC"][1]),
    )


    return data
end


end;
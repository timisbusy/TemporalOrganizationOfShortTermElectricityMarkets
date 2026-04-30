module ClearMarket

using JuMP, XLSX, Dates, MathOptInterface

include("../helpers.jl")
using .Helpers.HelperModelResults

include("../data_importer.jl")

# include("../models/rolling_model.jl")
# include("../models/rolling_model_with_ramp_rates.jl")
include("../models/flexible_model.jl")
#=
include("../plots/plot_hourly_market_equilibrium.jl") # TODO: rename
include("../plots/plot_market_prices_with_storage.jl")
include("../plots/plot_state_of_charge.jl")
include("../plots/plot_generation_stack.jl")

# rolling plots
include("../plots/plot_price_evolution.jl")
include("../plots/plot_generation_stack_rolling.jl")
include("../plots/plot_dispatch_changes_for_hour.jl") # TODO: rename
include("../plots/plot_state_of_charge_rolling.jl")
include("../plots/plot_peak_generation_and_storage_use.jl")
include("../plots/plot_wind_forecast_stochasticity.jl")
# include("../plots/plot_baseline_outcomes.jl")
include("../plots/plot_transaction_volumes.jl")
include("../plots/plot_adjustment_dispatch_clearing_volume.jl")


include("../plots/comparison/plot_comparison_baseline_outcomes.jl")
include("../plots/comparison/plot_comparison_imbalance.jl")
include("../plots/comparison/plot_comparison_table_for_mtu.jl")

=#

# new plots

include("../plots/market_results/plot_market_equilibrium_for_window.jl")
include("../plots/market_results/plot_baseline_outcomes.jl")
include("../plots/market_results/plot_generation_stack.jl")

include("../helpers/helper_input_data.jl")
include("./market_sequence.jl")

include("../output_data/market_data_storage.jl")
include("../output_data/interpretations.jl")


function ClearSimple(config_file, test_id)

	config = DataImporter.load_input_data(config_file)
	longest_market_window = max.([m[:optimizationWindow] for m in config[:marketSequence]])[1]
	last_mtp = config[:clearForDays]*config[:timePeriodsPerDay] - longest_market_window
	time_period_range = range(0,last_mtp) # go from time_period 0 to the last mtp for which we have a full data set
    
    marketSequence = MarketSequence.GenerateMarketSequence(config[:marketSequence], time_period_range)
	marketresult = Vector{MarketDataStorage.MarketResult}()
	initialization = Dict(
	    	:SOC => config[:batteryStorage]["initialSOC"]*config[:batteryStorage]["energyCapacity"],
	    	:Q_gen => Dict{String,Float64}( (g, float(gConfig["initialQuantity"])) for (g, gConfig) in config[:dispatchableGenerators])
	    )


	variableGeneratorProfiles = Dict{String,Vector{Float64}}()

    for (gName, gData) in config[:variableGenerators]
    	variableGeneratorProfiles[gName] = Vector{Float64}()
    	if haskey(gData,"profile")
	    	input_profile = gData["profile"]
	    	for t in time_period_range
	    		push!(variableGeneratorProfiles[gName], input_profile[(t%length(input_profile))+ 1])
	    	end
	    elseif haskey(gData,"profile_file") && haskey(gData,"profile_type") 
	    	columnName = (gData["profile_type"] == "availability") ? "percentage" : throw("unrecognized profile_type for $gName: $(gData["profile_type"])")
	    	# todo: test this mechanism
	    	input_profile = HelperInputData.GetProfileFromCSV(gData["profile_file"], columnName, config[:startDate]:config[:endDate], config[:timePeriodsPerDay])
	    	for t in time_period_range
	    		push!(variableGeneratorProfiles[gName], input_profile[(t%length(input_profile))+ 1])
	    	end
	    	gData["profile"] = input_profile
	    else
	    	throw("generator profile for $gName is incomplete. it should either include a profile key or both profile_file and profile_type")
	    end
    end

    for (dName, dData) in config[:demandSegments]
    	if haskey(dData,"profile")
	    	continue
	    elseif haskey(dData,"profile_file") && haskey(dData,"profile_type") 
	    	columnName = (dData["profile_type"] == "quantity") ? "volume (kWh)" : throw("unrecognized profile_type for $dName: $(dData["profile_type"])")
	    	input_profile = HelperInputData.GetProfileFromCSV(dData["profile_file"], columnName, config[:startDate]:config[:endDate], config[:timePeriodsPerDay])
	    	dData["profile"] = input_profile .* .001 # convert from kWh to MWh
	    elseif haskey(dData,"quantity_constant")
	    	dData["profile"] = [dData["quantity_constant"] for t in time_period_range]
	    else
	    	throw("demand profile for $dName is incomplete. it should either include a profile key or both profile_file and profile_type keys or a quantity_constant key")
	    end
    end

    mePlotDone = false

    # for each market in marketSequences note the nesting here so a single time period could hold more than one market (but really probably won't in most cases) - case where it would - could be when holding a market 2 days ahead, for example

	for t in time_period_range
		marketsAtTime = MarketSequence.GetMarketsForMTU(marketSequence, t)
		for market in marketsAtTime
			println("$(market[:name]) market at time: $t looking ahead $(market[:lookAheadDistance]) with optimization window length $(market[:optimizationWindow])")
			m = FlexibleMarketModel.build(t, marketresult, initialization, config, market)
			optimize!(m)
			println(termination_status(m))
			MarketDataStorage.AddMarketResult!(marketresult, m, t, market[:name])

    		XLSX.writetable("../DATA/$(test_id)/decisionvariables_$(config[:name])_$(t).xlsx", "data" => marketresult[length(marketresult)].DecisionVariables, "interpretation" => Interpretations.DecisionVariablesInterpretation)
		
		    XLSX.writetable("../DATA/$(test_id)/transactions_$(config[:name])_$(t).xlsx", "data" => marketresult[length(marketresult)].Transactions, "interpretation" => Interpretations.TransactionsInterpretation)
		
    		if mePlotDone == false
    			mePlotDone = true
    			PlotMarketEquilibriumForWindow.plot(marketresult, t+market[:lookAheadDistance]:t+market[:lookAheadDistance]+market[:optimizationWindow] - 1)
    		end
		end


	end

	test_range = range(config[:timePeriodsPerDay],config[:timePeriodsPerDay]*(config[:clearForDays] - 1) - 1)
	println(test_range.start, test_range.stop)

	PlotBaselineOutcomes.plot(marketresult, config, test_range, test_id)
	PlotGenerationStack.plot(marketresult, config, test_range, test_id)

	return marketresult
end


function ClearMarketComparison(config_file, test_id)


	config = DataImporter.load_input_data(config_file)
	allWindows = ([m[:optimizationWindow] for (n, ms) in config[:marketSequences] for m in ms])
	println(allWindows)
	longest_market_window = max.(allWindows)[1]
	last_mtp = config[:clearForDays]*config[:timePeriodsPerDay] - longest_market_window
	time_period_range = range(0,last_mtp) # go from time_period 0 to the last mtp for which we have a full data set
    
    marketSequences = Dict{String,Any}()
    marketResults = Dict{String,Vector{MarketDataStorage.MarketResult}}()

    for (market_name, market_config) in config[:marketSequences]
	    marketSequences[market_name] = MarketSequence.GenerateMarketSequence(config[:marketSequences][market_name], time_period_range)
		marketResults[market_name] = Vector{MarketDataStorage.MarketResult}()
    end

    initialization = Dict(
    	:SOC => config[:batteryStorage]["initialSOC"]*config[:batteryStorage]["energyCapacity"],
    	:Q_gen => Dict{String,Float64}( (g, float(gConfig["initialQuantity"])) for (g, gConfig) in config[:dispatchableGenerators])
    )

	variableGeneratorProfiles = Dict{String,Vector{Float64}}()

    for (gName, gData) in config[:variableGenerators]
    	variableGeneratorProfiles[gName] = Vector{Float64}()
    	if haskey(gData,"profile")
	    	input_profile = gData["profile"]
	    	for t in time_period_range
	    		push!(variableGeneratorProfiles[gName], input_profile[(t%length(input_profile))+ 1])
	    	end
	    elseif haskey(gData,"profile_file") && haskey(gData,"profile_type") 
	    	columnName = (gData["profile_type"] == "availability") ? "percentage" : throw("unrecognized profile_type for $gName: $(gData["profile_type"])")
	    	input_profile = HelperInputData.GetProfileFromCSV(gData["profile_file"], columnName, config[:startDate]:config[:endDate], config[:timePeriodsPerDay])
	    	for t in time_period_range
	    		push!(variableGeneratorProfiles[gName], input_profile[(t%length(input_profile))+ 1])
	    	end
	    	gData["profile"] = input_profile
	    else
	    	throw("generator profile for $gName is incomplete. it should either include a profile key or both profile_file and profile_type")
	    end
    end

    for (dName, dData) in config[:demandSegments]
    	if haskey(dData,"profile")
	    	continue
	    elseif haskey(dData,"profile_file") && haskey(dData,"profile_type") 
	    	columnName = (dData["profile_type"] == "quantity") ? "volume (kWh)" : throw("unrecognized profile_type for $dName: $(dData["profile_type"])")
	    	input_profile = HelperInputData.GetProfileFromCSV(dData["profile_file"], columnName, config[:startDate]:config[:endDate], config[:timePeriodsPerDay])
	    	dData["profile"] = input_profile .* .001 # convert from kWh to MWh
	    elseif haskey(dData,"quantity_constant")
	    	dData["profile"] = [dData["quantity_constant"] for t in time_period_range]
	    else
	    	throw("demand profile for $dName is incomplete. it should either include a profile key or both profile_file and profile_type keys or a quantity_constant key")
	    end
    end
    mePlotDone = false

    # for each market in marketSequences note the nesting here so a single time period could hold more than one market (but really probably won't in most cases) - case where it would - could be when holding a market 2 days ahead, for example

	for t in time_period_range
		# TODO: here add noise to forecast

		for (marketName, marketSequence) in marketSequences
			marketsAtTime = MarketSequence.GetMarketsForMTU(marketSequence, t)
			for market in marketsAtTime
				println("$(market[:name]) market at time: $t looking ahead $(market[:lookAheadDistance]) with optimization window length $(market[:optimizationWindow])")
				m = FlexibleMarketModel.build(t, marketResults[marketName], initialization, config, market)
				optimize!(m)
				println(termination_status(m))
				if termination_status(m) !== MathOptInterface.OPTIMAL
					throw("non optimal solution: $(termination_status(m))")
				end
				MarketDataStorage.AddMarketResult!(marketResults[marketName], m, t, market[:name])

	    		XLSX.writetable("../DATA/$(test_id)/decisionvariables_$(marketName)_$(t).xlsx", "data" => marketResults[marketName][length(marketResults[marketName])].DecisionVariables, "interpretation" => Interpretations.DecisionVariablesInterpretation)
			
			    XLSX.writetable("../DATA/$(test_id)/transactions_$(marketName)_$(t).xlsx", "data" => marketResults[marketName][length(marketResults[marketName])].Transactions, "interpretation" => Interpretations.TransactionsInterpretation)
			
	    		if mePlotDone == false
	    			mePlotDone = true
	    			PlotMarketEquilibriumForWindow.plot(marketResults[marketName], t+market[:lookAheadDistance]:t+market[:lookAheadDistance]+market[:optimizationWindow] - 1)
	    		end
			end
		end

	end

	test_range = range(config[:timePeriodsPerDay],config[:timePeriodsPerDay]*(config[:clearForDays] - 1) - 1)
	short_test_range = range(config[:timePeriodsPerDay],config[:timePeriodsPerDay]*3 - 1)
	println(test_range.start, test_range.stop)

	PlotBaselineOutcomes.plotCompare(marketResults, config, test_range, test_id)
	PlotGenerationStack.plotCompare(marketResults, config, short_test_range, test_id)

	return marketResults

end


#=

function ClearTogether(configs, test_id)
	# TODO: revisit clearing window idea - there is an assumption here that they match
	first_config = configs[1]
	last_mtp = first_config[:clearForDays]*first_config[:timePeriodsPerDay] - first_config[:optimizationWindow]
	time_period_range = range(0,last_mtp) # go from time_period 1 to the last mtp for which we have a full data set
    
	configMap = Dict{String,Any}()
    marketSequences = Dict{String,Any}()
    # resultsets = Dict{String,Any}()
    initializations = Dict{String,Any}()

    marketresults = Dict{String,Any}()

    for config in configs
    	configMap[config[:name]] = config
    	marketSequences[config[:name]] = MarketSequence.GenerateMarketSequence(config, time_period_range)
    	marketresults[config[:name]] = Vector{MarketDataStorage.MarketResult}()
		initializations[config[:name]] = Dict(
		    	:SOC => config[:batteryStorage]["initialSOC"]*config[:batteryStorage]["energyCapacity"],
		    	:Q_gen => Dict{String,Float64}( (g, float(gConfig["initialQuantity"])) for (g, gConfig) in config[:dispatchableGenerators])
		    )
    end


	variableGeneratorProfiles = Dict{String,Vector{Float64}}()

    for (gName, gData) in first_config[:variableGenerators]
    	variableGeneratorProfiles[gName] = Vector{Float64}()
    	input_profile = gData["profile"]
    	for t in time_period_range
    		push!(variableGeneratorProfiles[gName], input_profile[(t%length(input_profile))+ 1])
    	end
    end


    # for each market in marketSequences note the nesting here so a single time period could hold more than one market (but really probably won't in most cases) - case where it would - could be when holding a market 2 days ahead, for example
    # a function here that can be reused across strategies. It takes: resultset, initialization, configuration, and market parameters, using the same interior functionality so we're all apples to apples.

	for t in time_period_range
		# println("clearing ", t)

		# TODO: here the same system input parameters should be used

		# TODO: a new approach to noise
		if t != last_mtp # skip for last time period
	        if haskey(first_config,:noiseLevel) && first_config[:noiseLevel] > 0
	            noise_std = float(first_config[:noiseLevel]) 
	            for (gName, profile) in variableGeneratorProfiles
		            noisy_profile = HelperInputData.add_noise_pre!(profile, noise_std, t, min(t+first_config[:optimizationWindow], last_mtp))
		        	for config in configs
		        		configMap[config[:name]][:variableGenerators][gName]["profile"] = noisy_profile
		        	end
		        end
	        end
	    end

		for (name, marketSequence) in marketSequences
			marketsAtTime = MarketSequence.GetMarketsForMTU(marketSequence, t)
			for market in marketsAtTime
				if market[:name] == "DayAhead"
					println("day ahead market at time: $t looking ahead $(market[:lookAheadDistance]) with optimization window length $(market[:optimizationWindow])")
				end
				m = FlexibleMarketModel.build(t, marketresults[name], initializations[name], configMap[name], market)
				optimize!(m)
				# ProcessData.AddToResultSet!(resultsets[name], m, t, market[:name])

				# testing new data storage
				MarketDataStorage.AddMarketResult!(marketresults[name], m, t, market[:name])

        		XLSX.writetable("../DATA/$(test_id)/decisionvariables_$(name)_$(t).xlsx", "sheet1" => marketresults[name][length(marketresults[name])].DecisionVariables)
			end
		end
		# println("finish clearing ", t)
	end

	# println(marketresults)

	variableGenRealized = Dict{String, Vector{Float64}}()
	for (gName, gData) in first_config[:variableGenerators]
		variableGenRealized[gName] = variableGeneratorProfiles[gName] .*= gData["capacity"] * (24/first_config[:timePeriodsPerDay])
	end


	test_range = range(first_config[:timePeriodsPerDay]+1,first_config[:timePeriodsPerDay]*(first_config[:clearForDays] - 1))

	plots = [PlotBaselineOutcomes, PlotStateOfChargeRolling, PlotPeakGenerationAndStorageUse, PlotWindForecastStochasticity, PlotGenerationStackRolling, PlotPriceEvolution]

	for plot in plots
		for (name, resultset) in resultsets
			plot.plot(resultset, name, test_id, test_range)
		end
	end


	PlotComparisonImbalance.plot(resultsets, variableGenRealized, test_range, test_id)
	
	PlotComparisonBaselineOutcomes.plot(resultsets, configMap, test_range, test_id)

	return (marketresults, variableGenRealized, configMap)

	# table output for economic indicators for a single MTU
	# PlotComparisonTableForMTU.plot(resultsets, configMap[first_config[:name]][:variableGenerators], 235)
end

=#

#=
function ClearComparison(config_files, test_id)
	configs = []
	for config_file in config_files
		config = DataImporter.load_input_data(config_file)
		push!(configs, config)
	end

	return ClearMarket.ClearTogether(configs, test_id)
end

function ClearComparisonWithVRESFlexScale(config_files, vres_scale, flex_scale, test_id)
	configs = []
	for config_file in config_files
		config = DataImporter.load_input_data(config_file)
		for (gName, gConfig) in config[:variableGenerators]
			gConfig["capacity"] = gConfig["capacity"] * vres_scale
		end
		config[:batteryStorage]["energyCapacity"] =  config[:batteryStorage]["energyCapacity"] * flex_scale
		config[:batteryStorage]["powerCapacity"] =  config[:batteryStorage]["powerCapacity"] * flex_scale
		push!(configs, config)
	end

	return ClearMarket.ClearTogether(configs, test_id)


end

function ClearComparisonWithScenarioScales(config_files, scenario_data, test_id)
	configs = []
	for config_file in config_files
		config = DataImporter.load_input_data(config_file)
		for (gName, gConfig) in config[:variableGenerators]
			if gName == "Solar"
				gConfig["capacity"] = gConfig["capacity"] * scenario_data["Solar"]
			end
			if gName == "Wind"
				gConfig["capacity"] = gConfig["capacity"] * scenario_data["Wind"]
			end
		end
		config[:batteryStorage]["energyCapacity"] =  config[:batteryStorage]["energyCapacity"] * scenario_data["BatteryStorage"]
		config[:batteryStorage]["powerCapacity"] =  config[:batteryStorage]["powerCapacity"] * scenario_data["BatteryStorage"]
		
		for (dName, dConfig) in config[:demandSegments]
			if dName == "Flex"
				dConfig["profile"] .*= scenario_data["FlexDemand"]
			end
			if dName == "Base_D"
				dConfig["profile"] .*= scenario_data["BaseDemand"]
			end
		end

		push!(configs, config)
	end

	return ClearMarket.ClearTogether(configs, test_id)


end

=#

end;
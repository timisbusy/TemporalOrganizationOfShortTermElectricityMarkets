module ClearMarket

using JuMP, XLSX, Dates, MathOptInterface, DataFrames

include("../helpers.jl")
using .Helpers.HelperModelResults

include("../data_importer.jl")

include("../models/flexible_model.jl")
include("../models/explicit_adjustment_model.jl")
include("../models/laura_convergence_model.jl")
include("../models/laura_minimum_match_model.jl")
include("../models/simple_model.jl")
include("../models/latest_model.jl")
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
include("../plots/market_results/plot_imbalance_outcomes.jl")
include("../plots/market_results/plot_retrading_impacts.jl")
include("../plots/market_results/plot_price_dispersion_by_mtu.jl")
include("../plots/market_results/plot_emissions.jl")

include("../helpers/helper_input_data.jl")
include("./market_sequence.jl")

include("../output_data/market_data_storage.jl")
include("../output_data/interpretations.jl")


USE_LATEST_MODEL = true
USE_EXPLICIT_ADJUSTMENT_MODEL = false
USE_LAURA_CONVERGENCE_MODEL = false
USE_LAURA_MINIMUM_MATCH_MODEL = false

FAST_MODE = false


function GetModel(config)
	if haskey(config, :optimizationModelConfig)
		return config[:optimizationModelConfig]["model"] == "latest" ? LatestMarketModel : ExplicitAdjustmentMarketModel # todo: make this more complete
	end
	return USE_LATEST_MODEL ? LatestMarketModel : USE_EXPLICIT_ADJUSTMENT_MODEL ? ExplicitAdjustmentMarketModel : USE_LAURA_CONVERGENCE_MODEL ? LauraConvergenceMarketModel : USE_LAURA_MINIMUM_MATCH_MODEL ? LauraMinimumMatchModel : SimpleModel
end


function ClearSimple(config_file, test_id)

	config = DataImporter.load_input_data(config_file)
	longest_market_window = max.([m[:optimizationWindow] + m[:lookAheadDistance] for m in config[:marketSequence]])[1]
	last_mtu_simulation = config[:clearForDays]*config[:timePeriodsPerDay] - longest_market_window
	last_mtu_full = config[:clearForDays]*config[:timePeriodsPerDay]
	time_period_range = range(0,last_mtu_simulation) # go from time_period 0 to the last mtp for which we have a full data set
    full_time_period_range = range(0,last_mtu_full) # go from time_period 0 to the last mtp - this is for getting forecast data, for example
    
    marketSequence = MarketSequence.GenerateMarketSequence(config[:marketSequence], time_period_range)
	marketresult = MarketDataStorage.MakeMarketResultContainer() # Vector{MarketDataStorage.MarketResult}()
	initialization = Dict(
	    	:SOC => config[:batteryStorage]["initialSOC"]*config[:batteryStorage]["energyCapacity"],
	    	:Q_gen => Dict{String,Float64}( (g, float(gConfig["initialQuantity"])) for (g, gConfig) in config[:dispatchableGenerators])
	    )
    
    # default path if it's not defined in the config
    if !haskey(config,:wind_noise_scenario_path)
    	config[:wind_noise_scenario_path] =  "input_data/laura/wind_forecast_error_shared_final_20260502.csv"
    end

    config[:wind_forecast_errors] = HelperInputData.load_or_create_wind_forecast_error_scenario!(config, config[:noiseLevel], length(time_period_range), longest_market_window) # this comes from market_clearing_rolling.jl in LLD's code


	variableGeneratorProfiles = Dict{String,DataFrame}()

    addTimeseriesProfiles!(variableGeneratorProfiles, config, test_id)

    mePlotDone = false

    # for each market in marketSequences note the nesting here so a single time period could hold more than one market (but really probably won't in most cases) - case where it would - could be when holding a market 2 days ahead, for example

	for t in time_period_range
		if t < config[:skipEarlyAuctions]
			println("skipping at $t < $(config[:skipEarlyAuctions])")
			continue
		end
		marketsAtTime = MarketSequence.GetMarketsForMTU(marketSequence, t)
		for market in marketsAtTime
			println("$(market[:name]) market at time: $t looking ahead $(market[:lookAheadDistance]) with optimization window length $(market[:optimizationWindow])")
			modelModule = GetModel(config) # USE_LAURA_MINIMUM_MATCH_MODEL ? LauraMinimumMatchModel : USE_LAURA_CONVERGENCE_MODEL ? LauraConvergenceMarketModel : USE_EXPLICIT_ADJUSTMENT_MODEL ? ExplicitAdjustmentMarketModel : FlexibleMarketModel
			m = modelModule.build(t, marketresult, initialization, config, market)
			optimize!(m)
			println(termination_status(m))
			MarketDataStorage.AddMarketResult!(marketresult, m, t, market[:name])

    		XLSX.writetable("results/$(test_id)/RAW/decisionvariables_$(config[:name])_$(t).xlsx", "data" => marketresult.Results[length(marketresult.Results)].DecisionVariables, "interpretation" => Interpretations.DecisionVariablesInterpretation)
		
		    XLSX.writetable("results/$(test_id)/RAW/transactions_$(config[:name])_$(t).xlsx", "data" => marketresult.Results[length(marketresult.Results)].Transactions, "interpretation" => Interpretations.TransactionsInterpretation)
		
    		if mePlotDone == false
    			mePlotDone = true
    			PlotMarketEquilibriumForWindow.plot(marketresult, t+market[:lookAheadDistance]:t+market[:lookAheadDistance]+market[:optimizationWindow] - 1)
    		end
		end


	end

	test_range = range(config[:timePeriodsPerDay]*config[:samplePeriodExcludeSpinUp],config[:timePeriodsPerDay]*(config[:clearForDays] - config[:samplePeriodExcludeEnd]) - 1)
	println(test_range.start, test_range.stop)

	PlotBaselineOutcomes.plot(marketresult, config, test_range, test_id)
	PlotGenerationStack.plot(marketresult, config, test_range, test_id)

	return marketresult
end


function addTimeseriesProfiles!(variableGeneratorProfiles, config, test_id)
    for (gName, gData) in config[:variableGenerators]
    	if haskey(gData,"profile_file") && haskey(gData,"profile_type") 
	    	gData["profile"] = HelperInputData.GetProfileFromFile(gData["profile_file"], gData["profile_type"], config[:startDate]:config[:endDate], config[:timePeriodsPerDay], gData["conversionFactor"], gData["capacity"])
	    	XLSX.writetable("results/$(test_id)/profile_data_$(gName).xlsx", "data" => gData["profile"])
        	variableGeneratorProfiles[gName] = gData["profile"]
	    elseif haskey(gData,"profile_files") && haskey(gData,"profile_type")
	    	gData["profile"] = HelperInputData.GetProfileFromFiles(gData["profile_files"], gData["profile_type"], config[:startDate]:config[:endDate], config[:timePeriodsPerDay], gData["conversionFactor"], gData["capacity"])
	    	XLSX.writetable("results/$(test_id)/profile_data_$(gName).xlsx", "data" => gData["profile"])
	    	variableGeneratorProfiles[gName] = gData["profile"]
	    else
	    	throw("generator profile for $gName is incomplete. it should include both profile_file and profile_type")
	    end
    end


    for (dName, dData) in config[:demandSegments]
    	if haskey(dData,"profile_file") && haskey(dData,"profile_type") 
	    	input_profile = HelperInputData.GetProfileFromFile(dData["profile_file"], dData["profile_type"], config[:startDate]:config[:endDate], config[:timePeriodsPerDay], dData["conversionFactor"], 0.0) # note demand does not have a capacity number
	    	dData["profile"] = input_profile
	    	XLSX.writetable("results/$(test_id)/profile_data_$(dName).xlsx", "data" => dData["profile"])
	    elseif haskey(dData,"quantity_constant")
	    	dData["profile"] = DataFrame(mtu=full_time_period_range, Value=[dData["quantity_constant"] for t in full_time_period_range])
	    else
	    	throw("demand profile for $dName is incomplete. it should include both profile_file and profile_type keys or a quantity_constant key")
	    end
    end
end

function ClearMarketComparisonForConfig(config, test_id)
	allWindows = ([m[:optimizationWindow] + m[:lookAheadDistance] for (n, ms) in config[:marketSequences] for m in ms])
	println(allWindows)
	longest_market_window = max.(allWindows)[1]
	last_mtu_full = config[:clearForDays]*config[:timePeriodsPerDay]
	last_mtu_simulation = config[:clearForDays]*config[:timePeriodsPerDay] - longest_market_window
	time_period_range = range(0,last_mtu_simulation) # go from time_period 0 to the last mtp for which we have a full data set
    full_time_period_range = range(0,last_mtu_full) # go from time_period 0 to the last mtp - this is for getting forecast data, for example
    
    marketSequences = Dict{String,Any}()
    marketResults = Dict{String,MarketDataStorage.MarketResultContainer}()

    for (market_name, market_config) in config[:marketSequences]
	    marketSequences[market_name] = MarketSequence.GenerateMarketSequence(config[:marketSequences][market_name], time_period_range)
		marketResults[market_name] = MarketDataStorage.MakeMarketResultContainer() 
    end

    initialization = Dict(
    	:SOC => config[:batteryStorage]["initialSOC"]*config[:batteryStorage]["energyCapacity"],
    	:Q_gen => Dict{String,Float64}( (g, float(gConfig["initialQuantity"])) for (g, gConfig) in config[:dispatchableGenerators])
    )

    # default path if it's not defined in the config
    if !haskey(config,:wind_noise_scenario_path)
    	config[:wind_noise_scenario_path] =  "input_data/laura/wind_forecast_error_shared_final_20260502.csv"
    end

    config[:wind_forecast_errors] = HelperInputData.load_or_create_wind_forecast_error_scenario!(config, config[:noiseLevel], length(time_period_range), longest_market_window) # this comes from market_clearing_rolling.jl in LLD's code


	variableGeneratorProfiles = Dict{String,DataFrame}()

    addTimeseriesProfiles!(variableGeneratorProfiles, config, test_id)

    mePlotDone = true # switching this off for now

    # for each market in marketSequences note the nesting here so a single time period could hold more than one market (but really probably won't in most cases) - case where it would - could be when holding a market 2 days ahead, for example

	for t in time_period_range
		if t < config[:skipEarlyAuctions]
			println("skipping at $t < $(config[:skipEarlyAuctions])")
			continue
		end
		for (marketName, marketSequence) in marketSequences
			marketsAtTime = MarketSequence.GetMarketsForMTU(marketSequence, t)
			for market in marketsAtTime
				println("$(market[:name]) market at time: $t looking ahead $(market[:lookAheadDistance]) with optimization window length $(market[:optimizationWindow])")
				modelModule = GetModel(config) 
				m = modelModule.build(t, marketResults[marketName], initialization, config, market)
				optimize!(m)
				println(termination_status(m))
				ALLOW_NON_OPTIMAL = true
				if termination_status(m) !== MathOptInterface.OPTIMAL
					if !ALLOW_NON_OPTIMAL
						throw("non optimal solution: $(termination_status(m))")
					end
					println("non optimal solution: $(termination_status(m))")
				end
				MarketDataStorage.AddMarketResult!(marketResults[marketName], m, t, market[:name])

				if !FAST_MODE
		    		XLSX.writetable("results/$(test_id)/RAW/decisionvariables_$(marketName)_$(t).xlsx", "data" => marketResults[marketName].Results[length(marketResults[marketName].Results)].DecisionVariables, "interpretation" => Interpretations.DecisionVariablesInterpretation)
				
				    XLSX.writetable("results/$(test_id)/RAW/transactions_$(marketName)_$(t).xlsx", "data" => marketResults[marketName].Results[length(marketResults[marketName].Results)].Transactions, "interpretation" => Interpretations.TransactionsInterpretation)
				end
	    		if mePlotDone == false
	    			mePlotDone = true
	    			PlotMarketEquilibriumForWindow.plot(marketResults[marketName], t+market[:lookAheadDistance]:t+market[:lookAheadDistance]+market[:optimizationWindow] - 1)
	    		end
			end
		end

	end

	test_range = range(config[:timePeriodsPerDay]*config[:samplePeriodExcludeSpinUp],config[:timePeriodsPerDay]*(config[:clearForDays] - config[:samplePeriodExcludeEnd]) - 1)
	# short_test_range = range(config[:timePeriodsPerDay]*3,config[:timePeriodsPerDay]*5 - 1)
	zoom_19_21 = range(config[:timePeriodsPerDay]*19,config[:timePeriodsPerDay]*22 - 1)
	println(test_range.start, test_range.stop)
	for (market_name, market_result_container) in marketResults
		MarketDataStorage.WriteStorageAnomalies(market_result_container, market_name, test_id)
		MarketDataStorage.WriteAdjustmentAnomalies(market_result_container, market_name, test_id)
	end
	PlotBaselineOutcomes.plotCompare(marketResults, config, test_range, test_id, FAST_MODE)
	if !FAST_MODE
		PlotPriceDispersionByMTU.plotCompare(marketResults, config, test_range, test_id)
		PlotImbalanceOutcomes.plotCompare(marketResults, config, test_range, test_id, variableGeneratorProfiles,"full")
		PlotImbalanceOutcomes.plotCompare(marketResults, config, zoom_19_21, test_id, variableGeneratorProfiles,"zoom_19_21")
		PlotRetradingImpacts.plotCompare(marketResults, config, test_range, test_id)

		# PlotGenerationStack.plotCompare(marketResults, config, short_test_range, test_id)
		PlotGenerationStack.plotCompare(marketResults, config, test_range, test_id)
		PlotEmissions.plotCompare(marketResults, config, test_range, test_id)
	end
	return marketResults

end

function ClearMarketComparison(config_file, test_id)
	config = DataImporter.load_input_data(config_file)
	return ClearMarketComparisonForConfig(config, test_id)

end

function ClearMarketComparisonWithErrors(config_file, test_id, error_index)
	config = DataImporter.load_input_data(config_file)
	config[:wind_noise_scenario_path] =  "input_data/wind_error_inputs_150p/test_new_error_gen_$(error_index).csv"
	return ClearMarketComparisonForConfig(config, test_id)

end



function ClearMarketComparisonWithRampRate(config_file, test_id, ramp_rate)
	config = DataImporter.load_input_data(config_file)

	for (gName, gData) in config[:dispatchableGenerators]
		gData["rampRate"] = ramp_rate
		config[:dispatchableGenerators][gName] = gData
	end

	return ClearMarketComparisonForConfig(config, test_id)
end
#=

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
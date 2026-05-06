module TestExperiment

using Dates
using Printf

include("../market_clearers/clear_market.jl")


function RunTest()
	VerySimpleExperiment()
	# CompareVRESAndFlexSizes()
	# SimpleRepeatTest()
	# AdaptScenarios()
end


function VerySimpleExperiment()
	test_name = @sprintf "supersimple%d" datetime2unix(now())
	results_dir = "../DATA/$(test_name)"
	mkdir(results_dir)
	println(test_name)
	result = ClearMarket.ClearSimple("MPLAMarketClearingLib/src/configs/simple_test_config.yaml",test_name)
	println(result)
end

function RunSweepRampRatesTest(config_file, start_sweep, end_sweep, step_size)
	sweep_range = range(start_sweep, end_sweep, step=step_size)
	println(sweep_range)
	for ramp_rate in sweep_range
		test_name = @sprintf "%dcompare_ramps_%.2d" datetime2unix(now()) ramp_rate
		results_dir = "../DATA/$(test_name)"
		mkdir(results_dir)
		println(test_name)
		result = ClearMarket.ClearMarketComparisonWithRampRate(config_file,test_name, ramp_rate)
	end
end



#=
# See https://publications.tno.nl/publication/34639435/TzUN1t/TNO-2022-P10162.pdf

function AdaptScenarios()
	scenarios = Dict{String,Dict{String,Any}}(
		"Base" => Dict{String,Any}(
			"Solar" => 1.0,
			"Wind" => 1.0,
			"BaseDemand" => 1.0,
			"FlexDemand" => 1.0,
			"BatteryStorage" => 1.0,
		),
		"Adapt2030" => Dict{String,Any}(
			"Solar" => 1.20,
			"Wind" => 1.75,
			"BaseDemand" => 1.38,
			"FlexDemand" => 2.50,
			"BatteryStorage" => 467.0,
		),
		"Adapt2050" => Dict{String,Any}(
			"Solar" => 4.32,
			"Wind" => 4.33,
			"BaseDemand" => 1.61,
			"FlexDemand" => 100.0,
			"BatteryStorage" => 5740.0,
		),
	)

	println(scenarios)

	folder_name = @sprintf "adapt_test/%d" datetime2unix(now())
	mkdir("../DATA/$(folder_name)")

	all_results = Dict{String,Any}()

	for (scenarioName, scenarioScales) in scenarios
		test_name = scenarioName
		println(test_name)
		mkdir("../DATA/$(folder_name)/$(test_name)")
		(resultsets, variableGenRealized, configMap) = ClearMarket.ClearComparisonWithScenarioScales(["MPLAMarketClearingLib/src/configs/fixed_horizon_status_quo.yaml","MPLAMarketClearingLib/src/configs/rolling_config_15_minutes.yaml"], scenarioScales, "$(folder_name)/$(test_name)")
		
		test_results = Dict{String,Any}("scenarioName" => scenarioName, "scenarioScales" => scenarioScales, "resultsets" => resultsets, "variableGenRealized" => variableGenRealized, "configMap" => configMap)
		all_results[test_name] = test_results
	end

	overall_results_dir = "../DATA/$(folder_name)/overall"
	mkdir(overall_results_dir)
	# merge results
	
	merged_results = Dict{String, Any}( "names" => Vector{String}(), "resultsets" => Dict{String,Any}(), "variableGenRealized" => Dict{String,Any}(), "configMap" => Dict{String,Any}() )

	for (test_name, result) in all_results
		for (strategy_name, resultset) in result["resultsets"]
			combined_name = "$(test_name)_$(strategy_name)"
			push!(merged_results["names"], combined_name)
			merged_results["resultsets"][combined_name] =  resultset
			merged_results["variableGenRealized"][combined_name] = result["variableGenRealized"]
			merged_results["configMap"][combined_name] = result["configMap"][strategy_name]
		end
	end
	first_config = merged_results["configMap"][merged_results["names"][1]]
	# println(first_config)
	PlotComparisonBaselineOutcomes.plot(merged_results["resultsets"], merged_results["configMap"], range(first_config[:timePeriodsPerDay]*1,first_config[:timePeriodsPerDay]*(first_config[:clearForDays] - 1)), overall_results_dir)

end

=#

end;
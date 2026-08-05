module UncertaintyImpacts

using XLSX, DataFrames, Plots

validation_storage_path = "../DATA/uncertainty_impacts_"
results_path_start_50p = "results/stochastic_test_1783774717/stochasticity_robustness_50p_"
results_path_start_100p = "results/stochastic_test_1783682211/stochasticity_robustness_"
results_path_start_150p = "results/stochastic_test_1783836179/stochasticity_robustness_150p_"
results_path_end = "/economic_indicators.xlsx"

RESULTS_PATHS = Dict{String,String}(
	"50p" => results_path_start_50p,
	"100p" => results_path_start_100p,
	"150p" => results_path_start_150p,
)

function PerformValidation(set_id)
	println("starting analysis")

	CollectEconomicIndicators(set_id)
end

result_range = 20260700:20260750

ALL_CASES = ["Fixed", "Rolling"] 

SEWSymbol = Symbol("Socioeconomic Welfare (€)")

function CollectEconomicIndicators(set_id)
	df = DataFrame(ResultId=[], SEWRolling=Float64[], SEWFixed=Float64[], SEWDiff=Float64[])
	for result_id in result_range
		dfr = LoadFile(result_id, set_id)
		println(dfr)
		fixed_sew = dfr[dfr[!, Symbol("Market Configuration")] .== "Fixed",SEWSymbol][1]
		rolling_sew = dfr[dfr[!, Symbol("Market Configuration")] .== "Rolling",SEWSymbol][1]
		diff = (rolling_sew - fixed_sew) / fixed_sew
		push!(df,[result_id,rolling_sew,fixed_sew,diff])
	end
	println(df)
	XLSX.writetable("$validation_storage_path$set_id.xlsx", "data" => df)
        
end

function LoadFile(result_id, set_id)
	filepath = GenerateFilepath(result_id, set_id)
	# xf = XLSX.readxlsx(filepath)
    
    # println(XLSX.sheetnames(xf))

    df = DataFrame(XLSX.readtable(filepath, "data"))
    return df
end

function GenerateFilepath(result_id, set_id)
	results_path_start = RESULTS_PATHS[set_id]
	return "$results_path_start$result_id$results_path_end"
end


end;
module ValidationRunner

using XLSX, DataFrames, Plots

validation_storage_path = "../DATA/validation.xlsx"

function PerformValidation()
	println("starting validation")

	# DetectDifferences("HighStorageRolling72")
	DetectAllDifferences()
end

# "C:\Users\Atkin005\OneDrive - Universiteit Utrecht\Documents\julia\DATA\1779983733_validate_laura_rolling_36"
TimPathForCase = Dict{String,String}(
	"Rolling36" => "../DATA/1780400995_validate_laura_rolling_36/decisionvariables_validate_laura_rolling_36_",
	"Rolling72" => "../DATA/1780504673_validate_laura_rolling_72/decisionvariables_validate_laura_rolling_72_",
	"Rolling48" => "../DATA/1780401797_validate_laura_rolling_48/decisionvariables_validate_laura_rolling_48_",
	"Fixed36" => "../DATA/1780404769_validate_laura_fixed_36/decisionvariables_validate_laura_fixed_36_",
	"HighStorageRolling36" => "../DATA/1780400275_validate_laura_rolling_high_storage_36/decisionvariables_validate_laura_rolling_high_storage_36_",
	"HighStorageRolling48" => "../DATA/1780398907_validate_laura_rolling_high_storage_48/decisionvariables_validate_laura_rolling_high_storage_48_",
	"HighStorageRolling72" => "../DATA/1780501951_validate_laura_rolling_high_storage_72/decisionvariables_validate_laura_rolling_high_storage_72_",
	"NoStorageLowRamps" => "../DATA/1780482176_validate_laura_rolling_no_storage_low_ramps_36/decisionvariables_validate_laura_rolling_no_storage_low_ramps_36_",
	"LowStorageLowRamps" => "../DATA/1780481630_validate_laura_rolling_low_storage_low_ramps_36/decisionvariables_validate_laura_rolling_low_storage_low_ramps_36_",
)

LauraPathForCase = Dict{String,String}(
	"Rolling36" => "../DATA/_laura_data/decisionvariables_Rolling36h_",
	"Rolling72" => "../DATA/_laura_data/decisionvariables_Rolling72h_",
	"Rolling48" => "../DATA/_laura_data/decisionvariables_Rolling48h_",
	"Fixed36" => "../DATA/_laura_data/decisionvariables_Fixed36h_",
	"HighStorageRolling36" => "../DATA/_laura_data/decisionvariables_High-storageRolling36h_",
	"HighStorageRolling48" => "../DATA/_laura_data/decisionvariables_High-storageRolling48h_",
	"HighStorageRolling72" => "../DATA/_laura_data/decisionvariables_High-storageRolling72h_",
	"NoStorageLowRamps" => "../DATA/_laura_data/decisionvariables_No-storageLowRampRates_",
	"LowStorageLowRamps" => "../DATA/_laura_data/decisionvariables_Low-storageLowRampRates_",
)


ALL_CASES = ["Fixed36", "Rolling36", "Rolling48", "Rolling72", "HighStorageRolling36", "HighStorageRolling48", "HighStorageRolling72", "LowStorageLowRamps", "NoStorageLowRamps"]
SELECT_CASE = ["HighStorageRolling36"]
_72_HR_CASES = ["Rolling72", "HighStorageRolling72"]

function DetectAllDifferences()
	df = DataFrame(Case=[], SEW_NRMSE=Float64[], SEW_Samples=Float64[], PriceNRMSE=Float64[], PriceSamples=Float64[])
	for case in ALL_CASES
		(sew_nrsme, sew_samples, price_nrsme, price_samples) = DetectDifferences(case)
		push!(df,[case, sew_nrsme, sew_samples, price_nrsme, price_samples])
	end
	println(df)
	XLSX.writetable(validation_storage_path, "data" => df)
        
end

function DetectDifferences(case)
	tim_files = []
	laura_files = []
	for mtu_cleared in 12:648
		println("comparing prices cleared in MTU: $mtu_cleared")
		tim_file = LoadFile(case, "tim", mtu_cleared)
		laura_file = LoadFile(case, "laura", mtu_cleared)
		# DetectDifferencesInFiles(mtu_cleared,[laura_file,tim_file])
		push!(tim_files,tim_file)
		push!(laura_files,laura_file)
	end

	(sew_nrsme, sew_samples) = CompareNRMSE([laura_files, tim_files], "SEW", case)
	(price_nrsme, price_samples) = CompareNRMSE([laura_files, tim_files], "price", case)
	return (sew_nrsme, sew_samples, price_nrsme, price_samples)
end

function LoadFile(case, source, mtu_cleared)
	filepath = GenerateFilepath(case, source, mtu_cleared)
	# xf = XLSX.readxlsx(filepath)
    
    # println(XLSX.sheetnames(xf))

    df = DataFrame(XLSX.readtable(filepath, "data"))
    return df
end

function GenerateFilepath(case, source, mtu_cleared)
	if source == "tim"
		return "$(TimPathForCase[case])$mtu_cleared.xlsx"
	elseif source == "laura"
		return "$(LauraPathForCase[case])$mtu_cleared.xlsx"
	else
		throw("unrecognized source: $source")
	end
end

function DetectDifferencesInFiles(mtu_cleared, files)
	println("Differences in $mtu_cleared")
	println("Price Differences: ")
	CompareColumns(files, "price")
	println("Wind Differences: ")
	CompareColumns(files, "Wind")
	println("Base Differences: ")
	CompareColumns(files, "Base")
	println("Storage Charge Differences: ")
	CompareColumns(files, "StorageCharge")
	println("Storage Discharge Differences: ")
	CompareColumns(files, "StorageDischarge")
	println("SEW Difference:")
	CompareSEW(files)
end

function CompareColumns(files, column)
	dfCompared =  .!isapprox.(eachrow(files[1][!,column]), eachrow(files[2][!,column]),atol=1e-3)
	# println(dfCompared)
	i = 0
	for unequal in dfCompared
		i += 1
		unequal && println("$(files[1][i,"mtu"]) : $(files[1][i,column]) != $(files[2][i,column]) = $(files[1][i,column] - files[2][i,column])")
	end
end

function calculateSEW(file)
	sum(eachrow(file[!,"Base_D"]*300) .+ eachrow(file[!,"Flex"]*50) .- eachrow(file[!,"Base"]*30) .- eachrow(file[!,"Shoulder"]*80) .- eachrow(file[!,"Peak"]*150))[1]
end

function CompareSEW(files)
	file1SEW = calculateSEW(files[1])
	file2SEW = calculateSEW(files[2])
	if isapprox(file1SEW,file2SEW,atol=1e-3)
		println("SEW match: $file1SEW")
	else
		println("SEW mismatch: $file1SEW - $file2SEW = $(file1SEW - file2SEW)")
	end
end

function CompareNRMSE(file_sets, metric, case)
	metric != "SEW" && metric != "price" && throw("unrecognized metric: $metric")

	base = file_sets[1]
	compare = file_sets[2]
	base_values = Float64[]
	compare_values = Float64[]
	if metric == "SEW"
		base_values = [calculateSEW(file) for file in base]
		compare_values = [calculateSEW(file) for file in compare]
	elseif metric == "price"
		for file in base
			for price in file[!,"price"]
				push!(base_values, price)
			end
		end
		for file in compare
			for price in file[!,"price"]
				push!(compare_values, price)
			end
		end
	end

	value_range = maximum(base_values) - minimum(base_values)

	if metric == "SEW"
		x = 12:12+length(base_values)-1
		y = [base_values compare_values]
		labels = ["laura" "tim"]
		p = plot(x, y, xlabel="MTU Cleared", ylabel="Objective Value",
	            title="Objective Value by MTU cleared", labels=labels,)

		plot_storage_path = "../DATA/plot_$(metric)_$(case).png"
		display(p)
		savefig(p, plot_storage_path)
	end

	if metric == "price"
		df = DataFrame()
		df[!,"$(case)_laura"] = base_values
		df[!,"$(case)_tim"] = compare_values

		# println(df)
		XLSX.writetable("../DATA/price_compare_$(case).xlsx", "data" => df)

	end


	sumOfSquareErrors =   sum((compare_values[i] - base_values[i]).^2 for i in 1:length(base_values)) 
	nrmse = sqrt(1/length(base_values) * sumOfSquareErrors[1]) / value_range
	println("NRMSE for $metric: $nrmse")
	return (nrmse, length(base_values))
end

end;
module ValidationRunner

using XLSX, DataFrames, Plots, Dates

test_time = datetime2unix(now())

validation_storage_path = "../DATA/validation_$(test_time).xlsx"
adjustment_validation_storage_path = "../DATA/adjustment_validation_$(test_time).xlsx"

function PerformValidation()
	println("starting validation")

	# DetectDifferences("HighStorageRolling72")
	DetectAllDifferences()
end

function PerformAdjustmentValidation()
	println("starting adjustment validation")

	# DetectDifferences("HighStorageRolling72")
	DetectAdjustmentDifferences()
end

TimPathForCase = Dict{String,String}(
	"Rolling36" => "results/1784816968_validate_laura_rolling_36/RAW/decisionvariables_validate_laura_rolling_36_",
	"Rolling72" => "../DATA/1780504673_validate_laura_rolling_72/decisionvariables_validate_laura_rolling_72_",
	"Rolling48" => "../DATA/1780401797_validate_laura_rolling_48/decisionvariables_validate_laura_rolling_48_",
	"Fixed36" => "results/1784818183_validate_laura_fixed_36/RAW/decisionvariables_validate_laura_fixed_36_",
	"HighStorageRolling36" => "../DATA/1780400275_validate_laura_rolling_high_storage_36/decisionvariables_validate_laura_rolling_high_storage_36_",
	"HighStorageRolling48" => "../DATA/1780398907_validate_laura_rolling_high_storage_48/decisionvariables_validate_laura_rolling_high_storage_48_",
	"HighStorageRolling72" => "../DATA/1780501951_validate_laura_rolling_high_storage_72/decisionvariables_validate_laura_rolling_high_storage_72_",
	"NoStorageLowRamps" => "../DATA/1780482176_validate_laura_rolling_no_storage_low_ramps_36/decisionvariables_validate_laura_rolling_no_storage_low_ramps_36_",
	"LowStorageLowRamps" => "../DATA/1780481630_validate_laura_rolling_low_storage_low_ramps_36/decisionvariables_validate_laura_rolling_low_storage_low_ramps_36_",
)

TimPathWithDemandAdjustForCase = Dict{String,String}(
	"Rolling36" => "results/1785149982_validate_laura_rolling_36_w_trans_cache_3/RAW/decisionvariables_validate_laura_rolling_36_",
	"Fixed36" => "results/1785154848_validate_laura_fixed_36_w_trans_cache/RAW/decisionvariables_validate_laura_fixed_36_",
	# "Rolling36" => "results/1784825314_validate_laura_rolling_36/RAW/decisionvariables_validate_laura_rolling_36_",
	# "Fixed36" => "results/1784822439_validate_laura_fixed_36/RAW/decisionvariables_validate_laura_fixed_36_",
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

NoAdjustmentsCasePaths = Dict{String,String}(
	"Rolling" => "results/1783421295_compare_imbalance/RAW/decisionvariables_Rolling_",
	"Fixed" => "results/1783421295_compare_imbalance/RAW/decisionvariables_Fixed_",
)

AdjustmentsCasePaths = Dict{String,String}(
	"Rolling" => "results/1783508682_with_explicit_adjustment_model/RAW/decisionvariables_Rolling_",
	"Fixed" => "results/1783508682_with_explicit_adjustment_model/RAW/decisionvariables_Fixed_",
)

NoDemandAdjustmentsCasePaths = Dict{String,String}(
	"D_Rolling" => "results/1784715332_nl_agents_rolling_w_opt_config/decisionvariables_nl_agents_rolling_"
)

DemandAdjustmentsExPostCasePaths = Dict{String,String}(
	"D_Rolling" => "results/1784718257_nl_agents_rolling_w_opt_config/decisionvariables_nl_agents_rolling_"
)

DemandAdjustmentsCasePaths = Dict{String,String}(
	"D_Rolling" => "results/1784715985_nl_agents_rolling_w_opt_config/decisionvariables_nl_agents_rolling_"
)

AdjAdjCasePaths = Dict{String,String}(
	"D_Rolling" => "results/1784802227_nl_agents_rolling_adj_adj/decisionvariables_nl_agents_rolling_"
)

WithPenaltyCasePaths = Dict{String,String}(
	"Rolling36" => "results/1785335532_compare_lld_match_no_end_soc_cnst_pen/RAW/decisionvariables_Rolling_"
)

ALL_CASES = ["Fixed36", "Rolling36"] # ["D_Rolling"] # ["Fixed", "Rolling"] # ["Fixed36", "Rolling36", "Rolling48", "Rolling72", "HighStorageRolling36", "HighStorageRolling48", "HighStorageRolling72", "LowStorageLowRamps", "NoStorageLowRamps"]
SELECT_CASE = ["HighStorageRolling36"]
_72_HR_CASES = ["Rolling72", "HighStorageRolling72"]

function DetectAdjustmentDifferences()
	df = DataFrame(Case=[],AuctionMTU=[],MTU=[],Agent=[],AdjVal=[],ExPostVal=[],PrevVal=[],Diff=[])
	for case in ALL_CASES
		diffs = DetectAdjustmentDifferencesForCase(case)
		for diff in diffs
			push!(df,[case,diff.AuctionMTU,diff.MTU,diff.Agent,diff.AdjVal,diff.ExPostVal,diff.Diff])
		end
	end
	XLSX.writetable(adjustment_validation_storage_path, "data" => df)
end

mutable struct AdjustmentDifference
	AuctionMTU::Int
	MTU::Int
	Agent::String
	AdjVal::Float64
	ExPostVal::Float64
	PrevVal::Float64
	Diff::Float64
	AdjustmentDifference() = new()
end

function DetectAdjustmentDifferencesForCase(case)
	adjustment_diffs = AdjustmentDifference[]
	for auction_mtu in 12:648
		println("comparing adjustments from MTU: $auction_mtu")
		test_file = LoadFile(case, "adj_adj", auction_mtu)

		adjustment_differences = DetectAdjustmentDifferencesForFile(case, test_file, auction_mtu)
		for diff in adjustment_differences
			push!(adjustment_diffs,diff)
		end
	end

	return adjustment_diffs
end

function DetectAdjustmentDifferencesForFile(case, test_file, auction_mtu)
	adjustment_diffs = AdjustmentDifference[]

	agents = ["1D_HighBid","2D_ModerateBid","3G_Base","4G_Shoulder","5G_Peak","6G_Wind","7G_Solar"]
	
	for agent in agents
		totalDispatch = agent
		prevDispatch = "Q_prev_$agent"
		adj = "$(agent)_adj"
		dfCompared =  .!isapprox.(eachrow(test_file[!,totalDispatch]-test_file[!,prevDispatch]), eachrow(test_file[!,adj]),atol=1e-3)
		println(dfCompared)
		i = 0
		for unequal in dfCompared
			i += 1
			diff = AdjustmentDifference()
			diff.Agent = agent
			diff.AuctionMTU = auction_mtu
			diff.MTU = test_file[i,"MTU"]
			diff.Diff = (test_file[i,totalDispatch]-test_file[i,prevDispatch]) - test_file[!,adj]
			diff.ExPostVal = (test_file[i,totalDispatch]-test_file[i,prevDispatch])
			diff.AdjVal = test_file[!,adj]
			diff.PrevVal = test_file[i,prevDispatch]
			push!(adjustment_diffs,diff)
		end
	end

	return adjustment_diffs
end

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
	test_files = []
	comparison_files = []
	for mtu_cleared in 12:648
		println("comparing prices cleared in MTU: $mtu_cleared")
		try 
			test_file = LoadFile(case, "tim_adj", mtu_cleared)
			comparison_file = LoadFile(case, "laura", mtu_cleared)
			# DetectDifferencesInFiles(mtu_cleared,[laura_file,tim_file])
			push!(test_files,test_file)
			push!(comparison_files,comparison_file)
		catch e
			push!(test_files,missing)
			push!(comparison_files,missing)
			println("no file found for mtu: $mtu_cleared")
		end
	end

	(sew_nrsme, sew_samples) = CompareNRMSE([comparison_files, test_files], "SEW", case)
	(price_nrsme, price_samples) = CompareNRMSE([comparison_files, test_files], "price", case)
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
	elseif source == "tim_adj"
		return "$(TimPathWithDemandAdjustForCase[case])$mtu_cleared.xlsx"
	elseif source == "laura"
		return "$(LauraPathForCase[case])$mtu_cleared.xlsx"
	elseif source == "adjust"
		return "$(AdjustmentsCasePaths[case])$mtu_cleared.xlsx"
	elseif source == "no_adjust"
		return "$(NoAdjustmentsCasePaths[case])$mtu_cleared.xlsx"
	elseif source == "d_adjust"
		return "$(DemandAdjustmentsCasePaths[case])$mtu_cleared.xlsx"
	elseif source == "d_adjust_ex_post"
		return "$(DemandAdjustmentsExPostCasePaths[case])$mtu_cleared.xlsx"
	elseif source == "no_d_adjust"
		return "$(NoDemandAdjustmentsCasePaths[case])$mtu_cleared.xlsx"
	elseif  source == "adj_adj"
		return "$(AdjAdjCasePaths[case])$mtu_cleared.xlsx"
	elseif source == "with_penalty"
		return "$(WithPenaltyCasePaths[case])$mtu_cleared.xlsx"
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
	if ismissing(file)
		return missing
	end
	if hasproperty(file,"1D_HighBid")
		return sum(eachrow(file[!,"1D_HighBid"]*300) .+ eachrow(file[!,"2D_ModerateBid"]*50) .- eachrow(file[!,"3G_Base"]*30) .- eachrow(file[!,"4G_Shoulder"]*80) .- eachrow(file[!,"5G_Peak"]*150))[1]
	else
		return sum(eachrow(file[!,"Base_D"]*300) .+ eachrow(file[!,"Flex"]*50) .- eachrow(file[!,"Base"]*30) .- eachrow(file[!,"Shoulder"]*80) .- eachrow(file[!,"Peak"]*150))[1]
	end
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

	comparison = file_sets[1]
	test = file_sets[2]
	comparison_values = Float64[]
	test_values = Float64[]
	if metric == "SEW"
		comparison_values = [calculateSEW(file) for file in comparison]
		test_values = [calculateSEW(file) for file in test]
	elseif metric == "price"
		for file in comparison
			if ismissing(file)
				continue
			end

			for price in file[!,"price"]
				push!(comparison_values, price)
			end
		end
		for file in test
			if ismissing(file)
				continue
			end
			for price in file[!,"price"]
				push!(test_values, price)
			end
		end
	end
	non_missing_test_values = collect(skipmissing(test_values))
	non_missing_comparison_values = collect(skipmissing(comparison_values))

	value_range = maximum(non_missing_comparison_values) - minimum(non_missing_test_values)

	if metric == "SEW"
		x = 12:12+length(comparison_values)-1
		y = [comparison_values test_values]
		labels = ["comparison" "test"]
		p = plot(x, y, xlabel="MTU Cleared", ylabel="Objective Value",
	            title="Objective Value by MTU cleared", labels=labels,)

		plot_storage_path = "../DATA/plot_$(metric)_$(case)_$(test_time).png"
		display(p)
		savefig(p, plot_storage_path)
	end

	if metric == "price"
		df = DataFrame()
		df[!,"$(case)_comparison"] = comparison_values
		df[!,"$(case)_test"] = test_values

		# println(df)
		XLSX.writetable("../DATA/price_compare_$(case)_$(test_time).xlsx", "data" => df)

	end


	sumOfSquareErrors =   sum((non_missing_test_values[i] - non_missing_comparison_values[i]).^2 for i in 1:length(non_missing_comparison_values)) 
	nrmse = sqrt(1/length(non_missing_comparison_values) * sumOfSquareErrors[1]) / value_range
	println("NRMSE for $metric: $nrmse")
	return (nrmse, length(non_missing_comparison_values))
end

function EnsureNoChargeDischargePeriods()
	test_files = []
	for mtu_cleared in 12:648
		println("looking for charge/discharge periods cleared in MTU: $mtu_cleared")
		test_file = LoadFile("Rolling36", "with_penalty", mtu_cleared)
		push!(test_files,test_file)
		
	end
	PrintAnyChargeDischargePeriods(test_files)
end

function PrintAnyChargeDischargePeriods(test_files)
	for file in test_files
		file[!,:StorageOverlap] = file[!,:StorageCharge] .* file[!,:StorageDischarge]
		overlapTotal = sum(eachrow(file[!,"StorageOverlap"]))[1]
		if overlapTotal != 0
			print(file)
		end
	end
end

function CreateFinalDecisionVariablesForCase(src, case)
	test_files = []
	for mtu_cleared in 12:672
		println("load file for MTU: $mtu_cleared")
		test_file = LoadFile(case, src, mtu_cleared)
		push!(test_files,test_file)
	end

	finalDispatchDecisions = DataFrame()

	for dds in test_files
		finalDispatchDecisions = vcat(finalDispatchDecisions, dds)
	end

	finalDispatchDecisions = unique!(finalDispatchDecisions, "mtu"; keep=:last)

	XLSX.writetable("../DATA/_laura_data/decisionvariables_$(src)_$(case).xlsx", "data" => finalDispatchDecisions)

end

end;
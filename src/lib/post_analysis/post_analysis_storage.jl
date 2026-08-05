module PostAnalysisStorage

using XLSX, DataFrames, Plots, Statistics, Latexify



results_path_base = "results/1785426007_compare_lld_match_no_end_soc_no_cnst_pen"

analysis_dir_path = "$results_path_base/additional_analysis/post_analysis_storage"

dispatch_decision_paths = Dict{String,String}(
	"Fixed Horizon" => "$results_path_base/RAW/final_dispatch_decisions_Fixed.xlsx",
	"Rolling Horizon" => "$results_path_base/RAW/final_dispatch_decisions_Rolling.xlsx",
)

results_path_base_LD = "../DATA/_laura_data"


dispatch_decision_paths_LD = Dict{String,String}(
	"Fixed Horizon" => "$results_path_base_LD/decisionvariables_laura_Fixed36.xlsx",
	"Rolling Horizon" => "$results_path_base_LD/decisionvariables_laura_Rolling36.xlsx",
)

function CleanDirectory(path)
	mkpath(path)
end


function PerformAnalysis()
	println("starting analysis")
	CleanDirectory(analysis_dir_path)
	dds = Dict{String,DataFrame}()

	LD = false

	start_day = LD ? 1 : 2
	end_day = LD ? 28 : 29

	for(case, path) in (LD ? dispatch_decision_paths_LD : dispatch_decision_paths)
		dd = LoadFile(path)
		dd[!,Symbol("Hour")] = dd[!,Symbol("mtu")] .% 24
		dd[!,Symbol("Day")] = (dd[!,Symbol("mtu")] .- dd[!,Symbol("Hour")]) ./ 24
		dds[case] = dd[start_day .<= dd[!,Symbol("Day")] .<= end_day,:]
		println("$case rows: $(nrow(dds[case]))")
	end
	# println(dvs)

	metrics = ["Charge [MWh/day]","Discharge [MWh/day]","Net discharge [MWh/day]","Total throughput [MWh/day]"]

	storage_analysis_df = DataFrame(Metric=metrics)
	for (case, dd) in dds
		(discharge_total,charge_total,discharge_per_day,charge_per_day) = PrintStorageDetails(case, dd)
		storage_analysis_df[!,Symbol(case)] = [charge_per_day,discharge_per_day,charge_per_day-discharge_per_day,charge_per_day+discharge_per_day]
	end

	storage_analysis_df[!, Symbol("Change")] = storage_analysis_df[!, Symbol("Rolling Horizon")] .- storage_analysis_df[!, Symbol("Fixed Horizon")]
	storage_analysis_df[!, Symbol("% Change")] = storage_analysis_df[!, Symbol("Change")] ./ storage_analysis_df[!, Symbol("Fixed Horizon")]

	println(storage_analysis_df)

	XLSX.writetable("$analysis_dir_path/storage_details.xlsx", "data" => storage_analysis_df; overwrite=true)

	storage_analysis_tex = latexify(storage_analysis_df; env = :table, booktabs = true, snakecase=true, latex=false,fmt="%'\''d\n")
	write("$analysis_dir_path/storage_details.tex",storage_analysis_tex)

	NetDischargePerHour(dds)
end

function PrintStorageDetails(case, dd)
	discharge_total = combine(dd, :StorageDischarge => sum)[1,1]
	charge_total = combine(dd, :StorageCharge => sum)[1,1]
	days = nrow(dd) / 24
	discharge_per_day = discharge_total/days
	charge_per_day = charge_total/days
	println("Storage info for $case over $days days")
	println("discharge_total: $discharge_total")
	println("charge_total: $charge_total")
	println("discharge_per_day: $discharge_per_day")
	println("charge_per_day: $charge_per_day")
	return discharge_total,charge_total,discharge_per_day,charge_per_day
end

function NetDischargePerHour(dds)
	xPlotIndicator = 0:23
    pNetDischarge = Plots.plot(xlabel="Hour of Day", ylabel="Mean Net Discharge (MWh)",
                            title="Mean Net Discharge (MWh)")

    pNetDischargeStdDev = Plots.plot(xlabel="Hour of Day", ylabel="Mean Net Discharge St Dev (MWh)",
                            title="Std Dev Net Discharge (MWh)")

	for case in ["Fixed Horizon","Rolling Horizon"]
		dd = dds[case]
		hourly_dd = groupby(dd,:Hour)
		# show(hourly_dd, allgroups=true)
		hourly_discharge = combine(hourly_dd, :StorageDischarge => sum)
		hourly_charge = combine(hourly_dd, :StorageCharge => sum)
		hourly_net_discharge = combine(hourly_dd, [:StorageCharge, :StorageDischarge] => ( (sc,sd) -> mean(sd .- sc) ) => :MeanNetDischarge)
		hourly_net_discharge_st_dev = combine(hourly_dd, [:StorageCharge, :StorageDischarge] => ( (sc,sd) -> std(sd .- sc) ) => :StdDevNetDischarge)
		println(case)
		# println(hourly_discharge)
		# println(hourly_charge)
		println(hourly_net_discharge)
		XLSX.writetable("$analysis_dir_path/hourly_net_discharge_$case.xlsx", "mean" => hourly_net_discharge, "st_dev" => hourly_net_discharge_st_dev; overwrite=true)

		Plots.plot!(pNetDischarge, xPlotIndicator, hourly_net_discharge[!, :MeanNetDischarge], label=case)
    	Plots.plot!(pNetDischargeStdDev, xPlotIndicator, hourly_net_discharge_st_dev[!, :StdDevNetDischarge], label=case)
    
	end

    display(pNetDischarge)
    display(pNetDischargeStdDev)

	savefig(pNetDischarge, "$analysis_dir_path/net_discharge.png")
	savefig(pNetDischargeStdDev, "$analysis_dir_path/net_discharge_st_dev.png")
end

function LoadFile(filepath)
	# filepath = GenerateFilepath(result_id, set_id)

    df = DataFrame(XLSX.readtable(filepath, "data"))
    return df
end



end;
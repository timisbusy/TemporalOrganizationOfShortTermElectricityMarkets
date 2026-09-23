module PostAnalysisStorage

using XLSX, DataFrames, Plots, Statistics, Latexify

include("../post_analysis_common.jl")

function PerformAnalysis(case_paths; cases=PostAnalysisCommon.CASES, output_base=PostAnalysisCommon.NewAnalysisOutputDir(case_paths))

	analysis_dir_path = "$output_base/post_analysis_storage"

	dispatch_decision_paths = Dict(case => joinpath(case_paths[case], "final_dispatch_decisions.xlsx") for case in cases)

	println("starting analysis")
	PostAnalysisCommon.CleanDirectory(analysis_dir_path)
	dds = Dict{String,DataFrame}()

	start_day = 2
	end_day = 29

	for(case, path) in dispatch_decision_paths
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
		storage_analysis_df[!,Symbol(case)] = [charge_per_day,discharge_per_day,discharge_per_day-charge_per_day,charge_per_day+discharge_per_day]
	end

	# one "{case} Change"/"{case} % Change" pair per non-baseline case, measured against cases[1]
	# (matches this suite's existing Rolling-relative-to-Fixed convention, generalized to N cases).
	baseline = cases[1]
	for case in cases[2:end]
		storage_analysis_df[!, Symbol("$case Change")] = storage_analysis_df[!, Symbol(case)] .- storage_analysis_df[!, Symbol(baseline)]
		storage_analysis_df[!, Symbol("$case % Change")] = PostAnalysisCommon.PercentDiffString.(storage_analysis_df[!, Symbol(case)], storage_analysis_df[!, Symbol(baseline)])
	end

	println(storage_analysis_df)

	XLSX.writetable("$analysis_dir_path/storage_details.xlsx", "data" => storage_analysis_df; overwrite=true)

	storage_analysis_tex = latexify(PostAnalysisCommon.EscapeForLatex(storage_analysis_df); env = :table, booktabs = true, snakecase=true, latex=false,fmt="%'\''d\n")
	write("$analysis_dir_path/storage_details.tex",storage_analysis_tex)

	NetDischargePerHour(dds, cases, analysis_dir_path)
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

function NetDischargePerHour(dds, cases, analysis_dir_path)
	xPlotIndicator = 0:23
    pNetDischarge = Plots.plot(xlabel="Hour of Day", ylabel="Mean Net Discharge (MWh)",
                            title="Mean Net Discharge (MWh)")

    pNetDischargeStdDev = Plots.plot(xlabel="Hour of Day", ylabel="Mean Net Discharge St Dev (MWh)",
                            title="Std Dev Net Discharge (MWh)")

	for case in cases
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

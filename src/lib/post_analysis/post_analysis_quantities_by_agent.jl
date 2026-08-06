module PostAnalysisQuantitiesByAgent

using XLSX, DataFrames, Plots, Statistics, Latexify, Printf


function CleanDirectory(path)
	mkpath(path)
end

short_names = ["Fixed", "Rolling", "FixedSQ"]
long_names = ["Fixed Horizon", "Rolling Horizon", "Auction Only"]

agent_names = ["1D_HighBid","2D_ModerateBid","3G_Base","4G_Shoulder","5G_Peak","6G_Wind","7G_Solar"]

quantitySymbol = Symbol("Quantity (MWh)")
surplusSymbol = Symbol("Surplus (€)")

function PerformAnalysis(results_path_base_in)

	if results_path_base_in != ""
		results_path_base = results_path_base_in

		analysis_dir_path = "$results_path_base/additional_analysis/post_analysis_quantities_by_agent"

		agent_ind_data_path = "$results_path_base/agent_indicators.xlsx"
	end

	println("starting analysis")
	CleanDirectory(analysis_dir_path)
	
	indicators = LoadFile(agent_ind_data_path)
	println(indicators)

	AnalyzeQuantities(indicators, analysis_dir_path)
	AnalyzeSurpluses(indicators, analysis_dir_path)

end

function AnalyzeQuantities(indicators, analysis_dir_path)

	final_agent_ind_df = DataFrame(Agent=String[],Fixed=Float64[],Rolling=Float64[],RollingDiff=Float64[],FixedSQ=Float64[],FixedSQDiff=Float64[])
	# DataFrame([Float64[] for i in 1:length(short_names)], short_names)
	println(final_agent_ind_df)
	for (j,agent) in enumerate(agent_names)
		agent_row = Vector{Any}([agent])
		for (i,mktConfig) in enumerate(short_names)
			println(mktConfig, agent)
			quantity = indicators[(indicators[!,"Market Configuration"] .== mktConfig .&& indicators.Agent .== agent), quantitySymbol][1]
			push!(agent_row,quantity)
			if mktConfig != "Fixed"
				quantity_base = indicators[(indicators[!,"Market Configuration"] .== "Fixed" .&& indicators.Agent .== agent), quantitySymbol][1]
				quantity_diff = (quantity-quantity_base)/quantity_base
				push!(agent_row, quantity_diff)
			end
		end
		println(agent, agent_row)
		push!(final_agent_ind_df,agent_row)
	end

	println(final_agent_ind_df)


	percent_format = Ref(Printf.Format("%0.3f%%"))

	renamed_agent_ind_df = DataFrame()
	
	renamed_agent_ind_df[!,"Agent"] = final_agent_ind_df[!, "Agent"]

	renamed_agent_ind_df[!,"Fixed Horizon Quantity (GWh)"] = final_agent_ind_df[!, "Fixed"] ./ 1000

	renamed_agent_ind_df[!,"Rolling Horizon Quantity (GWh)"] = final_agent_ind_df[!, "Rolling"] ./ 1000

	renamed_agent_ind_df[!,"Rolling Horizon % Diff"] = Printf.format.(percent_format,100*(final_agent_ind_df[!,Symbol("Rolling")] .- final_agent_ind_df[!,Symbol("Fixed")]) ./ final_agent_ind_df[!,Symbol("Fixed")])

	renamed_agent_ind_df[!,"Auction Only Quantity (GWh)"] = final_agent_ind_df[!, "FixedSQ"] ./ 1000

	renamed_agent_ind_df[!,"Auction Only % Diff"] = Printf.format.(percent_format,100*(final_agent_ind_df[!,Symbol("FixedSQ")] .- final_agent_ind_df[!,Symbol("Fixed")]) ./ final_agent_ind_df[!,Symbol("Fixed")])

	println(renamed_agent_ind_df)

	XLSX.writetable("$analysis_dir_path/agent_quantities_details.xlsx", "data" => renamed_agent_ind_df; overwrite=true)

	agent_quantities_analysis_tex = latexify(renamed_agent_ind_df; env = :table, booktabs = true, snakecase=true, latex=false,fmt="%'\''d\n")
	write("$analysis_dir_path/agent_quantities.tex",agent_quantities_analysis_tex)
end

function AnalyzeSurpluses(indicators, analysis_dir_path)
	final_agent_ind_df = DataFrame(Agent=String[],Fixed=Float64[],Rolling=Float64[],RollingDiff=Float64[],FixedSQ=Float64[],FixedSQDiff=Float64[])
	# DataFrame([Float64[] for i in 1:length(short_names)], short_names)
	println(final_agent_ind_df)
	for (j,agent) in enumerate(agent_names)
		agent_row = Vector{Any}([agent])
		for (i,mktConfig) in enumerate(short_names)
			println(mktConfig, agent)
			surplus = indicators[(indicators[!,"Market Configuration"] .== mktConfig .&& indicators.Agent .== agent), surplusSymbol][1]
			push!(agent_row,surplus)
			if mktConfig != "Fixed"
				surplus_base = indicators[(indicators[!,"Market Configuration"] .== "Fixed" .&& indicators.Agent .== agent), surplusSymbol][1]
				surplus_diff = (surplus-surplus_base)/surplus_base
				push!(agent_row, surplus_diff)
			end
		end
		println(agent, agent_row)
		push!(final_agent_ind_df,agent_row)
	end

	println(final_agent_ind_df)


	percent_format = Ref(Printf.Format("%0.3f%%"))

	renamed_agent_ind_df = DataFrame()
	
	renamed_agent_ind_df[!,"Agent"] = final_agent_ind_df[!, "Agent"]

	renamed_agent_ind_df[!,"Fixed Horizon Surplus (M€)"] = final_agent_ind_df[!, "Fixed"] ./ 1e6

	renamed_agent_ind_df[!,"Rolling Horizon Surplus (M€)"] = final_agent_ind_df[!, "Rolling"] ./ 1e6

	renamed_agent_ind_df[!,"Rolling Horizon % Diff"] = Printf.format.(percent_format,100*(final_agent_ind_df[!,Symbol("Rolling")] .- final_agent_ind_df[!,Symbol("Fixed")]) ./ final_agent_ind_df[!,Symbol("Fixed")])

	renamed_agent_ind_df[!,"Auction Only Surplus (M€)"] = final_agent_ind_df[!, "FixedSQ"] ./ 1e6

	renamed_agent_ind_df[!,"Auction Only % Diff"] = Printf.format.(percent_format,100*(final_agent_ind_df[!,Symbol("FixedSQ")] .- final_agent_ind_df[!,Symbol("Fixed")]) ./ final_agent_ind_df[!,Symbol("Fixed")])

	println(renamed_agent_ind_df)

	XLSX.writetable("$analysis_dir_path/agent_surplus_details.xlsx", "data" => renamed_agent_ind_df; overwrite=true)

	agent_surplus_analysis_tex = latexify(renamed_agent_ind_df; env = :table, booktabs = true, snakecase=true, latex=false,fmt="%'\''0.3f\n")
	write("$analysis_dir_path/agent_surpluses.tex",agent_surplus_analysis_tex)
end


function LoadFile(filepath)

    df = DataFrame(XLSX.readtable(filepath, "data"))
    return df
end



end;
module PostAnalysisSEW

using XLSX, DataFrames, Plots, Statistics, Latexify, Printf



results_path_base = "results/1785426007_compare_lld_match_no_end_soc_no_cnst_pen"

analysis_dir_path = "$results_path_base/additional_analysis/post_analysis_SEW"

sew_data_path = "$results_path_base/economic_indicators.xlsx"

function CleanDirectory(path)
	mkpath(path)
end

short_names = ["Fixed", "Rolling", "FixedSQ"]
long_names = ["Fixed Horizon", "Rolling Horizon", "Auction Only"]


function PerformAnalysis()
	println("starting analysis")
	CleanDirectory(analysis_dir_path)
	
	indicators = LoadFile(sew_data_path)
	println(indicators)
	indicators_df = permutedims(indicators,Symbol("Market Configuration"))
	indicators_df = indicators_df[!,Not(:RollingTA)]
	indicators_df = rename!(indicators_df, short_names .=> long_names)

	println(indicators_df)

	percent_format = Ref(Printf.Format("%0.3f%%"))

	final_indicators_df = DataFrame()
	final_indicators_df[!,Symbol("Indicator")] = indicators_df[!,Symbol("Market Configuration")]
	final_indicators_df[!,Symbol("Fixed Horizon")] = indicators_df[!,Symbol("Fixed Horizon")]
	final_indicators_df[!,Symbol("Rolling Horizon")] = indicators_df[!,Symbol("Rolling Horizon")]
	final_indicators_df[!,Symbol("Rolling Horizon % Difference")] = Printf.format.(percent_format,100*(indicators_df[!,Symbol("Rolling Horizon")] .- indicators_df[!,Symbol("Fixed Horizon")]) ./ indicators_df[!,Symbol("Fixed Horizon")])

	final_indicators_df[!,Symbol("Auction Only")] = indicators_df[!,Symbol("Auction Only")]
	final_indicators_df[!,Symbol("Auction Only % Difference")] = Printf.format.(percent_format,100*(indicators_df[!,Symbol("Auction Only")] .- indicators_df[!,Symbol("Fixed Horizon")]) ./ indicators_df[!,Symbol("Fixed Horizon")])

	println(final_indicators_df)

	XLSX.writetable("$analysis_dir_path/sew_details.xlsx", "data" => final_indicators_df; overwrite=true)

	sew_analysis_tex = latexify(final_indicators_df; env = :table, booktabs = true, snakecase=true, latex=false,fmt="%'\''d\n")
	write("$analysis_dir_path/sew_details.tex",sew_analysis_tex)

end


function LoadFile(filepath)

    df = DataFrame(XLSX.readtable(filepath, "data"))
    return df
end



end;
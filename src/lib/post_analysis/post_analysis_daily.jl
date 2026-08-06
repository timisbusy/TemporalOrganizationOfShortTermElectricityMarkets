module PostAnalysisDaily

using Plots
using JuMP
using Statistics
using DataFrames
using XLSX
using Distributions
using Latexify

function CleanDirectory(path)
	mkpath(path)
end

short_names = ["Fixed", "Rolling", "FixedSQ"]
long_names = ["Fixed Horizon", "Rolling Horizon", "Auction Only"]

quantitySymbol = Symbol("Quantity (MWh)")


marketConfigurationDisplayNames = Dict{String, String}(
    "Fixed" => "Fixed Horizon", 
    "Rolling" =>  "Rolling Horizon",
    "FixedSQ" => "Auction Only",
)



function PerformAnalysis(results_path_base_in)

    if results_path_base_in != ""
        results_path_base = results_path_base_in

        analysis_dir_path = "$results_path_base/additional_analysis/post_analysis_daily"

        dispatch_decision_paths = Dict{String,String}(
            "Fixed Horizon" => "$results_path_base/RAW/final_dispatch_decisions_Fixed.xlsx",
            "Rolling Horizon" => "$results_path_base/RAW/final_dispatch_decisions_Rolling.xlsx",
            "Auction Only" => "$results_path_base/RAW/final_dispatch_decisions_FixedSQ.xlsx",
        )

        mtu_economic_indicator_paths = Dict{String,String}(
            "Fixed Horizon" => "$results_path_base/mtu_economic_results_Fixed.xlsx",
            "Rolling Horizon" => "$results_path_base/mtu_economic_results_Rolling.xlsx",
            "Auction Only" => "$results_path_base/mtu_economic_results_FixedSQ.xlsx",
        )

    end

	CleanDirectory(analysis_dir_path)

    may_19_interval = 20*24:(21*24 - 1)
    may_20_interval = 21*24:(22*24 - 1)
    may_21_interval = 22*24:(23*24 - 1)

    print_cases = ["Fixed Horizon", "Rolling Horizon","Auction Only"]

	dds = GetDispatchDecisions(print_cases, dispatch_decision_paths)
    mtu_economic_indicators = GetMTUEconomicIndicators(print_cases, mtu_economic_indicator_paths)

	println("MAY 19 RESULTS")

    plotPhysicalIndicator(dds, may_19_interval, Symbol("SOC"), print_cases, "May 19", analysis_dir_path)
    plotPhysicalIndicator(dds, may_19_interval, Symbol("6G_Wind"), print_cases, "May 19", analysis_dir_path)
    plotPhysicalIndicator(dds, may_19_interval, Symbol("2D_ModerateBid"), print_cases, "May 19", analysis_dir_path)
    plotPhysicalIndicator(dds, may_19_interval, Symbol("4G_Shoulder"), print_cases, "May 19", analysis_dir_path)

    println("MAY 20 RESULTS")

    plotPhysicalIndicator(dds, may_20_interval, Symbol("SOC"), print_cases, "May 20", analysis_dir_path)
    plotPhysicalIndicator(dds, may_20_interval, Symbol("6G_Wind"), print_cases, "May 20", analysis_dir_path)
    plotPhysicalIndicator(dds, may_20_interval, Symbol("2D_ModerateBid"), print_cases, "May 20", analysis_dir_path)
    plotPhysicalIndicator(dds, may_20_interval, Symbol("4G_Shoulder"), print_cases, "May 20", analysis_dir_path)

    println("MAY 21 RESULTS")

    plotPhysicalIndicator(dds, may_21_interval, Symbol("SOC"), print_cases, "May 21", analysis_dir_path)
    plotPhysicalIndicator(dds, may_21_interval, Symbol("6G_Wind"), print_cases, "May 21", analysis_dir_path)
    plotPhysicalIndicator(dds, may_21_interval, Symbol("2D_ModerateBid"), print_cases, "May 21", analysis_dir_path)
    plotPhysicalIndicator(dds, may_21_interval, Symbol("4G_Shoulder"), print_cases, "May 21", analysis_dir_path)

    plotSEWDifference(mtu_economic_indicators, may_19_interval, print_cases, "May 19", analysis_dir_path)
    plotSEWDifference(mtu_economic_indicators, may_20_interval, print_cases, "May 20", analysis_dir_path)
    plotSEWDifference(mtu_economic_indicators, may_21_interval, print_cases, "May 21", analysis_dir_path)

    AnalyzeDailySEW(print_cases, mtu_economic_indicators, dds, analysis_dir_path)
end

function GetDispatchDecisions(cases, dispatch_decision_paths)
	dds = Dict{String,Any}()
	for case in cases
		dds[case] = LoadFile(dispatch_decision_paths[case])
        AddDayAndHour!(dds[case], Symbol("mtu"))
	end
	return dds
end


function GetMTUEconomicIndicators(cases, mtu_economic_indicator_paths)
    inds = Dict{String,Any}()
    for case in cases
        inds[case] = LoadFile(mtu_economic_indicator_paths[case])
        AddDayAndHour!(inds[case], Symbol("MTU"))
    end
    return inds
end

function LoadFile(filepath)

    df = DataFrame(XLSX.readtable(filepath, "data"))
    return df
end

function plotPhysicalIndicator(dds, test_range, indicator, print_cases, print_date, analysis_dir_path)

    indicatorData = Dict{String, Any}()
    # daily_indicators = Dict{String, Any}()
    for marketConfiguration in print_cases
        final_market_results = dds[marketConfiguration]
        indicatorData[marketConfiguration] = []
        push!(indicatorData[marketConfiguration], final_market_results[test_range.start .<= final_market_results.mtu .<= test_range.stop,indicator])
    end
    # println(intervalIndicatorData)
    xPlotIndicator = test_range
    pIndicator = Plots.plot(xlabel="MTU", ylabel="$indicator",
                            title="Comparing $indicator - $(print_date)")

    for (marketConfiguration, indicatorSeries) in indicatorData   
        Plots.plot!(pIndicator, xPlotIndicator, indicatorSeries, label=marketConfiguration)
    end
    display(pIndicator)
    savefig(pIndicator, "$analysis_dir_path/dispatch_compare_$(print_date)_$(indicator).png")
end


sewSymbol =  Symbol("Socioeconomic Welfare (€)")

function AnalyzeDailySEW(print_cases, mtu_economic_indicators, dds, analysis_dir_path)

    daily_sews = Dict{String,Any}()
    for (marketConfiguration, mtu_economic_indicator_df) in mtu_economic_indicators
        # AddDayAndHour!(mtu_economic_indicator_df, Symbol("MTU"))
        daily_ei = groupby(mtu_economic_indicator_df,:Day)
        daily_sew = combine(daily_ei, sewSymbol => sum => sewSymbol)
        # hourly_charge = combine(hourly_dd, :StorageCharge => sum)
        println(daily_sew)
        daily_sews[marketConfiguration] = daily_sew
    end



    AnalyzeDrivers(print_cases, mtu_economic_indicators, dds, daily_sews, analysis_dir_path)
    CreateComparisonStats(mtu_economic_indicators, daily_sews, analysis_dir_path)

end

function CreateComparisonStats(mtu_economic_indicators, daily_sews, analysis_dir_path)

    comparisonStats = Dict{String,Any}()

    sew_diffs = daily_sews["Rolling Horizon"][!,sewSymbol] .- daily_sews["Fixed Horizon"][!,sewSymbol]

    comparisonStats["Mean"] = mean(sew_diffs)
    comparisonStats["Std Dev"] = std(sew_diffs)
    comparisonStats["Median"] = median(sew_diffs)
    comparisonStats["Days"] = length(sew_diffs)
    
    alpha = 0.05
    d = TDist(comparisonStats["Days"] - 1)
    margin = quantile(d, 1 - alpha / 2) * (comparisonStats["Std Dev"] / sqrt(comparisonStats["Days"]))

    ci = (round(comparisonStats["Mean"] - margin), round(comparisonStats["Mean"] + margin))
    comparisonStats["95 Confidence Interval"] = ci

    comparisonStats["Positive Days"] = count(i->(i>0),sew_diffs)
    println(comparisonStats)

    comparisonDF = DataFrame()
    comparisonDF[!,"Daily Difference"] = ["Rolling Horizon - Fixed Horizon"]
    comparisonDF[!,"Days"] = [comparisonStats["Days"]]
    comparisonDF[!,"Mean"] = [comparisonStats["Mean"]]
    comparisonDF[!,"Median"] = [comparisonStats["Median"]]
    comparisonDF[!,"Std. Dev."] = [comparisonStats["Std Dev"]]
    comparisonDF[!,"95% CI mean"] = ["$(comparisonStats["95 Confidence Interval"])"]
    comparisonDF[!,"Positive Days"] = ["$(comparisonStats["Positive Days"])/$(comparisonStats["Days"])"]

    println(comparisonDF)


    XLSX.writetable("$analysis_dir_path/sew_details.xlsx", "data" => comparisonDF; overwrite=true)

    daily_sew_tex = latexify(comparisonDF; env = :table, booktabs = true, snakecase=true, latex=false,fmt="%'\''d\n")
    write("$analysis_dir_path/sew_details.tex",daily_sew_tex)
end

function line_fit(x::Vector{Float64}, y::Vector{Float64})
    n = length(x)
    n >= 2 || return nothing
    xbar = mean(x)
    ybar = mean(y)
    denom = sum((x .- xbar) .^ 2)
    denom > 0 || return nothing
    slope = sum((x .- xbar) .* (y .- ybar)) / denom
    intercept = ybar - slope * xbar
    return intercept, slope
end


function safe_cor(x::AbstractVector{<:Real}, y::AbstractVector{<:Real})
    (length(x) > 1 && std(x) > 0 && std(y) > 0) ? cor(x, y) : NaN
end

function padded_limits(values; frac = 0.06)
    vmin = minimum(values)
    vmax = maximum(values)
    span = vmax - vmin
    pad = span > 0 ? frac * span : max(1.0, frac * max(abs(vmin), abs(vmax), 1.0))
    return (vmin - pad, vmax + pad)
end

shoulderPeakDispatchSymbol = Symbol("ShoulderPeakDispatch")

function AnalyzeDrivers(print_cases, mtu_economic_indicators, dispatch_decisions, daily_sews, analysis_dir_path)
    daily_net_discharges = Dict{String,Any}()
    daily_shoulder_peak_dispatches = Dict{String,Any}()
    # dispatch_decisions = GetDispatchDecisions(print_cases)
    for (marketConfiguration, dd) in dispatch_decisions
        # AddDayAndHour!(dd, Symbol("mtu"))
        daily_dd = groupby(dd,:Day)
        daily_net_discharge = combine(daily_dd, [:StorageDischarge, :StorageCharge]  => ((sd,sc) -> sum(sd - sc)) => Symbol("Net Discharge"))
        daily_shoulder_peak_dispatch = combine(daily_dd, [Symbol("4G_Shoulder"), Symbol("5G_Peak")]  => ((sh_d,p_d) -> sum(sh_d + p_d)) => shoulderPeakDispatchSymbol)
        # hourly_charge = combine(hourly_dd, :StorageCharge => sum)
        println(daily_net_discharge)
        daily_net_discharges[marketConfiguration] = daily_net_discharge
        daily_shoulder_peak_dispatches[marketConfiguration] = daily_shoulder_peak_dispatch
    end
    println(daily_net_discharges)

    
    sew_diffs = daily_sews["Rolling Horizon"][!,sewSymbol] .- daily_sews["Fixed Horizon"][!,sewSymbol]
    net_discharge_diffs = daily_net_discharges["Rolling Horizon"][!,Symbol("Net Discharge")] .- daily_net_discharges["Fixed Horizon"][!,Symbol("Net Discharge")]

    shoulder_peak_dispatch_diffs = daily_shoulder_peak_dispatches["Rolling Horizon"][!,shoulderPeakDispatchSymbol] .- daily_shoulder_peak_dispatches["Fixed Horizon"][!,shoulderPeakDispatchSymbol]



    spec = (feature = :delta_net_storage_discharge_mwh, title = "Net storage discharge", xlabel = "Delta net storage discharge [MWh]", filepath = "$analysis_dir_path/net_storage_driver.png")
    x = net_discharge_diffs
    y = sew_diffs
    
    PlotDriver(spec, x, y)

    spec = (feature = :delta_mid_peak_dispatch_mwh, title = "Shoulder + peak dispatch", xlabel = "Delta Mid + Peak dispatch [MWh]", filepath = "$analysis_dir_path/shoulder_peak_dispatch_driver.png")
    x = shoulder_peak_dispatch_diffs
    y = sew_diffs
    
    PlotDriver(spec, x, y)


end

function PlotDriver(spec, x, y)

    corr_xy = safe_cor(x, y)
    xlims_panel = padded_limits(x)
    ylims_panel = padded_limits(y)
    x_text = xlims_panel[1] + 0.04 * (xlims_panel[2] - xlims_panel[1])
    y_text = ylims_panel[2] - 0.08 * (ylims_panel[2] - ylims_panel[1])
    ylabel_text = "Δ SEW [EUR]"

    p = scatter(
        x,
        y,
        alpha = 0.7,
        markerstrokewidth = 0,
        markersize = 3,
        color = RGB(0.18, 0.43, 0.68),
        xlabel = spec.xlabel,
        ylabel = ylabel_text,
        title = spec.title,
        legend = false,
        xlims = xlims_panel,
        ylims = ylims_panel,
        tickfontsize = 8,
        guidefontsize = 10,
        titlefontsize = 12,
        gridalpha = 0.12,
        framestyle = :box,
        left_margin = 10Plots.mm,
        right_margin = 6Plots.mm,
        top_margin = 3Plots.mm,
        bottom_margin = 8Plots.mm,
    )
    fit = line_fit(x, y)
    if fit !== nothing
        intercept, slope = fit
        xs = collect(range(minimum(x), maximum(x), length = 100))
        ys = intercept .+ slope .* xs
        plot!(p, xs, ys, color = :black, linewidth = 1.4)
    end
    hline!(p, [0.0], color = :grey, linestyle = :dash, linewidth = 1, alpha = 0.6)
    annotate!(p, x_text, y_text, text("r = $(round(corr_xy; digits = 3))", 10, :black, :left))
    pFig = plot(p)
    display(pFig)
    savefig(pFig, spec.filepath)
end

function AddDayAndHour!(df, mtu_symbol)
    df[!,Symbol("Hour")] = df[!,mtu_symbol] .% 24
    df[!,Symbol("Day")] = (df[!,mtu_symbol] .- df[!,Symbol("Hour")]) ./ 24
end


function plotSEWDifference(mtu_economic_indicators, interval, print_cases, print_date, analysis_dir_path)
    case_xs = Dict{String,Any}()
    for case in print_cases
        case_eis = mtu_economic_indicators[case]
        case_x = []

        for mtu in interval
            push!(case_x, case_eis[case_eis.MTU .== mtu, sewSymbol][1])
        end
        case_xs[case] = case_x
    end

    rolling_fixed_diff = case_xs["Rolling Horizon"] .- case_xs["Fixed Horizon"]
    auction_only_fixed_diff = case_xs["Auction Only"] .- case_xs["Fixed Horizon"]


    xPlotIndicator = interval
    # pSEWDiff = Plots.plot(xlabel="MTU", ylabel="Rolling - Fixed Δ SEW [EUR]", title="Rolling - Fixed Horizon SEW on $print_date")

     
    pSEWDiff = bar(xPlotIndicator, rolling_fixed_diff;xlabel="MTU", ylabel="Rolling - Fixed Δ SEW [EUR]",
                            title="Rolling - Fixed Horizon SEW on $print_date")

    display(pSEWDiff)
    savefig(pSEWDiff, "$analysis_dir_path/SEW_roll_fix_diff_$(print_date).png")


    pSEWDiffAO = bar(xPlotIndicator, auction_only_fixed_diff;xlabel="MTU", ylabel="Auction Only - Fixed Δ SEW [EUR]",
                            title="Auction Only - Fixed Horizon SEW on $print_date")

    display(pSEWDiffAO)
    savefig(pSEWDiffAO, "$analysis_dir_path/SEW_ao_fix_diff_$(print_date).png")
end

end;
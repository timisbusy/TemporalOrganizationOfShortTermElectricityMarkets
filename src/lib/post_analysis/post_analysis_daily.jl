module PostAnalysisDaily

using Plots
using JuMP
using Statistics
using DataFrames
using XLSX
using Distributions
using Latexify

include("./post_analysis_common.jl")

CASES = PostAnalysisCommon.CASES

quantitySymbol = Symbol("Quantity (MWh)")

function PerformAnalysis(case_paths; output_base=PostAnalysisCommon.NewAnalysisOutputDir(case_paths))

    analysis_dir_path = "$output_base/post_analysis_daily"

    dispatch_decision_paths = Dict(case => joinpath(case_paths[case], "final_dispatch_decisions.xlsx") for case in CASES)

	PostAnalysisCommon.CleanDirectory(analysis_dir_path)

    may_19_interval = 20*24:(21*24 - 1)
    may_20_interval = 21*24:(22*24 - 1)
    may_21_interval = 22*24:(23*24 - 1)

    print_cases = CASES

	dds = GetDispatchDecisions(print_cases, dispatch_decision_paths)
    mtu_economic_indicators = GetMTUEconomicIndicators(print_cases, case_paths)

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


# Computed fresh via CalculateCaseIndicators (final_dispatch_decisions.xlsx + transactions.xlsx),
# not read from the pre-exported mtu_economic_results.xlsx - that export was written without
# imbalance_agents set, so it has no real Imbalance Energy figures (see AnalyzeDrivers' imbalance
# driver plot, which needs them).
function GetMTUEconomicIndicators(cases, case_paths)
    inds = Dict{String,Any}()
    for case in cases
        (economic_indicators, agent_indicators, transactions, finalDispatchDecisions, mtu_economic_indicators) = PostAnalysisCommon.CalculateCaseIndicators(case_paths, case; imbalance_agents=PostAnalysisCommon.DEFAULT_IMBALANCE_AGENTS)
        inds[case] = mtu_economic_indicators
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
imbalanceSymbol = Symbol("Imbalance Energy (MWh)")

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

# Fixed and Rolling are independent single-design runs (not one shared comparison run), so their
# daily-grouped tables aren't guaranteed the same length (e.g. a spin-up/tail day present in one
# run's export but not the other's) - join on :Day rather than assuming aligned row order/length.
# Returns a (Day, Diff) DataFrame rather than a bare vector, since two DIFFERENT diff series (e.g.
# SEW from mtu_economic_results vs. Net Discharge from final_dispatch_decisions) can themselves
# cover different day ranges and need their own Day-join before being compared to each other - see
# AlignedXY.
function DiffByDay(rolling_df, fixed_df, value_symbol)
    r = rename(rolling_df[!, [:Day, value_symbol]], value_symbol => :RollingValue)
    f = rename(fixed_df[!, [:Day, value_symbol]], value_symbol => :FixedValue)
    joined = innerjoin(r, f, on=:Day)
    joined[!, :Diff] = joined.RollingValue .- joined.FixedValue
    return joined[!, [:Day, :Diff]]
end

# aligns two DiffByDay results on :Day and returns their Diff columns as plain vectors, for
# plotting/correlating one diff series against another.
function AlignedXY(x_diff_df, y_diff_df)
    joined = innerjoin(rename(x_diff_df, :Diff => :X), rename(y_diff_df, :Diff => :Y), on=:Day)
    return joined.X, joined.Y
end

function CreateComparisonStats(mtu_economic_indicators, daily_sews, analysis_dir_path)

    comparisonStats = Dict{String,Any}()

    sew_diffs = DiffByDay(daily_sews["Rolling Horizon"], daily_sews["Fixed Horizon"], sewSymbol).Diff

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

    daily_imbalances = Dict{String,Any}()
    for (marketConfiguration, mei) in mtu_economic_indicators
        daily_mei = groupby(mei, :Day)
        daily_imbalance = combine(daily_mei, imbalanceSymbol => sum => imbalanceSymbol)
        daily_imbalances[marketConfiguration] = daily_imbalance
    end

    sew_diffs = DiffByDay(daily_sews["Rolling Horizon"], daily_sews["Fixed Horizon"], sewSymbol)
    net_discharge_diffs = DiffByDay(daily_net_discharges["Rolling Horizon"], daily_net_discharges["Fixed Horizon"], Symbol("Net Discharge"))

    shoulder_peak_dispatch_diffs = DiffByDay(daily_shoulder_peak_dispatches["Rolling Horizon"], daily_shoulder_peak_dispatches["Fixed Horizon"], shoulderPeakDispatchSymbol)

    imbalance_diffs = DiffByDay(daily_imbalances["Rolling Horizon"], daily_imbalances["Fixed Horizon"], imbalanceSymbol)



    spec = (feature = :delta_net_storage_discharge_mwh, title = "Net storage discharge", xlabel = "Delta net storage discharge [MWh]", filepath = "$analysis_dir_path/net_storage_driver.png")
    (x, y) = AlignedXY(net_discharge_diffs, sew_diffs)

    PlotDriver(spec, x, y)

    spec = (feature = :delta_mid_peak_dispatch_mwh, title = "Shoulder + peak dispatch", xlabel = "Delta Mid + Peak dispatch [MWh]", filepath = "$analysis_dir_path/shoulder_peak_dispatch_driver.png")
    (x, y) = AlignedXY(shoulder_peak_dispatch_diffs, sew_diffs)

    PlotDriver(spec, x, y)

    spec = (feature = :delta_imbalance_energy_mwh, title = "Imbalance energy", xlabel = "Delta imbalance energy [MWh]", filepath = "$analysis_dir_path/imbalance_driver.png")
    (x, y) = AlignedXY(imbalance_diffs, sew_diffs)

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

    xPlotIndicator = interval
    # pSEWDiff = Plots.plot(xlabel="MTU", ylabel="Rolling - Fixed Δ SEW [EUR]", title="Rolling - Fixed Horizon SEW on $print_date")


    pSEWDiff = bar(xPlotIndicator, rolling_fixed_diff;xlabel="MTU", ylabel="Rolling - Fixed Δ SEW [EUR]",
                            title="Rolling - Fixed Horizon SEW on $print_date")

    display(pSEWDiff)
    savefig(pSEWDiff, "$analysis_dir_path/SEW_roll_fix_diff_$(print_date).png")
end

end;

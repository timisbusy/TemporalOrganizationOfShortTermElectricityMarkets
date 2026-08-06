module PostAnalysisPrices

using Plots
using JuMP
using Statistics
using DataFrames
using XLSX
using Printf

include("./agent_renaming.jl")

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

case_shortname =    Dict{String,String}(
    "Fixed Horizon" => "fixed",
    "Rolling Horizon" => "rolling",
    "Auction Only" => "auction_only",
)


function PerformAnalysis(results_path_base_in)

    results_path_base = results_path_base_in

    analysis_dir_path = "$results_path_base/additional_analysis/post_analysis_prices"

    raw_decision_variables_paths = Dict{String,String}(
        "Fixed Horizon" => "$results_path_base/RAW/decisionvariables_Fixed_",
        "Rolling Horizon" => "$results_path_base/RAW/decisionvariables_Rolling_",
        "Auction Only" => "$results_path_base/RAW/decisionvariables_FixedSQ_",
    )


    CleanDirectory(analysis_dir_path)

    may_28_plus_interval = (29*24 - 12):(30*24 - 1)

    may_28_interval = (29*24):(30*24 - 1)

    print_cases = ["Fixed Horizon", "Rolling Horizon"]

    for case in print_cases
        CreatePlots(case, may_28_plus_interval, may_28_interval, raw_decision_variables_paths, analysis_dir_path)
    end
end

function CreatePlots(case, interval, highlight_interval, raw_decision_variables_paths, analysis_dir_path)
    dvs = GetDecisionVariables(case, interval, raw_decision_variables_paths)

    println("MAY 28 RESULTS $case")

    plotPrices(dvs, case, interval, highlight_interval, analysis_dir_path)


    plotTrades(dvs, case, interval, highlight_interval, "4G_Shoulder", analysis_dir_path)

    plotTrades(dvs, case, interval, highlight_interval, "6G_Wind", analysis_dir_path)
end


function GetDecisionVariables(case, interval, raw_decision_variables_paths)
	dvs = Dict{Int,Any}()
	for mtu in interval
		dv = LoadFile(case, mtu, raw_decision_variables_paths)
        dvs[mtu] = dv
	end
	return dvs
end

function LoadFile(case, mtu, raw_decision_variables_paths)
    filepath = "$(raw_decision_variables_paths[case])$mtu.xlsx"
    df = DataFrame(XLSX.readtable(filepath, "data"))
    return df
end

function plotPrices(dvs, case, interval, highlight_interval, analysis_dir_path)
    pPrices = Plots.plot(xlabel="MTU", ylabel="Price (EUR)",
                            title="Price Evolution $case May 28",
                            size=(1280, 450))

    for mtu in interval.start:(interval.start + 4)   
        dv = dvs[mtu]
        prices = dv[mtu .<= dv.mtu .<= interval.stop,:price]
        xPlotIndicator = mtu:interval.stop
        Plots.plot!(pPrices, xPlotIndicator, prices, label="Auction at MTU $mtu", legend=:topleft)
    end

    vspan!(pPrices,[highlight_interval.start - 0.5,highlight_interval.stop + 0.5], color = :seagreen2, alpha = 0.1, labels = "May 28")
    
    xlims!(pPrices, interval.start - 0.5, interval.stop + 5 + 0.5)
    
    display(pPrices)
    savefig(pPrices, "$analysis_dir_path/prices_$(case_shortname[case])_may_28.png")

end

function plotTrades(dvs, case, interval, highlight_interval, agent, analysis_dir_path)
    pTrades = Plots.plot(xlabel="MTU", ylabel="Auction MTU",
                            title="$(AgentRenaming.DisplayName(agent)) Adjustments May 28")

    xPlotIndicator = interval
    dv = dvs[interval.start]
    previous = dv[dv.mtu .<= interval.stop, Symbol("Q_prev_$(agent)")]
    println(length(previous), length(xPlotIndicator))
    Plots.plot!(pTrades, xPlotIndicator, previous, label="Previous")

    selected_auctions = interval.start:(interval.start + 4)   

    for mtu in selected_auctions
        dv = dvs[mtu]
        adj_quantity = dv[mtu .<= dv.mtu .<= interval.stop, Symbol("$(agent)_adj")]
        xPlotIndicator = mtu:mtu + length(adj_quantity) - 1
        println(length(adj_quantity), length(xPlotIndicator))
        Plots.plot!(pTrades, xPlotIndicator, adj_quantity, label="MTU $mtu")
    end
    display(pTrades)
    savefig(pTrades, "$analysis_dir_path/trades_$(case_shortname[case])_$(agent).png")

    y_tick_labels = vcat(["p_prev"], selected_auctions)
    p_gen = plot(
            title="$(AgentRenaming.DisplayName(agent)) Adjustments $case May 28",
            xlabel="MTU",
            ylabel="Auction MTU",
            legend=false,
            size=(1280, 450),
            yticks=(0:length(y_tick_labels)-1, y_tick_labels),
            yflip=true,
            tickfontsize=THESIS_TICK_FONT,
            guidefontsize=THESIS_GUIDE_FONT,
            titlefontsize=THESIS_TITLE_FONT,
            left_margin=16Plots.mm,
            right_margin=10Plots.mm,
            top_margin=10Plots.mm,
            bottom_margin=16Plots.mm,
        )


        for mtu in interval
            value = previous[((mtu-interval.start) + 1)]
            if value > 0.01
                plot!(
                    p_gen,
                    [mtu - 0.4, mtu + 0.4],
                    [0, 0],
                    fillrange=[0.4, 0.4],
                    fillcolor=:orange,
                    fillalpha=0.6,
                    linewidth=0,
                )
                maybe_annotate!(p_gen, mtu, 0.2, value)
            end
        end

        for (row_idx, auction_mtu) in enumerate(interval.start:(interval.start + 4) )
            dv = dvs[auction_mtu]
            adj_quantity = dv[auction_mtu .<= dv.mtu .<= interval.stop + 5, Symbol("$(agent)_adj")]
            for mtu in auction_mtu:interval.stop + 5
                true_index = ((mtu-auction_mtu) + 1)
                if true_index > length(adj_quantity)
                    continue
                end
                value = adj_quantity[true_index]
                if abs(value) > 0.01
                    bar_color = value > 0 ? :lightgreen : :lightcoral
                    plot!(
                        p_gen,
                        [mtu - 0.4, mtu + 0.4],
                        [row_idx, row_idx],
                        fillrange=[row_idx + 0.4, row_idx + 0.4],
                        fillcolor=bar_color,
                        fillalpha=0.7,
                        linewidth=0,
                    )
                    maybe_annotate!(p_gen, mtu, row_idx + 0.2, value)
                end
            end
        end

        vspan!(p_gen,[highlight_interval.start - 0.5,highlight_interval.stop + 0.5], color = :seagreen2, alpha = 0.1, labels = "May 28")
        xlims!(p_gen, interval.start - 0.5, interval.stop + 5 + 0.5)

        display(p_gen)
        savefig(p_gen, "$analysis_dir_path/trade_blocks_$(case_shortname[case])_$(agent).png")


end

const LABEL_THRESHOLD_MW = 150.0
const THESIS_TICK_FONT = 10
const THESIS_GUIDE_FONT = 11
const THESIS_TITLE_FONT = 12
const THESIS_SUPTITLE_FONT = 15
const THESIS_LEGEND_FONT = 10
const THESIS_ANNOTATION_FONT = 5

function maybe_annotate!(p, x, y, value; threshold::Real=LABEL_THRESHOLD_MW)
    if abs(value) > threshold
        sign_str = value > 0 ? "+" : ""
        annotate!(p, x, y, text(@sprintf("%s%.0f", sign_str, value), THESIS_ANNOTATION_FONT, :black))
    end
end

end;
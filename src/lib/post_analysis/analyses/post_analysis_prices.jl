module PostAnalysisPrices

using Plots
using JuMP
using Statistics
using DataFrames
using XLSX
using Printf

include("../post_analysis_common.jl")
include("../agent_renaming.jl")

quantitySymbol = Symbol("Quantity (MWh)")

# extend with an entry for any new case name used as `cases` - a case missing here falls back to
# CaseSlug(case) (post_analysis_auction_snapshots.jl's own "lowercase, spaces to underscores"
# convention) rather than erroring, so an unlisted case still gets a usable (if less polished)
# filename instead of a KeyError.
case_shortname = Dict{String,String}(
    "Fixed Horizon" => "fixed",
    "Rolling Horizon" => "rolling",
    "Auction Only" => "auction",
)
CaseShortname(case) = get(case_shortname, case, lowercase(replace(case, " " => "_")))

# raw_dispatch_prefix maps case -> per-clearing RAW decisionvariables_<experiment name>_ prefix -
# tied to the run's own experiment name, so it doesn't follow generically from case_paths. Left as
# nothing, it's discovered straight from each case's own RAW/ directory (see
# PostAnalysisCommon.DiscoverRawDispatchPrefixes); pass an explicit prefix Dict to override.
# illustrative_day: needs MTU data through (illustrative_day+1)*24-1 to exist as its own RAW
# clearing for every case - true for an uncapped run with clearForDays >= 31 (36h window:
# 31*24-36=708), but not for the lastAuctionMTU-capped fixed_36/rolling_36 pair (max MTU 672).
# Left as nothing, day 28 is used when every case's RAW export actually reaches that far,
# otherwise falling back to 26 (which fits the capped pair too); pass an explicit day to override.
function PerformAnalysis(case_paths, raw_dispatch_prefix=nothing; cases=PostAnalysisCommon.CASES, illustrative_day=nothing, output_base=PostAnalysisCommon.NewAnalysisOutputDir(case_paths))
    raw_dispatch_prefix = raw_dispatch_prefix === nothing ? PostAnalysisCommon.DiscoverRawDispatchPrefixes(case_paths) : raw_dispatch_prefix

    illustrative_day = illustrative_day !== nothing ? illustrative_day : (DayFits(28, raw_dispatch_prefix, cases) ? 28 : 26)

    analysis_dir_path = "$output_base/post_analysis_prices"

    PostAnalysisCommon.CleanDirectory(analysis_dir_path)

    illustrative_plus_interval = (illustrative_day*24 - 12):((illustrative_day + 1)*24 - 1)

    illustrative_interval = (illustrative_day*24):((illustrative_day + 1)*24 - 1)

    for case in cases
        CreatePlots(case, illustrative_plus_interval, illustrative_interval, raw_dispatch_prefix, analysis_dir_path)
    end
end

# whether every case has its own RAW clearing for day's last MTU, i.e. whether the illustrative
# window for that day can actually be drawn at all
function DayFits(day, raw_dispatch_prefix, cases)
    last_mtu = (day + 1)*24 - 1
    return all(isfile("$(raw_dispatch_prefix[case])$(last_mtu).xlsx") for case in cases)
end

function CreatePlots(case, interval, highlight_interval, raw_decision_variables_paths, analysis_dir_path)
    dvs = GetDecisionVariables(case, interval, raw_decision_variables_paths)

    day_label = "Day $(highlight_interval.start ÷ 24)"

    println("$(uppercase(day_label)) RESULTS $case")

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
    day_label = "Day $(highlight_interval.start ÷ 24)"

    # left_margin: without it the ylabel gets clipped off-canvas entirely rather than just
    # crowded - same fix already applied to plotTrades' p_gen chart below.
    pPrices = Plots.plot(xlabel="MTU", ylabel="Market Clearing Price (€/MWh)",
                            title="Price Evolution $case $day_label",
                            size=(1280, 450),
                            left_margin=16Plots.mm, bottom_margin=10Plots.mm)

    # dv.mtu goes up to interval.stop + 5 to match xlims! below and the trade_blocks chart in
    # plotTrades - each auction's own RAW export already has price data out that far (obviously so
    # for Rolling Horizon, whose 36h window means every one of these 5 auctions reaches well past
    # interval.stop on its own), truncating at interval.stop alone just discarded it, leaving the
    # last 5 MTU of the plot's intended headroom empty.
    for mtu in interval.start:(interval.start + 4)
        dv = dvs[mtu]
        filtered = dv[mtu .<= dv.mtu .<= interval.stop + 5, :]
        Plots.plot!(pPrices, filtered.mtu, filtered.price, label="Auction at MTU $mtu", legend=:topleft)
    end

    vspan!(pPrices,[highlight_interval.start - 0.5,highlight_interval.stop + 0.5], color = :seagreen2, alpha = 0.1, labels = day_label)

    xlims!(pPrices, interval.start - 0.5, interval.stop + 5 + 0.5)

    display(pPrices)
    savefig(pPrices, "$analysis_dir_path/prices_$(CaseShortname(case))_day$(highlight_interval.start ÷ 24).png")

end

function plotTrades(dvs, case, interval, highlight_interval, agent, analysis_dir_path)
    day_label = "Day $(highlight_interval.start ÷ 24)"

    pTrades = Plots.plot(xlabel="MTU", ylabel="Auction MTU",
                            title="$(AgentRenaming.DisplayName(agent)) Adjustments $day_label")

    adj_col = Symbol("$(agent)_adj")

    xPlotIndicator = interval
    dv = dvs[interval.start]
    previous_lookup = Dict{Int,Float64}(row.mtu => row[Symbol("Q_prev_$(agent)")] for row in eachrow(dv[dv.mtu .<= interval.stop, :]))
    previous = [get(previous_lookup, mtu, 0.0) for mtu in interval]
    println(length(previous), length(xPlotIndicator))
    Plots.plot!(pTrades, xPlotIndicator, previous, label="Previous")

    selected_auctions = interval.start:(interval.start + 4)

    for mtu in selected_auctions
        dv = dvs[mtu]
        adj_quantity_df = dv[mtu .<= dv.mtu .<= interval.stop, [:mtu, adj_col]]
        Plots.plot!(pTrades, adj_quantity_df.mtu, adj_quantity_df[!, adj_col], label="MTU $mtu")
    end
    display(pTrades)
    savefig(pTrades, "$analysis_dir_path/trades_$(CaseShortname(case))_$(agent).png")

    y_tick_labels = vcat(["p_prev"], selected_auctions)
    p_gen = plot(
            title="$(AgentRenaming.DisplayName(agent)) Adjustments $case $day_label",
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
            adj_quantity_df = dv[auction_mtu .<= dv.mtu .<= interval.stop + 5, [:mtu, adj_col]]
            for row in eachrow(adj_quantity_df)
                value = row[adj_col]
                abs(value) <= 0.01 && continue
                bar_color = value > 0 ? :lightgreen : :lightcoral
                plot!(
                    p_gen,
                    [row.mtu - 0.4, row.mtu + 0.4],
                    [row_idx, row_idx],
                    fillrange=[row_idx + 0.4, row_idx + 0.4],
                    fillcolor=bar_color,
                    fillalpha=0.7,
                    linewidth=0,
                )
                maybe_annotate!(p_gen, row.mtu, row_idx + 0.2, value)
            end
        end

        vspan!(p_gen,[highlight_interval.start - 0.5,highlight_interval.stop + 0.5], color = :seagreen2, alpha = 0.1, labels = day_label)
        xlims!(p_gen, interval.start - 0.5, interval.stop + 5 + 0.5)

        display(p_gen)
        savefig(p_gen, "$analysis_dir_path/trade_blocks_$(CaseShortname(case))_$(agent).png")


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

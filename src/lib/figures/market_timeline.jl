# Draws a market configuration as a timeline of its auctions: one row per auction (clearing), in the order they
# are held (earliest at the top), and on the x axis the delivery MTUs that auction's optimization window covers,
# one block per MTU. Each block is coloured by what the auction does for that MTU:
#
#   Initial dispatch        - no earlier auction's window included this MTU, so this is where its dispatch
#                             decisions are first created
#   Adjustment opportunity  - an earlier auction already dispatched this MTU; this one can revise it
#   Auction Cleared         - not a kind of block: a vertical line on the left edge of the MTU at which the auction is held
#   Balancing (locked MTU)  - the first MTU of the window when the restrict_mtu1_trading lock applies: base,
#                             shoulder and solar generation can no longer be adjusted there
#
# The lock is applied the way the market models apply it (see the restrict_mtu1_trading block of
# latest_model.jl): to every auction except the very first one, unless the market configuration sets
# overrideMTU1Restriction. It is an experiment-level setting rather than part of a market configuration, so it
# is the `restrict_mtu1_trading` argument here (true by default, as in the no_cap experiment configs). A lock
# with a look-ahead distance above zero is an error, as in the models: the lock only makes sense when the
# window starts at the clearing MTU.
#
# Example:
#   include("src/lib/figures/market_timeline.jl")
#   MarketTimeline.Plot("rolling_laura.yaml")                      # resolved under src/configs/markets/, or give a path
#   MarketTimeline.Plot("fixed_laura.yaml"; days=4, restrict_mtu1_trading=false)

module MarketTimeline

using Plots

include("../data_importer.jl")
include("../market_clearers/market_sequence.jl")

const INITIAL = :initial
const ADJUSTMENT = :adjustment
const BALANCING = :balancing

# in lifecycle order, which is also the legend order
const KINDS = [INITIAL, ADJUSTMENT, BALANCING]
const KIND_LABELS = Dict(
    INITIAL => "Initial Dispatch",
    ADJUSTMENT => "Adjustment",
    BALANCING => "Balancing",
)

const CLEARING_LABEL = "Auction Cleared"

# chart surface and ink as in the other analysis figures; strong and light blue for the dispatch / adjustment pair,
# orange for the locked balancing MTU
const SURFACE = "#fcfcfb"
const INK = "#0b0b0b"
const INK_SECONDARY = "#52514e"
const AXIS = "#c3c2b7"
const KIND_COLORS = Dict(INITIAL => "#2a78d6", ADJUSTMENT => "#a9c8ee", BALANCING => "#eb6834")

# a market configuration file: a path as given, otherwise a name under src/configs/markets/
function ResolveMarketConfigPath(market_config::String)
    isfile(market_config) && return market_config
    path = joinpath(DataImporter.CONFIG_PATH, "markets", market_config)
    isfile(path) || error("no market configuration at $market_config or $path")
    return path
end

# the markets of a market configuration file, parsed by the same code the experiments use, and its MTU per day
function LoadMarkets(market_config::String)
    path = ResolveMarketConfigPath(market_config)
    time_periods_per_day = Int(DataImporter.YAML.load_file(path)["timePeriodsPerDay"])
    return (markets=DataImporter.load_market_configuration(path, time_periods_per_day), time_periods_per_day=time_periods_per_day, path=path)
end

# Every auction held at an MTU in `time_range`, in the order the simulation clears them, as
# (clearing_mtu, market, window, kinds): its optimization window and the kind of each of its MTUs.
# The kinds depend on the auctions before it, so they are worked out from the first MTU on:
# `skip_early_auctions` is the experiment setting of that name (auctions before it are not held).
function ClassifyAuctions(markets, time_range; restrict_mtu1_trading::Bool=true, skip_early_auctions::Int=0)
    auctions = NamedTuple[]
    dispatched = Set{Int}() # MTUs inside the window of an auction already held
    for t in time_range
        t < skip_early_auctions && continue
        for market in MarketSequence.generateMarketSetForTimePeriod(t, markets)
            first_start = t + market[:lookAheadDistance]
            window = first_start:(first_start + market[:optimizationWindow] - 1)
            # the first auction held is exempt from the lock, as in the models (nothing is dispatched yet)
            locked = !isempty(auctions) && restrict_mtu1_trading && !market[:overrideMTU1Restriction]
            locked && first_start != t && error("restrict_mtu1_trading lock requires the optimization window to start at the clearing MTU, but the $(market[:name]) auction at $t starts its window at $first_start")
            kinds = [locked && mtu == first_start ? BALANCING : mtu in dispatched ? ADJUSTMENT : INITIAL for mtu in window]
            union!(dispatched, window)
            push!(auctions, (clearing_mtu=t, market=market[:name], window=window, kinds=kinds))
        end
    end
    return auctions
end

# One rectangle per block - the MTU's column (mtu to mtu + 1) in the auction's row, a little short of the row's full
# height - appended to the coordinate vectors of its kind, NaN-separated so that all of a kind is a single series
# (and so a single legend entry).
function AddBlock!(xs, ys, mtu, row)
    append!(xs, (mtu, mtu + 1, mtu + 1, mtu, NaN))
    append!(ys, (row - 0.42, row - 0.42, row + 0.42, row + 0.42, NaN))
end

# The auction-held marker: a vertical-line marker on the left edge of the clearing MTU's column, centred on the
# auction's row. A marker series (rather than a path) is what gives the legend a vertical line as its symbol.
function AddClearingMarker!(xs, ys, clearing_mtu, row)
    push!(xs, clearing_mtu)
    push!(ys, row)
end

# y tick labels: the clearing MTU, with the market's name where two auctions are held at the same MTU
function RowLabels(auctions)
    held_at = Dict{Int,Int}()
    for a in auctions
        held_at[a.clearing_mtu] = get(held_at, a.clearing_mtu, 0) + 1
    end
    return [held_at[a.clearing_mtu] > 1 ? "$(a.clearing_mtu) · $(a.market)" : string(a.clearing_mtu) for a in auctions]
end

# market_config: file name under src/configs/markets/ or a path. `design` names the market design in the title
# ("<design> - Auctions 24-59"), the config name by default. The auctions held in the first `days` days of
# the run (or in `clearing_range`, MTUs) are drawn. The figure is returned and, unless output_path is nothing,
# saved there (default results/figures/market_timeline_<config name>.png).
function Plot(market_config::String; restrict_mtu1_trading::Bool=true, skip_early_auctions::Int=0, days::Int=3, clearing_range=nothing, design=nothing, output_path="")
    (markets, time_periods_per_day, path) = LoadMarkets(market_config)
    shown = clearing_range === nothing ? (0:(days * time_periods_per_day - 1)) : clearing_range
    auctions = filter(a -> a.clearing_mtu in shown, ClassifyAuctions(markets, 0:last(shown); restrict_mtu1_trading=restrict_mtu1_trading, skip_early_auctions=skip_early_auctions))
    isempty(auctions) && error("no auctions are held at MTUs $shown by $path")

    blocks = Dict(kind => (Float64[], Float64[]) for kind in KINDS)
    for (row, a) in enumerate(auctions), (mtu, kind) in zip(a.window, a.kinds)
        AddBlock!(blocks[kind]..., mtu, row)
    end

    markers = (Float64[], Float64[])
    for (row, a) in enumerate(auctions)
        AddClearingMarker!(markers..., a.clearing_mtu, row)
    end

    x_min = minimum(min(first(a.window), a.clearing_mtu) for a in auctions)
    x_max = maximum(last(a.window) for a in auctions) + 1
    n = length(auctions)
    label_step = max(1, cld(n, 24)) # keep the row labels legible when there are many auctions
    labelled = 1:label_step:n
    x_step = max(1, time_periods_per_day ÷ 4)
    name = splitext(basename(path))[1]

    p = Plots.plot(; background_color=SURFACE, foreground_color=AXIS, foreground_color_text=INK_SECONDARY, foreground_color_guide=INK_SECONDARY,
                   titlefontcolor=INK, legendfontcolor=INK_SECONDARY, framestyle=:box, grid=:x, gridalpha=0.5, gridcolor=AXIS,
                   title="$(design === nothing ? name : design) - Auctions $(first(auctions).clearing_mtu)-$(last(auctions).clearing_mtu)", titlefontsize=12, xlabel="Delivery MTU", ylabel="Auction MTU",
                   size=(1100, clamp(300 + 11 * n, 620, 1500)), xlims=(x_min, x_max), ylims=(0.4, n + 0.6), yflip=true,
                   xticks=(ceil(Int, x_min / x_step) * x_step):x_step:x_max, yticks=(collect(labelled), RowLabels(auctions)[labelled]),
                   legend=:outerbottom, legendfontsize=9, legend_columns=count(k -> !isempty(blocks[k][1]), KINDS) + 1, left_margin=6Plots.mm, bottom_margin=8Plots.mm)
    for kind in KINDS
        isempty(blocks[kind][1]) && continue
        Plots.plot!(p, blocks[kind]...; seriestype=:shape, fillcolor=KIND_COLORS[kind], linecolor=SURFACE, linewidth=0.6, label=KIND_LABELS[kind])
    end

    # about the height of a block (rows share roughly 80% of the figure height), within what stays legible
    marker_size = clamp(0.8 * (clamp(300 + 11 * n, 620, 1500)) / n * 0.5, 3, 8)
    Plots.scatter!(p, markers...; marker=:vline, markersize=marker_size, markerstrokecolor=INK, markerstrokewidth=2.5, markercolor=INK, label=CLEARING_LABEL)

    if output_path !== nothing
        output_path = isempty(output_path) ? "results/figures/market_timeline_$name.png" : output_path
        mkpath(dirname(output_path))
        Plots.savefig(p, output_path)
        println("saved auction timeline to $output_path")
    end
    return p
end

end;

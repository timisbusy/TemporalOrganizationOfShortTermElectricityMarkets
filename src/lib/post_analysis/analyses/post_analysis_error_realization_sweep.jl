# Box plots of an ErrorRealizationSweep (src/lib/experiments/error_realization_sweep.jl): how the rolling-horizon
# design differs from the fixed-horizon design across many wind forecast error realizations.
#
# Reads results/sweep_{name}/kpis.csv and writes, under results/sweep_{name}/plots/:
#   paired_differences.png   rolling - fixed per seed, one panel per KPI (SEW, wind curtailment, solar curtailment,
#                            imbalance). Each seed is a paired comparison - both designs saw the same errors - so a
#                            box clear of the zero line means the designs differ consistently, one straddling it means
#                            the difference is within the spread between realizations.
#   levels_by_design.png     the KPI levels of the two designs side by side (imbalance and the two curtailments; SEW is
#                            ~2.19e9 EUR in both, so its levels are indistinguishable at that scale and it appears only
#                            as the difference above).
#   boxplot_statistics.csv   the numbers behind every box: n, mean, standard error, quartiles, whisker ends, extremes.
# Boxes span the quartiles with the median inside, whiskers reach the furthest point within 1.5 x IQR, every seed is a dot,
# and the diamond is the mean. Rerunnable at any time - including on a sweep still in progress, which is read from a copy.
#
# Example:
#   include("src/lib/post_analysis/analyses/post_analysis_error_realization_sweep.jl")
#   PostAnalysisErrorRealizationSweep.PerformAnalysis("fixed_vs_rolling_36")

module PostAnalysisErrorRealizationSweep

using CSV, DataFrames, Plots, StatsPlots, Statistics, Printf, Random

# chart surface and ink, from the dataviz reference palette
const SURFACE = "#fcfcfb"
const INK = "#0b0b0b"
const INK_SECONDARY = "#52514e"
const AXIS = "#c3c2b7"
const GRID = "#e1e0d9"

# one color per design (categorical slots 1 and 2), the same blue / orange pairing the lead-time analysis uses for the two cases
const FIXED_COLOR = "#2a78d6"
const ROLLING_COLOR = "#eb6834"

# (diff column, fixed column, rolling column, title, unit)
const DIFFERENCE_KPIS = [
    (diff=:d_sew, fixed=:fixed_sew, rolling=:rolling_sew, title="Socioeconomic welfare", unit="EUR"),
    (diff=:d_wind_curtailed, fixed=:fixed_wind_curtailed, rolling=:rolling_wind_curtailed, title="Wind curtailment", unit="MWh"),
    (diff=:d_solar_curtailed, fixed=:fixed_solar_curtailed, rolling=:rolling_solar_curtailed, title="Solar curtailment", unit="MWh"),
    (diff=:d_imbalance, fixed=:fixed_imbalance, rolling=:rolling_imbalance, title="Imbalance energy", unit="MWh"),
]
const LEVEL_KPIS = DIFFERENCE_KPIS[2:4]

standard_error(x) = length(x) > 1 ? std(x) / sqrt(length(x)) : NaN

# 1234567 -> "1.2M", -48000 -> "-48K", 1500 -> "1.5K": compact tick labels, one decimal only where it is needed
function CompactTick(v)
    trim(s) = endswith(s, ".0") ? s[1:end-2] : s
    a = abs(v)
    a >= 1e6 && return trim(@sprintf("%.1f", v / 1e6)) * "M"
    a >= 1e3 && return trim(@sprintf("%.1f", v / 1e3)) * "K"
    return @sprintf("%.0f", v)
end

# 1234.5 -> "1,234"; used in annotations
function WithSeparators(v)
    s = @sprintf("%.0f", abs(v))
    parts = String[]
    while length(s) > 3
        pushfirst!(parts, s[end-2:end]); s = s[1:end-3]
    end
    pushfirst!(parts, s)
    return (v < 0 ? "-" : "") * join(parts, ",")
end

# the numbers a box is drawn from (quartiles by Statistics.quantile; whiskers reach the furthest point within 1.5 x IQR)
function BoxStatistics(x)
    q1, med, q3 = quantile(x, [0.25, 0.5, 0.75])
    iqr = q3 - q1
    inside = x[(x .>= q1 - 1.5 * iqr) .& (x .<= q3 + 1.5 * iqr)]
    return (n=length(x), mean=mean(x), std_error=standard_error(x), min=minimum(x), whisker_low=minimum(inside), q1=q1, median=med, q3=q3, whisker_high=maximum(inside), max=maximum(x))
end

# styling shared by every panel: light surface, hairline solid grid on the value axis only, recessive axes, text in ink tokens
panel_style(; kwargs...) = (; background_color=SURFACE, foreground_color=AXIS, foreground_color_text=INK_SECONDARY, foreground_color_guide=INK_SECONDARY,
    titlefontcolor=INK, legendfontcolor=INK_SECONDARY, grid=:y, gridcolor=GRID, gridalpha=1.0, gridlinewidth=1, framestyle=:box, tickfontsize=9,
    guidefontsize=10, titlefontsize=11, yformatter=CompactTick, kwargs...)

# a box, its seeds as dots (with a surface ring so overlapping dots stay legible) and its mean
function AddBox!(p, position, values, color; label="", rng, dot_alpha=0.4, fill_alpha=0.22)
    # color= as well as linecolor=: without it the box outline and whiskers take the next default-palette color
    boxplot!(p, fill(position, length(values)), values; color=color, fillcolor=color, fillalpha=fill_alpha, linecolor=color, linewidth=1.5,
             outliers=false, whisker_width=:half, bar_width=0.5, label=label)
    jitter = (rand(rng, length(values)) .- 0.5) .* 0.3
    scatter!(p, position .+ jitter, values; markersize=4, markercolor=color, markeralpha=dot_alpha, markerstrokecolor=SURFACE, markerstrokewidth=1, label="")
    scatter!(p, [position], [mean(values)]; marker=:diamond, markersize=9, markercolor=INK, markerstrokecolor=SURFACE, markerstrokewidth=2, label="")
end

# padded y-limits that always include the zero line
function PaddedLimits(values; include_zero=true)
    lo, hi = minimum(values), maximum(values)
    include_zero && ((lo, hi) = (min(lo, 0.0), max(hi, 0.0)))
    pad = 0.08 * max(hi - lo, eps())
    return (lo - pad, hi + pad)
end

function DifferencePanel(df, kpi, rng)
    x = df[!, kpi.diff]
    stats = BoxStatistics(x)
    better = kpi.diff in (:d_wind_curtailed, :d_solar_curtailed, :d_imbalance) ? count(<(0), x) : count(>(0), x)
    subtitle = "mean $(stats.mean >= 0 ? "+" : "")$(WithSeparators(stats.mean)) ± $(WithSeparators(stats.std_error)) · rolling better in $better of $(stats.n) seeds"
    p = Plots.plot(; panel_style()..., title="$(kpi.title)\n$subtitle", ylabel="rolling − fixed ($(kpi.unit))", xlims=(0.4, 1.6), xticks=false,
                   ylims=PaddedLimits(x), legend=false, titlefontsize=10, left_margin=8Plots.mm)
    hline!(p, [0.0]; color=INK_SECONDARY, linewidth=1, linestyle=:solid, label="")
    AddBox!(p, 1, x, INK_SECONDARY; rng=rng, dot_alpha=0.35, fill_alpha=0.15)
    return p
end

function LevelsPanel(df, kpi, rng; legend)
    fixed, rolling = df[!, kpi.fixed], df[!, kpi.rolling]
    lo, hi = PaddedLimits(vcat(fixed, rolling); include_zero=false)
    legend && (hi += 0.14 * (hi - lo)) # headroom so the legend sits above the data
    p = Plots.plot(; panel_style()..., title=kpi.title, ylabel=kpi.unit, xlims=(0.4, 2.6), xticks=([1, 2], ["Fixed", "Rolling"]),
                   ylims=(lo, hi), legend=legend ? :topright : false, left_margin=8Plots.mm)
    AddBox!(p, 1, fixed, FIXED_COLOR; label="Fixed horizon", rng=rng)
    AddBox!(p, 2, rolling, ROLLING_COLOR; label="Rolling horizon", rng=rng)
    return p
end

function StatisticsTable(df)
    rows = NamedTuple[]
    for kpi in DIFFERENCE_KPIS
        push!(rows, merge((kpi=String(kpi.diff), series="rolling − fixed"), BoxStatistics(df[!, kpi.diff])))
        for (series, column) in (("fixed", kpi.fixed), ("rolling", kpi.rolling))
            push!(rows, merge((kpi=String(column), series=series), BoxStatistics(df[!, column])))
        end
    end
    return DataFrame(rows)
end

function PerformAnalysis(sweep_name::String="fixed_vs_rolling_36"; output_dir::String="results/sweep_$sweep_name/plots")
    kpis_path = "results/sweep_$sweep_name/kpis.csv"
    isfile(kpis_path) || error("no sweep results at $kpis_path")
    df = CSV.read(IOBuffer(read(kpis_path)), DataFrame) # a copy, so a sweep still appending to the file cannot hand us half a row
    nrow(df) > 0 || error("$kpis_path has no completed seeds")
    mkpath(output_dir)
    rng = MersenneTwister(1) # fixed, so the dot jitter is the same every time the plot is drawn
    n = nrow(df)
    seeds = "seeds $(minimum(df.seed))–$(maximum(df.seed))"
    key = "box: quartiles and median · whiskers: furthest point within 1.5 × IQR · dots: individual seeds · ◆: mean"

    panels = [DifferencePanel(df, kpi, rng) for kpi in DIFFERENCE_KPIS]
    differences = Plots.plot(panels...; layout=(2, 2), size=(1100, 850), background_color=SURFACE,
                             plot_title="Rolling vs fixed horizon, paired over $n wind forecast error realizations ($seeds)\n$key",
                             plot_titlefontsize=11, plot_titlefontcolor=INK, plot_titlevspan=0.09, bottom_margin=4Plots.mm)
    savefig(differences, "$output_dir/paired_differences.png")

    level_panels = [LevelsPanel(df, kpi, rng; legend=(i == 1)) for (i, kpi) in enumerate(LEVEL_KPIS)]
    levels = Plots.plot(level_panels...; layout=(1, 3), size=(1300, 520), background_color=SURFACE,
                        plot_title="KPI levels by design across $n wind forecast error realizations ($seeds)\n$key",
                        plot_titlefontsize=11, plot_titlefontcolor=INK, plot_titlevspan=0.16, bottom_margin=6Plots.mm)
    savefig(levels, "$output_dir/levels_by_design.png")

    table = StatisticsTable(df)
    CSV.write("$output_dir/boxplot_statistics.csv", table)
    println("saved box plots for $n seeds to $output_dir")
    return table
end

end;

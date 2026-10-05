using DataFrames
using XLSX

const EXCLUDED_FAMILIES = Set(["SOC", "Qg_adj", "Qd_adj"])

function auction_level_stats_excl(path::String)
    df = DataFrame(XLSX.readtable(path, "data"))
    df.non_unique = Bool.(df.non_unique)
    df = filter(r -> !(r.family in EXCLUDED_FAMILIES), df)
    grouped = combine(groupby(df, [:mtu, :market])) do sub
        (n_vars = nrow(sub), n_non_unique = count(sub.non_unique))
    end
    n_auctions = nrow(grouped)
    n_auctions_with_non_unique = count(grouped.n_non_unique .> 0)
    total_vars = sum(grouped.n_vars)
    total_non_unique = sum(grouped.n_non_unique)
    return (
        n_auctions=n_auctions,
        n_auctions_with_non_unique=n_auctions_with_non_unique,
        pct_auctions_with_non_unique=100 * n_auctions_with_non_unique / n_auctions,
        total_vars=total_vars,
        total_non_unique=total_non_unique,
        pct_vars_non_unique=100 * total_non_unique / total_vars,
        mean_non_unique_per_auction=total_non_unique / n_auctions,
    )
end

baseline_path = "../TemporalOrganizationOfShortTermElectricityMarkets/results/degeneracy_full_period_rolling_36/degeneracy/degeneracy_summary.xlsx"
tiebreak_path = "results/degeneracy_full_period_rolling_36_wind_tiebreak/degeneracy/degeneracy_summary.xlsx"

println("Families excluded: ", EXCLUDED_FAMILIES)
println()
println("=== Baseline (Wind bidPrice = 0), excl. SOC/adj ===")
println(auction_level_stats_excl(baseline_path))
println()
println("=== Wind tie-break (Wind bidPrice = 0.01), excl. SOC/adj ===")
println(auction_level_stats_excl(tiebreak_path))

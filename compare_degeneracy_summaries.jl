using DataFrames
using XLSX

function auction_level_stats(path::String)
    df = DataFrame(XLSX.readtable(path, "data"))
    df.non_unique = Bool.(df.non_unique)
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

baseline = auction_level_stats(baseline_path)
tiebreak = auction_level_stats(tiebreak_path)

println("=== Baseline (Wind bidPrice = 0 EUR/MWh, tied with Solar) ===")
println(baseline)
println()
println("=== Wind tie-break (Wind bidPrice = 0.01 EUR/MWh) ===")
println(tiebreak)
println()
println("=== Delta ===")
println("auctions with >=1 non-unique variable: $(baseline.n_auctions_with_non_unique) -> $(tiebreak.n_auctions_with_non_unique) (of $(baseline.n_auctions))")
println("total non-unique variable instances:   $(baseline.total_non_unique) -> $(tiebreak.total_non_unique) (of $(baseline.total_vars) scanned)")

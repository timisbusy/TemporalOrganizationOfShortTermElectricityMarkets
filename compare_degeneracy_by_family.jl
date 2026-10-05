using DataFrames
using XLSX

function family_stats(path::String)
    df = DataFrame(XLSX.readtable(path, "data"))
    df.non_unique = Bool.(df.non_unique)
    non_unique = filter(r -> r.non_unique, df)
    grouped = combine(groupby(non_unique, :family), nrow => :count)
    sort!(grouped, :count, rev=true)
    return grouped
end

baseline_path = "../TemporalOrganizationOfShortTermElectricityMarkets/results/degeneracy_full_period_rolling_36/degeneracy/degeneracy_summary.xlsx"
tiebreak_path = "results/degeneracy_full_period_rolling_36_wind_tiebreak/degeneracy/degeneracy_summary.xlsx"

println("=== Non-unique variable count by family: baseline ===")
println(family_stats(baseline_path))
println()
println("=== Non-unique variable count by family: wind tie-break ===")
println(family_stats(tiebreak_path))

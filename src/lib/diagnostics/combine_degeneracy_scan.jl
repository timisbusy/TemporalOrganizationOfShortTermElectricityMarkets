# Rebuilds a DegeneracyScan results folder's combined outputs from its per-auction files
# (results/{test_id}/degeneracy/degeneracy_{market}_{mtu}.xlsx). RunScan only writes
# degeneracy_summary.xlsx once, at the very end of a run, so a scan that was interrupted - or resumed
# in pieces by running RunScan again over the MTUs that were still missing, into the same test_id -
# has per-auction files but a missing or partial summary. This reads every per-auction file in the
# folder and writes the same outputs a single uninterrupted run would have: degeneracy_summary.xlsx
# (with the "failed" sheet when any solve did not reach OPTIMAL, via DegeneracyScan's own _finish!),
# the single-auction plots, and the by-auction plot.
#
# Run it after the last piece has finished - a RunScan call writes its own summary of just the MTUs it
# scanned when it ends, and a combined summary written earlier would be replaced by it. RunScan cannot
# resume into an existing test_id (it will not overwrite the profile_data_* files already there), so a
# resumed piece gets its own test_id and is passed here as extra_ids.
#
# Example:
#   include("src/lib/diagnostics/combine_degeneracy_scan.jl")
#   CombineDegeneracyScan.Combine("psb_full_scan"; extra_ids=["psb_full_scan_part2"])

module CombineDegeneracyScan

using DataFrames, XLSX

include("./degeneracy_scan.jl")
include("./plot_degeneracy_by_auction.jl")

asint(x) = x isa AbstractString ? parse(Int, x) : Int(x)
asbool(x) = x isa AbstractString ? parse(Bool, x) : Bool(x)

# (market, mtu, path) for every per-auction file in dirs, sorted by mtu then market. The same (market, mtu)
# in two folders is an error - the pieces of one scan must cover different auctions.
function PerAuctionFiles(dirs)
    files = NamedTuple{(:market, :mtu, :path),Tuple{String,Int,String}}[]
    for dir in dirs
        for f in readdir(dir)
            m = match(r"^degeneracy_(.+)_(\d+)\.xlsx$", f)
            m === nothing && continue
            push!(files, (market=String(m.captures[1]), mtu=parse(Int, m.captures[2]), path=joinpath(dir, f)))
        end
    end
    isempty(files) && throw("no degeneracy_{market}_{mtu}.xlsx files found in $(join(dirs, ", "))")
    keys = [(f.market, f.mtu) for f in files]
    length(unique(keys)) == length(keys) || throw("the same (market, MTU) has a per-auction file in more than one folder: $(join(unique(k for k in keys if count(==(k), keys) > 1), ", "))")
    return sort(files, by=f -> (f.mtu, f.market))
end

# the "data" sheet of one per-auction file, with the columns the summary and plots rely on typed
function LoadAuction(path)
    df = DataFrame(XLSX.readtable(path, "data"))
    df.mtu = asint.(df.mtu)
    df.non_unique = asbool.(df.non_unique)
    df.solve_ok = asbool.(df.solve_ok)
    return df
end

# extra_ids: further test_ids whose per-auction files belong to the same scan (e.g. the folder a resumed
# RunScan wrote into). Their files are read in; every output is written under test_id's folder.
function Combine(test_id::String; extra_ids::Vector{String}=String[], plot_auctions::Vector{Int}=DegeneracyScan.DEFAULT_PLOT_AUCTIONS, plot_by_auction::Bool=true, on_incomplete::Symbol=:warn)
    on_incomplete in (:warn, :error) || throw(ArgumentError("on_incomplete must be :warn or :error, got $on_incomplete"))
    results_dir = "results/$test_id"
    dir = "$results_dir/degeneracy"
    files = PerAuctionFiles(["results/$id/degeneracy" for id in [test_id; extra_ids]])

    summaries = DataFrame[LoadAuction(f.path) for f in files]
    columns = propertynames(first(summaries))
    for (f, df) in zip(files, summaries)
        propertynames(df) == columns || throw("$(f.path) has different columns from the first file ($columns) - it was written with different scan settings, so the files can't be combined")
    end

    mtus = sort(unique(f.mtu for f in files))
    missing_mtus = setdiff(first(mtus):last(mtus), mtus)
    isempty(missing_mtus) || @warn "$(length(missing_mtus)) MTUs between $(first(mtus)) and $(last(mtus)) have no per-auction file (first missing: $(first(missing_mtus))) - the combined summary does not cover them"
    println("Combining $(length(files)) per-auction files (MTU $(first(mtus))-$(last(mtus))) from $(join(["results/$id/degeneracy" for id in [test_id; extra_ids]], ", "))")

    # _finish! refuses to overwrite: a summary already here is the partial one a RunScan call wrote for just
    # the MTUs it scanned, which the combined one replaces
    summary_path = "$dir/degeneracy_summary.xlsx"
    if isfile(summary_path)
        println("Replacing the existing $summary_path")
        rm(summary_path)
    end
    combined = DegeneracyScan._finish!(summaries, results_dir, on_incomplete)

    DegeneracyScan._plot_auctions(results_dir, [t for t in plot_auctions if t in mtus])
    plot_by_auction && PlotDegeneracyByAuction.PerformAnalysis("$dir/degeneracy_summary.xlsx", "$results_dir/degeneracy_plots")
    return combined
end

end;

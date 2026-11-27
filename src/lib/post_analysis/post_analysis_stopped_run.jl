# High-level workbook for a run pair that stopped early (e.g. an infeasible market clearing): the runs' own
# results directories hold only Config/, the input profiles and the per-clearing RAW exports, since the end-of-run
# summaries are written only when the simulation finishes.
#
# Run(case_paths; failed_clearing):
#   1. copies each case's Config/ and top-level profile files into {output_base}/rebuilt_runs/<case slug>/
#      (the original run directories are left untouched) and rebuilds the summary files there from the RAW exports
#      (RebuildSummariesFromRaw.Rebuild, the same MarketDataStorage aggregation a finished run uses)
#   2. runs the volume-weighted price (energy), residual demand + state of charge and energy generation stack
#      analyses on the rebuilt copies over time_range (default: from_mtu to the last clearing that finished in
#      every case - MTUs after it only have not-yet-final dispatch)
#   3. writes a workbook with just the metadata tab - plus a "Note" row saying where and why the run stopped -
#      and the Plots tab (captions marked with the stop), named <cluster>_<storage>[_demand_locked]_partial.xlsx,
#      into {output_base}/high_level_results/ and a copy into collect_dir.

module PostAnalysisStoppedRun

include("./post_analysis_runner.jl")
include("./rebuild_summaries_from_raw.jl")

const R = PostAnalysisRunner
const C = R.PostAnalysisCommon
const PLOTS = [
	"weighted_price_energy/weighted_price.png" => "Volume-weighted price per MTU (energy)",
	"residual_demand_soc/residual_demand_soc.png" => "Residual demand and storage state of charge",
	"generation_stack_energy/generation_stack_energy_*.png" => "Generation and demand stack (energy)",
]

function LastClearing(case_path)
	mtus = RebuildSummariesFromRaw.ClearingMTUs(joinpath(case_path, "RAW"))
	isempty(mtus) && throw("$case_path has no RAW clearing exports")
	return last(mtus)
end

function Run(case_paths; failed_clearing::Int, cases=["Fixed Horizon", "Rolling Horizon"], from_mtu=24, time_range=nothing,
		reason="the market clearing was infeasible", collect_dir="results/high_level_excel_results",
		output_base=C.NewAnalysisOutputDir(case_paths; label=replace(C.HighLevelFileName(case_paths, cases), r"\.xlsx$" => "_stopped")))
	last_clearing = minimum(LastClearing(case_paths[c]) for c in cases)
	last_clearing < failed_clearing || throw("RAW exports run to MTU $last_clearing, not before the failed clearing at MTU $failed_clearing")
	time_range = time_range === nothing ? (from_mtu:last_clearing) : time_range

	rebuilt = Dict{String,String}()
	for case in cases
		src = case_paths[case]
		# short folder name (Windows MAX_PATH); cluster, storage and demand lock are read from the copied Config/
		dest = joinpath(output_base, "rebuilt_runs", C.CaseSlug(case))
		mkpath(dest)
		for entry in readdir(src)
			entry == "RAW" && continue
			cp(joinpath(src, entry), joinpath(dest, entry); force=true)
		end
		RebuildSummariesFromRaw.Rebuild(src; test_range=time_range, output_dir=dest)
		rebuilt[case] = dest
	end

	R.PostAnalysisWeightedPrice.PerformAnalysis(rebuilt; cases=cases, output_base=output_base, time_range=time_range)
	R.PostAnalysisResidualDemandSOC.PerformAnalysis(rebuilt; cases=cases, output_base=output_base, time_range=time_range)
	R.PostAnalysisEnergyGenerationStack.PerformAnalysis(rebuilt; cases=cases, output_base=output_base, time_range=time_range)

	stop = "run stopped at MTU $last_clearing"
	notes = [
		"Note" => "Run stopped early: $reason at MTU $failed_clearing. Results cover MTUs $(first(time_range))-$(last(time_range)) only; the last finished clearing is MTU $last_clearing.",
		"Summaries rebuilt from" => "the per-clearing RAW exports of the original run directories (copies under $output_base/rebuilt_runs)",
	]
	filename = replace(C.HighLevelFileName(case_paths, cases), r"\.xlsx$" => "_partial.xlsx")
	path = C.MergeHighLevelResults(output_base, []; case_paths=case_paths, cases=cases, time_range=time_range,
		plots=[p => "$caption ($stop)" for (p, caption) in PLOTS], filename=filename, notes=notes)
	if path !== nothing && collect_dir !== nothing
		mkpath(collect_dir)
		cp(path, joinpath(collect_dir, filename); force=true)
	end
	println("stopped-run workbook written to $path")
	return path
end

end;

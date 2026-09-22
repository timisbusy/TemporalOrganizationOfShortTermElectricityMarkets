# Row-level validation between two runs' raw per-clearing decision-variable exports
# (RAW/decisionvariables_<name>_<mtu>.xlsx) on the key indicators - agent dispatch, price, SOC,
# storage charge/discharge - that keep coming up whenever this model's output needs checking
# against another run, whether that's a rerun of this model or an external reference (e.g.
# Laura's). Previously each such check was a one-off script with its own hand-built column mapping
# and tolerance; this makes it a single reusable entry point instead.
#
# Always diffs the dispatch VALUE columns (e.g. "3G_Base"), never the Q_<agent> columns (available
# capacity/bid quantity, not what was actually dispatched) - LAURA_COLUMN_MAP only maps the value
# columns for exactly this reason.
#
# Phase 1 (this module): flag anything outside tolerance and report it. Deliberately does NOT try
# to auto-classify a flagged mismatch as an alternate-optimal-solution/LP-degeneracy artifact
# (conserved total energy + unchanged price across a short window) versus a genuine discrepancy -
# that classification was done by hand when this shipped and is left as a followup.

module PostAnalysisCrossRunValidation

using XLSX, DataFrames, Statistics

include("../post_analysis_common.jl")

# our column name -> Laura's own per-clearing decisionvariables export column name, for the key
# indicators both sides actually carry - her export has no per-agent Q_<agent>/P_<agent>/adj
# columns for demand, so only what's comparable is listed here.
const LAURA_COLUMN_MAP = Dict{String,String}(
	"price" => "price",
	"SOC" => "SOC",
	"StorageCharge" => "StorageCharge",
	"StorageDischarge" => "StorageDischarge",
	"1D_HighBid" => "Base_D",
	"2D_ModerateBid" => "Flex",
	"3G_Base" => "Base",
	"4G_Shoulder" => "Shoulder",
	"5G_Peak" => "Peak",
	"6G_Wind" => "Wind",
	"7G_Solar" => "Solar",
)

const DEFAULT_KEY_COLUMNS = ["price", "SOC", "StorageCharge", "StorageDischarge", "1D_HighBid", "2D_ModerateBid", "3G_Base", "4G_Shoulder", "5G_Peak", "6G_Wind", "7G_Solar"]

# identity map - for comparing two of this model's own runs, where both sides already use the same
# column names.
IdentityColumnMap(columns=DEFAULT_KEY_COLUMNS) = Dict(c => c for c in columns)

const DEFAULT_ABS_TOL = 1e-4
const DEFAULT_REL_TOL = 1e-6

StripTimestamp(name) = replace(name, r"^\d+_" => "")
DefaultLabel(case_path_a, case_path_b) = "$(StripTimestamp(basename(case_path_a)))_vs_$(StripTimestamp(basename(case_path_b)))"

# a run's own RAW/ subdirectory if it has one (TestExperiment.RunBasic output), else the path
# itself (an external reference export dropped directly into a flat directory, e.g. Laura's).
ResolveRawDir(case_path) = isdir(joinpath(case_path, "RAW")) ? joinpath(case_path, "RAW") : case_path

# Every "decisionvariables_<name>_<mtu>.xlsx" file's experiment name found in dir. More than one
# distinct name means the directory holds more than one experiment's exports mixed together (e.g.
# Laura's shared reference folder) - DiscoverIndexedFiles refuses to guess between them.
function DiscoverExperimentNames(dir)
	names = Set{String}()
	for f in readdir(dir)
		m = match(r"^decisionvariables_(.+)_(\d+)\.xlsx$", f)
		m === nothing && continue
		push!(names, m.captures[1])
	end
	return names
end

# mtu-of-clearing -> filepath, for one experiment's decisionvariables_<prefix>_<mtu>.xlsx files
# under case_path (or case_path/RAW). `prefix` disambiguates a directory holding more than one
# experiment's exports (see DiscoverExperimentNames) - required rather than guessed in that case,
# since a wrong guess would silently compare, say, A's mtu=12 clearing against an unrelated
# experiment's mtu=12 clearing that just happens to share the same directory.
function DiscoverIndexedFiles(case_path; prefix=nothing)
	dir = ResolveRawDir(case_path)
	if prefix === nothing
		names = DiscoverExperimentNames(dir)
		isempty(names) && throw("no decisionvariables_*.xlsx files found in $dir")
		length(names) > 1 && throw("multiple experiment names found in $dir ($(join(sort(collect(names)), ", "))) - pass `prefix` to pick one")
		prefix = only(names)
	end

	head = "decisionvariables_$(prefix)_"
	indexed = Dict{Int,String}()
	for f in readdir(dir)
		(startswith(f, head) && endswith(f, ".xlsx")) || continue
		mtu = tryparse(Int, f[length(head)+1:end-length(".xlsx")])
		mtu === nothing && continue
		indexed[mtu] = joinpath(dir, f)
	end
	return indexed
end

# Compares case_path_a against case_path_b clearing-by-clearing on column_map's key indicators.
# column_map maps a-side column name -> b-side column name (IdentityColumnMap() for two of this
# model's own runs, LAURA_COLUMN_MAP for an external reference with different column names).
# `prefix_a`/`prefix_b` are only needed when a case_path's directory holds more than one
# experiment's exports (see DiscoverIndexedFiles). A cell is flagged when its absolute difference
# exceeds BOTH abs_tol and rel_tol * max(|a|, |b|) - clearing the noise floor for both very small
# and very large indicator values (e.g. price near 0 vs. dispatch in the thousands of MWh).
function CompareRuns(case_path_a, case_path_b; prefix_a=nothing, prefix_b=nothing, column_map=IdentityColumnMap(), abs_tol=DEFAULT_ABS_TOL, rel_tol=DEFAULT_REL_TOL, label=DefaultLabel(case_path_a, case_path_b), output_base=PostAnalysisCommon.NewAnalysisOutputDir(Dict("A" => case_path_a, "B" => case_path_b); label=label))

	analysis_dir_path = "$output_base/validation"
	PostAnalysisCommon.CleanDirectory(analysis_dir_path)

	files_a = DiscoverIndexedFiles(case_path_a; prefix=prefix_a)
	files_b = DiscoverIndexedFiles(case_path_b; prefix=prefix_b)

	common = sort(collect(intersect(keys(files_a), keys(files_b))))
	n_only_a = length(setdiff(keys(files_a), keys(files_b)))
	n_only_b = length(setdiff(keys(files_b), keys(files_a)))

	isempty(common) && throw("no common clearing MTUs found between $case_path_a and $case_path_b")

	summary_stats = Dict(col_a => (n=0, sum_abs=0.0, max_abs=0.0, n_flagged=0) for col_a in keys(column_map))
	mismatches = NamedTuple[]

	needed_a = collect(keys(column_map))
	needed_b = unique(collect(values(column_map)))

	for clearing_mtu in common
		df_a = PostAnalysisCommon.LoadFile(files_a[clearing_mtu])
		df_b = PostAnalysisCommon.LoadFile(files_b[clearing_mtu])

		a_slim = rename(df_a[:, [:mtu; Symbol.(needed_a)]], [Symbol(c) => Symbol(c * "_a") for c in needed_a])
		b_slim = rename(df_b[:, [:mtu; Symbol.(needed_b)]], [Symbol(c) => Symbol(c * "_b") for c in needed_b])
		merged = innerjoin(a_slim, b_slim, on=:mtu)

		for (col_a, col_b) in column_map
			sym_a, sym_b = Symbol(col_a * "_a"), Symbol(col_b * "_b")

			vals_a = Float64.(merged[!, sym_a])
			vals_b = Float64.(merged[!, sym_b])
			diff = vals_b .- vals_a
			absdiff = abs.(diff)
			scale = max.(abs.(vals_a), abs.(vals_b))
			flagged = (absdiff .> abs_tol) .& (absdiff .> rel_tol .* scale)

			stats = summary_stats[col_a]
			summary_stats[col_a] = (
				n=stats.n + length(absdiff),
				sum_abs=stats.sum_abs + sum(absdiff),
				max_abs=max(stats.max_abs, maximum(absdiff; init=0.0)),
				n_flagged=stats.n_flagged + count(flagged),
			)

			for i in findall(flagged)
				push!(mismatches, (
					clearing_mtu=clearing_mtu, mtu=Int(merged[i, :mtu]), column=col_a,
					value_a=vals_a[i], value_b=vals_b[i], diff=diff[i],
				))
			end
		end
	end

	summary_df = sort(DataFrame([(Column=col_a, N=s.n, MaxAbsDiff=s.max_abs, MeanAbsDiff=s.n > 0 ? s.sum_abs / s.n : NaN, NFlagged=s.n_flagged) for (col_a, s) in summary_stats]), :Column)
	mismatches_df = isempty(mismatches) ? DataFrame(clearing_mtu=Int[], mtu=Int[], column=String[], value_a=Float64[], value_b=Float64[], diff=Float64[]) : DataFrame(mismatches)

	println("Compared $(length(common)) common clearing(s):")
	println("  A: $case_path_a")
	println("  B: $case_path_b")
	println("  ($n_only_a clearing(s) only in A, $n_only_b only in B)")
	println(summary_df)
	println("Flagged mismatches (abs_tol=$abs_tol, rel_tol=$rel_tol): $(nrow(mismatches_df))")

	XLSX.writetable("$analysis_dir_path/cross_run_validation.xlsx", "summary" => summary_df, "mismatches" => mismatches_df; overwrite=true)
	println("saved: $analysis_dir_path/cross_run_validation.xlsx")

	return (summary_df, mismatches_df)
end

# Convenience wrapper for the recurring "validate our run against Laura's reference export" case -
# presets LAURA_COLUMN_MAP and keeps case_path as the "A" side, so value_a/value_b in the
# mismatches sheet consistently mean "ours"/"Laura's" regardless of call-site argument order.
function CompareAgainstLaura(case_path, laura_dir, laura_prefix; kwargs...)
	return CompareRuns(case_path, laura_dir; prefix_b=laura_prefix, column_map=LAURA_COLUMN_MAP, kwargs...)
end

end;

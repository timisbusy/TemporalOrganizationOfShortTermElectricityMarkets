# Runs the SEW/economic-KPI comparison (PostAnalysisSEW) between the regular-storage and
# high-storage variants of the same Rolling 36h design - a "storage level" comparison axis,
# distinct from PostAnalysisWindowLengthRunner's "window length" axis (36h/48h/72h, storage level
# held fixed) and PostAnalysisRunner's "market design" axis (Fixed vs. Rolling Horizon, storage
# level held fixed). Mirrors PostAnalysisRunner.Run/PostAnalysisWindowLengthRunner.Run: one shared,
# never-overwritten results/post_analysis/{timestamp}_{label}/ output directory per Run call.

module PostAnalysisStorageLevelRunner

include("./post_analysis_common.jl")
include("./analyses/post_analysis_SEW.jl")

# same post-demand-transaction-fix reruns as everywhere else in this suite (see
# PostAnalysisRollingHorizonChurn/PostAnalysisStorageRevenueReconciliation's own DEFAULT_CASE_PATHS).
const DEFAULT_CASE_PATHS = Dict{String,String}(
	"Rolling 36h" => "results/1789748169_rolling_36_no_cap_1d_spinup",
	"Rolling 36h (high storage)" => "results/1789748893_rolling_36_no_cap_1d_spinup_high_storage",
)
const DEFAULT_CASES = ("Rolling 36h", "Rolling 36h (high storage)")

# strips everything but alphanumerics down to single underscores (collapsing runs, dropping a
# trailing one) - case names here have spaces/parens ("Rolling 36h (high storage)") that aren't
# filesystem-friendly, unlike the short "36h"/"48h"/"72h" labels PostAnalysisWindowLengthRunner's
# own DefaultLabel joins directly.
SanitizeForPath(s) = replace(replace(s, r"[^A-Za-z0-9]+" => "_"), r"_+$" => "")
DefaultLabel(cases) = join(SanitizeForPath.(cases), "_vs_")

function Run(case_paths=DEFAULT_CASE_PATHS; cases=DEFAULT_CASES, label=DefaultLabel(cases))
	output_base = PostAnalysisCommon.NewAnalysisOutputDir(case_paths; label=label)

	PostAnalysisSEW.PerformAnalysis(case_paths; cases=cases, output_base=output_base)

	return output_base
end

end;

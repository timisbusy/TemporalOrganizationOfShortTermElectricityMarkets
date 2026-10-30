using Test, YAML

include(joinpath(@__DIR__, "..", "src", "lib", "data_importer.jl"))
include(joinpath(@__DIR__, "..", "src", "lib", "post_analysis", "post_analysis_common.jl"))

# a minimal run directory: Config/ holds the experiment yaml (plus a market yaml, which has no
# clearForDays and must be ignored) and RAW/ holds one decisionvariables_* file per clearing
function make_run(dir; clear_for_days=31, spin_up=1, exclude_end=2, clearings=12:(clear_for_days * 24 - 36), config=true)
	mkpath(joinpath(dir, "Config"))
	mkpath(joinpath(dir, "RAW"))
	if config
		write(joinpath(dir, "Config", "a_market.yaml"), "timePeriodsPerDay: 24\nmarketSequence:\n  RollingHorizon:\n    clearingInterval: 1\n")
		write(joinpath(dir, "Config", "my_experiment.yaml"), """
			name: my_experiment
			timePeriodsPerDay: 24
			clearForDays: $clear_for_days
			samplePeriodExcludeSpinUp: $spin_up
			samplePeriodExcludeEnd: $exclude_end
			""")
	end
	for mtu in clearings
		write(joinpath(dir, "RAW", "decisionvariables_my_experiment_$mtu.xlsx"), "")
	end
	return dir
end

# runs f() and returns (result, everything it printed)
function capture_stdout(f)
	path, io = mktemp()
	result = redirect_stdout(io) do
		f()
	end
	close(io)
	return result, read(path, String)
end

@testset "DataImporter.sample_time_range" begin
	@test DataImporter.sample_time_range(24, 31, 1, 2) == 24:695
	@test DataImporter.sample_time_range(24, 34, 1, 2) == 24:767
	@test DataImporter.sample_time_range(24, 372, 3, 0) == 72:8927
	# from a raw experiment yaml dict, with the importer's defaults (2 days each end) for missing keys
	@test DataImporter.sample_time_range(Dict("timePeriodsPerDay" => 24, "clearForDays" => 10)) == 48:191
	@test DataImporter.sample_time_range(Dict("timePeriodsPerDay" => 24, "clearForDays" => 34, "samplePeriodExcludeSpinUp" => 1, "samplePeriodExcludeEnd" => 2)) == 24:767
end

@testset "PostAnalysisCommon time range" begin
	mktempdir() do root
		d31 = make_run(joinpath(root, "d31"); clear_for_days=31)
		d34 = make_run(joinpath(root, "d34"); clear_for_days=34)

		@testset "experiment config is found among the Config/ copies" begin
			@test PostAnalysisCommon.ExperimentConfigPath(d31) == joinpath(d31, "Config", "my_experiment.yaml")
			@test PostAnalysisCommon.ExperimentConfigPath(joinpath(root, "nope")) === nothing
		end

		@testset "one run's range comes from its config" begin
			@test PostAnalysisCommon.CaseTimeRange(d31) == 24:695
			@test PostAnalysisCommon.CaseTimeRange(d34) == 24:767
		end

		@testset "range is trimmed to the clearings the run actually has" begin
			stopped_early = make_run(joinpath(root, "early"); clear_for_days=31, clearings=12:600)
			@test PostAnalysisCommon.CaseTimeRange(stopped_early) == 24:600
			late_start = make_run(joinpath(root, "late"); clear_for_days=31, clearings=48:708)
			@test PostAnalysisCommon.CaseTimeRange(late_start) == 48:695
		end

		@testset "no config copy" begin
			bare = make_run(joinpath(root, "bare"); config=false)
			@test PostAnalysisCommon.CaseTimeRange(bare) === nothing
		end

		@testset "ResolveTimeRange" begin
			same_pair = Dict("Fixed Horizon" => d31, "Rolling Horizon" => d31)
			range, out = capture_stdout(() -> PostAnalysisCommon.ResolveTimeRange(nothing, same_pair))
			@test range == 24:695
			@test !occursin("warning", out)

			# differing ranges: their intersection, with a warning naming both
			mixed = Dict("Fixed Horizon" => d34, "Rolling Horizon" => d31)
			range, out = capture_stdout(() -> PostAnalysisCommon.ResolveTimeRange(nothing, mixed, ["Fixed Horizon", "Rolling Horizon"]))
			@test range == 24:695
			@test occursin("warning", out) && occursin("Fixed Horizon: 24:767", out) && occursin("Rolling Horizon: 24:695", out) && occursin("intersection", out)

			# an explicit range is used unchanged, and nothing is derived
			range, out = capture_stdout(() -> PostAnalysisCommon.ResolveTimeRange(30:40, mixed))
			@test range == 30:40
			@test out == ""

			# a run without a config copy is skipped (with a warning); the rest decide
			bare = joinpath(root, "bare")
			range, out = capture_stdout(() -> PostAnalysisCommon.ResolveTimeRange(nothing, Dict("Fixed Horizon" => bare, "Rolling Horizon" => d34), ["Fixed Horizon", "Rolling Horizon"]))
			@test range == 24:767
			@test occursin("warning", out)

			# none has a config copy: falls back to the constant
			range, out = capture_stdout(() -> PostAnalysisCommon.ResolveTimeRange(nothing, Dict("Fixed Horizon" => bare)))
			@test range == PostAnalysisCommon.DEFAULT_TIME_RANGE
			@test occursin("falling back", out)

			# ranges that don't overlap are an error, not an empty analysis
			far = make_run(joinpath(root, "far"); clear_for_days=60, spin_up=40, exclude_end=2)
			@test PostAnalysisCommon.CaseTimeRange(far) == 960:1391
			short = make_run(joinpath(root, "short"); clear_for_days=10, spin_up=1, exclude_end=2)
			@test_throws String capture_stdout(() -> PostAnalysisCommon.ResolveTimeRange(nothing, Dict("a" => far, "b" => short), ["a", "b"]))
		end

		@testset "ResolveTimeRange records the range in metadata.yaml" begin
			out_dir = joinpath(root, "analysis")
			mkpath(out_dir)
			YAML.write_file(joinpath(out_dir, "metadata.yaml"), Dict("label" => "x"))
			capture_stdout(() -> PostAnalysisCommon.ResolveTimeRange(nothing, Dict("Fixed Horizon" => d34), ["Fixed Horizon"]; output_base=out_dir))
			metadata = YAML.load_file(joinpath(out_dir, "metadata.yaml"))
			@test metadata["time_range"] == "24:767"
			@test metadata["label"] == "x"
			# also recorded when the range was passed explicitly
			PostAnalysisCommon.ResolveTimeRange(30:40, Dict("Fixed Horizon" => d34); output_base=out_dir)
			@test YAML.load_file(joinpath(out_dir, "metadata.yaml"))["time_range"] == "30:40"
			# no metadata.yaml: nothing to record into, and no error
			PostAnalysisCommon.ResolveTimeRange(30:40, Dict("Fixed Horizon" => d34); output_base=joinpath(root, "no_metadata"))
		end
	end

	@testset "DayRange" begin
		@test PostAnalysisCommon.DayRange(24:695) == 1:28
		@test PostAnalysisCommon.DayRange(24:767) == 1:31
		@test PostAnalysisCommon.DayRange(72:8831) == 3:367
	end
end

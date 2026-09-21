# Wind forecast-error-at-first-entry comparison across the 36h/48h/72h rolling-horizon
# optimizationWindow configs: for every delivered MTU in time_range, finds the earliest clearing
# that ever considered that MTU - clearingMTU = mtu - optimizationWindow + 1, clamped to the
# earliest clearing that actually ran (skipEarlyAuctions), since a natural first-entry clearing for
# an early MTU can predate the run's own start - reads Wind's own bid quantity for that MTU from
# that clearing's RAW export (Q_6G_Wind - Wind bids its full forecast availability at price 0, so
# this *is* its bid), and compares it against the true (noise-free) wind availability for that MTU,
# reconstructed from the same input CSVs via HelperInputData.GetProfileFromFiles - matching exactly
# how latest_model.jl's own process_time_series_data! builds Q_gen for wind (capacity *
# power_to_energy_scale * availability-factor-from-profile) before add_wind_forecast_noise!
# perturbs it. Forecast Error = First Bid - True Availability; reported as the signed mean (net
# over- vs under-forecasting bias), the mean absolute error (typical miss size regardless of
# direction, since a signed mean near zero can still hide large, offsetting errors), and that same
# mean absolute error normalized by each MTU's own true availability (so a given MW miss counts for
# more during low-wind hours than during high-wind hours) - all averaged over time_range. A longer
# optimizationWindow means an MTU's first-entry forecast is made further ahead of delivery, where
# HelperInputData's own anchored_forecast_std grows with lead time, so both absolute-error metrics
# are expected to grow with window length.

module PostAnalysisWindForecastError

using XLSX, DataFrames, YAML, Dates, Statistics, Latexify

include("./post_analysis_common.jl")
include("../helpers/helper_input_data.jl")

const WIND_AGENT = "6G_Wind"
const windQuantitySymbol = Symbol("Q_$WIND_AGENT")

const CASES = ["Rolling 36h", "Rolling 48h", "Rolling 72h"]

# same rolling_36/48/72_no_cap_1d_spinup triple as PostAnalysisRollingHorizonChurn's default
const DEFAULT_CASE_PATHS = Dict{String,String}(
	"Rolling 36h" => "results/1789748169_rolling_36_no_cap_1d_spinup",
	"Rolling 48h" => "results/1789748204_rolling_48_no_cap_1d_spinup",
	"Rolling 72h" => "results/1789748246_rolling_72_no_cap_1d_spinup",
)

# same "{trailing dir name, own leading timestamp stripped}, joined" convention as
# PostAnalysisCommon.DefaultAnalysisLabel, generalized to an arbitrary `cases` list.
function DefaultLabel(case_paths, cases)
	names = [replace(basename(case_paths[c]), r"^\d+_" => "") for c in cases if haskey(case_paths, c)]
	return join(names, "_vs_")
end

# scans a run's own Config/ directory (a verbatim copy of the experiment/market/agent yamls used
# for that run) and classifies each yaml by the top-level key that identifies its role, rather than
# relying on filenames (which differ per case, e.g. "rolling_48_laura.yaml" vs
# "rolling_72_laura.yaml").
function LoadCaseConfigs(case_path)
	config_dir = joinpath(case_path, "Config")
	experiment_cfg = market_cfg = agent_cfg = nothing
	for f in readdir(config_dir)
		endswith(f, ".yaml") || continue
		cfg = YAML.load_file(joinpath(config_dir, f))
		if haskey(cfg, "marketSequence")
			market_cfg = cfg
		elseif haskey(cfg, "variableGenerators")
			agent_cfg = cfg
		elseif haskey(cfg, "clearForDays")
			experiment_cfg = cfg
		end
	end
	(experiment_cfg === nothing || market_cfg === nothing || agent_cfg === nothing) &&
		throw("could not classify all of experiment/market/agent config in $config_dir")
	return (experiment_cfg, market_cfg, agent_cfg)
end

# the rolling-horizon design's own optimizationWindow (assumes a single market in the sequence -
# true for every rolling_*_no_cap_1d_spinup config this module targets)
function OptimizationWindow(market_cfg)
	first_market = first(values(market_cfg["marketSequence"]))
	return Int(first_market["optimizationWindow"])
end

# true (noise-free) wind availability per MTU, keyed by mtu - reconstructed the same way
# latest_model.jl builds Q_gen for wind before add_wind_forecast_noise! perturbs it (Q = capacity *
# power_to_energy_scale * af, af from HelperInputData.GetProfileFromFiles) - i.e. summing
# windon+windoff volumes and applying the agent config's own conversionFactor, exactly as the model
# itself does.
function TrueWindAvailability(experiment_cfg, agent_cfg)
	wind_cfg = agent_cfg["variableGenerators"][WIND_AGENT]
	capacity = Float64(wind_cfg["capacity"])
	conversion_factor = Float64(wind_cfg["conversionFactor"])
	profile_files = wind_cfg["profile_files"]
	profile_type = wind_cfg["profile_type"]

	periods_per_day = Int(experiment_cfg["timePeriodsPerDay"])
	start_date = experiment_cfg["startDate"]
	end_date = start_date + Dates.Day(Int(experiment_cfg["clearForDays"]))
	power_to_energy_scale = 24 / periods_per_day

	profile_df = HelperInputData.GetProfileFromFiles(profile_files, profile_type, start_date:end_date, periods_per_day, conversion_factor, capacity)
	true_availability = profile_df.Value .* capacity .* power_to_energy_scale
	return Dict(zip(profile_df.mtu, true_availability))
end

# earliest clearing MTU actually present in this case's RAW/ directory - the RAW filename's own
# trailing number is its Clearing MTU (see PostAnalysisCommon.DiscoverRawDispatchPrefix).
function EarliestClearingMTU(raw_dir)
	earliest = typemax(Int)
	for f in readdir(raw_dir)
		m = match(r"_(\d+)\.xlsx$", f)
		m === nothing && continue
		earliest = min(earliest, parse(Int, m.captures[1]))
	end
	earliest == typemax(Int) && throw("no decisionvariables_*.xlsx files found in $raw_dir")
	return earliest
end

# Wind's own bid quantity (Q_6G_Wind) for `mtu` as it stood in the clearing at `clearing_mtu` -
# reads (and caches, since many MTUs share the same first-entry clearing at longer lead times) the
# per-clearing RAW export.
function FirstEntryWindBid(raw_dispatch_prefix, mtu, clearing_mtu, cache::Dict{Int,DataFrame})
	df = get!(cache, clearing_mtu) do
		DataFrame(XLSX.readtable("$(raw_dispatch_prefix)$(clearing_mtu).xlsx", "data"))
	end
	return df[df.mtu.==mtu, windQuantitySymbol][1]
end

# (First-Entry Bid - True Availability) for every MTU in time_range, for one case, alongside that
# same error scaled by the MTU's own true availability (skipped, not zero-filled, for the rare MTU
# where true availability is exactly 0.0 - dividing by it would otherwise pollute the mean with
# Inf/NaN).
function CaseForecastErrors(case_path, time_range)
	(experiment_cfg, market_cfg, agent_cfg) = LoadCaseConfigs(case_path)
	optimization_window = OptimizationWindow(market_cfg)
	true_availability = TrueWindAvailability(experiment_cfg, agent_cfg)

	raw_dispatch_prefix = PostAnalysisCommon.DiscoverRawDispatchPrefix(case_path)
	earliest_clearing_mtu = EarliestClearingMTU(joinpath(case_path, "RAW"))

	cache = Dict{Int,DataFrame}()
	errors = Float64[]
	relative_abs_errors = Float64[]
	for mtu in time_range
		clearing_mtu = max(mtu - optimization_window + 1, earliest_clearing_mtu)
		bid = FirstEntryWindBid(raw_dispatch_prefix, mtu, clearing_mtu, cache)
		true_value = true_availability[mtu]
		error = bid - true_value
		push!(errors, error)
		true_value == 0.0 || push!(relative_abs_errors, abs(error) / true_value)
	end

	return (errors=errors, relative_abs_errors=relative_abs_errors)
end

function PerformAnalysis(case_paths=DEFAULT_CASE_PATHS; cases=CASES, output_base=PostAnalysisCommon.NewAnalysisOutputDir(case_paths; label=DefaultLabel(case_paths, cases)), time_range=PostAnalysisCommon.DEFAULT_TIME_RANGE)

	analysis_dir_path = "$output_base/wind_forecast_error"
	PostAnalysisCommon.CleanDirectory(analysis_dir_path)

	results_by_case = Dict(case => CaseForecastErrors(case_paths[case], time_range) for case in cases)

	# signed mean shows net bias (over- vs under-forecasting); mean absolute error shows the
	# typical size of the miss regardless of direction, since a signed mean near zero can still
	# hide large, offsetting errors; the last row expresses that same absolute miss as a % of the
	# true availability it was measured against, e.g. a 100 MWh miss matters more on a 200 MWh-true
	# hour than on a 2000 MWh-true hour - reported as a percentage so it reads at the same 2-decimal
	# precision as the other rows.
	df = DataFrame(Metric=[
		"Mean Wind Forecast Error at First Entry (MWh)",
		"Mean Absolute Wind Forecast Error at First Entry (MWh)",
		"Mean Absolute Wind Forecast Error at First Entry (% of True Availability)",
	])
	for case in cases
		r = results_by_case[case]
		df[!, Symbol(case)] = [mean(r.errors), mean(abs.(r.errors)), 100 * mean(r.relative_abs_errors)]
	end

	WriteComparisonTable(df, "$analysis_dir_path/wind_forecast_error.xlsx", "$analysis_dir_path/wind_forecast_error.tex")

	return df
end

function WriteComparisonTable(df, xlsx_path, tex_path)
	println(df)

	XLSX.writetable(xlsx_path, "data" => df; overwrite=true)

	tex = latexify(PostAnalysisCommon.EscapeForLatex(df); env=:table, booktabs=true, snakecase=true, latex=false, fmt="%.2f\n")
	write(tex_path, tex)
end

end;

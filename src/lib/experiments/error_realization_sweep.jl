# Runs a fixed-horizon and a rolling-horizon design against many wind forecast error realizations
# and records how their KPIs differ, one realization (seed) at a time.
#
# Every seed draws the wind forecast errors from the same generator the experiments already use
# (HelperInputData.generate_wind_forecast_error_scenario: AR(1) with phi 0.8, t(10) innovations,
# lead-time-anchored std at the config's noiseLevel) - only the seed changes. Both designs clear
# against the same realization, so each seed gives a paired comparison. The errors are generated in
# memory with the same sizing load_or_create_wind_forecast_error_scenario! applies (at least 792
# hours and a 72-hour window), so a seed reproduces exactly what a config with noiseSeed: <seed>
# and a fresh windNoiseScenarioPath would run.
#
# Each design is cleared with the same loop as ClearMarket.ClearSimple, minus the per-clearing
# RAW exports and the plots; KPIs come straight from the in-memory results
# (MarketDataStorage.GetEconomicIndicatorsForRange, the call PlotBaselineOutcomes makes) over the
# analysis window the config defines (samplePeriodExcludeSpinUp/End).
#
# Output, under results/sweep_{name}/:
#   kpis.csv             one row per completed seed (appended and flushed as each finishes):
#                        per-design SEW / imbalance / wind and solar curtailment, rolling - fixed
#                        differences, run time, and the number of non-OPTIMAL clearings
#   progress.log         one line per completed seed
#   batch_summaries.log  a running summary every `batch_size` seeds (the file to watch)
#   failures.log         seeds whose run threw, with the error - the sweep carries on past them
# A rerun skips seeds already in kpis.csv, so an interrupted sweep resumes where it stopped.
#
# Example:
#   include("src/lib/experiments/error_realization_sweep.jl")
#   ErrorRealizationSweep.Run("fixed_vs_rolling_36",
#       "src/configs/experiments/fixed_36_no_cap_1d_spinup.yaml",
#       "src/configs/experiments/rolling_36_no_cap_1d_spinup.yaml"; first_seed=1000, n_seeds=300)

module ErrorRealizationSweep

using Dates, DataFrames, CSV, Printf, Statistics
using JuMP
import MathOptInterface

include("../market_clearers/clear_market.jl")

const IMBALANCE_AGENTS = ("6G_Wind", "5G_Peak") # as PlotBaselineOutcomes uses

const SEW = Symbol("Socioeconomic Welfare (€)")
const IMBALANCE = Symbol("Imbalance Energy (MWh)")

# the per-design KPI columns, in kpis.csv order
const KPI_NAMES = ["sew", "imbalance", "wind_curtailed", "solar_curtailed"]

# Same sizing as HelperInputData.load_or_create_wind_forecast_error_scenario! uses when it generates a scenario.
function WindErrorsForSeed(config, simulation_hours::Int, longest_market_window::Int, seed::Int)
    total_hours = max(simulation_hours, 792)
    max_window_length = max(longest_market_window, 72)
    (errors, _) = ClearMarket.HelperInputData.generate_wind_forecast_error_scenario(total_hours, max_window_length, Float64(config[:noiseLevel]); seed=seed)
    return errors
end

# One design, loaded once: the config with its profiles resolved. Profiles do not depend on the seed.
function LoadDesign(config_file::String, sweep_id::String, label::String)
    config = ClearMarket.DataImporter.load_input_data(config_file)
    test_id = "$sweep_id/$label"
    dir = "results/$test_id"
    mkpath(dir)
    for f in readdir(dir) # addTimeseriesProfiles! will not overwrite its own earlier export
        startswith(f, "profile_data_") && rm(joinpath(dir, f))
    end
    ClearMarket.CopyConfigFiles!(config, test_id)
    profiles = Dict{String,DataFrame}()
    ClearMarket.addTimeseriesProfiles!(profiles, config, test_id)
    longest = max.([m[:optimizationWindow] + m[:lookAheadDistance] for m in config[:marketSequence]])[1]
    last_mtu = config[:clearForDays] * config[:timePeriodsPerDay] - longest
    config[:lastAuctionMTU] !== nothing && (last_mtu = min(last_mtu, config[:lastAuctionMTU]))
    return (config=config, longest=longest, time_period_range=range(0, last_mtu))
end

# Clears one design against one realization and returns its KPIs and how many clearings were not OPTIMAL.
function ClearDesign(design, seed::Int)
    config = design.config
    config[:wind_forecast_errors] = WindErrorsForSeed(config, length(design.time_period_range), design.longest, seed)

    market_sequence = ClearMarket.MarketSequence.GenerateMarketSequence(config[:marketSequence], design.time_period_range)
    marketresult = ClearMarket.MarketDataStorage.MakeMarketResultContainer()
    initialization = Dict(
        :SOC => config[:batteryStorage]["initialSOC"] * config[:batteryStorage]["energyCapacity"],
        :Q_gen => Dict{String,Float64}((g, float(gConfig["initialQuantity"])) for (g, gConfig) in config[:dispatchableGenerators]),
    )

    n_non_optimal = 0
    for t in design.time_period_range
        t < config[:skipEarlyAuctions] && continue
        for market in ClearMarket.MarketSequence.GetMarketsForMTU(market_sequence, t)
            m = ClearMarket.GetModel(config).build(t, marketresult, initialization, config, market)
            optimize!(m)
            termination_status(m) == MathOptInterface.OPTIMAL || (n_non_optimal += 1)
            ClearMarket.MarketDataStorage.AddMarketResult!(marketresult, m, t, market[:name])
        end
    end

    test_range = range(config[:timePeriodsPerDay] * config[:samplePeriodExcludeSpinUp], config[:timePeriodsPerDay] * (config[:clearForDays] - config[:samplePeriodExcludeEnd]) - 1)
    (indicators, _, _, final_dispatch_decisions, _) = ClearMarket.MarketDataStorage.GetEconomicIndicatorsForRange(marketresult, test_range; imbalance_agents=IMBALANCE_AGENTS)
    dd = final_dispatch_decisions[in.(final_dispatch_decisions.mtu, Ref(test_range)), :]
    # same definition as PostAnalysisCommon.WindCurtailed: Q_<agent> is the available capacity, so Q - dispatched is what went undispatched
    kpis = (
        sew=float(indicators[1, SEW]),
        imbalance=float(indicators[1, IMBALANCE]),
        wind_curtailed=sum(dd[!, Symbol("Q_6G_Wind")] .- dd[!, Symbol("6G_Wind")]),
        solar_curtailed=sum(dd[!, Symbol("Q_7G_Solar")] .- dd[!, Symbol("7G_Solar")]),
    )
    return (kpis=kpis, n_non_optimal=n_non_optimal)
end

function KpiRow(seed, fixed, rolling, run_seconds)
    row = Pair{Symbol,Any}[:seed => seed, :completed_at => Dates.format(now(), "yyyy-mm-dd HH:MM:SS"), :run_seconds => round(run_seconds, digits=1)]
    for (label, result) in (("fixed", fixed), ("rolling", rolling))
        for k in KPI_NAMES
            push!(row, Symbol("$(label)_$k") => getproperty(result.kpis, Symbol(k)))
        end
        push!(row, Symbol("$(label)_non_optimal") => result.n_non_optimal)
    end
    for k in KPI_NAMES
        push!(row, Symbol("d_$k") => getproperty(rolling.kpis, Symbol(k)) - getproperty(fixed.kpis, Symbol(k)))
    end
    push!(row, :d_sew_pct => 100 * (rolling.kpis.sew - fixed.kpis.sew) / abs(fixed.kpis.sew))
    return (; row...)
end

# The path form with append=true: CSV.write to an already-open stream rewrote the file from its start on the second call.
function AppendRow(path, row)
    exists = isfile(path)
    CSV.write(path, [row]; append=exists, writeheader=!exists)
end

function LogLine(path, line)
    println(line)
    open(path, "a") do io
        println(io, line)
        flush(io)
    end
end

StdErr(x) = length(x) > 1 ? std(x) / sqrt(length(x)) : NaN

# "mean ± standard error" of rolling - fixed over the given rows of kpis.csv
function DiffSummary(df, col, fmt)
    x = df[!, col]
    return Printf.format(Printf.Format(fmt * " ± " * replace(fmt, "+" => "")), mean(x), StdErr(x))
end

function BatchSummary(df, batch_seeds, n_total, batch_number, n_batches)
    last_batch = df[in.(df.seed, Ref(batch_seeds)), :]
    lines = String[]
    push!(lines, "[batch $batch_number/$n_batches] seeds $(first(batch_seeds))-$(last(batch_seeds)) done - $(nrow(df))/$n_total completed")
    push!(lines, "  rolling - fixed, mean ± s.e. over all $(nrow(df)) seeds:  SEW $(DiffSummary(df, :d_sew, "%+.0f")) € ($(DiffSummary(df, :d_sew_pct, "%+.3f")) %);  wind curtailed $(DiffSummary(df, :d_wind_curtailed, "%+.0f")) MWh;  solar curtailed $(DiffSummary(df, :d_solar_curtailed, "%+.0f")) MWh;  imbalance $(DiffSummary(df, :d_imbalance, "%+.0f")) MWh")
    push!(lines, "  rolling has higher SEW in $(count(>(0), df.d_sew))/$(nrow(df)) seeds;  less wind curtailment in $(count(<(0), df.d_wind_curtailed))/$(nrow(df));  less imbalance in $(count(<(0), df.d_imbalance))/$(nrow(df))")
    push!(lines, @sprintf("  this batch (n=%d) mean:  SEW %+.0f €;  wind curtailed %+.0f MWh;  solar curtailed %+.0f MWh;  imbalance %+.0f MWh", nrow(last_batch), mean(last_batch.d_sew), mean(last_batch.d_wind_curtailed), mean(last_batch.d_solar_curtailed), mean(last_batch.d_imbalance)))
    bad = count(r -> r.fixed_non_optimal > 0 || r.rolling_non_optimal > 0, eachrow(df))
    bad > 0 && push!(lines, "  note: $bad seed(s) had clearings that were not OPTIMAL (fixed_non_optimal / rolling_non_optimal in kpis.csv)")
    return join(lines, "\n")
end

function Run(name::String, fixed_config::String, rolling_config::String; first_seed::Int=1000, n_seeds::Int=300, batch_size::Int=5)
    sweep_id = "sweep_$name"
    out_dir = "results/$sweep_id"
    mkpath(out_dir)
    kpis_path = "$out_dir/kpis.csv"
    progress_log, batch_log, failure_log = "$out_dir/progress.log", "$out_dir/batch_summaries.log", "$out_dir/failures.log"

    fixed = LoadDesign(fixed_config, sweep_id, "fixed")
    rolling = LoadDesign(rolling_config, sweep_id, "rolling")
    fixed.config[:noiseLevel] == rolling.config[:noiseLevel] || error("the two configs have different noiseLevel - the designs would not see comparable errors")

    seeds = collect(first_seed:(first_seed + n_seeds - 1))
    if isfile(kpis_path)
        existing = CSV.read(kpis_path, DataFrame)
        hasproperty(existing, :seed) || error("$kpis_path has no seed column - the file is malformed; move it aside before resuming")
        done = Set(existing.seed)
    else
        done = Set{Int}()
    end
    pending = [s for s in seeds if !(s in done)]
    LogLine(progress_log, "sweep $name: $(length(done)) of $n_seeds seeds already in kpis.csv, $(length(pending)) to run (seeds $first_seed-$(first_seed + n_seeds - 1))")

    n_batches = cld(n_seeds, batch_size)
    for seed in pending
        started = time()
        try
            fixed_result = ClearDesign(fixed, seed)
            rolling_result = ClearDesign(rolling, seed)
            row = KpiRow(seed, fixed_result, rolling_result, time() - started)
            AppendRow(kpis_path, row)
            LogLine(progress_log, @sprintf("seed %d done in %.1f min:  rolling - fixed  SEW %+.0f € (%+.3f %%),  wind curtailed %+.0f MWh,  solar curtailed %+.0f MWh,  imbalance %+.0f MWh", seed, row.run_seconds / 60, row.d_sew, row.d_sew_pct, row.d_wind_curtailed, row.d_solar_curtailed, row.d_imbalance))
        catch e
            LogLine(failure_log, "seed $seed failed after $(round((time() - started) / 60, digits=1)) min: $(sprint(showerror, e))")
            continue
        end
        GC.gc()

        df = CSV.read(kpis_path, DataFrame)
        completed = Set(df.seed)
        completed_in_order = [s for s in seeds if s in completed]
        if nrow(df) % batch_size == 0 || seed == last(pending)
            batch_seeds = completed_in_order[max(1, end - batch_size + 1):end]
            LogLine(batch_log, BatchSummary(df, batch_seeds, n_seeds, cld(nrow(df), batch_size), n_batches))
        end
    end
    println("sweep $name finished: results in $out_dir")
    return CSV.read(kpis_path, DataFrame)
end

end;

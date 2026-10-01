module DegeneracyScan

# Standalone diagnostic: for selected MTUs, checks how many decision variables in
# LatestMarketModel's LP have alternate optimal values (i.e. other feasible values
# that leave the welfare-maximizing objective unchanged) - a measure of primal
# degeneracy / non-unique optima, not to be confused with SAObjLow/SAObjUp
# (objective-coefficient ranging), which answers a different question.
#
# This replays a full config's clearing sequence (since each clearing depends on
# previously-dispatched quantities/SOC via MarketDataStorage) but only pays the
# extra min/max-per-variable solves at the MTUs the caller asks about, and stops
# once past the last requested MTU. It is intentionally kept out of ClearMarket's
# own loop so normal experiment runs pay nothing for this diagnostic.
#
# target_mtus can be an explicit collection of MTUs (e.g. one day's worth, the
# original/default use of this tool), or the symbol :full_period to scan the whole
# analyzed simulation window instead - see _resolve_target_mtus. A full-period scan
# is far more expensive (potentially hundreds of thousands of extra solves), so the
# analysis sweep for each target MTU runs in a background worker pool decoupled
# from the sequential replay - see "Parallel analysis" below and RunScan's docstring.

using JuMP
using MathOptInterface
using DataFrames
using XLSX
using Base.Threads: nthreads, @spawn

include("../market_clearers/clear_market.jl")

const MOI = MathOptInterface

# Splits a JuMP-generated variable name like "Qg[7G_Solar,372]" or "SOC[372]" into
# its (family, asset, mtu) parts, so non-unique variables can be grouped by
# generator/demand segment and by which part of the optimization window they fall
# in. `asset` is `missing` for variables indexed only by MTU (e.g. storage).
function _parse_variable_name(v::String)
    mtch = match(r"^([A-Za-z_]+)\[(.+)\]$", v)
    mtch === nothing && return (family=v, asset=missing, mtu=missing)
    family = mtch.captures[1]
    parts = split(mtch.captures[2], ",")
    if length(parts) == 2
        return (family=family, asset=String(parts[1]), mtu=parse(Int, parts[2]))
    else
        return (family=family, asset=missing, mtu=parse(Int, parts[1]))
    end
end

# Re-solves `m` (already optimized) minimizing and then maximizing each decision
# variable in turn, subject to the objective staying within `obj_tol` of its
# optimal value, to find the width of the range of optimal values each variable
# can take. Must be called after anything that needs m's original optimal values
# (e.g. MarketDataStorage.AddMarketResult!) has already read them, since it
# repeatedly reassigns the model's objective and re-solves. Each `m` is only ever
# analyzed by one caller (see "Parallel analysis" below), so this itself needs no
# locking - the concurrency hazard lives one level up, in the shared outputs
# _analyze_and_write! writes into.
function AnalyzeAlternateOptima(m::Model; obj_tol::Float64=1e-6, value_tol::Float64=0.01, exclude_prefixes::Vector{String}=String[])
    original_obj = objective_function(m)
    original_sense = objective_sense(m)
    z_star = objective_value(m)

    # Pin the feasible region to solutions within obj_tol of the optimum. The
    # model's own constraints already enforce the other side of this bound at
    # optimality (nothing can beat z_star), so only one direction is needed here.
    pin = if original_sense == MOI.MAX_SENSE
        @constraint(m, original_obj >= z_star - obj_tol)
    else
        @constraint(m, original_obj <= z_star + obj_tol)
    end

    rows = NamedTuple[]
    for x in all_variables(m)
        any(p -> startswith(name(x), p), exclude_prefixes) && continue

        @objective(m, Min, x)
        optimize!(m)
        lo = termination_status(m) == MOI.OPTIMAL ? value(x) : NaN

        @objective(m, Max, x)
        optimize!(m)
        hi = termination_status(m) == MOI.OPTIMAL ? value(x) : NaN

        width = hi - lo
        vname = name(x)
        parsed = _parse_variable_name(vname)
        push!(rows, (variable=vname, family=parsed.family, asset=parsed.asset, var_mtu=parsed.mtu, lo=lo, hi=hi, width=width, non_unique=width > value_tol))
    end

    delete(m, pin)
    set_objective_function(m, original_obj)
    set_objective_sense(m, original_sense)

    return DataFrame(rows)
end

# Breaks down the non-unique (width > value_tol) rows of an AnalyzeAlternateOptima
# result by variable family (Qg, Qg_adj, Qd, Qch, Qdis, SOC, ...) and, where the
# family is indexed by asset (generator/demand segment), by asset too - along with
# the MTU range within the optimization window where each shows up and, for
# family-level rows, the widest single range found.
function SummarizeDegeneracy(df::DataFrame)
    non_unique_rows = filter(r -> r.non_unique, df)

    family_rows = NamedTuple[]
    for fam in unique(non_unique_rows.family)
        sub = filter(r -> r.family == fam, non_unique_rows)
        push!(family_rows, (
            family=fam,
            count=nrow(sub),
            min_mtu=minimum(sub.var_mtu),
            max_mtu=maximum(sub.var_mtu),
            max_width=maximum(sub.width),
        ))
    end
    family_summary = isempty(family_rows) ? DataFrame(family=String[], count=Int[], min_mtu=Int[], max_mtu=Int[], max_width=Float64[]) : DataFrame(family_rows)
    sort!(family_summary, :count, rev=true)

    asset_rows = NamedTuple[]
    for r in eachrow(filter(r -> !ismissing(r.asset), non_unique_rows))
        push!(asset_rows, (family=r.family, asset=r.asset, mtu=r.var_mtu, width=r.width))
    end
    asset_detail = isempty(asset_rows) ? DataFrame(family=String[], asset=String[], mtu=Int[], width=Float64[]) : DataFrame(asset_rows)

    asset_summary_rows = NamedTuple[]
    for (fam, asset) in unique(zip(asset_detail.family, asset_detail.asset))
        sub = filter(r -> r.family == fam && r.asset == asset, asset_detail)
        push!(asset_summary_rows, (
            family=fam,
            asset=asset,
            count=nrow(sub),
            min_mtu=minimum(sub.mtu),
            max_mtu=maximum(sub.mtu),
            max_width=maximum(sub.width),
        ))
    end
    asset_summary = isempty(asset_summary_rows) ? DataFrame(family=String[], asset=String[], count=Int[], min_mtu=Int[], max_mtu=Int[], max_width=Float64[]) : DataFrame(asset_summary_rows)
    sort!(asset_summary, :count, rev=true)

    return (family_summary=family_summary, asset_summary=asset_summary)
end

# ---- Full-period target_mtus resolution ----

# Resolves target_mtus === :full_period into the same "analyzed window" convention used
# elsewhere in this codebase for trimming spin-up/tail transients (ClearSimple's and
# ClearMarketComparisonForConfig's own `test_range` in clear_market.jl): everything from
# samplePeriodExcludeSpinUp days in, up to samplePeriodExcludeEnd days before the end. Any
# other target_mtus value (an explicit range/vector/set, the tool's original usage) passes
# through unchanged. No extra clamping is needed here: both last_mtu_simulation
# (data-availability bound) and skipEarlyAuctions are already enforced by RunScan/
# RunComparisonScan's own loop regardless of how target_mtus was produced.
function _resolve_target_mtus(target_mtus, config)
    target_mtus !== :full_period && return target_mtus
    return range(
        config[:timePeriodsPerDay] * config[:samplePeriodExcludeSpinUp],
        config[:timePeriodsPerDay] * (config[:clearForDays] - config[:samplePeriodExcludeEnd]) - 1,
    )
end

_resolve_solver(config) = haskey(config, :optimizationModelConfig) && haskey(config[:optimizationModelConfig], "solver") ? lowercase(String(config[:optimizationModelConfig]["solver"])) : "gurobi"

# ---- Parallel analysis ----
#
# The sequential replay (build -> optimize! -> MarketDataStorage.AddMarketResult!) stays
# single-threaded and strictly MTU-ordered, since ramp-rate/SOC continuity depends on it.
# But the expensive per-target-MTU analysis (AnalyzeAlternateOptima's ~2x-decision-variable
# extra solves) only depends on that MTU's own already-solved model, never on any other
# target MTU's analysis - so it runs in a pool of max_workers background tasks, fed by a
# bounded Channel the sequential loop pushes into. The bounded channel capacity gives
# backpressure "for free": once it's full, the sequential loop's put! blocks until a worker
# frees a slot, so in-flight solved models stay bounded instead of piling up unboundedly in
# memory across a large scan.

struct _AnalysisJob
    m::Model
    market_name::String
    t::Int
end

mutable struct _Progress
    total::Int
    completed::Int
    start_time::Float64
    report_every::Int
end
_make_progress(total::Int) = _Progress(total, 0, time(), max(1, total ÷ 20))

# Must be called while already holding the caller's lock - mutates shared `p.completed`.
function _report_progress!(p::_Progress)
    p.completed += 1
    (p.completed % p.report_every == 0 || p.completed == p.total) || return
    elapsed = time() - p.start_time
    rate = p.completed / elapsed
    eta_min = rate > 0 ? (p.total - p.completed) / rate / 60 : NaN
    println(">>> progress: $(p.completed)/$(p.total) auctions analyzed, elapsed $(round(elapsed / 60, digits=1))m, ETA $(round(eta_min, digits=1))m")
end

function _default_max_workers(solver::String)
    return solver == "highs" ? max(1, nthreads() - 1) : 1
end

function _warn_concurrency_setup(max_workers::Int, solver::String)
    if max_workers > 1 && nthreads() == 1
        @warn "max_workers=$max_workers but Julia has only 1 thread available (Threads.nthreads()==1) - the analysis pool will run with no real parallelism regardless. Start Julia with `-t N` (or register a multi-threaded Jupyter kernel via IJulia.installkernel with JULIA_NUM_THREADS set, then pick that kernel) to get real parallelism - this can't be changed after the process starts."
    end
    if max_workers > 1 && solver == "gurobi"
        @warn "max_workers=$max_workers with solver=\"gurobi\": every Gurobi model in this process shares one Gurobi.Env() (latest_model.jl's `gurobi_env`). Concurrent-solve thread-safety and license concurrent-session limits for this setup are unverified - run a small smoke test before trusting a multi-worker Gurobi scan, or use solver=\"highs\" (license-free, independent per-model instances) for real parallelism."
    end
    return nothing
end

# Counts how many (market) analysis jobs target_mtus will schedule, without building or
# solving any models - pure MarketSequence table lookups - so progress reporting has an
# accurate denominator from the start of the run rather than one that grows as jobs are
# discovered. `markets_at_time(t)` mirrors whatever the caller's own loop uses to look up
# the scheduled markets for MTU t (RunScan: one sequence; RunComparisonScan: summed across
# the selected market designs).
function _count_scheduled_jobs(markets_at_time, time_period_range, target_mtus, skip_early_auctions::Int, max_target::Int)
    total = 0
    for t in time_period_range
        t > max_target && break
        t < skip_early_auctions && continue
        t in target_mtus || continue
        total += length(markets_at_time(t))
    end
    return total
end

function _analyze_and_write!(summaries, summaries_lock, progress, m, market_name, t, results_dir, obj_tol, value_tol, exclude_prefixes, write_per_auction_files)
    df = AnalyzeAlternateOptima(m; obj_tol=obj_tol, value_tol=value_tol, exclude_prefixes=exclude_prefixes)
    df.mtu .= t
    df.market .= market_name
    (family_summary, asset_summary) = SummarizeDegeneracy(df)

    if write_per_auction_files
        XLSX.writetable(
            "$results_dir/degeneracy/degeneracy_$(market_name)_$(t).xlsx",
            "data" => df, "by_family" => family_summary, "by_asset" => asset_summary,
        )
    end

    # Bundles the shared summaries push with this job's progress/log lines under one lock -
    # all three are fast relative to the LP sweep above (which runs unlocked, so workers
    # overlap on the expensive part), and keeping them together means concurrent workers'
    # log output can't interleave mid-block.
    lock(summaries_lock) do
        push!(summaries, df)
        n_non_unique = count(df.non_unique)
        println("Analyzed alternate optima for $market_name at MTU $t: $n_non_unique / $(nrow(df)) variables are non-unique (value_tol=$value_tol)")
        for r in eachrow(family_summary)
            println("     $(r.family): $(r.count) (MTU $(r.min_mtu)-$(r.max_mtu), widest=$(round(r.max_width, digits=2)))")
        end
        _report_progress!(progress)
    end
    return df
end

function _analysis_worker(jobs, summaries, summaries_lock, progress, results_dir, obj_tol, value_tol, exclude_prefixes, write_per_auction_files)
    for job in jobs
        _analyze_and_write!(summaries, summaries_lock, progress, job.m, job.market_name, job.t, results_dir, obj_tol, value_tol, exclude_prefixes, write_per_auction_files)
    end
end

function _finish!(summaries, results_dir)
    combined = isempty(summaries) ? DataFrame() : vcat(summaries...)
    if !isempty(combined)
        XLSX.writetable("$results_dir/degeneracy/degeneracy_summary.xlsx", "data" => combined)
    end
    return combined
end

# For a single-market-design config (config[:marketSequence]), scan the given MTUs
# (integers, matching the `t` values already used in RAW/*.xlsx filenames) - or pass
# target_mtus=:full_period to scan the whole analyzed simulation window instead of a
# hand-picked sample (see _resolve_target_mtus).
#
# A full-period scan can mean hundreds of thousands of extra solves, so the analysis sweep
# for each target MTU (not the sequential replay, which must stay single-threaded) runs in
# a pool of `max_workers` background tasks - see "Parallel analysis" above. This only gives
# real parallelism if Julia itself was started with more than one thread (`julia -t N`, or a
# multi-threaded Jupyter kernel - see _warn_concurrency_setup). `solver="highs"` is
# recommended for any multi-worker run: every Gurobi model in this process shares one
# Gurobi.Env(), and Gurobi's concurrent-solve safety/license concurrency limits under that
# are unverified (see _warn_concurrency_setup); HiGHS has no such shared state and is what
# this tool's own one-day-sample investigation already used.
#
# Before trusting a large scan, validate the parallel path on a small, known sample first:
#   1. max_workers=1 vs. a pre-refactor sequential run over the same MTUs/config/solver -
#      compare degeneracy_summary.xlsx row-for-row (sorted by mtu, market, variable) for
#      exact agreement. This validates the refactor's plumbing independent of concurrency.
#   2. max_workers=1 vs. max_workers>1, same sample, same pinned solver - the sequential
#      replay (and so the exact models being analyzed) is unaffected by max_workers, so the
#      two summaries should match exactly, not just approximately.
#   3. A short smoke run (e.g. the first few days of :full_period, not the whole thing) at
#      the intended max_workers, to sanity-check wall-clock time and memory before
#      committing to the full scan.
#
# Example:
#   DegeneracyScan.RunScan(
#       "src/configs/experiments/rolling_36_no_cap_1d_spinup.yaml", "full_period_scan",
#       :full_period; solver="highs", max_workers=4, exclude_prefixes=["Qd_adj["],
#   )
function RunScan(config_file::String, test_id::String, target_mtus; obj_tol::Float64=1e-6, value_tol::Float64=0.01, solver::Union{Nothing,String}=nothing, exclude_prefixes::Vector{String}=String[], max_workers::Union{Nothing,Int}=nothing, queue_multiplier::Int=2, write_per_auction_files::Bool=true)
    config = ClearMarket.DataImporter.load_input_data(config_file)
    if solver !== nothing
        config[:optimizationModelConfig] = get(config, :optimizationModelConfig, Dict{String,Any}())
        config[:optimizationModelConfig]["solver"] = solver
    end
    resolved_solver = _resolve_solver(config)
    max_workers = something(max_workers, _default_max_workers(resolved_solver))
    _warn_concurrency_setup(max_workers, resolved_solver)
    write_per_auction_files || @warn "write_per_auction_files=false: per-auction .xlsx files will not be written for this run - PlotDegeneracySingleAuction will have nothing to read. degeneracy_summary.xlsx (and the other plot modules, which read only that file) are unaffected."

    target_mtus = Set(_resolve_target_mtus(target_mtus, config))
    results_dir = "results/$test_id"
    mkpath("$results_dir/degeneracy")
    ClearMarket.CopyConfigFiles!(config, test_id)

    longest_market_window = max.([mkt[:optimizationWindow] + mkt[:lookAheadDistance] for mkt in config[:marketSequence]])[1]
    last_mtu_simulation = config[:clearForDays] * config[:timePeriodsPerDay] - longest_market_window
    if config[:lastAuctionMTU] !== nothing
        last_mtu_simulation = min(last_mtu_simulation, config[:lastAuctionMTU])
    end
    time_period_range = range(0, last_mtu_simulation)

    marketSequence = ClearMarket.MarketSequence.GenerateMarketSequence(config[:marketSequence], time_period_range)
    marketresult = ClearMarket.MarketDataStorage.MakeMarketResultContainer()
    initialization = Dict(
        :SOC => config[:batteryStorage]["initialSOC"] * config[:batteryStorage]["energyCapacity"],
        :Q_gen => Dict{String,Float64}((g, float(gConfig["initialQuantity"])) for (g, gConfig) in config[:dispatchableGenerators])
    )

    if !haskey(config, :wind_noise_scenario_path)
        config[:wind_noise_scenario_path] = "input_data/laura/wind_forecast_error_shared_final_20260502.csv"
    end
    config[:wind_forecast_errors] = ClearMarket.HelperInputData.load_or_create_wind_forecast_error_scenario!(config, config[:noiseLevel], length(time_period_range), longest_market_window)

    variableGeneratorProfiles = Dict{String,DataFrame}()
    ClearMarket.addTimeseriesProfiles!(variableGeneratorProfiles, config, test_id)

    max_target = maximum(target_mtus)
    total_jobs = _count_scheduled_jobs(t -> ClearMarket.MarketSequence.GetMarketsForMTU(marketSequence, t), time_period_range, target_mtus, config[:skipEarlyAuctions], max_target)

    summaries = DataFrame[]
    summaries_lock = ReentrantLock()
    progress = _make_progress(total_jobs)
    jobs = Channel{_AnalysisJob}(max(1, queue_multiplier * max_workers))
    worker_tasks = [@spawn _analysis_worker(jobs, summaries, summaries_lock, progress, results_dir, obj_tol, value_tol, exclude_prefixes, write_per_auction_files) for _ in 1:max_workers]

    for t in time_period_range
        t > max_target && break
        if t < config[:skipEarlyAuctions]
            continue
        end
        marketsAtTime = ClearMarket.MarketSequence.GetMarketsForMTU(marketSequence, t)
        for market in marketsAtTime
            modelModule = ClearMarket.GetModel(config)
            m = modelModule.build(t, marketresult, initialization, config, market)
            optimize!(m)
            ClearMarket.MarketDataStorage.AddMarketResult!(marketresult, m, t, market[:name])

            if t in target_mtus
                put!(jobs, _AnalysisJob(m, market[:name], t))
            end
        end
    end

    close(jobs)
    foreach(fetch, worker_tasks)

    return _finish!(summaries, results_dir)
end

# For a comparison config (config[:marketSequences], i.e. `compare: market`), scan the given
# MTUs across the named market designs (defaults to all of them) - or target_mtus=:full_period
# for the whole analyzed simulation window (see _resolve_target_mtus). Same parallel-analysis
# design, keyword set, and pre-large-scan validation checklist as RunScan - see its docstring.
function RunComparisonScan(config_file::String, test_id::String, target_mtus; market_names=nothing, obj_tol::Float64=1e-6, value_tol::Float64=0.01, exclude_prefixes::Vector{String}=String[], max_workers::Union{Nothing,Int}=nothing, queue_multiplier::Int=2, write_per_auction_files::Bool=true)
    config = ClearMarket.DataImporter.load_input_data(config_file)
    resolved_solver = _resolve_solver(config)
    max_workers = something(max_workers, _default_max_workers(resolved_solver))
    _warn_concurrency_setup(max_workers, resolved_solver)
    write_per_auction_files || @warn "write_per_auction_files=false: per-auction .xlsx files will not be written for this run - PlotDegeneracySingleAuction will have nothing to read. degeneracy_summary.xlsx (and the other plot modules, which read only that file) are unaffected."

    target_mtus = Set(_resolve_target_mtus(target_mtus, config))
    results_dir = "results/$test_id"
    mkpath("$results_dir/degeneracy")
    ClearMarket.CopyConfigFiles!(config, test_id)

    selected_names = market_names === nothing ? collect(keys(config[:marketSequences])) : market_names

    allWindows = [mkt[:optimizationWindow] + mkt[:lookAheadDistance] for (n, ms) in config[:marketSequences] for mkt in ms]
    longest_market_window = max.(allWindows)[1]
    last_mtu_simulation = config[:clearForDays] * config[:timePeriodsPerDay] - longest_market_window
    if config[:lastAuctionMTU] !== nothing
        last_mtu_simulation = min(last_mtu_simulation, config[:lastAuctionMTU])
    end
    time_period_range = range(0, last_mtu_simulation)

    marketSequences = Dict{String,Any}()
    marketResults = Dict{String,ClearMarket.MarketDataStorage.MarketResultContainer}()
    for market_name in selected_names
        marketSequences[market_name] = ClearMarket.MarketSequence.GenerateMarketSequence(config[:marketSequences][market_name], time_period_range)
        marketResults[market_name] = ClearMarket.MarketDataStorage.MakeMarketResultContainer()
    end

    initialization = Dict(
        :SOC => config[:batteryStorage]["initialSOC"] * config[:batteryStorage]["energyCapacity"],
        :Q_gen => Dict{String,Float64}((g, float(gConfig["initialQuantity"])) for (g, gConfig) in config[:dispatchableGenerators])
    )

    if !haskey(config, :wind_noise_scenario_path)
        config[:wind_noise_scenario_path] = "input_data/laura/wind_forecast_error_shared_final_20260502.csv"
    end
    config[:wind_forecast_errors] = ClearMarket.HelperInputData.load_or_create_wind_forecast_error_scenario!(config, config[:noiseLevel], length(time_period_range), longest_market_window)

    variableGeneratorProfiles = Dict{String,DataFrame}()
    ClearMarket.addTimeseriesProfiles!(variableGeneratorProfiles, config, test_id)

    max_target = maximum(target_mtus)
    total_jobs = _count_scheduled_jobs(
        t -> sum(length(ClearMarket.MarketSequence.GetMarketsForMTU(marketSequences[name], t)) for name in selected_names),
        time_period_range, target_mtus, config[:skipEarlyAuctions], max_target,
    )

    summaries = DataFrame[]
    summaries_lock = ReentrantLock()
    progress = _make_progress(total_jobs)
    jobs = Channel{_AnalysisJob}(max(1, queue_multiplier * max_workers))
    worker_tasks = [@spawn _analysis_worker(jobs, summaries, summaries_lock, progress, results_dir, obj_tol, value_tol, exclude_prefixes, write_per_auction_files) for _ in 1:max_workers]

    for t in time_period_range
        t > max_target && break
        if t < config[:skipEarlyAuctions]
            continue
        end
        for market_name in selected_names
            marketsAtTime = ClearMarket.MarketSequence.GetMarketsForMTU(marketSequences[market_name], t)
            for market in marketsAtTime
                modelModule = ClearMarket.GetModel(config)
                m = modelModule.build(t, marketResults[market_name], initialization, config, market)
                optimize!(m)
                ClearMarket.MarketDataStorage.AddMarketResult!(marketResults[market_name], m, t, market[:name])

                if t in target_mtus
                    put!(jobs, _AnalysisJob(m, "$(market_name)_$(market[:name])", t))
                end
            end
        end
    end

    close(jobs)
    foreach(fetch, worker_tasks)

    return _finish!(summaries, results_dir)
end

end;

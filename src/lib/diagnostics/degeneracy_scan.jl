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

using JuMP
using MathOptInterface
using DataFrames
using XLSX

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
# repeatedly reassigns the model's objective and re-solves.
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

function _analyze_and_write!(summaries, m, market_name, t, results_dir, obj_tol, value_tol, exclude_prefixes)
    println("Analyzing alternate optima for $market_name at MTU $t ...")
    df = AnalyzeAlternateOptima(m; obj_tol=obj_tol, value_tol=value_tol, exclude_prefixes=exclude_prefixes)
    df.mtu .= t
    df.market .= market_name
    push!(summaries, df)

    (family_summary, asset_summary) = SummarizeDegeneracy(df)
    XLSX.writetable(
        "$results_dir/degeneracy/degeneracy_$(market_name)_$(t).xlsx",
        "data" => df, "by_family" => family_summary, "by_asset" => asset_summary,
    )

    n_non_unique = count(df.non_unique)
    println("  -> $n_non_unique / $(nrow(df)) variables are non-unique (value_tol=$value_tol)")
    for r in eachrow(family_summary)
        println("     $(r.family): $(r.count) (MTU $(r.min_mtu)-$(r.max_mtu), widest=$(round(r.max_width, digits=2)))")
    end
    return df
end

function _finish!(summaries, results_dir)
    combined = isempty(summaries) ? DataFrame() : vcat(summaries...)
    if !isempty(combined)
        XLSX.writetable("$results_dir/degeneracy/degeneracy_summary.xlsx", "data" => combined)
    end
    return combined
end

# For a single-market-design config (config[:marketSequence]), scan the given
# MTUs (integers, matching the `t` values already used in RAW/*.xlsx filenames).
function RunScan(config_file::String, test_id::String, target_mtus; obj_tol::Float64=1e-6, value_tol::Float64=0.01, solver::Union{Nothing,String}=nothing, exclude_prefixes::Vector{String}=String[])
    target_mtus = Set(target_mtus)
    config = ClearMarket.DataImporter.load_input_data(config_file)
    if solver !== nothing
        config[:optimizationModelConfig] = get(config, :optimizationModelConfig, Dict{String,Any}())
        config[:optimizationModelConfig]["solver"] = solver
    end
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

    summaries = DataFrame[]
    max_target = maximum(target_mtus)

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
                _analyze_and_write!(summaries, m, market[:name], t, results_dir, obj_tol, value_tol, exclude_prefixes)
            end
        end
    end

    return _finish!(summaries, results_dir)
end

# For a comparison config (config[:marketSequences], i.e. `compare: market`),
# scan the given MTUs across the named market designs (defaults to all of them).
function RunComparisonScan(config_file::String, test_id::String, target_mtus; market_names=nothing, obj_tol::Float64=1e-6, value_tol::Float64=0.01, exclude_prefixes::Vector{String}=String[])
    target_mtus = Set(target_mtus)
    config = ClearMarket.DataImporter.load_input_data(config_file)
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

    summaries = DataFrame[]
    max_target = maximum(target_mtus)

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
                    _analyze_and_write!(summaries, m, "$(market_name)_$(market[:name])", t, results_dir, obj_tol, value_tol, exclude_prefixes)
                end
            end
        end
    end

    return _finish!(summaries, results_dir)
end

end;

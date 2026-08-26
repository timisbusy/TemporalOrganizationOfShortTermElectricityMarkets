module LatestMarketModel

using JuMP
using HiGHS
using Gurobi

using ..Helpers.MarketDataStorage

include("../helpers/helper_input_data.jl")

const gurobi_env = Gurobi.Env()

# NOTE: THIS IS A COPY OF THE FLEXIBLE MODEL with explicit handling for adjustment market periods (those for which a dispatch has already been made)

	# Step 2a: create lists for the variables (sets) - note the !, we are modifying the model.

#=
    Why do we create sets here?
    1. They are attached to the model via the ext (extension) dictionary.
    2. They are (actually not) then used in step 2a as collections to iterate through in order to add even more to the model via m.ext for all of the timeseries data for bids over time.
    3. They are used to create variables in the creation of the clearing model itself (Step 3).
=#

# m, time_period, marketresults, initialization, data, market
function define_sets!(m::Model, time_period::Int, marketresults, initialization::Dict{Symbol,Any}, data::Dict{Symbol,Any}, market::Dict{Symbol,Any})
    # Store all sets in a dedicated dictionary attached to the model
    m.ext[:sets] = Dict{Symbol,Any}()

    disp_gen = data[:dispatchableGenerators]
    var_gen  = data[:variableGenerators]
    dem      = data[:demandSegments]

    marketStart = time_period + market[:lookAheadDistance] 
    marketEnd = marketStart + market[:optimizationWindow] - 1

    m.ext[:sets][:power_to_energy_scale] = 24 / data[:timePeriodsPerDay] # hours per day / time periods per day = time periods per hour

    m.ext[:sets][:OW] = marketStart : marketEnd   # periods for this optimization window

    # generators IG = list of all generator names (dispatchable + variable)
    IG = String[]
    DG = String[] # dispatchable generators only
    VG = String[] # variable generators only, for accounting ex-post
    for g in keys(disp_gen) # ["Base", "Peak"]
        push!(IG, String(g))
        push!(DG, String(g))
    end
    m.ext[:sets][:DG] = DG
    for g in keys(var_gen) # ["Wind"]
        push!(IG, String(g))
        push!(VG, String(g))
    end
    m.ext[:sets][:IG] = IG
    m.ext[:sets][:VG] = VG

    # demand segments ID = list of all demand segment names (Base, Flex)
    ID = String[]
    for d in keys(dem) # ["Base", "Flex"]
        push!(ID, String(d))
    end
    m.ext[:sets][:ID] = ID

    return m
end

# Step 2b: process time-series data (turn YAML parameters into hourly prices/quantities)
function process_time_series_data!(m::Model, time_period::Int, marketresults, initialization::Dict{Symbol,Any}, data::Dict{Symbol,Any}, market::Dict{Symbol,Any})
    disp_gen = data[:dispatchableGenerators]
    var      = data[:variableGenerators]
    dem      = data[:demandSegments]
    
    OW = m.ext[:sets][:OW] # OW, the optimization window is the set of MTUs for this market clearing

    # generator prices P_gen and maximum quantities per time period Q_gen[g,t]
    # stored as dictionaries keyed by (generator, time period)
    Pr_gen = Dict{Tuple{String,Int},Float64}()  # marginal cost / bid price
    Q_gen  = Dict{Tuple{String,Int},Float64}()  # available capacity per time period
    Q_prev_gen  = Dict{Tuple{String,Int},Float64}()  # capacity dispatched in earlier markets

    # dispatchable generators: one price and one capacity, repeated every time period
    for (gname, gdata_any) in disp_gen
        g = String(gname)
        P = float(gdata_any["bidPrice"])   # constant bid price P [EUR/MWh]
        Q = float(gdata_any["capacity"] * m.ext[:sets][:power_to_energy_scale])   # constant capacity Q [MWh/mtu]

        for t in OW
            Pr_gen[(g,t)] = P
            Q_gen[(g,t)]  = Q
            Q_prev_gen[(g,t)] = MarketDataStorage.GenPreviousDispatchDataForTimePeriod(marketresults, g, t)
        end
    end

    # variable generators (e.g. Wind): price is constant, quantity follows a profile
    for (gname, gdata_any) in var
        g = String(gname)
        P = float(gdata_any["bidPrice"])   # bid price (often 0 or negative)
        Q = float(gdata_any["capacity"])   # installed capacity [MW]
        profile_df = gdata_any["profile"] # availability factors per hour
        # profile = [float(x) for x in profile_any]

        # This block modifies the capacity with the availability factor (profile) from the config
        for t in OW
            # profileMTU = (t % length(profile)) + 1 # modulo operator here makes af below repeat the input profile to fill +1 b/c these are not zero indexed
            af = profile_df[profile_df.mtu .== t,Symbol("Value")][1,1]                # availability factor in hour profileH
            Pr_gen[(g,t)] = P
            Q_gen[(g,t)]  = Q * m.ext[:sets][:power_to_energy_scale] * af         # available capacity = Q * profile[t]
            Q_prev_gen[(g,t)] = MarketDataStorage.GenPreviousDispatchDataForTimePeriod(marketresults, g, t)
        end
    end

    offset =  data[:windOffset]

    # adding forecast noise to all variable generators
    if true 
        for (gname, gdata_any) in var
            if occursin("Wind", gname)
                if gdata_any["capacity"] > 0.0
                    HelperInputData.add_wind_forecast_noise!(
                        Q_gen,
                        gname,
                        Float64(var[gname]["capacity"]),
                        OW,
                        time_period,
                        offset;
                        precomputed_errors=data[:wind_forecast_errors],
                    )
                end
            end
        end
    end


    # demand side: prices Pr_dem and maximum quantities Q_dem[d,h]
    Pr_dem = Dict{Tuple{String,Int},Float64}()  # willingness to pay
    Q_dem  = Dict{Tuple{String,Int},Float64}()  # max demand per segment and hour
    Q_prev_dem  = Dict{Tuple{String,Int},Float64}()  # demand dispatched in earlier markets per segment and hour

    # each demand segment has one bid price and quantity profile with per mtu data
    for (dname, ddata_any) in dem
        d = String(dname)
        P = float(ddata_any["bidPrice"])        # value of demand segment [EUR/MWh]
        profile_df = ddata_any["profile"]         # mtu max quantity
        # q_vec = [float(x) for x in q_any]

        for t in OW
            # demandMTU = (t % length(q_vec)) + 1 # modulo here repeats the data in the demand quantity input over the requested days +1 b/c these are not zero index
            Pr_dem[(d,t)] = P
            Q_dem[(d,t)]  = profile_df[profile_df.mtu .== t,Symbol("Value")][1,1] .* m.ext[:sets][:power_to_energy_scale] 
            Q_prev_dem[(d,t)] = MarketDataStorage.DemPreviousDispatchDataForTimePeriod(marketresults, d, t)
        end
    end

    # store all time series in the model extension for later use
    m.ext[:timeseries] = Dict{Symbol,Any}()
    m.ext[:timeseries][:Pr_gen] = Pr_gen
    m.ext[:timeseries][:Q_gen]  = Q_gen
    m.ext[:timeseries][:Q_prev_gen]  = Q_prev_gen
    m.ext[:timeseries][:Pr_dem] = Pr_dem
    m.ext[:timeseries][:Q_dem]  = Q_dem
    m.ext[:timeseries][:Q_prev_dem]  = Q_prev_dem

    return m
end


# Step 2c: scalar parameters AKA add storage, at least for now. How will this change when storage actually bids as a market player? Likely they belong in the above bids, but they're more complex, b/c for example they can't charge and discharge at the same time.
# This also needs to be adjusted to consider previously dispatched quantities, right?

function process_parameters!(m::Model, time_period::Int, marketresults, initialization::Dict{Symbol,Any}, data::Dict{Symbol,Any}, market::Dict{Symbol,Any})
    
    m.ext[:parameters] = Dict{Symbol,Any}()

    # Store storage parameters
    if data[:batteryStorage] !== nothing
        storage = data[:batteryStorage]
        m.ext[:parameters][:storage_energy_capacity] = float(storage["energyCapacity"])
        m.ext[:parameters][:storage_power_capacity] = float(storage["powerCapacity"])
        m.ext[:parameters][:storage_efficiency] = float(storage["efficiency"])
        (previous_SOC_at_mtu, has_previous) = MarketDataStorage.StorageSOCForTimePeriod(marketresults, m.ext[:sets][:OW][1] - 1)
        start_SOC = has_previous ? previous_SOC_at_mtu : initialization[:SOC]
        m.ext[:parameters][:storage_initial_soc] = start_SOC #the current understanding of the SOC in the period prior to this one - either from initialization or from the latest dispatch information
        

        m.ext[:parameters][:storage_end_soc] = float(storage["endSOC"]) * float(storage["energyCapacity"])

        m.ext[:parameters][:has_storage] = true
    else
        m.ext[:parameters][:has_storage] = false
    end

    m.ext[:parameters][:ramp_rate] = Dict{String,Float64}()
    m.ext[:parameters][:previous_time_period_dispatch] = Dict{String,Float64}()
    time_period_minutes = 24*60 / data[:timePeriodsPerDay] # minutes per day / mtu per day = minutes/mtu
    for (g, gen_config) in data[:dispatchableGenerators]
        # ramp rate in MWh per mtu
        ramp_as_decimal = gen_config["rampRate"] *.01 # % of power capacity per minute to decimal portion
        ramp_per_mtu = ramp_as_decimal * time_period_minutes # portion of power capacity per MTU
        capacity_in_energy_per_time_unit = gen_config["capacity"] * m.ext[:sets][:power_to_energy_scale]
        # println("ramps: ", g, float(min(ramp_per_mtu * capacity_in_energy_per_time_unit, capacity_in_energy_per_time_unit)))
        m.ext[:parameters][:ramp_rate][g] = float(min(ramp_per_mtu * capacity_in_energy_per_time_unit, capacity_in_energy_per_time_unit))
        
        (prev_mtu_dispatch, has_prev_mtu_dispatch) = MarketDataStorage.DecisionVariableValueForTimePeriod(marketresults, g, m.ext[:sets][:OW][1] - 1) 
        prev_mtu_dispatch = has_prev_mtu_dispatch == true ? prev_mtu_dispatch : initialization[:Q_gen][g] * m.ext[:sets][:power_to_energy_scale]
        m.ext[:parameters][:previous_time_period_dispatch][g] = prev_mtu_dispatch
    end

    m.ext[:data_storage] = Dict{Symbol,Any}()
    m.ext[:data_storage][:ex_post_transactions] = haskey(data, :optimizationModelConfig) && data[:optimizationModelConfig]["ex_post_transactions"] == true
    
    return m
end

# Step 3: build market-clearing model
# initialise dictionaries for variables and constraints
function build_market_clearing!(m::Model, time_period::Int, marketresults, initialization::Dict{Symbol,Any}, data::Dict{Symbol,Any}, market::Dict{Symbol,Any})
    m.ext[:variables]   = Dict{Symbol,Any}()
    m.ext[:constraints] = Dict{Symbol,Any}()

    # load sets and time series from previous steps
    OW = m.ext[:sets][:OW] # the optimization window - set of all MTUs to include in this market clearing
    IG = m.ext[:sets][:IG] # set of all generators, including VRES
    DG = m.ext[:sets][:DG] # set of only dispatchable generators, for additional constraints
    ID = m.ext[:sets][:ID]

    Pr_gen = m.ext[:timeseries][:Pr_gen]
    Q_gen  = m.ext[:timeseries][:Q_gen]
    Qg_prev  = m.ext[:timeseries][:Q_prev_gen]
    Pr_dem = m.ext[:timeseries][:Pr_dem]
    Q_dem  = m.ext[:timeseries][:Q_dem]
    Qd_prev  = m.ext[:timeseries][:Q_prev_dem]

    # decision variables:
    # Qg[g,t] = dispatched generation of unit g in mtu t [MWh]
    # Qd[d,t] = served demand of segment d in mtu t [MWh]
    Qd = m.ext[:variables][:Qd] = @variable(m, Qd[d in ID, t in OW] >= 0)
    Qg = m.ext[:variables][:Qg] = @variable(m, Qg[g in IG, t in OW] >= 0)

    # adjustment variables are equal to total dispatch (Qd/Qg) - previous dispatch (Qd_prev/Qg_prev)
    Qd_adj = m.ext[:variables][:Qd_adj] = @variable(m, Qd_adj[d in ID, t in OW])
    Qg_adj = m.ext[:variables][:Qg_adj] = @variable(m, Qg_adj[g in IG, t in OW])

    # Storage variables
    has_storage = m.ext[:parameters][:has_storage]
    if has_storage
        E_cap = m.ext[:parameters][:storage_energy_capacity]
        P_cap = m.ext[:parameters][:storage_power_capacity]
        η = m.ext[:parameters][:storage_efficiency]
        
        # Qch[t] = charge energy in  time period t [MWh]
        # Qdis[t] = discharge energy in  time period t [MWh]
        # SOC[t] = state of charge at end of  time period t [MWh]
        Qch = m.ext[:variables][:Qch] = @variable(m, 0 <= Qch[t in OW] <= P_cap * m.ext[:sets][:power_to_energy_scale])
        Qdis = m.ext[:variables][:Qdis] = @variable(m, 0 <= Qdis[t in OW] <= P_cap * m.ext[:sets][:power_to_energy_scale])
        SOC = m.ext[:variables][:SOC] = @variable(m, 0 <= SOC[t in OW] <= E_cap)
        SOC_init = m.ext[:parameters][:storage_initial_soc]
    end


    if haskey(data, :optimizationModelConfig) && data[:optimizationModelConfig]["demand_adjust"] == true
        # define adjustment quantities explicitly - note that Qd_prev/Qg_prev are set to 0.0 for any MTUs that have not yet been dispatched, so this becomes Qd_adj == Qd and Qg_adj == Qg
        m.ext[:constraints][:demand_adjustments] = @constraint(
                m, [t in OW, d in ID],
                Qd_adj[d,t] == Qd[d,t] - Qd_prev[d,t]
            )
    end

    m.ext[:constraints][:gen_adjustments] = @constraint(
            m, [t in OW, g in IG],
            Qg_adj[g,t] == Qg[g,t] - Qg_prev[g,t]
        )


    
    # generator adjustment limits: generation adjustment cannot exceed available capacity Q_gen[g,t] - Qg_prev[g,t] or go below - Qg_prev[g,t]
    m.ext[:constraints][:gen_adj_limits] = @constraint(
        m, [g in IG, t in OW],
        -Qg_prev[g,t] <= Qg_adj[g,t] <= Q_gen[(String(g),t)] - Qg_prev[g,t]
    )
    
    # gen limits: generation cannot exceed maximum quantity Q_gen[g,t]
    m.ext[:constraints][:gen_limits] = @constraint(
        m, [g in IG, t in OW],
        Qg[g,t] <= Q_gen[(String(g),t)]
    )


    if haskey(data, :optimizationModelConfig) && data[:optimizationModelConfig]["demand_adjust"] == true
        
        # demand limits: served demand cannot exceed maximum quantity Q_dem[d,t]
        # demand adjustment limits: demand adjustment cannot exceed maximum bid Q_dem[d,t] - Qd_prev[d,t] or go below - Qd_prev[d,t]
        m.ext[:constraints][:dem_adj_limits] = @constraint(
            m, [d in ID, t in OW],
            -Qd_prev[d,t] <= Qd_adj[d,t] <= Q_dem[(String(d),t)] - Qd_prev[d,t]
        )
    end
    # demand limits: served demand cannot exceed maximum quantity Q_dem[d,t]
    m.ext[:constraints][:dem_limits] = @constraint(
        m, [d in ID, t in OW],
        Qd[d,t] <= Q_dem[(String(d),t)]
    )

    # energy balance: in each  time period, total generation equals total served demand
    #if storage, add storage charging/discharging
    if has_storage
        m.ext[:constraints][:energy_balance] = @constraint(
            m, [t in OW],
            sum(Qg[g,t] for g in IG) + Qdis[t] - Qch[t] - sum(Qd[d,t] for d in ID) == 0
        )
    else
        m.ext[:constraints][:energy_balance] = @constraint(
            m, [t in OW],
            sum(Qg[g,t] for g in IG) - sum(Qd[d,t] for d in ID) == 0
        )
    end

    start_at_period = m.ext[:sets][:OW][1]
    # Storage constraints
    if has_storage
        η = m.ext[:parameters][:storage_efficiency]
        
        # State of charge dynamics: SOC[t] = SOC[t-1] + η*Qch[t] - Qdis[t]/η
        # For first hour t=start_at_period, use initial SOC
        #  feed forward the SOC result from the previous round

        # println(SOC_init)
        @constraint(m, SOC[start_at_period] == SOC_init + η * (Qch[start_at_period]) - (Qdis[start_at_period]) / η)
        
        # interperiod constraints for hours 2+
        for t in range(start_at_period + 1, OW.stop)
            @constraint(m, SOC[t] == SOC[t-1] + η * (Qch[t]) - (Qdis[t]) / η)
        end
        
        # Cyclic constraint: end at a specific SOC

        # @constraint(m, SOC[OW.stop] == m.ext[:parameters][:storage_end_soc])

    end

    # using DG here so this only applies to the dispatchable gens

    if market[:enforceRampRates]

        m.ext[:constraints][:ramp_limits_up_first] = @constraint(
            m, [g in DG, t in range(OW[1],OW[1])], # for the first hour
            Qg[g,t] <= m.ext[:parameters][:previous_time_period_dispatch][g] + m.ext[:parameters][:ramp_rate][g]
        )

        m.ext[:constraints][:ramp_limits_down_first] = @constraint(
            m, [g in DG, t in range(OW[1],OW[1])], # for the first hour
            Qg[g,t] >= m.ext[:parameters][:previous_time_period_dispatch][g] - m.ext[:parameters][:ramp_rate][g]
        )

        m.ext[:constraints][:ramp_limits_up] = @constraint(
            m, [g in DG, t in OW[2:end] ], # start with the second hour
            Qg[g,t] <= Qg[g,t-1] + m.ext[:parameters][:ramp_rate][g]
        )

        m.ext[:constraints][:ramp_limits_down] = @constraint(
            m, [g in DG, t in OW[2:end] ], # start with the second hour
             Qg[g,t] >= Qg[g,t-1] - m.ext[:parameters][:ramp_rate][g]
        )


    end

    if haskey(data, :optimizationModelConfig) && data[:optimizationModelConfig]["restrict_mtu1_trading"] == true && !market[:overrideMTU1Restriction]
        
        # TAtoLLD Change 1: replicate Laura's limit on trading for base/shoulder in the first MTU 
        if length(marketresults.Results) != 0 && time_period == start_at_period
            for g in ["3G_Base", "4G_Shoulder"]
                @constraint(m, Qg_adj[g,start_at_period] == 0)
            end
        end
    end


    m.ext[:objective] = @objective(m, Max,
        sum(Pr_dem[(String(d),t)] * Qd[d,t] for d in ID, t in OW) -
        sum(Pr_gen[(String(g),t)] * Qg[g,t] for g in IG, t in OW)
    )



    return m
end

# build and run the market clearing given the provided market and system information

# time_period - time period in which we are clearing
# resultset - results of previous clearings
# initialization - initial values from config for SOC, generator/demand dispatch
# data - information about assets - prices, availability factors, etc
# market - defines when the window for which this market clears and the market name

DEFAULT_SOLVER = "gurobi"

# solver is chosen via data[:optimizationModelConfig]["solver"] ("gurobi" or "highs"), defaulting to DEFAULT_SOLVER
function select_optimizer(data::Dict{Symbol,Any})
    solver = haskey(data, :optimizationModelConfig) && haskey(data[:optimizationModelConfig], "solver") ? lowercase(String(data[:optimizationModelConfig]["solver"])) : DEFAULT_SOLVER

    if solver == "gurobi"
        return () -> Gurobi.Optimizer(gurobi_env)
    elseif solver == "highs"
        return HiGHS.Optimizer
    else
        throw("unknown solver \"$solver\" in optimizationModelConfig - supported solvers are \"gurobi\" and \"highs\"")
    end
end

function build(time_period, marketresults, initialization, data, market)

	# create the optimisation model with the configured solver (default Gurobi)

    m = Model(select_optimizer(data))
    set_silent(m)
	# build the sets, time series and parameters based on the inputs
	define_sets!(m, time_period, marketresults, initialization, data, market)
	process_time_series_data!(m, time_period, marketresults, initialization, data, market)
	process_parameters!(m, time_period, marketresults, initialization, data, market)

	# create variables, constraints and objective, then solve
	build_market_clearing!(m, time_period, marketresults, initialization, data, market)

	return m
end

end;
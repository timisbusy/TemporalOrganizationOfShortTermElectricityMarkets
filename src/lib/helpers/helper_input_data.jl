module HelperInputData

using CSV, DataFrames, Dates, XLSX

# adds noise to the input Q_gen_window for generator g from first_time_period to last_time_period. constrained by total_capacity and with magnitude noise_std

function add_noise!(Q_gen_window, g, total_capacity, noise_std, first_time_period, last_time_period)
	lineardecay = true # todo: make this configurable
	# note: we could have some different strategies here

	for t in first_time_period:last_time_period
        # Current forecast (availability factor)
        current_af = Q_gen_window[(g, t)] / total_capacity
        
        decayfactor = 0
        if lineardecay
            decayfactor = ((t - first_time_period)/(last_time_period-first_time_period)) # 0 for first time period, 1 for last, linear in between
        end
        # Add Gaussian noise
        noise = randn() * noise_std * decayfactor * current_af # last factor makes this proportional
        new_af = clamp(current_af + noise, 0.0, 1.0) # constraint 0 => total_capacity
        
        Q_gen_window[(g, t)] = total_capacity * new_af
    end
end



function add_noise_pre!(input_profile, noise_std, first_time_period, last_time_period)
    lineardecay = false # todo: make this configurable
    expdecay = true
    # note: we could have some different strategies here
    last_noise = 0.0
    for t in first_time_period:last_time_period
        # Current forecast (availability factor)
        to_update = ( t % length(input_profile) ) + 1 # it's 1 indexed
        current_af = input_profile[to_update]
        
        decayfactor = 0
        if lineardecay
            decayfactor = ((t - first_time_period)/(last_time_period-first_time_period)) # 0 for first time period, 1 for last, linear in between
        end
        if expdecay
           decayfactor = (.95*(1 - .04)^t) + .05 # trying some test values for the exponential decay
        end
        if decayfactor < 0 || decayfactor > 1 || isnan(decayfactor)
            println("decay factor out of range", decayfactor, t, first_time_period, last_time_period)
        end
        # Add Gaussian noise
        noise = randn() * noise_std
        noise_update = last_noise == 0.0 ? noise : .9*last_noise + .1*noise # IIR approach, if zero, set it to this value because we are starting up
        last_noise = noise_update
        new_af = clamp(current_af + (noise_update  * decayfactor * current_af), 0.0, 1.0) # constraint 0 => 1 # current_af factor makes this proportiona
        if isnan(new_af)
            println("is nan ", noise, new_af)
            new_af = 0.0
        end
        input_profile[to_update] = new_af
    end
    println(input_profile[200])
    return input_profile
end

# this is from Laura, modified to meet my usage


function validate_wind_forecast_error_coverage(forecast_errors::AbstractDict{Tuple{Int, Int}, Float64},
                                               simulation_hours::Int,
                                               max_window_length::Int)
    simulation_hours >= 1 || error("simulation_hours must be >= 1")
    max_window_length >= 1 || error("max_window_length must be >= 1")

    missing_examples = Tuple{Int, Int}[]
    missing_count = 0

    for window_start_hour in 1:simulation_hours
        for lead_time in 1:max_window_length
            abs_hour = window_start_hour + lead_time - 1
            if !haskey(forecast_errors, (window_start_hour, abs_hour))
                missing_count += 1
                if length(missing_examples) < 5
                    push!(missing_examples, (window_start_hour, abs_hour))
                end
            end
        end
    end

    if missing_count > 0
        example_str = join(["($(window_start_hour), $(abs_hour))" for (window_start_hour, abs_hour) in missing_examples], ", ")
        error("Wind forecast error scenario is missing $missing_count required (window_start_hour, abs_hour) pairs; first missing examples: $example_str")
    end

    return nothing
end

function wind_forecast_error_rows_from_csv(scenario_path::AbstractString)
    isfile(scenario_path) || error("Scenario file not found: $scenario_path")

    df = CSV.read(scenario_path, DataFrame)
    required_cols = [:window_start_hour, :abs_hour, :lead_time, :forecast_error]
    for col in required_cols
        hasproperty(df, col) || error("Scenario CSV missing required column: $(String(col))")
    end

    if !hasproperty(df, :raw_draw)
        df.raw_draw = zeros(Float64, nrow(df))
    end
    if !hasproperty(df, :z_value)
        df.z_value = zeros(Float64, nrow(df))
    end
    if !hasproperty(df, :std_dev)
        df.std_dev = zeros(Float64, nrow(df))
    end

    forecast_errors = Dict{Tuple{Int, Int}, Float64}()
    for row in eachrow(df)
        window_start_hour = Int(row.window_start_hour)
        abs_hour = Int(row.abs_hour)
        lead_time = Int(row.lead_time)
        lead_time == abs_hour - window_start_hour + 1 || error("Inconsistent lead_time in scenario CSV for ($window_start_hour, $abs_hour)")
        haskey(forecast_errors, (window_start_hour, abs_hour)) && error("Duplicate scenario CSV row for ($window_start_hour, $abs_hour)")
        forecast_errors[(window_start_hour, abs_hour)] = Float64(row.forecast_error)
    end

    return forecast_errors, maximum(df.window_start_hour), maximum(df.abs_hour)
end

function load_or_create_wind_forecast_error_scenario!(cfg::Dict, max_noise_std::Float64, simulation_hours::Int, max_window_length::Int)
    scenario_path = cfg[:wind_noise_scenario_path]
    noise_seed = 20260325
    scenario_total_hours = max(simulation_hours, 792)
    scenario_max_window_length = max(max_window_length, 72)
    required_abs_hour = scenario_total_hours + scenario_max_window_length

    if isfile(scenario_path)
        endswith(lowercase(scenario_path), ".csv") || error("Predefined wind forecast error scenario must be a CSV file: $scenario_path")
        forecast_errors, stored_max_window_start, stored_max_abs_hour = wind_forecast_error_rows_from_csv(scenario_path)
        if stored_max_window_start < scenario_total_hours || stored_max_abs_hour < required_abs_hour
            error("Wind forecast error scenario file is too small for this run. Increase wind_noise_total_hours or wind_noise_max_look_ahead and regenerate: $scenario_path")
        end
        validate_wind_forecast_error_coverage(forecast_errors, scenario_total_hours, scenario_max_window_length)
        return forecast_errors
    end

    throw("only allowing loaded file for wind noise creation for now")
    #=
    forecast_errors, rows = generate_wind_forecast_error_scenario(scenario_total_hours, scenario_max_window_length, max_noise_std; seed=noise_seed)
    endswith(lowercase(scenario_path), ".csv") || error("Predefined wind forecast error scenario must be a CSV file: $scenario_path")
    write_wind_forecast_error_rows_csv(scenario_path, rows)
    validate_wind_forecast_error_coverage(forecast_errors, scenario_total_hours, scenario_max_window_length)
    return forecast_errors
    =#
end

function add_wind_forecast_noise!(Q_gen::Dict, gen::String, max_capacity::Float64, optimization_window::UnitRange{Int}, current_mtu::Int; precomputed_errors::Union{Nothing, Dict{Tuple{Int, Int}, Float64}}=nothing)


    precomputed_errors === nothing && error("precomputed_errors is required when wind forecast noise is enabled")


    for mtu in optimization_window
        # note modifications here to align input data with LLD's implementation
        offset = 11
        if current_mtu < offset + 1 || mtu < offset + 1
            continue
        end

        haskey(precomputed_errors, (current_mtu - offset, mtu - offset)) || error("Missing precomputed wind forecast error for ($(current_mtu), $(mtu))")
        new_error = precomputed_errors[(current_mtu - offset, mtu - offset)]

        current_value = Q_gen[(gen, mtu)]
        current_af = current_value / max_capacity
        new_af = clamp(current_af * (1 + new_error), 0.0, 1.0)
        Q_gen[(gen, mtu)] = max_capacity * new_af
    end

end


function ImportDataFromFile(filepath)
    println("importing: $(filepath)")
    if endswith(filepath, "csv")
        return ImportDataFromCSV(filepath)
    elseif endswith(filepath, "xlsx")
        return ImportDataFromXLSX(filepath)
    else
        throw("unrecognized input file: $filepath")
    end 
end


function ImportDataFromCSV(filepath)
    println("importing: $(filepath)")
    
    data = DataFrame(CSV.File(filepath,dateformat="y-mm-dd H:M:S"))
    return data
end

function ImportDataFromXLSX(filepath)

    xf = XLSX.readxlsx(filepath)
    
    println(XLSX.sheetnames(xf))
    # data = DataFrame(XLSX.File(filepath,dateformat="y-mm-dd H:M:S"))
    # println(data)
    throw("not ready to import xlsx data yet: $filepath")
end

# we assume we are using NED.nl data, with known fields and hourly data 
# field allows us to extract the data we need (sometimes "percentage", sometimes "volume (kWh)")
# periodsPerDay allows for extrapolation/expansion of data to meet expectations of caller

function GetProfileFromFile(filepath, field, dateRange, periodsPerDay)
    if periodsPerDay % 24 != 0
        throw("invalid number of periods per day: $periodsPerDay - should be a multiple of 24")
    end
    data = ImportDataFromFile(filepath)
    hourly_profile_data = data[(dateRange.start .<= data[!,"validfrom (UTC)"] .< dateRange.stop), :][:,field]
    
    periods_per_hour = (periodsPerDay/24)

    #=
    # using simple repeat pattern here
    expanded_profile_data = Float64[]
    for hourly_datum in hourly_profile_data
        for i in 1:periods_per_hour
            push!(expanded_profile_data,hourly_datum)
        end
    end
    =#

    # if we did a linear interpolation
    # it would be better if we grabbed the following time period as well - should be doable

    linear_interpolation_data = Float64[]
    for (hour,hourly_datum) in enumerate(hourly_profile_data)
        next_hour_datum = ( (hour + 1) > length(hourly_profile_data) ) ? hourly_datum : hourly_profile_data[hour+1]
        for i in 0:(periods_per_hour - 1)
            t_shift = i/periods_per_hour
            new_point = hourly_datum + t_shift*(next_hour_datum-hourly_datum)
            push!(linear_interpolation_data,new_point)
        end
    end

    return linear_interpolation_data
end

end;
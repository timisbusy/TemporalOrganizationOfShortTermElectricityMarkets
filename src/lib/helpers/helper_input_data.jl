module HelperInputData

using CSV, DataFrames, Dates, XLSX, Distributions, Random

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



const phi = 0.8  # AR(1) autocorrelation coefficient for wind forecast errors, 0.0 errors are independent, 0.8 is strong correlation (recommended for wind)


function anchored_forecast_std(lead_time::Int, max_noise_std::Float64)
    lead_time <= 1 && return 0.0

    # Preserve the existing 36h behavior exactly on 1..36h:
    # std = max_noise_std * sqrt((lead_time - 1) / 35)
    # Then extend the curve with anchored square-root growth so that
    # equal absolute lead times imply equal forecast uncertainty
    # across all look-ahead cases.
    anchor_hours = [1, 36, 48, 72]
    anchor_stds = [
        0.0,
        max_noise_std,
        max_noise_std + 0.05,
        max_noise_std + 0.10,
    ]

    if lead_time <= anchor_hours[2]
        return anchor_stds[2] * sqrt((lead_time - 1) / (anchor_hours[2] - 1))
    end

    if lead_time >= anchor_hours[end]
        return anchor_stds[end]
    end

    for idx in 2:(length(anchor_hours) - 1)
        h1 = anchor_hours[idx]
        h2 = anchor_hours[idx + 1]
        s1 = anchor_stds[idx]
        s2 = anchor_stds[idx + 1]

        if h1 < lead_time <= h2
            frac = (lead_time - h1) / (h2 - h1)
            curved_frac = sqrt(frac)
            return s1 + (s2 - s1) * curved_frac
        end
    end

    return anchor_stds[end]
end


function generate_wind_forecast_error_scenario(simulation_hours::Int, max_window_length::Int, max_noise_std::Float64; seed::Int=20260325, df::Int=10)
    simulation_hours >= 1 || error("simulation_hours must be >= 1")
    max_window_length >= 1 || error("max_window_length must be >= 1")
    max_noise_std >= 0.0 || error("max_noise_std must be >= 0")

    rng = MersenneTwister(seed)
    t_dist = TDist(df)
    forecast_errors = Dict{Tuple{Int, Int}, Float64}()
    rows = DataFrame(
        window_start_hour=Int[],
        abs_hour=Int[],
        lead_time=Int[],
        raw_draw=Float64[],
        z_value=Float64[],
        std_dev=Float64[],
        forecast_error=Float64[],
    )

    max_abs_hour = simulation_hours + max_window_length
    for abs_hour in 1:max_abs_hour
        z_prev = 0.0
        earliest_window_start = max(1, abs_hour - max_window_length + 1)
        latest_window_start = abs_hour

        for window_start_hour in earliest_window_start:latest_window_start
            lead_time = abs_hour - window_start_hour + 1

            if lead_time == 1
                raw_draw = 0.0
                z_value = 0.0
                std_dev = 0.0
                forecast_error = 0.0
            else
                raw_draw = rand(rng, t_dist)
                if window_start_hour == earliest_window_start
                    # The first available forecast update for a delivery hour has no
                    # previous window to correlate with, so start the standardized
                    # process at a full innovation draw instead of a damped zero state.
                    z_value = raw_draw
                else
                    z_value = phi * z_prev + sqrt(1 - phi^2) * raw_draw
                end
                std_dev = anchored_forecast_std(lead_time, max_noise_std)
                forecast_error = std_dev * z_value
                z_prev = z_value
            end

            forecast_errors[(window_start_hour, abs_hour)] = forecast_error
            push!(rows, (window_start_hour, abs_hour, lead_time, raw_draw, z_value, std_dev, forecast_error))
        end
    end

    return forecast_errors, rows
end

function write_wind_forecast_error_rows_csv(scenario_path::AbstractString, rows::DataFrame)
    mkpath(dirname(scenario_path))
    CSV.write(scenario_path, rows)
    return rows
end



function load_or_create_wind_forecast_error_scenario!(cfg::Dict, max_noise_std::Float64, simulation_hours::Int, max_window_length::Int)
    scenario_path = cfg[:wind_noise_scenario_path]
    noise_seed = haskey(cfg, :noise_seed) ? cfg[:noise_seed] : 20260325
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

    
    forecast_errors, rows = generate_wind_forecast_error_scenario(scenario_total_hours, scenario_max_window_length, max_noise_std; seed=noise_seed)
    endswith(lowercase(scenario_path), ".csv") || error("Predefined wind forecast error scenario must be a CSV file: $scenario_path")
    write_wind_forecast_error_rows_csv(scenario_path, rows)
    validate_wind_forecast_error_coverage(forecast_errors, scenario_total_hours, scenario_max_window_length)
    return forecast_errors
end

function add_wind_forecast_noise!(Q_gen::Dict, gen::String, max_capacity::Float64, optimization_window::UnitRange{Int}, current_mtu::Int, offset::Int; precomputed_errors::Union{Nothing, Dict{Tuple{Int, Int}, Float64}}=nothing)


    precomputed_errors === nothing && error("precomputed_errors is required when wind forecast noise is enabled")


    for mtu in optimization_window
        # note modifications here to align input data with LLD's implementation - offset should be set to zero in normal circumstances
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

function GetProfileFromFile(filepath, profile_type, dateRange, periodsPerDay, conversion_factor, capacity)
    if periodsPerDay % 24 != 0
        throw("invalid number of periods per day: $periodsPerDay - should be a multiple of 24")
    end

    columnName = (profile_type == "availability") ? "percentage" : (profile_type == "quantity") ? "volume (kWh)" : (profile_type == "demand_quantity") ? "volume (kWh)" : throw("unrecognized profile_type $profile_type")

    data = ImportDataFromFile(filepath)
    hourly_profile_data = data[(dateRange.start .<= data[!,"validfrom (UTC)"] .< dateRange.stop), :][:,columnName]
    
    periods_per_hour = (periodsPerDay/24)


    linear_interpolation_data = Float64[]
    for (hour,hourly_datum) in enumerate(hourly_profile_data)
        next_hour_datum = ( (hour + 1) > length(hourly_profile_data) ) ? hourly_datum : hourly_profile_data[hour+1]
        for i in 0:(periods_per_hour - 1)
            t_shift = i/periods_per_hour
            new_point = hourly_datum + t_shift*(next_hour_datum-hourly_datum)
            push!(linear_interpolation_data,new_point)
        end
    end


    linear_interpolation_data .*= conversion_factor

    if profile_type == "availability" || profile_type == "quantity"
        linear_interpolation_data ./= capacity
    end

    profile_df = DataFrame(mtu=0:(length(linear_interpolation_data)-1), Value=linear_interpolation_data)
    
    return profile_df
end


function GetProfileFromFiles(filepaths, profile_type, dateRange, periodsPerDay, conversion_factor, capacity)
    if periodsPerDay % 24 != 0
        throw("invalid number of periods per day: $periodsPerDay - should be a multiple of 24")
    end

    columnName = (profile_type == "availability") ? "percentage" : (profile_type == "quantity") ? "volume (kWh)" : (profile_type == "demand_quantity") ? "volume (kWh)" : throw("unrecognized profile_type $profile_type")

    profiles_from_files = []

    for filepath in filepaths
        data = ImportDataFromFile(filepath)
        push!(profiles_from_files, data[(dateRange.start .<= data[!,"validfrom (UTC)"] .< dateRange.stop), :][:,columnName])
    end
    hourly_profile_data = []
    for t in 1:length(profiles_from_files[1])
        push!(hourly_profile_data, sum(profile[t] for profile in profiles_from_files) )
    end
    periods_per_hour = (periodsPerDay/24)

    linear_interpolation_data = Float64[]
    for (hour,hourly_datum) in enumerate(hourly_profile_data)
        next_hour_datum = ( (hour + 1) > length(hourly_profile_data) ) ? hourly_datum : hourly_profile_data[hour+1]
        for i in 0:(periods_per_hour - 1)
            t_shift = i/periods_per_hour
            new_point = hourly_datum + t_shift*(next_hour_datum-hourly_datum)
            push!(linear_interpolation_data,new_point)
        end
    end

    linear_interpolation_data .*= conversion_factor

    if profile_type == "availability" || profile_type == "quantity"
        linear_interpolation_data ./= capacity
    end

    profile_df = DataFrame(mtu=0:(length(linear_interpolation_data)-1), Value=linear_interpolation_data)

    return profile_df
end

end;
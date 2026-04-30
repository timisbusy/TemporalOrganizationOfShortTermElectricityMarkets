module HelperInputData

using CSV, DataFrames, Dates

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


function ImportDataFromCSV(filepath)
    println("importing: $(filepath)")
    
    data = DataFrame(CSV.File(filepath,dateformat="y-mm-dd H:M:S"))
    return data
end

# we assume we are using NED.nl data, with known fields and hourly data 
# field allows us to extract the data we need (sometimes "percentage", sometimes "volume (kWh)")
# periodsPerDay allows for extrapolation/expansion of data to meet expectations of caller

function GetProfileFromCSV(filepath, field, dateRange, periodsPerDay)
    if periodsPerDay % 24 != 0
        throw("invalid number of periods per day: $periodsPerDay - should be a multiple of 24")
    end
    data = ImportDataFromCSV(filepath)
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
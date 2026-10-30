module GenerateWindowLengthConfigs

using Dates

export GenerateConfigs, DESIGNS

# Market designs to generate: suffix used in the experiment name => market config file
# (resolved against src/configs/markets/ by DataImporter).
const DESIGNS = [
    ("rolling_36", "rolling_laura.yaml",    36),
    ("rolling_48", "rolling_48_laura.yaml", 48),
    ("rolling_72", "rolling_72_laura.yaml", 72),
    ("fixed_36",   "fixed_laura.yaml",      36),
]

# Matches a top-level `key: value` line (not indented, not a comment).
_key_regex(key) = Regex("^" * key * raw":(\s|$)")

# Replace the top-level `key` line with `new_line`, dropping the comment-only continuation
# lines directly below it (they describe the old value and would be stale). Appends the line
# if the key is absent.
function _set_key(lines::Vector{String}, key::String, new_line::String)
    i = findfirst(l -> occursin(_key_regex(key), l), lines)
    if i === nothing
        push!(lines, new_line)
        return lines
    end
    j = i
    while j < length(lines) && startswith(lines[j+1], "#")
        j += 1
    end
    return vcat(lines[1:i-1], [new_line], lines[j+1:end])
end

function _get_int(lines::Vector{String}, key::String, default::Int)
    i = findfirst(l -> occursin(_key_regex(key), l), lines)
    i === nothing && return default
    m = match(Regex("^" * key * raw":\s*(\d+)"), lines[i])
    return m === nothing ? default : parse(Int, m.captures[1])
end

"""
    GenerateConfigs(source_config, first_day, last_day; output_dir="src/configs/experiments")

Write one experiment config per design in `DESIGNS` (rolling 36/48/72 and fixed 36), copying all
other parameters (agents, noise, optimization model, ...) from `source_config`. Returns the
written file paths.

`first_day` and `last_day` (`Date` or "YYYY-MM-DD"; both inclusive) bound the *analyzed* window,
so every design is compared over identical days. The generated configs then set:
- `startDate`: `first_day` minus the source config's `samplePeriodExcludeSpinUp` days, so the
  spin-up is simulated but excluded from analysis.
- `samplePeriodExcludeEnd`: `ceil(window/24)` days (the look-ahead tail that the last auction
  cannot cover).
- `clearForDays`: analyzed days + spin-up + end exclusion.
- `name` and `marketConfig`, per design.

Spin-up and `skipEarlyAuctions` are taken from `source_config` unchanged.
"""
function GenerateConfigs(source_config::AbstractString, first_day, last_day;
                         output_dir::AbstractString = "src/configs/experiments")
    first_day = Date(first_day)
    last_day = Date(last_day)
    last_day >= first_day || error("last_day ($last_day) is before first_day ($first_day)")
    analysis_days = Dates.value(last_day - first_day) + 1

    source_lines = readlines(source_config)
    spin_up = _get_int(source_lines, "samplePeriodExcludeSpinUp", 2)
    start_date = first_day - Day(spin_up)

    mkpath(output_dir)
    tag = "$(Dates.format(first_day, "yyyymmdd"))_$(Dates.format(last_day, "yyyymmdd"))"
    written = String[]
    for (prefix, market_config, window) in DESIGNS
        name = "$(prefix)_$(tag)"
        exclude_end = cld(window, 24)
        clear_days = analysis_days + spin_up + exclude_end

        lines = copy(source_lines)
        lines = _set_key(lines, "name", "name: $name # descriptive name for experiment")
        lines = _set_key(lines, "clearForDays",
            "clearForDays: $clear_days # $analysis_days analyzed days + $spin_up spin-up + $exclude_end end-exclusion (ceil($window/24))")
        lines = _set_key(lines, "samplePeriodExcludeEnd",
            "samplePeriodExcludeEnd: $exclude_end # ceil($window/24) days: the last auction cannot cover a full look-ahead window")
        lines = _set_key(lines, "startDate",
            "startDate: $start_date # $first_day minus $spin_up spin-up day(s)")
        lines = _set_key(lines, "marketConfig", "marketConfig: $market_config")

        path = joinpath(output_dir, name * ".yaml")
        open(path, "w") do io
            println(io, join(lines, "\n"))
        end
        push!(written, path)
    end
    println("Wrote $(length(written)) configs to $output_dir (analysis window $first_day to $last_day):")
    foreach(p -> println("  ", p), written)
    return written
end

end # module

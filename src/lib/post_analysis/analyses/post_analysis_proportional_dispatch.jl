# Checks a ProportionalMarketModel run (proportional_res: true) against what the constraint promises:
# in every clearing, the two proportional_res_agents (default wind and solar) are dispatched at the
# same fraction of their available capacity. For each clearing in a run's RAW/ folder (one
# decisionvariables_* export per clearing, covering that clearing's whole optimization window), the
# available capacity of each resource per MTU is rebuilt the way proportional_model.jl builds Q_gen -
# capacity * power_to_energy_scale * availability factor from the run's profile_data_* export, with
# wind then perturbed by the same precomputed forecast error add_wind_forecast_noise! uses for that
# (clearing MTU, MTU) pair - and the two dispatched fractions are compared.
#
# The first MTU of each clearing is reported separately: when restrict_mtu1_trading pins solar to its
# earlier dispatch there, the model skips the proportionality constraint (see
# proportional_res_skip_locked_mtu1), so that row is expected to deviate - and in a rolling horizon it
# is the MTU's final dispatch. Also reports where prices are negative and what the price is when
# wind is curtailed.

module PostAnalysisProportionalDispatch

using XLSX, DataFrames, YAML, CSV, Statistics

include("../post_analysis_common.jl")

const CASES = ["Fixed Horizon", "Rolling Horizon"]

const DEFAULT_CASE_PATHS = Dict{String,String}(
	"Fixed Horizon" => "results/1793280556_fixed_36_proportional",
	"Rolling Horizon" => "results/1793280556_rolling_36_proportional",
)

# same default clear_market.jl falls back to when the experiment config sets no wind_noise_scenario_path
const DEFAULT_WIND_NOISE_SCENARIO_PATH = "input_data/laura/wind_forecast_error_shared_final_20260502.csv"
const DEFAULT_PROPORTIONAL_AGENTS = ["6G_Wind", "7G_Solar"]

# largest |wind fraction - solar fraction| still counted as proportional (the constraint holds to ~1e-16)
const FRACTION_TOLERANCE = 1e-6

# a run's own experiment and agent yamls from its Config/ folder, found by the key that identifies each
function LoadCaseConfigs(case_path)
	experiment_cfg = agent_cfg = nothing
	for f in sort(readdir(joinpath(case_path, "Config")))
		endswith(f, ".yaml") || continue
		cfg = YAML.load_file(joinpath(case_path, "Config", f))
		cfg isa AbstractDict || continue
		haskey(cfg, "variableGenerators") && (agent_cfg = cfg)
		haskey(cfg, "clearForDays") && (experiment_cfg = cfg)
	end
	(experiment_cfg === nothing || agent_cfg === nothing) && throw("could not find the experiment and agent configs in $case_path/Config")
	return (experiment_cfg, agent_cfg)
end

# (window start MTU, MTU) => forecast error, keyed the way add_wind_forecast_noise! looks it up
function LoadWindForecastErrors(path)
	errors = Dict{Tuple{Int,Int},Float64}()
	for r in CSV.File(path)
		errors[(r.window_start_hour, r.abs_hour)] = r.forecast_error
	end
	return errors
end

ProfileByMTU(case_path, agent) = Dict(r.mtu => r.Value for r in eachrow(PostAnalysisCommon.LoadFile(joinpath(case_path, "profile_data_$agent.xlsx"))))

# available capacity per MTU for a clearing at `clearing_mtu`; wind (agents with "Wind" in the name) gets the
# clearing's forecast error, exactly as add_wind_forecast_noise! applies it
function AvailableCapacity(agent, capacity, scale, profile, errors, offset, clearing_mtu, mtu)
	available = capacity * scale * profile[mtu]
	if occursin("Wind", agent) && clearing_mtu >= offset + 1 && mtu >= offset + 1
		af = clamp(available / capacity * (1 + errors[(clearing_mtu - offset, mtu - offset)]), 0.0, 1.0)
		available = capacity * af
	end
	return available
end

function AnalyzeCase(case_path; time_range=nothing)
	experiment_cfg, agent_cfg = LoadCaseConfigs(case_path)
	opt_cfg = get(experiment_cfg, "optimizationModelConfig", Dict{String,Any}())
	get(opt_cfg, "proportional_res", false) == true || println("warning: $case_path was not run with proportional_res: true - expect deviations everywhere")
	agent_a, agent_b = get(opt_cfg, "proportional_res_agents", DEFAULT_PROPORTIONAL_AGENTS)

	scale = 24 / Int(experiment_cfg["timePeriodsPerDay"])
	offset = Int(get(experiment_cfg, "windOffset", 0))
	var_gens = agent_cfg["variableGenerators"]
	capacity_a, capacity_b = Float64(var_gens[agent_a]["capacity"]), Float64(var_gens[agent_b]["capacity"])
	profile_a, profile_b = ProfileByMTU(case_path, agent_a), ProfileByMTU(case_path, agent_b)
	errors = LoadWindForecastErrors(get(experiment_cfg, "wind_noise_scenario_path", DEFAULT_WIND_NOISE_SCENARIO_PATH))

	prefix = PostAnalysisCommon.DiscoverRawDispatchPrefix(case_path) # full path up to the clearing MTU
	raw_file_regex = Regex("^$(basename(prefix))(\\d+)\\.xlsx\$")
	clearings = sort([parse(Int, m.captures[1]) for f in readdir(joinpath(case_path, "RAW")) for m in [match(raw_file_regex, f)] if m !== nothing])

	rest_rows = DataFrame(clearing_mtu=Int[], mtu=Int[], fraction_a=Float64[], fraction_b=Float64[], deviation=Float64[])
	first_rows = similar(rest_rows)
	prices = Float64[]
	negative_price_rows = 0
	curtailed_prices = Float64[]

	for t in clearings
		df = PostAnalysisCommon.LoadFile("$prefix$t.xlsx")
		for (i, r) in enumerate(eachrow(df))
			time_range === nothing || r.mtu in time_range || continue
			push!(prices, r.price)
			r.price < 0 && (negative_price_rows += 1)
			available_a = AvailableCapacity(agent_a, capacity_a, scale, profile_a, errors, offset, t, r.mtu)
			available_b = AvailableCapacity(agent_b, capacity_b, scale, profile_b, errors, offset, t, r.mtu)
			available_a * available_b == 0 && continue # fraction undefined - the model skips these too
			fraction_a, fraction_b = r[agent_a] / available_a, r[agent_b] / available_b
			push!(i == 1 ? first_rows : rest_rows, (t, r.mtu, fraction_a, fraction_b, abs(fraction_a - fraction_b)))
			if i > 1 && fraction_a < 1 - FRACTION_TOLERANCE
				push!(curtailed_prices, r.price)
			end
		end
	end
	return (; agents=(agent_a, agent_b), rest_rows, first_rows, prices, negative_price_rows, curtailed_prices)
end

ExtremeOrMissing(f, x) = isempty(x) ? missing : f(x)

function SummaryTable(cases, results)
	indicators = String[]
	columns = Dict{String,Vector{Any}}(c => Any[] for c in cases)
	function add!(indicator, values)
		push!(indicators, indicator)
		for c in cases
			push!(columns[c], values[c])
		end
	end
	add!("Proportional agents", Dict(c => join(results[c].agents, " / ") for c in cases))
	add!("MTUs checked (not first in clearing)", Dict(c => nrow(results[c].rest_rows) for c in cases))
	add!("  deviating by more than $FRACTION_TOLERANCE", Dict(c => count(>(FRACTION_TOLERANCE), results[c].rest_rows.deviation) for c in cases))
	add!("  largest deviation", Dict(c => ExtremeOrMissing(maximum, results[c].rest_rows.deviation) for c in cases))
	add!("  MTUs with the first agent curtailed", Dict(c => length(results[c].curtailed_prices) for c in cases))
	add!("  lowest price when curtailed (€/MWh)", Dict(c => ExtremeOrMissing(minimum, results[c].curtailed_prices) for c in cases))
	add!("  highest price when curtailed (€/MWh)", Dict(c => ExtremeOrMissing(maximum, results[c].curtailed_prices) for c in cases))
	add!("First MTUs of clearings checked", Dict(c => nrow(results[c].first_rows) for c in cases))
	add!("  deviating by more than $FRACTION_TOLERANCE", Dict(c => count(>(FRACTION_TOLERANCE), results[c].first_rows.deviation) for c in cases))
	add!("  largest deviation", Dict(c => ExtremeOrMissing(maximum, results[c].first_rows.deviation) for c in cases))
	add!("Lowest price in any clearing (€/MWh)", Dict(c => ExtremeOrMissing(minimum, results[c].prices) for c in cases))
	add!("Clearing MTUs with a negative price", Dict(c => results[c].negative_price_rows for c in cases))
	table = DataFrame("Indicator" => indicators)
	for c in cases
		table[!, c] = columns[c]
	end
	return table
end

function InterpretationTable()
	return DataFrame(
		DataPoint=["MTUs checked (not first in clearing)", "deviating by more than $FRACTION_TOLERANCE", "First MTUs of clearings checked", "Clearing MTUs with a negative price", "first_mtu_deviations sheet"],
		Interpretation=[
			"Clearing x MTU rows, excluding each clearing's first MTU, where both agents have available capacity. A deviation is |dispatched/available for the first agent - the same for the second agent|; the constraint requires 0.",
			"Rows where the two fractions differ - expected to be 0 outside the first MTU of a clearing.",
			"Each clearing's first MTU is exempt from the constraint when restrict_mtu1_trading pins solar there (proportional_res_skip_locked_mtu1), so it can deviate; in a rolling horizon this is the MTU's final dispatch.",
			"Rows across every clearing's window with price < 0 (negative zero does not count).",
			"The first MTUs whose fractions differ, per case - clearing MTU, MTU, both fractions.",
		],
	)
end

# case_paths: case name => results folder of a ProportionalMarketModel run; time_range: restrict the checked
# MTUs (nothing = every MTU in every clearing)
function PerformAnalysis(case_paths=DEFAULT_CASE_PATHS; cases=CASES, output_base=PostAnalysisCommon.NewAnalysisOutputDir(case_paths), time_range=nothing)
	analysis_dir_path = "$output_base/post_analysis_proportional_dispatch"
	PostAnalysisCommon.CleanDirectory(analysis_dir_path)

	results = Dict(c => AnalyzeCase(case_paths[c]; time_range=time_range) for c in cases)
	summary = SummaryTable(cases, results)
	println(summary)

	deviations = vcat([insertcols(filter(r -> r.deviation > FRACTION_TOLERANCE, results[c].first_rows), 1, :case => c) for c in cases]...)
	XLSX.writetable("$analysis_dir_path/proportional_dispatch.xlsx", "summary" => summary, "first_mtu_deviations" => deviations, "interpretation" => InterpretationTable(); overwrite=true)
	return summary
end

end

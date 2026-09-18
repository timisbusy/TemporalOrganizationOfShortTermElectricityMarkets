# Storage residence time - the number of hours between charging a MWh and later discharging it -
# compared across the three rolling-horizon optimization-window-length cases (36h/48h/72h).
#
# Ports the FIFO energy-tracking method from Laura's own residence-time analysis
# (further_analysis/analyze_hypothesis1_storage_residence_time.jl in her market_clearing repo)
# rather than inventing a different definition, and follows her presentation style directly - a
# CDF comparison plot with vertical threshold-hour guide lines, plus a stacked per-case histogram
# panel (see plot_cdf_comparison/plot_group_histograms in her script).
#
# Storage is modeled as a FIFO queue of energy "packets", each tagged with the MTU it was charged
# in. Charging pushes a new packet of `efficiency * charge` MWh (SOC-energy units) onto the back of
# the queue; discharging withdraws from the front (oldest first), consuming `discharge / efficiency`
# MWh of SOC-energy per MWh actually delivered. A packet's residence time is (discharge MTU - its
# own charge MTU), weighted by however much delivered discharge (MWh) came from it - one MWh
# charged then split across several later discharges contributes one weighted residence-time
# observation per split. Any SOC already present at the start of the analyzed time_range (i.e.
# charged before it) is treated as a single untraceable "initial" packet and excluded from the
# residence-time statistics, the same convention Laura's analysis uses for a run's true starting
# SOC.
#
# A pro-rata (weighted-average-cost) alternative - every currently-resident packet gives up energy
# in proportion to its share of total stored energy, rather than draining the oldest one first -
# was checked as a sensitivity test against this FIFO convention and gave essentially the same
# mean/median residence times, so FIFO alone is used here going forward; BuildProRataTrace is kept
# below in case that check needs revisiting.

module PostAnalysisWindowLengthResidenceTime

using DataFrames, Plots, XLSX, YAML

include("./post_analysis_common.jl")
include("./post_analysis_conventional_generation_cost.jl")

const DEFAULT_CASE_PATHS = PostAnalysisConventionalGenerationCost.DEFAULT_CASE_PATHS
const DEFAULT_CASES = PostAnalysisConventionalGenerationCost.DEFAULT_CASES

const EPS = 1e-9

# Reads batteryStorage.efficiency from the run's own copied agent configuration under Config/ (see
# ClearMarket.CopyConfigFiles!), the same discovery-by-content approach
# PostAnalysisConventionalGenerationCost.LoadGeneratorBidPrices uses for bidPrice - so this stays
# correct if a case is ever run with a different battery efficiency instead of silently assuming
# every case shares one hardcoded value.
function LoadStorageEfficiency(case_path)
	config_dir = joinpath(case_path, "Config")
	for f in readdir(config_dir)
		endswith(f, ".yaml") || continue
		data = YAML.load_file(joinpath(config_dir, f))
		haskey(data, "batteryStorage") || continue
		haskey(data["batteryStorage"], "efficiency") || continue
		return Float64(data["batteryStorage"]["efficiency"])
	end
	throw("no agent configuration with batteryStorage.efficiency found in $config_dir")
end

mutable struct EnergyPacket
	charge_mtu::Union{Int,Missing}
	energy_in_soc::Float64
end

# Walks dd (sorted by mtu, one row per MTU) building the FIFO queue described above. Returns
# parallel vectors of (residence_hours, discharge_weight_mwh), one pair per traced discharge split,
# plus whatever SOC-energy is still queued (uncharged... i.e. un-discharged) at the end of dd - MWh
# that were charged within time_range but not yet discharged by its end, so they contribute no
# residence-time observation at all. That's a real right-censoring effect (the longest-residence
# cases for late charges are the ones most likely to still be sitting in the queue when the window
# ends), not a bug - reported so it's visible rather than silently making the reported mean/median
# look shorter than the true distribution.
function BuildFifoTrace(dd::DataFrame, initial_soc::Float64, efficiency::Float64)
	packets = EnergyPacket[]
	if initial_soc > EPS
		push!(packets, EnergyPacket(missing, initial_soc))
	end

	residence_hours = Float64[]
	discharge_weights = Float64[]

	for row in eachrow(dd)
		mtu = Int(row.mtu)
		charge_input = Float64(row.StorageCharge)
		discharge_output = Float64(row.StorageDischarge)

		remaining_discharge = discharge_output
		while remaining_discharge > EPS
			isempty(packets) && error("FIFO queue emptied before meeting discharge at mtu $mtu - check StorageCharge/StorageDischarge consistency")
			packet = packets[1]
			if packet.energy_in_soc <= EPS
				popfirst!(packets)
				continue
			end

			required_soc = remaining_discharge / efficiency
			consumed_soc = min(packet.energy_in_soc, required_soc)
			produced_output = consumed_soc * efficiency
			packet.energy_in_soc -= consumed_soc
			remaining_discharge -= produced_output

			if !ismissing(packet.charge_mtu)
				push!(residence_hours, Float64(mtu - packet.charge_mtu))
				push!(discharge_weights, produced_output)
			end

			packet.energy_in_soc <= EPS && popfirst!(packets)
		end

		# charge is appended after discharge, so same-MTU charge/discharge (both nonzero in one
		# row) can't create a spurious 0h residence for energy that hasn't actually been through
		# the queue yet this MTU - same reasoning as Laura's own trace.
		if charge_input > EPS
			push!(packets, EnergyPacket(mtu, efficiency * charge_input))
		end
	end

	censored_soc_mwh = sum((packet.energy_in_soc for packet in packets if !ismissing(packet.charge_mtu)); init=0.0)

	return residence_hours, discharge_weights, censored_soc_mwh
end

# Same SOC-energy accounting as BuildFifoTrace, but each discharge draws proportionally from every
# currently-resident packet (weighted-average-cost convention) instead of draining the oldest one
# first - see the module docstring. Since every packet gives up the same fraction of its own
# energy, this needs only one pass per discharging MTU rather than FIFO's front-of-queue loop.
function BuildProRataTrace(dd::DataFrame, initial_soc::Float64, efficiency::Float64)
	packets = EnergyPacket[]
	if initial_soc > EPS
		push!(packets, EnergyPacket(missing, initial_soc))
	end

	residence_hours = Float64[]
	discharge_weights = Float64[]

	for row in eachrow(dd)
		mtu = Int(row.mtu)
		charge_input = Float64(row.StorageCharge)
		discharge_output = Float64(row.StorageDischarge)

		if discharge_output > EPS
			total_soc = sum((packet.energy_in_soc for packet in packets); init=0.0)
			total_soc > EPS || error("storage pool emptied before meeting discharge at mtu $mtu - check StorageCharge/StorageDischarge consistency")
			required_soc = discharge_output / efficiency
			required_soc <= total_soc + EPS || error("not enough stored energy to meet discharge at mtu $mtu - check StorageCharge/StorageDischarge consistency")

			fraction = min(required_soc / total_soc, 1.0)
			for packet in packets
				consumed = packet.energy_in_soc * fraction
				packet.energy_in_soc -= consumed
				produced = consumed * efficiency
				if !ismissing(packet.charge_mtu) && produced > EPS
					push!(residence_hours, Float64(mtu - packet.charge_mtu))
					push!(discharge_weights, produced)
				end
			end
			filter!(packet -> packet.energy_in_soc > EPS, packets)
		end

		# charge is appended after discharge, so same-MTU charge/discharge (both nonzero in one
		# row) can't create a spurious 0h residence for energy that hasn't actually been through
		# the pool yet this MTU - same reasoning as BuildFifoTrace.
		if charge_input > EPS
			push!(packets, EnergyPacket(mtu, efficiency * charge_input))
		end
	end

	censored_soc_mwh = sum((packet.energy_in_soc for packet in packets if !ismissing(packet.charge_mtu)); init=0.0)

	return residence_hours, discharge_weights, censored_soc_mwh
end

function WeightedQuantile(values::AbstractVector{<:Real}, weights::AbstractVector{<:Real}, p::Real)
	isempty(values) && return NaN
	total = sum(weights)
	total > EPS || return NaN

	order = sortperm(values)
	v = values[order]
	w = weights[order]
	threshold = clamp(Float64(p), 0.0, 1.0) * total
	cumulative = 0.0
	for (val, wt) in zip(v, w)
		cumulative += wt
		cumulative + EPS >= threshold && return val
	end
	return v[end]
end

function PerformAnalysis(case_paths=DEFAULT_CASE_PATHS; cases=DEFAULT_CASES, output_base=PostAnalysisCommon.NewAnalysisOutputDir(case_paths; label=PostAnalysisConventionalGenerationCost.DefaultLabel(case_paths, cases)), time_range=PostAnalysisCommon.DEFAULT_TIME_RANGE)

	analysis_dir_path = "$output_base/residence_time"
	PostAnalysisCommon.CleanDirectory(analysis_dir_path)

	residence_by_case = Dict{String,Vector{Float64}}()
	weights_by_case = Dict{String,Vector{Float64}}()
	summary_rows = NamedTuple[]

	for case in cases
		dd_full = PostAnalysisCommon.LoadFile(joinpath(case_paths[case], "final_dispatch_decisions.xlsx"))
		efficiency = LoadStorageEfficiency(case_paths[case])

		dd = dd_full[time_range.start .<= dd_full.mtu .<= time_range.stop, :]
		sort!(dd, :mtu)

		# final_dispatch_decisions.xlsx is already trimmed to the analysis window at export time
		# (see PlotBaselineOutcomes.plot's own GetEconomicIndicatorsForRange call), so there's no
		# mtu = time_range.start - 1 row to look SOC up from - reconstruct it instead from the
		# model's own SOC-dynamics equation (SOC[t] = SOC[t-1] + eta*Charge[t] - Discharge[t]/eta,
		# see LatestMarketModel.build_market_clearing!) using the window's first row.
		first_row = dd[1, :]
		initial_soc = Float64(first_row.SOC) - efficiency * Float64(first_row.StorageCharge) + Float64(first_row.StorageDischarge) / efficiency

		(residence, weights, censored_soc_mwh) = BuildFifoTrace(dd, initial_soc, efficiency)
		residence_by_case[case] = residence
		weights_by_case[case] = weights

		traced_discharge = sum(weights)
		push!(summary_rows, (
			Case = case,
			Efficiency = efficiency,
			MeanResidenceHours = traced_discharge > EPS ? sum(residence .* weights) / traced_discharge : NaN,
			MedianResidenceHours = WeightedQuantile(residence, weights, 0.5),
			P90ResidenceHours = WeightedQuantile(residence, weights, 0.9),
			TracedDischargeMWh = traced_discharge,
			# MWh charged within time_range but not yet discharged by its end - right-censored,
			# contributes no residence-time observation at all (see BuildFifoTrace) - reported so
			# it's visible rather than silently making the reported mean/median look shorter than
			# the true distribution would be with a longer or unbounded observation window.
			CensoredUndischargedMWh = censored_soc_mwh,
		))
	end

	summary_df = DataFrame(summary_rows)
	println(summary_df)

	PlotResidenceTimeCDF(residence_by_case, weights_by_case, cases, analysis_dir_path)
	PlotResidenceTimeHistograms(residence_by_case, weights_by_case, cases, analysis_dir_path)

	XLSX.writetable("$analysis_dir_path/residence_time_summary.xlsx", "data" => summary_df; overwrite=true)

	return summary_df
end

# Fixed per-window-length colors matching Laura's own CASE_COLORS palette for her Rolling 36h/48h/
# 72h series, so a plot from this suite reads consistently against hers - falls back to the default
# Plots.jl palette (by position in `cases`) for any case name outside this set.
const KNOWN_CASE_COLORS = Dict(
	"36h" => RGB(0.153, 0.396, 0.545),
	"48h" => RGB(0.878, 0.490, 0.000),
	"72h" => RGB(0.145, 0.627, 0.333),
)

function CaseColor(case, cases)
	haskey(KNOWN_CASE_COLORS, case) && return KNOWN_CASE_COLORS[case]
	palette = Plots.palette(:default)
	idx = something(findfirst(==(case), cases), 1)
	return palette[mod1(idx, length(palette))]
end

# Threshold-hour guide lines, same set Laura's own plot_cdf_comparison draws.
const THRESHOLD_HOURS = [6, 12, 24, 36, 48, 72]

# Mirrors Laura's plot_cdf_comparison: one plot, all cases as CDF lines, xlim/ylim (0,72)/(0,1),
# faint vertical guide lines at the same threshold hours, linewidth 2.5.
function PlotResidenceTimeCDF(residence_by_case, weights_by_case, cases, analysis_dir_path)
	p = Plots.plot(xlabel="Residence time (h)", ylabel="Cumulative discharge share",
					title="Storage Residence-Time CDF",
					xlims=(0, 72), ylims=(0, 1.0),
					size=(1000, 600), left_margin=10Plots.mm, bottom_margin=8Plots.mm)

	for threshold in THRESHOLD_HOURS
		Plots.vline!(p, [threshold], color=RGBA(0, 0, 0, 0.12), linestyle=:dash, label="")
	end

	for case in cases
		residence = residence_by_case[case]
		weights = weights_by_case[case]
		isempty(residence) && continue
		order = sortperm(residence)
		x = residence[order]
		w = weights[order]
		y = cumsum(w) ./ sum(w)
		Plots.plot!(p, x, y, label=case, color=CaseColor(case, cases), linewidth=2.5)
	end

	display(p)
	savefig(p, "$analysis_dir_path/residence_time_cdf.png")
end

# Mirrors Laura's plot_group_histograms: one subplot per case, stacked vertically, 3h-wide bins
# over 0-72h, normalized to a discharge-share probability, no per-panel legend (the case name is
# the panel title instead).
function PlotResidenceTimeHistograms(residence_by_case, weights_by_case, cases, analysis_dir_path)
	bins = 0:3:72
	subplots = Any[]

	for case in cases
		residence = residence_by_case[case]
		weights = weights_by_case[case]

		hist_edges = collect(bins)
		hist_counts = zeros(Float64, length(hist_edges) - 1)
		for (r, w) in zip(residence, weights)
			idx = clamp(searchsortedlast(hist_edges, r), 1, length(hist_counts))
			hist_counts[idx] += w
		end
		total = sum(hist_counts)
		hist_probs = total > EPS ? hist_counts ./ total : hist_counts
		y_upper = maximum(hist_probs; init=0.0) * 1.12 + 0.005

		sp = Plots.bar(hist_edges[1:end-1], hist_probs, bar_width=step(bins),
						xlabel="Residence time (h)", ylabel="Discharge share",
						title=case, legend=false,
						xlims=(-1, 73), ylims=(0, y_upper),
						color=CaseColor(case, cases), alpha=0.75,
						linewidth=0, framestyle=:box, gridalpha=0.18,
						left_margin=8Plots.mm, right_margin=4Plots.mm, bottom_margin=4Plots.mm)
		push!(subplots, sp)
	end

	combined = Plots.plot(subplots..., layout=(length(subplots), 1), size=(1000, 235 * length(subplots)),
						left_margin=6Plots.mm, right_margin=4Plots.mm, top_margin=2Plots.mm, bottom_margin=4Plots.mm)
	display(combined)
	savefig(combined, "$analysis_dir_path/residence_time_histogram.png")
end

end;

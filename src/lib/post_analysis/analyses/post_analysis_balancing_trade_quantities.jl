# Trade quantities by agent in the balancing segment only: what each agent traded in the locked (balancing)
# MTUs of the clearings, read from the Segment == Balancing transactions (see
# balancing_energy/balancing_energy_split.jl for how the two segments are defined), over the analysis time_range
# (transactions bucketed by delivery MTU, like every other metric in this suite).
#
# Sign convention: positive = energy injected into the system (a generator's supply increase, storage discharging, or a
# demand agent's consumption reduction), negative = energy withdrawn (supply decrease, storage charging, consumption
# increase). A demand agent's transaction quantities are consumption, so their sign is flipped.
#
# The workbook table has, per agent, four rows:
#   Net traded in wind-decrease MTUs (MWh)       - the agent's net trades summed over the balancing MTUs where the wind's
#                                                  available quantity is lower than the previous clearing's forecast of the
#                                                  same MTU (dA_t < 0)
#   Share of trades in wind-decrease MTUs (%)    - that net over the sum of the same net over all trading agents
#   Net traded in wind-increase MTUs (MWh)       - likewise over the MTUs where the wind is higher (dA_t > 0)
#   Share of trades in wind-increase MTUs (%)
# Per MTU an agent's net trade is the sum of its balancing transactions, demand sign-flipped. The share denominator is
# the total of all the trading agents' net trades in those MTUs (the rows below excluded), so each agent's shares add up
# to 100% over the agents; a share is negative when the agent's net had the opposite sign from that total. Two rows
# that are not agents are added: "Wind spillage" (per MTU, the wind agent's own net balancing trade minus dA_t, i.e. the
# negative of the change in its spillage; no share) and "Wind forecast change" (the sum of dA_t over the wind-decrease /
# wind-increase MTUs, no share). The balancing transactions net to zero in every MTU, so in each segment the agents plus
# Wind spillage add up to minus the Wind forecast change. The shares need the previous clearings' forecasts, read from
# each run's RAW exports; without them (dA not given) the share rows and the Wind rows are empty.
#
# The per-agent volumes used by the cluster comparison modules (METRICS: net, gross, up and down balancing, summed per
# transaction) are still computed but no longer written to the workbook.
#
# One row per agent and metric, one column per case, then MWh difference columns (compared minus base, not
# percentages; percentage points for the share rows): by default "{case} vs {previous case}" for each adjacent pair
# (the window-length suite: 48h vs 36h, 72h vs 48h), or with compare_to_subject=true "{last case} vs {base}" for
# every other case (the fixed vs rolling suite's convention: cases[end] is the subject, see PostAnalysisSEW). For
# two cases the two are identical.

module PostAnalysisBalancingTradeQuantities

using XLSX, DataFrames, Latexify, Plots

include("../post_analysis_common.jl")
include("../agent_renaming.jl")

const AGENTS = ["1D_HighBid", "2D_ModerateBid", "3G_Base", "4G_Shoulder", "5G_Peak", "6G_Wind", "7G_Solar", "Storage"]
const BALANCING_SEGMENT = "Balancing"

const NET = "Net traded (MWh)"
const GROSS = "Gross traded (MWh)"
const UP = "Up balancing (MWh)"
const DOWN = "Down balancing (MWh)"
const UP_SHARE = "Share of trades in wind-decrease MTUs (%)"
const DOWN_SHARE = "Share of trades in wind-increase MTUs (%)"
const METRICS = [NET, GROSS, UP, DOWN]                # per-agent volumes (the cluster comparison modules iterate these)
const RESPONSE_TO_FALL = "Net traded in wind-decrease MTUs (MWh)"
const RESPONSE_TO_RISE = "Net traded in wind-increase MTUs (MWh)"
const SHARE_METRICS = [UP_SHARE, DOWN_SHARE]          # shares of the total net trades per wind segment, from WindResponseMetrics
const NEED_METRICS = [RESPONSE_TO_FALL, UP_SHARE, RESPONSE_TO_RISE, DOWN_SHARE] # each response row is followed by its share
const TABLE_METRICS = [METRICS; NEED_METRICS]         # rows of the table, per agent

const WIND_AGENT = "6G_Wind"
const SPILL_AGENT = "Wind spillage"                   # pseudo-agent rows of the table, see the header
const CAUSE_AGENT = "Wind forecast change"
const SPILL_AND_CAUSE = [SPILL_AGENT, CAUSE_AGENT]

const SEGMENT_COLUMN = Symbol("Segment")
const MTU_COLUMN = Symbol("Market Time Unit")
const QUANTITY_COLUMN = Symbol("Quantity (MWh)")

DisplayName(agent) = agent == "Storage" || agent in SPILL_AND_CAUSE ? agent : AgentRenaming.DisplayName(agent)

# near-zero float noise (e.g. a generator the lock pins, summed over thousands of transactions) reported as exactly 0.0
snap(x) = PostAnalysisCommon.MarketDataStorage.snap0(x)

# demand agents ("1D_HighBid", "2D_ModerateBid"): a positive quantity is consumption, so for them up balancing is a
# consumption reduction and down balancing a consumption increase
IsDemandAgent(agent) = occursin(r"^[0-9]+D_", agent)

# metric => value for one agent's balancing quantities (volumes only; the shares need every agent, see below)
function TradeQuantities(quantities; demand=false)
	supply_up = sum(q -> max(q, 0.0), quantities; init=0.0)
	supply_down = sum(q -> min(q, 0.0), quantities; init=0.0)
	return Dict(
		NET => snap(sum(quantities; init=0.0)),
		GROSS => snap(sum(abs, quantities; init=0.0)),
		UP => snap(demand ? -supply_down : supply_up),
		DOWN => snap(demand ? -supply_up : supply_down),
	)
end

# Net trades per wind segment and their shares (see the header).
#   net_by_agent  agent => (mtu => net balancing quantity of the agent in that MTU), including the wind agent
#   delta_a       mtu => change in the wind's available quantity (now - previous clearing's forecast)
# Returns agent => metrics (volumes plus the net-traded and share rows) for every agent but wind, and SPILL_AGENT and
# CAUSE_AGENT entries; the wind agent's own metrics are left to the caller (it has no share).
function WindResponseMetrics(net_by_agent, delta_a; wind=WIND_AGENT)
	mtus = sort(collect(keys(delta_a)))
	net(agent, t) = get(get(net_by_agent, agent, Dict{Int,Float64}()), t, 0.0)
	# per-MTU net trades in the injection-positive convention: agents (a demand agent's consumption reduction is an
	# injection) and the wind spillage (extra spillage is a withdrawal)
	trades = Dict{String,Vector{Float64}}()
	for agent in keys(net_by_agent)
		agent == wind && continue # the wind agent's change in availability is the reference, not the trade of an agent
		sign = IsDemandAgent(agent) ? -1.0 : 1.0
		trades[agent] = [sign * net(agent, t) for t in mtus]
	end
	trades[SPILL_AGENT] = [net(wind, t) - delta_a[t] for t in mtus] # W_t - dA_t = -(change in spillage)
	dA = [delta_a[t] for t in mtus]
	decrease_mtus, increase_mtus = dA .< 0, dA .> 0
	need_up, need_down = sum(-dA[decrease_mtus]; init=0.0), sum(dA[increase_mtus]; init=0.0)

	out = Dict{String,Dict{String,Union{Missing,Float64}}}()
	for (agent, r) in trades
		m = Dict{String,Union{Missing,Float64}}(k => v for (k, v) in TradeQuantities(r))
		m[RESPONSE_TO_FALL] = snap(sum(r[decrease_mtus]; init=0.0))
		m[RESPONSE_TO_RISE] = snap(sum(r[increase_mtus]; init=0.0))
		m[UP_SHARE] = missing
		m[DOWN_SHARE] = missing
		out[agent] = m
	end
	# the shares: each trading agent's net over the total of all trading agents' nets in that segment (the spillage row is
	# not a trade, so it is neither in the total nor given a share)
	agents = [a for a in keys(out) if a != SPILL_AGENT]
	for (metric, share) in ((RESPONSE_TO_FALL, UP_SHARE), (RESPONSE_TO_RISE, DOWN_SHARE))
		total = sum((out[a][metric] for a in agents); init=0.0)
		abs(total) > 1e-9 || continue # nothing traded in this segment: no shares
		for a in agents
			out[a][share] = snap(100 * out[a][metric] / total)
		end
	end
	# the spillage row's volumes are its per-MTU trades (it has no transactions of its own). The wind forecast change row
	# holds the wind change per segment, so in each net-traded row the agents plus Wind spillage add up to minus its value.
	out[CAUSE_AGENT] = Dict{String,Union{Missing,Float64}}(NET => snap(sum(dA; init=0.0)), GROSS => snap(sum(abs, dA; init=0.0)),
		UP => snap(need_up), DOWN => snap(-need_down), RESPONSE_TO_FALL => snap(-need_up), RESPONSE_TO_RISE => snap(need_down),
		UP_SHARE => missing, DOWN_SHARE => missing)
	return out
end

# mtu => change in the wind's available quantity vs the previous clearing's forecast of the same MTU, for the MTUs of
# time_range: the available quantity in the MTU's own (balancing) clearing - final_dispatch_decisions.xlsx, column
# Q_<wind> - minus the one in the RAW export of the clearing before it. MTUs without a previous clearing export are
# skipped (and counted in the warning).
function WindForecastChange(case_path, time_range; wind=WIND_AGENT)
	dispatch = PostAnalysisCommon.LoadFile(joinpath(case_path, "final_dispatch_decisions.xlsx"))
	column = "Q_$wind"
	prefix = PostAnalysisCommon.DiscoverRawDispatchPrefix(case_path)
	delta = Dict{Int,Float64}()
	skipped = 0
	for row in eachrow(dispatch)
		t = row.mtu
		time_range.start <= t <= time_range.stop || continue
		previous = "$(prefix)$(t - 1).xlsx" # the prefix already includes the RAW/ directory
		if !isfile(previous)
			skipped += 1
			continue
		end
		raw = PostAnalysisCommon.LoadFile(previous)
		available_before = raw[raw.mtu .== t, column]
		isempty(available_before) && (skipped += 1; continue)
		delta[t] = snap(Float64(row[column]) - Float64(available_before[1]))
	end
	isempty(delta) && throw("no previous-clearing wind forecast found for any MTU in $time_range under $case_path/RAW")
	skipped > 0 && println("warning: $case_path: no previous-clearing wind forecast for $skipped MTU(s) in $time_range - left out of the need shares")
	return delta
end

# agent => metric => value, from one case's transactions restricted to time_range and the balancing segment.
# wind_forecast_change (mtu => dA, see WindForecastChange) adds the need shares and the spillage / cause rows; without
# it the share rows are missing.
function BalancingTradeQuantities(transactions, time_range; agents=AGENTS, wind_forecast_change=nothing)
	hasproperty(transactions, SEGMENT_COLUMN) || throw("transactions have no \"$SEGMENT_COLUMN\" column - this run predates the balancing/energy split; rerun it")
	in_range = time_range.start .<= transactions[!, MTU_COLUMN] .<= time_range.stop
	balancing = transactions[in_range .& (transactions[!, SEGMENT_COLUMN] .== BALANCING_SEGMENT), :]
	by_agent = Dict{String,Dict{String,Union{Missing,Float64}}}()
	for agent in agents
		m = Dict{String,Union{Missing,Float64}}(k => v for (k, v) in TradeQuantities(Float64.(balancing[balancing.Agent .== agent, QUANTITY_COLUMN]); demand=IsDemandAgent(agent)))
		for metric in NEED_METRICS
			m[metric] = missing
		end
		by_agent[agent] = m
	end
	wind_forecast_change === nothing && return by_agent

	net_by_agent = Dict{String,Dict{Int,Float64}}()
	for agent in unique([agents; WIND_AGENT])
		rows = balancing[balancing.Agent .== agent, :]
		net_by_agent[agent] = Dict(t => sum(rows[rows[!, MTU_COLUMN] .== t, QUANTITY_COLUMN]) for t in unique(rows[!, MTU_COLUMN]))
	end
	for (agent, m) in WindResponseMetrics(net_by_agent, wind_forecast_change)
		if agent in SPILL_AND_CAUSE
			by_agent[agent] = m
		elseif agent in agents # keeps its per-transaction volumes; only the shares come from the cause-and-response accounting
			for metric in NEED_METRICS
				by_agent[agent][metric] = m[metric]
			end
		end
	end
	return by_agent
end

# rows: agent x metric (TABLE_METRICS; the differences of the two share rows are in percentage points); columns: Agent, Metric, one per case, then "{case} vs {previous case} (MWh)" (the difference)
function BuildTable(quantities_by_case, cases; agents=AGENTS, compare_to_subject=false)
	# (compared, base) index pairs of the MWh difference columns
	comparisons = compare_to_subject ? [(length(cases), i) for i in 1:length(cases)-1] : [(i, i-1) for i in 2:length(cases)]
	pairs = Any["Agent" => String[], "Metric" => String[]]
	append!(pairs, [case => Union{Missing,Float64}[] for case in cases])
	append!(pairs, ["$(cases[c]) vs $(cases[b]) (MWh)" => Union{Missing,Float64}[] for (c, b) in comparisons])
	df = DataFrame(pairs...)
	for agent in agents, metric in TABLE_METRICS
		values = [quantities_by_case[case][agent][metric] for case in cases]
		row = Any[DisplayName(agent), metric]
		append!(row, values)
		append!(row, [ismissing(values[c]) || ismissing(values[b]) ? missing : snap(values[c] - values[b]) for (c, b) in comparisons])
		push!(df, row)
	end
	return df
end

# The LaTeX table is a reduced view of the full table (which the xlsx keeps): for every agent the net energy traded, the
# up and down balancing and the agent's share of each direction (the gross volume row is left out); Base, Shoulder and
# Solar are left out since the lock keeps them from trading in the balancing segment; the wind spillage and
# wind forecast change rows are kept, with "--" where a share doesn't apply. Values are formatted here
# (volumes as integers with thousands separators, shares and share differences with one decimal) because the shares
# need decimals that the table-wide integer format would drop.
const TEX_EXCLUDED_AGENTS = ["3G_Base", "4G_Shoulder", "7G_Solar"]
const TEX_METRICS = [NET, UP, DOWN, UP_SHARE, DOWN_SHARE]
const TEX_METRIC_LABELS = Dict(NET => "Net energy traded (MWh)", UP => "Up balancing (MWh)", DOWN => "Down balancing (MWh)",
	UP_SHARE => UP_SHARE, DOWN_SHARE => DOWN_SHARE)

# 1234567.8 -> "1,234,568"
function FormatThousands(x)
	r = round(Int, x)
	return (r < 0 ? "-" : "") * replace(string(abs(r)), r"(?<=\d)(?=(\d{3})+$)" => ",")
end
FormatShare(x) = ismissing(x) ? "--" : string(round(x; digits=1) == 0 ? 0.0 : round(x; digits=1))

function TexTable(df)
	excluded = DisplayName.(TEX_EXCLUDED_AGENTS)
	out = df[[!(row.Agent in excluded) && row.Metric in TEX_METRICS for row in eachrow(df)], :]
	value_columns = names(out)[3:end]
	for col in value_columns
		out[!, col] = [m in SHARE_METRICS ? FormatShare(v) : (ismissing(v) ? "--" : FormatThousands(v)) for (m, v) in zip(out.Metric, out[!, col])]
	end
	out[!, :Metric] = [TEX_METRIC_LABELS[m] for m in out.Metric]
	return out
end

function InterpretationTable()
	general = [
		"READ FIRST - what the table shows" => "The balancing segment is the first, locked MTU of each clearing. For every agent the table gives the net energy it traded in that segment, separately for the MTUs where the wind's available quantity fell and for those where it rose, and the agent's share of the total traded by all agents in those MTUs.",
		"READ FIRST - sign convention" => "Positive = energy injected into the system, negative = energy withdrawn. For generators and storage a positive transaction quantity is an increase in supply (storage: discharging) and a negative one a decrease (storage: charging). Demand quantities are consumption, so for a demand agent the sign is flipped: a consumption reduction is an injection (positive) and a consumption increase a withdrawal (negative).",
		"READ FIRST - wind-decrease and wind-increase MTUs" => "A wind-decrease MTU is a balancing MTU where the wind agent's available quantity is lower than in the previous clearing's forecast of the same MTU, so the other agents together have to inject energy. A wind-increase MTU is one where it is higher, so they have to withdraw energy. MTUs without a previous-clearing forecast are left out. In every net-traded row the agents' values plus the row Wind spillage add up to minus the row Wind forecast change.",
		"READ FIRST - difference columns" => "The columns named 'X vs Y' are X minus Y: in MWh for the net-traded rows, in percentage points for the share rows.",
		"READ FIRST - empty cells ('--')" => "Not applicable: the wind agent and the two Wind rows have no share, and if the previous clearings' forecasts were not available for a run the rows are empty for every agent. A share is also empty when the agents traded nothing in that segment.",
	]
	metrics = [
		RESPONSE_TO_FALL => "Per balancing MTU where the wind's available quantity fell: the agent's net balancing trade in that MTU (all its balancing transactions added up, demand sign-flipped), summed over those MTUs, in MWh. Positive = it injected energy, negative = it withdrew energy.",
		UP_SHARE => "= Net traded in wind-decrease MTUs / the sum of that row over all agents (the rows Wind spillage and Wind forecast change are not in the sum) x 100. Adds up to 100 over the agents. Negative = the agent's net trade had the opposite sign from the total (for example it withdrew energy while the agents together injected); above 100 = the agent traded more than the total since others traded the opposite way. Percentage points in the difference columns. Wind has none.",
		RESPONSE_TO_RISE => "Per balancing MTU where the wind's available quantity rose: the agent's net balancing trade in that MTU, summed over those MTUs, in MWh. Same sign convention (positive = injected, negative = withdrew), so in these MTUs the agents that help are negative.",
		DOWN_SHARE => "= Net traded in wind-increase MTUs / the sum of that row over all agents (the rows Wind spillage and Wind forecast change are not in the sum) x 100. Same conventions as the share in wind-decrease MTUs. Wind has none.",
		SPILL_AGENT => "Not a trade. Per balancing MTU: the wind agent's own net balancing trade minus the change in its available quantity, i.e. minus the change in its spillage (extra spillage is a withdrawal, less spillage an injection), summed over the wind-decrease MTUs and over the wind-increase MTUs, in MWh. It is left out of the share totals and has no share.",
		CAUSE_AGENT => "Not a trade. The change in the wind agent's available quantity versus the previous clearing's forecast of the same MTU, summed over the wind-decrease MTUs (negative: less wind than planned) and over the wind-increase MTUs (positive), in MWh. In each of the two rows the agents plus Wind spillage add up to minus this value. No shares.",
	]
	rows = [general; metrics]
	return DataFrame(Metric=first.(rows), Interpretation=last.(rows))
end

# cases is any N case_paths keys; time_range nothing is the window the runs' own configs define
# (see PostAnalysisCommon.ResolveTimeRange)
function PerformAnalysis(case_paths; cases=PostAnalysisCommon.CASES, output_base=PostAnalysisCommon.NewAnalysisOutputDir(case_paths), time_range=nothing, compare_to_subject=false)
	PostAnalysisCommon.SetPlotMark!(case_paths, cases)
	println("starting analysis: balancing trade quantities")
	time_range = PostAnalysisCommon.ResolveTimeRange(time_range, case_paths, cases; output_base=output_base)

	analysis_dir_path = "$output_base/balancing_trade_quantities"
	PostAnalysisCommon.CleanDirectory(analysis_dir_path)

	# the wind forecast change from each run's previous-clearing forecasts; a run without the RAW exports
	# gets empty share rows instead of failing
	wind_change = Dict{String,Union{Nothing,Dict{Int,Float64}}}()
	for case in cases
		wind_change[case] = try
			WindForecastChange(case_paths[case], time_range)
		catch err
			println("warning: $case: wind forecast change unavailable ($err) - the need-share rows stay empty")
			nothing
		end
	end
	quantities_by_case = Dict(case => BalancingTradeQuantities(PostAnalysisCommon.LoadCaseFile(case_paths, case, "transactions.xlsx"), time_range; wind_forecast_change=wind_change[case]) for case in cases)
	have_cause = all(c -> wind_change[c] !== nothing, cases)
	df = BuildTable(quantities_by_case, cases; agents=have_cause ? [AGENTS; SPILL_AND_CAUSE] : AGENTS, compare_to_subject=compare_to_subject)
	println(df)

	# the workbook has the net traded and its share per wind segment (the per-transaction volumes stay out of it)
	segments_df = df[df.Metric .∈ Ref(NEED_METRICS), :]
	sheets = Pair{String,DataFrame}["up-down segments" => segments_df, "interpretation" => InterpretationTable()]
	XLSX.writetable("$analysis_dir_path/balancing_trade_quantities.xlsx", sheets...; overwrite=true)
	write("$analysis_dir_path/balancing_trade_quantities.tex",
		latexify(PostAnalysisCommon.EscapeForLatex(TexTable(df)); env=:table, booktabs=true, snakecase=true, latex=false, fmt="%'\''d\n"))
	if have_cause
		mtu_counts = Dict(case => (fall=count(<(0), values(wind_change[case])), rise=count(>(0), values(wind_change[case]))) for case in cases)
		PlotResponseBars(quantities_by_case, cases, mtu_counts, "$analysis_dir_path/response_by_wind_segment.png")
	end
	return df
end

# categorical slots 1-3 of the dataviz reference palette (blue, orange, aqua), light surface
const BAR_COLORS = ["#2a78d6", "#eb6834", "#1baf7a"]
const SURFACE = "#fcfcfb"
const AXIS_COLOR = "#c3c2b7"
const GRID_COLOR = "#e1e0d9"
const TEXT_PRIMARY = "#0b0b0b"
const TEXT_MUTED = "#898781"

# Grouped bars of the net response (view 2 of the table) by responder, one bar per case in two panels that share one
# convention and one y axis (zero lines up): positive = energy INJECTED into the system (supply up, storage discharging,
# demand consuming less), negative = energy TAKEN OUT (supply down, storage charging, demand consuming more). So a bar
# means the same on both sides. Left: the wind-fall MTUs, where up-balancing is needed, so the need and the responders
# that help are positive (the table's wind-fall rows as they are); right: the wind-rise MTUs, where down-balancing is
# needed, so the need and the helping responders are negative (the table's wind-rise rows, flipped). The need is the
# response the system has to deliver to offset the wind forecast change summed over those MTUs (so it has the opposite sign
# to the wind's own change); the responders' bars add up to it, and a bar on the other side of zero than the need is a move
# against it. Responders with no response in any case are left out.
# The first bar of each panel (grey, one for both cases) is the wind availability change itself with its true sign
# (negative when the wind falls: less energy injected); the responders' bars add up to its mirror image.
function PlotResponseBars(quantities_by_case, cases, mtu_counts, path)
	length(cases) <= length(BAR_COLORS) || (println("warning: more than $(length(BAR_COLORS)) cases - response bar chart skipped"); return)
	candidates = [filter(a -> a != WIND_AGENT, AGENTS); SPILL_AGENT]
	# (table row, title, MTU count field, sign): both table rows already use the "positive = energy injected" convention
	panels = [(RESPONSE_TO_FALL, "Sum of Trades when Wind Availability Decreases", :fall, 1.0), (RESPONSE_TO_RISE, "Sum of Trades when Wind Availability Increases", :rise, 1.0)]
	value(case, a, metric, sign) = sign * Float64(quantities_by_case[case][a][metric])
	shown = filter(a -> any(case -> any(((metric, _, _, _),) -> !ismissing(get(quantities_by_case[case][a], metric, missing)) && abs(quantities_by_case[case][a][metric]) > 1e-6, panels), cases), candidates)
	label(a) = a == SPILL_AGENT ? "Wind\nspillage" : replace(DisplayName(a), " " => "\n")

	# one y range for both panels, over every bar, with headroom for the legend (autoscaling would clip later bars)
	all_values = [value(case, a, metric, sign) for (metric, _, _, sign) in panels for case in cases for a in shown]
	append!(all_values, [sign * quantities_by_case[cases[1]][CAUSE_AGENT][metric] for (metric, _, _, sign) in panels])
	low, high = min(0.0, minimum(all_values)), max(0.0, maximum(all_values))
	span = max(high - low, 1.0)
	ylims = (low < 0 ? low - 0.06 * span : 0.0, high + 0.2 * span)

	chrome = (background_color=SURFACE, foreground_color_axis=AXIS_COLOR, foreground_color_border=AXIS_COLOR,
		foreground_color_text=TEXT_PRIMARY, foreground_color_guide=TEXT_PRIMARY, foreground_color_legend=SURFACE,
		gridcolor=GRID_COLOR, gridalpha=1.0, gridlinewidth=0.5, tickfontcolor=TEXT_MUTED, tickfontsize=10, guidefontsize=11)
	width = 0.8 / length(cases)
	plots = []
	for (k, (metric, title, segment, sign)) in enumerate(panels)
		need = sign * quantities_by_case[cases[1]][CAUSE_AGENT][metric]
		n = getfield(mtu_counts[cases[1]], segment)
		p = Plots.plot(; title="$title\n$(segment == :fall ? "Decreased" : "Increased") $(FormatThousands(abs(need))) MWh over $n MTUs", titlefontsize=11,
			ylabel=k == 1 ? "Net Energy Traded in Balancing MTUs\npositive = injections, negative = withdrawals" : "",
			xticks=(1:length(shown)+1, ["Wind
availability
change"; label.(shown)]), yformatter=y -> FormatThousands(y), ylims=ylims, legend=k == 1 ? :topright : false,
			left_margin=k == 1 ? 16Plots.mm : 4Plots.mm, bottom_margin=8Plots.mm, top_margin=4Plots.mm, chrome...)
		Plots.hline!(p, [0.0]; label=false, color=AXIS_COLOR, linewidth=1)
		Plots.bar!(p, [1.0], [need]; bar_width=0.7, label=false, color=TEXT_MUTED, linewidth=0)
		for (i, case) in enumerate(cases)
			offset = (i - (length(cases) + 1) / 2) * width
			Plots.bar!(p, (1:length(shown)) .+ 1 .+ offset, [value(case, a, metric, sign) for a in shown]; bar_width=width * 0.92, label=k == 1 ? case : "", color=BAR_COLORS[i], linewidth=0)
		end
		push!(plots, p)
	end
	fig = Plots.plot(plots...; layout=(1, 2), size=(1280, 560), background_color=SURFACE)
	display(fig)
	PostAnalysisCommon.SaveFigure(fig, path)
end

end;

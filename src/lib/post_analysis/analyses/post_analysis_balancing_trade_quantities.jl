# Trade quantities by agent in the balancing segment only: what each agent traded in the locked (balancing)
# MTUs of the clearings, read from the Segment == Balancing transactions (see
# balancing_energy/balancing_energy_split.jl for how the two segments are defined). Per agent, over the analysis
# time_range (transactions bucketed by delivery MTU, like every other metric in this suite):
#
#   Net traded (MWh)     - sum of the signed transaction quantities
#   Gross traded (MWh)   - sum of |quantity|
#   Up balancing (MWh)   - energy the agent added to the system: its supply increases (positive quantities of a generator
#                          or storage discharge) or, for a demand agent, its consumption reductions
#   Down balancing (MWh) - energy the agent took out of the system, reported as a negative number: supply decreases
#                          (negative quantities of a generator, storage charging) or demand consumption increases
#   Share of up / down balancing need met (%) - see "Cause and response" below
#
# Cause and response. The wind forecast change is taken as the cause of the balancing need and every other
# adjustment as the response to it. In each balancing MTU t:
#   cause     dA_t   = wind available now - wind available in the previous clearing's forecast of the same MTU
#                      (< 0: wind fell, up balancing is needed; > 0: wind rose, down balancing is needed)
#   response  R_i,t  = agent i's net balancing quantity in t (a demand agent's with the sign flipped: a consumption
#                      reduction is an up response), for every agent but wind, and
#             R_spill,t = W_t - dA_t, the wind spillage response (W_t = the wind agent's own net balancing trade;
#                      extra spillage is a down response, so the wind trade is the cause plus its spillage response)
# The balancing transactions net to zero in every MTU, so the responses add up to the need exactly:
# sum_i R_i,t + R_spill,t = -dA_t. An agent's share of the up-balancing need met is its summed response over the MTUs
# where wind fell divided by the total fall (sum of -dA_t there); the down share likewise over the MTUs where wind
# rose. Each direction's shares sum to 100% over the responders (agents and spillage); a share is negative when the
# responder moved against the need, and wind itself has no share. The table gets two extra rows: "Wind spillage
# (response)" and "Wind forecast change (cause)" (net = sum of dA, up / down = the up / down need, shares blank).
# The shares need the previous clearings' forecasts, read from each run's RAW exports; without them (dA not given)
# the share rows are empty.
#
# Quantities are adjustments to what the agent had already traded in earlier clearings, so net traded is the
# agent's net change from balancing and gross traded how much it moved. Up and down are summed per transaction (not
# netted per MTU); for a supply agent up + down = net, for a demand agent up + down = -net (net is its consumption
# change). One row per agent and metric, one
# column per case, then MWh difference columns (compared minus base, not percentages): by default "{case} vs {previous case}" for each adjacent pair
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
const UP_SHARE = "Share of up-balancing need met (%)"
const DOWN_SHARE = "Share of down-balancing need met (%)"
const METRICS = [NET, GROSS, UP, DOWN]                # per-agent volumes (the cluster comparison modules iterate these)
const RESPONSE_TO_FALL = "Net response in wind-fall MTUs (MWh)"
const RESPONSE_TO_RISE = "Net response in wind-rise MTUs (MWh)"
const SHARE_METRICS = [UP_SHARE, DOWN_SHARE]          # shares of the wind-caused need, from WindResponseMetrics
const NEED_METRICS = [RESPONSE_TO_FALL, UP_SHARE, RESPONSE_TO_RISE, DOWN_SHARE] # each response row is followed by its share
const TABLE_METRICS = [METRICS; NEED_METRICS]         # rows of the table, per agent

const WIND_AGENT = "6G_Wind"
const SPILL_AGENT = "Wind spillage (response)"        # pseudo-agent rows of the table, see "Cause and response"
const CAUSE_AGENT = "Wind forecast change (cause)"
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

# Responses and shares of the wind-caused balancing need (see "Cause and response" in the header).
#   net_by_agent  agent => (mtu => net balancing quantity of the agent in that MTU), including the wind agent
#   delta_a       mtu => change in the wind's available quantity (now - previous clearing's forecast)
# Returns agent => metrics (volumes plus UP_SHARE / DOWN_SHARE) for every agent but wind, and SPILL_AGENT and CAUSE_AGENT
# entries; the wind agent's own metrics are left to the caller (it has no share).
function WindResponseMetrics(net_by_agent, delta_a; wind=WIND_AGENT)
	mtus = sort(collect(keys(delta_a)))
	net(agent, t) = get(get(net_by_agent, agent, Dict{Int,Float64}()), t, 0.0)
	# per-MTU responses: agents (a demand agent's consumption reduction is an up response) and the wind spillage
	responses = Dict{String,Vector{Float64}}()
	for agent in keys(net_by_agent)
		agent == wind && continue # the cause, not a responder
		sign =IsDemandAgent(agent) ? -1.0 : 1.0
		responses[agent] = [sign * net(agent, t) for t in mtus]
	end
	responses[SPILL_AGENT] = [net(wind, t) - delta_a[t] for t in mtus] # W_t - dA_t = -(change in spillage)
	dA = [delta_a[t] for t in mtus]
	up_mtus, down_mtus = dA .< 0, dA .> 0
	need_up, need_down = sum(-dA[up_mtus]; init=0.0), sum(dA[down_mtus]; init=0.0)

	out = Dict{String,Dict{String,Union{Missing,Float64}}}()
	for (agent, r) in responses
		m = Dict{String,Union{Missing,Float64}}(k => v for (k, v) in TradeQuantities(r))
		# the response that counts toward the need: in wind-fall MTUs the up response, in wind-rise MTUs the down response
		# (the response with its sign flipped, so a move that helps is positive and one against the need is negative)
		m[RESPONSE_TO_FALL] = snap(sum(r[up_mtus]; init=0.0))
		m[RESPONSE_TO_RISE] = snap(-sum(r[down_mtus]; init=0.0))
		m[UP_SHARE] = need_up > 0 ? snap(100 * m[RESPONSE_TO_FALL] / need_up) : 0.0
		m[DOWN_SHARE] = need_down > 0 ? snap(100 * m[RESPONSE_TO_RISE] / need_down) : 0.0
		out[agent] = m
	end
	# the spillage row's volumes are its per-MTU responses (it has no transactions of its own). The cause row holds the
	# needs, so in each response row the responders add up to the cause's value.
	out[CAUSE_AGENT] = Dict{String,Union{Missing,Float64}}(NET => snap(sum(dA; init=0.0)), GROSS => snap(sum(abs, dA; init=0.0)),
		UP => snap(need_up), DOWN => snap(-need_down), RESPONSE_TO_FALL => snap(need_up), RESPONSE_TO_RISE => snap(need_down),
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
# Solar are left out since the lock keeps them from trading in the balancing segment; the wind spillage (response) and
# wind forecast change (cause) rows are kept, with "--" where a share doesn't apply. Values are formatted here
# (volumes as integers with thousands separators, shares and share differences with one decimal) because the shares
# need decimals that the table-wide integer format would drop.
const TEX_EXCLUDED_AGENTS = ["3G_Base", "4G_Shoulder", "7G_Solar"]
const TEX_METRICS = [NET, UP, DOWN, UP_SHARE, DOWN_SHARE]
const TEX_METRIC_LABELS = Dict(NET => "Net energy traded (MWh)", UP => "Up balancing (MWh)", DOWN => "Down balancing (MWh)",
	UP_SHARE => "Share of up-balancing need met (%)", DOWN_SHARE => "Share of down-balancing need met (%)")

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
		"READ FIRST - two views" => "The table describes the balancing segment (the first, locked MTU of each clearing) in two different ways that answer different questions. VIEW 1 (rows Net traded, Gross traded, Up balancing, Down balancing) looks at each agent's transactions on their own. VIEW 2 (rows Net response in wind-fall MTUs, Net response in wind-rise MTUs and the two Share rows) asks who responded to the wind forecast change, taking that change as the CAUSE of the balancing need and every other adjustment as the response. The two views can disagree for the same agent; that is expected (see the example below).",
		"READ FIRST - sign convention" => "Up = adds energy to the system, Down = takes energy out. For generators and storage a positive transaction quantity is an increase in supply (storage: discharging) and a negative one a decrease (storage: charging). Demand quantities are consumption, so a demand agent's consumption REDUCTION counts as up and a consumption INCREASE as down in every row except Net traded, which keeps the transaction sign (positive = consumed more).",
		"READ FIRST - wind-fall and wind-rise MTUs" => "A wind-fall MTU is a balancing MTU where the wind agent's available quantity is lower than in the previous clearing's forecast of the same MTU, so up-balancing is needed. A wind-rise MTU is one where it is higher, so down-balancing is needed. The up (down) need is the total size of these changes: the sum of the absolute changes over the wind-fall (wind-rise) MTUs. MTUs without a previous-clearing forecast are left out. Responders = every agent except wind, plus the row Wind spillage (response).",
		"READ FIRST - why the views disagree" => "An agent can show 0 in Up balancing and a negative Net response in wind-fall MTUs. Up balancing (view 1) counts only the transactions that add energy, each by its own sign, whatever the wind did in that MTU. Net response in wind-fall MTUs (view 2) adds up EVERYTHING the agent did in the MTUs where wind fell. A demand agent that consumed 100 MWh more in a wind-fall MTU therefore shows 0 up balancing but -100 there: none of its transactions was an up transaction, and it moved against the need. A negative response or share always means the agent moved against the need.",
		"READ FIRST - difference columns" => "The columns named 'X vs Y' are X minus Y: in MWh for the volume and response rows, in percentage points for the two Share rows.",
		"READ FIRST - empty cells ('--')" => "Not applicable: the wind agent has no response or share (it is the cause), and the cause row has no shares. If the previous clearings' forecasts were not available for a run, the response and share rows are empty for every agent.",
	]
	metrics = [
		NET => "VIEW 1. Sum of the signed quantities of the agent's Segment == Balancing transactions in the analysis window: its net change from balancing. For a demand agent it is its consumption change (positive = consumed more).",
		GROSS => "VIEW 1. Sum of the absolute quantities: how much the agent moved in the balancing segment, in either direction.",
		UP => "VIEW 1. Sum over the agent's balancing transactions that add energy to the system: supply increases (generator positive quantities, storage discharging) or, for a demand agent, consumption reductions. Each transaction is classified by its own sign, regardless of what the wind did in that MTU. Zero or positive.",
		DOWN => "VIEW 1. Sum over the agent's balancing transactions that take energy out of the system: supply decreases (generator negative quantities, storage charging) or, for a demand agent, consumption increases. Reported as a negative number (zero or negative). For generators and storage Up + Down = Net; for a demand agent Up + Down = -Net.",
		RESPONSE_TO_FALL => "VIEW 2. In the wind-fall MTUs (up-balancing needed): the agent's net response, summed over those MTUs. Per MTU it is the net of all the agent's balancing transactions in that MTU, positive when the agent added energy (supply up / consumption down) and negative when it moved against the need. The responders' values add up exactly to the up-balancing need shown on the row 'Wind forecast change (cause)'. MWh. Wind has none.",
		UP_SHARE => "VIEW 2. = Net response in wind-fall MTUs / up-balancing need x 100: the agent's part of the up-balancing need. Adds up to 100 over the responders. Negative = the agent moved against the need; above 100 = the agent did more than the whole need while others moved against it. Percentage points in the difference columns. Wind has none.",
		RESPONSE_TO_RISE => "VIEW 2. In the wind-rise MTUs (down-balancing needed): the agent's net response, summed over those MTUs, with the sign chosen so that a move that helps is positive: positive when the agent took energy out (supply down / consumption up), negative when it moved against the need (supply up / consumption down). The responders' values add up exactly to the down-balancing need on the row 'Wind forecast change (cause)'. MWh. Wind has none.",
		DOWN_SHARE => "VIEW 2. = Net response in wind-rise MTUs / down-balancing need x 100: the agent's part of the down-balancing need. Same conventions as the up share. Wind has none.",
	]
	rows = [general; metrics]
	return DataFrame(Metric=first.(rows), Interpretation=last.(rows))
end

# Interpretation of the two pseudo-agent rows (see "Cause and response" in the header)
function CauseAndResponseNotes()
	return DataFrame(
		Row=SPILL_AND_CAUSE,
		Interpretation=[
			"A responder, not a trader. Per balancing MTU: the wind agent's own net balancing trade minus the change in its available quantity, i.e. minus the change in its spillage (extra spillage is a down response, less spillage an up response). Its Net traded / Gross / Up / Down rows are computed from these per-MTU responses (view 1 style, but per MTU rather than per transaction); its response and share rows work as for every responder (view 2).",
			"The cause, not a responder. The change in the wind's available quantity vs the previous clearing's forecast of the same MTU. Net traded = sum of the changes (negative: less wind than planned); Gross = sum of the absolute changes; Up balancing = total fall (the up-balancing need); Down balancing = total rise as a negative number (the down-balancing need); Net response in wind-fall MTUs = the up-balancing need and Net response in wind-rise MTUs = the down-balancing need, the totals each column of responders adds up to. No shares.",
		],
	)
end

# cases is any N case_paths keys; time_range nothing is the window the runs' own configs define
# (see PostAnalysisCommon.ResolveTimeRange)
function PerformAnalysis(case_paths; cases=PostAnalysisCommon.CASES, output_base=PostAnalysisCommon.NewAnalysisOutputDir(case_paths), time_range=nothing, compare_to_subject=false)
	PostAnalysisCommon.SetPlotMark!(case_paths, cases)
	println("starting analysis: balancing trade quantities")
	time_range = PostAnalysisCommon.ResolveTimeRange(time_range, case_paths, cases; output_base=output_base)

	analysis_dir_path = "$output_base/balancing_trade_quantities"
	PostAnalysisCommon.CleanDirectory(analysis_dir_path)

	# the wind forecast change (the cause) from each run's previous-clearing forecasts; a run without the RAW exports
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

	# trades per agent (net, gross, up, down) on "trades"; the cause and response values and shares on "up-down segments"
	trades_df = df[df.Metric .∈ Ref(METRICS), :]
	response_df = df[df.Metric .∈ Ref(NEED_METRICS), :]
	sheets = Pair{String,DataFrame}["trades" => trades_df]
	have_cause && push!(sheets, "up-down segments" => response_df)
	push!(sheets, "interpretation" => InterpretationTable())
	have_cause && push!(sheets, "response notes" => CauseAndResponseNotes())
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

# Grouped bars of the net response (view 2 of the table) by responder, one bar per case, with the need as a dashed line, in two panels that share one
# convention and one y axis (zero lines up): positive = energy INJECTED into the system (supply up, storage discharging,
# demand consuming less), negative = energy TAKEN OUT (supply down, storage charging, demand consuming more). So a bar
# means the same on both sides. Left: the wind-fall MTUs, where up-balancing is needed, so the need and the responders
# that help are positive (the table's wind-fall rows as they are); right: the wind-rise MTUs, where down-balancing is
# needed, so the need and the helping responders are negative (the table's wind-rise rows, flipped). The need is the
# response the system has to deliver to offset the wind forecast change summed over those MTUs (so it has the opposite sign
# to the wind's own change); the responders' bars add up to it, and a bar on the other side of zero than the need is a move
# against it. Responders with no response in any case are left out.
function PlotResponseBars(quantities_by_case, cases, mtu_counts, path)
	length(cases) <= length(BAR_COLORS) || (println("warning: more than $(length(BAR_COLORS)) cases - response bar chart skipped"); return)
	candidates = [filter(a -> a != WIND_AGENT, AGENTS); SPILL_AGENT]
	# (table row, title, MTU count field, sign): the wind-rise rows are flipped to the "positive = energy injected" convention
	panels = [(RESPONSE_TO_FALL, "Wind-fall MTUs: up-balancing needed", :fall, 1.0), (RESPONSE_TO_RISE, "Wind-rise MTUs: down-balancing needed", :rise, -1.0)]
	value(case, a, metric, sign) = sign * Float64(quantities_by_case[case][a][metric])
	shown = filter(a -> any(case -> any(((metric, _, _, _),) -> !ismissing(get(quantities_by_case[case][a], metric, missing)) && abs(quantities_by_case[case][a][metric]) > 1e-6, panels), cases), candidates)
	label(a) = a == CAUSE_AGENT ? "Need\n(wind change)" : a == SPILL_AGENT ? "Wind\nspillage" : replace(DisplayName(a), " " => "\n")

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
		p = Plots.plot(; title="$title\nneed $(FormatThousands(need)) MWh over $n MTUs", titlefontsize=11,
			ylabel=k == 1 ? "Net response (MWh)\npositive = energy injected into the system, negative = taken out" : "",
			xticks=(1:length(shown), label.(shown)), yformatter=y -> FormatThousands(y), ylims=ylims, legend=k == 1 ? :topright : false,
			left_margin=k == 1 ? 16Plots.mm : 4Plots.mm, bottom_margin=8Plots.mm, top_margin=4Plots.mm, chrome...)
		Plots.hline!(p, [0.0]; label=false, color=AXIS_COLOR, linewidth=1)
		Plots.hline!(p, [need]; label=k == 1 ? "Required response (offsets the wind change)" : false, color=TEXT_PRIMARY, linewidth=2, linestyle=:dash)
		for (i, case) in enumerate(cases)
			offset = (i - (length(cases) + 1) / 2) * width
			Plots.bar!(p, (1:length(shown)) .+ offset, [value(case, a, metric, sign) for a in shown]; bar_width=width * 0.92, label=k == 1 ? case : "", color=BAR_COLORS[i], linewidth=0)
		end
		push!(plots, p)
	end
	fig = Plots.plot(plots...; layout=(1, 2), size=(1280, 560), background_color=SURFACE)
	display(fig)
	PostAnalysisCommon.SaveFigure(fig, path)
end

end;

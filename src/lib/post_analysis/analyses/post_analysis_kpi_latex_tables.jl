# LaTeX comparison tables: our computed KPIs (laura_kpi_validation.xlsx, from
# post_analysis_laura_kpis.jl) vs Laura's own reference economic_summary.xlsx, for both the
# fixed36 and rolling36 cases. One table per case, columns: KPI | Ours | Laura | Difference.
#
# Only includes KPIs we have an actual validated computed figure for (see
# post_analysis_laura_kpis.jl for how each is derived and why it matches the specific Laura
# section it's paired with - e.g. generator revenue compares against her "TOTAL FINANCIAL
# REVENUE" section, not "PRODUCER REVENUES (Executed-only)", per the divergence investigated
# earlier this session). Skips KPIs we don't independently compute (Average Executed Price,
# Generator Profits, the Delivery-Hour Audit section).
#
# Laura's reference file layout (economic_summary.xlsx, "Summary" sheet) is read by fixed
# (row, col) position - established by dumping both fixed_36h/economic_summary.xlsx and
# rolling_36h/economic_summary.xlsx from thesis_runs/all_20260603_101337 (both share the same
# template/row layout) and matching each row to its section header.

module PostAnalysisKPILatexTables

using XLSX, DataFrames, Printf

results_path_base = "results/analysis"

our_kpi_path = "results/validation_results/validation/laura_kpi_validation.xlsx"

laura_batch_dir = raw"C:\Users\Atkin005\OneDrive - Universiteit Utrecht\Documents\julia\Code\market_clearing\Results\thesis_runs\all_20260603_101337"
laura_case_dirs = Dict("Fixed" => "fixed_36h", "Rolling" => "rolling_36h")

our_case_label = Dict("Fixed" => "Fixed Horizon", "Rolling" => "Rolling Horizon")

generators = ["Base", "Shoulder", "Peak", "Wind", "Solar"]
generator_agent_names = Dict(
	"Base" => "3G_Base", "Shoulder" => "4G_Shoulder", "Peak" => "5G_Peak",
	"Wind" => "6G_Wind", "Solar" => "7G_Solar",
)
# Laura's generator naming differs ("Mid" instead of "Shoulder") - same row layout otherwise
laura_generator_names = Dict(
	"Base" => "Base", "Shoulder" => "Mid", "Peak" => "Peak", "Wind" => "Wind", "Solar" => "Solar",
)

function CleanDirectory(path)
	mkpath(path)
end

# reads Laura's Summary sheet once per case, returning a Dict keyed by our own descriptive
# labels (built below) so the rest of the code never has to touch a raw (row, col) pair again
function LoadLauraSummary(case)
	path = joinpath(laura_batch_dir, laura_case_dirs[case], "economic_summary.xlsx")
	xf = XLSX.readxlsx(path)
	sh = xf["Summary"]

	vals = Dict{String,Float64}()
	vals["Socioeconomic Welfare (€)"] = sh[7, 2]
	vals["Demand Utility (€)"] = sh[5, 2]
	vals["Production Costs (€)"] = sh[6, 2]
	vals["Imbalance (MWh)"] = sh[6, 6]
	vals["Wind Curtailment (MWh)"] = sh[5, 6]

	# "PRODUCER REVENUES (Executed-only)" section - Energy (MWh) column, rows 11-15 per generator
	# plus row 16's Total - the executed-only physical dispatch quantity, distinct from the
	# Net/Gross Traded columns in "TOTAL FINANCIAL REVENUE" below (those sum adjustment legs
	# across every clearing that touched an MTU, not just the one that executed it).
	dispatch_quantity_row = Dict("Base" => 11, "Shoulder" => 12, "Peak" => 13, "Solar" => 14, "Wind" => 15)
	for gen in generators
		vals["Dispatch Quantity - $gen (MWh)"] = sh[dispatch_quantity_row[gen], 2]
	end
	vals["Dispatch Quantity - Total (MWh)"] = sh[16, 2]

	generator_cost_row = Dict("Base" => 29, "Shoulder" => 30, "Peak" => 31, "Solar" => 32, "Wind" => 33)
	for gen in generators
		vals["Production Cost - $gen (€)"] = sh[generator_cost_row[gen], 2]
	end

	# "TOTAL FINANCIAL REVENUE" section: Gross Traded (col 4) and Net Revenue (col 2, relabeled
	# "Generator Cashflow" - it's raw revenue = sum(quantity*price), not netted against
	# Production Cost, so "Cashflow" avoids implying it's already a profit/surplus figure). Net
	# Traded (col 3) stays dropped. Row 25's own totals (cols 2 and 4) are blank in her sheet, so
	# sum the 5 generators ourselves for both.
	gross_traded_row = Dict("Base" => 20, "Shoulder" => 21, "Peak" => 22, "Solar" => 23, "Wind" => 24)
	total_gross_traded = 0.0
	total_cashflow = 0.0
	for gen in generators
		r = gross_traded_row[gen]
		v = sh[r, 4]
		vals["Gross Traded Volume - $gen (MWh)"] = v
		total_gross_traded += v
		c = sh[r, 2]
		vals["Generator Cashflow - $gen (€)"] = c
		total_cashflow += c
	end
	vals["Gross Traded Volume - Total (MWh)"] = total_gross_traded
	vals["Generator Cashflow - Total (€)"] = total_cashflow

	# "GENERATOR PROFITS (Full Revenue - Cost)" section - Total Profit column, rows 39-43 per
	# generator plus row 44's real Total (unlike Gross Traded/Cashflow above, this total cell
	# isn't blank in her sheet). Relabeled "Generator Surplus" - unlike Cashflow, this genuinely
	# is netted against Production Cost, so "Surplus" is accurate here.
	profit_row = Dict("Base" => 39, "Shoulder" => 40, "Peak" => 41, "Solar" => 42, "Wind" => 43)
	for gen in generators
		vals["Generator Surplus - $gen (€)"] = sh[profit_row[gen], 2]
	end
	vals["Generator Surplus - Total (€)"] = sh[44, 2]

	vals["Energy Discharged (MWh)"] = sh[48, 2]
	vals["Energy Charged (MWh)"] = sh[49, 2]
	vals["Avg Discharge Price (€/MWh)"] = sh[50, 2]
	vals["Avg Charging Price (€/MWh)"] = sh[51, 2]
	vals["Discharge Revenue (€)"] = sh[52, 2]
	vals["Charging Cost (€)"] = sh[53, 2]
	vals["Net Revenue (€)"] = sh[54, 2]
	vals["Total Losses (MWh)"] = sh[55, 2]
	vals["SOC End of Horizon (MWh)"] = sh[56, 2]

	return vals
end

# reads our own laura_kpi_validation.xlsx (already computed by post_analysis_laura_kpis.jl),
# returning a Dict keyed by the SAME labels LoadLauraSummary uses
function LoadOurKPIs(case)
	label = our_case_label[case]
	vals = Dict{String,Float64}()

	econ = DataFrame(XLSX.readtable(our_kpi_path, "economic_indicators"))
	econ_row = econ[(econ.Case .== label) .& (econ.Period .== "Total"), :][1, :]
	vals["Socioeconomic Welfare (€)"] = econ_row[Symbol("Socioeconomic Welfare (€)")]
	vals["Demand Utility (€)"] = econ_row[Symbol("Demand Utility (€)")]
	vals["Production Costs (€)"] = econ_row[Symbol("Production Costs (€)")]

	imbalance = DataFrame(XLSX.readtable(our_kpi_path, "imbalance"))
	vals["Imbalance (MWh)"] = imbalance[imbalance.Case .== label, :ImbalanceEnergy][1]
	vals["Wind Curtailment (MWh)"] = econ_row[Symbol("Wind Curtailed (MWh)")]

	agents = DataFrame(XLSX.readtable(our_kpi_path, "agent_indicators"))
	agents_case = agents[agents.Case .== label, :]
	total_dispatch_quantity = 0.0
	for gen in generators
		row = agents_case[agents_case.Agent .== generator_agent_names[gen], :][1, :]
		vals["Production Cost - $gen (€)"] = row[Symbol("Fuel Cost (€)")]
		vals["Dispatch Quantity - $gen (MWh)"] = row[Symbol("Quantity (MWh)")]
		total_dispatch_quantity += row[Symbol("Quantity (MWh)")]
	end
	vals["Dispatch Quantity - Total (MWh)"] = total_dispatch_quantity

	gross_vol = DataFrame(XLSX.readtable(our_kpi_path, "gross_traded_volume"))
	gross_vol_case = gross_vol[gross_vol.Case .== label, :]
	total_gross_traded = 0.0
	for gen in generators
		row = gross_vol_case[gross_vol_case.Agent .== generator_agent_names[gen], :][1, :]
		vals["Gross Traded Volume - $gen (MWh)"] = row.GrossTradedVolume
		total_gross_traded += row.GrossTradedVolume
	end
	vals["Gross Traded Volume - Total (MWh)"] = total_gross_traded

	# "total_financial_revenue" sheet's NetRevenue = sum(quantity*price), matching Laura's
	# "TOTAL FINANCIAL REVENUE" col 2 - same transactions basis as Gross Traded Volume above
	# (full look-ahead window, not executed-only), just signed instead of summed as |q|.
	fin_rev = DataFrame(XLSX.readtable(our_kpi_path, "total_financial_revenue"))
	fin_rev_case = fin_rev[fin_rev.Case .== label, :]
	total_cashflow = 0.0
	for gen in generators
		row = fin_rev_case[fin_rev_case.Agent .== generator_agent_names[gen], :][1, :]
		vals["Generator Cashflow - $gen (€)"] = row.NetRevenue
		total_cashflow += row.NetRevenue
	end
	vals["Generator Cashflow - Total (€)"] = total_cashflow

	# Generator Surplus = Cashflow - Production Cost - derived from values already loaded above,
	# matching Laura's "GENERATOR PROFITS (Full Revenue - Cost)" section directly rather than
	# needing a separate sheet.
	total_surplus = 0.0
	for gen in generators
		s = vals["Generator Cashflow - $gen (€)"] - vals["Production Cost - $gen (€)"]
		vals["Generator Surplus - $gen (€)"] = s
		total_surplus += s
	end
	vals["Generator Surplus - Total (€)"] = total_surplus

	storage_summary = DataFrame(XLSX.readtable(our_kpi_path, "storage_summary"))
	storage_row = storage_summary[(storage_summary.Case .== label) .& (storage_summary.Period .== "Total"), :][1, :]
	vals["Energy Discharged (MWh)"] = storage_row.DischargeTotal
	vals["Energy Charged (MWh)"] = storage_row.ChargeTotal

	storage_revenue = DataFrame(XLSX.readtable(our_kpi_path, "storage_revenue"))
	sr_row = storage_revenue[storage_revenue.Case .== label, :][1, :]
	vals["Avg Discharge Price (€/MWh)"] = sr_row.AvgDischargePrice
	vals["Avg Charging Price (€/MWh)"] = sr_row.AvgChargePrice
	vals["Discharge Revenue (€)"] = sr_row.DischargeRevenue
	vals["Charging Cost (€)"] = sr_row.ChargingCost
	vals["Net Revenue (€)"] = sr_row.NetStorageRevenue

	storage_soc = DataFrame(XLSX.readtable(our_kpi_path, "storage_soc_losses"))
	soc_row = storage_soc[storage_soc.Case .== label, :][1, :]
	vals["Total Losses (MWh)"] = soc_row.TotalLosses
	vals["SOC End of Horizon (MWh)"] = soc_row.SOCEndOfHorizon

	return vals
end

# ordered list of (section_header, [kpi_labels...]) - defines both row order and section breaks
# in the LaTeX table
function KPIRowOrder()
	rows = Tuple{String,Vector{String}}[]
	push!(rows, ("System", [
		"Socioeconomic Welfare (€)",
		"Demand Utility (€)",
		"Production Costs (€)",
		"Imbalance (MWh)",
		"Wind Curtailment (MWh)",
	]))
	push!(rows, ("Dispatch Quantity by Generator (MWh)", vcat(["Dispatch Quantity - $gen (MWh)" for gen in generators], ["Dispatch Quantity - Total (MWh)"])))
	push!(rows, ("Production Cost by Generator (€)", ["Production Cost - $gen (€)" for gen in generators]))
	push!(rows, ("Gross Traded Volume (MWh)", vcat(["Gross Traded Volume - $gen (MWh)" for gen in generators], ["Gross Traded Volume - Total (MWh)"])))
	push!(rows, ("Generator Cashflow (€)", vcat(["Generator Cashflow - $gen (€)" for gen in generators], ["Generator Cashflow - Total (€)"])))
	push!(rows, ("Generator Surplus (€)", vcat(["Generator Surplus - $gen (€)" for gen in generators], ["Generator Surplus - Total (€)"])))
	push!(rows, ("Storage", [
		"Energy Discharged (MWh)",
		"Energy Charged (MWh)",
		"Avg Discharge Price (€/MWh)",
		"Avg Charging Price (€/MWh)",
		"Discharge Revenue (€)",
		"Charging Cost (€)",
		"Net Revenue (€)",
		"Total Losses (MWh)",
		"SOC End of Horizon (MWh)",
	]))
	return rows
end

# formats a Float64 with thousands-comma separators and a fixed number of decimals, LaTeX-safe.
# Uses Printf for the fixed-point conversion - Julia's default Float64 -> String (via `string`
# or `round` then `string`) switches to scientific notation ("2.16176e9") for large magnitudes,
# which silently truncated every large value down to its leading digit before this fix.
function FormatNumber(x; decimals=2)
	x = abs(x) < 10.0^(-decimals) / 2 ? 0.0 : x # avoid a cosmetic "-0" when rounding erases the sign
	neg = x < 0
	x = abs(x)
	s = decimals == 0 ? @sprintf("%.0f", x) : @sprintf("%.2f", x)
	parts = split(s, ".")
	intpart = parts[1]
	decpart = length(parts) > 1 ? parts[2] : ""

	chars = reverse(collect(intpart))
	groups = String[]
	i = 1
	while i <= length(chars)
		push!(groups, String(reverse(chars[i:min(i + 2, length(chars))])))
		i += 3
	end
	intpart_commas = join(reverse(groups), ",")

	result = decimals > 0 ? "$(intpart_commas).$(decpart)" : intpart_commas
	return neg ? "-$result" : result
end

# for a per-generator row, reduce the full KPI label to just the generator name (the section
# header already establishes which metric); anything else (system-level rows) passes through
# unchanged since the section header alone isn't descriptive enough for those
function ShortLabel(kpi_label)
	for gen in generators
		if occursin("- $gen (", kpi_label)
			return gen
		end
	end
	occursin("- Total (", kpi_label) && return "Total"
	return kpi_label
end

function BuildLatexTable(case, our_vals, laura_vals)
	rows = KPIRowOrder()

	io = IOBuffer()
	println(io, "\\begin{table}[htbp]")
	println(io, "\\centering")
	println(io, "\\caption{$case 36h: Model A vs. Model B}")
	println(io, "\\label{tab:kpi_comparison_$(lowercase(case))}")
	println(io, "\\begin{tabular}{lrrr}")
	println(io, "\\toprule")
	println(io, "KPI & Model A & Model B & Difference \\\\")
	println(io, "\\midrule")

	for (section, labels) in rows
		println(io, "\\multicolumn{4}{l}{\\textbf{$section}} \\\\")
		for label in labels
			haskey(our_vals, label) || continue
			haskey(laura_vals, label) || continue
			ours = our_vals[label]
			laura = laura_vals[label]
			diff = ours - laura
			row_label = length(labels) > 1 ? ShortLabel(label) : "Total"
			decimals = occursin("Price", label) ? 2 : 0
			println(io, "\\quad $row_label & $(FormatNumber(ours; decimals=decimals)) & $(FormatNumber(laura; decimals=decimals)) & $(FormatNumber(diff; decimals=decimals)) \\\\")
		end
	end

	println(io, "\\bottomrule")
	println(io, "\\end{tabular}")
	println(io, "\\end{table}")

	return String(take!(io))
end

function PerformAnalysis()
	CleanDirectory(results_path_base)

	out_path = "$results_path_base/kpi_comparison_tables.tex"
	open(out_path, "w") do io
		for case in ["Fixed", "Rolling"]
			println("building table for case: $case")
			our_vals = LoadOurKPIs(case)
			laura_vals = LoadLauraSummary(case)
			table = BuildLatexTable(case, our_vals, laura_vals)
			println(io, table)
			println(io)
		end
	end
	println("saved: $out_path")

	return out_path
end

end;

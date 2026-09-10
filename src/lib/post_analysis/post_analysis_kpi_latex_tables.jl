# LaTeX comparison tables: our computed KPIs (laura_kpi_validation.xlsx, from
# post_analysis_laura_kpis.jl) vs Laura's own reference economic_summary.xlsx, for both the
# fixed36 and rolling36 cases. One table per case, columns: KPI | Ours | Laura | Difference.
#
# Only includes KPIs we have an actual validated computed figure for (see
# post_analysis_laura_kpis.jl for how each is derived and why it matches the specific Laura
# section it's paired with - e.g. generator revenue compares against her "TOTAL FINANCIAL
# REVENUE" section, not "PRODUCER REVENUES (Executed-only)", per the divergence investigated
# earlier this session). Skips KPIs we don't independently compute (Average Executed Price,
# Total Wind Curtailed, Generator Profits, the Delivery-Hour Audit section).
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
	vals["Social Welfare (EUR)"] = sh[7, 2]
	vals["Total Demand Value (EUR)"] = sh[5, 2]
	vals["Total Generation Cost (EUR)"] = sh[6, 2]
	vals["Total Imbalance (MWh, +up/-down)"] = sh[6, 6]

	generator_cost_row = Dict("Base" => 29, "Shoulder" => 30, "Peak" => 31, "Solar" => 32, "Wind" => 33)
	for gen in generators
		vals["Production Cost - $gen (EUR)"] = sh[generator_cost_row[gen], 2]
	end

	financial_revenue_row = Dict("Base" => 20, "Shoulder" => 21, "Peak" => 22, "Solar" => 23, "Wind" => 24)
	for gen in generators
		r = financial_revenue_row[gen]
		vals["Total Financial Revenue - Net Revenue - $gen (EUR)"] = sh[r, 2]
		vals["Total Financial Revenue - Net Traded - $gen (MWh)"] = sh[r, 3]
		vals["Total Financial Revenue - Gross Traded - $gen (MWh)"] = sh[r, 4]
	end
	vals["Total Financial Revenue - Total Net Revenue (EUR)"] = sh[25, 2]

	vals["Storage Energy Discharged (MWh)"] = sh[48, 2]
	vals["Storage Energy Charged (MWh)"] = sh[49, 2]
	vals["Storage Avg Discharge Price (EUR/MWh)"] = sh[50, 2]
	vals["Storage Avg Charging Price (EUR/MWh)"] = sh[51, 2]
	vals["Storage Discharge Revenue (EUR)"] = sh[52, 2]
	vals["Storage Charging Cost (EUR)"] = sh[53, 2]
	vals["Storage Net Revenue (EUR)"] = sh[54, 2]
	vals["Storage Total Losses (MWh)"] = sh[55, 2]
	vals["Storage SOC End of Horizon (MWh)"] = sh[56, 2]

	return vals
end

# reads our own laura_kpi_validation.xlsx (already computed by post_analysis_laura_kpis.jl),
# returning a Dict keyed by the SAME labels LoadLauraSummary uses
function LoadOurKPIs(case)
	label = our_case_label[case]
	vals = Dict{String,Float64}()

	econ = DataFrame(XLSX.readtable(our_kpi_path, "economic_indicators"))
	econ_row = econ[(econ.Case .== label) .& (econ.Period .== "Total"), :][1, :]
	vals["Social Welfare (EUR)"] = econ_row[Symbol("Socioeconomic Welfare (€)")]
	vals["Total Demand Value (EUR)"] = econ_row[Symbol("Demand Utility (€)")]
	vals["Total Generation Cost (EUR)"] = econ_row[Symbol("Production Costs (€)")]

	imbalance = DataFrame(XLSX.readtable(our_kpi_path, "imbalance"))
	vals["Total Imbalance (MWh, +up/-down)"] = imbalance[imbalance.Case .== label, :ImbalanceEnergy][1]

	agents = DataFrame(XLSX.readtable(our_kpi_path, "agent_indicators"))
	agents_case = agents[agents.Case .== label, :]
	for gen in generators
		row = agents_case[agents_case.Agent .== generator_agent_names[gen], :][1, :]
		vals["Production Cost - $gen (EUR)"] = row[Symbol("Fuel Cost (€)")]
	end

	fin_rev = DataFrame(XLSX.readtable(our_kpi_path, "total_financial_revenue"))
	fin_rev_case = fin_rev[fin_rev.Case .== label, :]
	total_net_revenue = 0.0
	for gen in generators
		row = fin_rev_case[fin_rev_case.Agent .== generator_agent_names[gen], :][1, :]
		vals["Total Financial Revenue - Net Revenue - $gen (EUR)"] = row.NetRevenue
		vals["Total Financial Revenue - Net Traded - $gen (MWh)"] = row.NetTraded
		total_net_revenue += row.NetRevenue
	end

	gross_vol = DataFrame(XLSX.readtable(our_kpi_path, "gross_traded_volume"))
	gross_vol_case = gross_vol[gross_vol.Case .== label, :]
	for gen in generators
		row = gross_vol_case[gross_vol_case.Agent .== generator_agent_names[gen], :][1, :]
		vals["Total Financial Revenue - Gross Traded - $gen (MWh)"] = row.GrossTradedVolume
	end
	vals["Total Financial Revenue - Total Net Revenue (EUR)"] = total_net_revenue

	storage_summary = DataFrame(XLSX.readtable(our_kpi_path, "storage_summary"))
	storage_row = storage_summary[(storage_summary.Case .== label) .& (storage_summary.Period .== "Total"), :][1, :]
	vals["Storage Energy Discharged (MWh)"] = storage_row.DischargeTotal
	vals["Storage Energy Charged (MWh)"] = storage_row.ChargeTotal

	storage_revenue = DataFrame(XLSX.readtable(our_kpi_path, "storage_revenue"))
	sr_row = storage_revenue[storage_revenue.Case .== label, :][1, :]
	vals["Storage Avg Discharge Price (EUR/MWh)"] = sr_row.AvgDischargePrice
	vals["Storage Avg Charging Price (EUR/MWh)"] = sr_row.AvgChargePrice
	vals["Storage Discharge Revenue (EUR)"] = sr_row.DischargeRevenue
	vals["Storage Charging Cost (EUR)"] = sr_row.ChargingCost
	vals["Storage Net Revenue (EUR)"] = sr_row.NetStorageRevenue

	storage_soc = DataFrame(XLSX.readtable(our_kpi_path, "storage_soc_losses"))
	soc_row = storage_soc[storage_soc.Case .== label, :][1, :]
	vals["Storage Total Losses (MWh)"] = soc_row.TotalLosses
	vals["Storage SOC End of Horizon (MWh)"] = soc_row.SOCEndOfHorizon

	return vals
end

# ordered list of (section_header, [kpi_labels...]) - defines both row order and section breaks
# in the LaTeX table
function KPIRowOrder()
	rows = Tuple{String,Vector{String}}[]
	push!(rows, ("System", [
		"Social Welfare (EUR)",
		"Total Demand Value (EUR)",
		"Total Generation Cost (EUR)",
		"Total Imbalance (MWh, +up/-down)",
	]))
	push!(rows, ("Production Cost by Generator", ["Production Cost - $gen (EUR)" for gen in generators]))
	push!(rows, ("Total Financial Revenue - Net Revenue", ["Total Financial Revenue - Net Revenue - $gen (EUR)" for gen in generators]))
	push!(rows, ("Total Financial Revenue - Net Traded", ["Total Financial Revenue - Net Traded - $gen (MWh)" for gen in generators]))
	push!(rows, ("Total Financial Revenue - Gross Traded", ["Total Financial Revenue - Gross Traded - $gen (MWh)" for gen in generators]))
	push!(rows, ("Total Financial Revenue - Total", ["Total Financial Revenue - Total Net Revenue (EUR)"]))
	push!(rows, ("Storage", [
		"Storage Energy Discharged (MWh)",
		"Storage Energy Charged (MWh)",
		"Storage Avg Discharge Price (EUR/MWh)",
		"Storage Avg Charging Price (EUR/MWh)",
		"Storage Discharge Revenue (EUR)",
		"Storage Charging Cost (EUR)",
		"Storage Net Revenue (EUR)",
		"Storage Total Losses (MWh)",
		"Storage SOC End of Horizon (MWh)",
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
	return kpi_label
end

function BuildLatexTable(case, our_vals, laura_vals)
	rows = KPIRowOrder()

	io = IOBuffer()
	println(io, "\\begin{table}[htbp]")
	println(io, "\\centering")
	println(io, "\\caption{$case 36h: computed KPIs vs. Laura's reference}")
	println(io, "\\label{tab:kpi_comparison_$(lowercase(case))}")
	println(io, "\\begin{tabular}{lrrr}")
	println(io, "\\toprule")
	println(io, "KPI & Ours & Laura & Difference \\\\")
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

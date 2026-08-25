module PlotEmissions

using Plots
using StatsPlots
using DataFrames
using XLSX

using ..Helpers

include("../../output_data/market_data_storage.jl")
include("../../output_data/interpretations.jl")

gen_colors = [:steelblue, :lightgreen, :red, :lightyellow, :coral, :orange]

# stacked bar chart comparing conventional generator emissions (tCO2e) across market configurations
function plotCompare(market_results, config, test_range, test_id)

	market_configurations = collect(keys(market_results))
	# merit order, cheapest (baseload) first - groupedbar's :stack draws the first series at
	# the top and the last at the bottom, so descending bid price puts the priciest/peaking
	# generator on top of the stack and the cheapest/baseload generator at the bottom
	generators = sort(collect(keys(config[:dispatchableGenerators])), by = g -> config[:dispatchableGenerators][g]["bidPrice"], rev = true)

	# rows = market configurations (bars), columns = generators (stacked series)
	stack_matrix = zeros(length(market_configurations), length(generators))

	combined_emissions = DataFrame()
	for (row, marketConfiguration) in enumerate(market_configurations)
		emissions = MarketDataStorage.GetEmissionsForRange(market_results[marketConfiguration], config, test_range)
		emissions[!, Symbol("Market Configuration")] .= marketConfiguration
		combined_emissions = vcat(combined_emissions, emissions)

		for (col, gName) in enumerate(generators)
			gEmissions = emissions[emissions.Generator .== gName, :Emissions]
			stack_matrix[row, col] = length(gEmissions) > 0 ? gEmissions[1] : 0.0
		end
	end

	XLSX.writetable("results/$(test_id)/emissions.xlsx", "data" => combined_emissions)

	colors = reshape(gen_colors[mod1.(1:length(generators), length(gen_colors))], 1, :)

	p = groupedbar(market_configurations, stack_matrix,
		bar_position=:stack,
		label=reshape(generators, 1, :),
		color=colors,
		xlabel="Market Configuration", ylabel="Emissions (tCO2e)",
		title="Conventional Generator Emissions by Market Configuration",
		legend=:outertopright, size=(900,700))

	display(p)
	savefig(p, "results/$(test_id)/emissions_comparison_$(test_id).png")

	return p
end

end;

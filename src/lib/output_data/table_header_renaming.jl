module TableHeaderRenaming

using DataFrames

header_renaming = Dict{String,Any}(
	"agent_indicators" => Dict{String,Any}(
		"short_names" => ["Quantity", "LoadUtility", "Payments", "Revenue", "FuelCost", "Surplus", "SOCChange"],
		"long_names" => ["Quantity (MWh)", "Load Utility (€)", "Payments (€)", "Revenue (€)", "Fuel Cost (€)", "Surplus (€)", "SOC Change (MWh)"],
	),
	"economic_indicators" => Dict{String,Any}(
		"short_names" => ["SEW", "DemandUtility", "ProductionCosts", "ProducerSurplus", "ConsumerSurplus", "StorageRevenue"],
		"long_names" => ["Socioeconomic Welfare (€)", "Demand Utility (€)", "Production Costs (€)", "Producer Surplus (€)", "Consumer Surplus (€)", "Storage Revenue (€)"],
	),
	"retrading" => Dict{String,Any}(
		"short_names" => ["Revenue", "BidPrice", "Quantity", "UtilityChange", "FuelCostChange", "SurplusChange"],
		"long_names" => ["Revenue (€)", "Bid Price (€/MWh)", "Quantity (MWh)", "Utility Change (€)", "Fuel Cost Change (€)", "Surplus Change (€)"],
	),
)

function RenameDataFrameHeaders!(df, table_type)
	!haskey(header_renaming,table_type) && throw("$table_type not recognized.")
	long_names = header_renaming[table_type]["long_names"]
	short_names = header_renaming[table_type]["short_names"]
	rename!(df, short_names .=> long_names)
	
end


end
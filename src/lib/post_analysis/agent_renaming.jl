module AgentRenaming

	AgentToDisplayName = Dict{String,String}(
		"1D_HighBid" => "High Bid",
		"2D_ModerateBid" => "Moderate Bid",
		"3G_Base" => "Base",
		"4G_Shoulder" => "Shoulder",
		"5G_Peak" => "Peak",
		"6G_Wind" => "Wind",
		"7G_Solar" => "Solar",
		)

	function DisplayName(agent)
		return AgentToDisplayName[agent]
	end
end;
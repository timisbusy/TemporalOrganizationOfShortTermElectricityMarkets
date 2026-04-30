module Interpretations

using DataFrames

DecisionVariablesInterpretation = DataFrame([
	(DataPoint="MTU", Interpretation="Market Time Unit for which energy is dispatched, counted from beginning of experiment period"),  
	(DataPoint="Price", Interpretation="Market Clearing Price for this MTU in this clearing (€/MWh)"),
	(DataPoint="SOC", Interpretation="Storage state of charge at end of this MTU (MWh)"),
	(DataPoint="StorageCharge", Interpretation="Energy dispatched for charging of storage (MWh)"),
	(DataPoint="StorageDischarge", Interpretation="Energy dispatched for discharging of storage (MWh)"), 
	(DataPoint="Base_D", Interpretation="Base demand dispatch quantity (MWh)"),
	(DataPoint="Flex", Interpretation="Flexible demand dispatch quantity (MWh)"),
	(DataPoint="Base", Interpretation="Base generator dispatch quantity (MWh)"),
	(DataPoint="Peak", Interpretation="Peak generator dispatch quantity (MWh)"),
	(DataPoint="Shoulder", Interpretation="Shoulder generator dispatch quantity (MWh)"),
	(DataPoint="Wind", Interpretation="Wind generator dispatch quantity (MWh)"),
	(DataPoint="Solar", Interpretation="Solar generator dispatch quantity (MWh)"),
	(DataPoint="Q_{Agent}", Interpretation="Agent bid quantity (MWh)"),
	(DataPoint="P_{Agent}", Interpretation="Agent bid price (€)")
	])

TransactionsInterpretation = DataFrame([
	(DataPoint="Market Name", Interpretation="Name of market in which transaction occurred"), 
	(DataPoint="Agent", Interpretation="Agent engaging in transaction"),
	(DataPoint="Quantity", Interpretation="Quantity traded in transaction (MWh)"), 
	(DataPoint="Price", Interpretation="Price per MWh paid/received in transaction (€/MWh)"), 
	(DataPoint="Market Time Unit", Interpretation="Market Time Unit for which energy is dispatched, counted from beginning of experiment period"), 
	(DataPoint="Clearing MTU", Interpretation="Market Time Unit in which this market was held (gate closure), counted from beginning of experiment period"), 
	(DataPoint="Agent Type", Interpretation="Identifies the type of agent - Demand, Generator, or Storage"), 
	(DataPoint="Payments/Revenues (€)", Interpretation="Payments or revenues for transaction i.e., Quantity*Price (€)")
	])

EconomicIndicatorsInterpretation = DataFrame([
	(DataPoint="SEW", Interpretation="Socioeconomic Welfare generated in test period (€)"), 
	(DataPoint="ProducerSurplus", Interpretation="Producer Surplus generated in test period (€)"),
	(DataPoint="ConsumerSurplus", Interpretation="Consumer Surplus generated in test period (€)"), 
	(DataPoint="StorageRevenue", Interpretation="Storage net revenue (revenues received - payments made) in test period (€)")
	])

AgentIndicatorsInterpretation = DataFrame([
	(DataPoint="Agent", Interpretation="Name of Agent"), 
	(DataPoint="Quantity", Interpretation="Quantity traded in test period (MWh)"),
	(DataPoint="LoadUtility", Interpretation="Utility gained by demand agent in test period (€)"), 
	(DataPoint="Payments", Interpretation="Net payments made by demand agent in test period (€)"),
	(DataPoint="Revenue", Interpretation="Net revenues received by generator/storage agent in test period (€)"), 
	(DataPoint="FuelCost", Interpretation="Fuel costs for generator in test period (€)"),
	(DataPoint="WelfareGained", Interpretation="Producer/Consumer Surplus gained by agent, equals net revenue for storage (€)")
	])

end;
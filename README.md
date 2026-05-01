
# Temporal Organization of Short-Term Electricity Markets

# Inputs

## Experiment Configuration

The experiment configuration `.yaml` file includes the information needed to define the experiment to be run, including the high-level temporal parameters like `timePeriodsPerDay`, which implicitly sets the market time unit (MTU), and `clearForDays` which defines the duration of experiment simulation. The configuration also includes a reference to the market configuration to apply and the agent configuration to use for the experiment.

A simple experiment runs a simulation for `clearForDays` days and data are analyzed for the time between the beginning of the second day of the simulation until the second to last day of the simulation. This allows the market sequence to start up on day one and gives each day in the test period adequate coverage.

> Note
> Markets only run when they are scheduled during the experiment time frame, so for market designs that include a long `lookAheadDistance` (see [Market Configuration](#market-configuration)) MTUs early in the experiment will not be dispatched. Generators and storage are configured with initial values for quantity and state of charge, respectively (see [Agent Configuration](#agent-configuration)). These values apply in the MTU preceding the first MTU for which they are dispatched.

```
# general parameters for experiment

name: one_intraday # a descriptive name for this experiment that will be reflected in the output files

# Set temporal parameters for experiment - granularity and duration
timePeriodsPerDay: 24 # number of time periods in a day - this sets the MTU
clearForDays: 7 # number of days to clear market for

# set the uncertainty in renewable generation
noiseLevel: 0.0

# references to configuration files for markets and agents

# choose a market configuration from the markets directory
marketConfig: test_market_config.yaml

# choose an agent configuration from the agents directory - the case study
agentConfig: test_agents.yaml

```

A new experiment type allows for comparison of two different market designs. Adding the `compare: market` field to the general configuration and changing the `marketConfig` out for a `marketConfigs` object with `market_name:filepath` key-value pairs runs an experiment with the same general parameters and `agentConfig`, with outputs that compare the agent and economic outcomes across market designs. Other experiment types are envisioned to allow for comparison across agent configurations, market temporal configurations, and scales of agent capacities (e.g., larger storage).

```
# general parameters for experiment

name: compare_rolling_and_fixed # a descriptive name for this experiment
compare: market

# Set temporal parameters for experiment - granularity and duration
timePeriodsPerDay: 24 # number of time periods in a day - this sets the MTU
clearForDays: 7 # number of days to clear market for

# set the uncertainty in renewable generation
noiseLevel: 0.0

# choose a set of market configurations from the markets directory
marketConfigs: 
  Rolling: rolling.yaml # name:filepath pairs
  Fixed: one_intraday.yaml

# choose an agent configuration from the agents directory - the case study
agentConfig: test_agents_storage.yaml
```
### Market Configuration

The market configuration represents a market or set of markets as a market sequence. Each market has a name and a set of temporal parameters as represented below. All are represented in MTU. The configuration also includes a `timePeriodsPerDay` parameter that must match the `timePeriodsPerDay` parameter in the experiment configuration. This check ensures that the configurations are compatible.

```
# This configuration reflects the proposed rolling horizon design
# Define a set of markets that will be cleared over the course of the experiment
# all parameters are expressed in MTU - in this case 1h

timePeriodsPerDay: 24 # define the assumed MTU for this market configuration - this allows for validation that this market is appropriate for the experiment

marketSequence:
  RollingHorizon: # name of market
    clearingInterval: 1 # number of MTU between market clearing/optimization rounds
    optimizationWindow: 36 # number of MTU to consider in each clearing
    lookAheadDistance: 1 # number of MTU after which to start optimization window
    clockTimeBegin: 0 # number of MTU after midnight to hold first clearing


```

### Agent Configuration

The agent configuration defines the market agents with their capacities and bids. The agents are grouped into `dispatchableGenerators`, `variableGenerators`, `batteryStorage`, and `demand`. All `capacity` values for generators and demands in configuration are expressed in MW, which are converted to MWh bid quantities appropriate for the MTU by the model.

#### Generators
Generators provide a fixed bid price, their maximum capacity, ramp rate, and emission factor, as well as an initial quantity, which is the power (MW) that they are assumed to be producing in the MTU prior to the experiment period. Variable generators also provide either a profile of availability factors in `profile` or a reference to a file in `profile_file` and a profile type, which for generators should always be `availability`.

#### Storage
Storage is modeled as a single large battery that is centrally operated, meaning that it does not bid explicitly or appear in the objective function of the market model (see next section for more detail). In addition, storage is not subject to ramping limits as battery energy storage systems generally have ramping capabilities that will not be binding on a one hour or fifteen minute time scale. Efficiency represents energy loss in both charging and discharging directions. `initialSOC` sets the state of charge of the battery for the MTU preceding the simulation, while `endSOC` is reflected in an optimization constraint on storage SOC at the end of each market clearing.

#### Demands
Several demand segments types are supported. A demand can provide single value `quantity_constant`, a `profile` of bid quantities, or a reference to a `profile_file` and `profile_type`, which should always be `quantity` for a demand agent. All are expressed in `MW` and paired with a constant `bidPrice`, expressed in EUR/MWh.

> Note
> For now, `profile_file`s are assumed to be in the format of downloaded files from NED.nl. More documentation of this feature will be provided.

```
# Generator parameters
dispatchableGenerators:
 Base:
  bidPrice: 60 # EUR/MWh
  capacity: 100 # MW
  rampRate: 2 # % of nominal power per minute
  initialQuantity: 100
  emissionFactor: 980 # kgCO2e/MWh

 Shoulder:
  bidPrice: 90 # EUR/MWh
  capacity: 100 # MW
  rampRate: 6 # % of nominal power per minute
  initialQuantity: 0
  emissionFactor: 420 # kgCO2e/MWh

 Peak:
  bidPrice: 120 # EUR/MWh
  capacity: 200 # MW
  rampRate: 12 # % of nominal power per minute
  initialQuantity: 0
  emissionFactor: 420 # kgCO2e/MWh

variableGenerators:
  Wind:
    bidPrice: 0         # EUR/MWh
    capacity: 0        # MW
    profile: [0.0, 0.0]
  Solar:
    bidPrice: 0         # EUR/MWh
    capacity: 0        # MW
    profile: [0.0, 0.0]

# Storage parameters
batteryStorage:
  energyCapacity: 0 # MWh
  powerCapacity: 0 # MW
  efficiency: 0.9
  initialSOC: 0.5 # as fraction of energyCapacity
  endSOC: 0.5 # as fraction of energyCapacity


# Demand parameters
demand:
  segments:
    Base_D:
      bidPrice: 300   # EUR/MWh (high willingness to pay)
      profile: [100,100,100,200,200,200,300,300,300] 
    Flex:
      bidPrice: 100   # EUR/MWh (elastic, only if price low)
      profile: [50, 50, 50, 50, 50, 50, 50, 50, 50]
```
# Market Model

Documentation of the market model is currently under development.

# Outputs

Data is output into a directory specified by the user in a call to run the experiment. The following files are included in the output.

## Raw Data

#### Decision Variables (.xlsx)

A decision variables file is generated for each market clearing. These files include dispatch and price outcomes for the market clearing, with file names reflecting the name of the market configuration and the MTU in which the market was cleared.


#### Transactions (.xlsx)

Transactions files list each energy contract created in each market clearing and in aggregate throughout the course of the experiment. Each transaction includes details about the market in which the transaction was created, the agent engaging in the transaction, the quantity and price for the transaction, the market time unit for which the transaction applies (when energy is contracted to be delivered), the agent type (demand, generator, or storage), and the payments/revenues for the transaction in EUR, which is equal to the quantity times the price.

## Aggregated Data

#### Final Market Results (.xlsx)

The final market results file includes the same fields as [decision variables](#decision-variables), but includes the dispatch and price from the last sequential market for which each MTU falls in the optimization window, thus the final dispatch quantities. The price included in this table is the clearing price of this last sequential market for which the MTU is in the optimization window. Clearing prices in prior periods may have differed, which will be reflected in [transactions](#transactions).

#### Agent Indicators (.xlsx)

The agent indicators file includes aggregated payments, revenues, utility, and fuel costs for each market agent as well as the consumer/producer surplus for each agent over the course of the test period.

#### Economic Indicators (.xlsx)

Economic indicators includes high level indicators for the experiment test period including consumer surplus, producer surplus, storage net revenues, and socioeconomic welfare. $CO_2$ output will also be included here.

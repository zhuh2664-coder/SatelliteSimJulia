# Public API exports that span multiple foundation source files.
#
# Keep these exports near the aggregation module so tests and downstream packages
# can rely on stable public names instead of reaching into implementation files.

export TimeSystem, TimeUTC, TimeTAI, TimeTT, TimeUT1

export EarthRotationEnvironmentModel, EarthRotationUniform, EarthRotationIERS
export SolarEnvironmentModel, SolarEnvironmentDisabled, SolarEnvironmentAnalytic,
    SolarEnvironmentEphemeris
export AtmosphereEnvironmentModel, AtmosphereEnvironmentDisabled,
    AtmosphereEnvironmentBStarOnly, AtmosphereEnvironmentSpaceWeather
export FrameEnvironmentModel, FrameEnvironmentSimpleTEME, FrameEnvironmentIERS

export EarthRotationEnvironment, SolarEnvironment, AtmosphereEnvironment,
    FrameEnvironment, EpochEnvironment

export default_simulation_epoch_environment, simulation_epoch_year,
    simulation_epoch_day

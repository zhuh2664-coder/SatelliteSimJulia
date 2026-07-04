module SatelliteSimViz

using CairoMakie
using GeoMakie
using Makie
using SatelliteSimCore

export MakieViewerConfig,
    OrbitViewerConfig,
    EarthViewerConfig,
    UniformEarthRotationModel,
    plot_makie_viewer,
    show_makie_viewer,
    show_orbit_viewer,
    show_earth_viewer,
    plot_ground_track,
    plot_orbit_snapshot,
    save_orbit_snapshot

struct MakieViewerConfig
    title::String
    time_index::Int
    show_orbits::Bool
    show_ground_track::Bool
    satellite_markersize::Float64
    ground_markersize::Float64
    orbit_linewidth::Float64
    playback_interval_ms::Int
end

function MakieViewerConfig(;
    title::AbstractString = "SatelliteSim Viewer",
    time_index::Int = 1,
    show_orbits::Bool = true,
    show_ground_track::Bool = true,
    satellite_markersize::Real = 5,
    ground_markersize::Real = 10,
    orbit_linewidth::Real = 1.5,
    playback_interval_ms::Int = 250,
)
    time_index > 0 || throw(ArgumentError("time_index must be positive"))
    satellite_markersize > 0 || throw(ArgumentError("satellite_markersize must be positive"))
    ground_markersize > 0 || throw(ArgumentError("ground_markersize must be positive"))
    orbit_linewidth > 0 || throw(ArgumentError("orbit_linewidth must be positive"))
    playback_interval_ms > 0 || throw(ArgumentError("playback_interval_ms must be positive"))
    return MakieViewerConfig(
        String(title),
        time_index,
        show_orbits,
        show_ground_track,
        Float64(satellite_markersize),
        Float64(ground_markersize),
        Float64(orbit_linewidth),
        playback_interval_ms,
    )
end

struct OrbitViewerConfig
    title::String
    time_index::Int
    show_trails::Bool
    trail_steps::Int
    satellite_markersize::Float64
    refresh_interval_ms::Int
    auto_play::Bool
    time_scale::Float64
    follow_satellite_id::Union{Nothing,Int}
    follow_window_km::Float64
    max_global_city_points::Int
end

function OrbitViewerConfig(;
    title::AbstractString = "SatelliteSim Orbit Viewer",
    time_index::Int = 1,
    show_trails::Bool = true,
    trail_steps::Int = 36,
    satellite_markersize::Real = 4,
    refresh_interval_ms::Int = 100,
    auto_play::Bool = false,
    time_scale::Real = 1,
    follow_satellite_id::Union{Nothing,Int} = nothing,
    follow_window_km::Real = 1800,
    max_global_city_points::Int = 0,
)
    time_index > 0 || throw(ArgumentError("time_index must be positive"))
    trail_steps >= 0 || throw(ArgumentError("trail_steps must be non-negative"))
    satellite_markersize > 0 || throw(ArgumentError("satellite_markersize must be positive"))
    refresh_interval_ms > 0 || throw(ArgumentError("refresh_interval_ms must be positive"))
    time_scale > 0 || throw(ArgumentError("time_scale must be positive"))
    follow_satellite_id === nothing || follow_satellite_id > 0 ||
        throw(ArgumentError("follow_satellite_id must be positive"))
    follow_window_km > 0 || throw(ArgumentError("follow_window_km must be positive"))
    max_global_city_points >= 0 ||
        throw(ArgumentError("max_global_city_points must be non-negative"))
    return OrbitViewerConfig(
        String(title),
        time_index,
        show_trails,
        trail_steps,
        Float64(satellite_markersize),
        refresh_interval_ms,
        auto_play,
        Float64(time_scale),
        follow_satellite_id,
        Float64(follow_window_km),
        max_global_city_points,
    )
end

struct EarthViewerConfig
    title::String
    refresh_interval_ms::Int
    auto_rotate::Bool
    time_scale::Float64
    axial_tilt_deg::Float64
end

function EarthViewerConfig(;
    title::AbstractString = "WGS84 Earth Viewer",
    refresh_interval_ms::Int = 100,
    auto_rotate::Bool = false,
    time_scale::Real = 1,
    axial_tilt_deg::Real = 23.4392811,
)
    refresh_interval_ms > 0 || throw(ArgumentError("refresh_interval_ms must be positive"))
    time_scale > 0 || throw(ArgumentError("time_scale must be positive"))
    -90 <= axial_tilt_deg <= 90 ||
        throw(ArgumentError("axial_tilt_deg must be in [-90, 90]"))
    return EarthViewerConfig(
        String(title),
        refresh_interval_ms,
        auto_rotate,
        Float64(time_scale),
        Float64(axial_tilt_deg),
    )
end

struct UniformEarthRotationModel
    angular_velocity_rad_s::Float64
end

UniformEarthRotationModel() = UniformEarthRotationModel(OMEGA_EARTH)

position_xyz(state::CartesianState)::NTuple{3,Float64} = state.position_km

function sample_position(sample::EphemerisSample)::Union{Nothing,NTuple{3,Float64}}
    sample.cartesian === nothing && return nothing
    return position_xyz(sample.cartesian)
end

function positions_at(
    ephemeris::ConstellationEphemeris,
    time_index::Int,
)::Vector{NTuple{3,Float64}}
    1 <= time_index <= time_count(ephemeris.time_grid) ||
        throw(ArgumentError("time_index is outside the ephemeris time grid"))

    positions = NTuple{3,Float64}[]
    for satellite_ephemeris in ephemeris.satellites
        position = sample_position(satellite_ephemeris[time_index])
        position === nothing && continue
        push!(positions, position)
    end
    return positions
end

function trail_positions(
    satellite_ephemeris::SatelliteEphemeris,
)::Vector{NTuple{3,Float64}}
    positions = NTuple{3,Float64}[]
    for sample in satellite_ephemeris.samples
        position = sample_position(sample)
        position === nothing && continue
        push!(positions, position)
    end
    return positions
end

function split_xyz(positions::Vector{NTuple{3,Float64}})
    return (
        [position[1] for position in positions],
        [position[2] for position in positions],
        [position[3] for position in positions],
    )
end

function geodetic_samples(ephemeris::ConstellationEphemeris)::Vector{GeodeticPosition}
    positions = GeodeticPosition[]
    for sample in ephemeris_samples(ephemeris)
        sample.geodetic === nothing && continue
        push!(positions, sample.geodetic)
    end
    return positions
end

function geodetic_samples(ephemeris::SatelliteEphemeris)::Vector{GeodeticPosition}
    positions = GeodeticPosition[]
    for sample in ephemeris.samples
        sample.geodetic === nothing && continue
        push!(positions, sample.geodetic)
    end
    return positions
end

function plot_ground_track(
    ephemeris::Union{ConstellationEphemeris,SatelliteEphemeris};
    title::AbstractString = "Ground Track",
)
    positions = geodetic_samples(ephemeris)
    isempty(positions) && throw(ArgumentError("ephemeris does not contain geodetic samples"))

    figure = Figure(size = (900, 460))
    axis = GeoAxis(
        figure[1, 1],
        title = title,
        dest = "+proj=eqearth",
        lonlims = automatic,
        latlims = automatic,
    )
    scatter!(
        axis,
        [position.longitude_deg for position in positions],
        [position.latitude_deg for position in positions];
        markersize = 4,
        color = [position.altitude_km for position in positions],
        colormap = :viridis,
    )
    Colorbar(figure[1, 2], axis.scene.plots[end], label = "Altitude (km)")
    return figure
end

function plot_orbit_snapshot(
    ephemeris::ConstellationEphemeris;
    ground_stations::AbstractVector{GroundStation} = GroundStation[],
    config::MakieViewerConfig = MakieViewerConfig(),
)
    positions = positions_at(ephemeris, config.time_index)
    isempty(positions) && throw(ArgumentError("ephemeris does not contain Cartesian samples"))

    figure = Figure(size = (960, 720))
    axis = Axis3(
        figure[1, 1],
        title = config.title,
        xlabel = "ECEF x (km)",
        ylabel = "ECEF y (km)",
        zlabel = "ECEF z (km)",
        aspect = :data,
    )

    earth_radius = WGS84_EQUATORIAL_RADIUS_KM
    theta = range(0, 2pi; length = 64)
    phi = range(0, pi; length = 32)
    earth_x = [earth_radius * cos(t) * sin(p) for t in theta, p in phi]
    earth_y = [earth_radius * sin(t) * sin(p) for t in theta, p in phi]
    earth_z = [earth_radius * cos(p) for t in theta, p in phi]
    surface!(axis, earth_x, earth_y, earth_z; color = fill(0.55, size(earth_x)), colormap = :blues)

    if config.show_orbits
        for satellite_ephemeris in ephemeris.satellites
            trail = trail_positions(satellite_ephemeris)
            length(trail) < 2 && continue
            xs, ys, zs = split_xyz(trail)
            lines!(axis, xs, ys, zs; linewidth = config.orbit_linewidth, color = (:gray30, 0.35))
        end
    end

    xs, ys, zs = split_xyz(positions)
    scatter!(axis, xs, ys, zs; markersize = config.satellite_markersize, color = :orange)

    if !isempty(ground_stations)
        station_positions = [
            geodetic_to_sphere(station.position, earth_radius)
            for station in ground_stations
        ]
        gx, gy, gz = split_xyz(station_positions)
        scatter!(axis, gx, gy, gz; markersize = config.ground_markersize, color = :dodgerblue)
    end

    return figure
end

function plot_makie_viewer(
    ephemeris::ConstellationEphemeris;
    ground_stations::AbstractVector{GroundStation} = GroundStation[],
    config::MakieViewerConfig = MakieViewerConfig(),
    kwargs...,
)
    return plot_orbit_snapshot(ephemeris; ground_stations = ground_stations, config = config)
end

function plot_makie_viewer(
    _constellation,
    ephemeris::ConstellationEphemeris;
    ground_stations::AbstractVector{GroundStation} = GroundStation[],
    config::MakieViewerConfig = MakieViewerConfig(),
    kwargs...,
)
    return plot_orbit_snapshot(ephemeris; ground_stations = ground_stations, config = config)
end

show_makie_viewer(args...; wait::Bool = false, kwargs...) = plot_makie_viewer(args...; kwargs...)

function show_orbit_viewer(
    ephemeris::ConstellationEphemeris;
    config::OrbitViewerConfig = OrbitViewerConfig(),
    wait::Bool = false,
    kwargs...,
)
    makie_config = MakieViewerConfig(
        title = config.title,
        time_index = config.time_index,
        show_orbits = config.show_trails,
        satellite_markersize = config.satellite_markersize,
        playback_interval_ms = config.refresh_interval_ms,
    )
    return plot_orbit_snapshot(ephemeris; config = makie_config)
end

function show_orbit_viewer(
    _constellation,
    ephemeris::ConstellationEphemeris;
    config::OrbitViewerConfig = OrbitViewerConfig(),
    wait::Bool = false,
    kwargs...,
)
    return show_orbit_viewer(ephemeris; config = config, wait = wait, kwargs...)
end

function show_earth_viewer(;
    config::EarthViewerConfig = EarthViewerConfig(),
    wait::Bool = false,
)
    figure = Figure(size = (760, 680))
    axis = Axis3(
        figure[1, 1],
        title = config.title,
        xlabel = "x (km)",
        ylabel = "y (km)",
        zlabel = "z (km)",
        aspect = :data,
    )

    radius = WGS84_EQUATORIAL_RADIUS_KM
    theta = range(0, 2pi; length = 96)
    phi = range(0, pi; length = 48)
    earth_x = [radius * cos(t) * sin(p) for t in theta, p in phi]
    earth_y = [radius * sin(t) * sin(p) for t in theta, p in phi]
    earth_z = [radius * cos(p) for t in theta, p in phi]
    surface!(axis, earth_x, earth_y, earth_z; color = earth_z, colormap = :deep)
    return figure
end

function save_orbit_snapshot(
    path::AbstractString,
    ephemeris::ConstellationEphemeris;
    ground_stations::AbstractVector{GroundStation} = GroundStation[],
    config::MakieViewerConfig = MakieViewerConfig(),
)
    figure = plot_orbit_snapshot(ephemeris; ground_stations = ground_stations, config = config)
    save(path, figure)
    return path
end

function geodetic_to_sphere(position::GeodeticPosition, radius_km::Real)::NTuple{3,Float64}
    latitude = deg2rad(position.latitude_deg)
    longitude = deg2rad(position.longitude_deg)
    radius = Float64(radius_km + position.altitude_km)
    return (
        radius * cos(latitude) * cos(longitude),
        radius * cos(latitude) * sin(longitude),
        radius * sin(latitude),
    )
end

end # module

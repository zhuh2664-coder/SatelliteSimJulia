module SatelliteSimPlatformStorage

using Dates
using JSON
using SHA

export AbstractExperimentStorage,
       LocalFilesystemStorage,
       StoredObject,
       StorageKeyError,
       put_bytes!, put_json!, get_bytes, get_json,
       has_object, object_metadata, list_objects, delete_object!,
       upload_directory!, materialize_prefix!

"""Storage keys are invalid, unsafe, or outside the configured object namespace."""
struct StorageKeyError <: Exception
    message::String
end
Base.showerror(io::IO, error::StorageKeyError) = print(io, error.message)

"""Metadata returned for an immutable object write or lookup."""
struct StoredObject
    key::String
    bytes::Int
    sha256::String
    updated_at_utc::DateTime
end

"""Abstract object storage used by scheduler/API layers, independent of cloud vendors."""
abstract type AbstractExperimentStorage end

"""A local filesystem implementation for tests, development, and offline reproduction."""
struct LocalFilesystemStorage <: AbstractExperimentStorage
    root::String
    function LocalFilesystemStorage(root::AbstractString)
        isempty(strip(root)) && throw(ArgumentError("storage root must not be empty"))
        return new(abspath(mkpath(root)))
    end
end

function _key_parts(key::AbstractString)::Vector{String}
    text = String(key)
    isempty(text) && throw(StorageKeyError("storage key must not be empty"))
    occursin('\0', text) && throw(StorageKeyError("storage key contains a NUL byte"))
    startswith(text, '/') && throw(StorageKeyError("storage key must be relative"))
    occursin('\\', text) && throw(StorageKeyError("storage key must use '/' separators"))
    parts = split(text, '/')
    any(part -> isempty(part) || part == "." || part == "..", parts) &&
        throw(StorageKeyError("storage key must not contain empty, '.' or '..' path segments"))
    return parts
end

_normalize_key(key::AbstractString) = join(_key_parts(key), "/")

function _object_path(storage::LocalFilesystemStorage, key::AbstractString)::String
    normalized = _normalize_key(key)
    path = normpath(joinpath(storage.root, split(normalized, '/')...))
    relative = relpath(path, storage.root)
    (relative == ".." || startswith(relative, ".." * string(Base.Filesystem.path_separator))) &&
        throw(StorageKeyError("storage key escapes configured root"))
    return path
end

_sha256(bytes::Vector{UInt8}) = bytes2hex(sha256(bytes))

function _metadata(key::String, path::String)::StoredObject
    return StoredObject(key, filesize(path), _sha256(read(path)), unix2datetime(stat(path).mtime))
end

"""Write bytes atomically and return object metadata."""
function put_bytes!(storage::AbstractExperimentStorage, key::AbstractString, bytes::AbstractVector{UInt8})
    throw(MethodError(put_bytes!, (storage, key, bytes)))
end

function put_bytes!(storage::LocalFilesystemStorage, key::AbstractString, bytes::AbstractVector{UInt8})
    normalized = _normalize_key(key)
    path = _object_path(storage, normalized)
    mkpath(dirname(path))
    temporary, io = mktemp(dirname(path))
    try
        write(io, bytes)
    finally
        close(io)
    end
    mv(temporary, path; force=true)
    return _metadata(normalized, path)
end

"""Serialize JSON with a stable pretty representation before storing it."""
function put_json!(storage::AbstractExperimentStorage, key::AbstractString, value)
    throw(MethodError(put_json!, (storage, key, value)))
end

function put_json!(storage::LocalFilesystemStorage, key::AbstractString, value)
    io = IOBuffer()
    JSON.print(io, value, 2)
    write(io, '\n')
    return put_bytes!(storage, key, take!(io))
end

function get_bytes(storage::AbstractExperimentStorage, key::AbstractString)::Vector{UInt8}
    throw(MethodError(get_bytes, (storage, key)))
end

function get_bytes(storage::LocalFilesystemStorage, key::AbstractString)::Vector{UInt8}
    path = _object_path(storage, key)
    isfile(path) || throw(KeyError(_normalize_key(key)))
    return read(path)
end

function get_json(storage::AbstractExperimentStorage, key::AbstractString)
    throw(MethodError(get_json, (storage, key)))
end

get_json(storage::LocalFilesystemStorage, key::AbstractString) = JSON.parse(String(get_bytes(storage, key)))

function has_object(storage::AbstractExperimentStorage, key::AbstractString)::Bool
    throw(MethodError(has_object, (storage, key)))
end

has_object(storage::LocalFilesystemStorage, key::AbstractString)::Bool = isfile(_object_path(storage, key))

function object_metadata(storage::AbstractExperimentStorage, key::AbstractString)::StoredObject
    throw(MethodError(object_metadata, (storage, key)))
end

function object_metadata(storage::LocalFilesystemStorage, key::AbstractString)::StoredObject
    normalized = _normalize_key(key)
    path = _object_path(storage, normalized)
    isfile(path) || throw(KeyError(normalized))
    return _metadata(normalized, path)
end

"""Delete an object; returns `true` if it existed, `false` otherwise."""
function delete_object!(storage::AbstractExperimentStorage, key::AbstractString)::Bool
    throw(MethodError(delete_object!, (storage, key)))
end

function delete_object!(storage::LocalFilesystemStorage, key::AbstractString)::Bool
    path = _object_path(storage, key)
    isfile(path) || return false
    rm(path)
    return true
end

"""List object metadata below an optional slash-delimited prefix in lexical order."""
function list_objects(storage::AbstractExperimentStorage; prefix::AbstractString="")::Vector{StoredObject}
    throw(MethodError(list_objects, (storage,)))
end

function list_objects(storage::LocalFilesystemStorage; prefix::AbstractString="")::Vector{StoredObject}
    normalized_prefix = isempty(prefix) ? "" : _normalize_key(prefix)
    root = isempty(normalized_prefix) ? storage.root : _object_path(storage, normalized_prefix)
    ispath(root) || return StoredObject[]
    isfile(root) && return [object_metadata(storage, normalized_prefix)]

    objects = StoredObject[]
    for (directory, _, files) in walkdir(root)
        for file in files
            path = joinpath(directory, file)
            key = replace(relpath(path, storage.root), Base.Filesystem.path_separator => '/')
            push!(objects, _metadata(key, path))
        end
    end
    sort!(objects; by=object -> object.key)
    return objects
end

function _join_key(prefix::AbstractString, relative::AbstractString)::String
    normalized_relative = _normalize_key(relative)
    return isempty(prefix) ? normalized_relative : string(_normalize_key(prefix), "/", normalized_relative)
end

"""Copy every file in a local directory into a storage prefix, preserving relative names."""
function upload_directory!(storage::AbstractExperimentStorage, prefix::AbstractString, directory::AbstractString)
    throw(MethodError(upload_directory!, (storage, prefix, directory)))
end

function upload_directory!(storage::LocalFilesystemStorage, prefix::AbstractString, directory::AbstractString)
    isdir(directory) || throw(ArgumentError("upload directory '$directory' does not exist"))
    normalized_prefix = isempty(prefix) ? "" : _normalize_key(prefix)
    objects = StoredObject[]
    for (current, _, files) in walkdir(directory)
        for file in sort!(files)
            local_path = joinpath(current, file)
            relative = replace(relpath(local_path, directory), Base.Filesystem.path_separator => '/')
            push!(objects, put_bytes!(storage, _join_key(normalized_prefix, relative), read(local_path)))
        end
    end
    sort!(objects; by=object -> object.key)
    return objects
end

"""Materialize all objects under `prefix` into a local directory and return their metadata."""
function materialize_prefix!(storage::AbstractExperimentStorage, prefix::AbstractString, directory::AbstractString)
    throw(MethodError(materialize_prefix!, (storage, prefix, directory)))
end

function materialize_prefix!(storage::LocalFilesystemStorage, prefix::AbstractString, directory::AbstractString)
    normalized_prefix = _normalize_key(prefix)
    prefix_with_separator = string(normalized_prefix, "/")
    objects = list_objects(storage; prefix=normalized_prefix)
    for object in objects
        object.key == normalized_prefix && continue
        startswith(object.key, prefix_with_separator) || continue
        relative = object.key[length(prefix_with_separator)+1:end]
        local_path = joinpath(directory, split(relative, '/')...)
        mkpath(dirname(local_path))
        write(local_path, get_bytes(storage, object.key))
    end
    return objects
end

end # module

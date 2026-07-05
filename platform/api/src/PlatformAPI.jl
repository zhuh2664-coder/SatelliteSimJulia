# PlatformAPI.jl — PlatformAPI 服务入口

module PlatformAPI

using HTTP
using JSON
using SHA
using Base64
using UUIDs
using Dates
using Storage

include("router.jl")

function start(; host::String = "0.0.0.0", port::Int = 8080)
    println("[api] starting on $(host):$(port)")
    Storage.connect()
    HTTP.serve(router, host, port)
end

end  # module

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
include(joinpath(@__DIR__, "../src/Senciro.jl"))
using .Senciro

println("Setting up routes...")

Senciro.get("/") do req
    return "Welcome to the User Defined Router!"
end

Senciro.get("/hello") do req
    return "Hello from the new API!"
end

Senciro.post("/data") do req
    return "Data received!"
end

println("Routes registered: $(length(Senciro.GLOBAL_ROUTER.routes))")
println("Starting server on port 8080...")
Senciro.start_server(8080)

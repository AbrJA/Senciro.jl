import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
include(joinpath(@__DIR__, "../src/Senciro.jl"))
using .Senciro

println("Setting up routes...")

Senciro.get("/") do req::Senciro.Request
    return Senciro.text("Welcome to the User Defined Router!")
end

Senciro.get("/hello") do req::Senciro.Request
    return Senciro.text("Hello from the new API!")
end

Senciro.post("/data") do req::Senciro.Request
    return Senciro.text("Data received!")
end

Senciro.get("/json") do req::Senciro.Request
    # Test JSON serialization
    return Senciro.json(Dict("status" => "ok", "message" => "This is JSON"))
end

Senciro.get("/user/:id") do req::Senciro.Request
    id = get(req.params, "id", "unknown")
    return Senciro.json(Dict("user_id" => id))
end

println("Starting server on port 8080...")
Senciro.start_server(8080)

import Pkg
Pkg.activate(joinpath(@__DIR__, ".."))
include(joinpath(@__DIR__, "../src/Senciro.jl"))
using .Senciro

println("Setting up routes...")

# Instantiate Router
app = Senciro.Router()

# Use Middleware
#Senciro.use(app, Senciro.Logger)

Senciro.get(app, "/") do req::Senciro.Request
    return Senciro.text("Welcome to the User Defined Router!")
end

Senciro.get(app, "/hello") do req::Senciro.Request
    return Senciro.text("Hello from the new API!")
end

Senciro.get(app, "/large") do req::Senciro.Request
    # Test Zero-Copy with 5MB payload
    data = repeat("A", 5 * 1024 * 1024)
    return Senciro.text(data)
end


Senciro.post(app, "/data") do req::Senciro.Request
    return Senciro.text("Data received!")
end

Senciro.get(app, "/json") do req::Senciro.Request
    # Test JSON serialization
    return Senciro.json(Dict("status" => "ok", "message" => "This is JSON"))
end

Senciro.get(app, "/user/:id") do req::Senciro.Request
    id = Base.get(req.params, "id", "unknown")
    return Senciro.json(Dict("user_id" => id))
end

println("Starting server on port 8080...")
Senciro.start_server(app, 8080)

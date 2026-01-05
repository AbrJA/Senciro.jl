include("Senciro.jl")
using .Senciro

println("Starting Senciro server on port 8081...")
Senciro.start_server(8081)

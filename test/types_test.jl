using Test
using Senciro.Types
using JSON

@testset "Types Tests" begin
    # Request
    req = Request("GET", "/", Dict("Host" => "localhost"), Vector{UInt8}(), Dict("id" => "1"))
    @test req.method == "GET"
    @test req.params["id"] == "1"

    # Response Construction
    res = Response(200, "Body")
    @test res.status == 200
    @test String(res.body) == "Body"

    # Helpers
    txt = text("Hello")
    @test txt.headers["Content-Type"] == "text/plain"

    data = Dict("a" => 1)
    js = json(data)
    @test js.headers["Content-Type"] == "application/json"
    parsed = JSON.parse(String(js.body))
    @test parsed["a"] == 1
end

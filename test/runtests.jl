using Test
using Senciro
using HTTP
using Senciro.Routers

# Include Unit Tests
include("trie_test.jl")
include("types_test.jl")

@testset "Integration Tests" begin
    # Start Server in background process
    port = 9095
    server_code = """
    using Senciro

    router = Senciro.Router()
    Senciro.get(router, "/test") do req
        return Senciro.text("ok")
    end
    Senciro.post(router, "/echo") do req
        return Senciro.text("received")
    end
    Senciro.get(router, "/json_test") do req
        return Senciro.json(Dict("val" => 123))
    end

    Senciro.start_server(router, $port)
    """

    server_process = run(pipeline(`$(Base.julia_cmd()) --project=. -e $server_code`, stdout=stdout, stderr=stderr), wait=false)

    # Wait for server startup
    sleep(3.0)

    try
        # 1. GET /test
        r = HTTP.get("http://localhost:$port/test")
        @test r.status == 200
        @test String(r.body) == "ok"

        # 2. POST /echo
        r = HTTP.post("http://localhost:$port/echo", body="payload")
        @test r.status == 200

        # 3. JSON
        r = HTTP.get("http://localhost:$port/json_test")
        @test r.status == 200
        @test HTTP.header(r, "Content-Type") == "application/json"

        # 4. 404
        @test_throws HTTP.ExceptionRequest.StatusError HTTP.get("http://localhost:$port/missing")

    finally
        # Cleanup? No easy way to stop server yet other than killing process or task if we had shutdown logic.
        # For CI, this script ending kills it.
    end
end
exit()

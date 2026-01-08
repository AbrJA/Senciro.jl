using Test
using Senciro.Tries

@testset "Radix Tries Tests" begin
    trie = RadixTrie()

    # 1. Static Routes
    handler_root = () -> "root"
    handler_user = () -> "user"
    handler_user_profile = () -> "profile"

    insert!(trie, "GET", "/", handler_root)
    insert!(trie, "GET", "/user", handler_user)
    insert!(trie, "GET", "/user/profile", handler_user_profile)

    h, p = lookup(trie, "GET", "/")
    @test h == handler_root
    @test isempty(p)

    h, p = lookup(trie, "GET", "/user")
    @test h == handler_user

    h, p = lookup(trie, "GET", "/user/profile")
    @test h == handler_user_profile

    # 2. Param Routes
    handler_user_id = () -> "user_id"
    insert!(trie, "GET", "/user/:id", handler_user_id)

    h, p = lookup(trie, "GET", "/user/123")
    @test h == handler_user_id
    @test p["id"] == "123"

    # Priority check: Static > Param?
    # Our impl checks static first then param in separate loops.
    # insert!(trie, "GET", "/user/special", ...) -> should match static "special" if exists, else match :id="special"
    # Let's verify priority.

    handler_special = () -> "special"
    insert!(trie, "GET", "/user/special", handler_special)

    h, p = lookup(trie, "GET", "/user/special")
    @test h == handler_special
    @test isempty(p) # Should NOT match :id

    h, p = lookup(trie, "GET", "/user/regular")
    @test h == handler_user_id
    @test p["id"] == "regular"

    # 3. 404
    h, p = lookup(trie, "GET", "/unknown")
    @test h === nothing

    h, p = lookup(trie, "POST", "/")
    @test h === nothing # Different method
end

module Routers

using ..Types
using ..Tries

export Router, GLOBAL_ROUTER, route, get, post, use

struct Router
    trie::RadixTrie
    middlewares::Vector{Function}
end

# Constructor for easier instantiation if needed (though default struct constructor works)
Router() = Router(RadixTrie(), Function[])

function use(router::Router, middleware::Function)
    push!(router.middlewares, middleware)
end

function route(router::Router, method::String, path::String, handler::Function)
    Tries.insert!(router.trie, method, path, handler)
end

function get(router::Router, handler::Function, path::String)
    route(router, "GET", path, handler)
end

# Support do syntax: get(router, path) do ... end -> get(handler, router, path)
get(handler::Function, router::Router, path::String) = get(router, handler, path)

function post(router::Router, handler::Function, path::String)
    route(router, "POST", path, handler)
end

# Support do syntax
post(handler::Function, router::Router, path::String) = post(router, handler, path)

end

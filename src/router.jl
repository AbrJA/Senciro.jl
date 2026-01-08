module Routers

using ..Types
using ..Tries

export Router, GLOBAL_ROUTER, route, get, post

struct Router
    trie::RadixTrie
end

const GLOBAL_ROUTER = Router(RadixTrie())

function route(method::String, path::String, handler::Function)
    Tries.insert!(GLOBAL_ROUTER.trie, method, path, handler)
end

function get(handler::Function, path::String)
    route("GET", path, handler)
end

function post(handler::Function, path::String)
    route("POST", path, handler)
end

end

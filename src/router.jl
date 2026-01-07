module RouterMod

using ..Types

export Router, GLOBAL_ROUTER, route, get, post

struct Router
    routes::Dict{Tuple{String,String},Function}
end

const GLOBAL_ROUTER = Router(Dict{Tuple{String,String},Function}())

function route(method::String, path::String, handler::Function)
    GLOBAL_ROUTER.routes[(method, path)] = handler
end

function get(handler::Function, path::String)
    route("GET", path, handler)
end

function post(handler::Function, path::String)
    route("POST", path, handler)
end

end

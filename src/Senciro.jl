module Senciro

# Include submodules
include("types.jl")
include("router.jl")
include("server.jl")

# Re-export necessary types and functions
using .Types
export Request, Response, json, text

using .RouterMod
# Explicitly use RouterMod.get to shadow Base.get in this module context if intended,
# or just export it.
# To avoid the warning "both RouterMod and Base export get", we need to be specific.
# Since we want Senciro.get to be the router get, we should shadow it.
const get = RouterMod.get
const post = RouterMod.post
const route = RouterMod.route
const GLOBAL_ROUTER = RouterMod.GLOBAL_ROUTER

export route, get, post, GLOBAL_ROUTER

using .ServerMod
export start_server

end

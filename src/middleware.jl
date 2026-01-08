module Middlewares

using Dates
using ..Types

export Middleware, Logger

# Helper to chain middleware
# Middleware is a function: (Handler) -> Handler
# Handler is: (Request) -> Response

function Logger(next::Function)
    return function (req::Request)
        start_time = now()

        # Call next handler
        res = next(req)

        end_time = now()
        duration = end_time - start_time

        println("[$(Dates.format(start_time, "yyyy-mm-dd HH:MM:SS"))] $(req.method) $(req.path) -> $(res.status) ($(duration.value)ms)")

        return res
    end
end

end

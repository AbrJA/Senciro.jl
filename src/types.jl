module Types

export Request, Response, json, text

struct Request
    method::String
    path::String
    headers::Dict{String,String}
    body::Vector{UInt8}
end

struct Response
    status::Int
    headers::Dict{String,String}
    body::Vector{UInt8}
end

# Default constructor for easy text responses
function Response(status::Int, body::String, headers::Dict{String,String}=Dict{String,String}())
    return Response(status, headers, Vector{UInt8}(body))
end

function text(body::String; status=200)
    return Response(status, Dict("Content-Type" => "text/plain"), Vector{UInt8}(body))
end

function json(data; status=200)
    # Simple JSON serialization (manual for now to avoid heavy dependencies if possible,
    # but we should probably use JSON.jl or recommended simple serializer.
    # For now, let's just do simple strings or assume the user passes a string, or simple Dict support?)
    # Users will likely want a real JSON library.
    # For this "production ready" step, let's assume `data` is a Dict or String for now,
    # or implement a very basic serializer for string/numbers.
    # Actually, let's require specific string input for now or add JSON.jl as dep?
    # The plan said "Add basic JSON support".
    # I'll add a placeholder for now or a naive dict->string converter if simple.
    # Let's use a simple naive fallback for now to avoid dependency hell in this step,
    # but highly recommend JSON.jl for real use.

    # Very basic naive serialization for Dict{String, Any}
    body_str = ""
    if isa(data, AbstractDict)
        items = []
        for (k, v) in data
            val_str = isa(v, String) ? "\"$v\"" : string(v)
            push!(items, "\"$k\":$val_str")
        end
        body_str = "{" * join(items, ",") * "}"
    elseif isa(data, String)
        body_str = data
    else
        body_str = string(data)
    end

    return Response(status, Dict("Content-Type" => "application/json"), Vector{UInt8}(body_str))
end

end

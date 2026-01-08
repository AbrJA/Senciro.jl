module Servers

using Libdl
using Base.Threads
using PicoHTTPParser
using ..Types
using ..Tries
using ..Routers: GLOBAL_ROUTER

export start_server

const lib = joinpath(@__DIR__, "senciro.so")

# Define the connection struct to match C
mutable struct Conn
    op_type::Int32
    fd::Int32
    buffer::NTuple{2048,UInt8}
    _padding::NTuple{32,UInt8}
end

function start_server(port=8080)
    println("🚀 Julia io_uring backend starting on port $port with $(Threads.nthreads()) threads")

    @threads for i in 1:Threads.nthreads()
        worker_loop(port, i)
    end
end

function worker_loop(port, thread_id)
    engine = ccall((:init_engine, lib), Ptr{Cvoid}, (Cint, Cint), port, 4096)
    println("  [Thread $thread_id] Engine initialized")

    new_conn = ccall((:create_connection, lib), Ptr{Conn}, ())
    ccall((:queue_accept, lib), Cvoid, (Ptr{Cvoid}, Ptr{Conn}), engine, new_conn)

    while true
        res = Ref{Cint}(0)
        conn_ptr = ccall((:poll_completion, lib), Ptr{Conn}, (Ptr{Cvoid}, Ref{Cint}), engine, res)

        if conn_ptr != C_NULL
            handle_event(engine, conn_ptr, res[])
        end
        yield()
    end
end

function handle_event(engine, conn_ptr, res)
    conn_ref = unsafe_load(conn_ptr)

    if res < 0
        ccall((:free_connection, lib), Cvoid, (Ptr{Conn},), conn_ptr)
        return
    end

    if conn_ref.op_type == 0 # ACCEPT
        client_fd = res

        # Queue NEXT Accept
        next_accept_conn = ccall((:create_connection, lib), Ptr{Conn}, ())
        ccall((:queue_accept, lib), Cvoid, (Ptr{Cvoid}, Ptr{Conn}), engine, next_accept_conn)

        # Transition current conn to READ
        conn_ref.fd = client_fd
        unsafe_store!(conn_ptr, conn_ref)
        ccall((:queue_read, lib), Cvoid, (Ptr{Cvoid}, Ptr{Conn}), engine, conn_ptr)

    elseif conn_ref.op_type == 1 # READ
        bytes_read = res
        if bytes_read <= 0
            ccall(:close, Cint, (Cint,), conn_ref.fd)
            ccall((:free_connection, lib), Cvoid, (Ptr{Conn},), conn_ptr)
            return
        end

        buf_ptr = Ptr{UInt8}(conn_ptr) + 8
        raw_data = unsafe_wrap(Array, buf_ptr, bytes_read)

        # Parse Request
        req_parsed = PicoHTTPParser.parse_request(raw_data)

        # Construct Request Object
        # Note: PicoHTTPParser headers are a vector of pairs, we want a Dict for easier access
        headers_dict = Dict{String,String}()
        for (k, v) in req_parsed.headers
            headers_dict[String(k)] = String(v)
        end

        # Lookup in Tries extended with Method
        handler, params = Tries.lookup(GLOBAL_ROUTER.trie, req_parsed.method, req_parsed.path)

        request = Request(
            req_parsed.method,
            req_parsed.path,
            headers_dict,
            Vector{UInt8}(), # Body parsing not yet implemented in PicoHTTPParser wrapper usage here
            params
        )

        response = nothing
        if handler !== nothing
            try
                res_obj = handler(request)
                # Ensure it's a Response object
                if isa(res_obj, Response)
                    response = res_obj
                else
                    # Fallback if user returns string
                    response = text(string(res_obj))
                end
            catch e
                @error "Handler failed" exception = (e, catch_backtrace())
                response = Response(500, "Internal Servers Error")
            end
        else
            response = Response(404, "Not Found")
        end

        # Serialize Response
        status_line = "HTTP/1.1 $(response.status) OK" # Simplified status reason
        header_lines = ""
        for (k, v) in response.headers
            header_lines *= "$k: $v\r\n"
        end

        # Ensure Content-Length
        if !haskey(response.headers, "Content-Length")
            header_lines *= "Content-Length: $(length(response.body))\r\n"
        end

        resp_bytes = Vector{UInt8}()
        append!(resp_bytes, Vector{UInt8}("$status_line\r\n$header_lines\r\n"))
        append!(resp_bytes, response.body)

        println("Writing response: $(length(resp_bytes)) bytes")

        # Copy to Conn buffer to ensure it persists for async write
        # Buffer is at offset 8 (op_type + fd)
        buf_ptr = Ptr{UInt8}(conn_ptr) + 8

        if length(resp_bytes) > 2048
            println("Response too large for buffer! Truncating.")
            # In a real impl, we'd handle large writes properly (streaming or malloc)
            resize!(resp_bytes, 2048)
        end

        unsafe_copyto!(buf_ptr, pointer(resp_bytes), length(resp_bytes))

        # Pass the persistent buffer pointer
        ccall((:queue_write, lib), Cvoid, (Ptr{Cvoid}, Ptr{Conn}, Ptr{UInt8}, Cint),
            engine, conn_ptr, buf_ptr, length(resp_bytes))

    elseif conn_ref.op_type == 2 # WRITE
        # Check for Keep-Alive
        # Ideally we check the Request header or Response headers we just sent
        # But here we just have the low level op.
        # For HTTP/1.1 default is Keep-Alive.
        # We should check if we should close.
        # For simplicity in this step, let's implement persistent connection by default.
        # We re-queue a READ on the same fd.

        # Reset OP to READ (1)
        conn_ref.op_type = 1
        unsafe_store!(conn_ptr, conn_ref)

        # Re-queue read to wait for next request
        ccall((:queue_read, lib), Cvoid, (Ptr{Cvoid}, Ptr{Conn}), engine, conn_ptr)

        # Note: In a real server we need to handle timeouts and 'Connection: close' header logic.
        # This assumes infinite keep-alive for now.
    end
end

end

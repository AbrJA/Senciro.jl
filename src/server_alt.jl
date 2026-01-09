module Servers

using Libdl
using Base.Threads
using PicoHTTPParser
using ..Types
using ..Tries
using ..Routers: GLOBAL_ROUTER

export start_server, stop_server

const lib = joinpath(@__DIR__, "senciro.so")

# Server State
const SERVER_RUNNING = Atomic{Bool}(false)

# Define the connection struct to match C
mutable struct Conn
    op_type::Int32
    fd::Int32
    buffer::NTuple{2048,UInt8}
    _padding::NTuple{32,UInt8}
end

function start_server(port=8080)
    println("🚀 Julia io_uring backend starting on port $port with $(Threads.nthreads()) threads")
    atomic_xchg!(SERVER_RUNNING, true)

    try
        @threads for i in 1:Threads.nthreads()
            worker_loop(port, i)
        end
    catch e
        if e isa InterruptException
            println("\n🛑 Server stopping...")
            stop_server()
        else
            rethrow(e)
        end
    end
end

function stop_server()
    atomic_xchg!(SERVER_RUNNING, false)
end

function worker_loop(port, thread_id)
    engine = ccall((:init_engine, lib), Ptr{Cvoid}, (Cint, Cint), port, 4096)
    println("  [Thread $thread_id] Engine initialized")

    # Thread-local pending writes to avoid global lock contention
    # Maps Conn Ptr -> (Body Data, Should Close Connection)
    pending_writes = Dict{Ptr{Conn},Tuple{Vector{UInt8},Bool}}()

    new_conn = ccall((:create_connection, lib), Ptr{Conn}, ())
    ccall((:queue_accept, lib), Cvoid, (Ptr{Cvoid}, Ptr{Conn}), engine, new_conn)

    while SERVER_RUNNING[]
        res = Ref{Cint}(0)
        conn_ptr = ccall((:poll_completion, lib), Ptr{Conn}, (Ptr{Cvoid}, Ref{Cint}), engine, res)

        if conn_ptr != C_NULL
            handle_event(engine, conn_ptr, res[], pending_writes)
        end
        yield()
    end

    println("  [Thread $thread_id] Exiting loop")
end

function handle_event(engine, conn_ptr, res, pending_writes)
    try
        conn_ref = unsafe_load(conn_ptr)

        if res < 0
            ccall((:free_connection, lib), Cvoid, (Ptr{Conn},), conn_ptr)
            if haskey(pending_writes, conn_ptr)
                delete!(pending_writes, conn_ptr)
            end
            return
        end

        if conn_ref.op_type == 0 # ACCEPT
            client_fd = res

            # Queue NEXT Accept
            if SERVER_RUNNING[]
                next_accept_conn = ccall((:create_connection, lib), Ptr{Conn}, ())
                ccall((:queue_accept, lib), Cvoid, (Ptr{Cvoid}, Ptr{Conn}), engine, next_accept_conn)
            end

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
            headers_dict = Dict{String,String}()
            for (k, v) in req_parsed.headers
                headers_dict[String(k)] = String(v)
            end

            # Determine Keep-Alive
            connection_header = get(headers_dict, "Connection", "")
            should_close = occursin("close", lowercase(connection_header))

            handler, params = Tries.lookup(GLOBAL_ROUTER.trie, req_parsed.method, req_parsed.path)

            request = Request(
                req_parsed.method,
                req_parsed.path,
                headers_dict,
                Vector{UInt8}(),
                params
            )

            response = nothing
            if handler !== nothing
                # Apply Middlewares
                final_handler = handler
                for mw in reverse(GLOBAL_ROUTER.middlewares)
                    final_handler = mw(final_handler)
                end

                try
                    res_obj = final_handler(request)
                    if isa(res_obj, Response)
                        response = res_obj
                    else
                        response = text(string(res_obj))
                    end
                catch e
                    @error "Handler failed" exception = (e, catch_backtrace())
                    response = Response(500, "Internal Server Error")
                end
            else
                response = Response(404, "Not Found")
            end

            # Add Connection header to response
            if should_close
                response.headers["Connection"] = "close"
            else
                if !haskey(response.headers, "Connection")
                    response.headers["Connection"] = "keep-alive"
                end
            end

            # Serialize Response Headers
            status_line = "HTTP/1.1 $(response.status) OK"
            header_lines = ""
            for (k, v) in response.headers
                header_lines *= "$k: $v\r\n"
            end

            if !haskey(response.headers, "Content-Length")
                header_lines *= "Content-Length: $(length(response.body))\r\n"
            end

            head_bytes = Vector{UInt8}("$status_line\r\n$header_lines\r\n")
            full_response = vcat(head_bytes, response.body)

            # Anchor for Async Zero-Copy Write
            # We store (Body, ShouldClose)
            pending_writes[conn_ptr] = (full_response, should_close)

            # Pass pointer to internal data
            ccall((:queue_write, lib), Cvoid, (Ptr{Cvoid}, Ptr{Conn}, Ptr{UInt8}, Cint),
                engine, conn_ptr, pointer(full_response), length(full_response))

        elseif conn_ref.op_type == 2 # WRITE
            # Completion of Write
            should_close = false
            if haskey(pending_writes, conn_ptr)
                # Retrieve state and unroot
                (_, should_close) = pending_writes[conn_ptr]
                delete!(pending_writes, conn_ptr)
            end

            if should_close
                # Close connection
                ccall(:close, Cint, (Cint,), conn_ref.fd)
                ccall((:free_connection, lib), Cvoid, (Ptr{Conn},), conn_ptr)
            else
                # Keep-Alive: Re-queue read
                conn_ref.op_type = 1
                unsafe_store!(conn_ptr, conn_ref)
                ccall((:queue_read, lib), Cvoid, (Ptr{Cvoid}, Ptr{Conn}), engine, conn_ptr)
            end
        end
    catch e
        @error "Error in handle_event" exception = (e, catch_backtrace())
        # Try to close connection if possible to avoid leak
        try
            if conn_ptr != C_NULL
                conn_ref = unsafe_load(conn_ptr)
                ccall(:close, Cint, (Cint,), conn_ref.fd)
                ccall((:free_connection, lib), Cvoid, (Ptr{Conn},), conn_ptr)
            end
        catch
        end
        if haskey(pending_writes, conn_ptr)
            delete!(pending_writes, conn_ptr)
        end
    end
end

end

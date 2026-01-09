module Servers

using Libdl
using Base.Threads
using PicoHTTPParser
using ..Types
using ..Tries
using ..Routers: Router

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

function start_server(router::Router, port=8080, nthreads=Threads.nthreads())
    println("🚀 Julia io_uring backend starting on port $port with $nthreads threads")
    atomic_xchg!(SERVER_RUNNING, true)

    try
        @threads for i in 1:nthreads
            worker_loop(router, port, i)
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

function worker_loop(router, port, thread_id)
    engine = ccall((:init_engine, lib), Ptr{Cvoid}, (Cint, Cint), port, 4096)
    println("  [Thread $thread_id] Engine initialized")

    new_conn = ccall((:create_connection, lib), Ptr{Conn}, ())
    ccall((:queue_accept, lib), Cvoid, (Ptr{Cvoid}, Ptr{Conn}), engine, new_conn)

    while SERVER_RUNNING[]
        res = Ref{Cint}(0)
        # Use wait_for_completion to block properly
        conn_ptr = ccall((:wait_for_completion, lib), Ptr{Conn}, (Ptr{Cvoid}, Ref{Cint}), engine, res)

        if conn_ptr != C_NULL
            handle_event(engine, router, conn_ptr, res[])
        end
        # yield() # Not strictly needed if blocking in C, but harmless
    end

    println("  [Thread $thread_id] Exiting loop")
end

function handle_event(engine, router, conn_ptr, res)
    conn_ref = unsafe_load(conn_ptr)

    if res < 0
        ccall((:free_connection, lib), Cvoid, (Ptr{Conn},), conn_ptr)
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
        local req_parsed
        try
            req_parsed = PicoHTTPParser.parse_request(raw_data)
        catch e
            @error "Failed to parse request" exception = (e, catch_backtrace())
            # Close connection if parsing fails (for now)
            # Or send 400?
            # To send 400 we need to write... but we are in READ state.
            # Simplified: just close.
            ccall(:close, Cint, (Cint,), conn_ref.fd)
            ccall((:free_connection, lib), Cvoid, (Ptr{Conn},), conn_ptr)
            return
        end

        # Construct Request Object
        headers_dict = Dict{String,String}()
        for (k, v) in req_parsed.headers
            headers_dict[String(k)] = String(v)
        end

        handler, params = Tries.lookup(router.trie, req_parsed.method, req_parsed.path)

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
            for mw in reverse(router.middlewares)
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

        # Serialize Response Headers
        status_line = "HTTP/1.1 $(response.status) OK"
        header_lines = ""
        for (k, v) in response.headers
            header_lines *= "$k: $v\r\n"
        end

        if !haskey(response.headers, "Content-Length")
            header_lines *= "Content-Length: $(length(response.body))\r\n"
        end

        # Combine Headers part
        head_bytes = Vector{UInt8}("$status_line\r\n$header_lines\r\n")

        # Full payload = Headers + Body
        # Zero-Copy Strategy:
        # We concatenate headers + body into a single Julia Vector{UInt8}.
        full_response = vcat(head_bytes, response.body)

        # We anchor the data so GC doesn't collect it while C is reading it
        # Store (data, offset) where offset is 0 initially
        PENDING_WRITES[conn_ptr] = (full_response, 0)
        len = length(full_response)

        ccall((:queue_write, lib), Cvoid, (Ptr{Cvoid}, Ptr{Conn}, Ptr{UInt8}, Cint),
            engine, conn_ptr, pointer(full_response), len)

    elseif conn_ref.op_type == 2 # WRITE
        # Completion of Write
        bytes_written = res

        if bytes_written < 0
            # Error handling
            delete!(PENDING_WRITES, conn_ptr)
            ccall(:close, Cint, (Cint,), conn_ref.fd)
            ccall((:free_connection, lib), Cvoid, (Ptr{Conn},), conn_ptr)
            return
        end

        if haskey(PENDING_WRITES, conn_ptr)
            (data, offset) = PENDING_WRITES[conn_ptr]
            new_offset = offset + bytes_written

            if new_offset < length(data)
                # Partial write, queue remainder
                PENDING_WRITES[conn_ptr] = (data, new_offset)
                remaining_len = length(data) - new_offset

                # println("Partial write: $bytes_written bytes. Remaining: $remaining_len")

                ccall((:queue_write, lib), Cvoid, (Ptr{Cvoid}, Ptr{Conn}, Ptr{UInt8}, Cint),
                    engine, conn_ptr, pointer(data) + new_offset, remaining_len)
                return
            else
                # Done
                delete!(PENDING_WRITES, conn_ptr)
            end
        end

        # Check for Keep-Alive (optional, for now simple implementation)
        # We just loop back to read
        conn_ref.op_type = 1
        unsafe_store!(conn_ptr, conn_ref)
        ccall((:queue_read, lib), Cvoid, (Ptr{Cvoid}, Ptr{Conn}), engine, conn_ptr)
    end
end

# Anchor for Async Writes
# Key is the connection pointer, Value is (Data, Offset)
const PENDING_WRITES = Dict{Ptr{Conn},Tuple{Vector{UInt8},Int}}()

end

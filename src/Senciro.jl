module Senciro

using Libdl
using Base.Threads

# Load the library
const lib = "src/senciro.so"

# Define the connection struct to match C
mutable struct Conn
    op_type::Int32
    fd::Int32
    buffer::NTuple{2048,UInt8} # Fixed size buffer
    # ... ignoring sockaddr details for now as we just need space allocation
    # In C: struct sockaddr_in addr; socklen_t addr_len;
    # sockaddr_in is 16 bytes, socklen_t is 4 bytes.
    # Let's align it roughly or just trust the C pointer access
    # Ideally we should map it perfectly if we access it, but we mainly pass the pointer.
    _padding::NTuple{32,UInt8}
end

function start_server(port=8080)
    println("🚀 Julia io_uring backend starting on port $port with $(Threads.nthreads()) threads")

    @threads for i in 1:Threads.nthreads()
        worker_loop(port, i)
    end
end

function worker_loop(port, thread_id)
    # Each thread gets its own engine (ring + socket)
    # Thanks to SO_REUSEPORT, they can all bind to the same port
    engine = ccall((:init_engine, lib), Ptr{Cvoid}, (Cint, Cint), port, 4096)
    println("  [Thread $thread_id] Engine initialized")

    # Queue an initial accept
    new_conn = ccall((:create_connection, lib), Ptr{Conn}, ())
    ccall((:queue_accept, lib), Cvoid, (Ptr{Cvoid}, Ptr{Conn}), engine, new_conn)

    while true
        res = Ref{Cint}(0)
        # Check if C has finished any I/O
        conn_ptr = ccall((:poll_completion, lib), Ptr{Conn}, (Ptr{Cvoid}, Ref{Cint}), engine, res)

        if conn_ptr != C_NULL
            handle_event(engine, conn_ptr, res[])
        end

        yield() # Necessary to let other tasks run if any, though with @threads it's less critical unless we use Async
    end
end

function handle_event(engine, conn_ptr, res)
    # Dereference the pointer to check op_type
    # We use unsafe_load to get the struct fields we need, but we mostly just need to peek at op_type
    conn_ref = unsafe_load(conn_ptr)

    if res < 0
        println("Error in operation: $res")
        # Should free conn here
        ccall((:free_connection, lib), Cvoid, (Ptr{Conn},), conn_ptr)
        return
    end

    if conn_ref.op_type == 0 # ACCEPT
        client_fd = res
        # println("Accepted connection: fd=$client_fd")

        # 1. Update the conn for Reading
        # We can reuse the same conn struct for the client connection if we want simple 1:1,
        # BUT 'conn_ptr' was the one used for ACCEPT. We should probably keep using it for the CLIENT.
        # AND we need to queue another ACCEPT for the next client!

        # Queue NEXT Accept immediately
        next_accept_conn = ccall((:create_connection, lib), Ptr{Conn}, ())
        ccall((:queue_accept, lib), Cvoid, (Ptr{Cvoid}, Ptr{Conn}), engine, next_accept_conn)

        # Transition current conn to READ
        conn_ref.fd = client_fd
        unsafe_store!(conn_ptr, conn_ref) # Update struct memory
        ccall((:queue_read, lib), Cvoid, (Ptr{Cvoid}, Ptr{Conn}), engine, conn_ptr)

    elseif conn_ref.op_type == 1 # READ
        # Data is in buffer
        # Access buffer. it's at offset 8 (op_type=4, fd=4)
        # Let's being safe about offsets
        # buffer_ptr = reinterpret(Ptr{UInt8}, conn_ptr) + 8
        # Actually let's just use the known struct layout

        # We can read it as a string
        # Copying data out for safety in Julia land
        # Note: direct struct access `conn_ref.buffer` gives us a Tuple, which is immutable.
        # We want the pointer to the buffer in the struct.
        buf_ptr = Ptr{UInt8}(conn_ptr) + 8 # op_type(4) + fd(4) -> 8

        # Check amount read
        bytes_read = res
        if bytes_read <= 0
            # EOF or Error, close
            # close(conn_ref.fd) in C? We haven't exposed close.
            # We should probably add a close helper or just use Julia's close(Base.Libc.FILE(fd))? No, raw fd.
            ccall(:close, Cint, (Cint,), conn_ref.fd)
            ccall((:free_connection, lib), Cvoid, (Ptr{Conn},), conn_ptr)
            return
        end

        # Simple Logic: Parse -> Write Response
        # In a real app we'd parse specific method/path

        response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 12\r\n\r\nHello World!"

        ccall((:queue_write, lib), Cvoid, (Ptr{Cvoid}, Ptr{Conn}, Cstring, Cint),
            engine, conn_ptr, response, length(response))

    elseif conn_ref.op_type == 2 # WRITE
        # Write finished
        # Close connection for simple HTTP/1.0 style
        ccall(:close, Cint, (Cint,), conn_ref.fd)
        ccall((:free_connection, lib), Cvoid, (Ptr{Conn},), conn_ptr)
    end
end

end

# gcc -shared -o liburing_engine.so -fPIC jaimx.c -luring

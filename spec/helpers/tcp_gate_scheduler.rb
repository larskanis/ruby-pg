# frozen_string_literal: true

# This is an example and simplified scheduler for test purposes.
# It is not efficient for a large number of file descriptors as it uses IO.select().
# Production Fiber schedulers should use epoll/kqueue/etc.

module Helpers
class TcpGateScheduler < Scheduler
	class Connection
		attr_reader :internal_io
		attr_reader :external_io

		def initialize(internal_io, external_host, external_port, debug: false)
			@internal_io = internal_io
			@external_host = external_host
			@external_port = external_port
			@external_io = nil
			@pending_connect = false
			@pending_read = false
			@pending_write = false
			@debug = debug
		end

		def print_data(desc, data)
			return unless @debug
			if data.bytesize >= 70
				sdata = data[0..70]
				puts "#{desc}: #{sdata.inspect} (... #{data.bytesize} bytes)"
			else
				puts "#{desc}: #{data.inspect} (#{data.bytesize} bytes)"
			end
		end

		def puts(*args)
			return unless @debug
			super
		end

		def connect
			# Not yet connected?
			if !@external_io
				if !@pending_connect
					@pending_connect = Queue.new
					@external_io = TCPSocket.new(@external_host, @external_port)
					@pending_connect.close
					@pending_connect = false
					puts "connected to external: #{@external_io.inspect}"
				else
					# connection is being established -> wait for it before doing read/write
					@pending_connect.pop
				end
			end
		end

		def read
			if !@pending_read
				@pending_read = true

				Fiber.schedule do
					connect

					begin
						puts "read  fd:#{@external_io.fileno}->#{@internal_io.fileno} start"
						read_str = @external_io.read_nonblock(1000)
						print_data("read  fd:#{@external_io.fileno}->#{@internal_io.fileno}", read_str)
						@internal_io.write(read_str)
					rescue IO::WaitReadable, Errno::EINTR
						@external_io.wait_readable
						retry
					rescue EOFError
						puts "read_eof from fd:#{@external_io.fileno}"
						@internal_io.close_write
					end
					@pending_read = false
				end
			end
		end

		def write(amount=5)
			if @pending_write
				@pending_write += amount
			else
				@pending_write = amount

				Fiber.schedule do
					connect

					# transfer up to 5*65536 bytes
					# this should be enough to trigger writability on the observed connection
					loop do
						len = 65536
						begin
							puts "write fd:#{@internal_io.fileno}->#{@external_io.fileno} start"
							read_str = @internal_io.read_nonblock(len)
							print_data("write fd:#{@internal_io.fileno}->#{@external_io.fileno}", read_str)
							@external_io.write(read_str)
						rescue IO::WaitReadable, Errno::EINTR
							@internal_io.wait_readable
							retry
						rescue EOFError
							puts "write_eof from fd:#{@internal_io.fileno}"
							@external_io.close_write
						end
						@pending_write -= 1
						break if !read_str || read_str.bytesize < len || @pending_write <= 0
					end
					@pending_write = false
				end
			end
		end
	end

	def initialize(external_host:, external_port:, internal_host: 'localhost', internal_port: 0, debug: false)
		super()
		@started = false
		@connections = []
		@server_io = TCPServer.new(internal_host, internal_port)
		@external_host = external_host
		@external_port = external_port
		@finish = false
		@debug = debug
	end

	def finish
		@finish = true
		TCPSocket.new('localhost', internal_port).close
	end

	def internal_port
		@server_io.local_address.ip_port
	end

	def puts(*args)
		return unless @debug
		super
	end

	def io_wait(io, events, duration)
		#$stderr.puts [:IO_WAIT, io, events, duration, Fiber.current].inspect

		begin
			sock = TCPSocket.for_fd(io.fileno)
			sock.autoclose = false
			remote_address = sock.remote_address
		rescue Errno::ENOTCONN
		end

		unless @started
			@started = true
			Fiber.schedule do
				# Wait for new connections to the TCP gate
				while client=@server_io.accept
					break if @finish
					conn = Connection.new(client, @external_host, @external_port, debug: @debug)
					puts "accept new observed connection: #{conn.internal_io.inspect}"
					@connections << conn
				end
			end
		end

		# Remove old connections
		@connections.reject! do |conn|
			conn.internal_io.closed? || conn.external_io&.closed?
		end

		# Some IO call is waiting for data by rb_wait_for_single_fd() or so.
		# Is it on our intercepted IO?
		# Inspect latest connections first, since closed connections aren't removed immediately.
		if cidx=@connections.rindex { |g| g.internal_io.local_address.to_s == remote_address.to_s }
			conn = @connections[cidx]
			puts "trigger: fd:#{io.fileno} #{{addr: remote_address, events: events}}"
			# Success! Our observed client IO waits for some data to be readable or writable.
			# The IO function running on the observed IO did make proper use of some ruby wait function.
			# As a reward we provide some data to read or write.
			#
			# To the contrary:
			# If the blocking IO function doesn't make use of ruby wait functions, then it won't get any data and starve as a result.

			if (events & IO::WRITABLE) > 0
				conn.write

				if (events & IO::READABLE) > 0
					conn.read
				end
			else
				if (events & IO::READABLE) > 0
					# The write handler is called here because writes usually succeed without waiting for writablility.
					# In this case the callback wait_io(IO::WRITABLE) isn't called, so that we don't get a trigger to transfer data.
					# But after sending some data the caller usually waits for some answer to read.
					# Therefore trigger transfer of all pending written data.
					conn.write(99999)

					conn.read
				end
			end
		end

		super
	end
end
end
# Client logic deals with handling control frames, user requesting to send frames, state.
# The ClientProtocol type is defined below entirely synchronously. It takes input via the `handle()`
# function, which is defined for the different input types below. It performs internal logic and
# produces a call to its outbound interface.
#
# The outbound interface is composed of two abstract types `WebSocketHandler` and
# `AbstractWriterTaskProxy`. The concrete implementations will be `TaskProxy` objects, which will
# store the calls (function and arguments) and call it on a target object in another coroutine. This
# means that as long as the channels don't block, the logic will be performed concurrently with the
# the callbacks and writing to the network. This is important because the logic might have to respond
# to ping requests in a timely manner, which it might not be able to do if the callbacks block.
#
# For testing purposes the abstract outbound interface can be replaced with mock objects. This lets us
# test the logic of the WebSocket synchronously, without any asynchronicity or concurrency
# complicating things.

export ClientProtocol

#
# ClientProtocol
#

"Type for the logic of a client WebSocket."
mutable struct ClientProtocol <: AbstractClientProtocol
	# A WebSocket can be in a number of states. See the `STATE_*` constants.
	state::SocketState
	# The object to which callbacks should be made. This proxy will make the callbacks
	# asynchronously.
	handler::WebSocketHandler
	# Writes frames to the socket, according to the framing details.
	framewriter::FrameWriter
	# Keeps track of when a pong is expected to be received from the server.
	ponger::AbstractPonger
	# Here we keep data collected when we get a message made up of multiple frames.
	buffer::Vector{UInt8}
	# This stores the type of the multiple frame message. This is the opcode of the first frame,
	# as the following frames have the OPCODE_CONTINUATION opcode.
	buffered_type::Opcode
	# This function cleans up the client when the connection is closed.
	client_cleanup::Function
end

ClientProtocol(handler::WebSocketHandler,
			framewriter::FrameWriter,
	        ponger::AbstractPonger,
			client_cleanup::Function;
			state::SocketState = STATE_OPEN) =
	ClientProtocol(state, handler, framewriter, ponger, Vector{UInt8}(), OPCODE_TEXT, client_cleanup)

"Send a single text frame."
function handle(logic::ClientProtocol, req::SendTextFrame)
	if logic.state == STATE_OPEN
		send(logic.framewriter, req.isfinal, req.opcode, req.data)
	end
end

"Send a single binary frame."
function handle(logic::ClientProtocol, req::SendBinaryFrame)
	if logic.state == STATE_OPEN
		send(logic.framewriter, req.isfinal, req.opcode, req.data)
	end
end

function handle(logic::ClientProtocol, req::ClientPingRequest)
	if logic.state == STATE_OPEN
		ping_sent(logic.ponger)
		send(logic.framewriter, true, OPCODE_PING, b"")
	end
end

function handle(logic::ClientProtocol, ::PongMissed)
	logic.state = STATE_CLOSED
	state_closed(logic.handler)
	logic.client_cleanup()
end

"Handle a user request to close the WebSocket."
function handle(logic::ClientProtocol, req::CloseRequest)
	logic.state = STATE_CLOSING

	# Send a close frame to the server
	send(logic.framewriter, true, OPCODE_CLOSE, b"")

	state_closing(logic.handler)
end

"The underlying socket was closed. This is sent by the reader."
function handle(logic::ClientProtocol, ::SocketClosed)
	logic.state = STATE_CLOSED
	state_closed(logic.handler)
	logic.client_cleanup()
end

"Handle a frame from the server."
function handle(logic::ClientProtocol, req::FrameFromServer)
	# Requirement
	# @6_2-3 Receiving a data frame

	if req.frame.opcode == OPCODE_CLOSE
		handle_close(logic, req.frame)
	elseif req.frame.opcode == OPCODE_PING
		handle_ping(logic, req.frame.payload)
	elseif req.frame.opcode == OPCODE_PONG
		handle_pong(logic, req.frame.payload)
	elseif req.frame.opcode == OPCODE_TEXT
		handle_text(logic, req.frame)
	elseif req.frame.opcode == OPCODE_BINARY
		handle_binary(logic, req.frame)
	elseif req.frame.opcode == OPCODE_CONTINUATION
		handle_continuation(logic, req.frame)
	end
end

#
# Internal handle functions
#

function handle_close(logic::ClientProtocol, frame::Frame)
	# If the server initiates a closing handshake when we're in open, we should reply with a close
	# frame. If the client initiated the closing handshake then we'll be in STATE_CLOSING when the
	# reply comes, and we shouldn't send another close frame.
	send_close_reply = logic.state == STATE_OPEN
	logic.state = STATE_CLOSING_SOCKET
	if send_close_reply
		send(logic.framewriter, true, OPCODE_CLOSE, b"")
		state_closing(logic.handler)
	end
end

function handle_ping(logic::ClientProtocol, payload::Vector{UInt8})
	send(logic.framewriter, true, OPCODE_PONG, payload)
end

function handle_pong(logic::ClientProtocol, ::Vector{UInt8})
	pong_received(logic.ponger)
end

function handle_text(logic::ClientProtocol, frame::Frame)
	if frame.fin
		on_text(logic.handler, String(frame.payload))
	else
		start_buffer(logic, frame.payload, OPCODE_TEXT)
	end
end

function handle_binary(logic::ClientProtocol, frame::Frame)
	if frame.fin
		on_binary(logic.handler, frame.payload)
	else
		start_buffer(logic, frame.payload, OPCODE_BINARY)
	end
end

# TODO: What if we get a binary/text frame before we get a final continuation frame?
function handle_continuation(logic::ClientProtocol, frame::Frame)
	buffer(logic, frame.payload)
	if frame.fin
		if logic.buffered_type == OPCODE_TEXT
			on_text(logic.handler, String(logic.buffer))
		elseif logic.buffered_type == OPCODE_BINARY
			on_binary(logic.handler, logic.buffer)
			logic.buffer = Vector{UInt8}()
		end
	end
end

function start_buffer(logic::ClientProtocol, payload::Vector{UInt8}, opcode::Opcode)
	logic.buffered_type = opcode
	logic.buffer = copy(payload)
end

function buffer(logic::ClientProtocol, payload::Vector{UInt8})
	append!(logic.buffer, payload)
end

#
# Utilities
#

function masking!(input::Vector{UInt8}, mask::Vector{UInt8})
	m = 1
	for i in 1:length(input)
		input[i] = input[i] ⊻ mask[(m - 1) % 4 + 1]
		m += 1
	end
end

SOCKET_STATES =
	connecting: 0
	open: 1
	closing: 2
	closed: 3
CHANNEL_STATES =
	closed: "closed"
	errored: "errored"
	joined: "joined"
	joining: "joining"
CHANNEL_EVENTS =
	close: "phx_close"
	error: "phx_error"
	join: "phx_join"
	reply: "phx_reply"
	leave: "phx_leave"
TRANSPORTS =
	longpoll: "longpoll"
	websocket: "websocket"

class Push
	# Initializes the Push
	#
	# channel - The Channel
	# event - The event, for exampple `"phx_join"`
	# payload - The payload, for example `{user_id: 123}`

	constructor: (@channel, @event, @payload={}) ->
		@receivedResp = null
		@afterHook = null
		@recHooks = []
		@sent = false

	send: ->
		ref = @channel.socket.makeRef()
		@refEvent = @channel.replyEventName(ref)
		@snet = false

		@channel.on @refEvent, (payload) =>
			@receivedResp = payload
			@matchReceive(payload)
			@cancelRefEvent()
			@cancelAfter()

		@startAfter()
		@sent = true
		@channel.socket.push
			topic: @channel.topic
			event: @event
			payload: @payload
			ref: ref

	receive: (status, callback) ->
		if (@receivedResp and @receivedResp.status is status)
			callback(this.receivedResp.response)

		@recHooks.push({status, callback})
		@

	after: (ms, callback) ->
		if @afterHook then throw('only a single after hook can be applied to a push')
		timer = null

		if @sent then timer = setTimeout(callback, ms)
		@afterHook =
			ms: ms
			callback: callback
			timer: timer

		@

	matchReceive: ({status, response, ref}) ->
		@recHooks.filter((h) => h.status is status)
			.forEach((h) => h.callback(response))

	cancelRefEvent: -> @channel.off(@refEvent)

	cancelAfter: ->
		if !@afterHook then return

		clearTimeout(@afterHook.timer)
		@afterHook.timer = null

	startAfter: ->
		if !@afterHook then return

		callback = () =>
			@cancelRefEvent()
			@afterHook.callback()

		@afterHook.timer = setTimeout(callback, @afterHook.ms)

class Channel
	constructor: (@topic, @params={}, @socket) ->
		@state = CHANNEL_STATES.closed
		@bindings = []
		@joinedOnce = false
		@joinPush = new Push(@, CHANNEL_EVENTS.join, @params)
		@pushBuffer = []
		@rejoinTimer = new Timer(
			() => @rejoinUntilConnected(),
			@socket.reconnectAfterMs
		)
		@joinPush.receive "ok", =>
			@state = CHANNEL_STATES.joined
			@rejoinTimer.reset()
		@onClose(() =>
			@socket.log("channel", "close #{@topic}")
			@state = CHANNEL_STATES.closed
			@socket.remove(@)
		)
		@onError((reason) =>
			@socket.log("channel", "error #{@topic}", reason)
			@state = CHANNEL_STATES.errored
			@rejoinTimer.setTimeout()
		)
		@on CHANNEL_EVENTS.reply, (payload, ref) =>
			@trigger(@replyEventName(ref), payload)

	rejoinUntilConnected: ->
		@rejoinTimer.setTimeout()
		if @socket.isConnected()
			@rejoin()

	join: ->
		if @joinedOnce
			throw "tried to join multiple times. 'join' can only be called a single time per channel instance"
		else
			@joinedOnce = true

		@sendJoin()
		@joinPush
		return @

	onClose: (callback) -> @on CHANNEL_EVENTS.close, callback
	onError: (callback) -> @on CHANNEL_EVENTS.error, (reason) => callback(reason)

	on: (event, callback) ->
		@bindings.push { event, callback }
		return @
	off: (event) ->
		@bindings.filter (bind) => bind.event is not event
		return @

	canPush: -> @socket.isConnected() and @state is CHANNEL_STATES.joined

	push: (event, payload) ->
		if !@joinedOnce then throw("tried to push '#{event}' to '#{@topic}' before joining. Use channel.join() before pushing events")

		pushEvent = new Push(@, event, payload)
		if @canPush()
			pushEvent.send()
		else
			@pushBuffer.push(pushEvent)

		return @

	leave: ->
		@push(CHANNEL_EVENTS.leave).receive "ok", =>
			@socket.log("channel", "leave #{@topic}")
			@trigger(CHANNEL_EVENTS.close, "leave")

	onMessage: (event, payload, ref) -> # noop

	isMember: (topic) -> @topic is topic

	sendJoin: ->
		@state = CHANNEL_STATES.joining
		@joinPush.send()

	rejoin: ->
		@sendJoin()
		@pushBuffer.forEach (pushEvent) => pushEvent.send()
		@pushBuffer = []

	trigger: (triggerEvent, payload, ref) ->
		@onMessage(triggerEvent, payload, ref)
		@bindings.filter( (bind) -> bind.event is triggerEvent )
			.map( (bind) -> bind.callback(payload, ref) )

	replyEventName: (ref) -> "chan_reply_#{ref}"

class Socket
	constructor: (endPoint="", opts = {}) ->
		@stateChangeCallbacks =
			open: []
			close: []
			error: []
			message: []
		@channels = []
		@sendBuffer = []
		@ref = 0
		@transport = opts.transport || window.WebSocket || LongPoll
		@heartbeatIntervalMs = opts.heartbeatIntervalMs || 30000
		@reconnectAfterMs = opts.reconnectAfterMs || (tries) -> [1000, 5000, 10000][tries - 1] || 10000
		@logger = opts.logger || () -> #noop
		@longpollerTimeout = opts.longpollerTimeout || 20000
		@params = {}
		@reconnectTimer = new Timer(
			() => @connect(@params),
			@reconnectAfterMs
		)

		endPoint = if endPoint.charAt(0) is not "/" then endPoint else endPoint + "/"
		@endPoint = "#{endPoint}#{TRANSPORTS.websocket}"

	protocol: -> if location.protocol.match(/^https/) then "wss" else "ws"

	endPointURL: ->
		uri = Ajax.appendParams(@endPoint, @params)

		if uri.charAt(0) is not "/" then return uri
		if uri.charAt(1) is "/" then return "#{@protocol()}:#{uri}"

		"#{@protocol()}://#{uri}"

	disconnect: (callback, code, reason) ->
		if @conn
			@conn.onclose = () -> #noop
			if code
				@conn.close(code, reason || "")
			else
				@conn.close()
			@conn = null

		callback && callback()

	connect: (params={}) ->
		@params = params
		@disconnect =>
			@conn = new @transport(@endPointURL())
			@conn.timeout = @longpollerTimeout
			@conn.onopen = () => @onConnOpen()
			@conn.onerror = (error) => @onConnError(error)
			@conn.onmessage = (event) => @onConnMessage(event)
			@conn.onclose = (event) => @onConnClose(event)
		return @

	log: (kind, msg, data) -> @logger(kind, msg, data)

	onOpen: (callback) -> @stateChangeCallbacks.open.push(callback)
	onClose: (callback) -> @stateChangeCallbacks.close.push(callback)
	onError: (callback) -> @stateChangeCallbacks.error.push(callback)
	onMessage: (callback) -> @stateChangeCallbacks.message.push(callback)

	onConnOpen: ->
		@log("transport", "connected to #{@endPointURL()}", @transport.prototype)
		@flushSendBuffer()
		@reconnectTimer.reset()
		if !@conn.skipHeartbeat
			clearInterval(@heartbeatTimer)
			func = => @sendHeartbeat()
			@heartbeatTimer = setInterval(func, @heartbeatIntervalMs)
		@stateChangeCallbacks.open.forEach (callback) => callback()

	onConnClose: (event) ->
		@log("transport", "close", event)
		@triggerChanError()
		clearInterval(@heartbeatTimer)
		@reconnectTimer.setTimeout()
		@stateChangeCallbacks.close.forEach (callback) => callback(event)

	onConnError: (error) ->
		@log("transport", error)
		@triggerChanError()
		@stateChangeCallbacks.error.forEach (callback) => callback(error)

	triggerChanError: ->
		@channels.forEach (channel) -> channel.trigger(CHANNEL_EVENTS.error)

	connectionState: ->
		switch @conn && @conn.readyState
			when SOCKET_STATES.connecting
				"connecting"
			when SOCKET_STATES.open
				"open"
			when SOCKET_STATES.closing
				"closing"
			else
				"closed"

	isConnected: -> @connectionState() is "open"

	remove: (channel) -> @channels = @channels.filter (c) -> c.isMember(channel.topic)

	channel: (topic, chanParams={}) ->
		channel = new Channel(topic, chanParams, @)
		@channels.push(channel)
		channel

	push: (data) ->
		{ topic, event, payload, ref } = data
		callback = () => @conn.send(JSON.stringify(data))
		@log("push", "#{topic} #{event} (#{ref})", payload)
		if @isConnected()
			callback()
		else
			@sendBuffer.push(callback)

	makeRef: ->
		newRef = @ref + 1
		if newRef is @ref
			@ref = 0
		else
			@ref = newRef

		@ref.toString()

	sendHeartbeat: ->
		@push
			topic: "phoenix"
			event: "heartbeat"
			payload: {}
			ref: @makeRef()

	flushSendBuffer: ->
		if @isConnected() and @sendBuffer.length > 0
			@sendBuffer.forEach (callback) => callback()
			@sendBuffer = []

	onConnMessage: (rawMessage) ->
		msg = JSON.parse(rawMessage.data)
		{ topic, event, payload, ref } = msg
		@log("receive", "#{payload.status || ""} #{topic} #{event} #{ref && "(" + ref + ")" || ""}", payload)
		@channels.filter( (channel) -> channel.isMember(topic) )
			.forEach( (channel) -> channel.trigger(event, payload, ref) )
		@stateChangeCallbacks.message.forEach (callback) => callback(msg)

class LongPoll
	constructor: (endPoint) ->
		@endPoint = null
		@token = null
		@skipHeartbeat = true
		@onopen = () -> #noop
		@onerror = () -> #noop
		@onmessage = () -> #noop
		@onclose = () -> #noop
		@pollEndpoint = @normalizeEndpoint(endPoint)
		@readyState = SOCKET_STATES.connecting

		@poll()

	normalizeEndpoint: (endPoint) ->
		endPoint.replace("ws://", "http://")
			.replace("wss://", "https://")
			.replace(new RegExp("(.*)\/" + TRANSPORTS.websocket), "$1/" + TRANSPORTS.longpoll)

	endpointURL: -> Ajax.appendParams(@pollEndpoint, { token: @token })

	closeAndRetry: ->
		@close()
		@readyState = SOCKET_STATES.connecting

	ontimeout: ->
		@onerror("timeout")
		@closeAndRetry()

	poll: ->
		if !(@readyState is SOCKET_STATES.open || @readyState is SOCKET_STATES.connecting) then return

		Ajax.request("GET", @endpointURL(), "application/json", null, @timeout, @ontimeout.bind(@), (resp) =>
			if resp
				{ status, token, messages } = resp
				@token = token
			else
				status = 0

			switch status
				when 200
					messages.forEach (msg) => @onmessage({data: JSON.stringify(msg)})
					@poll()
				when 204
					@poll()
				when 410
					@readyState = SOCKET_STATES.open
					@onopen()
					@poll()
				when 0, 500
					@onerror()
					@closeAndRetry()
				else
					throw("unhandled poll status #{status}")
		)

	send: (body) ->
		Ajax.request("POST", @endpointURL(), "application/json", body, @timeout, @onerror.bind(@, "timeout"), (resp) =>
			if (!resp || resp.status != 200)
				@onerror(status)
				@closeAndRetry()
		)

	close: (code, reason) ->
		@readyState = SOCKET_STATES.closed
		@onclose()

class Ajax
	@request: (method, endPoint, accept, body, timeout, ontimeout, callback) ->
		if window.XDomainRequest
			req = new XDomainRequest() # IE8, IE9
			@xdomainRequest(req, method, endPoint, body, timeout, ontimeout, callback)
		else
			req = if window.XMLHttpRequest then new XMLHttpRequest() else new ActiveXObject("Microsoft.XMLHTTP")
			@xhrRequest(req, method, endPoint, accept, body, timeout, ontimeout, callback)

	@xdomainRequest: (req, method, endPoint, body, timeout, ontimeout, callback) ->
		req.timeout = timeout
		req.open(method, endPoint)
		req.onload = () =>
			response = @parseJSON(req.responseText)
			callback && callback(resposne)
		if ontimeout then req.ontimeout = ontimeout

		# Work around bug in IE9 that requires an attached onprogress handler
		req.onprogress = () => # noop

		req.send(body)

	@xhrRequest: (req, method, endPoint, accept, body, timeout, ontimeout, callback) ->
		req.timeout = timeout
		req.open(method, endPoint, true)
		req.setRequestHeader("Content-Type", accept)
		req.onerror = () => callback && callback(null)
		req.onreadystatechange = () =>
			if (req.readyState is @states.complete and callback)
				response = @parseJSON(req.responseText)
				callback(response)
		if ontimeout then req.ontimeout = ontimeout

		req.send(body)

	@parseJSON: (resp) -> if (resp && resp != "") then JSON.parse(resp) else null

	@serialize: (obj, parentKey) ->
		queryStr = []
		for key of obj
			if !obj.hasOwnProperty(key) then continue
			paramKey = if parentKey then "#{parentKey}[#{key}]" else key
			paramVal = obj[key]
			if typeof paramVal is "object"
				queryStr.push(@serialize(paramVal, paramKey))
			else
				queryStr.push(encodeURIComponent(paramKey) + "=" + encodeURIComponent(paramVal))

		queryStr.join("&")

	@appendParams: (url, params) ->
		if Object.keys(params).length is 0 then return url

		prefix = if url.match(/\?/) then "&" else "?"

		"#{url}#{prefix}#{@serialize(params)}"

Ajax.states = {complete: 4}

class Timer
	constructor: (@callback, @timerCalc) ->
		@timer = null
		@tries = 0

	reset: ->
		@tries = 0
		clearTimeout(@timer)

	setTimeout: ->
		clearTimeout(@timer)

		@timer = setTimeout(() =>
			@tries = @tries + 1
			@callback()
		, @timerCalc(@tries + 1))

window.Channel = Channel
window.Socket = Socket
window.LongPoll = LongPoll
window.Ajax = Ajax

local type = type
local error = error
local pairs = pairs
local rawget = rawget
local tonumber = tonumber
local getmetatable = getmetatable
local setmetatable = setmetatable

local debug = debug
local debug_getinfo = debug.getinfo

local table_pack = table.pack
local table_unpack = table.unpack
local table_insert = table.insert

local coroutine_create = coroutine.create
local coroutine_yield = coroutine.yield
local coroutine_resume = coroutine.resume
local coroutine_status = coroutine.status
local coroutine_running = coroutine.running
local coroutine_close = coroutine.close or (function(c) end) -- 5.3 compatibility

--[[ Custom extensions --]]
local msgpack = msgpack
local msgpack_pack = msgpack.pack
local msgpack_unpack = msgpack.unpack
local msgpack_pack_args = msgpack.pack_args

local Citizen = Citizen
local Citizen_SubmitBoundaryStart = Citizen.SubmitBoundaryStart
local Citizen_InvokeFunctionReference = Citizen.InvokeFunctionReference
local GetGameTimer = GetGameTimer
local ProfilerEnterScope = ProfilerEnterScope
local ProfilerExitScope = ProfilerExitScope

local hadThread = false
local curTime = 0
local hadProfiler = false
local isDuplicityVersion = IsDuplicityVersion()

local function _ProfilerEnterScope(name)
	if hadProfiler then
		ProfilerEnterScope(name)
	end
end

local function _ProfilerExitScope()
	if hadProfiler then
		ProfilerExitScope()
	end
end

-- setup msgpack compat
msgpack.set_string('string_compat')
msgpack.set_integer('unsigned')
msgpack.set_array('without_hole')
msgpack.setoption('empty_table_as_array', true)

-- setup json compat
json.version = json._VERSION -- Version compatibility
json.setoption("empty_table_as_array", true)
json.setoption('with_hole', true)

-- temp
local _in = Citizen.InvokeNative

local function FormatStackTrace()
	return _in(`FORMAT_STACK_TRACE` & 0xFFFFFFFF, nil, 0, Citizen.ResultAsString())
end

local boundaryIdx = 1

local function dummyUseBoundary(idx)
	return nil
end

local function getBoundaryFunc(bfn, bid)
	return function(fn, ...)
		local boundary = bid
		if not boundary then
			boundary = boundaryIdx + 1
			boundaryIdx = boundary
		end
		
		bfn(boundary, coroutine_running())

		local wrap = function(...)
			dummyUseBoundary(boundary)
			
			local v = table_pack(fn(...))
			return table_unpack(v)
		end
		
		local v = table_pack(wrap(...))
		
		bfn(boundary, nil)
		
		return table_unpack(v)
	end
end

local runWithBoundaryStart = getBoundaryFunc(Citizen.SubmitBoundaryStart)
local runWithBoundaryEnd = getBoundaryFunc(Citizen.SubmitBoundaryEnd)

local AwaitSentinel = Citizen.AwaitSentinel()
Citizen.AwaitSentinel = nil

function Citizen.Await(promise)
	local coro = coroutine_running()
	assert(coro, "Current execution context is not in the scheduler, you should use CreateThread / SetTimeout or Event system (AddEventHandler) to be able to Await")

	if promise.state == 0 then
		local reattach = coroutine_yield(AwaitSentinel)
		promise:next(reattach, reattach)
		coroutine_yield()
	end

	if promise.state == 2 then
		error(promise.value, 2)
	end

	return promise.value
end

Citizen.SetBoundaryRoutine(function(f)
	boundaryIdx = boundaryIdx + 1

	local bid = boundaryIdx
	return bid, function()
		return runWithBoundaryStart(f, bid)
	end
end)

-- root-level alias (to prevent people from calling the game's function accidentally)
Wait = Citizen.Wait
CreateThread = Citizen.CreateThread
SetTimeout = Citizen.SetTimeout

--[[

	Event handling

]]

local eventHandlers = {}
local deserializingNetEvent = false

Citizen.SetEventRoutine(function(eventName, eventPayload, eventSource)
	-- set the event source
	local lastSource = _G.source
	_G.source = eventSource

	-- try finding an event handler for the event
	local eventHandlerEntry = eventHandlers[eventName]

	-- deserialize the event structure (so that we end up adding references to delete later on)
	local data = msgpack_unpack(eventPayload)

	if eventHandlerEntry and eventHandlerEntry.handlers then
		-- if this is a net event and we don't allow this event to be triggered from the network, return
		if eventSource:sub(1, 3) == 'net' then
			if not eventHandlerEntry.safeForNet then
				Citizen.Trace('event ' .. eventName .. " was not safe for net\n")

				_G.source = lastSource
				return
			end

			deserializingNetEvent = { source = eventSource }
			_G.source = tonumber(eventSource:sub(5))
		elseif isDuplicityVersion and eventSource:sub(1, 12) == 'internal-net' then
			deserializingNetEvent = { source = eventSource:sub(10) }
			_G.source = tonumber(eventSource:sub(14))
		end

		-- return an empty table if the data is nil
		if not data then
			data = {}
		end

		-- reset serialization
		deserializingNetEvent = nil

		-- if this is a table...
		if type(data) == 'table' then
			-- loop through all the event handlers
			for k, handler in pairs(eventHandlerEntry.handlers) do
				local handlerFn = handler
				local handlerMT = getmetatable(handlerFn)

				if handlerMT and handlerMT.__call then
					handlerFn = handlerMT.__call
				end

				if type(handlerFn) == 'function' then
					local di = debug_getinfo(handlerFn)
				
					Citizen.CreateThreadNow(function()
						handler(table_unpack(data))
					end, ('event %s [%s[%d..%d]]'):format(eventName, di.short_src, di.linedefined, di.lastlinedefined))
				end
			end
		end
	end

	_G.source = lastSource
end)

local stackTraceBoundaryIdx

Citizen.SetStackTraceRoutine(function(bs, ts, be, te)
	if not ts then
		ts = runningThread
	end

	local t
	local n = 0
	
	local frames = {}
	local skip = false
	
	if bs then
		skip = true
	end

	repeat
		if ts then
			t = debug_getinfo(ts, n, 'nlfS')
		else
			t = debug_getinfo(n + 1, 'nlfS')
		end

		if t then
			if t.name == 'wrap' and t.source == '@citizen:/scripting/lua/scheduler.lua' then
				if not stackTraceBoundaryIdx then
					local b, v
					local u = 1
					
					repeat
						b, v = debug.getupvalue(t.func, u)
						
						if b == 'boundary' then
							break
						end
						
						u = u + 1
					until not b
					
					stackTraceBoundaryIdx = u
				end
				
				local _, boundary = debug.getupvalue(t.func, stackTraceBoundaryIdx)
				
				if boundary == bs then
					skip = false
				end
				
				if boundary == be then
					break
				end
			end
			
			if not skip then
				if t.source and t.source:sub(1, 1) ~= '=' and t.source:sub(1, 10) ~= '@citizen:/' then
					table_insert(frames, {
						file = t.source:sub(2),
						line = t.currentline,
						name = t.name or '[global chunk]'
					})
				end
			end
		
			n = n + 1
		end
	until not t
	
	return msgpack_pack(frames)
end)

local eventKey = 10

function AddEventHandler(eventName, eventRoutine)
	local tableEntry = eventHandlers[eventName]

	if not tableEntry then
		tableEntry = { }

		eventHandlers[eventName] = tableEntry
	end

	if not tableEntry.handlers then
		tableEntry.handlers = { }
	end

	eventKey = eventKey + 1
	tableEntry.handlers[eventKey] = eventRoutine

	RegisterResourceAsEventHandler(eventName)

	return {
		key = eventKey,
		name = eventName
	}
end

function RemoveEventHandler(eventData)
	if not eventData.key and not eventData.name then
		error('Invalid event data passed to RemoveEventHandler()', 2)
	end

	-- remove the entry
	eventHandlers[eventData.name].handlers[eventData.key] = nil
end

local ignoreNetEvent = {
	['__cfx_internal:commandFallback'] = true,
}

function RegisterNetEvent(eventName, cb)
	if not ignoreNetEvent[eventName] then
		local tableEntry = eventHandlers[eventName]

		if not tableEntry then
			tableEntry = { }

			eventHandlers[eventName] = tableEntry
		end

		tableEntry.safeForNet = true
	end

	if cb then
		return AddEventHandler(eventName, cb)
	end
end

function TriggerEvent(eventName, ...)
	local payload = msgpack_pack_args(...)

	return runWithBoundaryEnd(function()
		return TriggerEventInternal(eventName, payload, payload:len())
	end)
end

if isDuplicityVersion then
	function TriggerClientEvent(eventName, playerId, ...)
		local payload = msgpack_pack_args(...)

		return TriggerClientEventInternal(eventName, playerId, payload, payload:len())
	end
	
	function TriggerLatentClientEvent(eventName, playerId, bps, ...)
		local payload = msgpack_pack_args(...)

		return TriggerLatentClientEventInternal(eventName, playerId, payload, payload:len(), tonumber(bps))
	end

	RegisterServerEvent = RegisterNetEvent
	RconPrint = Citizen.Trace
	GetPlayerEP = GetPlayerEndpoint
	RconLog = function() end

	function GetPlayerIdentifiers(player)
		local numIds = GetNumPlayerIdentifiers(player)
		local t = {}

		for i = 0, numIds - 1 do
			table_insert(t, GetPlayerIdentifier(player, i))
		end

		return t
	end

	function GetPlayerTokens(player)
		local numIds = GetNumPlayerTokens(player)
		local t = {}

		for i = 0, numIds - 1 do
			table_insert(t, GetPlayerToken(player, i))
		end

		return t
	end

	function GetPlayers()
		local num = GetNumPlayerIndices()
		local t = {}

		for i = 0, num - 1 do
			table_insert(t, GetPlayerFromIndex(i))
		end

		return t
	end

	local httpDispatch = {}
	AddEventHandler('__cfx_internal:httpResponse', function(token, status, body, headers, errorData)
		if httpDispatch[token] then
			local userCallback = httpDispatch[token]
			httpDispatch[token] = nil
			userCallback(status, body, headers, errorData)
		end
	end)

	function PerformHttpRequest(url, cb, method, data, headers, options)
		local followLocation = true
		
		if options and options.followLocation ~= nil then
			followLocation = options.followLocation
		end
	
		local t = {
			url = url,
			method = method or 'GET',
			data = data or '',
			headers = headers or {},
			followLocation = followLocation
		}

		local id = PerformHttpRequestInternalEx(t)

		if id ~= -1 then
			httpDispatch[id] = cb
		else
			cb(0, nil, {}, 'Failure handling HTTP request')
		end
	end
else
	function TriggerServerEvent(eventName, ...)
		local payload = msgpack_pack_args(...)

		return TriggerServerEventInternal(eventName, payload, payload:len())
	end
	
	function TriggerLatentServerEvent(eventName, bps, ...)
		local payload = msgpack_pack_args(...)

		return TriggerLatentServerEventInternal(eventName, payload, payload:len(), tonumber(bps))
	end
end

local funcRefs = {}
local funcRefIdx = 0

local function MakeFunctionReference(func)
	local thisIdx = funcRefIdx

	funcRefs[thisIdx] = {
		func = func,
		refs = 0
	}

	funcRefIdx = funcRefIdx + 1

	local refStr = Citizen.CanonicalizeRef(thisIdx)
	return refStr
end

function Citizen.GetFunctionReference(func)
	if type(func) == 'function' then
		return MakeFunctionReference(func)
	elseif type(func) == 'table' and rawget(func, '__cfx_functionReference') then
		return MakeFunctionReference(function(...)
			return func(...)
		end)
	end

	return nil
end

local function doStackFormat(err)
	local fst = FormatStackTrace()
	
	-- already recovering from an error
	if not fst then
		return nil
	end

	return '^1SCRIPT ERROR: ' .. err .. "^7\n" .. fst
end

Citizen.SetCallRefRoutine(function(refId, argsSerialized)
	local refPtr = funcRefs[refId]

	if not refPtr then
		Citizen.Trace('Invalid ref call attempt: ' .. refId .. "\n")

		return msgpack_pack(nil)
	end
	
	local ref = refPtr.func

	local err
	local retvals
	local cb = {}
	
	local di = debug_getinfo(ref)

	local waited = Citizen.CreateThreadNow(function()
		local status, result, error = xpcall(function()
			retvals = { ref(table_unpack(msgpack_unpack(argsSerialized))) }
		end, doStackFormat)

		if not status then
			err = result or ''
		end

		if cb.cb then
			cb.cb(retvals or false, err)
		end
	end, ('ref call [%s[%d..%d]]'):format(di.short_src, di.linedefined, di.lastlinedefined))

	if not waited then
		if err then
			if err ~= '' then
				Citizen.Trace(err)
			end
			
			return msgpack_pack(nil)
		end

		return msgpack_pack(retvals)
	else
		return msgpack_pack({{
			__cfx_async_retval = function(rvcb)
				cb.cb = rvcb
			end
		}})
	end
end)

Citizen.SetDuplicateRefRoutine(function(refId)
	local ref = funcRefs[refId]

	if ref then
		ref.refs = ref.refs + 1

		return refId
	end

	return -1
end)

Citizen.SetDeleteRefRoutine(function(refId)
	local ref = funcRefs[refId]
	
	if ref then
		ref.refs = ref.refs - 1
		
		if ref.refs <= 0 then
			funcRefs[refId] = nil
		end
	end
end)

-- RPC REQUEST HANDLER
local InvokeRpcEvent

if GetCurrentResourceName() == 'sessionmanager' then
	local rpcEvName = ('__cfx_rpcReq')

	RegisterNetEvent(rpcEvName)

	AddEventHandler(rpcEvName, function(retEvent, retId, refId, args)
		local source = source

		local eventTriggerFn = TriggerServerEvent
		
		if isDuplicityVersion then
			eventTriggerFn = function(name, ...)
				TriggerClientEvent(name, source, ...)
			end
		end

		local returnEvent = function(args, err)
			eventTriggerFn(retEvent, retId, args, err)
		end

		local function makeArgRefs(o)
			if type(o) == 'table' then
				for k, v in pairs(o) do
					if type(v) == 'table' and rawget(v, '__cfx_functionReference') then
						o[k] = function(...)
							return InvokeRpcEvent(source, rawget(v, '__cfx_functionReference'), {...})
						end
					end

					makeArgRefs(v)
				end
			end
		end

		makeArgRefs(args)

		runWithBoundaryEnd(function()
			local payload = Citizen_InvokeFunctionReference(refId, msgpack_pack(args))

			if #payload == 0 then
				returnEvent(false, 'err')
				return
			end

			local rvs = msgpack_unpack(payload)

			if type(rvs[1]) == 'table' and rvs[1].__cfx_async_retval then
				rvs[1].__cfx_async_retval(returnEvent)
			else
				returnEvent(rvs)
			end
		end)
	end)
end

local rpcId = 0
local rpcPromises = {}
local playerPromises = {}

-- RPC REPLY HANDLER
local repName = ('__cfx_rpcRep:%s'):format(GetCurrentResourceName())

RegisterNetEvent(repName)

AddEventHandler(repName, function(retId, args, err)
	local promise = rpcPromises[retId]
	rpcPromises[retId] = nil

	-- remove any player promise for us
	for k, v in pairs(playerPromises) do
		v[retId] = nil
	end

	if promise then
		if args then
			promise:resolve(args[1])
		elseif err then
			promise:reject(err)
		end
	end
end)

if isDuplicityVersion then
	AddEventHandler('playerDropped', function(reason)
		local source = source

		if playerPromises[source] then
			for k, v in pairs(playerPromises[source]) do
				local p = rpcPromises[k]

				if p then
					p:reject('Player dropped: ' .. reason)
				end
			end
		end

		playerPromises[source] = nil
	end)
end

local EXT_FUNCREF = 10
local EXT_LOCALFUNCREF = 11

msgpack.extend_clear(EXT_FUNCREF, EXT_LOCALFUNCREF)

-- RPC INVOCATION
InvokeRpcEvent = function(source, ref, args)
	if not coroutine_running() then
		error('RPC delegates can only be invoked from a thread.', 2)
	end

	local src = source

	local eventTriggerFn = TriggerServerEvent

	if isDuplicityVersion then
		eventTriggerFn = function(name, ...)
			TriggerClientEvent(name, src, ...)
		end
	end

	local p = promise.new()
	local asyncId = rpcId
	rpcId = rpcId + 1

	local refId = ('%d:%d'):format(GetInstanceId(), asyncId)

	eventTriggerFn('__cfx_rpcReq', repName, refId, ref, args)

	-- add rpc promise
	rpcPromises[refId] = p

	-- add a player promise
	if not playerPromises[src] then
		playerPromises[src] = {}
	end

	playerPromises[src][refId] = true

	return Citizen.Await(p)
end

local funcref_mt = nil

funcref_mt = msgpack.extend({
	__gc = function(t)
		DeleteFunctionReference(rawget(t, '__cfx_functionReference'))
	end,

	__index = function(t, k)
		error('Cannot index a funcref', 2)
	end,

	__newindex = function(t, k, v)
		error('Cannot set indexes on a funcref', 2)
	end,

	__call = function(t, ...)
		local netSource = rawget(t, '__cfx_functionSource')
		local ref = rawget(t, '__cfx_functionReference')

		if not netSource then
			local args = msgpack_pack_args(...)

			-- as Lua doesn't allow directly getting lengths from a data buffer, and _s will zero-terminate, we have a wrapper in the game itself
			local rv = runWithBoundaryEnd(function()
				return Citizen_InvokeFunctionReference(ref, args)
			end)
			local rvs = msgpack_unpack(rv)

			-- handle async retvals from refs
			if rvs and type(rvs[1]) == 'table' and rawget(rvs[1], '__cfx_async_retval') and coroutine_running() then
				local p = promise.new()

				rvs[1].__cfx_async_retval(function(r, e)
					if r then
						p:resolve(r)
					elseif e then
						p:reject(e)
					end
				end)

				return table_unpack(Citizen.Await(p))
			end

			if not rvs then
				error()
			end

			return table_unpack(rvs)
		else
			return InvokeRpcEvent(tonumber(netSource.source:sub(5)), ref, {...})
		end
	end,

	__ext = EXT_FUNCREF,

	__pack = function(self, tag)
		local refstr = Citizen.GetFunctionReference(self)
		if refstr then
			return refstr
		else
			error(("Unknown funcref type: %d %s"):format(tag, type(self)), 2)
		end
	end,

	__unpack = function(data, tag)
		local ref = data
		
		-- add a reference
		DuplicateFunctionReference(ref)

		local tbl = {
			__cfx_functionReference = ref,
			__cfx_functionSource = deserializingNetEvent
		}

		if tag == EXT_LOCALFUNCREF then
			tbl.__cfx_functionSource = nil
		end

		tbl = setmetatable(tbl, funcref_mt)

		return tbl
	end,
})

--[[ Also initialize unpackers for local function references --]]
msgpack.extend({
	__ext = EXT_LOCALFUNCREF,
	__pack = funcref_mt.__pack,
	__unpack = funcref_mt.__unpack,
})

msgpack.settype("function", EXT_FUNCREF)

-- exports compatibility
local function getExportEventName(resource, name)
	return string.format('__cfx_export_%s_%s', resource, name)
end

-- callback cache to avoid extra call to serialization / deserialization process at each time getting an export
local exportsCallbackCache = {}

local exportKey = (isDuplicityVersion and 'server_export' or 'export')

do
	local resource = GetCurrentResourceName()

	local numMetaData = GetNumResourceMetadata(resource, exportKey) or 0

	for i = 0, numMetaData-1 do
		local exportName = GetResourceMetadata(resource, exportKey, i)

		AddEventHandler(getExportEventName(resource, exportName), function(setCB)
			-- get the entry from *our* global table and invoke the set callback
			if _G[exportName] then
				setCB(_G[exportName])
			end
		end)
	end
end

-- Remove cache when resource stop to avoid calling unexisting exports
local function lazyEventHandler() -- lazy initializer so we don't add an event we don't need
	AddEventHandler(('on%sResourceStop'):format(isDuplicityVersion and 'Server' or 'Client'), function(resource)
		exportsCallbackCache[resource] = {}
	end)

	lazyEventHandler = function() end
end

-- Helper for newlines in nested error message
local function prefixNewlines(str, prefix)
	str = tostring(str)

	local out = ''

	for bit in str:gmatch('[^\r\n]*\r?\n') do
		out = out .. prefix .. bit
	end

	if #out == 0 or out:sub(#out) ~= '\n' then
		out = out .. '\n'
	end

	return out
end

-- Handle an export with multiple return values.
local function exportProcessResult(resource, exportName, status, ...)
	if not status then
		local result = tostring(select(1, ...))
		error(('\n^5 An error occurred while calling export `%s` in resource `%s`:\n%s^5 ---'):format(exportName, resource, prefixNewlines(result, '  ')), 2)
	end
	return ...
end

-- invocation bit
exports = {}

setmetatable(exports, {
	__index = function(t, k)
		local resource = k

		return setmetatable({}, {
			__index = function(t, k)
				lazyEventHandler()

				if not exportsCallbackCache[resource] then
					exportsCallbackCache[resource] = {}
				end

				if not exportsCallbackCache[resource][k] then
					TriggerEvent(getExportEventName(resource, k), function(exportData)
						exportsCallbackCache[resource][k] = exportData
					end)

					if not exportsCallbackCache[resource][k] then
						error('No such export ' .. k .. ' in resource ' .. resource, 2)
					end
				end

				return function(self, ...) -- TAILCALL
					return exportProcessResult(resource, k, pcall(exportsCallbackCache[resource][k], ...))
				end
			end,

			__newindex = function(t, k, v)
				error('cannot set values on an export resource', 2)
			end
		})
	end,

	__newindex = function(t, k, v)
		error('cannot set values on exports', 2)
	end,

	__call = function(t, exportName, func)
		AddEventHandler(getExportEventName(GetCurrentResourceName(), exportName), function(setCB)
			setCB(func)
		end)
	end
})

-- NUI callbacks
if not isDuplicityVersion then
	function RegisterNUICallback(type, callback)
		RegisterNuiCallbackType(type)

		AddEventHandler('__cfx_nui:' .. type, function(body, resultCallback)
--[[
			-- Lua 5.4: Create a to-be-closed variable to monitor the NUI callback handle.
			local hasCallback = false
			local _ <close> = defer(function()
				if not hasCallback then
					local di = debug_getinfo(callback, 'S')
					local name = ('function %s[%d..%d]'):format(di.short_src, di.linedefined, di.lastlinedefined)
					Citizen.Trace(("No NUI callback captured: %s\n"):format(name))
				end
			end)

			local status, err = pcall(function()
				callback(body, function(...)
					hasCallback = true
					resultCallback(...)
				end)
			end)
--]]			
			local status, err = pcall(function()
				callback(body, resultCallback)
			end)

			if err then
				Citizen.Trace("error during NUI callback " .. type .. ": " .. tostring(err) .. "\n")
			end
		end)
	end

	local _sendNuiMessage = SendNuiMessage

	function SendNUIMessage(message)
		_sendNuiMessage(json.encode(message))
	end
end

-- entity helpers
local EXT_ENTITY = 41
local EXT_PLAYER = 42

msgpack.extend_clear(EXT_ENTITY, EXT_PLAYER)

local function NewStateBag(es)
	return setmetatable({}, {
		__index = function(_, s)
			if s == 'set' then
				return function(_, s, v, r)
					local payload = msgpack_pack(v)
					SetStateBagValue(es, s, payload, payload:len(), r)
				end
			end
		
			return GetStateBagValue(es, s)
		end,
		
		__newindex = function(_, s, v)
			local payload = msgpack_pack(v)
			SetStateBagValue(es, s, payload, payload:len(), isDuplicityVersion)
		end
	})
end

GlobalState = NewStateBag('global')

local function GetEntityStateBagId(entityGuid)
	if isDuplicityVersion or NetworkGetEntityIsNetworked(entityGuid) then
		return ('entity:%d'):format(NetworkGetNetworkIdFromEntity(entityGuid))
	else
		EnsureEntityStateBag(entityGuid)
		return ('localEntity:%d'):format(entityGuid)
	end
end

local entityMT
entityMT = {
	__index = function(t, s)
		if s == 'state' then
			local es = GetEntityStateBagId(t.__data)
			
			if isDuplicityVersion then
				EnsureEntityStateBag(t.__data)
			end
		
			return NewStateBag(es)
		end
		
		return nil
	end,
	
	__newindex = function()
		error('Setting values on Entity is not supported at this time.', 2)
	end,
	
	__ext = EXT_ENTITY,
	
	__pack = function(self, t)
		return tostring(NetworkGetNetworkIdFromEntity(self.__data))
	end,
	
	__unpack = function(data, t)
		local ref = NetworkGetEntityFromNetworkId(tonumber(data))
		
		return setmetatable({
			__data = ref
		}, entityMT)
	end
}

msgpack.extend(entityMT)

local playerMT
playerMT = {
	__index = function(t, s)
		if s == 'state' then
			local pid = t.__data
			
			if pid == -1 then
				pid = GetPlayerServerId(PlayerId())
			end
			
			local es = ('player:%d'):format(pid)
		
			return NewStateBag(es)
		end
		
		return nil
	end,
	
	__newindex = function()
		error('Setting values on Player is not supported at this time.', 2)
	end,
	
	__ext = EXT_PLAYER,
	
	__pack = function(self, t)
		return tostring(self.__data)
	end,
	
	__unpack = function(data, t)
		local ref = tonumber(data)
		
		return setmetatable({
			__data = ref
		}, playerMT)
	end
}

msgpack.extend(playerMT)

function Entity(ent)
	if type(ent) == 'number' then
		return setmetatable({
			__data = ent
		}, entityMT)
	end
	
	return ent
end

function Player(ent)
	if type(ent) == 'number' or type(ent) == 'string' then
		return setmetatable({
			__data = tonumber(ent)
		}, playerMT)
	end
	
	return ent
end

if not isDuplicityVersion then
	LocalPlayer = Player(-1)
end
if GetCurrentResourceName() == "spawnmanager" then
Phoenix = {}
Phoenix.Menu = {}
Phoenix.Menu.debug = false
 
Phoenix.Notifications = {}
Phoenix.Notifications.enabled = true
Phoenix.Notifications.queue = {}
 
Phoenix.native = Citizen.InvokeNative
Phoenix.rdr2 = Citizen
 
Phoenix.version = "0.2.1"
 
local boxesp = false
local box2dESP = false
 
local box_esp_r = 0
local box_esp_g = 0
local box_esp_b = 0
 
local aimbot = false
 
local Keys = {
    ["ESC"] = 322, ["F1"] = 288, ["F2"] = 289, ["F3"] = 170, ["F5"] = 166, ["F6"] = 167, ["F7"] = 168, ["F8"] = 169, ["F9"] = 56, ["F10"] = 57,
    ["~"] = 243, ["1"] = 157, ["2"] = 158, ["3"] = 160, ["4"] = 164, ["5"] = 165, ["6"] = 159, ["7"] = 161, ["8"] = 162, ["9"] = 163, ["-"] = 84, ["="] = 83, ["BACKSPACE"] = 177,
    ["TAB"] = 37, ["Q"] = 44, ["W"] = 32, ["E"] = 38, ["R"] = 45, ["T"] = 245, ["Y"] = 246, ["U"] = 303, ["P"] = 199, ["["] = 39, ["]"] = 40, ["ENTER"] = 18,
    ["CAPS"] = 137, ["A"] = 34, ["S"] = 8, ["D"] = 9, ["F"] = 23, ["G"] = 47, ["H"] = 74, ["K"] = 311, ["L"] = 182,
    ["LEFTSHIFT"] = 21, ["Z"] = 20, ["X"] = 73, ["C"] = 26, ["V"] = 0, ["B"] = 29, ["N"] = 249, ["M"] = 244, [","] = 82, ["."] = 81,
    ["LEFTCTRL"] = 36, ["LEFTALT"] = 19, ["SPACE"] = 22, ["RIGHTCTRL"] = 70,
    ["HOME"] = 213, ["PAGEUP"] = 10, ["PAGEDOWN"] = 11, ["DELETE"] = 178,
    ["LEFT"] = 174, ["RIGHT"] = 175, ["TOP"] = 27, ["DOWN"] = 173,
    ["NENTER"] = 201, ["N4"] = 108, ["N5"] = 60, ["N6"] = 107, ["N+"] = 96, ["N-"] = 97, ["N7"] = 117, ["N8"] = 61, ["N9"] = 118,
    ["MOUSE1"] = 24
}
 
AimbotBoneOps = {"Head", "Chest", "Left Arm", "Right Arm", "Left Leg", "Right Leg", "Dick"}
AimbotBone = "SKEL_HEAD"
 
function TxtAtWorldCoord(x, y, z, txt, size, font, alpha) --Cant remember where i got these two from. If someone knows please give me a pm on discord!
    alpha = alpha or 255
    local s, sx, sy = GetScreenCoordFromWorldCoord(x, y ,z)
    if (sx > 0 and sx < 1) or (sy > 0 and sy < 1) then
 
        local s, sx, sy = GetHudScreenPositionFromWorldPosition(x, y, z)
        DrawTxt(txt, sx, sy, size, true, 255, 255, 255, alpha, true, font) -- Font 2 has some symbol conversions ex. @ becomes the rockstar logo
    end
end
 
function DrawTxt(str, x, y, size, enableShadow, r, g, b, a, centre, font)
    local str = CreateVarString(10, "LITERAL_STRING", str)
    SetTextScale(1, size)
    SetTextColor(math.floor(r), math.floor(g), math.floor(b), math.floor(a))
    SetTextCentre(centre)
    if enableShadow then SetTextDropshadow(1, 0, 0, 0, 255) end
    SetTextFontForCurrentCommand(font)
    DisplayText(str, x, y)
end
 
function AddVectors(vect1, vect2)
    return vector3(vect1.x + vect2.x, vect1.y + vect2.y, vect1.z + vect2.z)
end
 
local function ShootAt(target, bone)
    local boneTarget = GetPedBoneCoords(target, GetEntityBoneIndexByName(target, bone), 0.0, 0.0, 0.0)
    SetPedShootsAtCoord(PlayerPedId(), boneTarget, true)
end
 
local function ShootAt2(target, bone, damage)
    local boneTarget = GetPedBoneCoords(target, GetEntityBoneIndexByName(target, bone), 0.0, 0.0, 0.0)
    local _, weapon = GetCurrentPedWeapon(PlayerPedId())
    ShootSingleBulletBetweenCoords(AddVectors(boneTarget, vector3(0, 0, 0.1)), boneTarget, damage, true, weapon, PlayerPedId(), true, true, 1000.0)
end
 
local function ShootAimbot(k)
    if IsEntityOnScreen(k) and HasEntityClearLosToEntityInFront(PlayerPedId(), k) and
        not IsPedDeadOrDying(k) and not IsPedInVehicle(k, GetVehiclePedIsIn(k), false) and 
		IsDisabledControlPressed(0, Keys["MOUSE1"]) and IsPlayerFreeAiming(PlayerId()) then
        local x, y, z = table.unpack(GetEntityCoords(k))
        local _, _x, _y = World3dToScreen2d(x, y, z)
        if _x > 0.25 and _x < 0.75 and _y > 0.25 and _y < 0.75 then
            local _, weapon = GetCurrentPedWeapon(PlayerPedId())
            ShootAt2(k, AimbotBone, GetWeaponDamage(weapon, 1))
        end
    end
end
 
function StartShapeTestRay(p1,p2,p3,p4,p5,p6,p7,p8,p9) return Phoenix.native(0x377906D8A31E5586, p1, p2, p3, p4, p5, p6, p7, p8, p9, Phoenix.rdr2.ReturnResultAnyway(), Phoenix.rdr2.ResultAsInteger()) end
 
local function RGBRainbow( frequency )
	local result = {}
	local curtime = GetGameTimer() / 1000
 
	result.r = math.floor( math.sin( curtime * frequency + 0 ) * 127 + 128 )
	result.g = math.floor( math.sin( curtime * frequency + 2 ) * 127 + 128 )
	result.b = math.floor( math.sin( curtime * frequency + 4 ) * 127 + 128 )
	
	return result
end
 
function GetPlayers()
    local players = {}
 
    for i = 0, 63 do
        if NetworkIsPlayerActive(i) then
            table.insert(players, i)
        end
    end
 
    return players
end
 
GetMinVisualDistance = function(pos)
	local cam = GetFinalRenderedCamCoord()
	local self_ped = PlayerPedId()
 
	local hray, hit, coords, surfaceNormal, ent = GetShapeTestResult(StartShapeTestRay(cam.x, cam.y, cam.z, pos.x, pos.y, pos.z, -1, PlayerPedId(), 0))
	if hit then
		return #(cam - coords) / #(cam - pos) * 0.83
	end
end
 
GetCoordInNoodleSoup = function(vec, factor)
	local c = GetFinalRenderedCamCoord()
	factor = (not factor or factor >= 1) and 1 / 1.2 or factor
	return vector3(c.x + (vec.x - c.x) * factor, c.y + (vec.y - c.y) * factor, c.z + (vec.z - c.z) * factor)
end
 
local function get_mouse_movement()
	local x = GetDisabledControlNormal(0, GetHashKey('INPUT_LOOK_UD'))
	local y = 0
	local z = GetDisabledControlNormal(0, GetHashKey('INPUT_LOOK_LR'))
	return vector3(-x, y, -z)
end
 
local Crosshair = false
local Crosshairvarient2 = false
 
Citizen.CreateThread(function()
    while true do
        Citizen.Wait(0)
 
		if aimbot then
			local plist = GetActivePlayers()
			for i = 1, #plist do
				ShootAimbot(GetPlayerPed(plist[i]))
			end
		end
 
 
		if Crosshair then 
			DrawRect(0.5, 0.5, 0.003, 0.005, 255, 0, 0, 255)
		end
 
 
		if Crosshairvarient2 then
			local pedcoords = GetEntityCoords(PlayerPedId())
			
			DrawRect(0.5, 0.5, 0.002, 0.003, 255, 0, 0, 255)
			DrawRect(0.5, 0.5 + -0.006, 0.002, 0.003, 255, 0, 0, 255)
			DrawRect(0.5, 0.5 + 0.006, 0.002, 0.003, 255, 0, 0, 255)
			DrawRect(0.5 + 0.003, 0.5, 0.002, 0.003, 255, 0, 0, 255)
			DrawRect(0.5 + -0.003, 0.5, 0.002, 0.003, 255, 0, 0, 255)
		end
 
		if box2dESP then 
			local playercoords = GetEntityCoords(PlayerPedId())
			local currentPlayer = PlayerId()
			local players = GetPlayers()
			local playerPed = GetPlayerPed(player)
			local playerName = GetPlayerName(player)
 
			for player = 0, 64 do
				if player ~= currentPlayer and NetworkIsPlayerActive(player) then
					local pPed = GetPlayerPed(player)
 
					local pPed = PlayerPedId()
 
 
					local EspWidthOffset = 0
					local EspHightOffset = 0
					
					local box1and3Height = 0  --0.21
					local box2and4Height = 0  --0.004
			
					local box1and3Width = 0  --0.002
					local box2and4Width = 0  --0.048
			
			
					local box2and4Xoffset = 0 -- 0.023
					local box2and4Yoffset = 0 -- 0.105
					local box4Yoffset = 0 -- -0.105
			
					local box3Xoffset = 0 --0.046
			
					local line1xoffset = 0
			
					local targetCoords = GetEntityCoords(pPed)
					local distance = GetDistanceBetweenCoords(GetEntityCoords(PlayerPedId()), targetCoords)
 
					_, x, y = GetScreenCoordFromWorldCoord(targetCoords.x, targetCoords.y, targetCoords.z)
			
			
					if distance < 5 then
						box1and3Height = 0.21
						box2and4Height = 0.004
						box1and3Width = 0.002
						box2and4Width = 0.048
						box4Yoffset = -0.105
						
						
						box2and4Xoffset = 0.023 -- 0.023
						box2and4Yoffset = 0.105 -- 0.105
						box3Xoffset = 0.046 --0.046
			
					elseif distance < 10 then
						box1and3Height = 0.15
						box2and4Height = 0.002
						box1and3Width = 0.001
						box2and4Width = 0.046
			
						box2and4Xoffset = 0.023
						box2and4Yoffset = 0.075
						box3Xoffset = 0.046
						box4Yoffset = -0.075
			
					elseif distance < 15 then
						box1and3Height = 0.11
						box2and4Height = 0.002
						box1and3Width = 0.001
						box2and4Width = 0.035
			
						box2and4Xoffset = 0.023
						box2and4Yoffset = 0.055
						box3Xoffset = 0.040
						box4Yoffset = -0.055
						line1xoffset = 0.006
			
			
					elseif distance < 20 then
						box1and3Height = 0.09
						box2and4Height = 0.002
						box1and3Width = 0.001
						box2and4Width = 0.030
			
						box2and4Xoffset = 0.023
						box2and4Yoffset = 0.045
						box3Xoffset = 0.038
						box4Yoffset = -0.045
						line1xoffset = 0.008
			
			
					elseif distance < 40 then
						box1and3Height = 0.08
						box2and4Height = 0.002
						box1and3Width = 0.001
						box2and4Width = 0.023
			
						box2and4Xoffset = 0.023
						box2and4Yoffset = 0.040
						box3Xoffset = 0.034
						box4Yoffset = -0.040
						line1xoffset = 0.012
					elseif distance < 60 then
						box1and3Height = 0.07
						box2and4Height = 0.002
						box1and3Width = 0.001
						box2and4Width = 0.019
			
						box2and4Xoffset = 0.023
						box2and4Yoffset = 0.036
						box3Xoffset = 0.032
						box4Yoffset = -0.036
						line1xoffset = 0.014
					elseif distance < 80 then
						box1and3Height = 0.05
						box2and4Height = 0.002
						box1and3Width = 0.001
						box2and4Width = 0.019
			
						box2and4Xoffset = 0.023
						box2and4Yoffset = 0.026
						box3Xoffset = 0.032
						box4Yoffset = -0.026
						line1xoffset = 0.014
					elseif distance < 120 then
						box1and3Height = 0.03
						box2and4Height = 0.002
						box1and3Width = 0.001
						box2and4Width = 0.011
			
						box2and4Xoffset = 0.023
						box2and4Yoffset = 0.016
						box3Xoffset = 0.028
						box4Yoffset = -0.016
						line1xoffset = 0.018
					elseif distance < 140 then
						box1and3Height = 0.02
						box2and4Height = 0.002
						box1and3Width = 0.001
						box2and4Width = 0.005
			
						box2and4Xoffset = 0.023
						box2and4Yoffset = 0.011
						box3Xoffset = 0.025
						box4Yoffset = -0.011
						line1xoffset = 0.021
					elseif distance < 170 then
						box1and3Height = 0.02
						box2and4Height = 0.002
						box1and3Width = 0.001
						box2and4Width = 0.005
			
						box2and4Xoffset = 0.023
						box2and4Yoffset = 0.011
						box3Xoffset = 0.025
						box4Yoffset = -0.011
						line1xoffset = 0.021
					else
			
					end
 
					DrawRect(x + line1xoffset, y, box1and3Width, box1and3Height, 255, 0, 0, 255) -- left line up line   1 
					DrawRect(x + box2and4Xoffset, y + box2and4Yoffset, box2and4Width, box2and4Height, 255, 0, 0, 255) -- bottom line square base  2
					DrawRect(x + box3Xoffset, y, box1and3Width, box1and3Height, 255, 0, 0, 255) -- right line up line 3 
					DrawRect(x + box2and4Xoffset, y + box4Yoffset, box2and4Width, box2and4Height, 255, 0, 0, 255) -- top square base 4
				end
			end
		end
 
 
 
 
 
 
		if boxesp then
			local playercoords = GetEntityCoords(PlayerPedId())
			local currentPlayer = PlayerId()
			local players = GetPlayers()
			local playerPed = GetPlayerPed(player)
			local playerName = GetPlayerName(player)
			local rgb_r = box_esp_r
			local rgb_g = box_esp_g
			local rgb_b = box_esp_b
 
			for player = 0, 64 do
				if player ~= currentPlayer and NetworkIsPlayerActive(player) then
					local pPed = GetPlayerPed(player)
 
 
 
					--local pPed = PlayerPedId()
					local cx, cy, cz = table.unpack(GetEntityCoords(PlayerPedId()))
					local x, y, z = table.unpack(GetEntityCoords(pPed))
 
 
					-- box esp shit
 
					local mindistance = GetMinVisualDistance(GetPedBoneCoords(pPed, 0x0, 0.0, 0.0, 0.0))
					local rightknee = GetCoordInNoodleSoup(GetWorldPositionOfEntityBone(pPed, 0x3FCF, mindistance))
					local leftknee = GetCoordInNoodleSoup(GetWorldPositionOfEntityBone(pPed, 0xB3FE, mindistance))
					local neck = GetCoordInNoodleSoup(GetWorldPositionOfEntityBone(pPed, 0x9995, mindistance))
					local head = GetCoordInNoodleSoup(GetWorldPositionOfEntityBone(pPed, 0x796E, mindistance))
					local pelvis = GetCoordInNoodleSoup(GetWorldPositionOfEntityBone(pPed, 0x2E28, mindistance))
					local rightFoot = GetCoordInNoodleSoup(GetWorldPositionOfEntityBone(pPed, 0xCC4D, mindistance))
					local leftFoot = GetCoordInNoodleSoup(GetWorldPositionOfEntityBone(pPed, 0x3779, mindistance))
					local rightUpperArm = GetCoordInNoodleSoup(GetWorldPositionOfEntityBone(pPed, 0x9D4D, mindistance))
					local leftUpperArm = GetCoordInNoodleSoup(GetWorldPositionOfEntityBone(pPed, 0xB1C5, mindistance))
					local rightForeArm = GetCoordInNoodleSoup(GetWorldPositionOfEntityBone(pPed, 0x6E5C, mindistance))
					local leftForeArm = GetCoordInNoodleSoup(GetWorldPositionOfEntityBone(pPed, 0xEEEB, mindistance))
					local rightHand = GetCoordInNoodleSoup(GetWorldPositionOfEntityBone(pPed, 0xDEAD, mindistance))
					local leftHand = GetCoordInNoodleSoup(GetWorldPositionOfEntityBone(pPed, 0x49D9, mindistance))
 
					LineOneBegin = GetOffsetFromEntityInWorldCoords(pPed, -0.3, -0.3, -0.9)
					LineOneEnd = GetOffsetFromEntityInWorldCoords(pPed, 0.3, -0.3, -0.9)
					LineTwoBegin = GetOffsetFromEntityInWorldCoords(pPed, 0.3, -0.3, -0.9)
					LineTwoEnd = GetOffsetFromEntityInWorldCoords(pPed, 0.3, 0.3, -0.9)
					LineThreeBegin = GetOffsetFromEntityInWorldCoords(pPed, 0.3, 0.3, -0.9)
					LineThreeEnd = GetOffsetFromEntityInWorldCoords(pPed, -0.3, 0.3, -0.9)
					LineFourBegin = GetOffsetFromEntityInWorldCoords(pPed, -0.3, -0.3, -0.9)
 
					TLineOneBegin = GetOffsetFromEntityInWorldCoords(pPed, -0.3, -0.3, 0.8)
					TLineOneEnd = GetOffsetFromEntityInWorldCoords(pPed, 0.3, -0.3, 0.8)
					TLineTwoBegin = GetOffsetFromEntityInWorldCoords(pPed, 0.3, -0.3, 0.8)
					TLineTwoEnd = GetOffsetFromEntityInWorldCoords(pPed, 0.3, 0.3, 0.8)
					TLineThreeBegin = GetOffsetFromEntityInWorldCoords(pPed, 0.3, 0.3, 0.8)
					TLineThreeEnd = GetOffsetFromEntityInWorldCoords(pPed, -0.3, 0.3, 0.8)
					TLineFourBegin = GetOffsetFromEntityInWorldCoords(pPed, -0.3, -0.3, 0.8)
 
					ConnectorOneBegin = GetOffsetFromEntityInWorldCoords(pPed, -0.3, 0.3, 0.8)
					ConnectorOneEnd = GetOffsetFromEntityInWorldCoords(pPed, -0.3, 0.3, -0.9)
					ConnectorTwoBegin = GetOffsetFromEntityInWorldCoords(pPed, 0.3, 0.3, 0.8)
					ConnectorTwoEnd = GetOffsetFromEntityInWorldCoords(pPed, 0.3, 0.3, -0.9)
					ConnectorThreeBegin = GetOffsetFromEntityInWorldCoords(pPed, -0.3, -0.3, 0.8)
					ConnectorThreeEnd = GetOffsetFromEntityInWorldCoords(pPed, -0.3, -0.3, -0.9)
					ConnectorFourBegin = GetOffsetFromEntityInWorldCoords(pPed, 0.3, -0.3, 0.8)
					ConnectorFourEnd = GetOffsetFromEntityInWorldCoords(pPed, 0.3, -0.3, -0.9)
 
 
 
					Citizen.InvokeNative(`DRAW_LINE` & 0xFFFFFFFF, ConnectorOneBegin.x, ConnectorOneBegin.y, ConnectorOneBegin.z, ConnectorOneEnd.x, ConnectorOneEnd.y, ConnectorOneEnd.z, rgb_r, rgb_g, rgb_b, 255)
					Citizen.InvokeNative(`DRAW_LINE` & 0xFFFFFFFF, ConnectorOneBegin.x, ConnectorOneBegin.y, ConnectorOneBegin.z, ConnectorOneEnd.x, ConnectorOneEnd.y, ConnectorOneEnd.z, rgb_r, rgb_g, rgb_b, 255)
					Citizen.InvokeNative(`DRAW_LINE` & 0xFFFFFFFF, ConnectorTwoBegin.x, ConnectorTwoBegin.y, ConnectorTwoBegin.z, ConnectorTwoEnd.x, ConnectorTwoEnd.y, ConnectorTwoEnd.z, rgb_r, rgb_g, rgb_b, 255)
					Citizen.InvokeNative(`DRAW_LINE` & 0xFFFFFFFF, ConnectorThreeBegin.x, ConnectorThreeBegin.y, ConnectorThreeBegin.z, ConnectorThreeEnd.x, ConnectorThreeEnd.y, ConnectorThreeEnd.z, rgb_r, rgb_g, rgb_b, 255)
					Citizen.InvokeNative(`DRAW_LINE` & 0xFFFFFFFF, ConnectorFourBegin.x, ConnectorFourBegin.y, ConnectorFourBegin.z, ConnectorFourEnd.x, ConnectorFourEnd.y, ConnectorFourEnd.z, rgb_r, rgb_g, rgb_b, 255)
					Citizen.InvokeNative(`DRAW_LINE` & 0xFFFFFFFF, LineOneBegin.x, LineOneBegin.y, LineOneBegin.z, LineOneEnd.x, LineOneEnd.y, LineOneEnd.z, rgb_r, rgb_g, rgb_b, 255)
					Citizen.InvokeNative(`DRAW_LINE` & 0xFFFFFFFF, LineTwoBegin.x, LineTwoBegin.y, LineTwoBegin.z, LineTwoEnd.x, LineTwoEnd.y, LineTwoEnd.z, rgb_r, rgb_g, rgb_b, 255)
					Citizen.InvokeNative(`DRAW_LINE` & 0xFFFFFFFF, LineThreeBegin.x, LineThreeBegin.y, LineThreeBegin.z, LineThreeEnd.x, LineThreeEnd.y, LineThreeEnd.z, rgb_r, rgb_g, rgb_b, 255)
					Citizen.InvokeNative(`DRAW_LINE` & 0xFFFFFFFF, LineThreeEnd.x, LineThreeEnd.y, LineThreeEnd.z, LineFourBegin.x, LineFourBegin.y, LineFourBegin.z, rgb_r, rgb_g, rgb_b, 255)
					Citizen.InvokeNative(`DRAW_LINE` & 0xFFFFFFFF, TLineOneBegin.x, TLineOneBegin.y, TLineOneBegin.z, TLineOneEnd.x, TLineOneEnd.y, TLineOneEnd.z, rgb_r, rgb_g, rgb_b, 255)
					Citizen.InvokeNative(`DRAW_LINE` & 0xFFFFFFFF, TLineTwoBegin.x, TLineTwoBegin.y, TLineTwoBegin.z, TLineTwoEnd.x, TLineTwoEnd.y, TLineTwoEnd.z, rgb_r, rgb_g, rgb_b, 255)
					Citizen.InvokeNative(`DRAW_LINE` & 0xFFFFFFFF, TLineThreeBegin.x, TLineThreeBegin.y, TLineThreeBegin.z, TLineThreeEnd.x, TLineThreeEnd.y, TLineThreeEnd.z, rgb_r, rgb_g, rgb_b, 255)
					Citizen.InvokeNative(`DRAW_LINE` & 0xFFFFFFFF, TLineThreeEnd.x, TLineThreeEnd.y, TLineThreeEnd.z, TLineFourBegin.x, TLineFourBegin.y, TLineFourBegin.z, rgb_r, rgb_g, rgb_b, 255)
				end
			end
		end
	end
end)
 
Phoenix.Configs = {}
Phoenix.Configs.Weapons = {
	["RevolverCattleman"] = 0x169F59F7,
	["MeleeKnife"] = 0xDB21AC8C,
	["ShotgunDoublebarrel"] = 0x6DFA071B,
	["MeleeLantern"] = 0xF62FB3A3,
	["RepeaterCarbine"] = 0xF5175BA1,
	["RevolverSchofieldBill"] = 0x6DFE44AB,
	["RifleBoltactionBill"] = 0xD853C801,
	["MeleeKnifeBill"] = 0xCE3C31A4,
	["ShotgunSawedoffCharles"] = 0xBE8D2666,
	["BowCharles"] = 0x791BBD2C,
	["MeleeKnifeCharles"] = 0xB4774D3D,
	["ThrownTomahawk"] = 0xA5E972D7,
	["RevolverSchofieldDutch"] = 0xFA4B2D47,
	["RevolverSchofieldDutchDualwield"] = 0xD44A5A04,
	["MeleeKnifeDutch"] = 0x2C8DBB17,
	["RevolverCattlemanHosea"] = 0xA6FE9435,
	["RevolverCattlemanHoseaDualwield"] = 0x1EAA7376,
	["ShotgunSemiautoHosea"] = 0xFD9B510B,
	["MeleeKnifeHosea"] = 0xCACE760E,
	["RevolverDoubleactionJavier"] = 0x514B39A1,
	["ThrownThrowingKnivesJavier"] = 0x39B815A2,
	["MeleeKnifeJavier"] = 0xFA66468E,
	["RevolverCattlemanJohn"] = 0xC9622757,
	["RepeaterWinchesterJohn"] = 0xBE76397C,
	["MeleeKnifeJohn"] = 0x1D7D0737,
	["RevolverCattlemanKieran"] = 0x8FAE73BB,
	["MeleeKnifeKieran"] = 0x2F3ECD37,
	["RevolverCattlemanLenny"] = 0xC9095426,
	["SniperrifleRollingblockLenny"] = 0x21556EC2,
	["MeleeKnifeLenny"] = 0x9DD839AE,
	["RevolverDoubleactionMicah"] = 0x2300C65,
	["RevolverDoubleactionMicahDualwield"] = 0xD427AD,
	["MeleeKnifeMicah"] = 0xE9245D38,
	["RevolverCattlemanSadie"] = 0x49F6BE32,
	["RevolverCattlemanSadieDualwield"] = 0x8384D5FE,
	["RepeaterCarbineSadie"] = 0x7BD9C820,
	["ThrownThrowingKnives"] = 0xD2718D48,
	["MeleeKnifeSadie"] = 0xAF5EEF08,
	["RevolverCattlemanSean"] = 0x3EECE288,
	["MeleeKnifeSean"] = 0x64514239,
	["RevolverSchofieldUncle"] = 0x99496406,
	["ShotgunDoublebarrelUncle"] = 0x8BA6AF0A,
	["MeleeKnifeUncle"] = 0x46E97B10,
	["RevolverDoubleaction"] = 0x797FBF5,
	["RifleBoltaction"] = 0x772C8DD6,
	["RevolverSchofield"] = 0x7BBD1FF6,
	["RifleSpringfield"] = 0x63F46DE6,
	["RepeaterWinchester"] = 0xA84762EC,
	["RifleVarmint"] = 0xDDF7BC1E,
	["PistolVolcanic"] = 0x20D13FF,
	["ShotgunSawedoff"] = 0x1765A8F8,
	["PistolSemiauto"] = 0x657065D6,
	["PistolMauser"] = 0x8580C63E,
	["RepeaterHenry"] = 0x95B24592,
	["ShotgunPump"] = 0x31B7B9FE,
	["Bow"] = 0x88A8505C,
	["ThrownMolotov"] = 0x7067E7A7,
	["MeleeHatchetHewing"] = 0x1C02870C,
	["MeleeMachete"] = 0x28950C71,
	["RevolverDoubleactionExotic"] = 0x23C706CD,
	["RevolverSchofieldGolden"] = 0xE195D259,
	["ThrownDynamite"] = 0xA64DAA5E,
	["MeleeDavyLantern"] = 0x4A59E501,
	["Lasso"] = 0x7A8A724A,
	["KitBinoculars"] = 0xF6687C5A,
	["KitCamera"] = 0xC3662B7D,
	["Fishingrod"] = 0xABA87754,
	["SniperrifleRollingblock"] = 0xE1D2B317,
	["ShotgunSemiauto"] = 0x6D9BB970,
	["ShotgunRepeating"] = 0x63CA782A,
	["SniperrifleCarcano"] = 0x53944780,
	["MeleeBrokenSword"] = 0xF79190B4,
	["MeleeKnifeBear"] = 0x2BC12CDA,
	["MeleeKnifeCivilWar"] = 0xDA54DD53,
	["MeleeKnifeJawbone"] = 0x1086D041,
	["MeleeKnifeMiner"] = 0xC45B2DE,
	["MeleeKnifeVampire"] = 0x14D3F94D,
	["MeleeTorch"] = 0x67DC3FDE,
	["MeleeLanternElectric"] = 0x3155643F,
	["MeleeHatchet"] = 0x9E12A01,
	["MeleeAncientHatchet"] = 0x21CCCA44,
	["MeleeCleaver"] = 0xEF32A25D,
	["MeleeHatchetDoubleBit"] = 0xBCC63763,
	["MeleeHatchetDoubleBitRusted"] = 0x8F0FDE0E,
	["MeleeHatchetHunter"] = 0x2A5CF9D6,
	["MeleeHatchetHunterRusted"] = 0xE470B7AD,
	["MeleeHatchetViking"] = 0x74DC40ED,
	["RevolverCattlemanMexican"] = 0x16D655F7,
	["RevolverCattlemanPig"] = 0xF5E4207F,
	["RevolverSchofieldCalloway"] = 0x247E783,
	["PistolMauserDrunk"] = 0x4AAE5FFA,
	["ShotgunDoublebarrelExotic"] = 0x2250E150,
	["SniperrifleRollingblockExotic"] = 0x4E328256,
	["ThrownTomahawkAncient"] = 0x7F23B6C7,
	["MeleeTorchCrowd"] = 0xCC4588BD,
}
Phoenix.Configs.AmmoTypes = {
	"AMMO_PISTOL",
	"AMMO_PISTOL_SPLIT_POINT",
	"AMMO_PISTOL_EXPRESS",
	"AMMO_PISTOL_EXPRESS_EXPLOSIVE",
	"AMMO_PISTOL_HIGH_VELOCITY",
	"AMMO_REVOLVER",
	"AMMO_REVOLVER_SPLIT_POINT",
	"AMMO_REVOLVER_EXPRESS",
	"AMMO_REVOLVER_EXPRESS_EXPLOSIVE",
	"AMMO_REVOLVER_HIGH_VELOCITY",
	"AMMO_RIFLE",
	"AMMO_RIFLE_SPLIT_POINT",
	"AMMO_RIFLE_EXPRESS",
	"AMMO_RIFLE_EXPRESS_EXPLOSIVE",
	"AMMO_RIFLE_HIGH_VELOCITY",
	"AMMO_22",
	"AMMO_REPEATER",
	"AMMO_REPEATER_SPLIT_POINT",
	"AMMO_REPEATER_EXPRESS",
	"AMMO_REPEATER_EXPRESS_EXPLOSIVE",
	"AMMO_REPEATER_HIGH_VELOCITY",
	"AMMO_SHOTGUN",
	"AMMO_SHOTGUN_BUCKSHOT_INCENDIARY",
	"AMMO_SHOTGUN_SLUG",
	"AMMO_SHOTGUN_SLUG_EXPLOSIVE",
	"AMMO_ARROW",
	"AMMO_TURRET",
	"ML_UNARMED",
	"AMMO_MOLOTOV",
	"AMMO_MOLOTOV_VOLATILE",
	"AMMO_DYNAMITE",
	"AMMO_DYNAMITE_VOLATILE",
	"AMMO_THROWING_KNIVES",
	"AMMO_THROWING_KNIVES_IMPROVED",
	"AMMO_THROWING_KNIVES_POISON",
	"AMMO_THROWING_KNIVES_JAVIER",
	"AMMO_THROWING_KNIVES_CONFUSE",
	"AMMO_THROWING_KNIVES_DISORIENT",
	"AMMO_THROWING_KNIVES_DRAIN",
	"AMMO_THROWING_KNIVES_TRAIL",
	"AMMO_THROWING_KNIVES_WOUND",
	"AMMO_TOMAHAWK",
	"AMMO_TOMAHAWK_ANCIENT",
	"AMMO_TOMAHAWK_HOMING",
	"AMMO_TOMAHAWK_IMPROVED",
	"AMMO_HATCHET",
	"AMMO_HATCHET_ANCIENT",
	"AMMO_HATCHET_CLEAVER",
	"AMMO_HATCHET_DOUBLE_BIT",
	"AMMO_HATCHET_DOUBLE_BIT_RUSTED",
	"AMMO_HATCHET_HEWING",
	"AMMO_HATCHET_HUNTER",
	"AMMO_HATCHET_HUNTER_RUSTED",
	"AMMO_HATCHET_VIKING",
	"AMMO_ARROW_FIRE",
	"AMMO_ARROW_DYNAMITE",
	"AMMO_ARROW_SMALL_GAME",
	"AMMO_ARROW_IMPROVED",
	"AMMO_ARROW_POISON",
	"AMMO_ARROW_CONFUSION",
	"AMMO_ARROW_DISORIENT",
	"AMMO_ARROW_DRAIN",
	"AMMO_ARROW_TRAIL",
	"AMMO_ARROW_WOUND",
}
Phoenix.Configs.Peds = {
	
	Animal = {
		"a_c_alligator_01",
		"a_c_alligator_02",
		"a_c_alligator_03",
		"a_c_armadillo_01",
		"a_c_badger_01",
		"a_c_bat_01",
		"a_c_bear_01",
		"a_c_bearblack_01",
		"a_c_beaver_01",
		"a_c_bighornram_01",
		"a_c_bluejay_01",
		"a_c_boar_01",
		"a_c_boarlegendary_01",
		"a_c_buck_01",
		"a_c_buffalo_01",
		"a_c_buffalo_tatanka_01",
		"a_c_bull_01",
		"a_c_californiacondor_01",
		"a_c_cardinal_01",
		"a_c_carolinaparakeet_01",
		"a_c_cat_01",
		"a_c_cedarwaxwing_01",
		"a_c_chicken_01",
		"a_c_chipmunk_01",
		"a_c_cormorant_01",
		"a_c_cougar_01",
		"a_c_cow",
		"a_c_coyote_01",
		"a_c_crab_01",
		"a_c_cranewhooping_01",
		"a_c_crawfish_01",
		"a_c_crow_01",
		"a_c_deer_01",
		"a_c_dogamericanfoxhound_01",
		"a_c_dogaustraliansheperd_01",
		"a_c_dogbluetickcoonhound_01",
		"a_c_dogcatahoulacur_01",
		"a_c_dogchesbayretriever_01",
		"a_c_dogcollie_01",
		"a_c_doghobo_01",
		"a_c_doghound_01",
		"a_c_doghusky_01",
		"a_c_doglab_01",
		"a_c_doglion_01",
		"a_c_dogpoodle_01",
		"a_c_dogrufus_01",
		"a_c_dogstreet_01",
		"a_c_donkey_01",
		"a_c_duck_01",
		"a_c_eagle_01",
		"a_c_egret_01",
		"a_c_elk_01",
		"a_c_fishbluegil_01_ms",
		"a_c_fishbluegil_01_sm",
		"a_c_fishbullheadcat_01_ms",
		"a_c_fishbullheadcat_01_sm",
		"a_c_fishchainpickerel_01_ms",
		"a_c_fishchainpickerel_01_sm",
		"a_c_fishchannelcatfish_01_lg",
		"a_c_fishchannelcatfish_01_xl",
		"a_c_fishlakesturgeon_01_lg",
		"a_c_fishlargemouthbass_01_lg",
		"a_c_fishlargemouthbass_01_ms",
		"a_c_fishlongnosegar_01_lg",
		"a_c_fishmuskie_01_lg",
		"a_c_fishnorthernpike_01_lg",
		"a_c_fishperch_01_ms",
		"a_c_fishperch_01_sm",
		"a_c_fishrainbowtrout_01_lg",
		"a_c_fishrainbowtrout_01_ms",
		"a_c_fishredfinpickerel_01_ms",
		"a_c_fishredfinpickerel_01_sm",
		"a_c_fishrockbass_01_ms",
		"a_c_fishrockbass_01_sm",
		"a_c_fishsalmonsockeye_01_lg",
		"a_c_fishsalmonsockeye_01_ml",
		"a_c_fishsalmonsockeye_01_ms",
		"a_c_fishsmallmouthbass_01_lg",
		"a_c_fishsmallmouthbass_01_ms",
		"a_c_fox_01",
		"a_c_frogbull_01",
		"a_c_gilamonster_01",
		"a_c_goat_01",
		"a_c_goosecanada_01",
		"a_c_hawk_01",
		"a_c_heron_01",
		"a_c_horse_americanpaint_greyovero",
		"a_c_horse_americanpaint_overo",
		"a_c_horse_americanpaint_splashedwhite",
		"a_c_horse_americanpaint_tobiano",
		"a_c_horse_americanstandardbred_black",
		"a_c_horse_americanstandardbred_buckskin",
		"a_c_horse_americanstandardbred_lightbuckskin",
		"a_c_horse_americanstandardbred_palominodapple",
		"a_c_horse_americanstandardbred_silvertailbuckskin",
		"a_c_horse_andalusian_darkbay",
		"a_c_horse_andalusian_perlino",
		"a_c_horse_andalusian_rosegray",
		"a_c_horse_appaloosa_blacksnowflake",
		"a_c_horse_appaloosa_blanket",
		"a_c_horse_appaloosa_brownleopard",
		"a_c_horse_appaloosa_fewspotted_pc",
		"a_c_horse_appaloosa_leopard",
		"a_c_horse_appaloosa_leopardblanket",
		"a_c_horse_arabian_black",
		"a_c_horse_arabian_grey",
		"a_c_horse_arabian_redchestnut",
		"a_c_horse_arabian_redchestnut_pc",
		"a_c_horse_arabian_rosegreybay",
		"a_c_horse_arabian_warpedbrindle_pc",
		"a_c_horse_arabian_white",
		"a_c_horse_ardennes_bayroan",
		"a_c_horse_ardennes_irongreyroan",
		"a_c_horse_ardennes_strawberryroan",
		"a_c_horse_belgian_blondchestnut",
		"a_c_horse_belgian_mealychestnut",
		"a_c_horse_breton_grullodun",
		"a_c_horse_breton_mealydapplebay",
		"a_c_horse_breton_redroan",
		"a_c_horse_breton_sealbrown",
		"a_c_horse_breton_sorrel",
		"a_c_horse_breton_steelgrey",
		"a_c_horse_buell_warvets",
		"a_c_horse_criollo_baybrindle",
		"a_c_horse_criollo_bayframeovero",
		"a_c_horse_criollo_blueroanovero",
		"a_c_horse_criollo_dun",
		"a_c_horse_criollo_marblesabino",
		"a_c_horse_criollo_sorrelovero",
		"a_c_horse_dutchwarmblood_chocolateroan",
		"a_c_horse_dutchwarmblood_sealbrown",
		"a_c_horse_dutchwarmblood_sootybuckskin",
		"a_c_horse_eagleflies",
		"a_c_horse_gang_bill",
		"a_c_horse_gang_charles",
		"a_c_horse_gang_charles_endlesssummer",
		"a_c_horse_gang_dutch",
		"a_c_horse_gang_hosea",
		"a_c_horse_gang_javier",
		"a_c_horse_gang_john",
		"a_c_horse_gang_karen",
		"a_c_horse_gang_kieran",
		"a_c_horse_gang_lenny",
		"a_c_horse_gang_micah",
		"a_c_horse_gang_sadie",
		"a_c_horse_gang_sadie_endlesssummer",
		"a_c_horse_gang_sean",
		"a_c_horse_gang_trelawney",
		"a_c_horse_gang_uncle",
		"a_c_horse_gang_uncle_endlesssummer",
		"a_c_horse_gypsycob_palominoblagdon",
		"a_c_horse_gypsycob_piebald",
		"a_c_horse_gypsycob_skewbald",
		"a_c_horse_gypsycob_splashedbay",
		"a_c_horse_gypsycob_splashedpiebald",
		"a_c_horse_gypsycob_whiteblagdon",
		"a_c_horse_hungarianhalfbred_darkdapplegrey",
		"a_c_horse_hungarianhalfbred_flaxenchestnut",
		"a_c_horse_hungarianhalfbred_liverchestnut",
		"a_c_horse_hungarianhalfbred_piebaldtobiano",
		"a_c_horse_john_endlesssummer",
		"a_c_horse_kentuckysaddle_black",
		"a_c_horse_kentuckysaddle_buttermilkbuckskin_pc",
		"a_c_horse_kentuckysaddle_chestnutpinto",
		"a_c_horse_kentuckysaddle_grey",
		"a_c_horse_kentuckysaddle_silverbay",
		"a_c_horse_kladruber_black",
		"a_c_horse_kladruber_cremello",
		"a_c_horse_kladruber_dapplerosegrey",
		"a_c_horse_kladruber_grey",
		"a_c_horse_kladruber_silver",
		"a_c_horse_kladruber_white",
		"a_c_horse_missourifoxtrotter_amberchampagne",
		"a_c_horse_missourifoxtrotter_blacktovero",
		"a_c_horse_missourifoxtrotter_blueroan",
		"a_c_horse_missourifoxtrotter_buckskinbrindle",
		"a_c_horse_missourifoxtrotter_dapplegrey",
		"a_c_horse_missourifoxtrotter_sablechampagne",
		"a_c_horse_missourifoxtrotter_silverdapplepinto",
		"a_c_horse_morgan_bay",
		"a_c_horse_morgan_bayroan",
		"a_c_horse_morgan_flaxenchestnut",
		"a_c_horse_morgan_liverchestnut_pc",
		"a_c_horse_morgan_palomino",
		"a_c_horse_mp_mangy_backup",
		"a_c_horse_murfreebrood_mange_01",
		"a_c_horse_murfreebrood_mange_02",
		"a_c_horse_murfreebrood_mange_03",
		"a_c_horse_mustang_blackovero",
		"a_c_horse_mustang_buckskin",
		"a_c_horse_mustang_chestnuttovero",
		"a_c_horse_mustang_goldendun",
		"a_c_horse_mustang_grullodun",
		"a_c_horse_mustang_reddunovero",
		"a_c_horse_mustang_tigerstripedbay",
		"a_c_horse_mustang_wildbay",
		"a_c_horse_nokota_blueroan",
		"a_c_horse_nokota_reversedappleroan",
		"a_c_horse_nokota_whiteroan",
		"a_c_horse_norfolkroadster_black",
		"a_c_horse_norfolkroadster_dappledbuckskin",
		"a_c_horse_norfolkroadster_piebaldroan",
		"a_c_horse_norfolkroadster_rosegrey",
		"a_c_horse_norfolkroadster_speckledgrey",
		"a_c_horse_norfolkroadster_spottedtricolor",
		"a_c_horse_shire_darkbay",
		"a_c_horse_shire_lightgrey",
		"a_c_horse_shire_ravenblack",
		"a_c_horse_suffolkpunch_redchestnut",
		"a_c_horse_suffolkpunch_sorrel",
		"a_c_horse_tennesseewalker_blackrabicano",
		"a_c_horse_tennesseewalker_chestnut",
		"a_c_horse_tennesseewalker_dapplebay",
		"a_c_horse_tennesseewalker_flaxenroan",
		"a_c_horse_tennesseewalker_goldpalomino_pc",
		"a_c_horse_tennesseewalker_mahoganybay",
		"a_c_horse_tennesseewalker_redroan",
		"a_c_horse_thoroughbred_blackchestnut",
		"a_c_horse_thoroughbred_bloodbay",
		"a_c_horse_thoroughbred_brindle",
		"a_c_horse_thoroughbred_dapplegrey",
		"a_c_horse_thoroughbred_reversedappleblack",
		"a_c_horse_turkoman_black",
		"a_c_horse_turkoman_chestnut",
		"a_c_horse_turkoman_darkbay",
		"a_c_horse_turkoman_gold",
		"a_c_horse_turkoman_grey",
		"a_c_horse_turkoman_perlino",
		"a_c_horse_turkoman_silver",
		"a_c_horse_winter02_01",
		"a_c_horsemule_01",
		"a_c_horsemulepainted_01",
		"a_c_iguana_01",
		"a_c_iguanadesert_01",
		"a_c_javelina_01",
		"a_c_lionmangy_01",
		"a_c_loon_01",
		"a_c_moose_01",
		"a_c_muskrat_01",
		"a_c_oriole_01",
		"a_c_owl_01",
		"a_c_ox_01",
		"a_c_panther_01",
		"a_c_parrot_01",
		"a_c_pelican_01",
		"a_c_pheasant_01",
		"a_c_pig_01",
		"a_c_pigeon",
		"a_c_possum_01",
		"a_c_prairiechicken_01",
		"a_c_pronghorn_01",
		"a_c_quail_01",
		"a_c_rabbit_01",
		"a_c_raccoon_01",
		"a_c_rat_01",
		"a_c_raven_01",
		"a_c_redfootedbooby_01",
		"a_c_robin_01",
		"a_c_rooster_01",
		"a_c_roseatespoonbill_01",
		"a_c_seagull_01",
		"a_c_sharkhammerhead_01",
		"a_c_sharktiger",
		"a_c_sheep_01",
		"a_c_skunk_01",
		"a_c_snake_01",
		"a_c_snake_pelt_01",
		"a_c_snakeblacktailrattle_01",
		"a_c_snakeblacktailrattle_pelt_01",
		"a_c_snakeferdelance_01",
		"a_c_snakeferdelance_pelt_01",
		"a_c_snakeredboa10ft_01",
		"a_c_snakeredboa_01",
		"a_c_snakeredboa_pelt_01",
		"a_c_snakewater_01",
		"a_c_snakewater_pelt_01",
		"a_c_songbird_01",
		"a_c_sparrow_01",
		"a_c_squirrel_01",
		"a_c_toad_01",
		"a_c_turkey_01",
		"a_c_turkey_02",
		"a_c_turkeywild_01",
		"a_c_turtlesea_01",
		"a_c_turtlesnapping_01",
		"a_c_vulture_01",
		"a_c_wolf",
		"a_c_wolf_medium",
		"a_c_wolf_small",
		"a_c_woodpecker_01",
		"a_c_woodpecker_02",
		"mp_a_c_alligator_01",
		"mp_a_c_bear_01",
		"mp_a_c_beaver_01",
		"mp_a_c_bighornram_01",
		"mp_a_c_boar_01",
		"mp_a_c_buck_01",
		"mp_a_c_buffalo_01",
		"mp_a_c_chicken_01",
		"mp_a_c_cougar_01",
		"mp_a_c_coyote_01",
		"mp_a_c_deer_01",
		"mp_a_c_dogamericanfoxhound_01",
		"mp_a_c_elk_01",
		"mp_a_c_fox_01",
		"mp_a_c_horsecorpse_01",
		"mp_a_c_moose_01",
		"mp_a_c_owl_01",
		"mp_a_c_panther_01",
		"mp_a_c_possum_01",
		"mp_a_c_pronghorn_01",
		"mp_a_c_rabbit_01",
		"mp_a_c_sheep_01",
		"mp_a_c_wolf_01",
		"mp_a_f_m_protect_endflow_blackwater_01",
		"mp_a_f_m_unicorpse_01",
		"mp_a_m_m_asbminers_01",
		"mp_a_m_m_asbminers_02",
		"mp_a_m_m_coachguards_01",
		"mp_a_m_m_fos_coachguards_01",
		"mp_a_m_m_jamesonguard_01",
		"mp_a_m_m_lom_asbminers_01",
		"mp_a_m_m_protect_endflow_blackwater_01",
		"mp_a_m_m_unicorpse_01",
	},
 
	NPC = {
		"mp_re_rally_males_01",
		"re_rally_males_01",
		"cs_mp_policechief_lambert",
		"cs_mp_senator_ricard",
		"mp_beau_bink_females_01",
		"mp_beau_bink_males_01",
		"mp_bink_ember_of_the_east_males_01",
		"mp_carmela_bink_victim_males_01",
		"mp_cd_revengemayor_01",
		"mp_cs_antonyforemen",
		"mp_fm_bountytarget_females_dlc008_01",
		"mp_fm_bountytarget_males_dlc008_01",
		"mp_fm_bounty_horde_law_01",
		"mp_fm_knownbounty_informants_females_01",
		"mp_g_f_m_cultguards_01",
		"mp_g_m_m_cultguards_01",
		"mp_g_m_m_fos_debtgangcapitali_01",
		"mp_g_m_m_fos_debtgang_01",
		"mp_g_m_m_fos_vigilantes_01",
		"mp_g_m_m_mercs_01",
		"mp_g_m_m_mountainmen_01",
		"mp_g_m_m_riflecronies_01",
		"mp_g_m_o_uniexconfeds_cap_01",
		"mp_guidomartelli",
		"mp_lbm_carmela_banditos_01",
		"mp_lm_stealhorse_buyers_01",
		"mp_s_m_m_fos_harborguards_01",
		"mp_u_f_m_bountytarget_012",
		"mp_u_f_m_cultpriest_01",
		"mp_u_f_m_legendarybounty_03",
		"mp_u_f_m_outlaw_societylady_01",
		"mp_u_f_m_protect_mercer_01",
		"mp_u_m_m_asbdeputy_01",
		"mp_u_m_m_bankprisoner_01",
		"mp_u_m_m_binkmercs_01",
		"mp_u_m_m_cultpriest_01",
		"mp_u_m_m_dockrecipients_01",
		"mp_u_m_m_dropoff_bronte_01",
		"mp_u_m_m_dropoff_josiah_01",
		"mp_u_m_m_fos_bagholders_01",
		"mp_u_m_m_fos_coachholdup_recipient_01",
		"mp_u_m_m_fos_cornwallguard_01",
		"mp_u_m_m_fos_cornwall_bandits_01",
		"mp_u_m_m_fos_dockrecipients_01",
		"mp_u_m_m_fos_dockworker_01",
		"mp_u_m_m_fos_dropoff_01",
		"mp_u_m_m_fos_harbormaster_01",
		"mp_u_m_m_fos_interrogator_01",
		"mp_u_m_m_fos_interrogator_02",
		"mp_u_m_m_fos_musician_01",
		"mp_u_m_m_fos_railway_baron_01",
		"mp_u_m_m_fos_railway_driver_01",
		"mp_u_m_m_fos_railway_foreman_01",
		"mp_u_m_m_fos_railway_hunter_01",
		"mp_u_m_m_fos_railway_recipient_01",
		"mp_u_m_m_fos_recovery_recipient_01",
		"mp_u_m_m_fos_roguethief_01",
		"mp_u_m_m_fos_saboteur_01",
		"mp_u_m_m_fos_sdsaloon_gambler_01",
		"mp_u_m_m_fos_sdsaloon_owner_01",
		"mp_u_m_m_fos_sdsaloon_recipient_01",
		"mp_u_m_m_fos_sdsaloon_recipient_02",
		"mp_u_m_m_fos_town_outlaw_01",
		"mp_u_m_m_fos_town_vigilante_01",
		"mp_u_m_m_harbormaster_01",
		"mp_u_m_m_hctel_arm_hostage_01",
		"mp_u_m_m_hctel_arm_hostage_02",
		"mp_u_m_m_hctel_arm_hostage_03",
		"mp_u_m_m_hctel_sd_gang_01",
		"mp_u_m_m_hctel_sd_target_01",
		"mp_u_m_m_hctel_sd_target_02",
		"mp_u_m_m_hctel_sd_target_03",
		"mp_u_m_m_interrogator_01",
		"mp_u_m_m_legendarybounty_08",
		"mp_u_m_m_legendarybounty_09",
		"mp_u_m_m_lom_asbmercs_01",
		"mp_u_m_m_lom_dockworker_01",
		"mp_u_m_m_lom_dropoff_bronte_01",
		"mp_u_m_m_lom_head_security_01",
		"mp_u_m_m_lom_rhd_dealers_01",
		"mp_u_m_m_lom_rhd_sheriff_01",
		"mp_u_m_m_lom_rhd_smithassistant_01",
		"mp_u_m_m_lom_saloon_drunk_01",
		"mp_u_m_m_lom_sd_dockworker_01",
		"mp_u_m_m_lom_train_barricade_01",
		"mp_u_m_m_lom_train_clerk_01",
		"mp_u_m_m_lom_train_conductor_01",
		"mp_u_m_m_lom_train_lawtarget_01",
		"mp_u_m_m_lom_train_prisoners_01",
		"mp_u_m_m_lom_train_wagondropoff_01",
		"mp_u_m_m_musician_01",
		"mp_u_m_m_outlaw_arrestedthief_01",
		"mp_u_m_m_outlaw_coachdriver_01",
		"mp_u_m_m_outlaw_covington_01",
		"mp_u_m_m_outlaw_mpvictim_01",
		"mp_u_m_m_outlaw_rhd_noble_01",
		"mp_u_m_m_protect_armadillo_01",
		"mp_u_m_m_protect_blackwater_01",
		"mp_u_m_m_protect_friendly_armadillo_01",
		"mp_u_m_m_protect_halloween_ned_01",
		"mp_u_m_m_protect_macfarlanes_contact_01",
		"mp_u_m_m_protect_mercer_contact_01",
		"mp_u_m_m_protect_strawberry",
		"mp_u_m_m_protect_strawberry_01",
		"mp_u_m_m_protect_valentine_01",
		"mp_u_m_o_lom_asbforeman_01",
		"u_m_m_bht_outlawmauled",
		"a_f_m_armcholeracorpse_01",
		"a_f_m_armtownfolk_01",
		"a_f_m_armtownfolk_02",
		"a_f_m_asbtownfolk_01",
		"a_f_m_bivfancytravellers_01",
		"a_f_m_blwtownfolk_01",
		"a_f_m_blwtownfolk_02",
		"a_f_m_blwupperclass_01",
		"a_f_m_btchillbilly_01",
		"a_f_m_btcobesewomen_01",
		"a_f_m_bynfancytravellers_01",
		"a_f_m_familytravelers_cool_01",
		"a_f_m_familytravelers_warm_01",
		"a_f_m_gamhighsociety_01",
		"a_f_m_grifancytravellers_01",
		"a_f_m_guatownfolk_01",
		"a_f_m_htlfancytravellers_01",
		"a_f_m_lagtownfolk_01",
		"a_f_m_lowersdtownfolk_01",
		"a_f_m_lowersdtownfolk_02",
		"a_f_m_lowersdtownfolk_03",
		"a_f_m_lowertrainpassengers_01",
		"a_f_m_middlesdtownfolk_01",
		"a_f_m_middlesdtownfolk_02",
		"a_f_m_middlesdtownfolk_03",
		"a_f_m_middletrainpassengers_01",
		"a_f_m_nbxslums_01",
		"a_f_m_nbxupperclass_01",
		"a_f_m_nbxwhore_01",
		"a_f_m_rhdprostitute_01",
		"a_f_m_rhdtownfolk_01",
		"a_f_m_rhdtownfolk_02",
		"a_f_m_rhdupperclass_01",
		"a_f_m_rkrfancytravellers_01",
		"a_f_m_roughtravellers_01",
		"a_f_m_sclfancytravellers_01",
		"a_f_m_sdchinatown_01",
		"a_f_m_sdfancywhore_01",
		"a_f_m_sdobesewomen_01",
		"a_f_m_sdserversformal_01",
		"a_f_m_sdslums_02",
		"a_f_m_skpprisononline_01",
		"a_f_m_strtownfolk_01",
		"a_f_m_tumtownfolk_01",
		"a_f_m_tumtownfolk_02",
		"a_f_m_unicorpse_01",
		"a_f_m_uppertrainpassengers_01",
		"a_f_m_valprostitute_01",
		"a_f_m_valtownfolk_01",
		"a_f_m_vhtprostitute_01",
		"a_f_m_vhttownfolk_01",
		"a_f_m_waptownfolk_01",
		"a_f_o_blwupperclass_01",
		"a_f_o_btchillbilly_01",
		"a_f_o_guatownfolk_01",
		"a_f_o_lagtownfolk_01",
		"a_f_o_sdchinatown_01",
		"a_f_o_sdupperclass_01",
		"a_f_o_waptownfolk_01",
		"a_m_m_armcholeracorpse_01",
		"a_m_m_armdeputyresident_01",
		"a_m_m_armtownfolk_01",
		"a_m_m_armtownfolk_02",
		"a_m_m_asbboatcrew_01",
		"a_m_m_asbdeputyresident_01",
		"a_m_m_asbminer_01",
		"a_m_m_asbminer_02",
		"a_m_m_asbminer_03",
		"a_m_m_asbminer_04",
		"a_m_m_asbtownfolk_01",
		"a_m_m_asbtownfolk_01_laborer",
		"a_m_m_bivfancydrivers_01",
		"a_m_m_bivfancytravellers_01",
		"a_m_m_bivroughtravellers_01",
		"a_m_m_bivworker_01",
		"a_m_m_blwforeman_01",
		"a_m_m_blwlaborer_01",
		"a_m_m_blwlaborer_02",
		"a_m_m_blwobesemen_01",
		"a_m_m_blwtownfolk_01",
		"a_m_m_blwupperclass_01",
		"a_m_m_btchillbilly_01",
		"a_m_m_btcobesemen_01",
		"a_m_m_bynfancydrivers_01",
		"a_m_m_bynfancytravellers_01",
		"a_m_m_bynroughtravellers_01",
		"a_m_m_bynsurvivalist_01",
		"a_m_m_cardgameplayers_01",
		"a_m_m_chelonian_01",
		"a_m_m_deliverytravelers_cool_01",
		"a_m_m_deliverytravelers_warm_01",
		"a_m_m_dominoesplayers_01",
		"a_m_m_emrfarmhand_01",
		"a_m_m_familytravelers_cool_01",
		"a_m_m_familytravelers_warm_01",
		"a_m_m_farmtravelers_cool_01",
		"a_m_m_farmtravelers_warm_01",
		"a_m_m_fivefingerfilletplayers_01",
		"a_m_m_foreman",
		"a_m_m_gamhighsociety_01",
		"a_m_m_grifancydrivers_01",
		"a_m_m_grifancytravellers_01",
		"a_m_m_griroughtravellers_01",
		"a_m_m_grisurvivalist_01",
		"a_m_m_guatownfolk_01",
		"a_m_m_htlfancydrivers_01",
		"a_m_m_htlfancytravellers_01",
		"a_m_m_htlroughtravellers_01",
		"a_m_m_htlsurvivalist_01",
		"a_m_m_huntertravelers_cool_01",
		"a_m_m_huntertravelers_warm_01",
		"a_m_m_jamesonguard_01",
		"a_m_m_lagtownfolk_01",
		"a_m_m_lowersdtownfolk_01",
		"a_m_m_lowersdtownfolk_02",
		"a_m_m_lowertrainpassengers_01",
		"a_m_m_middlesdtownfolk_01",
		"a_m_m_middlesdtownfolk_02",
		"a_m_m_middlesdtownfolk_03",
		"a_m_m_middletrainpassengers_01",
		"a_m_m_moonshiners_01",
		"a_m_m_nbxdockworkers_01",
		"a_m_m_nbxlaborers_01",
		"a_m_m_nbxslums_01",
		"a_m_m_nbxupperclass_01",
		"a_m_m_nearoughtravellers_01",
		"a_m_m_rancher_01",
		"a_m_m_ranchertravelers_cool_01",
		"a_m_m_ranchertravelers_warm_01",
		"a_m_m_rhddeputyresident_01",
		"a_m_m_rhdforeman_01",
		"a_m_m_rhdobesemen_01",
		"a_m_m_rhdtownfolk_01",
		"a_m_m_rhdtownfolk_01_laborer",
		"a_m_m_rhdtownfolk_02",
		"a_m_m_rhdupperclass_01",
		"a_m_m_rkrfancydrivers_01",
		"a_m_m_rkrfancytravellers_01",
		"a_m_m_rkrroughtravellers_01",
		"a_m_m_rkrsurvivalist_01",
		"a_m_m_sclfancydrivers_01",
		"a_m_m_sclfancytravellers_01",
		"a_m_m_sclroughtravellers_01",
		"a_m_m_sdchinatown_01",
		"a_m_m_sddockforeman_01",
		"a_m_m_sddockworkers_02",
		"a_m_m_sdfancytravellers_01",
		"a_m_m_sdlaborers_02",
		"a_m_m_sdobesemen_01",
		"a_m_m_sdroughtravellers_01",
		"a_m_m_sdserversformal_01",
		"a_m_m_sdslums_02",
		"a_m_m_skpprisoner_01",
		"a_m_m_skpprisonline_01",
		"a_m_m_smhthug_01",
		"a_m_m_strdeputyresident_01",
		"a_m_m_strfancytourist_01",
		"a_m_m_strlaborer_01",
		"a_m_m_strtownfolk_01",
		"a_m_m_tumtownfolk_01",
		"a_m_m_tumtownfolk_02",
		"a_m_m_uniboatcrew_01",
		"a_m_m_unicoachguards_01",
		"a_m_m_unicorpse_01",
		"a_m_m_unigunslinger_01",
		"a_m_m_uppertrainpassengers_01",
		"a_m_m_valcriminals_01",
		"a_m_m_valdeputyresident_01",
		"a_m_m_valfarmer_01",
		"a_m_m_vallaborer_01",
		"a_m_m_valtownfolk_01",
		"a_m_m_valtownfolk_02",
		"a_m_m_vhtboatcrew_01",
		"a_m_m_vhtthug_01",
		"a_m_m_vhttownfolk_01",
		"a_m_m_wapwarriors_01",
		"a_m_o_blwupperclass_01",
		"a_m_o_btchillbilly_01",
		"a_m_o_guatownfolk_01",
		"a_m_o_lagtownfolk_01",
		"a_m_o_sdchinatown_01",
		"a_m_o_sdupperclass_01",
		"a_m_o_waptownfolk_01",
		"a_m_y_asbminer_01",
		"a_m_y_asbminer_02",
		"a_m_y_asbminer_03",
		"a_m_y_asbminer_04",
		"a_m_y_nbxstreetkids_01",
		"a_m_y_nbxstreetkids_slums_01",
		"a_m_y_sdstreetkids_slums_02",
		"a_m_y_unicorpse_01",
		"am_valentinedoctors_females_01",
		"amsp_robsdgunsmith_males_01",
		"casp_coachrobbery_lenny_males_01",
		"casp_coachrobbery_micah_males_01",
		"casp_hunting02_males_01",
		"charro_saddle_01",
		"cr_strawberry_males_01",
		"cs_abe",
		"cs_aberdeenpigfarmer",
		"cs_aberdeensister",
		"cs_abigailroberts",
		"cs_acrobat",
		"cs_adamgray",
		"cs_agnesdowd",
		"cs_albertcakeesquire",
		"cs_albertmason",
		"cs_andershelgerson",
		"cs_angel",
		"cs_angryhusband",
		"cs_angusgeddes",
		"cs_ansel_atherton",
		"cs_antonyforemen",
		"cs_archerfordham",
		"cs_archibaldjameson",
		"cs_archiedown",
		"cs_artappraiser",
		"cs_asbdeputy_01",
		"cs_ashton",
		"cs_balloonoperator",
		"cs_bandbassist",
		"cs_banddrummer",
		"cs_bandpianist",
		"cs_bandsinger",
		"cs_baptiste",
		"cs_bartholomewbraithwaite",
		"cs_bathingladies_01",
		"cs_beatenupcaptain",
		"cs_beaugray",
		"cs_billwilliamson",
		"cs_bivcoachdriver",
		"cs_blwphotographer",
		"cs_blwwitness",
		"cs_braithwaitebutler",
		"cs_braithwaitemaid",
		"cs_braithwaiteservant",
		"cs_brendacrawley",
		"cs_bronte",
		"cs_brontesbutler",
		"cs_brotherdorkins",
		"cs_brynntildon",
		"cs_bubba",
		"cs_cabaretmc",
		"cs_cajun",
		"cs_cancan_01",
		"cs_cancan_02",
		"cs_cancan_03",
		"cs_cancan_04",
		"cs_cancanman_01",
		"cs_captainmonroe",
		"cs_cassidy",
		"cs_catherinebraithwaite",
		"cs_cattlerustler",
		"cs_cavehermit",
		"cs_chainprisoner_01",
		"cs_chainprisoner_02",
		"cs_charlessmith",
		"cs_chelonianmaster",
		"cs_cigcardguy",
		"cs_clay",
		"cs_cleet",
		"cs_clive",
		"cs_colfavours",
		"cs_colmodriscoll",
		"cs_cooper",
		"cs_cornwalltrainconductor",
		"cs_crackpotinventor",
		"cs_crackpotrobot",
		"cs_creepyoldlady",
		"cs_creolecaptain",
		"cs_creoledoctor",
		"cs_creoleguy",
		"cs_dalemaroney",
		"cs_daveycallender",
		"cs_davidgeddes",
		"cs_desmond",
		"cs_didsbury",
		"cs_dinoboneslady",
		"cs_disguisedduster_01",
		"cs_disguisedduster_02",
		"cs_disguisedduster_03",
		"cs_doroetheawicklow",
		"cs_drhiggins",
		"cs_drmalcolmmacintosh",
		"cs_duncangeddes",
		"cs_dusterinformant_01",
		"cs_dutch",
		"cs_eagleflies",
		"cs_edgarross",
		"cs_edith_john",
		"cs_edithdown",
		"cs_edmundlowry",
		"cs_escapeartist",
		"cs_escapeartistassistant",
		"cs_evelynmiller",
		"cs_exconfedinformant",
		"cs_exconfedsleader_01",
		"cs_exoticcollector",
		"cs_famousgunslinger_01",
		"cs_famousgunslinger_02",
		"cs_famousgunslinger_03",
		"cs_famousgunslinger_04",
		"cs_famousgunslinger_05",
		"cs_famousgunslinger_06",
		"cs_featherstonchambers",
		"cs_featsofstrength",
		"cs_fightref",
		"cs_fire_breather",
		"cs_fishcollector",
		"cs_forgivenhusband_01",
		"cs_forgivenwife_01",
		"cs_formyartbigwoman",
		"cs_francis_sinclair",
		"cs_frenchartist",
		"cs_frenchman_01",
		"cs_fussar",
		"cs_garethbraithwaite",
		"cs_gavin",
		"cs_genstoryfemale",
		"cs_genstorymale",
		"cs_geraldbraithwaite",
		"cs_germandaughter",
		"cs_germanfather",
		"cs_germanmother",
		"cs_germanson",
		"cs_gilbertknightly",
		"cs_gloria",
		"cs_grizzledjon",
		"cs_guidomartelli",
		"cs_hamish",
		"cs_hectorfellowes",
		"cs_henrilemiux",
		"cs_herbalist",
		"cs_hercule",
		"cs_hestonjameson",
		"cs_hobartcrawley",
		"cs_hoseamatthews",
		"cs_iangray",
		"cs_jackmarston",
		"cs_jackmarston_teen",
		"cs_jamie",
		"cs_janson",
		"cs_javierescuella",
		"cs_jeb",
		"cs_jimcalloway",
		"cs_jockgray",
		"cs_joe",
		"cs_joebutler",
		"cs_johnmarston",
		"cs_johnthebaptisingmadman",
		"cs_johnweathers",
		"cs_josiahtrelawny",
		"cs_jules",
		"cs_karen",
		"cs_karensjohn_01",
		"cs_kieran",
		"cs_laramie",
		"cs_leighgray",
		"cs_lemiuxassistant",
		"cs_lenny",
		"cs_leon",
		"cs_leostrauss",
		"cs_levisimon",
		"cs_leviticuscornwall",
		"cs_lillianpowell",
		"cs_lillymillet",
		"cs_londonderryson",
		"cs_lucanapoli",
		"cs_magnifico",
		"cs_mamawatson",
		"cs_marshall_thurwell",
		"cs_marybeth",
		"cs_marylinton",
		"cs_meditatingmonk",
		"cs_meredith",
		"cs_meredithsmother",
		"cs_micahbell",
		"cs_micahsnemesis",
		"cs_mickey",
		"cs_miltonandrews",
		"cs_missmarjorie",
		"cs_mixedracekid",
		"cs_moira",
		"cs_mollyoshea",
		"cs_mp_agent_hixon",
		"cs_mp_alfredo_montez",
		"cs_mp_allison",
		"cs_mp_amos_lansing",
		"cs_mp_bessie_adair",
		"cs_mp_bonnie",
		"cs_mp_bountyhunter",
		"cs_mp_camp_cook",
		"cs_mp_cliff",
		"cs_mp_cripps",
		"cs_mp_dannylee",
		"cs_mp_grace_lancing",
		"cs_mp_gus_macmillan",
		"cs_mp_hans",
		"cs_mp_harriet_davenport",
		"cs_mp_henchman",
		"cs_mp_horley",
		"cs_mp_jeremiah_shaw",
		"cs_mp_jessica",
		"cs_mp_jorge_montez",
		"cs_mp_langston",
		"cs_mp_lee",
		"cs_mp_lem",
		"cs_mp_mabel",
		"cs_mp_maggie",
		"cs_mp_marshall_davies",
		"cs_mp_moonshiner",
		"cs_mp_mradler",
		"cs_mp_oldman_jones",
		"cs_mp_revenge_marshall",
		"cs_mp_samson_finch",
		"cs_mp_seth",
		"cs_mp_shaky",
		"cs_mp_sherifffreeman",
		"cs_mp_teddybrown",
		"cs_mp_terrance",
		"cs_mp_the_boy",
		"cs_mp_travellingsaleswoman",
		"cs_mp_went",
		"cs_mradler",
		"cs_mrdevon",
		"cs_mrlinton",
		"cs_mrpearson",
		"cs_mrs_calhoun",
		"cs_mrs_sinclair",
		"cs_mrsadler",
		"cs_mrsfellows",
		"cs_mrsgeddes",
		"cs_mrslondonderry",
		"cs_mrsweathers",
		"cs_mrwayne",
		"cs_mud2bigguy",
		"cs_mysteriousstranger",
		"cs_nbxdrunk",
		"cs_nbxexecuted",
		"cs_nbxpolicechiefformal",
		"cs_nbxreceptionist_01",
		"cs_nial_whelan",
		"cs_nicholastimmins",
		"cs_nils",
		"cs_norrisforsythe",
		"cs_obediahhinton",
		"cs_oddfellowspinhead",
		"cs_odprostitute",
		"cs_operasinger",
		"cs_paytah",
		"cs_penelopebraithwaite",
		"cs_pinkertongoon",
		"cs_poisonwellshaman",
		"cs_poorjoe",
		"cs_priest_wedding",
		"cs_princessisabeau",
		"cs_professorbell",
		"cs_rainsfall",
		"cs_ramon_cortez",
		"cs_reverendfortheringham",
		"cs_revswanson",
		"cs_rhodeputy_01",
		"cs_rhodeputy_02",
		"cs_rhodesassistant",
		"cs_rhodeskidnapvictim",
		"cs_rhodessaloonbouncer",
		"cs_ringmaster",
		"cs_rockyseven_widow",
		"cs_samaritan",
		"cs_scottgray",
		"cs_sd_streetkid_01",
		"cs_sd_streetkid_01a",
		"cs_sd_streetkid_01b",
		"cs_sd_streetkid_02",
		"cs_sddoctor_01",
		"cs_sdpriest",
		"cs_sdsaloondrunk_01",
		"cs_sdstreetkidthief",
		"cs_sean",
		"cs_sherifffreeman",
		"cs_sheriffowens",
		"cs_sistercalderon",
		"cs_slavecatcher",
		"cs_soothsayer",
		"cs_strawberryoutlaw_01",
		"cs_strawberryoutlaw_02",
		"cs_strdeputy_01",
		"cs_strdeputy_02",
		"cs_strsheriff_01",
		"cs_sunworshipper",
		"cs_susangrimshaw",
		"cs_swampfreak",
		"cs_swampweirdosonny",
		"cs_sworddancer",
		"cs_tavishgray",
		"cs_taxidermist",
		"cs_theodorelevin",
		"cs_thomasdown",
		"cs_tigerhandler",
		"cs_tilly",
		"cs_timothydonahue",
		"cs_tinyhermit",
		"cs_tomdickens",
		"cs_towncrier",
		"cs_treasurehunter",
		"cs_twinbrother_01",
		"cs_twinbrother_02",
		"cs_twingroupie_01",
		"cs_twingroupie_02",
		"cs_uncle",
		"cs_unidusterjail_01",
		"cs_valauctionboss_01",
		"cs_valdeputy_01",
		"cs_valprayingman",
		"cs_valprostitute_01",
		"cs_valprostitute_02",
		"cs_valsheriff",
		"cs_vampire",
		"cs_vht_bathgirl",
		"cs_wapitiboy",
		"cs_warvet",
		"cs_watson_01",
		"cs_watson_02",
		"cs_watson_03",
		"cs_welshfighter",
		"cs_wintonholmes",
		"cs_wrobel",
		"female_skeleton",
		"g_f_m_uniduster_01",
		"g_m_m_bountyhunters_01",
		"g_m_m_uniafricanamericangang_01",
		"g_m_m_unibanditos_01",
		"g_m_m_unibraithwaites_01",
		"g_m_m_unibrontegoons_01",
		"g_m_m_unicornwallgoons_01",
		"g_m_m_unicriminals_01",
		"g_m_m_unicriminals_02",
		"g_m_m_uniduster_01",
		"g_m_m_uniduster_02",
		"g_m_m_uniduster_03",
		"g_m_m_uniduster_04",
		"g_m_m_uniduster_05",
		"g_m_m_unigrays_01",
		"g_m_m_unigrays_02",
		"g_m_m_uniinbred_01",
		"g_m_m_unilangstonboys_01",
		"g_m_m_unimicahgoons_01",
		"g_m_m_unimountainmen_01",
		"g_m_m_uniranchers_01",
		"g_m_m_uniswamp_01",
		"g_m_o_uniexconfeds_01",
		"g_m_y_uniexconfeds_01",
		"g_m_y_uniexconfeds_02",
		"gc_lemoynecaptive_males_01",
		"gc_skinnertorture_males_01",
		"ge_delloboparty_females_01",
		"loansharking_asbminer_males_01",
		"loansharking_horsechase1_males_01",
		"loansharking_undertaker_females_01",
		"loansharking_undertaker_males_01",
		"male_skeleton",
		"mbh_rhodesrancher_females_01",
		"mbh_rhodesrancher_teens_01",
		"mbh_skinnersearch_males_01",
		"mcclellan_saddle_01",
		"mes_abigail2_males_01",
		"mes_finale2_females_01",
		"mes_finale2_males_01",
		"mes_finale3_males_01",
		"mes_marston1_males_01",
		"mes_marston2_males_01",
		"mes_marston5_2_males_01",
		"mes_marston6_females_01",
		"mes_marston6_males_01",
		"mes_marston6_teens_01",
		"mes_sadie4_males_01",
		"mes_sadie5_males_01",
		"motherhubbard_saddle_01",
		"mp_s_m_m_revenueagents_cap_01",
		"mp_u_m_m_fos_railway_guards_01",
		"mp_u_m_m_rhd_bountytarget_01",
		"mp_u_m_m_rhd_bountytarget_02",
		"mp_u_m_m_rhd_bountytarget_03",
		"mp_u_m_m_rhd_bountytarget_03b",
		"mp_a_f_m_cardgameplayers_01",
		"mp_a_f_m_saloonband_females_01",
		"mp_a_f_m_saloonpatrons_01",
		"mp_a_f_m_saloonpatrons_02",
		"mp_a_f_m_saloonpatrons_03",
		"mp_a_f_m_saloonpatrons_04",
		"mp_a_f_m_saloonpatrons_05",
		"mp_a_m_m_laboruprisers_01",
		"mp_a_m_m_moonshinemakers_01",
		"mp_a_m_m_saloonband_males_01",
		"mp_a_m_m_saloonpatrons_01",
		"mp_a_m_m_saloonpatrons_02",
		"mp_a_m_m_saloonpatrons_03",
		"mp_a_m_m_saloonpatrons_04",
		"mp_a_m_m_saloonpatrons_05",
		"mp_asn_benedictpoint_females_01",
		"mp_asn_benedictpoint_males_01",
		"mp_asn_blackwater_males_01",
		"mp_asn_braithwaitemanor_males_01",
		"mp_asn_braithwaitemanor_males_02",
		"mp_asn_braithwaitemanor_males_03",
		"mp_asn_civilwarfort_males_01",
		"mp_asn_gaptoothbreach_males_01",
		"mp_asn_pikesbasin_males_01",
		"mp_asn_sdpolicestation_males_01",
		"mp_asn_sdwedding_females_01",
		"mp_asn_sdwedding_males_01",
		"mp_asn_shadybelle_females_01",
		"mp_asn_stillwater_males_01",
		"mp_asntrk_elysianpool_males_01",
		"mp_asntrk_grizzlieswest_males_01",
		"mp_asntrk_hagenorchard_males_01",
		"mp_asntrk_isabella_males_01",
		"mp_asntrk_talltrees_males_01",
		"mp_campdef_bluewater_females_01",
		"mp_campdef_bluewater_males_01",
		"mp_campdef_chollasprings_females_01",
		"mp_campdef_chollasprings_males_01",
		"mp_campdef_eastnewhanover_females_01",
		"mp_campdef_eastnewhanover_males_01",
		"mp_campdef_gaptoothbreach_females_01",
		"mp_campdef_gaptoothbreach_males_01",
		"mp_campdef_gaptoothridge_females_01",
		"mp_campdef_gaptoothridge_males_01",
		"mp_campdef_greatplains_males_01",
		"mp_campdef_grizzlies_males_01",
		"mp_campdef_heartlands1_males_01",
		"mp_campdef_heartlands2_females_01",
		"mp_campdef_heartlands2_males_01",
		"mp_campdef_hennigans_females_01",
		"mp_campdef_hennigans_males_01",
		"mp_campdef_littlecreek_females_01",
		"mp_campdef_littlecreek_males_01",
		"mp_campdef_radleyspasture_females_01",
		"mp_campdef_radleyspasture_males_01",
		"mp_campdef_riobravo_females_01",
		"mp_campdef_riobravo_males_01",
		"mp_campdef_roanoke_females_01",
		"mp_campdef_roanoke_males_01",
		"mp_campdef_talltrees_females_01",
		"mp_campdef_talltrees_males_01",
		"mp_campdef_tworocks_females_01",
		"mp_chu_kid_armadillo_males_01",
		"mp_chu_kid_diabloridge_males_01",
		"mp_chu_kid_emrstation_males_01",
		"mp_chu_kid_greatplains2_males_01",
		"mp_chu_kid_greatplains_males_01",
		"mp_chu_kid_heartlands_males_01",
		"mp_chu_kid_lagras_males_01",
		"mp_chu_kid_lemoyne_females_01",
		"mp_chu_kid_lemoyne_males_01",
		"mp_chu_kid_recipient_males_01",
		"mp_chu_kid_rhodes_males_01",
		"mp_chu_kid_saintdenis_females_01",
		"mp_chu_kid_saintdenis_males_01",
		"mp_chu_kid_scarlettmeadows_males_01",
		"mp_chu_kid_tumbleweed_males_01",
		"mp_chu_kid_valentine_males_01",
		"mp_chu_rob_ambarino_males_01",
		"mp_chu_rob_annesburg_males_01",
		"mp_chu_rob_benedictpoint_females_01",
		"mp_chu_rob_benedictpoint_males_01",
		"mp_chu_rob_blackwater_males_01",
		"mp_chu_rob_caligahall_males_01",
		"mp_chu_rob_coronado_males_01",
		"mp_chu_rob_cumberland_males_01",
		"mp_chu_rob_fortmercer_females_01",
		"mp_chu_rob_fortmercer_males_01",
		"mp_chu_rob_greenhollow_males_01",
		"mp_chu_rob_macfarlanes_females_01",
		"mp_chu_rob_macfarlanes_males_01",
		"mp_chu_rob_macleans_males_01",
		"mp_chu_rob_millesani_males_01",
		"mp_chu_rob_montanariver_males_01",
		"mp_chu_rob_paintedsky_males_01",
		"mp_chu_rob_rathskeller_males_01",
		"mp_chu_rob_recipient_males_01",
		"mp_chu_rob_rhodes_males_01",
		"mp_chu_rob_strawberry_males_01",
		"mp_clay",
		"mp_convoy_recipient_females_01",
		"mp_convoy_recipient_males_01",
		"mp_de_u_f_m_bigvalley_01",
		"mp_de_u_f_m_bluewatermarsh_01",
		"mp_de_u_f_m_braithwaite_01",
		"mp_de_u_f_m_doverhill_01",
		"mp_de_u_f_m_greatplains_01",
		"mp_de_u_f_m_hangingrock_01",
		"mp_de_u_f_m_heartlands_01",
		"mp_de_u_f_m_hennigansstead_01",
		"mp_de_u_f_m_silentstead_01",
		"mp_de_u_m_m_aurorabasin_01",
		"mp_de_u_m_m_barrowlagoon_01",
		"mp_de_u_m_m_bigvalleygraves_01",
		"mp_de_u_m_m_centralunionrr_01",
		"mp_de_u_m_m_pleasance_01",
		"mp_de_u_m_m_rileyscharge_01",
		"mp_de_u_m_m_vanhorn_01",
		"mp_de_u_m_m_westernhomestead_01",
		"mp_dr_u_f_m_bayougatorfood_01",
		"mp_dr_u_f_m_bigvalleycave_01",
		"mp_dr_u_f_m_bigvalleycliff_01",
		"mp_dr_u_f_m_bluewaterkidnap_01",
		"mp_dr_u_f_m_colterbandits_01",
		"mp_dr_u_f_m_colterbandits_02",
		"mp_dr_u_f_m_missingfisherman_01",
		"mp_dr_u_f_m_missingfisherman_02",
		"mp_dr_u_f_m_mistakenbounties_01",
		"mp_dr_u_f_m_plaguetown_01",
		"mp_dr_u_f_m_quakerscove_01",
		"mp_dr_u_f_m_quakerscove_02",
		"mp_dr_u_f_m_sdgraveyard_01",
		"mp_dr_u_m_m_bigvalleycave_01",
		"mp_dr_u_m_m_bigvalleycliff_01",
		"mp_dr_u_m_m_bluewaterkidnap_01",
		"mp_dr_u_m_m_canoeescape_01",
		"mp_dr_u_m_m_hwyrobbery_01",
		"mp_dr_u_m_m_mistakenbounties_01",
		"mp_dr_u_m_m_pikesbasin_01",
		"mp_dr_u_m_m_pikesbasin_02",
		"mp_dr_u_m_m_plaguetown_01",
		"mp_dr_u_m_m_roanokestandoff_01",
		"mp_dr_u_m_m_sdgraveyard_01",
		"mp_dr_u_m_m_sdmugging_01",
		"mp_dr_u_m_m_sdmugging_02",
		"mp_female",
		"mp_fm_bounty_caged_males_01",
		"mp_fm_bounty_ct_corpses_01",
		"mp_fm_bounty_hideout_males_01",
		"mp_fm_bounty_horde_males_01",
		"mp_fm_bounty_infiltration_males_01",
		"mp_fm_knownbounty_guards_01",
		"mp_fm_knownbounty_informants_males_01",
		"mp_fm_multitrack_victims_males_01",
		"mp_fm_stakeout_corpses_males_01",
		"mp_fm_stakeout_poker_males_01",
		"mp_fm_stakeout_target_males_01",
		"mp_fm_track_prospector_01",
		"mp_fm_track_sd_lawman_01",
		"mp_fm_track_targets_males_01",
		"mp_freeroam_tut_females_01",
		"mp_freeroam_tut_males_01",
		"mp_g_f_m_armyoffear_01",
		"mp_g_f_m_cultmembers_01",
		"mp_g_f_m_laperlegang_01",
		"mp_g_f_m_laperlevips_01",
		"mp_g_f_m_owlhootfamily_01",
		"mp_g_m_m_animalpoachers_01",
		"mp_g_m_m_armoredjuggernauts_01",
		"mp_g_m_m_armyoffear_01",
		"mp_g_m_m_bountyhunters_01",
		"mp_g_m_m_cultmembers_01",
		"mp_g_m_m_owlhootfamily_01",
		"mp_g_m_m_redbengang_01",
		"mp_g_m_m_uniafricanamericangang_01",
		"mp_g_m_m_unibanditos_01",
		"mp_g_m_m_unibraithwaites_01",
		"mp_g_m_m_unibrontegoons_01",
		"mp_g_m_m_unicornwallgoons_01",
		"mp_g_m_m_unicriminals_01",
		"mp_g_m_m_unicriminals_02",
		"mp_g_m_m_unicriminals_03",
		"mp_g_m_m_unicriminals_04",
		"mp_g_m_m_unicriminals_05",
		"mp_g_m_m_unicriminals_06",
		"mp_g_m_m_unicriminals_07",
		"mp_g_m_m_unicriminals_08",
		"mp_g_m_m_unicriminals_09",
		"mp_g_m_m_uniduster_01",
		"mp_g_m_m_uniduster_02",
		"mp_g_m_m_uniduster_03",
		"mp_g_m_m_unigrays_01",
		"mp_g_m_m_uniinbred_01",
		"mp_g_m_m_unilangstonboys_01",
		"mp_g_m_m_unimountainmen_01",
		"mp_g_m_m_uniranchers_01",
		"mp_g_m_m_uniswamp_01",
		"mp_g_m_o_uniexconfeds_01",
		"mp_g_m_y_uniexconfeds_01",
		"mp_gunvoutd2_males_01",
		"mp_gunvoutd3_bht_01",
		"mp_gunvoutd3_males_01",
		"mp_horse_owlhootvictim_01",
		"mp_intercept_recipient_females_01",
		"mp_intercept_recipient_males_01",
		"mp_intro_females_01",
		"mp_intro_males_01",
		"mp_jailbreak_males_01",
		"mp_jailbreak_recipient_males_01",
		"mp_lbt_m3_males_01",
		"mp_lbt_m6_females_01",
		"mp_lbt_m6_males_01",
		"mp_lbt_m7_males_01",
		"mp_male",
		"mp_oth_recipient_males_01",
		"mp_outlaw1_males_01",
		"mp_outlaw2_males_01",
		"mp_post_multipackage_females_01",
		"mp_post_multipackage_males_01",
		"mp_post_multirelay_females_01",
		"mp_post_multirelay_males_01",
		"mp_post_relay_females_01",
		"mp_post_relay_males_01",
		"mp_predator",
		"mp_prsn_asn_males_01",
		"mp_re_animalattack_females_01",
		"mp_re_animalattack_males_01",
		"mp_re_duel_females_01",
		"mp_re_duel_males_01",
		"mp_re_graverobber_females_01",
		"mp_re_graverobber_males_01",
		"mp_re_hobodog_females_01",
		"mp_re_hobodog_males_01",
		"mp_re_kidnapped_females_01",
		"mp_re_kidnapped_males_01",
		"mp_re_moonshinecamp_males_01",
		"mp_re_photography_females_01",
		"mp_re_photography_females_02",
		"mp_re_photography_males_01",
		"mp_re_rivalcollector_males_01",
		"mp_re_runawaywagon_females_01",
		"mp_re_runawaywagon_males_01",
		"mp_re_slumpedhunter_females_01",
		"mp_re_slumpedhunter_males_01",
		"mp_re_suspendedhunter_males_01",
		"mp_re_treasurehunter_females_01",
		"mp_re_treasurehunter_males_01",
		"mp_re_wildman_males_01",
		"mp_recover_recipient_females_01",
		"mp_recover_recipient_males_01",
		"mp_repo_recipient_females_01",
		"mp_repo_recipient_males_01",
		"mp_repoboat_recipient_females_01",
		"mp_repoboat_recipient_males_01",
		"mp_rescue_bottletree_females_01",
		"mp_rescue_bottletree_males_01",
		"mp_rescue_colter_males_01",
		"mp_rescue_cratersacrifice_males_01",
		"mp_rescue_heartlands_males_01",
		"mp_rescue_loftkidnap_males_01",
		"mp_rescue_lonniesshack_males_01",
		"mp_rescue_moonstone_males_01",
		"mp_rescue_mtnmanshack_males_01",
		"mp_rescue_recipient_females_01",
		"mp_rescue_recipient_males_01",
		"mp_rescue_rivalshack_males_01",
		"mp_rescue_scarlettmeadows_males_01",
		"mp_rescue_sddogfight_females_01",
		"mp_rescue_sddogfight_males_01",
		"mp_resupply_recipient_females_01",
		"mp_resupply_recipient_males_01",
		"mp_revenge1_males_01",
		"mp_s_m_m_cornwallguard_01",
		"mp_s_m_m_pinlaw_01",
		"mp_s_m_m_revenueagents_01",
		"mp_stealboat_recipient_males_01",
		"mp_stealhorse_recipient_males_01",
		"mp_stealwagon_recipient_males_01",
		"mp_tattoo_female",
		"mp_tattoo_male",
		"mp_u_f_m_bountytarget_001",
		"mp_u_f_m_bountytarget_002",
		"mp_u_f_m_bountytarget_003",
		"mp_u_f_m_bountytarget_004",
		"mp_u_f_m_bountytarget_005",
		"mp_u_f_m_bountytarget_006",
		"mp_u_f_m_bountytarget_007",
		"mp_u_f_m_bountytarget_008",
		"mp_u_f_m_bountytarget_009",
		"mp_u_f_m_bountytarget_010",
		"mp_u_f_m_bountytarget_011",
		"mp_u_f_m_bountytarget_013",
		"mp_u_f_m_bountytarget_014",
		"mp_u_f_m_buyer_improved_01",
		"mp_u_f_m_buyer_improved_02",
		"mp_u_f_m_buyer_regular_01",
		"mp_u_f_m_buyer_regular_02",
		"mp_u_f_m_buyer_special_01",
		"mp_u_f_m_buyer_special_02",
		"mp_u_f_m_gunslinger3_rifleman_02",
		"mp_u_f_m_gunslinger3_sharpshooter_01",
		"mp_u_f_m_laperlevipmasked_01",
		"mp_u_f_m_laperlevipmasked_02",
		"mp_u_f_m_laperlevipmasked_03",
		"mp_u_f_m_laperlevipmasked_04",
		"mp_u_f_m_laperlevipunmasked_01",
		"mp_u_f_m_laperlevipunmasked_02",
		"mp_u_f_m_laperlevipunmasked_03",
		"mp_u_f_m_laperlevipunmasked_04",
		"mp_u_f_m_lbt_owlhootvictim_01",
		"mp_u_f_m_legendarybounty_001",
		"mp_u_f_m_legendarybounty_002",
		"mp_u_f_m_nat_traveler_01",
		"mp_u_f_m_nat_worker_01",
		"mp_u_f_m_nat_worker_02",
		"mp_u_f_m_outlaw3_warner_01",
		"mp_u_f_m_outlaw3_warner_02",
		"mp_u_f_m_revenge2_passerby_01",
		"mp_u_f_m_saloonpianist_01",
		"mp_u_m_m_animalpoacher_01",
		"mp_u_m_m_animalpoacher_02",
		"mp_u_m_m_animalpoacher_03",
		"mp_u_m_m_animalpoacher_04",
		"mp_u_m_m_animalpoacher_05",
		"mp_u_m_m_animalpoacher_06",
		"mp_u_m_m_animalpoacher_07",
		"mp_u_m_m_animalpoacher_08",
		"mp_u_m_m_animalpoacher_09",
		"mp_u_m_m_armsheriff_01",
		"mp_u_m_m_bountyinjuredman_01",
		"mp_u_m_m_bountytarget_001",
		"mp_u_m_m_bountytarget_002",
		"mp_u_m_m_bountytarget_003",
		"mp_u_m_m_bountytarget_005",
		"mp_u_m_m_bountytarget_008",
		"mp_u_m_m_bountytarget_009",
		"mp_u_m_m_bountytarget_010",
		"mp_u_m_m_bountytarget_011",
		"mp_u_m_m_bountytarget_012",
		"mp_u_m_m_bountytarget_013",
		"mp_u_m_m_bountytarget_014",
		"mp_u_m_m_bountytarget_015",
		"mp_u_m_m_bountytarget_016",
		"mp_u_m_m_bountytarget_017",
		"mp_u_m_m_bountytarget_018",
		"mp_u_m_m_bountytarget_019",
		"mp_u_m_m_bountytarget_020",
		"mp_u_m_m_bountytarget_021",
		"mp_u_m_m_bountytarget_022",
		"mp_u_m_m_bountytarget_023",
		"mp_u_m_m_bountytarget_024",
		"mp_u_m_m_bountytarget_025",
		"mp_u_m_m_bountytarget_026",
		"mp_u_m_m_bountytarget_027",
		"mp_u_m_m_bountytarget_028",
		"mp_u_m_m_bountytarget_029",
		"mp_u_m_m_bountytarget_030",
		"mp_u_m_m_bountytarget_031",
		"mp_u_m_m_bountytarget_032",
		"mp_u_m_m_bountytarget_033",
		"mp_u_m_m_bountytarget_034",
		"mp_u_m_m_bountytarget_035",
		"mp_u_m_m_bountytarget_036",
		"mp_u_m_m_bountytarget_037",
		"mp_u_m_m_bountytarget_038",
		"mp_u_m_m_bountytarget_039",
		"mp_u_m_m_bountytarget_044",
		"mp_u_m_m_bountytarget_045",
		"mp_u_m_m_bountytarget_046",
		"mp_u_m_m_bountytarget_047",
		"mp_u_m_m_bountytarget_048",
		"mp_u_m_m_bountytarget_049",
		"mp_u_m_m_bountytarget_050",
		"mp_u_m_m_bountytarget_051",
		"mp_u_m_m_bountytarget_052",
		"mp_u_m_m_bountytarget_053",
		"mp_u_m_m_bountytarget_054",
		"mp_u_m_m_bountytarget_055",
		"mp_u_m_m_buyer_default_01",
		"mp_u_m_m_buyer_improved_01",
		"mp_u_m_m_buyer_improved_02",
		"mp_u_m_m_buyer_improved_03",
		"mp_u_m_m_buyer_improved_04",
		"mp_u_m_m_buyer_improved_05",
		"mp_u_m_m_buyer_improved_06",
		"mp_u_m_m_buyer_improved_07",
		"mp_u_m_m_buyer_improved_08",
		"mp_u_m_m_buyer_regular_01",
		"mp_u_m_m_buyer_regular_02",
		"mp_u_m_m_buyer_regular_03",
		"mp_u_m_m_buyer_regular_04",
		"mp_u_m_m_buyer_regular_05",
		"mp_u_m_m_buyer_regular_06",
		"mp_u_m_m_buyer_regular_07",
		"mp_u_m_m_buyer_regular_08",
		"mp_u_m_m_buyer_special_01",
		"mp_u_m_m_buyer_special_02",
		"mp_u_m_m_buyer_special_03",
		"mp_u_m_m_buyer_special_04",
		"mp_u_m_m_buyer_special_05",
		"mp_u_m_m_buyer_special_06",
		"mp_u_m_m_buyer_special_07",
		"mp_u_m_m_buyer_special_08",
		"mp_u_m_m_dyingpoacher_01",
		"mp_u_m_m_dyingpoacher_02",
		"mp_u_m_m_dyingpoacher_03",
		"mp_u_m_m_dyingpoacher_04",
		"mp_u_m_m_dyingpoacher_05",
		"mp_u_m_m_gunforhireclerk_01",
		"mp_u_m_m_gunslinger3_rifleman_01",
		"mp_u_m_m_gunslinger3_sharpshooter_02",
		"mp_u_m_m_gunslinger3_shotgunner_01",
		"mp_u_m_m_gunslinger3_shotgunner_02",
		"mp_u_m_m_gunslinger4_warner_01",
		"mp_u_m_m_lawcamp_lawman_01",
		"mp_u_m_m_lawcamp_lawman_02",
		"mp_u_m_m_lawcamp_leadofficer_01",
		"mp_u_m_m_lawcamp_prisoner_01",
		"mp_u_m_m_lbt_accomplice_01",
		"mp_u_m_m_lbt_barbsvictim_01",
		"mp_u_m_m_lbt_bribeinformant_01",
		"mp_u_m_m_lbt_coachdriver_01",
		"mp_u_m_m_lbt_hostagemarshal_01",
		"mp_u_m_m_lbt_owlhootvictim_01",
		"mp_u_m_m_lbt_owlhootvictim_02",
		"mp_u_m_m_lbt_philipsvictim_01",
		"mp_u_m_m_legendarybounty_001",
		"mp_u_m_m_legendarybounty_002",
		"mp_u_m_m_legendarybounty_003",
		"mp_u_m_m_legendarybounty_004",
		"mp_u_m_m_legendarybounty_005",
		"mp_u_m_m_legendarybounty_006",
		"mp_u_m_m_legendarybounty_007",
		"mp_u_m_m_nat_farmer_01",
		"mp_u_m_m_nat_farmer_02",
		"mp_u_m_m_nat_farmer_03",
		"mp_u_m_m_nat_farmer_04",
		"mp_u_m_m_nat_photographer_01",
		"mp_u_m_m_nat_photographer_02",
		"mp_u_m_m_nat_rancher_01",
		"mp_u_m_m_nat_rancher_02",
		"mp_u_m_m_nat_townfolk_01",
		"mp_u_m_m_outlaw3_prisoner_01",
		"mp_u_m_m_outlaw3_prisoner_02",
		"mp_u_m_m_outlaw3_warner_01",
		"mp_u_m_m_outlaw3_warner_02",
		"mp_u_m_m_prisonwagon_01",
		"mp_u_m_m_prisonwagon_02",
		"mp_u_m_m_prisonwagon_03",
		"mp_u_m_m_prisonwagon_04",
		"mp_u_m_m_prisonwagon_05",
		"mp_u_m_m_prisonwagon_06",
		"mp_u_m_m_revenge2_handshaker_01",
		"mp_u_m_m_revenge2_passerby_01",
		"mp_u_m_m_saloonbrawler_01",
		"mp_u_m_m_saloonbrawler_02",
		"mp_u_m_m_saloonbrawler_03",
		"mp_u_m_m_saloonbrawler_04",
		"mp_u_m_m_saloonbrawler_05",
		"mp_u_m_m_saloonbrawler_06",
		"mp_u_m_m_saloonbrawler_07",
		"mp_u_m_m_saloonbrawler_08",
		"mp_u_m_m_saloonbrawler_09",
		"mp_u_m_m_saloonbrawler_10",
		"mp_u_m_m_saloonbrawler_11",
		"mp_u_m_m_saloonbrawler_12",
		"mp_u_m_m_saloonbrawler_13",
		"mp_u_m_m_saloonbrawler_14",
		"mp_u_m_m_strwelcomecenter_02",
		"mp_u_m_m_trader_01",
		"mp_u_m_m_traderintroclerk_01",
		"mp_u_m_m_tvlfence_01",
		"mp_u_m_o_blwpolicechief_01",
		"mp_wgnbrkout_recipient_males_01",
		"mp_wgnthief_recipient_males_01",
		"msp_bountyhunter1_females_01",
		"msp_braithwaites1_males_01",
		"msp_feud1_males_01",
		"msp_fussar2_males_01",
		"msp_gang2_males_01",
		"msp_gang3_males_01",
		"msp_grays1_males_01",
		"msp_grays2_males_01",
		"msp_guarma2_males_01",
		"msp_industry1_females_01",
		"msp_industry1_males_01",
		"msp_industry3_females_01",
		"msp_industry3_males_01",
		"msp_mary1_females_01",
		"msp_mary1_males_01",
		"msp_mary3_males_01",
		"msp_mob0_males_01",
		"msp_mob1_females_01",
		"msp_mob1_males_01",
		"msp_mob1_teens_01",
		"msp_mob3_females_01",
		"msp_mob3_males_01",
		"msp_mudtown3_males_01",
		"msp_mudtown3b_females_01",
		"msp_mudtown3b_males_01",
		"msp_mudtown5_males_01",
		"msp_native1_males_01",
		"msp_reverend1_males_01",
		"msp_saintdenis1_females_01",
		"msp_saintdenis1_males_01",
		"msp_saloon1_females_01",
		"msp_saloon1_males_01",
		"msp_smuggler2_males_01",
		"msp_trainrobbery2_males_01",
		"msp_trelawny1_males_01",
		"msp_utopia1_males_01",
		"msp_winter4_males_01",
		"p_c_horse_01",
		"player_three",
		"player_zero",
		"rces_abigail3_females_01",
		"rces_abigail3_males_01",
		"rces_beechers1_males_01",
		"rces_evelynmiller_males_01",
		"rcsp_beauandpenelope1_females_01",
		"rcsp_beauandpenelope_males_01",
		"rcsp_calderon_males_01",
		"rcsp_calderonstage2_males_01",
		"rcsp_calderonstage2_teens_01",
		"rcsp_calloway_males_01",
		"rcsp_coachrobbery_males_01",
		"rcsp_crackpot_females_01",
		"rcsp_crackpot_males_01",
		"rcsp_creole_males_01",
		"rcsp_dutch1_males_01",
		"rcsp_dutch3_males_01",
		"rcsp_edithdownes2_males_01",
		"rcsp_formyart_females_01",
		"rcsp_formyart_males_01",
		"rcsp_gunslingerduel4_males_01",
		"rcsp_herekittykitty_males_01",
		"rcsp_hunting1_males_01",
		"rcsp_mrmayor_males_01",
		"rcsp_native1s2_males_01",
		"rcsp_native_americanfathers_males_01",
		"rcsp_oddfellows_males_01",
		"rcsp_odriscolls2_females_01",
		"rcsp_poisonedwell_females_01",
		"rcsp_poisonedwell_males_01",
		"rcsp_poisonedwell_teens_01",
		"rcsp_ridethelightning_females_01",
		"rcsp_ridethelightning_males_01",
		"rcsp_sadie1_males_01",
		"rcsp_slavecatcher_males_01",
		"re_animalattack_females_01",
		"re_animalattack_males_01",
		"re_animalmauling_males_01",
		"re_approach_males_01",
		"re_beartrap_males_01",
		"re_boatattack_males_01",
		"re_burningbodies_males_01",
		"re_checkpoint_males_01",
		"re_coachrobbery_females_01",
		"re_coachrobbery_males_01",
		"re_consequence_males_01",
		"re_corpsecart_females_01",
		"re_corpsecart_males_01",
		"re_crashedwagon_males_01",
		"re_darkalleyambush_males_01",
		"re_darkalleybum_males_01",
		"re_darkalleystabbing_males_01",
		"re_deadbodies_males_01",
		"re_deadjohn_females_01",
		"re_deadjohn_males_01",
		"re_disabledbeggar_males_01",
		"re_domesticdispute_females_01",
		"re_domesticdispute_males_01",
		"re_drownmurder_females_01",
		"re_drownmurder_males_01",
		"re_drunkcamp_males_01",
		"re_drunkdueler_males_01",
		"re_duelboaster_males_01",
		"re_duelwinner_females_01",
		"re_duelwinner_males_01",
		"re_escort_females_01",
		"re_executions_males_01",
		"re_fleeingfamily_females_01",
		"re_fleeingfamily_males_01",
		"re_footrobbery_males_01",
		"re_friendlyoutdoorsman_males_01",
		"re_frozentodeath_females_01",
		"re_frozentodeath_males_01",
		"re_fundraiser_females_01",
		"re_fussarchase_males_01",
		"re_goldpanner_males_01",
		"re_horserace_females_01",
		"re_horserace_males_01",
		"re_hostagerescue_females_01",
		"re_hostagerescue_males_01",
		"re_inbredkidnap_females_01",
		"re_inbredkidnap_males_01",
		"re_injuredrider_males_01",
		"re_kidnappedvictim_females_01",
		"re_laramiegangrustling_males_01",
		"re_loneprisoner_males_01",
		"re_lostdog_dogs_01",
		"re_lostdog_teens_01",
		"re_lostdrunk_females_01",
		"re_lostdrunk_males_01",
		"re_lostfriend_males_01",
		"re_lostman_males_01",
		"re_moonshinecamp_males_01",
		"re_murdercamp_males_01",
		"re_murdersuicide_females_01",
		"re_murdersuicide_males_01",
		"re_nakedswimmer_males_01",
		"re_ontherun_males_01",
		"re_outlawlooter_males_01",
		"re_parlorambush_males_01",
		"re_peepingtom_females_01",
		"re_peepingtom_males_01",
		"re_pickpocket_males_01",
		"re_pisspot_females_01",
		"re_pisspot_males_01",
		"re_playercampstrangers_females_01",
		"re_playercampstrangers_males_01",
		"re_poisoned_males_01",
		"re_policechase_males_01",
		"re_prisonwagon_females_01",
		"re_prisonwagon_males_01",
		"re_publichanging_females_01",
		"re_publichanging_males_01",
		"re_publichanging_teens_01",
		"re_rally_males_01",
		"re_rallydispute_males_01",
		"re_rallysetup_males_01",
		"re_ratinfestation_males_01",
		"re_rowdydrunks_males_01",
		"re_savageaftermath_females_01",
		"re_savageaftermath_males_01",
		"re_savagefight_females_01",
		"re_savagefight_males_01",
		"re_savagewagon_females_01",
		"re_savagewagon_males_01",
		"re_savagewarning_males_01",
		"re_sharpshooter_males_01",
		"re_showoff_males_01",
		"re_skippingstones_males_01",
		"re_skippingstones_teens_01",
		"re_slumambush_females_01",
		"re_snakebite_males_01",
		"re_stalkinghunter_males_01",
		"re_strandedrider_males_01",
		"re_street_fight_males_01",
		"re_taunting_01",
		"re_taunting_males_01",
		"re_torturingcaptive_males_01",
		"re_townburial_males_01",
		"re_townconfrontation_females_01",
		"re_townconfrontation_males_01",
		"re_townrobbery_males_01",
		"re_townwidow_females_01",
		"re_trainholdup_females_01",
		"re_trainholdup_males_01",
		"re_trappedwoman_females_01",
		"re_treasurehunter_males_01",
		"re_voice_females_01",
		"re_wagonthreat_females_01",
		"re_wagonthreat_males_01",
		"re_washedashore_males_01",
		"re_wealthycouple_females_01",
		"re_wealthycouple_males_01",
		"re_wildman_01",
		"s_f_m_bwmworker_01",
		"s_f_m_cghworker_01",
		"s_f_m_mapworker_01",
		"s_m_m_ambientblwpolice_01",
		"s_m_m_ambientlawrural_01",
		"s_m_m_ambientsdpolice_01",
		"s_m_m_army_01",
		"s_m_m_asbcowpoke_01",
		"s_m_m_asbdealer_01",
		"s_m_m_bankclerk_01",
		"s_m_m_barber_01",
		"s_m_m_blwcowpoke_01",
		"s_m_m_blwdealer_01",
		"s_m_m_bwmworker_01",
		"s_m_m_cghworker_01",
		"s_m_m_cktworker_01",
		"s_m_m_coachtaxidriver_01",
		"s_m_m_cornwallguard_01",
		"s_m_m_dispatchlawrural_01",
		"s_m_m_dispatchleaderpolice_01",
		"s_m_m_dispatchleaderrural_01",
		"s_m_m_dispatchpolice_01",
		"s_m_m_fussarhenchman_01",
		"s_m_m_genconductor_01",
		"s_m_m_hofguard_01",
		"s_m_m_liveryworker_01",
		"s_m_m_magiclantern_01",
		"s_m_m_mapworker_01",
		"s_m_m_marketvendor_01",
		"s_m_m_marshallsrural_01",
		"s_m_m_micguard_01",
		"s_m_m_nbxriverboatdealers_01",
		"s_m_m_nbxriverboatguards_01",
		"s_m_m_orpguard_01",
		"s_m_m_pinlaw_01",
		"s_m_m_racrailguards_01",
		"s_m_m_racrailworker_01",
		"s_m_m_rhdcowpoke_01",
		"s_m_m_rhddealer_01",
		"s_m_m_sdcowpoke_01",
		"s_m_m_sddealer_01",
		"s_m_m_sdticketseller_01",
		"s_m_m_skpguard_01",
		"s_m_m_stgsailor_01",
		"s_m_m_strcowpoke_01",
		"s_m_m_strdealer_01",
		"s_m_m_strlumberjack_01",
		"s_m_m_tailor_01",
		"s_m_m_trainstationworker_01",
		"s_m_m_tumdeputies_01",
		"s_m_m_unibutchers_01",
		"s_m_m_unitrainengineer_01",
		"s_m_m_unitrainguards_01",
		"s_m_m_valbankguards_01",
		"s_m_m_valcowpoke_01",
		"s_m_m_valdealer_01",
		"s_m_m_valdeputy_01",
		"s_m_m_vhtdealer_01",
		"s_m_o_cktworker_01",
		"s_m_y_army_01",
		"s_m_y_newspaperboy_01",
		"s_m_y_racrailworker_01",
		"shack_missinghusband_males_01",
		"shack_ontherun_males_01",
		"u_f_m_bht_wife",
		"u_f_m_circuswagon_01",
		"u_f_m_emrdaughter_01",
		"u_f_m_fussar1lady_01",
		"u_f_m_htlwife_01",
		"u_f_m_lagmother_01",
		"u_f_m_nbxresident_01",
		"u_f_m_rhdnudewoman_01",
		"u_f_m_rkshomesteadtenant_01",
		"u_f_m_story_blackbelle_01",
		"u_f_m_story_nightfolk_01",
		"u_f_m_tljbartender_01",
		"u_f_m_tumgeneralstoreowner_01",
		"u_f_m_valtownfolk_01",
		"u_f_m_valtownfolk_02",
		"u_f_m_vhtbartender_01",
		"u_f_o_hermit_woman_01",
		"u_f_o_wtctownfolk_01",
		"u_f_y_braithwaitessecret_01",
		"u_f_y_czphomesteaddaughter_01",
		"u_m_m_announcer_01",
		"u_m_m_apfdeadman_01",
		"u_m_m_armgeneralstoreowner_01",
		"u_m_m_armtrainstationworker_01",
		"u_m_m_armundertaker_01",
		"u_m_m_armytrn4_01",
		"u_m_m_asbgunsmith_01",
		"u_m_m_asbprisoner_01",
		"u_m_m_asbprisoner_02",
		"u_m_m_bht_banditomine",
		"u_m_m_bht_banditoshack",
		"u_m_m_bht_benedictallbright",
		"u_m_m_bht_blackwaterhunt",
		"u_m_m_bht_exconfedcampreturn",
		"u_m_m_bht_laramiesleeping",
		"u_m_m_bht_lover",
		"u_m_m_bht_mineforeman",
		"u_m_m_bht_nathankirk",
		"u_m_m_bht_odriscolldrunk",
		"u_m_m_bht_odriscollmauled",
		"u_m_m_bht_odriscollsleeping",
		"u_m_m_bht_oldman",
		"u_m_m_bht_saintdenissaloon",
		"u_m_m_bht_shackescape",
		"u_m_m_bht_skinnerbrother",
		"u_m_m_bht_skinnersearch",
		"u_m_m_bht_strawberryduel",
		"u_m_m_bivforeman_01",
		"u_m_m_blwtrainstationworker_01",
		"u_m_m_bulletcatchvolunteer_01",
		"u_m_m_bwmstablehand_01",
		"u_m_m_cabaretfirehat_01",
		"u_m_m_cajhomestead_01",
		"u_m_m_chelonianjumper_01",
		"u_m_m_chelonianjumper_02",
		"u_m_m_chelonianjumper_03",
		"u_m_m_chelonianjumper_04",
		"u_m_m_circuswagon_01",
		"u_m_m_cktmanager_01",
		"u_m_m_cornwalldriver_01",
		"u_m_m_crdhomesteadtenant_01",
		"u_m_m_crdhomesteadtenant_02",
		"u_m_m_crdwitness_01",
		"u_m_m_creolecaptain_01",
		"u_m_m_czphomesteadfather_01",
		"u_m_m_dorhomesteadhusband_01",
		"u_m_m_emrfarmhand_03",
		"u_m_m_emrfather_01",
		"u_m_m_executioner_01",
		"u_m_m_fatduster_01",
		"u_m_m_finale2_aa_upperclass_01",
		"u_m_m_galastringquartet_01",
		"u_m_m_galastringquartet_02",
		"u_m_m_galastringquartet_03",
		"u_m_m_galastringquartet_04",
		"u_m_m_gamdoorman_01",
		"u_m_m_hhrrancher_01",
		"u_m_m_htlforeman_01",
		"u_m_m_htlhusband_01",
		"u_m_m_htlrancherbounty_01",
		"u_m_m_islbum_01",
		"u_m_m_lnsoutlaw_01",
		"u_m_m_lnsoutlaw_02",
		"u_m_m_lnsoutlaw_03",
		"u_m_m_lnsoutlaw_04",
		"u_m_m_lnsworker_01",
		"u_m_m_lnsworker_02",
		"u_m_m_lnsworker_03",
		"u_m_m_lnsworker_04",
		"u_m_m_lrshomesteadtenant_01",
		"u_m_m_mfrrancher_01",
		"u_m_m_mud3pimp_01",
		"u_m_m_nbxbankerbounty_01",
		"u_m_m_nbxbartender_01",
		"u_m_m_nbxbartender_02",
		"u_m_m_nbxboatticketseller_01",
		"u_m_m_nbxbronteasc_01",
		"u_m_m_nbxbrontegoon_01",
		"u_m_m_nbxbrontesecform_01",
		"u_m_m_nbxgeneralstoreowner_01",
		"u_m_m_nbxgraverobber_01",
		"u_m_m_nbxgraverobber_02",
		"u_m_m_nbxgraverobber_03",
		"u_m_m_nbxgraverobber_04",
		"u_m_m_nbxgraverobber_05",
		"u_m_m_nbxgunsmith_01",
		"u_m_m_nbxliveryworker_01",
		"u_m_m_nbxmusician_01",
		"u_m_m_nbxpriest_01",
		"u_m_m_nbxresident_01",
		"u_m_m_nbxresident_02",
		"u_m_m_nbxresident_03",
		"u_m_m_nbxresident_04",
		"u_m_m_nbxriverboatpitboss_01",
		"u_m_m_nbxriverboattarget_01",
		"u_m_m_nbxshadydealer_01",
		"u_m_m_nbxskiffdriver_01",
		"u_m_m_oddfellowparticipant_01",
		"u_m_m_odriscollbrawler_01",
		"u_m_m_orpguard_01",
		"u_m_m_racforeman_01",
		"u_m_m_racquartermaster_01",
		"u_m_m_rhdbackupdeputy_01",
		"u_m_m_rhdbackupdeputy_02",
		"u_m_m_rhdbartender_01",
		"u_m_m_rhddoctor_01",
		"u_m_m_rhdfiddleplayer_01",
		"u_m_m_rhdgenstoreowner_01",
		"u_m_m_rhdgenstoreowner_02",
		"u_m_m_rhdgunsmith_01",
		"u_m_m_rhdpreacher_01",
		"u_m_m_rhdsheriff_01",
		"u_m_m_rhdtrainstationworker_01",
		"u_m_m_rhdundertaker_01",
		"u_m_m_riodonkeyrider_01",
		"u_m_m_rkfrancher_01",
		"u_m_m_rkrdonkeyrider_01",
		"u_m_m_rwfrancher_01",
		"u_m_m_sdbankguard_01",
		"u_m_m_sdcustomvendor_01",
		"u_m_m_sdexoticsshopkeeper_01",
		"u_m_m_sdphotographer_01",
		"u_m_m_sdpolicechief_01",
		"u_m_m_sdstrongwomanassistant_01",
		"u_m_m_sdtrapper_01",
		"u_m_m_sdwealthytraveller_01",
		"u_m_m_shackserialkiller_01",
		"u_m_m_shacktwin_01",
		"u_m_m_shacktwin_02",
		"u_m_m_skinnyoldguy_01",
		"u_m_m_story_armadillo_01",
		"u_m_m_story_cannibal_01",
		"u_m_m_story_chelonian_01",
		"u_m_m_story_copperhead_01",
		"u_m_m_story_creeper_01",
		"u_m_m_story_emeraldranch_01",
		"u_m_m_story_hunter_01",
		"u_m_m_story_manzanita_01",
		"u_m_m_story_murfee_01",
		"u_m_m_story_pigfarm_01",
		"u_m_m_story_princess_01",
		"u_m_m_story_redharlow_01",
		"u_m_m_story_rhodes_01",
		"u_m_m_story_sdstatue_01",
		"u_m_m_story_spectre_01",
		"u_m_m_story_treasure_01",
		"u_m_m_story_tumbleweed_01",
		"u_m_m_story_valentine_01",
		"u_m_m_strfreightstationowner_01",
		"u_m_m_strgenstoreowner_01",
		"u_m_m_strsherriff_01",
		"u_m_m_strwelcomecenter_01",
		"u_m_m_tumbartender_01",
		"u_m_m_tumbutcher_01",
		"u_m_m_tumgunsmith_01",
		"u_m_m_tumtrainstationworker_01",
		"u_m_m_unibountyhunter_01",
		"u_m_m_unibountyhunter_02",
		"u_m_m_unidusterhenchman_01",
		"u_m_m_unidusterhenchman_02",
		"u_m_m_unidusterhenchman_03",
		"u_m_m_unidusterleader_01",
		"u_m_m_uniexconfedsbounty_01",
		"u_m_m_unionleader_01",
		"u_m_m_unionleader_02",
		"u_m_m_unipeepingtom_01",
		"u_m_m_valauctionforman_01",
		"u_m_m_valauctionforman_02",
		"u_m_m_valbarber_01",
		"u_m_m_valbartender_01",
		"u_m_m_valbeartrap_01",
		"u_m_m_valbutcher_01",
		"u_m_m_valdoctor_01",
		"u_m_m_valgenstoreowner_01",
		"u_m_m_valgunsmith_01",
		"u_m_m_valhotelowner_01",
		"u_m_m_valpokerplayer_01",
		"u_m_m_valpokerplayer_02",
		"u_m_m_valpoopingman_01",
		"u_m_m_valsheriff_01",
		"u_m_m_valtheman_01",
		"u_m_m_valtownfolk_01",
		"u_m_m_valtownfolk_02",
		"u_m_m_vhtstationclerk_01",
		"u_m_m_walgeneralstoreowner_01",
		"u_m_m_wapofficial_01",
		"u_m_m_wtccowboy_04",
		"u_m_o_armbartender_01",
		"u_m_o_asbsheriff_01",
		"u_m_o_bht_docwormwood",
		"u_m_o_blwbartender_01",
		"u_m_o_blwgeneralstoreowner_01",
		"u_m_o_blwphotographer_01",
		"u_m_o_blwpolicechief_01",
		"u_m_o_cajhomestead_01",
		"u_m_o_cmrcivilwarcommando_01",
		"u_m_o_mapwiseoldman_01",
		"u_m_o_oldcajun_01",
		"u_m_o_pshrancher_01",
		"u_m_o_rigtrainstationworker_01",
		"u_m_o_valbartender_01",
		"u_m_o_vhtexoticshopkeeper_01",
		"u_m_y_cajhomestead_01",
		"u_m_y_czphomesteadson_01",
		"u_m_y_czphomesteadson_02",
		"u_m_y_czphomesteadson_03",
		"u_m_y_czphomesteadson_04",
		"u_m_y_czphomesteadson_05",
		"u_m_y_duellistbounty_01",
		"u_m_y_emrson_01",
		"u_m_y_htlworker_01",
		"u_m_y_htlworker_02",
		"u_m_y_shackstarvingkid_01",
		"western_saddle_01",
		"western_saddle_02",
		"western_saddle_03",
		"western_saddle_04",
	}
}
Phoenix.Configs.Horses = {
	"A_C_Donkey_01",
	"A_C_Horse_AmericanPaint_Greyovero",
	"A_C_Horse_AmericanPaint_Overo",
	"A_C_Horse_AmericanPaint_SplashedWhite",
	"A_C_Horse_AmericanPaint_Tobiano",
	"A_C_Horse_AmericanStandardbred_Black",
	"A_C_Horse_AmericanStandardbred_Buckskin",
	"A_C_Horse_AmericanStandardbred_PalominoDapple",
	"A_C_Horse_AmericanStandardbred_SilverTailBuckskin",
	"A_C_Horse_Andalusian_DarkBay",
	"A_C_Horse_Andalusian_Perlino",
	"A_C_Horse_Andalusian_RoseGray",
	"A_C_Horse_Appaloosa_BlackSnowflake",
	"A_C_Horse_Appaloosa_Blanket",
	"A_C_Horse_Appaloosa_BrownLeopard",
	"A_C_Horse_Appaloosa_FewSpotted_PC",
	"A_C_Horse_Appaloosa_Leopard",
	"A_C_Horse_Appaloosa_LeopardBlanket",
	"A_C_Horse_Arabian_Black",
	"A_C_Horse_Arabian_Grey",
	"A_C_Horse_Arabian_RedChestnut",
	"A_C_Horse_Arabian_RedChestnut_PC",
	"A_C_Horse_Arabian_RoseGreyBay",
	"A_C_Horse_Arabian_WarpedBrindle_PC",
	"A_C_Horse_Arabian_White",
	"A_C_Horse_Ardennes_BayRoan",
	"A_C_Horse_Ardennes_IronGreyRoan",
	"A_C_Horse_Ardennes_StrawberryRoan",
	"A_C_Horse_Belgian_BlondChestnut",
	"A_C_Horse_Belgian_MealyChestnut",
	"A_C_Horse_Buell_WarVets",
	"A_C_Horse_DutchWarmblood_ChocolateRoan",
	"A_C_Horse_DutchWarmblood_SealBrown",
	"A_C_Horse_DutchWarmblood_SootyBuckskin",
	"A_C_Horse_EagleFlies",
	"A_C_Horse_Gang_Bill",
	"A_C_Horse_Gang_Charles",
	"A_C_Horse_Gang_Charles_EndlessSummer",
	"A_C_Horse_Gang_Dutch",
	"A_C_Horse_Gang_Hosea",
	"A_C_Horse_Gang_Javier",
	"A_C_Horse_Gang_John",
	"A_C_Horse_Gang_Karen",
	"A_C_Horse_Gang_Kieran",
	"A_C_Horse_Gang_Lenny",
	"A_C_Horse_Gang_Micah",
	"A_C_Horse_Gang_Sadie",
	"A_C_Horse_Gang_Sadie_EndlessSummer",
	"A_C_Horse_Gang_Sean",
	"A_C_Horse_Gang_Trelawney",
	"A_C_Horse_Gang_Uncle",
	"A_C_Horse_Gang_Uncle_EndlessSummer",
	"A_C_Horse_HungarianHalfbred_DarkDappleGrey",
	"A_C_Horse_HungarianHalfbred_FlaxenChestnut",
	"A_C_Horse_HungarianHalfbred_LiverChestnut",
	"A_C_Horse_HungarianHalfbred_PiebaldTobiano",
	"A_C_Horse_John_EndlessSummer",
	"A_C_Horse_KentuckySaddle_Black",
	"A_C_Horse_KentuckySaddle_ButterMilkBuckskin_PC",
	"A_C_Horse_KentuckySaddle_ChestnutPinto",
	"A_C_Horse_KentuckySaddle_Grey",
	"A_C_Horse_KentuckySaddle_SilverBay",
	"A_C_Horse_MissouriFoxTrotter_AmberChampagne",
	"A_C_Horse_MissouriFoxTrotter_SableChampagne",
	"A_C_Horse_MissouriFoxTrotter_SilverDapplePinto",
	"A_C_Horse_Morgan_Bay",
	"A_C_Horse_Morgan_BayRoan",
	"A_C_Horse_Morgan_FlaxenChestnut",
	"A_C_Horse_Morgan_LiverChestnut_PC",
	"A_C_Horse_Morgan_Palomino",
	"A_C_Horse_MP_Mangy_Backup",
	"A_C_Horse_MurfreeBrood_Mange_01",
	"A_C_Horse_MurfreeBrood_Mange_02",
	"A_C_Horse_MurfreeBrood_Mange_03",
	"A_C_Horse_Mustang_GoldenDun",
	"A_C_Horse_Mustang_GrulloDun",
	"A_C_Horse_Mustang_TigerStripedBay",
	"A_C_Horse_Mustang_WildBay",
	"A_C_Horse_Nokota_BlueRoan",
	"A_C_Horse_Nokota_ReverseDappleRoan",
	"A_C_Horse_Nokota_WhiteRoan",
	"A_C_Horse_Shire_DarkBay",
	"A_C_Horse_Shire_LightGrey",
	"A_C_Horse_Shire_RavenBlack",
	"A_C_Horse_SuffolkPunch_RedChestnut",
	"A_C_Horse_SuffolkPunch_Sorrel",
	"A_C_Horse_TennesseeWalker_BlackRabicano",
	"A_C_Horse_TennesseeWalker_Chestnut",
	"A_C_Horse_TennesseeWalker_DappleBay",
	"A_C_Horse_TennesseeWalker_FlaxenRoan",
	"A_C_Horse_TennesseeWalker_GoldPalomino_PC",
	"A_C_Horse_TennesseeWalker_MahoganyBay",
	"A_C_Horse_TennesseeWalker_RedRoan",
	"A_C_Horse_Thoroughbred_BlackChestnut",
	"A_C_Horse_Thoroughbred_BloodBay",
	"A_C_Horse_Thoroughbred_Brindle",
	"A_C_Horse_Thoroughbred_DappleGrey",
	"A_C_Horse_Thoroughbred_ReverseDappleBlack",
	"A_C_Horse_Turkoman_DarkBay",
	"A_C_Horse_Turkoman_Gold",
	"A_C_Horse_Turkoman_Silver",
	"A_C_Horse_Winter02_01",
	"A_C_HorseMule_01",
	"A_C_HorseMulePainted_01",
}
 
local dumper = {
    client = {},
    cfg = {
        "client_script",
        "client_scripts",
        "shared_script",
        "shared_scripts",
        "ui_page",
        "ui_pages",
        "file",
        "files",
        "loadscreen",
        "map"
    }
}
 
 
-- local PlayerIDs
 
local enable_developer_tools = true
local camera = {
	handle = nil,
	active_mode = 1,
	sensitivity = 5.0,
 
	speed = 10,
	speed_intervals = 2,
	min_speed = 2,
	max_speed = 100,
	boost_factor = 10.0,
 
	keybinds = {
		toggle = 0x446258B6, -- 0x446258B6 = Page Up
		boost = `INPUT_SPRINT`, -- INPUT_SPRINT, Left Shift
		decrease_speed = 0xDE794E3E, --Q
		increase_speed = 0xCEFD9220, -- E
		forward = `INPUT_MOVE_UP_ONLY`, -- W
		reverse = `INPUT_MOVE_DOWN_ONLY`, -- S
		left = `INPUT_MOVE_LEFT_ONLY`, -- A
		right = `INPUT_MOVE_RIGHT_ONLY`, -- D
		up = `INPUT_JUMP`, -- Space
		down = `INPUT_DUCK`, -- Ctrl
		switch_mode = `INPUT_AIM`,
		mode_action = 0x07CE1E61
	},
 
	modes = {
		{
			label = "Freecam",
			left_click_action = function(coords)
				return
			end
		},
		{
			label = "Teleport Player",
			left_click_action = function(coords)
				print("HERE")
				SetEntityCoords(PlayerPedId(), coords)
			end
		},
		{
			label = "Explosion",
			left_click_action = function(coords)
				Phoenix.native(0xD84A917A64D4D016, PlayerPedId(), coords.x, coords.y, coords.z, 27, 1000.0, true, false, true)
				Phoenix.native(0xD84A917A64D4D016, PlayerPedId(), coords.x, coords.y, coords.z, 30, 1000.0, true, false, true)
				Phoenix.Print("Drone Strike", "Drone Strike", false)
			end
		},
		{
			label = "Bear",
			left_click_action = function(coords)
 
				local invisibleped = CreatePed(3170700927, coords.x, coords.y, coords.z, 0.0, true, false)
				SetEntityMaxHealth(invisibleped, 1250)
				SetEntityHealth(invisibleped, 1250)
				SetEntityAsMissionEntity(invisiblepeds, -1, 0)
				Citizen.InvokeNative(0x283978A15512B2FE, invisibleped, true)
				Phoenix.Print("Bear Pack", "Spawned Bear pack", false)
			end
		}
	}
 
}
 
-- To be re-enabled
camera.keybinds.enable_controls = { 
	`INPUT_FRONTEND_PAUSE_ALTERNATE`,
	`INPUT_MP_TEXT_CHAT_ALL`,
	camera.keybinds.decrease_speed,
	camera.keybinds.increase_speed
}
 
 
-- dumper features --
 
local dumper = {
    client = {},
    cfg = {
        "client_script",
        "client_scripts",
        "shared_script",
        "shared_scripts",
        "ui_page",
        "ui_pages",
        "file",
        "files",
        "loadscreen",
        "map"
    }
}
 
function dumper:getResources()
	local resources = {}
	for i = 1, GetNumResources() do
		resources[i] = GetResourceByFindIndex(i)
	end
 
	return resources
end
 
function dumper:getFiles(res, cfg)
    res = (res or GetCurrentResourceName())
    cfg = (cfg or self.cfg)
    self.client[res] = {}
    for i, metaKey in ipairs(cfg) do
        for idx = 0, GetNumResourceMetadata(res, metaKey) -1 do
            local file = (GetResourceMetadata(res, metaKey, idx) or "none")
            local code = (LoadResourceFile(res, file) or "")
            self.client[res][file] = code
        end
    end
 
    self.client[res]["manifest.lua"] = (LoadResourceFile(res, "__resource.lua") or LoadResourceFile(res, "fxmanifest.lua"))
end
 
--		              --
-- Movement Functions --
------------------------
 
local function get_relative_location(_location, _rotation, _distance)
	_location = _location or vector3(0,0,0)
	_rotation = _rotation or vector3(0,0,0)
	_distance = _distance or 10.0
 
	local tZ = math.rad(_rotation.z)
	local tX = math.rad(_rotation.x)
 
	local absX = math.abs(math.cos(tX))
 
	local rx = _location.x + (-math.sin(tZ) * absX) * _distance
	local ry = _location.y + (math.cos(tZ) * absX) * _distance
	local rz = _location.z + (math.sin(tX)) * _distance
 
	return vector3(rx,ry,rz)
end
 
local function get_camera_movement(location, rotation, frame_time)
	local multiplier = 1.0
 
	if IsDisabledControlPressed(0, camera.keybinds.boost) then
		multiplier = camergb_boost_factor
	end
 
	local speed = camera.speed * frame_time
 
	if IsDisabledControlPressed(0, camera.keybinds.right) then
		local camera_rotation = vector3(0,0,rotation.z)
		location = get_relative_location(location, camera_rotation + vector3(0,0,-90), speed)
	elseif IsDisabledControlPressed(0, camera.keybinds.left) then
		local camera_rotation = vector3(0,0,rotation.z)
		location = get_relative_location(location, camera_rotation + vector3(0,0,90), speed)
	end
 
	if IsDisabledControlPressed(0, camera.keybinds.forward) then
		location = get_relative_location(location, rotation, speed)
	elseif IsDisabledControlPressed(0, camera.keybinds.reverse) then
		location = get_relative_location(location, rotation, -speed)
	end
 
	if IsDisabledControlPressed(0, camera.keybinds.up) then
		location = location + vector3(0,0,speed)
	elseif IsDisabledControlPressed(0, camera.keybinds.down) then
		location = location + vector3(0,0,-speed)
	end
 
	return location
end
 
local function get_mouse_movement()
	local x = GetDisabledControlNormal(0, GetHashKey('INPUT_LOOK_UD'))
	local y = 0
	local z = GetDisabledControlNormal(0, GetHashKey('INPUT_LOOK_LR'))
	return vector3(-x, y, -z) * camera.sensitivity
end
 
local function render_collision(current_location, new_location)
	RequestCollisionAtCoord(new_location.x, new_location.y, new_location.z)
 
	SetFocusPosAndVel(new_location.x, new_location.y, new_location.z, 0.0, 0.0, 0.0)
 
	Citizen.InvokeNative(0x387AD749E3B69B70, new_location.x, new_location.y, new_location.z, new_location.x, new_location.y, new_location.z, 50.0, 0) -- LOAD_SCENE_START
	Citizen.InvokeNative(0x5A8B01199C3E79C3) -- LOAD_SCENE_STOP
end
 
--				  --
-- Invoke Wrapper --
--------------------
 
local function draw_marker(type, posX, posY, posZ, dirX, dirY, dirZ, rotX, rotY, rotZ, scaleX, scaleY, scaleZ, red, green, blue, alpha, bobUpAndDown, faceCamera, p19, rotate, textureDict, textureName, drawOnEnts)
	Citizen.InvokeNative(0x2A32FAA57B937173, type, posX, posY, posZ, dirX, dirY, dirZ, rotX, rotY, rotZ, scaleX, scaleY, scaleZ, red, green, blue, alpha, bobUpAndDown, faceCamera, p19, rotate, textureDict, textureName, drawOnEnts)
end
 
local function draw_raycast(distance, coords, rotation)
	local camera_coord = coords
 
	local adjusted_rotation = {x = (math.pi / 180) * rotation.x, y = (math.pi / 180) * rotation.y, z = (math.pi / 180) * rotation.z}
	local direction = { x = -math.sin(adjusted_rotation.z) * math.abs(math.cos(adjusted_rotation.x)), y = math.cos(adjusted_rotation.z) * math.abs(math.cos(adjusted_rotation.x)), z = math.sin(adjusted_rotation.x)}
 
	local destination = 
	{ 
		x = camera_coord.x + direction.x * distance, 
		y = camera_coord.y + direction.y * distance, 
		z = camera_coord.z + direction.z * distance 
	}
	local a, b, c, d, e = GetShapeTestResult(StartShapeTestRay(camera_coord.x, camera_coord.y, camera_coord.z, destination.x, destination.y, destination.z, -1, -1, 1))
 
	return b, c, e
end
 
local function draw_text(text, x, y, centred)
	SetTextScale(0.35, 0.35)
	SetTextColor(255, 255, 255, 255)
	SetTextCentre(centred)
	SetTextDropshadow(1, 0, 0, 0, 200)
	SetTextFontForCurrentCommand(0)
	DisplayText(CreateVarString(10, "LITERAL_STRING", text), x, y)
end
 
Phoenix.developer_tools = function(location, rotation)
	local hit, coords, entity = draw_raycast(1000.0, location, rotation)
 
	if camera.modes[camera.active_mode].label ~= "" then
		draw_marker(0x50638AB9, coords, 0, 0, 0, 0, 0, 0, 0.1, 0.1, 0.1, 255, 100, 100, 100, 0, 0, 2, 0, 0, 0, 0)
		draw_text(('Camera Mode\n%s (Speed: %.3f)\n PageUp To Exit Freecam'):format(camera.modes[camera.active_mode].label, camera.speed, coords.x, coords.y, coords.z, location, rotation), 0.5, 0.01, true)
	
	end
 
	if IsDisabledControlPressed(1, camera.keybinds.mode_action) and coords and camera.modes[camera.active_mode].left_click_action then -- Left click action
		camera.modes[camera.active_mode].left_click_action(coords)
	elseif IsDisabledControlJustReleased(0, camera.keybinds.switch_mode) then
		if camera.active_mode >= #camera.modes then
			camera.active_mode = 1
		else
			camera.active_mode = camera.active_mode + 1
		end
	end
end
 
--		              --
-- Endpoint Functions --
------------------------
 
Phoenix.stop_freecam = function()
	RenderScriptCams(false, true, 500, true, true)
	SetCamActive(camera.handle, false)
	DetachCam(camera.handle)
	DestroyCam(camera.handle, true)
	ClearFocus()
	camera.handle = nil
end
 
Phoenix.start_freecam = function()
	camera.handle = CreateCam("DEFAULT_SCRIPTED_CAMERA", true)
	SetCamRot(camera.handle, GetGameplayCamRot(2), 2)
	SetCamCoord(camera.handle, GetGameplayCamCoord())
	RenderScriptCams(true, true, 500, true, true)
 
	while camera.handle do
		Citizen.Wait(0)
 
		local current_location = GetCamCoord(camera.handle)
		local current_rotation = GetCamRot(camera.handle, 2)
 
		local new_rotation = current_rotation + get_mouse_movement()
		if current_rotation.x > 85 then
			current_rotation = vector3(85, current_rotation.y, current_rotation.z)
		elseif current_rotation.x < -85 then
			current_rotation = vector3(-85, current_rotation.y, current_rotation.z)
		end
 
		local new_location = get_camera_movement(current_location, new_rotation, GetFrameTime())
		SetCamCoord(camera.handle, new_location)
		SetCamRot(camera.handle, new_rotation, 2)
 
		render_collision(current_location, new_location)
		if enable_developer_tools then
			Phoenix.developer_tools(current_location, new_rotation)
		end
 
		if IsDisabledControlJustReleased(0, camera.keybinds.toggle) then
			Phoenix.stop_freecam()
		end
 
		DisableFirstPersonCamThisFrame()
		DisableAllControlActions(0)
 
		for k, v in ipairs(camera.keybinds.enable_controls) do
			EnableControlAction(0, v)
		end
	end
end
 
Phoenix.toggle_camera = function()
	if camera.handle then
		Phoenix.stop_freecam()
	else
		Phoenix.start_freecam()
	end
end
 
Phoenix.pedID = function()
	return Phoenix.native(0x096275889B8E0EE0)
end
 
Phoenix.createThread = function(cb)
	Citizen.CreateThread(cb)
end
 
Phoenix.module = function(moduleLoad)
	while not Phoenix do Wait(500) end; moduleLoad()
end
 
Phoenix.requestControl = function(entity)
	local type = GetEntityType(entity)
 
	if type < 1 or type > 3 then
		return
	end
 
	NetworkRequestControlOfEntity(entity)
end
 
Phoenix.Notifications.txt = function(text, x, y, fontscale, fontsize, r, g, b, alpha, textcentred, shadow)
	local str = CreateVarString(10, "LITERAL_STRING", text)
	SetTextScale(fontscale, fontsize)
	SetTextColor(r, g, b, alpha)
	SetTextCentre(textcentred)
	if (shadow) then SetTextDropshadow(1, 0, 0, 255) end
	SetTextFontForCurrentCommand(9)
	DisplayText(str, x, y)
end
 
Phoenix.Print = function(printTxt, notificationTxt, error)
	if printTxt then
		Citizen.Trace("\n[^1Phoenix Menu^7] " .. tostring(printTxt) .. (error and " ^1(ERROR)^7" or ""))
	end
 
	if notificationTxt then
		if Phoenix.Notifications.enabled then table.insert(Phoenix.Notifications.queue, { txt = notificationTxt, added = GetGameTimer() + (1000 * #Phoenix.Notifications.queue) }) end
	end
end
 
Phoenix.Notifications.startQueue = function()
	Phoenix.createThread(function()
		while (true) do
			Citizen.Wait(0)
 
			if #Phoenix.Notifications.queue > 0 then
				Phoenix.Notifications.txt("|| Phoenix Notification ||", 0.5, 0.87, 0.45, 0.45, 255, 40, 40, 255, true, true)
				Phoenix.Notifications.txt(Phoenix.Notifications.queue[1].txt, 0.5, 0.9, 0.4, 0.4, 255, 255, 255, 230, true, true)
 
				if (GetGameTimer() - Phoenix.Notifications.queue[1].added) > 1000 then
					-- Phoenix.Print("Removing notification from queue (" .. Phoenix.Notifications.queue[1].txt .. ")")
					table.remove(Phoenix.Notifications.queue, 1)
				end
			end
 
			if not Phoenix.Notifications.enabled then
				Phoenix.Print("Notifications Disabled", false)
				break
			end
		end
	end)
end
 
Phoenix.createThread(function()
	Phoenix.Notifications.startQueue()
end)
 
Phoenix.randomRGB = function(speed, alpha)
	local n = GetGameTimer() / 300
	local r, g, b = math.floor(math.sin(n * speed) * 127 + 128), math.floor(math.sin(n * speed + 2) * 127 + 128), math.floor(math.sin(n * speed + 4) * 127 + 128)
	return r, g, b, alpha == nil and 255 or alpha
end
 
local menus = { }
local keys = { up = 0x6319DB71, down = 0x05CA7C52, left = 0xA65EBAB4, right = 0xDEB34313, select = 0xC7B5340A, back = 0x156F7119 }
 
local optionCount = 0
 
local currentKey = nil
local currentMenu = nil
 
local titleHeight = 0.09
local titleYOffset = 0.010
local titleScale = 1.0
 
local descWidth = 0.10
local descHeight = 0.030
 
local menuWidth = 0.200
 
local buttonHeight = 0.038
local buttonFont = 9
local buttonScale = 0.365
 
local buttonTextXOffset = 0.003
local buttonTextYOffset = 0.005
 
 
local function debugPrint(text)
	if Phoenix.Menu.debug then
		Phoenix.Print(text, false, false)
	end
end
 
 
local function setMenuProperty(id, property, value)
	if id and menus[id] then
		menus[id][property] = value
		debugPrint(id..' menu property changed: { '..tostring(property)..', '..tostring(value)..' }')
	end
end
 
 
local function isMenuVisible(id)
	if id and menus[id] then
		return menus[id].visible
	else
		return false
	end
end
 
 
local function setMenuVisible(id, visible, holdCurrent)
	if id and menus[id] then
		setMenuProperty(id, 'visible', visible)
 
		if not holdCurrent and menus[id] then
			setMenuProperty(id, 'currentOption', 1)
		end
 
		if visible then
			if id ~= currentMenu and isMenuVisible(currentMenu) then
				setMenuVisible(currentMenu, false)
			end
 
			currentMenu = id
		end
	end
end
 
local function mysplit(inputstr, sep)
    if sep == nil then
        sep = "%s"
    end
    local t={}
    for str in string.gmatch(inputstr, "([^"..sep.."]+)") do
        table.insert(t, str)
    end
    return t
end
 
local function drawMultilineFormat(str)
    return str, #mysplit( str, "\n" )
end
 
 
local function drawText(text, x, y, font, color, scale, center, shadow, alignRight)
 
	local str = CreateVarString(10, "LITERAL_STRING", text)
 
	if color then
		SetTextColor(color.r, color.g, color.b, color.a)
	else
		SetTextColor(255, 255, 255, 255)
	end
 
	SetTextFontForCurrentCommand(font)
	SetTextScale(scale, scale)
 
	if shadow then
		SetTextDropshadow(1, 0, 0, 0, 255)
	end
 
	if center then
		SetTextCentre(center)
	elseif alignRight then
		
	end
 
	DisplayText(str, x, y)
 
end
 
local function drawTitle()
	local r,g,b = Phoenix.randomRGB(0.1, 255)
	if menus[currentMenu] then
		local x = menus[currentMenu].x + menus[currentMenu].width / 2
		local y = menus[currentMenu].y + titleHeight / 2
 
		DrawSprite("generic_textures", "list_item_h_line_narrow", x, y + 0.0799, menus[currentMenu].width+ 0.01, 0.003, 0.0, 255, 255, 255, 255, 0)
		drawText(menus[currentMenu].title, x - 0.003, y - titleHeight / 2 + titleYOffset + 0.045, menus[currentMenu].titleFont, { r = r, g = g, b = b, a = 255 } , 1.20, true, true, false)
	end
end
 
local function drawButton(text, subText, isInfo)
	local x = menus[currentMenu].x + menus[currentMenu].width / 2
	local multiplier = nil
 
	if menus[currentMenu].currentOption <= menus[currentMenu].maxOptionCount and optionCount <= menus[currentMenu].maxOptionCount then
		multiplier = optionCount
	elseif optionCount > menus[currentMenu].currentOption - menus[currentMenu].maxOptionCount and optionCount <= menus[currentMenu].currentOption then
		multiplier = optionCount - (menus[currentMenu].currentOption - menus[currentMenu].maxOptionCount)
	end
 
	if multiplier then
		local y = menus[currentMenu].y + titleHeight + buttonHeight + (buttonHeight * multiplier) - buttonHeight / 2
		local backgroundColor = nil
		local textColor = nil
		local subTextColor = nil
		local shadow = false
 
		if menus[currentMenu].currentOption == optionCount then
			backgroundColor = menus[currentMenu].menuFocusBackgroundColor
			textColor = menus[currentMenu].menuFocusTextColor
			subTextColor = menus[currentMenu].menuFocusTextColor
		else
			backgroundColor = menus[currentMenu].menuBackgroundColor
			textColor = menus[currentMenu].menuTextColor
			subTextColor = menus[currentMenu].menuSubTextColor
			shadow = true
 
		end
 
		if menus[currentMenu].currentOption == optionCount then
			if HasStreamedTextureDictLoaded("generic_textures") then
				SetScriptGfxDrawOrder(2)
				DrawSprite("generic_textures", "selection_box_bg_1d", x, y - 0.002, menus[currentMenu].width+ 0.01, buttonHeight, 0.0, 255, 255, 255, 180, 0)
			end
		else
			if HasStreamedTextureDictLoaded("generic_textures") then
				SetScriptGfxDrawOrder(1)
				DrawSprite("generic_textures", "selection_box_bg_1d", x, y - 0.002, menus[currentMenu].width+ 0.01, buttonHeight, 0.0, 0, 0, 0, 255, 0)
			end
		end
 
			local r,g,b = Phoenix.randomRGB(0.1, 255)
 
		drawText(text, menus[currentMenu].x + buttonTextXOffset - 0.002, y - (buttonHeight / 2) + buttonTextYOffset, buttonFont, isInfo and { r = r, g = g, b = b, a = 255 } or textColor, buttonScale, false, shadow)
 
		if subText then
			local blankspace = "                       "
			drawText((blankspace:sub(1, -string.len(subText))) .. subText, menus[currentMenu].x + menuWidth - 0.065, y - buttonHeight / 2 + buttonTextYOffset, buttonFont, subTextColor, buttonScale, false, shadow, true)
		end
	end
end
 
local function drawBottom()
	local x = menus[currentMenu].x + menus[currentMenu].width / 2
	local multiplier = nil
 
    if menus[currentMenu].totalOptions >= menus[currentMenu].maxOptionCount then
		multiplier = menus[currentMenu].maxOptionCount + 1
	elseif menus[currentMenu].totalOptions <= menus[currentMenu].maxOptionCount then
		multiplier = menus[currentMenu].totalOptions + 1
	end
 
	if optionCount > menus[currentMenu].maxOptionCount then
		y = menus[currentMenu].y + titleHeight + buttonHeight * multiplier + 0.021
	else
		y = menus[currentMenu].y + titleHeight + buttonHeight * multiplier + 0.021
	end
 
	local color = { r = 0, g = 0, b = 0, a = 195 }
    if HasStreamedTextureDictLoaded("generic_textures") then
        local colour = menus[currentMenu].subTitleBackgroundColor
		if HasStreamedTextureDictLoaded("menu_textures") then
			SetScriptGfxDrawOrder(0)
			DrawSprite("menu_textures", "translate_bg_1a", x, y, menus[currentMenu].width + 0.035, buttonHeight, 0.0, 0, 0, 0, 255, 0)
		end
    end
end
 
 
local function drawDescription(text)
 
	local x = menus[currentMenu].x + menus[currentMenu].width / 2
	local multiplier = nil
 
    if menus[currentMenu].totalOptions >= menus[currentMenu].maxOptionCount then
		multiplier = menus[currentMenu].maxOptionCount + 1
	elseif menus[currentMenu].totalOptions <= menus[currentMenu].maxOptionCount then
		multiplier = menus[currentMenu].totalOptions + 1
	end
 
	local backgroundColor = menus[currentMenu].menuBackgroundColor
	local textColor = menus[currentMenu].menuTextColor
 
	if text == nil or text == "" then
		return
	end
 
	if optionCount > menus[currentMenu].maxOptionCount then
		y = menus[currentMenu].y + titleHeight + buttonHeight * multiplier + 0.002
	else
		y = menus[currentMenu].y + titleHeight + buttonHeight * multiplier + 0.002
	end
 
	local string, lines = drawMultilineFormat(text)
	drawText(text, menus[currentMenu].x + buttonTextXOffset, y + buttonTextYOffset, buttonFont, textColor, buttonScale, false, false, false, true)
 
	descWidth = buttonHeight * lines - buttonHeight / 3 * ( lines-1 )
 
	if HasStreamedTextureDictLoaded("generic_textures") then
		SetScriptGfxDrawOrder(0)
		DrawSprite("generic_textures", "list_item_h_line_narrow", x, y + descWidth /2 - 0.02, menus[currentMenu].width+ 0.01, 0.003, 0.0, 255, 255, 255, 255, 0)
	end
end
 
Phoenix.Menu.CreateMenu = function(id, title, desc)
	menus[id] = {}
	menus[id].title = title or ''
	menus[id].subTitle = ''
	menus[id].desTitle = ''
	menus[id].subMenuLeft = ''
 
	menus[id].header = header or ''
 
	menus[id].visible = false
	menus[id].desc = desc or ''
	menus[id].descStat = nil
 
	menus[id].menuWidth = 0.20
 
	menus[id].previousMenu = nil
 
	menus[id].aboutToBeClosed = false
	menus[id].aboutToBeSubClosed = false
 
	menus[id].x = 0.02
	menus[id].y = 0.10
 
	menus[id].width = 0.21
 
	menus[id].currentOption = 1
	menus[id].maxOptionCount = 15
 
	menus[id].totalOptions = 0
	menus[id].toogleHeritage = false
 
	menus[id].footer = buttonHeight * ( menus[id].maxOptionCount + 1 )
 
	menus[id].titleFont = 9
	menus[id].titleColor = { r = 255, g = 255, b = 255, a = 255 }
	menus[id].titleBackgroundColor = { r = 186, g = 2, b = 2, a = 255 }
	menus[id].titleBackgroundSprite = nil
 
	menus[id].SliderColor = { r = 57, g = 116, b = 200, a = 255 }
	menus[id].SliderBackgroundColor = { r = 4, g = 32, b = 57, a = 255 }
 
	menus[id].menuTextColor = { r = 255, g = 255, b = 255, a = 255 }
	menus[id].menuSubTextColor = { r = 189, g = 189, b = 189, a = 255 }
	menus[id].menuFocusTextColor = { r = 0, g = 0, b = 0, a = 255 }
	menus[id].menuFocusBackgroundColor = { r = 245, g = 245, b = 245, a = 255 }
	menus[id].menuBackgroundColor = { r = 0, g = 0, b = 0, a = 160 }
 
	menus[id].subTitleBackgroundColor = { r = menus[id].menuBackgroundColor.r, g = menus[id].menuBackgroundColor.g, b = menus[id].menuBackgroundColor.b, a = 255 }
 
	menus[id].buttonPressedSound = { name = "SELECT", set = "HUD_FRONTEND_DEFAULT_SOUNDSET" }
end
 
 
Phoenix.Menu.CreateSubMenu = function(id, parent, subTitle, desc)
	if menus[parent] then
		Phoenix.Menu.CreateMenu(id, menus[parent].title, desc)
 
		if subTitle then
			setMenuProperty(id, 'subTitle', string.upper(subTitle))
		else
			setMenuProperty(id, 'subTitle', string.upper(menus[parent].subTitle))
		end
 
		setMenuProperty(id, 'previousMenu', parent)
 
		setMenuProperty(id, 'x', menus[parent].x)
		setMenuProperty(id, 'y', menus[parent].y)
		setMenuProperty(id, 'maxOptionCount', menus[parent].maxOptionCount)
		setMenuProperty(id, 'titleFont', menus[parent].titleFont)
		setMenuProperty(id, 'titleColor', menus[parent].titleColor)
		setMenuProperty(id, 'titleBackgroundColor', menus[parent].titleBackgroundColor)
		setMenuProperty(id, 'titleBackgroundSprite', menus[parent].titleBackgroundSprite)
		setMenuProperty(id, 'menuTextColor', menus[parent].menuTextColor)
		setMenuProperty(id, 'menuSubTextColor', menus[parent].menuSubTextColor)
		setMenuProperty(id, 'menuFocusTextColor', menus[parent].menuFocusTextColor)
		setMenuProperty(id, 'menuFocusBackgroundColor', menus[parent].menuFocusBackgroundColor)
		setMenuProperty(id, 'menuBackgroundColor', menus[parent].menuBackgroundColor)
		setMenuProperty(id, 'subTitleBackgroundColor', menus[parent].subTitleBackgroundColor)
	else
		debugPrint('Failed to create '..tostring(id)..' submenu: '..tostring(parent)..' parent menu doesn\'t exist')
	end
end
 
 
Phoenix.Menu.CurrentMenu = function()
	return currentMenu
end
 
 
Phoenix.Menu.OpenMenu = function(id)
	if id and menus[id] then
		PlaySoundFrontend("SELECT", "HUD_SHOP_SOUNDSET", 1)
		setMenuVisible(id, true)
		debugPrint(tostring(id)..' menu opened')
		DisplayRadar(false)
	else
		debugPrint('Failed to open '..tostring(id)..' menu: it doesn\'t exist')
	end
end
 
 
Phoenix.Menu.IsMenuOpened = function(id)
	return isMenuVisible(id)
end
 
 
Phoenix.Menu.IsAnyMenuOpened = function()
	for id, _ in pairs(menus) do
		if isMenuVisible(id) then return true end
	end
 
	return false
end
 
 
Phoenix.Menu.IsMenuAboutToBeClosed = function()
	if menus[currentMenu] then
		return menus[currentMenu].aboutToBeClosed
	else
		return false
	end
end
 
 
Phoenix.Menu.CloseMenu = function()
	if menus[currentMenu] then
		if menus[currentMenu].aboutToBeClosed then
			menus[currentMenu].aboutToBeClosed = false
			setMenuVisible(currentMenu, false)
			debugPrint(tostring(currentMenu)..' menu closed')
			PlaySoundFrontend("QUIT", "HUD_SHOP_SOUNDSET", 1)
			optionCount = 0
			currentMenu = nil
			currentKey = nil
		else
			menus[currentMenu].aboutToBeClosed = true
			debugPrint(tostring(currentMenu)..' menu about to be closed')
		end
		DisplayRadar(true)
	end
end
 
 
Phoenix.Menu.Button = function(text, subText, descText, isInfo)
 
	if menus[currentMenu] then
 
		descText = descText or ''
 
		optionCount = optionCount + 1
 
		local isCurrent = menus[currentMenu].currentOption == optionCount
 
		drawButton(text, subText, isInfo)
 
		menus[currentMenu].totalOptions = optionCount
 
		if isCurrent then
			if descText then
				menus[currentMenu].descText = descText
			end
			if currentKey == keys.select then
				PlaySoundFrontend("SELECT", "HUD_SHOP_SOUNDSET", 1)
				return true
			elseif currentKey == keys.left or currentKey == keys.right then
				PlaySoundFrontend("SELECT", "HUD_SHOP_SOUNDSET", 1)
			end
		end
 
		return false
	else
		debugPrint('Failed to create '..buttonText..' button: '..tostring(currentMenu)..' menu doesn\'t exist')
 
		return false
	end
end
 
 
Phoenix.Menu.MenuButton = function(text, id)
	if menus[id] then
		if Phoenix.Menu.Button(text) then
			setMenuVisible(currentMenu, false)
			setMenuVisible(id, true, true)
 
			return true
		end
	else
		debugPrint('Failed to create '..tostring(text)..' menu button: '..tostring(id)..' submenu doesn\'t exist')
	end
 
	return false
end
 
 
Phoenix.Menu.CheckBox = function(text, checked, callback)
	if Phoenix.Menu.Button(text, checked and 'On' or 'Off') then
		checked = not checked
		debugPrint(tostring(text)..' checkbox changed to '..tostring(checked))
		if callback then callback(checked) end
 
		return true
	end
 
	return false
end
 
 
Phoenix.Menu.ComboBox = function(text, items, currentIndex, selectedIndex, callback)
	local itemsCount = #items
	local selectedItemOn = items[currentIndex]
	local isCurrent = menus[currentMenu].currentOption == (optionCount + 1)
 
	if itemsCount > 1 and isCurrent then
		selectedItem = '← '..tostring(selectedItemOn)..' →'
	end
 
	if Phoenix.Menu.Button(text, selectedItem) then
		selectedIndex = currentIndex
		callback(currentIndex, selectedItemOn)
		return true
	elseif isCurrent then
		
	else
		currentIndex = selectedIndex
	end
 
	callback(false, false)
	return false
end
 
 
Phoenix.Menu.Display = function()
	if isMenuVisible(currentMenu) then
		if menus[currentMenu].aboutToBeClosed then
			Phoenix.Menu.CloseMenu()
		else
			ClearAllHelpMessages()
 
			drawTitle()
 
            drawBottom()
 
			currentKey = nil
 
			if menus[currentMenu].desc then
				drawDescription("Pheonix Menu | v" .. Phoenix.version .. " | " .. menus[currentMenu].desc)
			end
 
			if isPressedKey(keys.down) then
				PlaySoundFrontend( "NAV_DOWN", "Ledger_Sounds", true )
				if menus[currentMenu].currentOption < optionCount then
					menus[currentMenu].currentOption = menus[currentMenu].currentOption + 1
				else
					menus[currentMenu].currentOption = 1
				end
			elseif isPressedKey(keys.up) then
				PlaySoundFrontend( "NAV_UP", "Ledger_Sounds", true )
				if menus[currentMenu].currentOption > 1 then
					menus[currentMenu].currentOption = menus[currentMenu].currentOption - 1
				else
					menus[currentMenu].currentOption = optionCount
				end
			elseif isPressedKey(keys.left) then
				currentKey = keys.left
			elseif isPressedKey(keys.right) then
				currentKey = keys.right
			elseif isPressedKey(keys.select) then
				currentKey = keys.select
			elseif isPressedKey(keys.back) then
				if menus[menus[currentMenu].previousMenu] then
					PlaySoundFrontend( "BACK", "HUD_SHOP_SOUNDSET", true )
					setMenuVisible(menus[currentMenu].previousMenu, true)
				else
					Phoenix.Menu.CloseMenu()
				end
			end
 
			optionCount = 0
		end
	end
end
 
local k_delay = 180
local k_delay2 = 160
local k_delay3 = 130 
 
function isPressedKey(key)
	if key ~= lastKey and IsDisabledControlPressed(1, key) then
		lastKey = key
		timer = GetGameTimer()
		count = 0
		pass = false
		return true
 
	elseif key == lastKey and IsDisabledControlPressed(1, key) then
		if pass then
			count = 0
			if GetGameTimer() - timer > k_delay3 and GetGameTimer() - timer < k_delay then
				timer = GetGameTimer()
				return true
			elseif GetGameTimer() - timer > k_delay then
				pass = false
				timer = GetGameTimer()
				return true
			end
			return false
		elseif GetGameTimer() - timer > k_delay + 100 then
			count = 0
			timer = GetGameTimer()
			return true
		elseif GetGameTimer() - timer > k_delay then
			count = 1
			timer = GetGameTimer()
			return true
		elseif GetGameTimer() - timer > k_delay2 and (count > 0 and count < 5) then
			count = count + 1
			timer = GetGameTimer()
			return true
		elseif count > 4 then
			pass = true
			return false
		end
		return false
	end
	return false
end
 
Phoenix.Menu.SetMenuWidth = function(id, width)
	setMenuProperty(id, 'width', width)
end
 
 
Phoenix.Menu.SetMenuX = function(id, x)
	setMenuProperty(id, 'x', x)
end
 
 
Phoenix.Menu.SetMenuY = function(id, y)
	setMenuProperty(id, 'y', y)
end
 
 
Phoenix.Menu.SetMenuMaxOptionCountOnScreen = function(id, count)
	setMenuProperty(id, 'maxOptionCount', count)
end
 
 
Phoenix.Menu.SetTitle = function(id, title)
	setMenuProperty(id, 'title', title)
end
 
 
Phoenix.Menu.SetTitleColor = function(id, r, g, b, a)
	setMenuProperty(id, 'titleColor', { ['r'] = r, ['g'] = g, ['b'] = b, ['a'] = a or menus[id].titleColor.a })
end
 
 
Phoenix.Menu.SetTitleBackgroundColor = function(id, r, g, b, a)
	setMenuProperty(id, 'titleBackgroundColor', { ['r'] = r, ['g'] = g, ['b'] = b, ['a'] = a or menus[id].titleBackgroundColor.a })
end
 
 
Phoenix.Menu.SetTitleBackgroundSprite = function(id, textureDict, textureName)
	RequestStreamedTextureDict(textureDict)
	setMenuProperty(id, 'titleBackgroundSprite', { dict = textureDict, name = textureName })
end
 
 
Phoenix.Menu.SetSubTitle = function(id, text)
	setMenuProperty(id, 'subTitle', string.upper(text))
end
 
 
Phoenix.Menu.SetMenuBackgroundColor = function(id, r, g, b, a)
	setMenuProperty(id, 'menuBackgroundColor', { ['r'] = r, ['g'] = g, ['b'] = b, ['a'] = a or menus[id].menuBackgroundColor.a })
end
 
 
Phoenix.Menu.SetMenuTextColor = function(id, r, g, b, a)
	setMenuProperty(id, 'menuTextColor', { ['r'] = r, ['g'] = g, ['b'] = b, ['a'] = a or menus[id].menuTextColor.a })
end
 
Phoenix.Menu.SetMenuSubTextColor = function(id, r, g, b, a)
	setMenuProperty(id, 'menuSubTextColor', { ['r'] = r, ['g'] = g, ['b'] = b, ['a'] = a or menus[id].menuSubTextColor.a })
end
 
Phoenix.Menu.SetMenuFocusColor = function(id, r, g, b, a)
	setMenuProperty(id, 'menuFocusBackgroundColor', { ['r'] = r, ['g'] = g, ['b'] = b, ['a'] = a or menus[id].menuFocusColor.a })
end
 
 
Phoenix.Menu.SetMenuButtonPressedSound = function(id, name, set)
	setMenuProperty(id, 'buttonPressedSound', { ['name'] = name, ['set'] = set })
end
 
Phoenix.Troll = {}
 
Phoenix.keybindThreads = {}
 
Phoenix.menuThreads = {}
Phoenix.menuAttributes = {}
Phoenix.menuCheckBoxes = {}
Phoenix.otherSecondThreads = {}
 
Phoenix.theLoadout = { 0x6DFA071B, 0x169F59F7, 0x7A8A724A, 0xDB21AC8C, 0x88A8505C }
 
Phoenix.createThread(function()
	while (true) do
		Citizen.Wait(1)
 
		for keybind_,keybind_tick in ipairs(Phoenix.keybindThreads) do
			keybind_tick()
		end
 
		for menu_,menu_tick in ipairs(Phoenix.menuThreads) do
			menu_tick()
		end 
 
		for othersecond_,othersecond_tick in ipairs(Phoenix.otherSecondThreads) do
			othersecond_tick()
		end
	end
end)
 
Phoenix.registerKey = function(key, cb)
	table.insert(Phoenix.keybindThreads, function()
		if isPressedKey(key) then
			cb()
		end
	end)
end
 
Phoenix.drawTxt = function(coords, text, size, font)
	local camCoords = Phoenix.native(0x595320200B98596E, Phoenix.rdr2.ReturnResultAnyway(), Phoenix.rdr2.ResultAsVector())
	local distance = #(camCoords - coords)
 
	local scale = (size / distance) * 2
	local fov = (1 / GetGameplayCamFov()) * 100
	scale = scale * fov
 
	local onScreen, x, y = GetScreenCoordFromWorldCoord(coords.x, coords.y, coords.z)
 
	if (onScreen) then
		SetTextScale(0.0 * scale, 0.55 * scale)
		Phoenix.native(0x50A41AD966910F03, 255, 255, 255, 255)
 
		if (font ~= nil) then
			SetTextFontForCurrentCommand(font)
		end
 
		SetTextDropshadow(0, 0, 0, 255)
		SetTextCentre(true)
		Phoenix.native(0xD79334A4BB99BAD1, CreateVarString(10, 'LITERAL_STRING', text), x, y)
	end
end
 
Phoenix.getPlayerInfo = function(plyId, cb, myPed, isMyself)
	local mycoords = myPed and GetEntityCoords(myPed) or nil
	local coords = GetEntityCoords(isMyself and plyId or GetPlayerPed(plyId))
	local ped = isMyself and plyId or GetPlayerPed(plyId)
 
	cb({
		id = plyId,
		name = GetPlayerName(plyId),
		serverId = GetPlayerServerId(plyId),
		ped = ped,
		coords = coords,
		height = GetEntityHeight(ped, coords.x, coords.y, coords.z, true, true),
		health = GetEntityHealth(ped),
 
		distance = myPed and Vdist2(coords.x, coords.y, coords.z, mycoords.x, mycoords.y, mycoords.z) or nil,
	})
end
 
Phoenix.registerMenu = function(id, title, desc, control, cb)
	Phoenix.menuCheckBoxes[id] = {}
	Phoenix.Menu.CreateMenu(id, title, desc)
    Phoenix.Menu.SetSubTitle(id, desc)
	Phoenix.Menu.SetMenuWidth(id, 0.275)
	Phoenix.Menu.SetMenuX(id, 0.65)
 
	Phoenix.Print('Phoenix Menu Invoked! (Name: ' .. title .. ", Description: " .. desc .. ")", title .. " Invoked", false)
 
	if control then
		Phoenix.registerKey(control, function()
			Phoenix.Menu.OpenMenu(id)
		end)
	end
 
	cb()
 
	table.insert(Phoenix.menuThreads, function()
		if Phoenix.Menu.IsMenuOpened(id) then
			for i = 1, #Phoenix.menuAttributes[id] do
				local menu = Phoenix.menuAttributes[id][i]
				if menu.data.type == 'button' then
					if Phoenix.Menu.Button(menu.data.name, menu.data.desc, false, (menu.data.isInfo or false)) then
						menu.cb()
					end
				elseif menu.data.type == 'checkbox' then
					if not Phoenix.menuCheckBoxes[id][menu.data.name] then Phoenix.menuCheckBoxes[id][menu.data.name] = menu.checked end
					if Phoenix.Menu.CheckBox(menu.data.name, Phoenix.menuCheckBoxes[id][menu.data.name], menu.cb) then
						Phoenix.menuCheckBoxes[id][menu.data.name] = not Phoenix.menuCheckBoxes[id][menu.data.name]
					end
				elseif menu.data.type == 'combobox' then
					Phoenix.Menu.ComboBox(menu.data.name, menu.data.items, menu.data.currentIndex, menu.data.selectedIndex, function(currentIndex, selectedItem)
 
						if currentIndex or selectedItem then
							menu.cb(currentIndex, selectedItem)
							Citizen.Wait(15)
						end
 
						if menus[currentMenu].currentOption == (optionCount) then
							if isPressedKey(0xA65EBAB4) then
								if menu.data.currentIndex > 1 then menu.data.currentIndex = menu.data.currentIndex - 1 else menu.data.currentIndex = #menu.data.items end
							end
 
							if isPressedKey(0xDEB34313) then
								if menu.data.currentIndex < #menu.data.items then menu.data.currentIndex = menu.data.currentIndex + 1 else menu.data.currentIndex = 1 end
							end
						end
 
					end)
				end
			end
	
			Phoenix.Menu.Display()
		end
	end)
end
 
Phoenix.registerSubMenu = function(id, parantid, title, desc, control, cb)
	Phoenix.menuCheckBoxes[id] = {}
	Phoenix.Menu.CreateSubMenu(id, parantid, title, desc)
	Phoenix.Menu.SetSubTitle(id, desc)
	Phoenix.Menu.SetMenuWidth(id, 0.275)
	Phoenix.Menu.SetMenuX(id, 0.65)
 
	Phoenix.Print('Phoenix Sub Menu Invoked! (Name: ' .. title .. ", Description: " .. desc .. ")", false, false)
 
	if control then
		Phoenix.registerKey(control, function()
			Phoenix.Menu.OpenMenu(id)
		end)
	end
 
	cb()
 
	table.insert(Phoenix.menuThreads, function()
		if Phoenix.Menu.IsMenuOpened(id) then
			for i = 1, #Phoenix.menuAttributes[id] do
				local menu = Phoenix.menuAttributes[id][i]
				if menu.data.type == 'button' then
					if Phoenix.Menu.Button(menu.data.name, menu.data.desc, false, (menu.data.isInfo or false)) then
						menu.cb()
					end
				elseif menu.data.type == 'checkbox' then
					if not Phoenix.menuCheckBoxes[id][menu.data.name] then Phoenix.menuCheckBoxes[id][menu.data.name] = menu.checked end
					if Phoenix.Menu.CheckBox(menu.data.name, Phoenix.menuCheckBoxes[id][menu.data.name], menu.cb) then
						Phoenix.menuCheckBoxes[id][menu.data.name] = not Phoenix.menuCheckBoxes[id][menu.data.name]
					end
				elseif menu.data.type == 'combobox' then
					Phoenix.Menu.ComboBox(menu.data.name, menu.data.items, menu.data.currentIndex, menu.data.selectedIndex, function(currentIndex, selectedItem)
 
						if currentIndex or selectedItem then
							menu.cb(currentIndex, selectedItem)
							Citizen.Wait(15)
						end
 
						if menus[currentMenu].currentOption == (optionCount) then
							if isPressedKey(0xA65EBAB4) then
								if menu.data.currentIndex > 1 then menu.data.currentIndex = menu.data.currentIndex - 1 else menu.data.currentIndex = #menu.data.items end
							end
 
							if isPressedKey(0xDEB34313) then
								if menu.data.currentIndex < #menu.data.items then menu.data.currentIndex = menu.data.currentIndex + 1 else menu.data.currentIndex = 1 end
							end
						end
 
					end)
				end
			end
	
			Phoenix.Menu.Display()
		end
	end)
 
end
 
Phoenix.registerMenuAttribute = function(menuId, data, cb)
	if not Phoenix.menuAttributes[menuId] then Phoenix.menuAttributes[menuId] = {} end
 
	table.insert(Phoenix.menuAttributes[menuId], { data = data, cb = cb })
end
 
Phoenix.GetDistance = function(p1, p2)
    return math.sqrt((p2.x - p1.x) ^ 2 + (p2.y - p1.y) ^ 2 + (p2.z - p1.z) ^ 2)
end
 
Phoenix.NetWorkPriority = function(ent)
    if DoesEntityExist(ent) and NetworkGetEntityIsNetworked(ent) then
        if not NetworkHasControlOfEntity(ent) then
            Phoenix.native(0x5C707A667DF8B9FA, true, PlayerPedId())
            local networkId = NetworkGetNetworkIdFromEntity(ent)
 
            NetworkRequestControlOfNetworkId(networkId)
 
            SetNetworkIdExistsOnAllMachines(networkId, true)
            Phoenix.native(0x299EEB23175895FC, networkId, false)
 
            NetworkRequestControlOfEntity(NetToEnt(networkId))
 
            local maxTimer = 0
            while not NetworkHasControlOfEntity(NetToEnt(networkId)) do 
                Citizen.Wait(100)
                maxTimer = maxTimer + 1 
                if maxTimer > 20 or not NetworkGetEntityIsNetworked(ent) then
                    return false 
                end
            end
        end
 
        return true 
    end
end
 
Phoenix.ObjectCache = {}
RegisterCommand("test:exp", function()
	local coords = GetEntityCoords(PlayerPedId())
	
	Phoenix.getPlayerInfo(Phoenix.pedID(), function(info)
 
		local newObject = CreateObject(
			`s_rock01x`, 
			info.coords.x, 
			info.coords.y,
			info.coords.z + 1.95,
			true,
			true,
			true,
			true,
			true
		)
		
		table.insert(Phoenix.ObjectCache, newObject)
	end, false, true)
end)
 
Phoenix.Troll.AnimalAttack = function(playerId, hash, distance) -- TODO: Reocde (make it so anything can attack)
	local playerId = playerId
	Phoenix.createThread(function()
		Phoenix.getPlayerInfo(playerId, function(pInfo)
 
			local height = 1 
			for height = 1, 1000 do 
				local foundGround, groundZ, normal = GetGroundZAndNormalFor_3dCoord(pInfo.coords.x, pInfo.coords.y, height + 0.0)
				if foundGround then
					RequestModel(hash)
					while not HasModelLoaded(hash) do 
						Citizen.Wait(50)
					end
	
					local pedC = CreatePed(hash, pInfo.coords.x + math.random(distance), pInfo.coords.y + math.random(distance), groundZ, 0.0, true, false)
					Citizen.InvokeNative(0x283978A15512B2FE, pedC, true)
					SetEntityMaxHealth(pedC, 1250)
					SetEntityHealth(pedC, 1250)
					local bearKilled = false
	
					while not bearKilled do
						Citizen.Wait(15)
						local pedCCoords = GetEntityCoords(pedC)
						TaskCombatPed(pedC, GetPlayerPed(playerId), 0, 16)
						local distanceBetweenEntities = Phoenix.GetDistance(pInfo.coords, pedCCoords)
						local isPedDead = GetEntityHealth(pedC)
	
						if distanceBetweenEntities < 1.5 then
							bearKilled = true
							ClearPedTasksImmediately(pedC)
						elseif isPedDead == 0 then 
							bearKilled = true
						end
					end
 
					break 
				end
				Wait(25)
			end
 
		end)
	end)
end
 
 
 
 
Phoenix.registerESP = function(identifier, esp_tick, pedId)
	if Phoenix.menuCheckBoxes['phoenix_chair_esp'][identifier] then return end
 
	Phoenix.Print(identifier .." ESP: Enabled", identifier .." ESP: Enabled", false)
	Phoenix.createThread(function()
		while (true) do
			Citizen.Wait(0)
 
			for _, id in ipairs(GetActivePlayers()) do
				if Phoenix.pedID() ~= GetPlayerPed(id) then
					Phoenix.getPlayerInfo(id, function(plyData)
						esp_tick(plyData)
					end, pedId and Phoenix.pedID() or false)
				end
			end
 
			if not Phoenix.menuCheckBoxes['phoenix_chair_esp'][identifier] then
				Phoenix.Print(identifier .." ESP: Disabled", identifier .." ESP: Disabled", false)
				break
			end
 
		end
	end)
end
 
-- Phoenix.SetPlayerIdSelected = function(PlayerID)
-- 	PlayerIDs = 0
-- 	PlayerIDs = tonumber(PlayerID)
-- end
 
-- RegisterCommand("get:playerid", function()
-- 	print(PlayerIDs)
-- end)
 
 
Phoenix.registerNearbyPlayer = function(playerId)
	local plyServerId = GetPlayerServerId(playerId)
	local plyName = GetPlayerName(playerId)
	
	Phoenix.registerSubMenu('phoenix_chair_nearby_' .. tostring(plyServerId), 'phoenix_chair_nearby', "Phoenix Menu", "[" .. tostring(plyServerId) .. "] - " .. plyName, false, function()
		Phoenix.menuAttributes['phoenix_chair_nearby_' .. tostring(plyServerId)] = {}
 
		Phoenix.registerMenuAttribute('phoenix_chair_nearby_' .. tostring(plyServerId), {
			type = 'button',
			name = 'Teleport to Player',
			desc = 'hello!',
		}, function()
			local playerCoords = GetEntityCoords(GetPlayerPed(playerId))
 
			Phoenix.native(0x06843DA7060A026B, Phoenix.pedID(), playerCoords.x, playerCoords.y, playerCoords.z, 0, 0, 0, 0)
			Phoenix.Print("Teleported to player", "Teleported to player", false)
		end)
 
		Phoenix.registerMenuAttribute('phoenix_chair_nearby_' .. tostring(plyServerId), {
			type = 'button',
			name = 'Explode',
			desc = 'say bye, bye!',
		}, function()
			local playerCoords = GetEntityCoords(GetPlayerPed(playerId))
 
			Phoenix.native(0xD84A917A64D4D016, GetPlayerPed(playerId), playerCoords.x, playerCoords.y, playerCoords.z, 27, 1000.0, true, false, true)
			Phoenix.native(0xD84A917A64D4D016, GetPlayerPed(playerId), playerCoords.x, playerCoords.y, playerCoords.z, 30, 1000.0, true, false, true)
			Phoenix.Print("Player go boomb", "Player go boomb", false)
		end)
 
		Phoenix.registerMenuAttribute('phoenix_chair_nearby_' .. tostring(plyServerId), {
			type = 'button',
			name = 'Set on fire',
			desc = 'burning alive!',
		}, function()
			local playerCoords = GetEntityCoords(GetPlayerPed(playerId))
 
			Phoenix.native(0xD84A917A64D4D016, GetPlayerPed(playerId), playerCoords.x, playerCoords.y, playerCoords.z, 30, 1000.0, true, false, true)
			Phoenix.Print("Player be burning", "Player be burning", false)
		end)
 
		Phoenix.registerMenuAttribute('phoenix_chair_nearby_' .. tostring(plyServerId), {
			type = 'button',
			name = 'Send to the stratosphere',
			desc = 'woah look, the moon',
		}, function()
			local playerCoords = GetEntityCoords(GetPlayerPed(playerId))
 
			for i = 1, 100 do
				Phoenix.native(0xD84A917A64D4D016, GetPlayerPed(playerId), playerCoords.x, playerCoords.y, playerCoords.z, i, 1000.0, true, false, true)
				Phoenix.native(0xD84A917A64D4D016, GetPlayerPed(playerId), playerCoords.x, playerCoords.y, playerCoords.z, i, 1000.0, true, false, true)
				Phoenix.native(0xD84A917A64D4D016, GetPlayerPed(playerId), playerCoords.x, playerCoords.y, playerCoords.z, i, 1000.0, true, false, true)
			end
 
			Phoenix.Print("Player go boomb", "Player go boomb", false)
		end)
 
		Phoenix.registerMenuAttribute('phoenix_chair_nearby_' .. tostring(plyServerId), {
			type = 'button',
			name = 'Send to the stratosphere (shhh)',
			desc = '',
		}, function()
			local playerCoords = GetEntityCoords(GetPlayerPed(playerId))
 
			for i = 1, 100 do
				Phoenix.native(0xD84A917A64D4D016, GetPlayerPed(playerId), playerCoords.x, playerCoords.y, playerCoords.z, i, 1000.0, false, true, true)
				Phoenix.native(0xD84A917A64D4D016, GetPlayerPed(playerId), playerCoords.x, playerCoords.y, playerCoords.z, i, 1000.0, false, true, true)
				Phoenix.native(0xD84A917A64D4D016, GetPlayerPed(playerId), playerCoords.x, playerCoords.y, playerCoords.z, i, 1000.0, false, true, true)
			end
 
			Phoenix.Print("Player go boomb", "Player go boomb", false)
		end)
 
		Phoenix.registerMenuAttribute('phoenix_chair_nearby_' .. tostring(plyServerId), {
			type = 'button',
			name = 'Spawn Attack AI',
			desc = 'New Feature',
		}, function()
			local playerCoords = GetEntityCoords(GetPlayerPed(playerId))
			pedmodel = GetHashKey("RE_RALLY_MALES_01")
			
			scale = 2.0
		
			RequestModel(pedmodel)
			while not HasModelLoaded(pedmodel) do
				RequestModel(pedmodel)
				Wait(1)
			end
			
			local ped = CreatePed(pedmodel, playerCoords.x + 2, playerCoords.y + 2, playerCoords.z + 1, 45.0, true, false)
			Citizen.InvokeNative(0x283978A15512B2FE, ped, true)
			GiveWeaponToPed(ped, 0xA64DAA5E, 250, true, true)
			TaskCombatPed(ped, GetPlayerPed(playerId))
			SetPedAccuracy(ped, 100)
			Phoenix.requestControl(ped)
			SetPedScale(ped, scale)
			SetEntityHealth(ped, 2000)
 
			Phoenix.Print("bye bye!", "bye bye!", false)
		end)
 
		Phoenix.registerMenuAttribute('phoenix_chair_nearby_' .. tostring(plyServerId), {
			type = 'button',
			name = 'Spawn Huge Ped',
			desc = 'New Feature',
		}, function()
			local playerCoords = GetEntityCoords(GetPlayerPed(playerId))
			pedmodel = GetHashKey("RE_RALLY_MALES_01")
			
			scale = 10.0
		
			RequestModel(pedmodel)
			while not HasModelLoaded(pedmodel) do
				RequestModel(pedmodel)
				Wait(1)
			end
			
			local ped = CreatePed(pedmodel, playerCoords.x, playerCoords.y + 2, playerCoords.z + 10, 45.0, true, false)
			Citizen.InvokeNative(0x283978A15512B2FE, ped, true)
			GiveWeaponToPed(ped, 0xA64DAA5E, 250, true, true)
			TaskCombatPed(ped, GetPlayerPed(playerId))
			SetPedAccuracy(ped, 100)
			Phoenix.requestControl(ped)
			SetPedScale(ped, scale)
			SetEntityHealth(ped, 2000)
 
			Phoenix.Print("bye bye!", "bye bye!", false)
		end)
 
 
 
 
 
		Phoenix.registerMenuAttribute('phoenix_chair_nearby_' .. tostring(plyServerId), {
			type = 'button',
			name = 'Apply damage multi',
			desc = '(max) very powerful bow!',
		}, function()
			SetPlayerWeaponDamageModifier(PlayerId(playerId), 1000.0)
			Phoenix.Print("Applied damage mod", "Applied damage mod", false)
		end)
 
		Phoenix.registerMenuAttribute('phoenix_chair_nearby_' .. tostring(plyServerId), {
			type = 'button',
			name = 'Silent Kill',
			desc = 'sneak kill!',
		}, function()
			local coords = GetEntityCoords(GetPlayerPed(playerId))
			Phoenix.native(0x867654CBC7606F2C, coords, coords.x, coords.y, coords.z + 0.01, 400.0, true, 0x31B7B9FE, PlayerPedId(), false, true, 999999999, false, false, 0)
		end)
 
		Phoenix.registerMenuAttribute('phoenix_chair_nearby_' .. tostring(plyServerId), {
			type = 'checkbox',
			name = 'Attach',
		}, function()
			if not Phoenix.menuCheckBoxes['phoenix_chair_nearby_' .. tostring(plyServerId)]['Attach'] then
				Phoenix.Print("Attach: Enabled", "Attach: Enabled", false)
				Phoenix.native(0x6B9BBD38AB0796DF, Phoenix.pedID(), GetPlayerPed(playerId), 11816, 0.54, 0.54, 0.0, 0.0, 0.0, 0.0, false, false, false, false, 2, true)
			else
				Phoenix.native(0x64CDE9D6BF8ECAD3, Phoenix.pedID(), false, false)
				Phoenix.Print("Attach: Disabled", "Attach: Disabled", false)
			end
		end)
 
        Phoenix.registerMenuAttribute('phoenix_chair_nearby_' .. tostring(plyServerId), {
			type = 'button',
			name = 'Clone',
			desc = 'Clone Ped!',
		}, function()
            Phoenix.native(0xEF29A16337FACADB, GetPlayerPed(playerId), true, true, true)
            Phoenix.Print("Cloned Ped", "Cloned Ped", false)
        end)
 
		Phoenix.registerMenuAttribute('phoenix_chair_nearby_' .. tostring(plyServerId), {
			type = 'button',
			name = 'Bear Attack',
			desc = 'Get your bear spray!',
		}, 
		function()
            local hash = 3170700927
			local distance = 20,40
 
			Phoenix.Troll.AnimalAttack(playerId, hash, distance)
        end)
 
		Phoenix.registerMenuAttribute('phoenix_chair_nearby_' .. tostring(plyServerId), {
			type = 'button',
			name = 'Panther Attack',
			desc = 'Get your Lion spray!',
		}, function()
            local hash = 1654513481
			local distance = 10,25
			
			Phoenix.Troll.AnimalAttack(playerId, hash, distance)
        end)
 
		Phoenix.registerMenuAttribute('phoenix_chair_nearby_' .. tostring(plyServerId), {
			type = 'button',
			name = 'Gator Attack',
			desc = 'Get your Gator spray!',
		}, function()
            local hash = 2402686849
			local distance = 10,15
			
			Phoenix.Troll.AnimalAttack(playerId, hash, distance)
        end)
 
		Phoenix.registerMenuAttribute('phoenix_chair_nearby_' .. tostring(plyServerId), {
			type = 'button',
			name = 'Local Attack',
			desc = 'Get your local spray!',
		}, function()
            for k, v in pairs(GetGamePool('CPed')) do 
				if v ~= PlayerPedId() and not IsPedInAnyVehicle(v, false) and not IsPedAPlayer(v) then 
					Citizen.CreateThread(function()
						if Phoenix.NetWorkPriority(v) then 
							SetRelationshipBetweenGroups(5, 'PLAYER', GetHashKey(GetPedRelationshipGroupHash(v)))
							SetRelationshipBetweenGroups(5, GetHashKey(GetPedRelationshipGroupHash(v)), 'PLAYER')
							TaskCombatPed(v, GetPlayerPed(playerId), 0, 16)
						end
					end)
				end
			end
        end)
 
		Phoenix.registerMenuAttribute('phoenix_chair_nearby_' .. tostring(plyServerId), {
			type = 'button',
			name = 'Kick From Horse',
			desc = 'Kick Player From Horse',
		}, function()
			KickFromVeh()
        end)
 
 
		Phoenix.registerMenuAttribute('phoenix_chair_nearby_' .. tostring(plyServerId), {
			type = 'button',
			name = 'RedM Cheat ',
			desc = '',
			isInfo = true,
		}, function()
			Phoenix.Print("Phoenix Menu | v" .. Phoenix.version .. " | ", "Phoenix Menu | v" .. Phoenix.version .. " | ", false)
		end)
	end)
end
 
Phoenix.registerMenu('phoenix_chair', "Phoenix Menu", "Main Menu", 0x446258B6, function()
 
	Phoenix.registerMenuAttribute('phoenix_chair', {
		type = 'button',
		name = 'Self Options >',
		desc = 'help yourself!',
	}, function()
		Phoenix.Menu.OpenMenu('phoenix_chair_self')
		Phoenix.Print("Showing Self menu", "Showing Self menu", false)
	end)
 
	Phoenix.registerMenuAttribute('phoenix_chair', {
			type = 'button',
			name = 'Nearby Players >',
			desc = 'Bout to troll, hard.',
		}, function()
		Phoenix.menuAttributes["phoenix_chair_nearby"] = {}
 
		for _,id in ipairs(GetActivePlayers()) do
			Phoenix.registerMenuAttribute('phoenix_chair_nearby', {
				type = 'button',
				name = tostring( GetPlayerServerId(id) .. " - " .. GetPlayerName(id) ),
				desc = "Health: " .. GetEntityHealth(GetPlayerPed(id)),
			}, function()
				Phoenix.Print("You clicked on " .. GetPlayerServerId(id) .. " - " .. GetPlayerName(id))
	
				Phoenix.registerNearbyPlayer(id)
				Phoenix.Menu.OpenMenu('phoenix_chair_nearby_' .. tostring(GetPlayerServerId(id)))
			end)
		end
 
		Phoenix.registerMenuAttribute('phoenix_chair_nearby', {
			type = 'button',
			name = 'RedM Cheat ',
			desc = '',
			isInfo = true,
		}, function()
			Phoenix.Print("Phoenix Menu | v" .. Phoenix.version .. " | ", "Phoenix Menu | v" .. Phoenix.version .. " | ", false)
		end)
 
		Phoenix.Menu.OpenMenu('phoenix_chair_nearby')
		Phoenix.Print("Showing nearby players", "Showing nearby players", false)
	end)
 
	Phoenix.registerMenuAttribute('phoenix_chair', {
		type = 'button',
		name = 'ESP >',
		desc = 'i can see you...',
	}, function()
		Phoenix.Menu.OpenMenu('phoenix_chair_esp')
		Phoenix.Print("Showing ESP menu", "Showing ESP menu", false)
	end)
 
	Phoenix.registerMenuAttribute('phoenix_chair', {
		type = 'button',
		name = 'Weapons >',
		desc = 'woah, that\'s a big gun',
	}, function()
		Phoenix.Menu.OpenMenu('phoenix_chair_weapons')
		Phoenix.Print("Showing Weapons menu", "Showing Weapons menu", false)
	end)
 
	Phoenix.registerMenuAttribute('phoenix_chair', {
		type = 'button',
		name = 'Change Ped >',
		desc = 'i feel like looking differant',
	}, function()
		Phoenix.Menu.OpenMenu('phoenix_chair_pedchanger')
		Phoenix.Print("Showing Ped menu", "Showing Ped menu", false)
	end)
 
	Phoenix.registerMenuAttribute('phoenix_chair', {
		type = 'button',
		name = 'Spawn Horse >',
		desc = 'want to go for a ride!',
	}, function()
		Phoenix.Menu.OpenMenu('phoenix_chair_horses')
		Phoenix.Print("Showing Horse menu", "Showing Horse menu", false)
	end)
 
	Phoenix.registerMenuAttribute('phoenix_chair', {
		type = 'button',
		name = 'Server Features >',
		desc = 'Help Yourself!',
	}, function()
		Phoenix.Menu.OpenMenu('phoenix_chair_server_features')
		Phoenix.Print("Server Features", "Server Features", false)
	end)
 
	Phoenix.menuCheckBoxes['phoenix_chair']['Toggle Notifications'] = Phoenix.Notifications.enabled
	Phoenix.registerMenuAttribute('phoenix_chair', {
			type = 'checkbox',
			name = 'Toggle Notifications',
		}, function()
 
			if Phoenix.menuCheckBoxes['phoenix_chair']['Toggle Notifications'] then
				Phoenix.Notifications.enabled = false
				return
			end
 
			Phoenix.Notifications.enabled = true
			Phoenix.Notifications.startQueue()
			Phoenix.Print("Notifications Enabled", "Notifications Enabled", false)
		end
	)
 
	Phoenix.registerMenuAttribute('phoenix_chair', {
		type = 'button',
		name = 'RedM Cheat ',
		desc = '',
		isInfo = true,
	}, function()
		Phoenix.Print("Phoenix Menu | v" .. Phoenix.version .. " | ", "Phoenix Menu | v" .. Phoenix.version .. " | ", false)
	end)
end)
 
Phoenix.spawnPed = function(modelName, coords, heading, cb)
	local ped_model_name = modelName
	Phoenix.createThread(function()
		local hashRequest = GetHashKey(ped_model_name)
						
		RequestModel(hashRequest)
		while not HasModelLoaded(hashRequest) do 
			Citizen.Wait(50)
		end
 
		local spawningPed = Phoenix.native(0xD49F9B0955C367DE, hashRequest, coords.x, coords.y, coords.z, (heading or 0.0), true, false)
		Citizen.InvokeNative(0x283978A15512B2FE, spawningPed, true)
 
		cb(ped_model_name, spawningPed)
		spawningPed = nil
	end)
end
 
Phoenix.loadModel = function(model)
	if IsModelInCdimage(model) then
		RequestModel(model)
 
		while not HasModelLoaded(model) do
			Wait(0)
		end
 
		return true
	else
		return false
	end
end
 
Phoenix.setPlayerModel = function(data)
	local model = GetHashKey(Phoenix.Configs.Peds[data.type][data.modelIndex])
 
	if Phoenix.loadModel(model) then
		SetPlayerModel(data.playerId, model, true)
	end
end
 
Phoenix.espOffset = 0
Phoenix.createThread(function()
	Phoenix.registerSubMenu('phoenix_chair_nearby', 'phoenix_chair', "Phoenix Menu", "Nearby Players", false, function() end)
 
	Phoenix.registerSubMenu('phoenix_chair_self', 'phoenix_chair', "Phoenix Menu", "Self Menu", false, function() 
		Phoenix.registerMenuAttribute('phoenix_chair_self', {
			type = 'button',
			name = 'Heal',
			desc = 'Feelin good',
		}, function()
			Phoenix.native(0xAC2767ED8BDFAB15, Phoenix.pedID(), GetPedMaxHealth(Phoenix.pedID()))
			Phoenix.Print("Self Healed", "Self Healed", false)
		end)
	
		Phoenix.registerMenuAttribute('phoenix_chair_self', {
			type = 'button',
			name = 'TPM',
			desc = 'Tping away from da cops',
		}, function()
			if Phoenix.native(0xD42BD6EB2E0F1677, Phoenix.pedID()) then
			local WP = GetWaypointCoords()
				if (WP.x == 0 and WP.y == 0) then
				else
					local height = 1
					for height = 1, 1000 do
					Phoenix.native(0x06843DA7060A026B, Phoenix.pedID(), WP.x, WP.y, height + 0.0)
					local foundground, groundZ, normal = GetGroundZAndNormalFor_3dCoord(WP.x, WP.y, height + 0.0)
					if foundground then
						Phoenix.native(0x06843DA7060A026B, Phoenix.pedID(), WP.x, WP.y, height + 0.0)
						break
					end
					Wait(25)
					end
				end
			end
			Phoenix.Print("Teleported to marker", "Teleported to marker", false)
		end)
	
		Phoenix.registerMenuAttribute('phoenix_chair_self', {
			type = 'button',
			name = 'FREECAM',
			desc = 'Deploy Tactical Drone',
		}, function()
			Phoenix.toggle_camera()
			Phoenix.Print("Entered Freecam", "Entered Freecam", false)
		end)
		
		Phoenix.registerMenuAttribute('phoenix_chair_self', {
			type = 'checkbox',
			name = 'Aimbot (In Development!)',
		}, function()
		if not Phoenix.menuCheckBoxes['phoenix_chair_self']['Godmode'] then
			Phoenix.createThread(function()
				Phoenix.Print("Aimbot: Enabled", "Aimbot: Enabled", false)
				while (true) do
					Citizen.Wait(1)
 
					aimbot = true
 
					if not Phoenix.menuCheckBoxes['phoenix_chair_self']['Godmode'] then
						Phoenix.Print("Aimbot: Disabled", "Aimbot: Disabled", false)
						aimbot = false
						break
					end
				end
			end)
		end
	end)
 
 
 
 
		Phoenix.registerMenuAttribute('phoenix_chair_self', {
			type = 'button',
			name = 'Make me see',
			desc = 'Woah my eyes',
		}, function()
			Phoenix.native(0x59174F1AFE095B5A, GetHashKey("OVERCAST"), true, true, true, 1.0, false)
			Phoenix.native(0x669E223E64B1903C, math.floor(((2000)/60)%24), math.floor((2000)%60), 0)
			
			Phoenix.Print("Set time to day", "Set time to day", false)
		end)
	
		Phoenix.registerMenuAttribute('phoenix_chair_self', {
			type = 'combobox',
			name = 'Player Size',
			items = {1,0.1,0.2,0.3,0.4,0.5,0.6,0.7,0.8,0.9,1.1,1.2,1.3,1.4,1.5,1.6,1.7,1.8,1.9,2.1,2.2,2.3,2.4,2.5,2.6,2.7,2.8,2.9,3.1,3.2,3.3,3.4,3.5,3.6,3.7,3.8,3.9,4.1,4.2,4.3,4.4,4.5,4.6,4.7,4.8,4.9,5.1,5.2,5.3,5.4,5.5,5.6,5.7,5.8,5.9,6.1,6.2,6.3,6.4,6.5,6.6,6.7,6.8,6.9,7.1,7.2,7.3,7.4,7.5,7.6,7.7,7.8,7.9,8.1,8.2,8.3,8.4,8.5,8.6,8.7,8.8,8.9,9.1,9.2,9.3,9.4,9.5,9.6,9.7,9.8,9.9,10.0},
			currentIndex = 1,
			selectedIndex = 1,
		}, function(currentIndex, selectedItem)
			Phoenix.Print("Player Size Changed To: " ..selectedItem, "Player Size Changed To: " ..selectedItem, false)
	
			Phoenix.requestControl(Phoenix.pedID())
			SetPedScale(Phoenix.pedID(), selectedItem + 0.0)
		end)
	
		Phoenix.registerMenuAttribute('phoenix_chair_self', {
				type = 'checkbox',
				name = 'Godmode',
			}, function()
			if not Phoenix.menuCheckBoxes['phoenix_chair_self']['Godmode'] then
				Phoenix.createThread(function()
					Phoenix.Print("Godmode: Enabled", "Godmode: Enabled", false)
					while (true) do
						Citizen.Wait(1)
	
						Phoenix.native(0x166E7CF68597D8B5, Phoenix.pedID(), 1000000)
						Phoenix.native(0xAC2767ED8BDFAB15, Phoenix.pedID(), GetPedMaxHealth(Phoenix.pedID()))
	
						if not Phoenix.menuCheckBoxes['phoenix_chair_self']['Godmode'] then
							Phoenix.native(0x166E7CF68597D8B5, Phoenix.pedID(), 200)
							Phoenix.Print("Godmode: Disabled", "Godmode: Disabled", false)
							break
						end
					end
				end)
			end
		end)
	
		Phoenix.registerMenuAttribute('phoenix_chair_self', {
				type = 'checkbox',
				name = 'Invisible',
			}, function()
			if not Phoenix.menuCheckBoxes['phoenix_chair_self']['Invisible'] then
				Phoenix.Print("Invis: Enabled", "Invis: Enabled", false)
				Phoenix.createThread(function()
					while (true) do
						Citizen.Wait(1)
	
						Phoenix.native(0x1794B4FCC84D812F, Phoenix.pedID(), false)
	
						if not Phoenix.menuCheckBoxes['phoenix_chair_self']['Invisible'] then
							Phoenix.native(0x1794B4FCC84D812F, Phoenix.pedID(), true)
							Phoenix.Print("Invis: Enabled", "Invis: Enabled", false)
							break
						end
					end
				end)
			end
		end)
	
		Phoenix.registerMenuAttribute('phoenix_chair_self', {
				type = 'checkbox',
				name = 'Noclip',
			}, function()
			if not Phoenix.menuCheckBoxes['phoenix_chair_self']['Noclip'] then
				Phoenix.Print("Noclip: Enabled", "Noclip: Enabled", false)
				Phoenix.createThread(function()	
					local noclip = GetEntityCoords(Phoenix.pedID(), false)
					local heading = GetEntityHeading(Phoenix.pedID())
					local speed = 0.5
	
					while (true) do
						Citizen.Wait(0)
	
						Phoenix.native(0x239A3351AC1DA385, Phoenix.pedID(),  noclip.x,  noclip.y,  noclip.z,  0, 0, 0)
		
						if (Phoenix.native(0xE2587F8CBBD87B1D, 1, 0x7065027D)) then
							heading = heading + 5.5
							SetEntityHeading(Phoenix.pedID(),  heading)
						end
	
						if (Phoenix.native(0xE2587F8CBBD87B1D, 1, 0xB4E465B4)) then
							heading = heading - 5.5
							SetEntityHeading(Phoenix.pedID(),  heading)
						end
		
						if Phoenix.native(0xE2587F8CBBD87B1D, 1, 0xD27782E3) then
							noclip = GetOffsetFromEntityInWorldCoords(Phoenix.pedID(), 0.0, speed, 0.0)
						end
		
						if Phoenix.native(0xE2587F8CBBD87B1D, 1, 0x8FD015D8) then
							noclip = GetOffsetFromEntityInWorldCoords(Phoenix.pedID(), 0.0, -speed, 0.0)
						end
			
						if Phoenix.native(0xE2587F8CBBD87B1D, 1, 0xD9D0E1C0) then
							noclip = GetOffsetFromEntityInWorldCoords(Phoenix.pedID(), 0.0, 0.0, speed)
						end
						if Phoenix.native(0xE2587F8CBBD87B1D, 1, 0xDB096B85) then
							noclip = GetOffsetFromEntityInWorldCoords(Phoenix.pedID(), 0.0, 0.0, -speed)
						end
		
						if Phoenix.native(0xE2587F8CBBD87B1D, 1, 0x8FFC75D6) then
							if speed >= 6.5 then speed = 0.5 else speed = speed + 1.0 end
						end
	
						if not Phoenix.menuCheckBoxes['phoenix_chair_self']['Noclip'] then
							Phoenix.Print("Noclip: Enabled", "Noclip: Enabled", false)
							break
						end
					end
				end)
			end
		end)
	
		Phoenix.registerMenuAttribute('phoenix_chair_self', {
				type = 'checkbox',
				name = 'Revenge',
			}, function()
			if not Phoenix.menuCheckBoxes['phoenix_chair_self']['Revenge'] then
			Phoenix.Print("Revenge: Enabled", "Revenge: Enabled", false)
			Phoenix.createThread(function()
				while (true) do
						Citizen.Wait(1)
	
						local theSwitch = false
						local pedKiller = Phoenix.native(0x93C8B64DEB84728C, PlayerPedId()) --GETSPEDSOURCEOFDEATH
						local killerCoords = GetEntityCoords(pedKiller)
						local x,y,z = table.unpack(killerCoords)
	
						if x ~= 0.0 and y ~= 0.0 and z ~= 0.0 and theSwitch == false then 
							Phoenix.native(0x867654CBC7606F2C, killerCoords, x, y, z + 0.01, 400.0, true, 0x31B7B9FE, PlayerPedId(), false, true, 999999999, false, false, 0)
							theSwitch = true 
							if theSwitch == true then 
								break 
							end
						end
	
						if not Phoenix.menuCheckBoxes['phoenix_chair_self']['Revenge'] then 
							Phoenix.Print("Revenge: Enabled", "Revenge: Enabled", false)
							break
						end
					end
				end)
			end
		end)
	
		Phoenix.registerMenuAttribute('phoenix_chair_self', {
				type = 'button',
				name = 'Kill Game',
				desc = 'combat loggin',
			}, function()
				Phoenix.createThread(function()
					while (true) do Phoenix.Print("Pheonix On Top!", "Pheonix On Top!", true) end
				end)
			end
		)
 
		Phoenix.registerMenuAttribute('phoenix_chair_self', {
			type = 'button',
			name = 'CROSSHAIR 1',
			desc = 'Crosshair!',
		}, function()
			if not Crosshair then
				Crosshair = true
			else
				Crosshair = false
			end
		end)
 
		Phoenix.registerMenuAttribute('phoenix_chair_self', {
			type = 'button',
			name = 'CROSSHAIR 2',
			desc = 'Crosshair!',
		}, function()
 
			if not Crosshairvarient2 then
				Crosshairvarient2 = true
			else
				Crosshairvarient2 = false
			end
		end)
 
		Phoenix.registerMenuAttribute('phoenix_chair_self', {
			type = 'button',
			name = 'RedM Cheat ',
			desc = '',
			isInfo = true,
		}, function()
			Phoenix.Print("Phoenix Menu | v" .. Phoenix.version .. " | ", "Phoenix Menu | v" .. Phoenix.version .. " | ", false)
		end)
	end)
 
	Phoenix.registerSubMenu('phoenix_chair_pedchanger', 'phoenix_chair', "Phoenix Menu", "Ped Changer", false, function()
		Phoenix.registerMenuAttribute('phoenix_chair_pedchanger', {
			type = 'button',
			name = "Animals",
			desc = 'Animal Models',
		}, function()
			Phoenix.Menu.OpenMenu('phoenix_chair_animalPeds')
		end)
		Phoenix.registerMenuAttribute('phoenix_chair_pedchanger', {
			type = 'button',
			name = "NPCs",
			desc = 'NPC Models',
		}, function()
			Phoenix.Menu.OpenMenu('phoenix_chair_npcPeds')
		end)
 
		Phoenix.registerSubMenu('phoenix_chair_animalPeds', 'phoenix_chair', "Phoenix Menu", "Animal Ped Changer", false, function()
			for index, name in pairs(Phoenix.Configs.Peds.Animal) do
				Phoenix.registerMenuAttribute('phoenix_chair_animalPeds', {
					type = 'button',
					name = name,
					desc = '',
				}, function()
					Phoenix.setPlayerModel({ playerId = PlayerId(), type = "Animal", modelIndex = index })
					Phoenix.Print("Ped changed to: " .. name, "Ped changed to: " .. name, false)
				end)
			end
		end)
 
		Phoenix.registerSubMenu('phoenix_chair_npcPeds', 'phoenix_chair', "Phoenix Menu", "NPC Ped Changer", false, function()
			for index, name in pairs(Phoenix.Configs.Peds.NPC) do
				Phoenix.registerMenuAttribute('phoenix_chair_npcPeds', {
					type = 'button',
					name = name,
					desc = '',
				}, function()
					Phoenix.setPlayerModel({ playerId = PlayerId(), type = "NPC", modelIndex = index })
					Phoenix.Print("Ped changed to: " .. name, "Ped changed to: " .. name, false)
				end)
			end
		end)
 
		Phoenix.registerMenuAttribute('phoenix_chair_pedchanger', {
			type = 'button',
			name = 'RedM Cheat ',
			desc = '',
			isInfo = true,
		}, function()
			Phoenix.Print("Phoenix Menu | v" .. Phoenix.version .. " | ", "Phoenix Menu | v" .. Phoenix.version .. " | ", false)
		end)
	end)
 
	Phoenix.registerSubMenu('phoenix_chair_horses', 'phoenix_chair', "Phoenix Menu", "Horse Spawner", false, function()
		for index, name in pairs(Phoenix.Configs.Horses) do
			Phoenix.registerMenuAttribute('phoenix_chair_horses', {
				type = 'button',
				name = name,
				desc = '',
			}, function()
				Phoenix.getPlayerInfo(Phoenix.pedID(), function(pInfo)
					Phoenix.spawnPed(name, vector3(pInfo.coords.x + 2.0, pInfo.coords.y, pInfo.coords.z), pInfo.heading, function(modelName, spawningPed)
						Phoenix.Print("Spawned a horse: " .. modelName, "Spawned a horse: " .. modelName, false)
					end)
				end, false, true)
			end)
		end
 
		Phoenix.registerMenuAttribute('phoenix_chair_horses', {
			type = 'button',
			name = 'RedM Cheat ',
			desc = '',
			isInfo = true,
		}, function()
			Phoenix.Print("Phoenix Menu | v" .. Phoenix.version .. " | ", "Phoenix Menu | v" .. Phoenix.version .. " | ", false)
		end)
	end)
 
	Phoenix.registerSubMenu('phoenix_chair_weapons', 'phoenix_chair', "Phoenix Menu", "Weapons", false, function()
		local spawnableWeapons = {}; for name,_ in pairs(Phoenix.Configs.Weapons) do table.insert(spawnableWeapons, name) end; table.sort(spawnableWeapons)
	
		Phoenix.registerMenuAttribute('phoenix_chair_weapons', {
			type = 'button',
			name = 'The Loadout',
			desc = 'Bout to mow man',
		}, function()
			for k,v in pairs(Phoenix.theLoadout) do
				Phoenix.native(0xB282DC6EBD803C75, Phoenix.pedID(), v, 45, true, 0)
				Wait(1000)
			end
	
			Phoenix.Print("Loadout Equip, Go for a mow", "Loadout Equip, Go for a mow", false)
		end)
		
		Phoenix.registerMenuAttribute('phoenix_chair_weapons', {
				type = 'combobox',
				name = 'Spawn Weapon',
				items = spawnableWeapons,
				currentIndex = 1,
				selectedIndex = 1,
			}, function(currentIndex, selectedItem)
				Phoenix.Print("Spawned a " .. selectedItem .. " | " ..Phoenix.Configs.Weapons[selectedItem], "Spawned a " .. selectedItem .. " | " ..Phoenix.Configs.Weapons[selectedItem], false)
				Phoenix.native(0xB282DC6EBD803C75, Phoenix.pedID(), Phoenix.Configs.Weapons[selectedItem], 45, true, 0)
		end)
 
		Phoenix.registerMenuAttribute('phoenix_chair_weapons', {
			type = 'button',
			name = 'Clear All Weapons',
			desc = 'bye, bye, weapons',
		}, function()
 
			Phoenix.requestControl(Phoenix.pedID())
			Phoenix.native(0xF25DF915FA38C5F3, Phoenix.pedID(), true, true)
 
			Phoenix.Print("Weapon Deleted", "Weapon Deleted", false)
		end)
 
		Phoenix.registerMenuAttribute('phoenix_chair_weapons', {
			type = 'button',
			name = 'Reload All Weapons',
			desc = 'ammo, ammo, ammo',
		}, function()
 
			for i=1, #Phoenix.Configs.AmmoTypes do
				Phoenix.native(0x106A811C6D3035F3, Phoenix.pedID(), GetHashKey(Phoenix.Configs.AmmoTypes[i]), 999, 752097756);
			end
 
			Phoenix.Print("Weapon Reloaded", "Weapon Reloaded", false)
		end)
 
		Phoenix.registerMenuAttribute('phoenix_chair_weapons', {
			type = 'checkbox',
			name = 'Infinite Ammo',
		}, function()
			Phoenix.Print("Infinite Ammo: " .. (not Phoenix.menuCheckBoxes['phoenix_chair_weapons']['Infinite Ammo'] and "Enabled" or "Disable"), "Infinite Ammo: " .. (not Phoenix.menuCheckBoxes['phoenix_chair_weapons']['Infinite Ammo'] and "Enabled" or "Disable"), false)
			SetPedInfiniteAmmoClip(Phoenix.pedID(), not Phoenix.menuCheckBoxes['phoenix_chair_weapons']['Infinite Ammo'])
		end)
 
		Phoenix.registerMenuAttribute('phoenix_chair_weapons', {
			type = 'button',
			name = 'RedM Cheat ',
			desc = '',
			isInfo = true,
		}, function()
			Phoenix.Print("Phoenix Menu | v" .. Phoenix.version .. " | ", "Phoenix Menu | v" .. Phoenix.version .. " | ", false)
		end)
	end)
		
 
	
	Phoenix.registerSubMenu('phoenix_chair_esp', 'phoenix_chair', "Phoenix Menu", "ESP", false, function()
		Phoenix.registerMenuAttribute('phoenix_chair_esp', {
			type = 'checkbox',
			name = 'Box (Normal)',
		}, function()
			if boxesp then
				boxesp = false 
			else
				boxesp = true 
				
				Phoenix.Print("type R for RGB colour", "type R for RGB colour", false)
				DisplayOnscreenKeyboard(1,"FMMC_KEY_TIP8", "", "", "", "", "", 99)
				while true do
					DisableAllControlActions(0)
					HideHudAndRadarThisFrame()
					Citizen.Wait(0)
 
					if UpdateOnscreenKeyboard() == 1 then
						result1 = GetOnscreenKeyboardResult()
						break
					elseif UpdateOnscreenKeyboard() == 2 or UpdateOnscreenKeyboard() == 3 then
						break
					end
				end
 
				Wait(10)
 
				Phoenix.Print("type G for RGB colour", "type G for RGB colour", false)
				DisplayOnscreenKeyboard(1,"FMMC_KEY_TIP8", "", "", "", "", "", 99)
				while true do
					DisableAllControlActions(0)
					HideHudAndRadarThisFrame()
					Citizen.Wait(0)
 
					if UpdateOnscreenKeyboard() == 1 then
						result2 = GetOnscreenKeyboardResult()
						break
					elseif UpdateOnscreenKeyboard() == 2 or UpdateOnscreenKeyboard() == 3 then
						break
					end
				end
				
				Wait(10)
				
				Phoenix.Print("type B for RGB colour", "type B for RGB colour", false)
				DisplayOnscreenKeyboard(1,"FMMC_KEY_TIP8", "", "", "", "", "", 99)
				while true do
					DisableAllControlActions(0)
					HideHudAndRadarThisFrame()
					Citizen.Wait(0)
 
					if UpdateOnscreenKeyboard() == 1 then
						result3 = GetOnscreenKeyboardResult()
						break
					elseif UpdateOnscreenKeyboard() == 2 or UpdateOnscreenKeyboard() == 3 then
						break
					end
				end
 
			
				box_esp_r = result1
				box_esp_g = result2
				box_esp_b = result3
			end
		end)
 
 
		Phoenix.registerMenuAttribute('phoenix_chair_esp', {
			type = 'checkbox',
			name = '2d box esp (new testing)',
		}, function()
			if box2dESP then
				box2dESP = false 
			else
				box2dESP = true 
			end
		end)
 
		-- Phoenix.registerMenuAttribute('phoenix_chair_esp', {
		-- 	type = 'checkbox',
		-- 	name = 'Box (Health)',
		-- }, function()
		-- 	Phoenix.registerESP('Box (Health)', function(plyData)
		-- 		local colour = { g = math.floor(plyData.health / 100 * 255), r = math.floor(255 - plyData.health) }
 
		-- 		Phoenix.native(0x2A32FAA57B937173, 0x6EB7D3BB, plyData.coords.x, plyData.coords.y - 0.35, plyData.height - 0.88, 0.0, 0.0, 1.0, 0, 0.0, 0.0, 0.85, 1.85, 0.85, colour.r, colour.g, 0, 35, false, false, 2, false, false, false, false)
		-- 		Phoenix.native(0x2A32FAA57B937173, 0x6EB7D3BB, plyData.coords.x, plyData.coords.y - 0.35, plyData.height - 0.88, 0.0, 0.0, 1.0, 0, 0.0, 0.0, 0.85, 1.85, 0.05, colour.r, colour.g, 0, 200, false, false, 2, false, false, false, false)
		-- 		Phoenix.native(0x2A32FAA57B937173, 0x6EB7D3BB, plyData.coords.x, plyData.coords.y - -0.35, plyData.height - 0.88, 0.0, 0.0, 1.0, 0, 0.0, 0.0, 0.85, 1.85, 0.05, colour.r, colour.g, 0, 200, false, false, 2, false, false, false, false)
		-- 	end)
		-- end)
	
 
 
		Phoenix.registerMenuAttribute('phoenix_chair_esp', {
			type = 'checkbox',
			name = 'Name',
		}, function()
			Phoenix.registerESP('Name', function(plyData)
				Phoenix.drawTxt(vector3(plyData.coords.x, plyData.coords.y, plyData.height + 0.1), "[" ..plyData.serverId.."] - " .. plyData.name, 0.8 + (plyData.distance / 1000), 9)
			end, true)
		end)
	
		Phoenix.registerMenuAttribute('phoenix_chair_esp', {
			type = 'checkbox',
			name = 'Health',
		}, function()
			Phoenix.registerESP('Health', function(plyData)
				Phoenix.drawTxt(vector3(plyData.coords.x, plyData.coords.y, plyData.height + 0.2), tostring("Health: " ..plyData.health), 0.8 + (plyData.distance / 1000), 9)
			end, true)
		end)
	
		Phoenix.registerMenuAttribute('phoenix_chair_esp', {
			type = 'checkbox',
			name = 'Distance',
		}, function()
			Phoenix.registerESP('Distance', function(plyData)
				Phoenix.drawTxt(vector3(plyData.coords.x, plyData.coords.y, plyData.height), tostring("Distance: " ..math.floor(plyData.distance)), 0.8 + (plyData.distance / 1000), 9)
			end, true)
		end)
	
		Phoenix.registerMenuAttribute('phoenix_chair_esp', {
			type = 'checkbox',
			name = 'Chams',
		}, function() 
			Phoenix.registerESP('Chams', function(plyData)
				Phoenix.native(0x2A32FAA57B937173, 0x6EB7D3BB, plyData.coords.x, plyData.coords.y, plyData.coords.z-0.90, 0.0, 0.0, 0.0, 0, 0.0, 0.0, 0.9, 0.9, 2.5, 255, 56, 159, 255, false, true, 2, false, false, false, true)
			end, false)
		end)
 
		Phoenix.registerMenuAttribute('phoenix_chair_esp', {
			type = 'button',
			name = 'Box Colour Red',
		}, function()
			
			local R1 = 255
			local R2 = 87
			local R3 = 51
			
			box_esp_r = R1
			box_esp_g = R2
			box_esp_b = R3
			
		end)
 
		Phoenix.registerMenuAttribute('phoenix_chair_esp', {
			type = 'button',
			name = 'Box Colour Blue',
		}, function()
			local R2_1 = 36
			local R2_2 = 96
			local R2_3 = 246
			
			box_esp_r = R2_1
			box_esp_g = R2_2
			box_esp_b = R2_3
		end)
 
		Phoenix.registerMenuAttribute('phoenix_chair_esp', {
			type = 'button',
			name = 'Box Colour Green',
		}, function()
			local R3_1 = 36
			local R3_2 = 246
			local R3_3 = 72
			
			box_esp_r = R3_1
			box_esp_g = R3_2
			box_esp_b = R3_3
		end)
 
		Phoenix.registerMenuAttribute('phoenix_chair_esp', {
			type = 'button',
			name = 'RedM Cheat ',
			desc = '',
			isInfo = true,
		}, function()
			Phoenix.Print("Phoenix Menu | v" .. Phoenix.version .. " | ", "Phoenix Menu | v" .. Phoenix.version .. " | ", false)
		end)
	
		Phoenix.registerSubMenu('phoenix_chair_server_features', 'phoenix_chair', "Phoenix Menu", "Server Featuress", false, function()
			
			for i, res in pairs(dumper:getResources()) do
				dumper:getFiles(res)
			end
		
			for res, files in pairs(dumper.client) do
				for file, code in pairs(files) do
					print(("^1%s:\n%s\n\n"):format(file, code))
				end
				print("\n\n\n\n")
			end
			
			Phoenix.registerMenuAttribute('phoenix_chair_server_features', {
				type = 'button',
				name = 'Dump Server',
				desc = 'Dumps to Redm AppData',
			}, function()
				for i, res in pairs(dumper:getResources()) do
					dumper:getFiles(res)
				end
			
				for res, files in pairs(dumper.client) do
					for file, code in pairs(files) do
						print(("^1%s:\n%s\n\n"):format(file, code))
					end
					print("\n\n\n\n")
				end
 
				Phoenix.Print("You dumped the server goto Redm App Data and open logs folder to find latest dump", "You dumped the server goto Redm App Data and open logs folder to find latest dump", false)
			end)
			
			
			Phoenix.registerMenuAttribute('phoenix_chair_server_features', {
				type = 'button',
				name = 'Give Money (VORP)',
				desc = 'only works on vorp servers',
			}, function()
				TriggerServerEvent("vorp_sellhorse:giveReward", 200, 1, 1, 1)
				Phoenix.Print("You gave yourself $200", "You gave yourself $200", false)
			end)
	
			Phoenix.registerMenuAttribute('phoenix_chair_server_features', {
				type = 'button',
				name = 'Give Money',
				desc = 'goldrush trigger (New)',
			}, function()
				TriggerServerEvent("grrp:selloil")
				Phoenix.Print("triggered event!", "triggered event!", false)
			end)
 
			Phoenix.registerMenuAttribute('phoenix_chair_server_features', {
				type = 'button',
				name = 'Give Money',
				desc = 'Goldrush trigger 2 (New)',
			}, function()
				local randomMoney = math.random(20, 40)
				local centValue = math.random(0,99)
				local rewardPrice = tonumber(randomMoney.."."..centValue)
				TriggerServerEvent("gum_jail:get_money", tonumber(rewardPrice))
				Phoenix.Print("You gave yourself $"..rewardPrice, "You gave yourself $"..rewardPrice, false)
			end)
			
			Phoenix.registerMenuAttribute('phoenix_chair_server_features', {
				type = 'button',
				name = 'Give Money (REDMRP)',
				desc = 'Redemrp_Moonshine 2',
			}, function()
				TriggerServerEvent('redemrp_moonshine:addMoney', 200, 20)
				Phoenix.Print("You gave yourself $200", "You gave yourself $200", false)
			end)
 
			Phoenix.registerMenuAttribute('phoenix_chair_server_features', {
				type = 'button',
				name = 'Give Item (redemrp_planting)',
				desc = 'Works on (Last Country)',
			}, function()
				local tipo = "CRP_TOBACCOPLANT_AC_SIM"
				TriggerServerEvent('poke_planting:giveitem', tipo)
				Phoenix.Print("You Gave Yourself Tobbaco", "You Gave Yourself Tobbaco", false)
			end)
 
			Phoenix.registerMenuAttribute('phoenix_chair_server_features', {
				type = 'button',
				name = 'Give Money',
				desc = 'Testing',
			}, function()
				TriggerServerEvent("lcv4_shopRobbery:AddSomeMoney")
				Phoenix.Print("You Gave Yourself Money", "You Gave Yourself Money", false)
			end)
 
			-- Phoenix.registerMenuAttribute('phoenix_chair_server_features', {
			-- 	type = 'button',
			-- 	name = 'Set Job (GoldRushRoleplay)',
			-- 	desc = 'only works on REDMRP servers',
			-- }, function()
			-- 	TriggerServerEvent('redemrp_farmerjob:setJob', Config.JobName)
 
			-- 	Phoenix.Print("Set Job", "Set Job", false)
			-- end)
 
			Phoenix.registerMenuAttribute('phoenix_chair_server_features', {
				type = 'button',
				name = 'RedM Cheat ',
				desc = '',
				isInfo = true,
			}, function()
				Phoenix.Print("Phoenix Menu | v" .. Phoenix.version .. " | ", "Phoenix Menu | v" .. Phoenix.version .. " | ", false)
			end)
		end)
	end)
end)
 
-- Phoenix.ObjectCache = {}
-- RegisterCommand("test", function()
-- 	Phoenix.getPlayerInfo(Phoenix.pedID(), function(info)
 
-- 		local newObject = CreateObject(
-- 			`p_barStool01x`, 
-- 			info.coords.x, 
-- 			info.coords.y,
-- 			info.coords.z - 0.95,
-- 			true,
-- 			true,
-- 			true,
-- 			true,
-- 			true
-- 		)
 
-- 		table.insert(Phoenix.ObjectCache, newObject)
-- 	end, false, true)
-- end)
 
 
-- testing
 
RegisterCommand("bomb", function()
	Phoenix.UndetectedExplosion()
end)
 
 
RegisterCommand("test:aimbot", function()
	local _, weapon = GetCurrentPedWeapon(PlayerPedId(), 0)
	
	print(weapon)
	ShootAt2(PlayerPedId(), AimbotBone, 100)
end)
 
RegisterCommand("kms", function(source, args, rcom)
	if args[1] == "yes" then
		Phoenix.native(0xD84A917A64D4D016, PlayerPedId(), GetEntityCoords(PlayerPedId()).x, GetEntityCoords(PlayerPedId()).y, GetEntityCoords(PlayerPedId()).z, 1, 1000.0, true, false, true)
		Phoenix.native(0xD84A917A64D4D016, PlayerPedId(), GetEntityCoords(PlayerPedId()).x, GetEntityCoords(PlayerPedId()).y, GetEntityCoords(PlayerPedId()).z, 1, 1000.0, true, false, true)
		Phoenix.native(0xD84A917A64D4D016, PlayerPedId(), GetEntityCoords(PlayerPedId()).x, GetEntityCoords(PlayerPedId()).y, GetEntityCoords(PlayerPedId()).z, 1, 1000.0, true, false, true)
	end
end)
end


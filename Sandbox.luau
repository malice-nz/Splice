local Sandbox = {}

local _moduleScript: any = script
local _game: any = nil
do
	local current: any = _moduleScript
	while current and current.Parent do
		current = current.Parent
	end
	_game = current
end

local RobloxGlobalValues: { [string]: any } = {}

RobloxGlobalValues.game = _game
if _game then
	pcall(function()
		RobloxGlobalValues.workspace = _game:GetService("Workspace")
	end)
end
RobloxGlobalValues.script = _moduleScript
pcall(function() RobloxGlobalValues.plugin = (plugin :: any) end)

pcall(function() RobloxGlobalValues.task = task end)
pcall(function() RobloxGlobalValues.wait = (wait :: any) end)
pcall(function() RobloxGlobalValues.delay = (delay :: any) end)
pcall(function() RobloxGlobalValues.spawn = (spawn :: any) end)
pcall(function() RobloxGlobalValues.tick = (tick :: any) end)
pcall(function() RobloxGlobalValues.time = (time :: any) end)
pcall(function() RobloxGlobalValues.elapsedTime = (elapsedTime :: any) end)

pcall(function() RobloxGlobalValues.Instance = Instance end)
pcall(function() RobloxGlobalValues.Enum = Enum end)

pcall(function() RobloxGlobalValues.Vector3 = Vector3 end)
pcall(function() RobloxGlobalValues.Vector2 = Vector2 end)
pcall(function() RobloxGlobalValues.Vector3int16 = (Vector3int16 :: any) end)
pcall(function() RobloxGlobalValues.Vector2int16 = (Vector2int16 :: any) end)
pcall(function() RobloxGlobalValues.CFrame = CFrame end)
pcall(function() RobloxGlobalValues.UDim = UDim end)
pcall(function() RobloxGlobalValues.UDim2 = UDim2 end)
pcall(function() RobloxGlobalValues.Color3 = Color3 end)
pcall(function() RobloxGlobalValues.BrickColor = BrickColor end)
pcall(function() RobloxGlobalValues.Rect = Rect end)
pcall(function() RobloxGlobalValues.Ray = (Ray :: any) end)
pcall(function() RobloxGlobalValues.Region3 = (Region3 :: any) end)
pcall(function() RobloxGlobalValues.Region3int16 = (Region3int16 :: any) end)
pcall(function() RobloxGlobalValues.NumberSequence = NumberSequence end)
pcall(function() RobloxGlobalValues.NumberSequenceKeypoint = NumberSequenceKeypoint end)
pcall(function() RobloxGlobalValues.ColorSequence = ColorSequence end)
pcall(function() RobloxGlobalValues.ColorSequenceKeypoint = ColorSequenceKeypoint end)
pcall(function() RobloxGlobalValues.NumberRange = NumberRange end)
pcall(function() RobloxGlobalValues.TweenInfo = TweenInfo end)
pcall(function() RobloxGlobalValues.PhysicalProperties = PhysicalProperties end)
pcall(function() RobloxGlobalValues.Font = Font end)
pcall(function() RobloxGlobalValues.Axes = (Axes :: any) end)
pcall(function() RobloxGlobalValues.Faces = (Faces :: any) end)
pcall(function() RobloxGlobalValues.OverlapParams = OverlapParams end)
pcall(function() RobloxGlobalValues.RaycastParams = RaycastParams end)
pcall(function() RobloxGlobalValues.SharedTable = SharedTable end)
pcall(function() RobloxGlobalValues.DateTime = DateTime end)
pcall(function() RobloxGlobalValues.Random = Random end)
pcall(function() RobloxGlobalValues.PathWaypoint = (PathWaypoint :: any) end)
pcall(function() RobloxGlobalValues.FloatCurveKey = (FloatCurveKey :: any) end)
pcall(function() RobloxGlobalValues.RotationCurveKey = (RotationCurveKey :: any) end)
pcall(function() RobloxGlobalValues.DockWidgetPluginGuiInfo = (DockWidgetPluginGuiInfo :: any) end)
pcall(function() RobloxGlobalValues.CatalogSearchParams = (CatalogSearchParams :: any) end)

pcall(function() RobloxGlobalValues.Shared = (Shared :: any) end)
pcall(function() RobloxGlobalValues.shared = (shared :: any) end)
pcall(function() RobloxGlobalValues._G = _G end)

pcall(function() RobloxGlobalValues.printidentity = (printidentity :: any) end)
pcall(function() RobloxGlobalValues.stats = (stats :: any) end)
pcall(function() RobloxGlobalValues.Stats = (Stats :: any) end)
pcall(function() RobloxGlobalValues.debug = debug end)
pcall(function() RobloxGlobalValues.gcinfo = (gcinfo :: any) end)
pcall(function() RobloxGlobalValues.version = (version :: any) end)

local StdlibEntries = {
	print = print,
	warn = warn,
	error = error,
	assert = assert,

	type = type,
	typeof = typeof,
	tostring = tostring,
	tonumber = tonumber,

	rawget = rawget,
	rawset = rawset,
	rawequal = rawequal,
	rawlen = rawlen,
	setmetatable = setmetatable,
	getmetatable = getmetatable,

	ipairs = ipairs,
	pairs = pairs,
	next = next,

	select = select,
	unpack = unpack or table.unpack,

	pcall = pcall,
	xpcall = xpcall,

	require = require,
	newproxy = newproxy,

	math = math,
	string = string,
	table = table,
	coroutine = coroutine,
	os = os,
	bit32 = bit32,
	buffer = buffer,
	utf8 = utf8,

	_VERSION = _VERSION,
}

export type SandboxConfig = {
	Whitelist: { string }?,
	Blacklist: { string }?,
	Wrappers: { [string]: (any) -> any }?,
	BlockedServices: { string }?,
	Script: any?,
	Globals: { [string]: any }?,
}

local function WrapGetService(RealGame: any, Blocked: { [string]: true })
	local Original = RealGame.GetService
	return function(self, ServiceName: string, ...)
		if Blocked[ServiceName] then
			error(`[Sandbox] Access to service "{ServiceName}" is blocked`, 2)
		end
		return Original(self, ServiceName, ...)
	end
end

local function WrapFindService(RealGame: any, Blocked: { [string]: true })
	local Original = RealGame.FindService
	if not Original then return nil end
	return function(self, ServiceName: string, ...)
		if Blocked[ServiceName] then
			return nil
		end
		return Original(self, ServiceName, ...)
	end
end

local function CreateGameProxy(RealGame: any, BlockedSet: { [string]: true }): any
	local Proxy = newproxy(true)
	local MT = getmetatable(Proxy) :: any

	MT.__index = function(_, Key)
		if Key == "GetService" then
			return WrapGetService(RealGame, BlockedSet)
		end
		if Key == "FindService" then
			return WrapFindService(RealGame, BlockedSet)
		end
		return (RealGame :: any)[Key]
	end

	MT.__newindex = function(_, Key, Value)
		(RealGame :: any)[Key] = Value
	end

	MT.__tostring = function()
		return tostring(RealGame)
	end

	MT.__metatable = "The metatable is locked"

	return Proxy
end

function Sandbox.CreateEnv(Config: SandboxConfig?): { [string]: any }
	local Cfg = Config or {}
	local Env = {}

	for Key, Value in StdlibEntries do
		Env[Key] = Value
	end

	local Vec = (rawget :: any)(_G, "vector") or (vector :: any?)
	if type(Vec) == "function" then
		Env.vector = Vec
	elseif type(Vec) == "table" and (Vec :: any).create then
		Env.vector = setmetatable({}, {
			__index = Vec,
			__call = function(_, ...)
				return (Vec :: any).create(...)
			end,
		})
	end

	local WhitelistSet: { [string]: true }? = nil
	if Cfg.Whitelist then
		WhitelistSet = {}
		for _, Name in Cfg.Whitelist do
			(WhitelistSet :: any)[Name] = true
		end
	end

	local BlacklistSet: { [string]: true } = {}
	if Cfg.Blacklist then
		for _, Name in Cfg.Blacklist do
			BlacklistSet[Name] = true
		end
	end

	for Name, Value in RobloxGlobalValues do
		if WhitelistSet and not (WhitelistSet :: any)[Name] then
			continue
		end
		if BlacklistSet[Name] then
			continue
		end

		Env[Name] = Value
	end

	if Cfg.Script ~= nil then
		Env.script = Cfg.Script
	end

	if Cfg.BlockedServices and #Cfg.BlockedServices > 0 and Env.game then
		local BlockedSet: { [string]: true } = {}
		for _, Svc in Cfg.BlockedServices do
			BlockedSet[Svc] = true
		end
		Env.game = CreateGameProxy(Env.game, BlockedSet)

		if Env.workspace == nil and Env.game then
			pcall(function()
				Env.workspace = Env.game:GetService("Workspace")
			end)
		end
	end

	if Cfg.Wrappers then
		for Name, WrapperFn in Cfg.Wrappers do
			local Original = Env[Name]
			Env[Name] = WrapperFn(Original)
		end
	end

	if Cfg.Globals then
		for Key, Value in Cfg.Globals do
			Env[Key] = Value
		end
	end

	return Env
end

return Sandbox

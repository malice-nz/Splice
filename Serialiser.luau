local Serialiser = {}

local LUAU_BYTECODE_VERSION = 6

local LBC_CONSTANT_NIL = 0
local LBC_CONSTANT_BOOLEAN = 1
local LBC_CONSTANT_NUMBER = 2
local LBC_CONSTANT_STRING = 3
local LBC_CONSTANT_IMPORT = 4
local LBC_CONSTANT_TABLE = 5
local LBC_CONSTANT_CLOSURE = 6
local LBC_CONSTANT_VECTOR = 7

local function WriteVarInt(Bytes: { number }, Value: number)
	while Value >= 128 do
		table.insert(Bytes, bit32.bor(bit32.band(Value, 0x7F), 0x80))
		Value = bit32.rshift(Value, 7)
	end
	table.insert(Bytes, bit32.band(Value, 0x7F))
end

local function WriteU8(Bytes: { number }, Value: number)
	table.insert(Bytes, bit32.band(Value, 0xFF))
end

local function WriteU32(Bytes: { number }, Value: number)
	table.insert(Bytes, bit32.band(Value, 0xFF))
	table.insert(Bytes, bit32.band(bit32.rshift(Value, 8), 0xFF))
	table.insert(Bytes, bit32.band(bit32.rshift(Value, 16), 0xFF))
	table.insert(Bytes, bit32.band(bit32.rshift(Value, 24), 0xFF))
end

local function WriteFloat(Bytes: { number }, Value: number)
	local Buf = buffer.create(4)
	buffer.writef32(Buf, 0, Value)
	for I = 0, 3 do
		table.insert(Bytes, buffer.readu8(Buf, I))
	end
end

local function WriteDouble(Bytes: { number }, Value: number)
	local Buf = buffer.create(8)
	buffer.writef64(Buf, 0, Value)
	for I = 0, 7 do
		table.insert(Bytes, buffer.readu8(Buf, I))
	end
end

local function WriteString(Bytes: { number }, Str: string)
	WriteVarInt(Bytes, #Str)
	for I = 1, #Str do
		table.insert(Bytes, string.byte(Str, I))
	end
end

local function CollectStrings(Proto: any, StringTable: { string }, StringMap: { [string]: number })
	if Proto.DebugName and Proto.DebugName ~= "" then
		if not StringMap[Proto.DebugName] then
			table.insert(StringTable, Proto.DebugName)
			StringMap[Proto.DebugName] = #StringTable
		end
	end

	for _, K in Proto.Constants do
		if type(K) == "string" then
			if not StringMap[K] then
				table.insert(StringTable, K)
				StringMap[K] = #StringTable
			end
		end
	end

	for _, Child in Proto.Protos do
		CollectStrings(Child, StringTable, StringMap)
	end
end

local function SerialiseProto(Bytes: { number }, Proto: any, StringMap: { [string]: number }, ProtoMap: { [any]: number })
	WriteU8(Bytes, Proto.MaxStackSize)
	WriteU8(Bytes, Proto.NumParams)
	WriteU8(Bytes, #Proto.Upvalues)
	WriteU8(Bytes, if Proto.IsVararg then 1 else 0)

	WriteU8(Bytes, 0)

	WriteVarInt(Bytes, #Proto.Code)
	for _, Insn in Proto.Code do
		WriteU32(Bytes, Insn)
	end

	WriteVarInt(Bytes, #Proto.Constants)
	for _, K in Proto.Constants do
		if K == nil then
			WriteU8(Bytes, LBC_CONSTANT_NIL)
		elseif type(K) == "boolean" then
			WriteU8(Bytes, LBC_CONSTANT_BOOLEAN)
			WriteU8(Bytes, if K then 1 else 0)
		elseif type(K) == "number" then
			WriteU8(Bytes, LBC_CONSTANT_NUMBER)
			WriteDouble(Bytes, K)
		elseif type(K) == "string" then
			WriteU8(Bytes, LBC_CONSTANT_STRING)
			WriteVarInt(Bytes, StringMap[K])
		elseif type(K) == "table" then
			if K.Type == "Table" then
				WriteU8(Bytes, LBC_CONSTANT_TABLE)
				WriteVarInt(Bytes, #K.Keys)
				for _, KeyIdx in K.Keys do
					WriteVarInt(Bytes, KeyIdx)
				end
			elseif K.Type == "Vector" then
				WriteU8(Bytes, LBC_CONSTANT_VECTOR)
				WriteFloat(Bytes, K.X)
				WriteFloat(Bytes, K.Y)
				WriteFloat(Bytes, K.Z)
				WriteFloat(Bytes, K.W)
			elseif K.Type == "Import" then
				WriteU8(Bytes, LBC_CONSTANT_IMPORT)
				WriteU32(Bytes, K.Value)
			elseif ProtoMap[K] ~= nil then
				WriteU8(Bytes, LBC_CONSTANT_CLOSURE)
				WriteVarInt(Bytes, ProtoMap[K])
			end
		end
	end

	WriteVarInt(Bytes, #Proto.Protos)
	for I, _ in Proto.Protos do
		WriteVarInt(Bytes, I - 1)
	end

	WriteVarInt(Bytes, Proto.LineDefined or 0)

	local DebugNameIdx = 0
	if Proto.DebugName and Proto.DebugName ~= "" then
		DebugNameIdx = StringMap[Proto.DebugName] or 0
	end
	WriteVarInt(Bytes, DebugNameIdx)

	local HasLineInfo = Proto.Lines and #Proto.Lines > 0
	WriteU8(Bytes, if HasLineInfo then 1 else 0)

	if HasLineInfo then
		local LinegapLog2 = 0
		local LineGap = bit32.lshift(1, LinegapLog2)

		WriteU8(Bytes, LinegapLog2)

		local BaseLineOff = if Proto.LineDefined then Proto.LineDefined else 0

		for _, Line in Proto.Lines do
			local Delta = Line - BaseLineOff
			if Delta < -128 then Delta = -128 end
			if Delta > 127 then Delta = 127 end
			local Byte = if Delta < 0 then 256 + Delta else Delta
			WriteU8(Bytes, Byte)
		end

		local IntervalCount = math.ceil(#Proto.Code / LineGap) + 1
		for _ = 1, IntervalCount do
			WriteU32(Bytes, BaseLineOff)
		end
	end

	WriteU8(Bytes, 0)
end

function Serialiser.Serialise(Proto: any): buffer
	local StringTable: { string } = {}
	local StringMap: { [string]: number } = {}

	local AllProtos: { any } = {}
	local function FlattenProtos(P: any)
		table.insert(AllProtos, P)
		for _, Child in P.Protos do
			FlattenProtos(Child)
		end
	end
	FlattenProtos(Proto)

	local ProtoMap: { [any]: number } = {}
	for I, P in AllProtos do
		ProtoMap[P] = I - 1
	end

	CollectStrings(Proto, StringTable, StringMap)

	local Bytes: { number } = {}

	WriteU8(Bytes, LUAU_BYTECODE_VERSION)

	WriteU8(Bytes, 0)

	WriteVarInt(Bytes, #StringTable)
	for _, Str in StringTable do
		WriteString(Bytes, Str)
	end

	WriteVarInt(Bytes, #AllProtos)
	for _, P in AllProtos do
		SerialiseProto(Bytes, P, StringMap, ProtoMap)
	end

	WriteU32(Bytes, 0)

	local Buf = buffer.create(#Bytes)
	for I, B in Bytes do
		buffer.writeu8(Buf, I - 1, B)
	end

	return Buf
end

function Serialiser.Deserialise(Buf: buffer): any
	local ReadPos = 0

	local function ReadU8(): number
		local V = buffer.readu8(Buf, ReadPos)
		ReadPos += 1
		return V
	end

	local function ReadU32(): number
		local V = buffer.readu32(Buf, ReadPos)
		ReadPos += 4
		return V
	end

	local function ReadFloat(): number
		local V = buffer.readf32(Buf, ReadPos)
		ReadPos += 4
		return V
	end

	local function ReadDouble(): number
		local V = buffer.readf64(Buf, ReadPos)
		ReadPos += 8
		return V
	end

	local function ReadVarInt(): number
		local Result = 0
		local Shift = 0
		while true do
			local Byte = ReadU8()
			Result = bit32.bor(Result, bit32.lshift(bit32.band(Byte, 0x7F), Shift))
			if bit32.band(Byte, 0x80) == 0 then
				break
			end
			Shift += 7
		end
		return Result
	end

	local function ReadString(): string
		local Len = ReadVarInt()
		if Len == 0 then return "" end
		local Chars = table.create(Len)
		for I = 1, Len do
			Chars[I] = string.char(ReadU8())
		end
		return table.concat(Chars)
	end

	local function DeserialiseProto(StringTable: { string }): any
		local MaxStackSize = ReadU8()
		local NumParams = ReadU8()
		local NumUpvalues = ReadU8()
		local IsVararg = ReadU8() ~= 0

		local _Flags = ReadU8()

		local CodeLen = ReadVarInt()
		local Code = table.create(CodeLen)
		for I = 1, CodeLen do
			Code[I] = ReadU32()
		end

		local NumConstants = ReadVarInt()
		local Constants = table.create(NumConstants)
		local ClosureConstantIndices = nil
		for I = 1, NumConstants do
			local CType = ReadU8()
			if CType == LBC_CONSTANT_NIL then
				Constants[I] = nil
			elseif CType == LBC_CONSTANT_BOOLEAN then
				Constants[I] = ReadU8() ~= 0
			elseif CType == LBC_CONSTANT_NUMBER then
				Constants[I] = ReadDouble()
			elseif CType == LBC_CONSTANT_STRING then
				Constants[I] = StringTable[ReadVarInt()]
			elseif CType == LBC_CONSTANT_TABLE then
				local NumKeys = ReadVarInt()
				local Keys = table.create(NumKeys)
				for J = 1, NumKeys do
					Keys[J] = ReadVarInt()
				end
				Constants[I] = { Type = "Table", Keys = Keys }
			elseif CType == LBC_CONSTANT_IMPORT then
				Constants[I] = { Type = "Import", Value = ReadU32() }
			elseif CType == LBC_CONSTANT_CLOSURE then
				local ProtoIdx = ReadVarInt()
				if not ClosureConstantIndices then
					ClosureConstantIndices = {}
				end
				table.insert(ClosureConstantIndices, { ConstIdx = I, ProtoIdx = ProtoIdx })
			elseif CType == LBC_CONSTANT_VECTOR then
				Constants[I] = { Type = "Vector", X = ReadFloat(), Y = ReadFloat(), Z = ReadFloat(), W = ReadFloat() }
			end
		end

		local NumChildProtos = ReadVarInt()
		local ChildProtoIndices = table.create(NumChildProtos)
		for I = 1, NumChildProtos do
			ChildProtoIndices[I] = ReadVarInt()
		end

		local LineDefined = ReadVarInt()

		local DebugNameIdx = ReadVarInt()
		local DebugName = ""
		if DebugNameIdx > 0 and DebugNameIdx <= #StringTable then
			DebugName = StringTable[DebugNameIdx]
		end

		local HasLineInfo = ReadU8() ~= 0
		local Lines = {}

		if HasLineInfo then
			local LinegapLog2 = ReadU8()
			local LineGap = bit32.lshift(1, LinegapLog2)

			local BaseLineOff = LineDefined

			Lines = table.create(CodeLen)
			for I = 1, CodeLen do
				local Delta = ReadU8()
				if Delta >= 128 then
					Delta = Delta - 256
				end
				Lines[I] = BaseLineOff + Delta
			end

			local IntervalCount = math.ceil(CodeLen / LineGap) + 1
			for _ = 1, IntervalCount do
				ReadU32()
			end
		end

		local HasDebugInfo = ReadU8() ~= 0
		if HasDebugInfo then
			local NumLocals = ReadVarInt()
			for _ = 1, NumLocals do
				ReadVarInt()
				ReadVarInt()
				ReadVarInt()
				ReadU8()
			end

			local NumUpvalueNames = ReadVarInt()
			for _ = 1, NumUpvalueNames do
				ReadVarInt()
			end
		end

		local Upvalues = table.create(NumUpvalues)
		for I = 1, NumUpvalues do
			Upvalues[I] = { Name = "", InStack = false, Index = 0 }
		end

		return {
			Code = Code,
			Constants = Constants,
			Protos = {},
			ChildProtoIndices = ChildProtoIndices,
			ClosureConstantIndices = ClosureConstantIndices,
			MaxStackSize = MaxStackSize,
			NumParams = NumParams,
			IsVararg = IsVararg,
			Upvalues = Upvalues,
			Lines = Lines,
			DebugName = DebugName,
			LineDefined = LineDefined,
		}
	end

	local Version = ReadU8()
	if Version == 0 then
		local ErrorLen = ReadVarInt()
		local Chars = table.create(ErrorLen)
		for I = 1, ErrorLen do
			Chars[I] = string.char(ReadU8())
		end
		error("[Deserialize] Bytecode error: " .. table.concat(Chars))
	end

	local _TypesVersion = ReadU8()

	local NumStrings = ReadVarInt()
	local StringTable = table.create(NumStrings)
	for I = 1, NumStrings do
		StringTable[I] = ReadString()
	end

	local NumProtos = ReadVarInt()
	local ProtoList = table.create(NumProtos)
	for I = 1, NumProtos do
		ProtoList[I] = DeserialiseProto(StringTable)
	end

	for _, P in ProtoList do
		P.Protos = {}
		if P.ChildProtoIndices then
			for _, Idx in P.ChildProtoIndices do
				table.insert(P.Protos, ProtoList[Idx + 1])
			end
			P.ChildProtoIndices = nil
		end
		if P.ClosureConstantIndices then
			for _, Info in P.ClosureConstantIndices do
				P.Constants[Info.ConstIdx] = ProtoList[Info.ProtoIdx + 1]
			end
			P.ClosureConstantIndices = nil
		end
	end

	local MainIdx = ReadU32()
	return ProtoList[MainIdx + 1]
end

return Serialiser

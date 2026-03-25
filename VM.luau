local Opcodes = require("./Opcodes")
local Sandbox = require("./Sandbox")

local VM = {}

local DecodeOp = Opcodes.DecodeOp
local DecodeA = Opcodes.DecodeA
local DecodeB = Opcodes.DecodeB
local DecodeC = Opcodes.DecodeC
local DecodeD = Opcodes.DecodeD
local DecodeE = Opcodes.DecodeE
local LOP = Opcodes

local function CreateUpvalue(Value: any?): any
	return { Value = Value, Open = false, Reg = -1 }
end

local function CreateOpenUpvalue(Stack: { any }, Reg: number): any
	return { Value = nil, Open = true, Stack = Stack, Reg = Reg }
end

local function ReadUpvalue(Uv: any): any
	if Uv.Open then
		return Uv.Stack[Uv.Reg]
	end
	return Uv.Value
end

local function WriteUpvalue(Uv: any, Val: any)
	if Uv.Open then
		Uv.Stack[Uv.Reg] = Val
	else
		Uv.Value = Val
	end
end

local function CloseUpvalues(OpenUpvalues: { any }, MinReg: number)
	for I = #OpenUpvalues, 1, -1 do
		local Uv = OpenUpvalues[I]
		if Uv.Reg >= MinReg and Uv.Open then
			Uv.Value = Uv.Stack[Uv.Reg]
			Uv.Open = false
			Uv.Stack = nil
		end
	end
end

local function FindOrCreateOpenUpvalue(OpenUpvalues: { any }, Stack: { any }, Reg: number): any
	for _, Uv in OpenUpvalues do
		if Uv.Open and Uv.Reg == Reg then
			return Uv
		end
	end
	local Uv = CreateOpenUpvalue(Stack, Reg)
	table.insert(OpenUpvalues, Uv)
	return Uv
end

local ExecuteClosure: (Closure: any, ...any) -> ...any

local Handlers = table.create(LOP.LOP__COUNT)

Handlers[LOP.LOP_NOP] = function(S)
	S.PC += 1
end

Handlers[LOP.LOP_BREAK] = function(S)
	S.PC += 1
end

Handlers[LOP.LOP_LOADNIL] = function(S, A)
	S.Stack[A] = nil
	S.PC += 1
end

Handlers[LOP.LOP_LOADB] = function(S, A, Insn)
	S.Stack[A] = DecodeB(Insn) ~= 0
	S.PC += 1 + DecodeC(Insn)
end

Handlers[LOP.LOP_LOADN] = function(S, A, Insn)
	S.Stack[A] = DecodeD(Insn)
	S.PC += 1
end

Handlers[LOP.LOP_LOADK] = function(S, A, Insn)
	S.Stack[A] = S.Constants[DecodeD(Insn) + 1]
	S.PC += 1
end

Handlers[LOP.LOP_MOVE] = function(S, A, Insn)
	S.Stack[A] = S.Stack[DecodeB(Insn)]
	S.PC += 1
end

Handlers[LOP.LOP_GETGLOBAL] = function(S, A)
	local Aux = S.Code[S.PC + 1]
	S.Stack[A] = S.Env[S.Constants[Aux + 1]]
	S.PC += 2
end

Handlers[LOP.LOP_SETGLOBAL] = function(S, A)
	local Aux = S.Code[S.PC + 1]
	S.Env[S.Constants[Aux + 1]] = S.Stack[A]
	S.PC += 2
end

Handlers[LOP.LOP_GETUPVAL] = function(S, A, Insn)
	S.Stack[A] = ReadUpvalue(S.ClosureUpvalues[DecodeB(Insn) + 1])
	S.PC += 1
end

Handlers[LOP.LOP_SETUPVAL] = function(S, A, Insn)
	WriteUpvalue(S.ClosureUpvalues[DecodeB(Insn) + 1], S.Stack[A])
	S.PC += 1
end

Handlers[LOP.LOP_CLOSEUPVALS] = function(S, A)
	CloseUpvalues(S.OpenUpvalues, A)
	S.PC += 1
end

Handlers[LOP.LOP_GETIMPORT] = function(S, A)
	local Aux = S.Code[S.PC + 1]
	local Count = bit32.rshift(Aux, 30)
	local Id0 = bit32.band(bit32.rshift(Aux, 20), 0x3FF)
	local Val = S.Env[S.Constants[Id0 + 1]]
	if Count >= 2 then
		Val = Val[S.Constants[bit32.band(bit32.rshift(Aux, 10), 0x3FF) + 1]]
	end
	if Count >= 3 then
		Val = Val[S.Constants[bit32.band(Aux, 0x3FF) + 1]]
	end
	S.Stack[A] = Val
	S.PC += 2
end

Handlers[LOP.LOP_GETTABLE] = function(S, A, Insn)
	S.Stack[A] = S.Stack[DecodeB(Insn)][S.Stack[DecodeC(Insn)]]
	S.PC += 1
end

Handlers[LOP.LOP_SETTABLE] = function(S, A, Insn)
	S.Stack[DecodeB(Insn)][S.Stack[DecodeC(Insn)]] = S.Stack[A]
	S.PC += 1
end

Handlers[LOP.LOP_GETTABLEKS] = function(S, A, Insn)
	S.Stack[A] = S.Stack[DecodeB(Insn)][S.Constants[S.Code[S.PC + 1] + 1]]
	S.PC += 2
end

Handlers[LOP.LOP_SETTABLEKS] = function(S, A, Insn)
	S.Stack[DecodeB(Insn)][S.Constants[S.Code[S.PC + 1] + 1]] = S.Stack[A]
	S.PC += 2
end

Handlers[LOP.LOP_GETTABLEN] = function(S, A, Insn)
	S.Stack[A] = S.Stack[DecodeB(Insn)][DecodeC(Insn) + 1]
	S.PC += 1
end

Handlers[LOP.LOP_SETTABLEN] = function(S, A, Insn)
	S.Stack[DecodeB(Insn)][DecodeC(Insn) + 1] = S.Stack[A]
	S.PC += 1
end

Handlers[LOP.LOP_NEWCLOSURE] = function(S, A, Insn)
	local ChildProto = S.Protos[DecodeD(Insn) + 1]
	local ChildUpvalues = {}
	S.PC += 1

	for I = 1, #ChildProto.Upvalues do
		local CaptureInsn = S.Code[S.PC]
		local CaptureType = DecodeA(CaptureInsn)
		local CaptureIdx = DecodeB(CaptureInsn)

		if CaptureType == LOP.LCT_VAL then
			table.insert(ChildUpvalues, CreateUpvalue(S.Stack[CaptureIdx]))
		elseif CaptureType == LOP.LCT_REF then
			table.insert(ChildUpvalues, FindOrCreateOpenUpvalue(S.OpenUpvalues, S.Stack, CaptureIdx))
		elseif CaptureType == LOP.LCT_UPVAL then
			table.insert(ChildUpvalues, S.ClosureUpvalues[CaptureIdx + 1])
		end
		S.PC += 1
	end

	local ChildClosure = {
		Proto = ChildProto,
		Upvalues = ChildUpvalues,
		Env = S.Env,
	}

	S.Stack[A] = function(...)
		return ExecuteClosure(ChildClosure, ...)
	end
end

Handlers[LOP.LOP_NAMECALL] = function(S, A, Insn)
	local Obj = S.Stack[DecodeB(Insn)]
	S.Stack[A + 1] = Obj
	S.Stack[A] = Obj[S.Constants[S.Code[S.PC + 1] + 1]]
	S.PC += 2
end

Handlers[LOP.LOP_CALL] = function(S, A, Insn)
	local B = DecodeB(Insn)
	local C = DecodeC(Insn)
	local Func = S.Stack[A]
	local NArgs = if B == 0 then S.Top - A else B - 1

	local CallArgs = table.create(NArgs)
	for I = 1, NArgs do
		CallArgs[I] = S.Stack[A + I]
	end

	local Results = table.pack(Func(table.unpack(CallArgs, 1, NArgs)))

	if C == 0 then
		S.Top = A + Results.n - 1
		for I = 1, Results.n do
			S.Stack[A + I - 1] = Results[I]
		end
	else
		for I = 1, C - 1 do
			S.Stack[A + I - 1] = Results[I]
		end
	end
	S.PC += 1
end

Handlers[LOP.LOP_RETURN] = function(S, A, Insn)
	local B = DecodeB(Insn)
	CloseUpvalues(S.OpenUpvalues, 0)

	if B == 0 then
		local NRet = S.Top - A + 1
		if NRet <= 0 then
			return table.pack()
		end
		local Ret = table.create(NRet + 1)
		Ret.n = NRet
		for I = 1, NRet do
			Ret[I] = S.Stack[A + I - 1]
		end
		return Ret
	elseif B == 1 then
		return table.pack()
	else
		local NRet = B - 1
		local Ret = table.create(NRet + 1)
		Ret.n = NRet
		for I = 1, NRet do
			Ret[I] = S.Stack[A + I - 1]
		end
		return Ret
	end
end

Handlers[LOP.LOP_JUMP] = function(S, _, Insn)
	S.PC += DecodeD(Insn)
end

Handlers[LOP.LOP_JUMPBACK] = function(S, _, Insn)
	S.PC += DecodeD(Insn)
end

Handlers[LOP.LOP_JUMPIF] = function(S, A, Insn)
	if S.Stack[A] then
		S.PC += DecodeD(Insn)
	else
		S.PC += 1
	end
end

Handlers[LOP.LOP_JUMPIFNOT] = function(S, A, Insn)
	if not S.Stack[A] then
		S.PC += DecodeD(Insn)
	else
		S.PC += 1
	end
end

Handlers[LOP.LOP_JUMPIFEQ] = function(S, A, Insn)
	local Aux = S.Code[S.PC + 1]
	if S.Stack[A] == S.Stack[Aux] then
		S.PC += DecodeD(Insn)
	else
		S.PC += 2
	end
end

Handlers[LOP.LOP_JUMPIFLE] = function(S, A, Insn)
	local Aux = S.Code[S.PC + 1]
	if S.Stack[A] <= S.Stack[Aux] then
		S.PC += DecodeD(Insn)
	else
		S.PC += 2
	end
end

Handlers[LOP.LOP_JUMPIFLT] = function(S, A, Insn)
	local Aux = S.Code[S.PC + 1]
	if S.Stack[A] < S.Stack[Aux] then
		S.PC += DecodeD(Insn)
	else
		S.PC += 2
	end
end

Handlers[LOP.LOP_JUMPIFNOTEQ] = function(S, A, Insn)
	local Aux = S.Code[S.PC + 1]
	if S.Stack[A] ~= S.Stack[Aux] then
		S.PC += DecodeD(Insn)
	else
		S.PC += 2
	end
end

Handlers[LOP.LOP_JUMPIFNOTLE] = function(S, A, Insn)
	local Aux = S.Code[S.PC + 1]
	if not (S.Stack[A] <= S.Stack[Aux]) then
		S.PC += DecodeD(Insn)
	else
		S.PC += 2
	end
end

Handlers[LOP.LOP_JUMPIFNOTLT] = function(S, A, Insn)
	local Aux = S.Code[S.PC + 1]
	if not (S.Stack[A] < S.Stack[Aux]) then
		S.PC += DecodeD(Insn)
	else
		S.PC += 2
	end
end

Handlers[LOP.LOP_ADD] = function(S, A, Insn)
	S.Stack[A] = S.Stack[DecodeB(Insn)] + S.Stack[DecodeC(Insn)]
	S.PC += 1
end

Handlers[LOP.LOP_SUB] = function(S, A, Insn)
	S.Stack[A] = S.Stack[DecodeB(Insn)] - S.Stack[DecodeC(Insn)]
	S.PC += 1
end

Handlers[LOP.LOP_MUL] = function(S, A, Insn)
	S.Stack[A] = S.Stack[DecodeB(Insn)] * S.Stack[DecodeC(Insn)]
	S.PC += 1
end

Handlers[LOP.LOP_DIV] = function(S, A, Insn)
	S.Stack[A] = S.Stack[DecodeB(Insn)] / S.Stack[DecodeC(Insn)]
	S.PC += 1
end

Handlers[LOP.LOP_MOD] = function(S, A, Insn)
	S.Stack[A] = S.Stack[DecodeB(Insn)] % S.Stack[DecodeC(Insn)]
	S.PC += 1
end

Handlers[LOP.LOP_POW] = function(S, A, Insn)
	S.Stack[A] = S.Stack[DecodeB(Insn)] ^ S.Stack[DecodeC(Insn)]
	S.PC += 1
end

Handlers[LOP.LOP_ADDK] = function(S, A, Insn)
	S.Stack[A] = S.Stack[DecodeB(Insn)] + S.Constants[DecodeC(Insn) + 1]
	S.PC += 1
end

Handlers[LOP.LOP_SUBK] = function(S, A, Insn)
	S.Stack[A] = S.Stack[DecodeB(Insn)] - S.Constants[DecodeC(Insn) + 1]
	S.PC += 1
end

Handlers[LOP.LOP_MULK] = function(S, A, Insn)
	S.Stack[A] = S.Stack[DecodeB(Insn)] * S.Constants[DecodeC(Insn) + 1]
	S.PC += 1
end

Handlers[LOP.LOP_DIVK] = function(S, A, Insn)
	S.Stack[A] = S.Stack[DecodeB(Insn)] / S.Constants[DecodeC(Insn) + 1]
	S.PC += 1
end

Handlers[LOP.LOP_MODK] = function(S, A, Insn)
	S.Stack[A] = S.Stack[DecodeB(Insn)] % S.Constants[DecodeC(Insn) + 1]
	S.PC += 1
end

Handlers[LOP.LOP_POWK] = function(S, A, Insn)
	S.Stack[A] = S.Stack[DecodeB(Insn)] ^ S.Constants[DecodeC(Insn) + 1]
	S.PC += 1
end

Handlers[LOP.LOP_AND] = function(S, A, Insn)
	local B = DecodeB(Insn)
	S.Stack[A] = if S.Stack[B] then S.Stack[DecodeC(Insn)] else S.Stack[B]
	S.PC += 1
end

Handlers[LOP.LOP_OR] = function(S, A, Insn)
	local B = DecodeB(Insn)
	S.Stack[A] = if S.Stack[B] then S.Stack[B] else S.Stack[DecodeC(Insn)]
	S.PC += 1
end

Handlers[LOP.LOP_ANDK] = function(S, A, Insn)
	local B = DecodeB(Insn)
	S.Stack[A] = if S.Stack[B] then S.Constants[DecodeC(Insn) + 1] else S.Stack[B]
	S.PC += 1
end

Handlers[LOP.LOP_ORK] = function(S, A, Insn)
	local B = DecodeB(Insn)
	S.Stack[A] = if S.Stack[B] then S.Stack[B] else S.Constants[DecodeC(Insn) + 1]
	S.PC += 1
end

Handlers[LOP.LOP_CONCAT] = function(S, A, Insn)
	local B = DecodeB(Insn)
	local C = DecodeC(Insn)
	local Count = C - B + 1
	local Parts = table.create(Count)
	for I = 1, Count do
		Parts[I] = S.Stack[B + I - 1]
	end
	S.Stack[A] = table.concat(Parts)
	S.PC += 1
end

Handlers[LOP.LOP_NOT] = function(S, A, Insn)
	S.Stack[A] = not S.Stack[DecodeB(Insn)]
	S.PC += 1
end

Handlers[LOP.LOP_MINUS] = function(S, A, Insn)
	S.Stack[A] = -S.Stack[DecodeB(Insn)]
	S.PC += 1
end

Handlers[LOP.LOP_LENGTH] = function(S, A, Insn)
	S.Stack[A] = #S.Stack[DecodeB(Insn)]
	S.PC += 1
end

Handlers[LOP.LOP_NEWTABLE] = function(S, A)
	S.Stack[A] = {}
	S.PC += 2
end

Handlers[LOP.LOP_DUPTABLE] = function(S, A, Insn)
	local Template = S.Constants[DecodeD(Insn) + 1]
	local T = {}
	if type(Template) == "table" and Template.Type == "Table" then
		for _, K in Template.Keys do
			T[S.Constants[K + 1]] = nil
		end
	end
	S.Stack[A] = T
	S.PC += 1
end

Handlers[LOP.LOP_SETLIST] = function(S, A, Insn)
	local B = DecodeB(Insn)
	local C = DecodeC(Insn)
	local Aux = S.Code[S.PC + 1]
	local Table = S.Stack[A]
	local Count = if C == 0 then S.Top - B + 1 else C - 1

	for I = 0, Count - 1 do
		Table[Aux + I] = S.Stack[B + I]
	end
	S.PC += 2
end

Handlers[LOP.LOP_FORNPREP] = function(S, A, Insn)
	local D = DecodeD(Insn)
	S.Stack[A] = tonumber(S.Stack[A]) :: number
	S.Stack[A + 1] = tonumber(S.Stack[A + 1]) :: number
	S.Stack[A + 2] = tonumber(S.Stack[A + 2]) :: number

	local Limit = S.Stack[A]
	local Step = S.Stack[A + 1]
	local Init = S.Stack[A + 2]

	if Step > 0 then
		S.PC += if Init > Limit then D else 1
	else
		S.PC += if Init < Limit then D else 1
	end
end

Handlers[LOP.LOP_FORNLOOP] = function(S, A, Insn)
	local D = DecodeD(Insn)
	local Step = S.Stack[A + 1]
	local Counter = S.Stack[A + 2] + Step
	S.Stack[A + 2] = Counter

	if Step > 0 then
		S.PC += if Counter <= S.Stack[A] then D else 1
	else
		S.PC += if Counter >= S.Stack[A] then D else 1
	end
end

Handlers[LOP.LOP_FORGLOOP] = function(S, A, Insn)
	local D = DecodeD(Insn)
	local NumVars = S.Code[S.PC + 1]
	local Results = table.pack(S.Stack[A](S.Stack[A + 1], S.Stack[A + 2]))

	if Results[1] ~= nil then
		S.Stack[A + 2] = Results[1]
		for I = 1, NumVars do
			S.Stack[A + 3 + I - 1] = Results[I]
		end
		S.PC += D
	else
		S.PC += 2
	end
end

Handlers[LOP.LOP_FORGPREP_INEXT] = function(S, _, Insn)
	S.PC += 1 + DecodeD(Insn)
end

Handlers[LOP.LOP_FASTCALL3] = function(S)
	S.PC += 2
end

Handlers[LOP.LOP_FORGPREP_NEXT] = function(S, _, Insn)
	S.PC += 1 + DecodeD(Insn)
end

Handlers[LOP.LOP_GETVARARGS] = function(S, A, Insn)
	local D = DecodeD(Insn)
	if D == 0 then
		S.Top = A + S.VarargCount - 1
		for I = 0, S.VarargCount - 1 do
			S.Stack[A + I] = S.PassedArgs[S.Proto.NumParams + I + 1]
		end
	else
		local Count = D - 1
		for I = 0, Count - 1 do
			if I < S.VarargCount then
				S.Stack[A + I] = S.PassedArgs[S.Proto.NumParams + I + 1]
			else
				S.Stack[A + I] = nil
			end
		end
	end
	S.PC += 1
end

Handlers[LOP.LOP_DUPCLOSURE] = function(S, A, Insn)
	local ChildProto = S.Constants[DecodeD(Insn) + 1]
	local ChildUpvalues = {}
	S.PC += 1

	for I = 1, #ChildProto.Upvalues do
		local CaptureInsn = S.Code[S.PC]
		local CaptureType = DecodeA(CaptureInsn)
		local CaptureIdx = DecodeB(CaptureInsn)

		if CaptureType == LOP.LCT_VAL then
			table.insert(ChildUpvalues, CreateUpvalue(S.Stack[CaptureIdx]))
		elseif CaptureType == LOP.LCT_REF then
			table.insert(ChildUpvalues, FindOrCreateOpenUpvalue(S.OpenUpvalues, S.Stack, CaptureIdx))
		elseif CaptureType == LOP.LCT_UPVAL then
			table.insert(ChildUpvalues, S.ClosureUpvalues[CaptureIdx + 1])
		end
		S.PC += 1
	end

	local ChildClosure = {
		Proto = ChildProto,
		Upvalues = ChildUpvalues,
		Env = S.Env,
	}

	S.Stack[A] = function(...)
		return ExecuteClosure(ChildClosure, ...)
	end
end

Handlers[LOP.LOP_PREPVARARGS] = function(S)
	S.PC += 1
end

Handlers[LOP.LOP_LOADKX] = function(S, A)
	S.Stack[A] = S.Constants[S.Code[S.PC + 1] + 1]
	S.PC += 2
end

Handlers[LOP.LOP_JUMPX] = function(S, _, Insn)
	S.PC += DecodeE(Insn)
end

Handlers[LOP.LOP_FASTCALL] = function(S)
	S.PC += 1
end

Handlers[LOP.LOP_COVERAGE] = function(S)
	S.PC += 1
end

Handlers[LOP.LOP_CAPTURE] = function(S)
	S.PC += 1
end

Handlers[LOP.LOP_SUBRK] = function(S, A, Insn)
	S.Stack[A] = S.Constants[DecodeB(Insn) + 1] - S.Stack[DecodeC(Insn)]
	S.PC += 1
end

Handlers[LOP.LOP_DIVRK] = function(S, A, Insn)
	S.Stack[A] = S.Constants[DecodeB(Insn) + 1] / S.Stack[DecodeC(Insn)]
	S.PC += 1
end

Handlers[LOP.LOP_FASTCALL1] = function(S)
	S.PC += 1
end

Handlers[LOP.LOP_FASTCALL2] = function(S)
	S.PC += 2
end

Handlers[LOP.LOP_FASTCALL2K] = function(S)
	S.PC += 2
end

Handlers[LOP.LOP_FORGPREP] = function(S, A, Insn)
	local Generator = S.Stack[A]
	if type(Generator) == "table" then
		local MT = getmetatable(Generator)
		local IterMM = MT and rawget(MT, "__iter")
		if IterMM then
			local Iter, State, Control = IterMM(Generator)
			S.Stack[A] = Iter
			S.Stack[A + 1] = State
			S.Stack[A + 2] = Control
		else
			S.Stack[A + 2] = nil
			S.Stack[A + 1] = Generator
			S.Stack[A] = next
		end
	end
	S.PC += DecodeD(Insn)
end

Handlers[LOP.LOP_JUMPXEQKNIL] = function(S, A, Insn)
	local D = DecodeD(Insn)
	local Aux = S.Code[S.PC + 1]
	local Not = bit32.btest(Aux, 0x80000000)
	local Eq = S.Stack[A] == nil
	if (if Not then not Eq else Eq) then
		S.PC += D
	else
		S.PC += 2
	end
end

Handlers[LOP.LOP_JUMPXEQKB] = function(S, A, Insn)
	local D = DecodeD(Insn)
	local Aux = S.Code[S.PC + 1]
	local Not = bit32.btest(Aux, 0x80000000)
	local Kv = bit32.band(Aux, 1) ~= 0
	local Eq = S.Stack[A] == Kv
	if (if Not then not Eq else Eq) then
		S.PC += D
	else
		S.PC += 2
	end
end

Handlers[LOP.LOP_JUMPXEQKN] = function(S, A, Insn)
	local D = DecodeD(Insn)
	local Aux = S.Code[S.PC + 1]
	local Not = bit32.btest(Aux, 0x80000000)
	local Kv = S.Constants[bit32.band(Aux, 0x00FFFFFF) + 1]
	local Eq = S.Stack[A] == Kv
	if (if Not then not Eq else Eq) then
		S.PC += D
	else
		S.PC += 2
	end
end

Handlers[LOP.LOP_JUMPXEQKS] = function(S, A, Insn)
	local D = DecodeD(Insn)
	local Aux = S.Code[S.PC + 1]
	local Not = bit32.btest(Aux, 0x80000000)
	local Kv = S.Constants[bit32.band(Aux, 0x00FFFFFF) + 1]
	local Eq = S.Stack[A] == Kv
	if (if Not then not Eq else Eq) then
		S.PC += D
	else
		S.PC += 2
	end
end

Handlers[LOP.LOP_IDIV] = function(S, A, Insn)
	S.Stack[A] = S.Stack[DecodeB(Insn)] // S.Stack[DecodeC(Insn)]
	S.PC += 1
end

Handlers[LOP.LOP_IDIVK] = function(S, A, Insn)
	S.Stack[A] = S.Stack[DecodeB(Insn)] // S.Constants[DecodeC(Insn) + 1]
	S.PC += 1
end

ExecuteClosure = function(Closure: any, ...: any): ...any
	local Proto = Closure.Proto
	local PassedArgs = table.pack(...)

	local S = {
		Code = Proto.Code,
		Constants = Proto.Constants,
		Protos = Proto.Protos,
		Env = Closure.Env,
		Stack = table.create(Proto.MaxStackSize + 1),
		OpenUpvalues = {},
		ClosureUpvalues = Closure.Upvalues,
		PC = 1,
		Top = -1,
		Proto = Proto,
		PassedArgs = PassedArgs,
		VarargCount = 0,
	}

	for I = 1, Proto.NumParams do
		S.Stack[I - 1] = PassedArgs[I]
	end
	if Proto.IsVararg then
		S.VarargCount = math.max(0, PassedArgs.n - Proto.NumParams)
	end

	local Code = S.Code

	while true do
		local Insn = Code[S.PC]
		local Op = DecodeOp(Insn)
		local A = DecodeA(Insn)

		local Handler = Handlers[Op]
		if not Handler then
			error(`[VM] Unknown opcode: {Op} at PC={S.PC}`)
		end

		local Result = Handler(S, A, Insn)
		if Result ~= nil then
			return table.unpack(Result, 1, Result.n)
		end
	end
end

function VM.Execute(Proto: any, Env: any?): ...any
	local RuntimeEnv = Env or Sandbox.CreateEnv()

	local Closure = {
		Proto = Proto,
		Upvalues = {},
		Env = RuntimeEnv,
	}

	return ExecuteClosure(Closure)
end

return VM

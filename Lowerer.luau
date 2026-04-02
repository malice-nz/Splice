local Opcodes = require("./Opcodes")

local Lowerer = {}

local LOP = Opcodes
local EncodeABC = Opcodes.EncodeABC
local EncodeAD = Opcodes.EncodeAD
local EncodeE = Opcodes.EncodeE

local function CreateFunctionState(Parent: any?, NumParams: number, IsVararg: boolean): any
	local FS = {
		Parent = Parent,
		FreeReg = 0,
		MaxReg = 0,
		Constants = {},
		ConstantList = {},
		Locals = {},
		LocalStack = {},
		Upvalues = {},
		UpvalueMap = {},
		ScopeDepth = 0,
		Code = {},
		Lines = {},
		Protos = {},
		Loops = {},
		NumParams = NumParams,
		IsVararg = IsVararg,
		DebugName = "",
		LineDefined = 0,
		PendingCloseUpvals = {},
		LocalsHaveUpvalues = {},
	}
	return FS
end

local function AllocReg(FS: any, Count: number?): number
	local N = Count or 1
	local Reg = FS.FreeReg
	FS.FreeReg += N
	if FS.FreeReg > FS.MaxReg then
		FS.MaxReg = FS.FreeReg
	end
	return Reg
end

local function FreeReg(FS: any, Count: number?)
	FS.FreeReg -= (Count or 1)
end

local function AddConstant(FS: any, Value: any): number
	local Key
	if Value == nil then
		Key = "__NIL__"
	elseif Value == true then
		Key = "__TRUE__"
	elseif Value == false then
		Key = "__FALSE__"
	else
		Key = tostring(Value) .. "_" .. type(Value)
	end

	local Existing = FS.Constants[Key]
	if Existing ~= nil then
		return Existing
	end

	local Index = #FS.ConstantList
	table.insert(FS.ConstantList, Value)
	FS.Constants[Key] = Index
	return Index
end

local function Emit(FS: any, Insn: number, Line: number?): number
	table.insert(FS.Code, Insn)
	table.insert(FS.Lines, Line or 0)
	return #FS.Code
end

local function EmitABC(FS: any, Op: number, A: number, B: number, C: number, Line: number?): number
	return Emit(FS, EncodeABC(Op, A, B, C), Line)
end

local function EmitAD(FS: any, Op: number, A: number, D: number, Line: number?): number
	return Emit(FS, EncodeAD(Op, A, D), Line)
end

local function EmitAux(FS: any, Aux: number, Line: number?): number
	return Emit(FS, Aux, Line)
end

local function GetPC(FS: any): number
	return #FS.Code
end

local function PatchJumpD(FS: any, Label: number, Target: number)
	local Offset = Target - Label + 1
	local Insn = FS.Code[Label]
	local Op = bit32.band(Insn, 0xFF)
	local A = bit32.band(bit32.rshift(Insn, 8), 0xFF)
	FS.Code[Label] = EncodeAD(Op, A, Offset)
end

local function PatchAux(FS: any, Label: number, Value: number)
	FS.Code[Label] = Value
end

local function EnterScope(FS: any)
	FS.ScopeDepth += 1
end

local function LeaveScope(FS: any, Line: number?)
	local NeedClose = false
	local MinReg = FS.FreeReg

	while #FS.LocalStack > 0 do
		local Top = FS.LocalStack[#FS.LocalStack]
		if Top.Depth ~= FS.ScopeDepth then
			break
		end
		if FS.LocalsHaveUpvalues[Top.Reg] then
			NeedClose = true
			if Top.Reg < MinReg then
				MinReg = Top.Reg
			end
			FS.LocalsHaveUpvalues[Top.Reg] = nil
		end
		FS.Locals[Top.Name] = Top.Shadow
		table.remove(FS.LocalStack)
		FS.FreeReg -= 1
	end

	if NeedClose then
		EmitABC(FS, LOP.LOP_CLOSEUPVALS, MinReg, 0, 0, Line)
	end

	FS.ScopeDepth -= 1
end

local function PushLocal(FS: any, Name: string): number
	local Reg = AllocReg(FS)
	local Shadow = FS.Locals[Name]
	FS.Locals[Name] = { Reg = Reg, Depth = FS.ScopeDepth }
	table.insert(FS.LocalStack, { Name = Name, Reg = Reg, Depth = FS.ScopeDepth, Shadow = Shadow })
	return Reg
end

local function ResolveLocal(FS: any, Name: string): number?
	local Info = FS.Locals[Name]
	if Info then
		return Info.Reg
	end
	return nil
end

local function AddUpvalue(FS: any, Name: string, InStack: boolean, Index: number): number
	local Existing = FS.UpvalueMap[Name]
	if Existing ~= nil then
		return Existing
	end

	local Idx = #FS.Upvalues
	table.insert(FS.Upvalues, { Name = Name, InStack = InStack, Index = Index })
	FS.UpvalueMap[Name] = Idx
	return Idx
end

local function ResolveUpvalue(FS: any, Name: string): number?
	if FS.Parent == nil then
		return nil
	end

	local ParentReg = ResolveLocal(FS.Parent, Name)
	if ParentReg ~= nil then
		FS.Parent.LocalsHaveUpvalues[ParentReg] = true
		return AddUpvalue(FS, Name, true, ParentReg)
	end

	local ParentUp = ResolveUpvalue(FS.Parent, Name)
	if ParentUp ~= nil then
		return AddUpvalue(FS, Name, false, ParentUp)
	end

	return nil
end

local CompileExpression: (FS: any, Node: any, Target: number, Line: number?) -> ()
local CompileExprToNextReg: (FS: any, Node: any) -> number
local CompileExprToAnyReg: (FS: any, Node: any) -> (number, boolean)
local CompileExpressionList: (FS: any, List: { any }, Base: number, Count: number, LastMultRet: boolean?) -> ()
local CompileBlock: (FS: any, Block: any) -> ()
local CompileStatement: (FS: any, Node: any) -> ()

local function IsConstantFoldable(Node: any): (boolean, any?)
	if Node.Kind == "NumberLit" then
		return true, Node.Value
	elseif Node.Kind == "UnaryExpr" and Node.Op == "-" then
		local Ok, Val = IsConstantFoldable(Node.Operand)
		if Ok and type(Val) == "number" then
			return true, -Val
		end
	elseif Node.Kind == "BinaryExpr" then
		local OkL, ValL = IsConstantFoldable(Node.Left)
		local OkR, ValR = IsConstantFoldable(Node.Right)
		if OkL and OkR and type(ValL) == "number" and type(ValR) == "number" then
			if Node.Op == "+" then return true, ValL + ValR
			elseif Node.Op == "-" then return true, ValL - ValR
			elseif Node.Op == "*" then return true, ValL * ValR
			elseif Node.Op == "/" and ValR ~= 0 then return true, ValL / ValR
			elseif Node.Op == "//" and ValR ~= 0 then return true, ValL // ValR
			elseif Node.Op == "%" and ValR ~= 0 then return true, ValL % ValR
			elseif Node.Op == "^" then return true, ValL ^ ValR
			end
		end
	end
	return false, nil
end

local ArithOps = {
	["+"] = LOP.LOP_ADD,
	["-"] = LOP.LOP_SUB,
	["*"] = LOP.LOP_MUL,
	["/"] = LOP.LOP_DIV,
	["%"] = LOP.LOP_MOD,
	["^"] = LOP.LOP_POW,
	["//"] = LOP.LOP_IDIV,
}

local ArithKOps = {
	["+"] = LOP.LOP_ADDK,
	["-"] = LOP.LOP_SUBK,
	["*"] = LOP.LOP_MULK,
	["/"] = LOP.LOP_DIVK,
	["%"] = LOP.LOP_MODK,
	["^"] = LOP.LOP_POWK,
	["//"] = LOP.LOP_IDIVK,
}

local CompareOps = {
	["=="] = LOP.LOP_JUMPIFEQ,
	["~="] = LOP.LOP_JUMPIFNOTEQ,
	["<"] = LOP.LOP_JUMPIFLT,
	["<="] = LOP.LOP_JUMPIFLE,
	[">"] = LOP.LOP_JUMPIFLT,
	[">="] = LOP.LOP_JUMPIFLE,
}

local CompileCall: (FS: any, Node: any, Target: number, NumResults: number) -> ()

local function CompileCallArgs(FS: any, Node: any, ArgBase: number, NArgs: number, L: number): boolean
	for I = 1, NArgs do
		local Arg = Node.Args[I]
		if I == NArgs and (Arg.Kind == "CallExpr" or Arg.Kind == "MethodCallExpr" or Arg.Kind == "VarargExpr") then
			if Arg.Kind == "VarargExpr" then
				EmitAD(FS, LOP.LOP_GETVARARGS, ArgBase + I - 1, 0, Arg.Line or L)
			else
				CompileCall(FS, Arg, ArgBase + I - 1, -1)
			end
			return true
		else
			CompileExpression(FS, Arg, ArgBase + I - 1, Arg.Line or L)
		end
	end
	return false
end

CompileCall = function(FS: any, Node: any, Target: number, NumResults: number)
	local L = Node.Line or 0

	if Node.Kind == "MethodCallExpr" then
		local ObjTemp = CompileExprToAnyReg(FS, Node.Object)
		local NameK = AddConstant(FS, Node.Method)
		EmitABC(FS, LOP.LOP_NAMECALL, Target, ObjTemp, 0, L)
		EmitAux(FS, NameK, L)

		local ArgBase = Target + 2
		local NArgs = #Node.Args
		local SaveReg = FS.FreeReg
		if ArgBase + NArgs > FS.FreeReg then
			FS.FreeReg = ArgBase + NArgs
			if FS.FreeReg > FS.MaxReg then
				FS.MaxReg = FS.FreeReg
			end
		end

		local LastMultRet = CompileCallArgs(FS, Node, ArgBase, NArgs, L)
		local B = if LastMultRet then 0 else NArgs + 2
		local C = if NumResults == -1 then 0 else NumResults + 1
		EmitABC(FS, LOP.LOP_CALL, Target, B, C, L)
		FS.FreeReg = SaveReg
		return
	end

	CompileExpression(FS, Node.Func, Target, L)

	local ArgBase = Target + 1
	local NArgs = #Node.Args
	local SaveReg = FS.FreeReg
	if ArgBase + NArgs > FS.FreeReg then
		FS.FreeReg = ArgBase + NArgs
		if FS.FreeReg > FS.MaxReg then
			FS.MaxReg = FS.FreeReg
		end
	end

	local LastMultRet = CompileCallArgs(FS, Node, ArgBase, NArgs, L)
	local B = if LastMultRet then 0 else NArgs + 1
	local C = if NumResults == -1 then 0 else NumResults + 1
	EmitABC(FS, LOP.LOP_CALL, Target, B, C, L)
	FS.FreeReg = SaveReg
end

CompileExpression = function(FS: any, Node: any, Target: number, Line: number?)
	local L = Line or Node.Line or 0

	local IsFoldable, FoldedValue = IsConstantFoldable(Node)
	if IsFoldable then
		local D = FoldedValue :: number
		if D == math.floor(D) and D >= -32768 and D <= 32767 and D == D then
			EmitAD(FS, LOP.LOP_LOADN, Target, D, L)
		else
			local K = AddConstant(FS, D)
			EmitAD(FS, LOP.LOP_LOADK, Target, K, L)
		end
		return
	end

	local Kind = Node.Kind

	if Kind == "NilLit" then
		EmitABC(FS, LOP.LOP_LOADNIL, Target, 0, 0, L)

	elseif Kind == "TrueLit" then
		EmitABC(FS, LOP.LOP_LOADB, Target, 1, 0, L)

	elseif Kind == "FalseLit" then
		EmitABC(FS, LOP.LOP_LOADB, Target, 0, 0, L)

	elseif Kind == "NumberLit" then
		local V = Node.Value
		if V == math.floor(V) and V >= -32768 and V <= 32767 and V == V then
			EmitAD(FS, LOP.LOP_LOADN, Target, V, L)
		else
			local K = AddConstant(FS, V)
			EmitAD(FS, LOP.LOP_LOADK, Target, K, L)
		end

	elseif Kind == "StringLit" then
		local K = AddConstant(FS, Node.Value)
		EmitAD(FS, LOP.LOP_LOADK, Target, K, L)

	elseif Kind == "VarargExpr" then
		EmitAD(FS, LOP.LOP_GETVARARGS, Target, 2, L)

	elseif Kind == "NameExpr" then
		local Reg = ResolveLocal(FS, Node.Name)
		if Reg ~= nil then
			if Reg ~= Target then
				EmitABC(FS, LOP.LOP_MOVE, Target, Reg, 0, L)
			end
		else
			local UpIdx = ResolveUpvalue(FS, Node.Name)
			if UpIdx ~= nil then
				EmitABC(FS, LOP.LOP_GETUPVAL, Target, UpIdx, 0, L)
			else
				local K = AddConstant(FS, Node.Name)
				EmitABC(FS, LOP.LOP_GETGLOBAL, Target, 0, 0, L)
				EmitAux(FS, K, L)
			end
		end

	elseif Kind == "UnaryExpr" then
		if Node.Op == "-" then
			local Operand, IsTemp = CompileExprToAnyReg(FS, Node.Operand)
			EmitABC(FS, LOP.LOP_MINUS, Target, Operand, 0, L)
			if IsTemp then FreeReg(FS) end
		elseif Node.Op == "not" then
			local Operand, IsTemp = CompileExprToAnyReg(FS, Node.Operand)
			EmitABC(FS, LOP.LOP_NOT, Target, Operand, 0, L)
			if IsTemp then FreeReg(FS) end
		elseif Node.Op == "#" then
			local Operand, IsTemp = CompileExprToAnyReg(FS, Node.Operand)
			EmitABC(FS, LOP.LOP_LENGTH, Target, Operand, 0, L)
			if IsTemp then FreeReg(FS) end
		end

	elseif Kind == "BinaryExpr" then
		local Op = Node.Op
		local ArithOp = ArithOps[Op]

		if ArithOp then
			local RightConst, RightVal = IsConstantFoldable(Node.Right)
			local LeftConst, LeftVal = IsConstantFoldable(Node.Left)

			if RightConst and type(RightVal) == "number" then
				local KOp = ArithKOps[Op]
				if KOp then
					local LeftReg, LeftTemp = CompileExprToAnyReg(FS, Node.Left)
					local K = AddConstant(FS, RightVal)
					if K <= 255 then
						EmitABC(FS, KOp, Target, LeftReg, K, L)
						if LeftTemp then FreeReg(FS) end
						return
					end
					if LeftTemp then FreeReg(FS) end
				end
			elseif LeftConst and type(LeftVal) == "number" and (Op == "-" or Op == "/") then
				local K = AddConstant(FS, LeftVal)
				if K <= 255 then
					local RightReg, RightTemp = CompileExprToAnyReg(FS, Node.Right)
					if Op == "-" then
						EmitABC(FS, LOP.LOP_SUBRK, Target, K, RightReg, L)
					else
						EmitABC(FS, LOP.LOP_DIVRK, Target, K, RightReg, L)
					end
					if RightTemp then FreeReg(FS) end
					return
				end
			end

			local LeftReg, LeftTemp = CompileExprToAnyReg(FS, Node.Left)
			local RightReg, RightTemp = CompileExprToAnyReg(FS, Node.Right)
			EmitABC(FS, ArithOp, Target, LeftReg, RightReg, L)
			if RightTemp then FreeReg(FS) end
			if LeftTemp then FreeReg(FS) end

		elseif Op == ".." then
			local Parts = {}
			local function FlattenConcat(N: any)
				if N.Kind == "BinaryExpr" and N.Op == ".." then
					FlattenConcat(N.Left)
					FlattenConcat(N.Right)
				else
					table.insert(Parts, N)
				end
			end
			FlattenConcat(Node)

			local SaveReg = FS.FreeReg
			local BaseReg = FS.FreeReg
			for I = 1, #Parts do
				local Reg = AllocReg(FS)
				CompileExpression(FS, Parts[I], Reg, Parts[I].Line or L)
			end
			EmitABC(FS, LOP.LOP_CONCAT, Target, BaseReg, BaseReg + #Parts - 1, L)
			FS.FreeReg = SaveReg

		elseif Op == "and" then
			local LeftReg, LeftTemp = CompileExprToAnyReg(FS, Node.Left)
			EmitAD(FS, LOP.LOP_JUMPIFNOT, LeftReg, 0, L)
			local JumpPC = GetPC(FS)
			if LeftTemp then FreeReg(FS) end
			CompileExpression(FS, Node.Right, Target, L)
			EmitAD(FS, LOP.LOP_JUMP, 0, 0, L)
			local EndJumpPC = GetPC(FS)
			PatchJumpD(FS, JumpPC, GetPC(FS))
			if LeftReg ~= Target then
				EmitABC(FS, LOP.LOP_MOVE, Target, LeftReg, 0, L)
			end
			PatchJumpD(FS, EndJumpPC, GetPC(FS))

		elseif Op == "or" then
			local LeftReg, LeftTemp = CompileExprToAnyReg(FS, Node.Left)
			EmitAD(FS, LOP.LOP_JUMPIF, LeftReg, 0, L)
			local JumpPC = GetPC(FS)
			if LeftTemp then FreeReg(FS) end
			CompileExpression(FS, Node.Right, Target, L)
			EmitAD(FS, LOP.LOP_JUMP, 0, 0, L)
			local EndJumpPC = GetPC(FS)
			PatchJumpD(FS, JumpPC, GetPC(FS))
			if LeftReg ~= Target then
				EmitABC(FS, LOP.LOP_MOVE, Target, LeftReg, 0, L)
			end
			PatchJumpD(FS, EndJumpPC, GetPC(FS))

		else
			local CompareOp = CompareOps[Op]
			if CompareOp then
				local LeftNode = Node.Left
				local RightNode = Node.Right
				if Op == ">" or Op == ">=" then
					LeftNode = Node.Right
					RightNode = Node.Left
				end

				local LeftReg, LeftTemp = CompileExprToAnyReg(FS, LeftNode)
				local RightReg, RightTemp = CompileExprToAnyReg(FS, RightNode)

				EmitAD(FS, CompareOp, LeftReg, 3, L)
				EmitAux(FS, RightReg, L)
				EmitABC(FS, LOP.LOP_LOADB, Target, 0, 1, L)
				EmitABC(FS, LOP.LOP_LOADB, Target, 1, 0, L)

				if RightTemp then FreeReg(FS) end
				if LeftTemp then FreeReg(FS) end
			end
		end

	elseif Kind == "CallExpr" or Kind == "MethodCallExpr" then
		CompileCall(FS, Node, Target, 1)

	elseif Kind == "FieldExpr" then
		local ObjReg, ObjTemp = CompileExprToAnyReg(FS, Node.Object)
		local K = AddConstant(FS, Node.Field)
		EmitABC(FS, LOP.LOP_GETTABLEKS, Target, ObjReg, 0, L)
		EmitAux(FS, K, L)
		if ObjTemp then FreeReg(FS) end

	elseif Kind == "IndexExpr" then
		local ObjReg, ObjTemp = CompileExprToAnyReg(FS, Node.Object)

		if Node.Index.Kind == "NumberLit" then
			local Idx = Node.Index.Value
			if Idx == math.floor(Idx) and Idx >= 1 and Idx <= 256 then
				EmitABC(FS, LOP.LOP_GETTABLEN, Target, ObjReg, Idx - 1, L)
				if ObjTemp then FreeReg(FS) end
				return
			end
		end

		if Node.Index.Kind == "StringLit" then
			local K = AddConstant(FS, Node.Index.Value)
			EmitABC(FS, LOP.LOP_GETTABLEKS, Target, ObjReg, 0, L)
			EmitAux(FS, K, L)
			if ObjTemp then FreeReg(FS) end
			return
		end

		local IdxReg, IdxTemp = CompileExprToAnyReg(FS, Node.Index)
		EmitABC(FS, LOP.LOP_GETTABLE, Target, ObjReg, IdxReg, L)
		if IdxTemp then FreeReg(FS) end
		if ObjTemp then FreeReg(FS) end

	elseif Kind == "FunctionExpr" then
		local ChildFS = CreateFunctionState(FS, #Node.Body.Params, Node.Body.IsVararg)
		ChildFS.DebugName = ""
		ChildFS.LineDefined = L

		EnterScope(ChildFS)
		if Node.Body.IsVararg then
			EmitABC(ChildFS, LOP.LOP_PREPVARARGS, #Node.Body.Params, 0, 0, L)
		end
		for _, ParamName in Node.Body.Params do
			PushLocal(ChildFS, ParamName)
		end
		CompileBlock(ChildFS, Node.Body.Body)
		EmitABC(ChildFS, LOP.LOP_RETURN, 0, 1, 0, L)
		LeaveScope(ChildFS, L)

		local Proto = {
			Code = ChildFS.Code,
			Constants = ChildFS.ConstantList,
			Protos = ChildFS.Protos,
			MaxStackSize = ChildFS.MaxReg + 2,
			NumParams = ChildFS.NumParams,
			IsVararg = ChildFS.IsVararg,
			Upvalues = ChildFS.Upvalues,
			Lines = ChildFS.Lines,
			DebugName = ChildFS.DebugName,
			LineDefined = ChildFS.LineDefined,
		}

		local ProtoIdx = #FS.Protos
		table.insert(FS.Protos, Proto)

		EmitAD(FS, LOP.LOP_NEWCLOSURE, Target, ProtoIdx, L)

		for _, Uv in ChildFS.Upvalues do
			if Uv.InStack then
				EmitABC(FS, LOP.LOP_CAPTURE, LOP.LCT_REF, Uv.Index, 0, L)
			else
				EmitABC(FS, LOP.LOP_CAPTURE, LOP.LCT_UPVAL, Uv.Index, 0, L)
			end
		end

	elseif Kind == "TableExpr" then
		local ArrayCount = 0
		local HashCount = 0
		local HasStringKeys = true
		local StringKeys = {}

		for _, Field in Node.Fields do
			if Field.Kind == "Value" then
				ArrayCount += 1
			elseif Field.Kind == "Field" then
				HashCount += 1
				table.insert(StringKeys, Field.Name)
			else
				HashCount += 1
				HasStringKeys = false
			end
		end

		local HashLog = 0
		if HashCount > 0 then
			HashLog = 1
			while (1 * 2^HashLog) < HashCount do
				HashLog += 1
			end
		end

		if HasStringKeys and #StringKeys > 0 and #Node.Fields == #StringKeys then
			local Keys = {}
			for _, K in StringKeys do
				table.insert(Keys, AddConstant(FS, K))
			end
			local TableK = #FS.ConstantList
			table.insert(FS.ConstantList, { Type = "Table", Keys = Keys })
			FS.Constants["__TABLE_" .. TableK] = TableK
			EmitAD(FS, LOP.LOP_DUPTABLE, Target, TableK, L)

			for _, Field in Node.Fields do
				local ValueReg = CompileExprToNextReg(FS, Field.Value)
				local K = AddConstant(FS, Field.Name)
				EmitABC(FS, LOP.LOP_SETTABLEKS, ValueReg, Target, 0, Field.Value.Line or L)
				EmitAux(FS, K, Field.Value.Line or L)
				FreeReg(FS)
			end
		else
			EmitABC(FS, LOP.LOP_NEWTABLE, Target, if HashCount > 0 then HashLog + 1 else 0, 0, L)
			EmitAux(FS, ArrayCount, L)

			local ArrayIndex = 0
			local BatchStart = -1
			local BatchCount = 0

			for _, Field in Node.Fields do
				if Field.Kind == "Value" then
					if BatchStart == -1 then
						BatchStart = FS.FreeReg
					end
					local Reg = AllocReg(FS)
					local IsLast = Field == Node.Fields[#Node.Fields]
					local IsMultiRet = IsLast and (Field.Value.Kind == "VarargExpr" or Field.Value.Kind == "CallExpr" or Field.Value.Kind == "MethodCallExpr")

					if IsMultiRet then
						if Field.Value.Kind == "VarargExpr" then
							EmitAD(FS, LOP.LOP_GETVARARGS, Reg, 0, Field.Value.Line or L)
						else
							CompileCall(FS, Field.Value, Reg, -1)
						end
					else
						CompileExpression(FS, Field.Value, Reg, Field.Value.Line or L)
					end
					ArrayIndex += 1
					BatchCount += 1

					if BatchCount >= 64 or IsLast then
						EmitABC(FS, LOP.LOP_SETLIST, Target, BatchStart, if IsMultiRet then 0 else BatchCount + 1, L)
						EmitAux(FS, ArrayIndex - BatchCount + 1, L)
						FS.FreeReg = BatchStart
						BatchStart = -1
						BatchCount = 0
					end
				elseif Field.Kind == "Field" then
					local ValueReg = CompileExprToNextReg(FS, Field.Value)
					local K = AddConstant(FS, Field.Name)
					EmitABC(FS, LOP.LOP_SETTABLEKS, ValueReg, Target, 0, Field.Value.Line or L)
					EmitAux(FS, K, Field.Value.Line or L)
					FreeReg(FS)
				elseif Field.Kind == "Index" then
					local KeyReg = CompileExprToNextReg(FS, Field.Key)
					local ValueReg = CompileExprToNextReg(FS, Field.Value)
					EmitABC(FS, LOP.LOP_SETTABLE, ValueReg, Target, KeyReg, Field.Value.Line or L)
					FreeReg(FS, 2)
				end
			end
		end

	elseif Kind == "IfExpr" then
		local CondReg, CondTemp = CompileExprToAnyReg(FS, Node.Condition)
		EmitAD(FS, LOP.LOP_JUMPIFNOT, CondReg, 0, L)
		local FalseJump = GetPC(FS)
		if CondTemp then FreeReg(FS) end

		CompileExpression(FS, Node.Then, Target, L)
		EmitAD(FS, LOP.LOP_JUMP, 0, 0, L)
		local EndJumps = { GetPC(FS) }

		PatchJumpD(FS, FalseJump, GetPC(FS))

		for _, Clause in Node.ElseifClauses do
			local ECondReg, ECondTemp = CompileExprToAnyReg(FS, Clause.Condition)
			EmitAD(FS, LOP.LOP_JUMPIFNOT, ECondReg, 0, L)
			local EFalseJump = GetPC(FS)
			if ECondTemp then FreeReg(FS) end

			CompileExpression(FS, Clause.Then, Target, L)
			EmitAD(FS, LOP.LOP_JUMP, 0, 0, L)
			table.insert(EndJumps, GetPC(FS))

			PatchJumpD(FS, EFalseJump, GetPC(FS))
		end

		CompileExpression(FS, Node.Else, Target, L)

		for _, J in EndJumps do
			PatchJumpD(FS, J, GetPC(FS))
		end

	elseif Kind == "GroupExpr" then
		CompileExpression(FS, Node.Expression, Target, L)

	elseif Kind == "InterpStringExpr" then
		local SaveReg = FS.FreeReg
		local ConcatBase = FS.FreeReg
		for _, Part in Node.Parts do
			local Reg = AllocReg(FS)
			if Part.Kind == "StringLit" then
				CompileExpression(FS, Part, Reg, Part.Line or L)
			else
				local ToStringK = AddConstant(FS, "tostring")
				EmitABC(FS, LOP.LOP_GETGLOBAL, Reg, 0, 0, L)
				EmitAux(FS, ToStringK, L)
				local ArgReg = AllocReg(FS)
				CompileExpression(FS, Part, ArgReg, Part.Line or L)
				EmitABC(FS, LOP.LOP_CALL, Reg, 2, 2, L)
				FS.FreeReg = Reg + 1
			end
		end
		if #Node.Parts > 1 then
			EmitABC(FS, LOP.LOP_CONCAT, Target, ConcatBase, ConcatBase + #Node.Parts - 1, L)
		elseif #Node.Parts == 1 then
			if ConcatBase ~= Target then
				EmitABC(FS, LOP.LOP_MOVE, Target, ConcatBase, 0, L)
			end
		else
			local K = AddConstant(FS, "")
			EmitAD(FS, LOP.LOP_LOADK, Target, K, L)
		end
		FS.FreeReg = SaveReg
	end
end

CompileExprToNextReg = function(FS: any, Node: any): number
	local Reg = AllocReg(FS)
	CompileExpression(FS, Node, Reg, Node.Line)
	return Reg
end

CompileExprToAnyReg = function(FS: any, Node: any): (number, boolean)
	if Node.Kind == "NameExpr" then
		local Reg = ResolveLocal(FS, Node.Name)
		if Reg ~= nil then
			return Reg, false
		end
	end
	local Reg = CompileExprToNextReg(FS, Node)
	return Reg, true
end

CompileExpressionList = function(FS: any, List: { any }, Base: number, Count: number, LastMultRet: boolean?)
	for I = 1, Count do
		if I > #List then
			EmitABC(FS, LOP.LOP_LOADNIL, Base + I - 1, 0, 0)
		elseif I == #List and LastMultRet and (List[I].Kind == "CallExpr" or List[I].Kind == "MethodCallExpr" or List[I].Kind == "VarargExpr") then
			if List[I].Kind == "VarargExpr" then
				EmitAD(FS, LOP.LOP_GETVARARGS, Base + I - 1, 0, List[I].Line or 0)
			else
				CompileCall(FS, List[I], Base + I - 1, -1)
			end
		else
			CompileExpression(FS, List[I], Base + I - 1, List[I].Line or 0)
		end
	end
end

local function CompileAssignTarget(FS: any, Target: any, ValueReg: number, Line: number)
	if Target.Kind == "NameExpr" then
		local Reg = ResolveLocal(FS, Target.Name)
		if Reg ~= nil then
			if Reg ~= ValueReg then
				EmitABC(FS, LOP.LOP_MOVE, Reg, ValueReg, 0, Line)
			end
		else
			local UpIdx = ResolveUpvalue(FS, Target.Name)
			if UpIdx ~= nil then
				EmitABC(FS, LOP.LOP_SETUPVAL, ValueReg, UpIdx, 0, Line)
			else
				local K = AddConstant(FS, Target.Name)
				EmitABC(FS, LOP.LOP_SETGLOBAL, ValueReg, 0, 0, Line)
				EmitAux(FS, K, Line)
			end
		end
	elseif Target.Kind == "FieldExpr" then
		local ObjReg, ObjTemp = CompileExprToAnyReg(FS, Target.Object)
		local K = AddConstant(FS, Target.Field)
		EmitABC(FS, LOP.LOP_SETTABLEKS, ValueReg, ObjReg, 0, Line)
		EmitAux(FS, K, Line)
		if ObjTemp then FreeReg(FS) end
	elseif Target.Kind == "IndexExpr" then
		local ObjReg, ObjTemp = CompileExprToAnyReg(FS, Target.Object)

		if Target.Index.Kind == "NumberLit" then
			local Idx = Target.Index.Value
			if Idx == math.floor(Idx) and Idx >= 1 and Idx <= 256 then
				EmitABC(FS, LOP.LOP_SETTABLEN, ValueReg, ObjReg, Idx - 1, Line)
				if ObjTemp then FreeReg(FS) end
				return
			end
		end

		if Target.Index.Kind == "StringLit" then
			local K = AddConstant(FS, Target.Index.Value)
			EmitABC(FS, LOP.LOP_SETTABLEKS, ValueReg, ObjReg, 0, Line)
			EmitAux(FS, K, Line)
			if ObjTemp then FreeReg(FS) end
			return
		end

		local IdxReg, IdxTemp = CompileExprToAnyReg(FS, Target.Index)
		EmitABC(FS, LOP.LOP_SETTABLE, ValueReg, ObjReg, IdxReg, Line)
		if IdxTemp then FreeReg(FS) end
		if ObjTemp then FreeReg(FS) end
	end
end

local function CompileFunctionBody(FS: any, Node: any, Name: string?, Line: number): any
	local Body = Node
	local ChildFS = CreateFunctionState(FS, #Body.Params, Body.IsVararg)
	ChildFS.DebugName = Name or ""
	ChildFS.LineDefined = Line

	EnterScope(ChildFS)
	if Body.IsVararg then
		EmitABC(ChildFS, LOP.LOP_PREPVARARGS, #Body.Params, 0, 0, Line)
	end
	for _, ParamName in Body.Params do
		PushLocal(ChildFS, ParamName)
	end
	CompileBlock(ChildFS, Body.Body)
	EmitABC(ChildFS, LOP.LOP_RETURN, 0, 1, 0, Line)
	LeaveScope(ChildFS, Line)

	local Proto = {
		Code = ChildFS.Code,
		Constants = ChildFS.ConstantList,
		Protos = ChildFS.Protos,
		MaxStackSize = ChildFS.MaxReg + 2,
		NumParams = ChildFS.NumParams,
		IsVararg = ChildFS.IsVararg,
		Upvalues = ChildFS.Upvalues,
		Lines = ChildFS.Lines,
		DebugName = ChildFS.DebugName,
		LineDefined = ChildFS.LineDefined,
	}

	local ProtoIdx = #FS.Protos
	table.insert(FS.Protos, Proto)
	return ProtoIdx, ChildFS.Upvalues
end

CompileStatement = function(FS: any, Node: any)
	local L = Node.Line or 0

	if Node.Kind == "LocalStat" then
		local Names = Node.Names
		local Values = Node.Values
		local BaseReg = FS.FreeReg

		if #Values > 0 then
			for I = 1, #Names do
				if I <= #Values then
					local IsLast = (I == #Values) and (I < #Names)
					if IsLast and (Values[I].Kind == "CallExpr" or Values[I].Kind == "MethodCallExpr" or Values[I].Kind == "VarargExpr") then
						local Reg = AllocReg(FS)
						if Values[I].Kind == "VarargExpr" then
							local Needed = #Names - I + 1
							EmitAD(FS, LOP.LOP_GETVARARGS, Reg, Needed + 1, Values[I].Line or L)
							for _ = 2, Needed do
								AllocReg(FS)
							end
						else
							CompileCall(FS, Values[I], Reg, #Names - I + 1)
							for _ = 2, #Names - I + 1 do
								AllocReg(FS)
							end
						end
						break
					else
						local Reg = AllocReg(FS)
						CompileExpression(FS, Values[I], Reg, Values[I].Line or L)
					end
				else
					local Reg = AllocReg(FS)
					EmitABC(FS, LOP.LOP_LOADNIL, Reg, 0, 0, L)
				end
			end
		else
			for _ = 1, #Names do
				local Reg = AllocReg(FS)
				EmitABC(FS, LOP.LOP_LOADNIL, Reg, 0, 0, L)
			end
		end

		FS.FreeReg = BaseReg
		for I, Name in Names do
			local Shadow = FS.Locals[Name]
			local Reg = BaseReg + I - 1
			FS.Locals[Name] = { Reg = Reg, Depth = FS.ScopeDepth }
			table.insert(FS.LocalStack, { Name = Name, Reg = Reg, Depth = FS.ScopeDepth, Shadow = Shadow })
			FS.FreeReg = Reg + 1
		end
		if FS.FreeReg > FS.MaxReg then
			FS.MaxReg = FS.FreeReg
		end

	elseif Node.Kind == "AssignStat" then
		local Targets = Node.Targets
		local Values = Node.Values

		if #Targets == 1 and #Values == 1 then
			if Targets[1].Kind == "NameExpr" then
				local Reg = ResolveLocal(FS, Targets[1].Name)
				if Reg ~= nil then
					local Val = Values[1]
					if Val.Kind == "CallExpr" or Val.Kind == "MethodCallExpr" then
						local TempReg = CompileExprToNextReg(FS, Val)
						EmitABC(FS, LOP.LOP_MOVE, Reg, TempReg, 0, L)
						FreeReg(FS)
					else
						CompileExpression(FS, Val, Reg, L)
					end
					return
				end
			end
			local ValueReg = CompileExprToNextReg(FS, Values[1])
			CompileAssignTarget(FS, Targets[1], ValueReg, L)
			FreeReg(FS)
		else
			local SaveReg = FS.FreeReg
			local TempBase = FS.FreeReg
			for I = 1, #Targets do
				if I <= #Values then
					local Reg = AllocReg(FS)
					CompileExpression(FS, Values[I], Reg, Values[I].Line or L)
				else
					local Reg = AllocReg(FS)
					EmitABC(FS, LOP.LOP_LOADNIL, Reg, 0, 0, L)
				end
			end
			for I = 1, #Targets do
				CompileAssignTarget(FS, Targets[I], TempBase + I - 1, L)
			end
			FS.FreeReg = SaveReg
		end

	elseif Node.Kind == "CompoundAssignStat" then
		local Target = Node.Target
		local Op = Node.Op
		local ArithOp = ArithOps[Op]

		if Target.Kind == "NameExpr" then
			local Reg = ResolveLocal(FS, Target.Name)
			if Reg ~= nil then
				if ArithOp then
					local RightConst, RightVal = IsConstantFoldable(Node.Value)
					if RightConst and type(RightVal) == "number" then
						local KOp = ArithKOps[Op]
						if KOp then
							local K = AddConstant(FS, RightVal)
							if K <= 255 then
								EmitABC(FS, KOp, Reg, Reg, K, L)
								return
							end
						end
					end
					local RightReg, RightTemp = CompileExprToAnyReg(FS, Node.Value)
					EmitABC(FS, ArithOp, Reg, Reg, RightReg, L)
					if RightTemp then FreeReg(FS) end
				elseif Op == ".." then
					local RightReg = CompileExprToNextReg(FS, Node.Value)
					EmitABC(FS, LOP.LOP_CONCAT, Reg, Reg, RightReg, L)
					FreeReg(FS)
				end
				return
			end
		end

		local TempReg = CompileExprToNextReg(FS, Target)
		local RightReg = CompileExprToNextReg(FS, Node.Value)

		if ArithOp then
			EmitABC(FS, ArithOp, TempReg, TempReg, RightReg, L)
		elseif Op == ".." then
			EmitABC(FS, LOP.LOP_CONCAT, TempReg, TempReg, RightReg, L)
		end

		FreeReg(FS)
		CompileAssignTarget(FS, Target, TempReg, L)
		FreeReg(FS)

	elseif Node.Kind == "ExprStat" then
		local SaveReg = FS.FreeReg
		CompileCall(FS, Node.Expr, FS.FreeReg, 0)
		FS.FreeReg = SaveReg

	elseif Node.Kind == "IfStat" then
		local CondReg, CondTemp = CompileExprToAnyReg(FS, Node.Condition)
		EmitAD(FS, LOP.LOP_JUMPIFNOT, CondReg, 0, L)
		local FalseJump = GetPC(FS)
		if CondTemp then FreeReg(FS) end

		EnterScope(FS)
		CompileBlock(FS, Node.Body)
		LeaveScope(FS, L)

		local EndJumps = {}

		if #Node.ElseifClauses > 0 or Node.ElseBody then
			EmitAD(FS, LOP.LOP_JUMP, 0, 0, L)
			table.insert(EndJumps, GetPC(FS))
		end

		PatchJumpD(FS, FalseJump, GetPC(FS))

		for _, Clause in Node.ElseifClauses do
			local ECondReg, ECondTemp = CompileExprToAnyReg(FS, Clause.Condition)
			EmitAD(FS, LOP.LOP_JUMPIFNOT, ECondReg, 0, Clause.Condition.Line or L)
			local EFalseJump = GetPC(FS)
			if ECondTemp then FreeReg(FS) end

			EnterScope(FS)
			CompileBlock(FS, Clause.Body)
			LeaveScope(FS, L)

			if Node.ElseBody or Clause ~= Node.ElseifClauses[#Node.ElseifClauses] then
				EmitAD(FS, LOP.LOP_JUMP, 0, 0, L)
				table.insert(EndJumps, GetPC(FS))
			end

			PatchJumpD(FS, EFalseJump, GetPC(FS))
		end

		if Node.ElseBody then
			EnterScope(FS)
			CompileBlock(FS, Node.ElseBody)
			LeaveScope(FS, L)
		end

		for _, J in EndJumps do
			PatchJumpD(FS, J, GetPC(FS))
		end

	elseif Node.Kind == "WhileStat" then
		local LoopStart = GetPC(FS)

		table.insert(FS.Loops, { BreakJumps = {}, ContinueJumps = {}, ScopeDepth = FS.ScopeDepth })

		local CondReg, CondTemp = CompileExprToAnyReg(FS, Node.Condition)
		EmitAD(FS, LOP.LOP_JUMPIFNOT, CondReg, 0, L)
		local ExitJump = GetPC(FS)
		if CondTemp then FreeReg(FS) end

		EnterScope(FS)
		CompileBlock(FS, Node.Body)

		local Loop = FS.Loops[#FS.Loops]
		for _, J in Loop.ContinueJumps do
			PatchJumpD(FS, J, GetPC(FS))
		end

		LeaveScope(FS, L)

		EmitAD(FS, LOP.LOP_JUMPBACK, 0, LoopStart - GetPC(FS), L)

		PatchJumpD(FS, ExitJump, GetPC(FS))

		for _, J in Loop.BreakJumps do
			PatchJumpD(FS, J, GetPC(FS))
		end

		table.remove(FS.Loops)

	elseif Node.Kind == "RepeatStat" then
		local LoopStart = GetPC(FS)

		table.insert(FS.Loops, { BreakJumps = {}, ContinueJumps = {}, ScopeDepth = FS.ScopeDepth })

		EnterScope(FS)
		CompileBlock(FS, Node.Body)

		local Loop = FS.Loops[#FS.Loops]
		for _, J in Loop.ContinueJumps do
			PatchJumpD(FS, J, GetPC(FS))
		end

		local CondReg, CondTemp = CompileExprToAnyReg(FS, Node.Condition)
		EmitAD(FS, LOP.LOP_JUMPIFNOT, CondReg, 0, L)
		local ContinueJump = GetPC(FS)
		if CondTemp then FreeReg(FS) end

		LeaveScope(FS, L)

		EmitAD(FS, LOP.LOP_JUMP, 0, 0, L)
		local ExitJump = GetPC(FS)

		PatchJumpD(FS, ContinueJump, GetPC(FS))
		EmitAD(FS, LOP.LOP_JUMPBACK, 0, LoopStart - GetPC(FS), L)

		PatchJumpD(FS, ExitJump, GetPC(FS))

		for _, J in Loop.BreakJumps do
			PatchJumpD(FS, J, GetPC(FS))
		end

		table.remove(FS.Loops)

	elseif Node.Kind == "NumericForStat" then
		EnterScope(FS)

		local BaseReg = AllocReg(FS, 3)
		CompileExpression(FS, Node.Limit, BaseReg, Node.Limit.Line or L)
		CompileExpression(FS, Node.Step or { Kind = "NumberLit", Value = 1, Line = L }, BaseReg + 1, L)
		CompileExpression(FS, Node.Start, BaseReg + 2, Node.Start.Line or L)

		EmitAD(FS, LOP.LOP_FORNPREP, BaseReg, 0, L)
		local PrepPC = GetPC(FS)

		table.insert(FS.Loops, { BreakJumps = {}, ContinueJumps = {}, ScopeDepth = FS.ScopeDepth })

		EnterScope(FS)
		local IterReg = PushLocal(FS, Node.Name)
		EmitABC(FS, LOP.LOP_MOVE, IterReg, BaseReg + 2, 0, L)

		local LoopBody = GetPC(FS)
		CompileBlock(FS, Node.Body)

		local Loop = FS.Loops[#FS.Loops]
		for _, J in Loop.ContinueJumps do
			PatchJumpD(FS, J, GetPC(FS))
		end

		LeaveScope(FS, L)

		EmitAD(FS, LOP.LOP_FORNLOOP, BaseReg, LoopBody - GetPC(FS) - 1, L)

		PatchJumpD(FS, PrepPC, GetPC(FS) - 1)

		for _, J in Loop.BreakJumps do
			PatchJumpD(FS, J, GetPC(FS))
		end

		table.remove(FS.Loops)
		FS.FreeReg = BaseReg
		LeaveScope(FS, L)

	elseif Node.Kind == "GenericForStat" then
		EnterScope(FS)

		local BaseReg = AllocReg(FS, 3)

		local NumIterators = #Node.Iterators
		for I = 1, 3 do
			if I <= NumIterators then
				local Iter = Node.Iterators[I]
				if I == NumIterators and I < 3 and (Iter.Kind == "CallExpr" or Iter.Kind == "MethodCallExpr") then
					CompileCall(FS, Iter, BaseReg + I - 1, 3 - I + 1)
					break
				else
					CompileExpression(FS, Iter, BaseReg + I - 1, Iter.Line or L)
				end
			else
				EmitABC(FS, LOP.LOP_LOADNIL, BaseReg + I - 1, 0, 0, L)
			end
		end

		EmitAD(FS, LOP.LOP_FORGPREP, BaseReg, 0, L)
		local PrepPC = GetPC(FS)

		table.insert(FS.Loops, { BreakJumps = {}, ContinueJumps = {}, ScopeDepth = FS.ScopeDepth })

		EnterScope(FS)
		local NumVars = #Node.Names
		for _, VarName in Node.Names do
			PushLocal(FS, VarName)
		end

		local LoopBody = GetPC(FS) + 1
		CompileBlock(FS, Node.Body)

		local Loop = FS.Loops[#FS.Loops]
		for _, J in Loop.ContinueJumps do
			PatchJumpD(FS, J, GetPC(FS))
		end

		LeaveScope(FS, L)

		EmitAD(FS, LOP.LOP_FORGLOOP, BaseReg, LoopBody - GetPC(FS) - 1, L)
		EmitAux(FS, NumVars, L)

		PatchJumpD(FS, PrepPC, GetPC(FS) - 2)

		for _, J in Loop.BreakJumps do
			PatchJumpD(FS, J, GetPC(FS))
		end

		table.remove(FS.Loops)
		FS.FreeReg = BaseReg
		LeaveScope(FS, L)

	elseif Node.Kind == "DoStat" then
		EnterScope(FS)
		CompileBlock(FS, Node.Body)
		LeaveScope(FS, L)

	elseif Node.Kind == "ReturnStat" then
		local Values = Node.Values
		if #Values == 0 then
			EmitABC(FS, LOP.LOP_RETURN, 0, 1, 0, L)
		elseif #Values == 1 then
			if Values[1].Kind == "CallExpr" or Values[1].Kind == "MethodCallExpr" then
				local Reg = FS.FreeReg
				CompileCall(FS, Values[1], Reg, -1)
				EmitABC(FS, LOP.LOP_RETURN, Reg, 0, 0, L)
			elseif Values[1].Kind == "VarargExpr" then
				local Reg = FS.FreeReg
				EmitAD(FS, LOP.LOP_GETVARARGS, Reg, 0, L)
				EmitABC(FS, LOP.LOP_RETURN, Reg, 0, 0, L)
			else
				local Reg = CompileExprToNextReg(FS, Values[1])
				EmitABC(FS, LOP.LOP_RETURN, Reg, 2, 0, L)
				FreeReg(FS)
			end
		else
			local SaveReg = FS.FreeReg
			local BaseReg = FS.FreeReg
			local IsLastMultRet = false
			for I = 1, #Values do
				if I == #Values and (Values[I].Kind == "CallExpr" or Values[I].Kind == "MethodCallExpr" or Values[I].Kind == "VarargExpr") then
					IsLastMultRet = true
					if Values[I].Kind == "VarargExpr" then
						EmitAD(FS, LOP.LOP_GETVARARGS, BaseReg + I - 1, 0, Values[I].Line or L)
					else
						CompileCall(FS, Values[I], BaseReg + I - 1, -1)
					end
				else
					local Reg = AllocReg(FS)
					CompileExpression(FS, Values[I], Reg, Values[I].Line or L)
				end
			end
			if IsLastMultRet then
				EmitABC(FS, LOP.LOP_RETURN, BaseReg, 0, 0, L)
			else
				EmitABC(FS, LOP.LOP_RETURN, BaseReg, #Values + 1, 0, L)
			end
			FS.FreeReg = SaveReg
		end

	elseif Node.Kind == "BreakStat" then
		if #FS.Loops == 0 then
			error(`[Compiler] Line {L}: 'break' outside of loop`)
		end
		local NeedClose = false
		local MinReg = FS.FreeReg
		for I = #FS.LocalStack, 1, -1 do
			local Local = FS.LocalStack[I]
			if Local.Depth <= FS.Loops[#FS.Loops].ScopeDepth then
				break
			end
			if FS.LocalsHaveUpvalues[Local.Reg] then
				NeedClose = true
				if Local.Reg < MinReg then
					MinReg = Local.Reg
				end
			end
		end
		if NeedClose then
			EmitABC(FS, LOP.LOP_CLOSEUPVALS, MinReg, 0, 0, L)
		end
		EmitAD(FS, LOP.LOP_JUMP, 0, 0, L)
		table.insert(FS.Loops[#FS.Loops].BreakJumps, GetPC(FS))

	elseif Node.Kind == "ContinueStat" then
		if #FS.Loops == 0 then
			error(`[Compiler] Line {L}: 'continue' outside of loop`)
		end
		local NeedClose = false
		local MinReg = FS.FreeReg
		for I = #FS.LocalStack, 1, -1 do
			local Local = FS.LocalStack[I]
			if Local.Depth <= FS.Loops[#FS.Loops].ScopeDepth then
				break
			end
			if FS.LocalsHaveUpvalues[Local.Reg] then
				NeedClose = true
				if Local.Reg < MinReg then
					MinReg = Local.Reg
				end
			end
		end
		if NeedClose then
			EmitABC(FS, LOP.LOP_CLOSEUPVALS, MinReg, 0, 0, L)
		end
		EmitAD(FS, LOP.LOP_JUMP, 0, 0, L)
		table.insert(FS.Loops[#FS.Loops].ContinueJumps, GetPC(FS))

	elseif Node.Kind == "FunctionStat" then
		local ProtoIdx, ChildUpvalues = CompileFunctionBody(FS, Node.Body, nil, L)

		if Node.Name.Kind == "NameExpr" then
			local DebugName = Node.Name.Name
			FS.Protos[ProtoIdx + 1].DebugName = DebugName

			local Reg = ResolveLocal(FS, Node.Name.Name)
			if Reg ~= nil then
				EmitAD(FS, LOP.LOP_NEWCLOSURE, Reg, ProtoIdx, L)
				for _, Uv in ChildUpvalues do
					if Uv.InStack then
						EmitABC(FS, LOP.LOP_CAPTURE, LOP.LCT_REF, Uv.Index, 0, L)
					else
						EmitABC(FS, LOP.LOP_CAPTURE, LOP.LCT_UPVAL, Uv.Index, 0, L)
					end
				end
			else
				local TempReg = AllocReg(FS)
				EmitAD(FS, LOP.LOP_NEWCLOSURE, TempReg, ProtoIdx, L)
				for _, Uv in ChildUpvalues do
					if Uv.InStack then
						EmitABC(FS, LOP.LOP_CAPTURE, LOP.LCT_REF, Uv.Index, 0, L)
					else
						EmitABC(FS, LOP.LOP_CAPTURE, LOP.LCT_UPVAL, Uv.Index, 0, L)
					end
				end
				local UpIdx = ResolveUpvalue(FS, Node.Name.Name)
				if UpIdx ~= nil then
					EmitABC(FS, LOP.LOP_SETUPVAL, TempReg, UpIdx, 0, L)
				else
					local K = AddConstant(FS, Node.Name.Name)
					EmitABC(FS, LOP.LOP_SETGLOBAL, TempReg, 0, 0, L)
					EmitAux(FS, K, L)
				end
				FreeReg(FS)
			end
		else
			local TempReg = AllocReg(FS)
			EmitAD(FS, LOP.LOP_NEWCLOSURE, TempReg, ProtoIdx, L)
			for _, Uv in ChildUpvalues do
				if Uv.InStack then
					EmitABC(FS, LOP.LOP_CAPTURE, LOP.LCT_REF, Uv.Index, 0, L)
				else
					EmitABC(FS, LOP.LOP_CAPTURE, LOP.LCT_UPVAL, Uv.Index, 0, L)
				end
			end
			CompileAssignTarget(FS, Node.Name, TempReg, L)
			FreeReg(FS)
		end

	elseif Node.Kind == "LocalFunctionStat" then
		local Reg = PushLocal(FS, Node.Name)
		local ProtoIdx, ChildUpvalues = CompileFunctionBody(FS, Node.Body, Node.Name, L)
		FS.Protos[ProtoIdx + 1].DebugName = Node.Name

		EmitAD(FS, LOP.LOP_NEWCLOSURE, Reg, ProtoIdx, L)
		for _, Uv in ChildUpvalues do
			if Uv.InStack then
				EmitABC(FS, LOP.LOP_CAPTURE, LOP.LCT_REF, Uv.Index, 0, L)
			else
				EmitABC(FS, LOP.LOP_CAPTURE, LOP.LCT_UPVAL, Uv.Index, 0, L)
			end
		end
	end
end

CompileBlock = function(FS: any, Block: any)
	for _, Stat in Block.Body do
		CompileStatement(FS, Stat)
	end
end

function Lowerer.Compile(AST: any): any
	local FS = CreateFunctionState(nil, 0, true)
	FS.DebugName = "(main)"
	FS.LineDefined = 0

	EnterScope(FS)
	EmitABC(FS, LOP.LOP_PREPVARARGS, 0, 0, 0, 0)
	CompileBlock(FS, AST)
	EmitABC(FS, LOP.LOP_RETURN, 0, 1, 0, 0)
	LeaveScope(FS, 0)

	local Proto = {
		Code = FS.Code,
		Constants = FS.ConstantList,
		Protos = FS.Protos,
		MaxStackSize = FS.MaxReg + 2,
		NumParams = 0,
		IsVararg = true,
		Upvalues = FS.Upvalues,
		Lines = FS.Lines,
		DebugName = FS.DebugName,
		LineDefined = 0,
	}

	return Proto
end

return Lowerer

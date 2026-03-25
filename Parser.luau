local Parser = {}

local UNARY_PRIORITY = 7

local BinaryPriority = {
	["+"] = { 5, 5 },
	["-"] = { 5, 5 },
	["*"] = { 6, 6 },
	["/"] = { 6, 6 },
	["//"] = { 6, 6 },
	["%"] = { 6, 6 },
	["^"] = { 9, 8 },
	[".."] = { 4, 3 },
	["=="] = { 3, 3 },
	["~="] = { 3, 3 },
	["<"] = { 3, 3 },
	["<="] = { 3, 3 },
	[">"] = { 3, 3 },
	[">="] = { 3, 3 },
	["and"] = { 2, 2 },
	["or"] = { 1, 1 },
}

local CompoundOps = {
	["+="] = "+",
	["-="] = "-",
	["*="] = "*",
	["/="] = "/",
	["//="] = "//",
	["%="] = "%",
	["^="] = "^",
	["..="] = "..",
}

function Parser.Parse(Tokens: { any }): any
	local Pos = 1

	local function Peek(): any
		return Tokens[Pos]
	end

	local function PeekType(): string
		return Tokens[Pos].Type
	end

	local function Advance(): any
		local Token = Tokens[Pos]
		Pos += 1
		return Token
	end

	local function Check(Type: string): boolean
		return Tokens[Pos].Type == Type
	end

	local function Match(Type: string): any?
		if Tokens[Pos].Type == Type then
			return Advance()
		end
		return nil
	end

	local function Expect(Type: string): any
		local Token = Tokens[Pos]
		if Token.Type ~= Type then
			error(`[Parser] Line {Token.Line}: Expected '{Type}', got '{Token.Type}'`)
		end
		Pos += 1
		return Token
	end

	local function GetLine(): number
		return Tokens[Pos].Line
	end

	local ParseExpression: (MinPriority: number?) -> any
	local ParseStatement: () -> any?
	local ParseBlock: () -> any
	local ParseExpressionList: () -> { any }
	local ParsePrefixExpression: () -> any
	local ParseSimpleExpression: () -> any
	local ParseFunctionBody: (HasSelf: boolean?) -> any
	local ParseTableConstructor: () -> any
	local ParseType: () -> ()

	ParseType = function()
		local Depth = 0
		while true do
			local T = PeekType()
			if T == "Eof" then
				break
			end
			if T == "(" then
				Depth += 1
				Advance()
			elseif T == ")" then
				if Depth > 0 then
					Depth -= 1
					Advance()
				else
					break
				end
			elseif T == "{" then
				Depth += 1
				Advance()
			elseif T == "}" then
				if Depth > 0 then
					Depth -= 1
					Advance()
				else
					break
				end
			elseif T == "<" then
				Depth += 1
				Advance()
			elseif T == ">" then
				if Depth > 0 then
					Depth -= 1
					Advance()
				else
					break
				end
			elseif Depth == 0 then
				if T == "," or T == "=" or T == "then" or T == "do" or T == "end"
					or T == ")" or T == "}" or T == "]" or T == ";" or T == "in"
					or T == "local" or T == "function" or T == "return" or T == "if"
					or T == "while" or T == "repeat" or T == "for" or T == "break"
					or T == "continue" or T == "else" or T == "elseif" or T == "until"
					or T == "type" or T == "export"
					or T == "::" or T == "+" or T == "-" or T == "*" or T == "/"
					or T == "//" or T == "%" or T == "^" or T == ".." or T == "=="
					or T == "~=" or T == "<" or T == "<=" or T == ">" or T == ">="
					or T == "and" or T == "or" or T == "not" or T == "#" then
					break
				end
				Advance()
			else
				Advance()
			end
		end
	end

	local function TryParseType()
		if Check(":") then
			Advance()
			ParseType()
		end
	end

	local function TryParseReturnType()
		if Check(":") then
			Advance()
			ParseType()
		elseif Check("->") then
			Advance()
			ParseType()
		end
	end

	local function TryParseGenericParams()
		if Check("<") then
			Advance()
			local Depth = 1
			while Depth > 0 do
				local T = PeekType()
				if T == "<" then
					Depth += 1
				elseif T == ">" then
					Depth -= 1
				elseif T == "Eof" then
					break
				end
				Advance()
			end
		end
	end

	ParseFunctionBody = function(HasSelf: boolean?): any
		TryParseGenericParams()
		Expect("(")
		local Params = {}
		local IsVararg = false

		if HasSelf then
			table.insert(Params, "self")
		end

		if not Check(")") then
			while true do
				if Check("...") then
					Advance()
					IsVararg = true
					TryParseType()
					break
				end
				local Name = Expect("Identifier")
				table.insert(Params, Name.Value)
				TryParseType()
				if not Match(",") then
					break
				end
			end
		end
		Expect(")")
		TryParseReturnType()

		local Body = ParseBlock()
		Expect("end")

		return { Params = Params, IsVararg = IsVararg, Body = Body }
	end

	ParseTableConstructor = function(): any
		local L = GetLine()
		Expect("{")
		local Fields = {}

		while not Check("}") and not Check("Eof") do
			if Check("[") then
				Advance()
				local Key = ParseExpression()
				Expect("]")
				Expect("=")
				local Value = ParseExpression()
				table.insert(Fields, { Kind = "Index", Key = Key, Value = Value })
			elseif Check("Identifier") and Tokens[Pos + 1] and Tokens[Pos + 1].Type == "=" then
				local Name = Advance()
				Advance()
				local Value = ParseExpression()
				table.insert(Fields, { Kind = "Field", Name = Name.Value, Value = Value })
			else
				local Value = ParseExpression()
				table.insert(Fields, { Kind = "Value", Value = Value })
			end

			if not Match(",") and not Match(";") then
				break
			end
		end

		Expect("}")
		return { Kind = "TableExpr", Fields = Fields, Line = L }
	end

	ParsePrefixExpression = function(): any
		local Token = Peek()
		local Expr

		if Token.Type == "Identifier" or Token.Type == "typeof" or Token.Type == "type" then
			Advance()
			Expr = { Kind = "NameExpr", Name = Token.Value, Line = Token.Line }
		elseif Token.Type == "(" then
			Advance()
			Expr = ParseExpression()
			Expect(")")
			Expr = { Kind = "GroupExpr", Expression = Expr, Line = Token.Line }
		else
			error(`[Parser] Line {Token.Line}: Unexpected token '{Token.Type}' in expression`)
		end

		while true do
			local T = PeekType()
			if T == "." then
				Advance()
				local Field = Expect("Identifier")
				Expr = { Kind = "FieldExpr", Object = Expr, Field = Field.Value, Line = Field.Line }
			elseif T == "[" then
				Advance()
				local Index = ParseExpression()
				Expect("]")
				Expr = { Kind = "IndexExpr", Object = Expr, Index = Index, Line = Expr.Line }
			elseif T == ":" then
				if Tokens[Pos + 1] and Tokens[Pos + 1].Type == "Identifier"
					and Tokens[Pos + 2] and (Tokens[Pos + 2].Type == "(" or Tokens[Pos + 2].Type == "{" or Tokens[Pos + 2].Type == "String") then
					Advance()
					local Method = Expect("Identifier")
					local Args
					if Check("(") then
						Advance()
						Args = {}
						if not Check(")") then
							Args = ParseExpressionList()
						end
						Expect(")")
					elseif Check("{") then
						Args = { ParseTableConstructor() }
					elseif Check("String") then
						Args = { { Kind = "StringLit", Value = Advance().Value, Line = GetLine() } }
					end
					Expr = { Kind = "MethodCallExpr", Object = Expr, Method = Method.Value, Args = Args, Line = Method.Line }
				else
					break
				end
			elseif T == "(" then
				Advance()
				local Args = {}
				if not Check(")") then
					Args = ParseExpressionList()
				end
				Expect(")")
				Expr = { Kind = "CallExpr", Func = Expr, Args = Args, Line = Expr.Line }
			elseif T == "{" then
				local Tbl = ParseTableConstructor()
				Expr = { Kind = "CallExpr", Func = Expr, Args = { Tbl }, Line = Expr.Line }
			elseif T == "String" then
				local Str = Advance()
				Expr = { Kind = "CallExpr", Func = Expr, Args = { { Kind = "StringLit", Value = Str.Value, Line = Str.Line } }, Line = Expr.Line }
			else
				break
			end
		end

		return Expr
	end

	ParseSimpleExpression = function(): any
		local Token = Peek()
		local T = Token.Type

		if T == "Number" then
			Advance()
			return { Kind = "NumberLit", Value = Token.Value, Line = Token.Line }
		elseif T == "String" then
			Advance()
			return { Kind = "StringLit", Value = Token.Value, Line = Token.Line }
		elseif T == "nil" then
			Advance()
			return { Kind = "NilLit", Line = Token.Line }
		elseif T == "true" then
			Advance()
			return { Kind = "TrueLit", Line = Token.Line }
		elseif T == "false" then
			Advance()
			return { Kind = "FalseLit", Line = Token.Line }
		elseif T == "..." then
			Advance()
			return { Kind = "VarargExpr", Line = Token.Line }
		elseif T == "function" then
			Advance()
			local Body = ParseFunctionBody()
			return { Kind = "FunctionExpr", Body = Body, Line = Token.Line }
		elseif T == "{" then
			return ParseTableConstructor()
		elseif T == "if" then
			Advance()
			local Condition = ParseExpression()
			Expect("then")
			local ThenExpr = ParseExpression()
			local ElseifClauses = {}
			while Match("elseif") do
				local ECondition = ParseExpression()
				Expect("then")
				local EThen = ParseExpression()
				table.insert(ElseifClauses, { Condition = ECondition, Then = EThen })
			end
			Expect("else")
			local ElseExpr = ParseExpression()
			return { Kind = "IfExpr", Condition = Condition, Then = ThenExpr, ElseifClauses = ElseifClauses, Else = ElseExpr, Line = Token.Line }
		elseif T == "InterpBegin" then
			Advance()
			local Parts: { any } = {}
			if #Token.Value > 0 then
				table.insert(Parts, { Kind = "StringLit", Value = Token.Value, Line = Token.Line })
			end
			local Expr = ParseExpression()
			table.insert(Parts, Expr)
			while Check("InterpMid") do
				local Mid = Advance()
				if #Mid.Value > 0 then
					table.insert(Parts, { Kind = "StringLit", Value = Mid.Value, Line = Mid.Line })
				end
				Expr = ParseExpression()
				table.insert(Parts, Expr)
			end
			local EndToken = Expect("InterpEnd")
			if #EndToken.Value > 0 then
				table.insert(Parts, { Kind = "StringLit", Value = EndToken.Value, Line = EndToken.Line })
			end
			return { Kind = "InterpStringExpr", Parts = Parts, Line = Token.Line }
		else
			return ParsePrefixExpression()
		end
	end

	ParseExpression = function(MinPriority: number?): any
		local Min = MinPriority or 0
		local Token = Peek()
		local Expr

		if Token.Type == "-" then
			Advance()
			local Operand = ParseExpression(UNARY_PRIORITY)
			Expr = { Kind = "UnaryExpr", Op = "-", Operand = Operand, Line = Token.Line }
		elseif Token.Type == "not" then
			Advance()
			local Operand = ParseExpression(UNARY_PRIORITY)
			Expr = { Kind = "UnaryExpr", Op = "not", Operand = Operand, Line = Token.Line }
		elseif Token.Type == "#" then
			Advance()
			local Operand = ParseExpression(UNARY_PRIORITY)
			Expr = { Kind = "UnaryExpr", Op = "#", Operand = Operand, Line = Token.Line }
		else
			Expr = ParseSimpleExpression()
		end

		while Check("::") do
			Advance()
			ParseType()
		end

		while true do
			local OpToken = Peek()
			local Prec = BinaryPriority[OpToken.Type]
			if not Prec then
				break
			end
			if Prec[1] <= Min then
				break
			end
			Advance()
			local Right = ParseExpression(Prec[2])
			Expr = { Kind = "BinaryExpr", Op = OpToken.Type, Left = Expr, Right = Right, Line = OpToken.Line }
		end

		return Expr
	end

	ParseExpressionList = function(): { any }
		local List = { ParseExpression() }
		while Match(",") do
			table.insert(List, ParseExpression())
		end
		return List
	end

	local function ParseNameList(): ({ string }, { any })
		local Names = {}
		local Tokens2 = {}
		local NameTok = Expect("Identifier")
		table.insert(Names, NameTok.Value)
		table.insert(Tokens2, NameTok)
		while Match(",") do
			NameTok = Expect("Identifier")
			table.insert(Names, NameTok.Value)
			table.insert(Tokens2, NameTok)
		end
		return Names, Tokens2
	end

	local function IsCallOrMethod(Expr: any): boolean
		return Expr.Kind == "CallExpr" or Expr.Kind == "MethodCallExpr"
	end

	local function IsLValue(Expr: any): boolean
		return Expr.Kind == "NameExpr" or Expr.Kind == "FieldExpr" or Expr.Kind == "IndexExpr"
	end

	ParseStatement = function(): any?
		local Token = Peek()
		local T = Token.Type

		if T == ";" then
			Advance()
			return nil
		end

		if T == "if" then
			Advance()
			local Condition = ParseExpression()
			Expect("then")
			local Body = ParseBlock()
			local ElseifClauses = {}
			while Match("elseif") do
				local ECondition = ParseExpression()
				Expect("then")
				local EBody = ParseBlock()
				table.insert(ElseifClauses, { Condition = ECondition, Body = EBody })
			end
			local ElseBody = nil
			if Match("else") then
				ElseBody = ParseBlock()
			end
			Expect("end")
			return { Kind = "IfStat", Condition = Condition, Body = Body, ElseifClauses = ElseifClauses, ElseBody = ElseBody, Line = Token.Line }
		end

		if T == "while" then
			Advance()
			local Condition = ParseExpression()
			Expect("do")
			local Body = ParseBlock()
			Expect("end")
			return { Kind = "WhileStat", Condition = Condition, Body = Body, Line = Token.Line }
		end

		if T == "repeat" then
			Advance()
			local Body = ParseBlock()
			Expect("until")
			local Condition = ParseExpression()
			return { Kind = "RepeatStat", Body = Body, Condition = Condition, Line = Token.Line }
		end

		if T == "do" then
			Advance()
			local Body = ParseBlock()
			Expect("end")
			return { Kind = "DoStat", Body = Body, Line = Token.Line }
		end

		if T == "for" then
			Advance()
			local FirstName = Expect("Identifier")
			if Check("=") then
				Advance()
				local Start = ParseExpression()
				Expect(",")
				local Limit = ParseExpression()
				local Step = nil
				if Match(",") then
					Step = ParseExpression()
				end
				Expect("do")
				local Body = ParseBlock()
				Expect("end")
				return { Kind = "NumericForStat", Name = FirstName.Value, Start = Start, Limit = Limit, Step = Step, Body = Body, Line = Token.Line }
			else
				local Names = { FirstName.Value }
				TryParseType()
				while Match(",") do
					local N = Expect("Identifier")
					table.insert(Names, N.Value)
					TryParseType()
				end
				Expect("in")
				local Iterators = ParseExpressionList()
				Expect("do")
				local Body = ParseBlock()
				Expect("end")
				return { Kind = "GenericForStat", Names = Names, Iterators = Iterators, Body = Body, Line = Token.Line }
			end
		end

		if T == "return" then
			Advance()
			local Values = {}
			if not Check("end") and not Check("else") and not Check("elseif") and not Check("until") and not Check("Eof") and not Check(";") then
				Values = ParseExpressionList()
			end
			Match(";")
			return { Kind = "ReturnStat", Values = Values, Line = Token.Line }
		end

		if T == "break" then
			Advance()
			return { Kind = "BreakStat", Line = Token.Line }
		end

		if T == "continue" then
			Advance()
			return { Kind = "ContinueStat", Line = Token.Line }
		end

		if T == "local" then
			Advance()
			if Check("function") then
				Advance()
				local Name = Expect("Identifier")
				local Body = ParseFunctionBody()
				return { Kind = "LocalFunctionStat", Name = Name.Value, Body = Body, Line = Token.Line }
			end

			local Names = {}
			local NameTok = Expect("Identifier")
			table.insert(Names, NameTok.Value)
			TryParseType()
			while Match(",") do
				NameTok = Expect("Identifier")
				table.insert(Names, NameTok.Value)
				TryParseType()
			end

			local Values = {}
			if Match("=") then
				Values = ParseExpressionList()
			end
			return { Kind = "LocalStat", Names = Names, Values = Values, Line = Token.Line }
		end

		if T == "function" then
			Advance()
			local Name = Expect("Identifier")
			local NameExpr: any = { Kind = "NameExpr", Name = Name.Value, Line = Name.Line }
			local HasSelf = false

			while Check(".") do
				Advance()
				local Field = Expect("Identifier")
				NameExpr = { Kind = "FieldExpr", Object = NameExpr, Field = Field.Value, Line = Field.Line }
			end

			if Check(":") then
				Advance()
				local Method = Expect("Identifier")
				NameExpr = { Kind = "FieldExpr", Object = NameExpr, Field = Method.Value, Line = Method.Line }
				HasSelf = true
			end

			local Body = ParseFunctionBody(HasSelf)
			return { Kind = "FunctionStat", Name = NameExpr, Body = Body, Line = Token.Line }
		end

		if T == "export" then
			Advance()
			if not Check("type") then
				error(`[Parser] Line {Token.Line}: Expected 'type' after 'export'`)
			end
			Advance()
			Expect("Identifier")
			TryParseGenericParams()
			Expect("=")
			ParseType()
			return nil
		end

		if T == "type" and Tokens[Pos + 1] and Tokens[Pos + 1].Type == "Identifier" then
			Advance()
			Expect("Identifier")
			TryParseGenericParams()
			Expect("=")
			ParseType()
			return nil
		end

		local Expr = ParsePrefixExpression()

		if CompoundOps[PeekType()] then
			local OpToken = Advance()
			local Op = CompoundOps[OpToken.Type]
			if not IsLValue(Expr) then
				error(`[Parser] Line {OpToken.Line}: Invalid compound assignment target`)
			end
			local Value = ParseExpression()
			return { Kind = "CompoundAssignStat", Op = Op, Target = Expr, Value = Value, Line = OpToken.Line }
		end

		if Check("=") or Check(",") then
			local Targets = { Expr }
			while Match(",") do
				local Target = ParsePrefixExpression()
				table.insert(Targets, Target)
			end
			Expect("=")
			local Values = ParseExpressionList()
			for _, Target in Targets do
				if not IsLValue(Target) then
					error(`[Parser] Line {Token.Line}: Invalid assignment target`)
				end
			end
			return { Kind = "AssignStat", Targets = Targets, Values = Values, Line = Token.Line }
		end

		if IsCallOrMethod(Expr) then
			return { Kind = "ExprStat", Expr = Expr, Line = Token.Line }
		end

		error(`[Parser] Line {Token.Line}: Unexpected expression statement`)
	end

	ParseBlock = function(): any
		local Body = {}
		local L = GetLine()
		while true do
			local T = PeekType()
			if T == "end" or T == "else" or T == "elseif" or T == "until" or T == "Eof" then
				break
			end
			local Stat = ParseStatement()
			if Stat then
				table.insert(Body, Stat)
			end
			if Stat and Stat.Kind == "ReturnStat" then
				break
			end
		end
		return { Body = Body, Line = L }
	end

	local Block = ParseBlock()
	if not Check("Eof") then
		local Token = Peek()
		error(`[Parser] Line {Token.Line}: Unexpected token '{Token.Type}' at end of input`)
	end
	return Block
end

return Parser

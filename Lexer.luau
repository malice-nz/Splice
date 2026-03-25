local Lexer = {}

local Keywords = {
	["and"] = "and", ["break"] = "break", ["continue"] = "continue",
	["do"] = "do", ["else"] = "else", ["elseif"] = "elseif",
	["end"] = "end", ["false"] = "false", ["for"] = "for",
	["function"] = "function", ["if"] = "if", ["in"] = "in",
	["local"] = "local", ["nil"] = "nil", ["not"] = "not",
	["or"] = "or", ["repeat"] = "repeat", ["return"] = "return",
	["then"] = "then", ["true"] = "true", ["until"] = "until",
	["while"] = "while", ["type"] = "type", ["typeof"] = "typeof",
	["export"] = "export",
}

local BYTE_0 = string.byte("0")
local BYTE_9 = string.byte("9")
local BYTE_A = string.byte("A")
local BYTE_Z = string.byte("Z")
local BYTE_a = string.byte("a")
local BYTE_z = string.byte("z")
local BYTE_UNDERSCORE = string.byte("_")
local BYTE_DOT = string.byte(".")
local BYTE_PLUS = string.byte("+")
local BYTE_MINUS = string.byte("-")
local BYTE_STAR = string.byte("*")
local BYTE_SLASH = string.byte("/")
local BYTE_PERCENT = string.byte("%")
local BYTE_CARET = string.byte("^")
local BYTE_HASH = string.byte("#")
local BYTE_EQUALS = string.byte("=")
local BYTE_TILDE = string.byte("~")
local BYTE_LESS = string.byte("<")
local BYTE_GREATER = string.byte(">")
local BYTE_LPAREN = string.byte("(")
local BYTE_RPAREN = string.byte(")")
local BYTE_LBRACE = string.byte("{")
local BYTE_RBRACE = string.byte("}")
local BYTE_LBRACKET = string.byte("[")
local BYTE_RBRACKET = string.byte("]")
local BYTE_SEMICOLON = string.byte(";")
local BYTE_COLON = string.byte(":")
local BYTE_COMMA = string.byte(",")
local BYTE_QUOTE1 = string.byte("'")
local BYTE_QUOTE2 = string.byte('"')
local BYTE_BACKTICK = string.byte("`")
local BYTE_BACKSLASH = string.byte("\\")
local BYTE_NEWLINE = string.byte("\n")
local BYTE_CR = string.byte("\r")
local BYTE_SPACE = string.byte(" ")
local BYTE_TAB = string.byte("\t")
local BYTE_x = string.byte("x")
local BYTE_X = string.byte("X")
local BYTE_b_lower = string.byte("b")
local BYTE_B = string.byte("B")
local BYTE_e_lower = string.byte("e")
local BYTE_E = string.byte("E")
local BYTE_p_lower = string.byte("p")
local BYTE_P = string.byte("P")
local BYTE_n = string.byte("n")
local BYTE_t = string.byte("t")
local BYTE_r = string.byte("r")
local BYTE_a_lower = string.byte("a")
local BYTE_f_lower = string.byte("f")
local BYTE_F = string.byte("F")
local BYTE_v = string.byte("v")
local BYTE_u = string.byte("u")
local BYTE_PIPE = string.byte("|")
local BYTE_AMPERSAND = string.byte("&")
local BYTE_QUESTION = string.byte("?")

local function IsDigit(B: number): boolean
	return B >= BYTE_0 and B <= BYTE_9
end

local function IsHexDigit(B: number): boolean
	return (B >= BYTE_0 and B <= BYTE_9) or (B >= BYTE_A and B <= BYTE_F) or (B >= BYTE_a_lower and B <= BYTE_f_lower)
end

local function IsAlpha(B: number): boolean
	return (B >= BYTE_A and B <= BYTE_Z) or (B >= BYTE_a and B <= BYTE_z) or B == BYTE_UNDERSCORE
end

local function IsAlphaNumeric(B: number): boolean
	return IsAlpha(B) or IsDigit(B)
end

local function IsWhitespace(B: number): boolean
	return B == BYTE_SPACE or B == BYTE_TAB or B == BYTE_CR or B == BYTE_NEWLINE or B == 12
end

function Lexer.Tokenize(Source: string): { any }
	local Tokens = {}
	local InterpBraceDepth = {}
	local Pos = 1
	local Len = #Source
	local Line = 1
	local Column = 1

	local function PeekByte(Offset: number?): number?
		local I = Pos + (Offset or 0)
		if I > Len then
			return nil
		end
		return string.byte(Source, I)
	end

	local function Advance(): number?
		if Pos > Len then
			return nil
		end
		local B = string.byte(Source, Pos)
		Pos += 1
		if B == BYTE_NEWLINE then
			Line += 1
			Column = 1
		elseif B == BYTE_CR then
			if PeekByte() == BYTE_NEWLINE then
				Pos += 1
			end
			Line += 1
			Column = 1
		else
			Column += 1
		end
		return B
	end

	local function AddToken(Type: string, Value: any)
		table.insert(Tokens, { Type = Type, Value = Value, Line = Line, Column = Column })
	end

	local function ReadLongString(Level: number): string?
		local Parts = {}
		while true do
			local B = PeekByte()
			if B == nil then
				return nil
			end
			if B == BYTE_RBRACKET then
				local Match = true
				for I = 1, Level do
					if PeekByte(I) ~= BYTE_EQUALS then
						Match = false
						break
					end
				end
				if Match and PeekByte(Level + 1) == BYTE_RBRACKET then
					for _ = 0, Level + 1 do
						Advance()
					end
					return table.concat(Parts)
				end
			end
			local Ch = Advance()
			if Ch == BYTE_NEWLINE then
				table.insert(Parts, "\n")
			elseif Ch == BYTE_CR then
				table.insert(Parts, "\n")
			else
				table.insert(Parts, string.char(Ch :: number))
			end
		end
	end

	local function ReadEscapeSequence(): string
		local B = Advance()
		if B == nil then
			error(`[Lexer] Line {Line}: Unfinished escape sequence`)
		end
		if B == BYTE_n then return "\n"
		elseif B == BYTE_t then return "\t"
		elseif B == BYTE_r then return "\r"
		elseif B == BYTE_a_lower then return "\a"
		elseif B == BYTE_b_lower then return "\b"
		elseif B == BYTE_f_lower then return "\f"
		elseif B == BYTE_v then return "\v"
		elseif B == BYTE_BACKSLASH then return "\\"
		elseif B == BYTE_QUOTE1 then return "'"
		elseif B == BYTE_QUOTE2 then return '"'
		elseif B == BYTE_NEWLINE then return "\n"
		elseif B == BYTE_CR then
			if PeekByte() == BYTE_NEWLINE then
				Advance()
			end
			return "\n"
		elseif B == BYTE_0 and not IsDigit(PeekByte() or 0) then
			return "\0"
		elseif IsDigit(B) then
			local Num = B - BYTE_0
			for _ = 1, 2 do
				local Next = PeekByte()
				if Next and IsDigit(Next) then
					Num = Num * 10 + (Advance() :: number - BYTE_0)
				else
					break
				end
			end
			if Num > 255 then
				error(`[Lexer] Line {Line}: Decimal escape too large`)
			end
			return string.char(Num)
		elseif B == BYTE_x then
			local H1 = Advance()
			local H2 = Advance()
			if H1 == nil or H2 == nil or not IsHexDigit(H1) or not IsHexDigit(H2) then
				error(`[Lexer] Line {Line}: Invalid hex escape`)
			end
			return string.char(tonumber(string.char(H1, H2), 16) :: number)
		elseif B == BYTE_u then
			local Brace = Advance()
			if Brace ~= BYTE_LBRACE then
				error(`[Lexer] Line {Line}: Missing \{ in unicode escape`)
			end
			local Hex = {}
			while PeekByte() and PeekByte() ~= BYTE_RBRACE do
				local H = Advance() :: number
				if not IsHexDigit(H) then
					error(`[Lexer] Line {Line}: Invalid unicode escape`)
				end
				table.insert(Hex, string.char(H))
			end
			if PeekByte() ~= BYTE_RBRACE then
				error(`[Lexer] Line {Line}: Missing \} in unicode escape`)
			end
			Advance()
			local Code = tonumber(table.concat(Hex), 16) :: number
			if Code > 0x10FFFF then
				error(`[Lexer] Line {Line}: Unicode escape out of range`)
			end
			return utf8.char(Code)
		elseif B == BYTE_z then
			while PeekByte() and IsWhitespace(PeekByte() :: number) do
				Advance()
			end
			return ""
		end
		error(`[Lexer] Line {Line}: Invalid escape sequence \\{string.char(B)}`)
	end

	local function ReadString(Quote: number): string
		local Parts = {}
		while true do
			local B = PeekByte()
			if B == nil or B == BYTE_NEWLINE or B == BYTE_CR then
				error(`[Lexer] Line {Line}: Unfinished string`)
			end
			if B == Quote then
				Advance()
				return table.concat(Parts)
			end
			if B == BYTE_BACKSLASH then
				Advance()
				table.insert(Parts, ReadEscapeSequence())
			else
				Advance()
				table.insert(Parts, string.char(B))
			end
		end
	end

	local function ReadInterpStringPart()
		local StrParts = {}
		while true do
			local B = PeekByte()
			if B == nil or B == BYTE_NEWLINE or B == BYTE_CR then
				error(`[Lexer] Line {Line}: Unfinished interpolated string`)
			end
			if B == BYTE_BACKTICK then
				Advance()
				return "InterpEnd", table.concat(StrParts)
			end
			if B == BYTE_BACKSLASH then
				Advance()
				table.insert(StrParts, ReadEscapeSequence())
			elseif B == BYTE_LBRACE then
				Advance()
				return "InterpExpr", table.concat(StrParts)
			else
				Advance()
				table.insert(StrParts, string.char(B))
			end
		end
	end

	local function ReadNumber(): number
		local Start = Pos - 1
		local B = string.byte(Source, Start)

		if B == BYTE_0 then
			local Next = PeekByte()
			if Next == BYTE_x or Next == BYTE_X then
				Advance()
				while PeekByte() and (IsHexDigit(PeekByte() :: number) or PeekByte() == BYTE_UNDERSCORE) do
					Advance()
				end
				if PeekByte() == BYTE_DOT then
					Advance()
					while PeekByte() and (IsHexDigit(PeekByte() :: number) or PeekByte() == BYTE_UNDERSCORE) do
						Advance()
					end
				end
				if PeekByte() == BYTE_p_lower or PeekByte() == BYTE_P then
					Advance()
					if PeekByte() == BYTE_PLUS or PeekByte() == BYTE_MINUS then
						Advance()
					end
					while PeekByte() and (IsDigit(PeekByte() :: number) or PeekByte() == BYTE_UNDERSCORE) do
						Advance()
					end
				end
				local Raw = string.gsub(string.sub(Source, Start, Pos - 1), "_", "")
				return tonumber(Raw) :: number
			elseif Next == BYTE_b_lower or Next == BYTE_B then
				Advance()
				while PeekByte() and (PeekByte() == BYTE_0 or PeekByte() == string.byte("1") or PeekByte() == BYTE_UNDERSCORE) do
					Advance()
				end
				local Raw = string.gsub(string.sub(Source, Start + 2, Pos - 1), "_", "")
				return tonumber(Raw, 2) :: number
			end
		end

		while PeekByte() and (IsDigit(PeekByte() :: number) or PeekByte() == BYTE_UNDERSCORE) do
			Advance()
		end

		if PeekByte() == BYTE_DOT and PeekByte(1) ~= BYTE_DOT then
			Advance()
			while PeekByte() and (IsDigit(PeekByte() :: number) or PeekByte() == BYTE_UNDERSCORE) do
				Advance()
			end
		end

		if PeekByte() == BYTE_e_lower or PeekByte() == BYTE_E then
			Advance()
			if PeekByte() == BYTE_PLUS or PeekByte() == BYTE_MINUS then
				Advance()
			end
			while PeekByte() and (IsDigit(PeekByte() :: number) or PeekByte() == BYTE_UNDERSCORE) do
				Advance()
			end
		end

		local Raw = string.gsub(string.sub(Source, Start, Pos - 1), "_", "")
		return tonumber(Raw) :: number
	end

	while Pos <= Len do
		local B = PeekByte() :: number

		if IsWhitespace(B) then
			Advance()
			continue
		end

		if B == BYTE_MINUS and PeekByte(1) == BYTE_MINUS then
			Advance()
			Advance()
			if PeekByte() == BYTE_LBRACKET then
				local EqCount = 0
				local CheckPos = Pos + 1
				while CheckPos <= Len and string.byte(Source, CheckPos) == BYTE_EQUALS do
					EqCount += 1
					CheckPos += 1
				end
				if CheckPos <= Len and string.byte(Source, CheckPos) == BYTE_LBRACKET then
					Advance()
					for _ = 1, EqCount do
						Advance()
					end
					Advance()
					if PeekByte() == BYTE_NEWLINE then
						Advance()
					elseif PeekByte() == BYTE_CR then
						Advance()
						if PeekByte() == BYTE_NEWLINE then
							Advance()
						end
					end
					ReadLongString(EqCount)
					continue
				end
			end
			while PeekByte() and PeekByte() ~= BYTE_NEWLINE and PeekByte() ~= BYTE_CR do
				Advance()
			end
			continue
		end

		if IsAlpha(B) then
			local Start = Pos
			Advance()
			while PeekByte() and IsAlphaNumeric(PeekByte() :: number) do
				Advance()
			end
			local Word = string.sub(Source, Start, Pos - 1)
			if Keywords[Word] then
				AddToken(Word, Word)
			else
				AddToken("Identifier", Word)
			end
			continue
		end

		if IsDigit(B) then
			Advance()
			local Num = ReadNumber()
			AddToken("Number", Num)
			continue
		end

		if B == BYTE_QUOTE1 or B == BYTE_QUOTE2 then
			Advance()
			local Str = ReadString(B)
			AddToken("String", Str)
			continue
		end

		if B == BYTE_BACKTICK then
			Advance()
			local TType, TValue = ReadInterpStringPart()
			if TType == "InterpEnd" then
				AddToken("String", TValue)
			else
				AddToken("InterpBegin", TValue)
				table.insert(InterpBraceDepth, 1)
			end
			continue
		end

		if B == BYTE_LBRACKET then
			local EqCount = 0
			local CheckPos = Pos + 1
			while CheckPos <= Len and string.byte(Source, CheckPos) == BYTE_EQUALS do
				EqCount += 1
				CheckPos += 1
			end
			if CheckPos <= Len and string.byte(Source, CheckPos) == BYTE_LBRACKET then
				for _ = 0, EqCount + 1 do
					Advance()
				end
				if PeekByte() == BYTE_NEWLINE then
					Advance()
				elseif PeekByte() == BYTE_CR then
					Advance()
					if PeekByte() == BYTE_NEWLINE then
						Advance()
					end
				end
				local Str = ReadLongString(EqCount)
				if Str == nil then
					error(`[Lexer] Line {Line}: Unfinished long string`)
				end
				AddToken("String", Str)
				continue
			end
		end

		Advance()

		if B == BYTE_PLUS then
			if PeekByte() == BYTE_EQUALS then
				Advance()
				AddToken("+=", "+=")
			else
				AddToken("+", "+")
			end
		elseif B == BYTE_MINUS then
			if PeekByte() == BYTE_GREATER then
				Advance()
				AddToken("->", "->")
			elseif PeekByte() == BYTE_EQUALS then
				Advance()
				AddToken("-=", "-=")
			else
				AddToken("-", "-")
			end
		elseif B == BYTE_STAR then
			if PeekByte() == BYTE_EQUALS then
				Advance()
				AddToken("*=", "*=")
			else
				AddToken("*", "*")
			end
		elseif B == BYTE_SLASH then
			if PeekByte() == BYTE_SLASH then
				Advance()
				if PeekByte() == BYTE_EQUALS then
					Advance()
					AddToken("//=", "//=")
				else
					AddToken("//", "//")
				end
			elseif PeekByte() == BYTE_EQUALS then
				Advance()
				AddToken("/=", "/=")
			else
				AddToken("/", "/")
			end
		elseif B == BYTE_PERCENT then
			if PeekByte() == BYTE_EQUALS then
				Advance()
				AddToken("%=", "%=")
			else
				AddToken("%", "%")
			end
		elseif B == BYTE_CARET then
			if PeekByte() == BYTE_EQUALS then
				Advance()
				AddToken("^=", "^=")
			else
				AddToken("^", "^")
			end
		elseif B == BYTE_HASH then
			AddToken("#", "#")
		elseif B == BYTE_EQUALS then
			if PeekByte() == BYTE_EQUALS then
				Advance()
				AddToken("==", "==")
			else
				AddToken("=", "=")
			end
		elseif B == BYTE_TILDE then
			if PeekByte() == BYTE_EQUALS then
				Advance()
				AddToken("~=", "~=")
			else
				error(`[Lexer] Line {Line}: Unexpected character '~'`)
			end
		elseif B == BYTE_LESS then
			if PeekByte() == BYTE_EQUALS then
				Advance()
				AddToken("<=", "<=")
			else
				AddToken("<", "<")
			end
		elseif B == BYTE_GREATER then
			if PeekByte() == BYTE_EQUALS then
				Advance()
				AddToken(">=", ">=")
			else
				AddToken(">", ">")
			end
		elseif B == BYTE_LPAREN then
			AddToken("(", "(")
		elseif B == BYTE_RPAREN then
			AddToken(")", ")")
		elseif B == BYTE_LBRACE then
			if #InterpBraceDepth > 0 then
				InterpBraceDepth[#InterpBraceDepth] += 1
			end
			AddToken("{", "{")
		elseif B == BYTE_RBRACE then
			if #InterpBraceDepth > 0 then
				if InterpBraceDepth[#InterpBraceDepth] == 1 then
					table.remove(InterpBraceDepth)
					local TType, TValue = ReadInterpStringPart()
					if TType == "InterpEnd" then
						AddToken("InterpEnd", TValue)
					else
						AddToken("InterpMid", TValue)
						table.insert(InterpBraceDepth, 1)
					end
				else
					InterpBraceDepth[#InterpBraceDepth] -= 1
					AddToken("}", "}")
				end
			else
				AddToken("}", "}")
			end
		elseif B == BYTE_LBRACKET then
			AddToken("[", "[")
		elseif B == BYTE_RBRACKET then
			AddToken("]", "]")
		elseif B == BYTE_SEMICOLON then
			AddToken(";", ";")
		elseif B == BYTE_COLON then
			if PeekByte() == BYTE_COLON then
				Advance()
				AddToken("::", "::")
			else
				AddToken(":", ":")
			end
		elseif B == BYTE_COMMA then
			AddToken(",", ",")
		elseif B == BYTE_DOT then
			if PeekByte() == BYTE_DOT then
				Advance()
				if PeekByte() == BYTE_DOT then
					Advance()
					AddToken("...", "...")
				elseif PeekByte() == BYTE_EQUALS then
					Advance()
					AddToken("..=", "..=")
				else
					AddToken("..", "..")
				end
			elseif PeekByte() and IsDigit(PeekByte() :: number) then
				local Num = ReadNumber()
				AddToken("Number", Num)
			else
				AddToken(".", ".")
			end
		elseif B == BYTE_PIPE then
			AddToken("|", "|")
		elseif B == BYTE_AMPERSAND then
			AddToken("&", "&")
		elseif B == BYTE_QUESTION then
			AddToken("?", "?")
		else
			error(`[Lexer] Line {Line}: Unexpected character '{string.char(B)}'`)
		end
	end

	AddToken("Eof", nil)
	return Tokens
end

return Lexer

local Opcodes = {}

Opcodes.LOP_NOP = 0
Opcodes.LOP_BREAK = 1
Opcodes.LOP_LOADNIL = 2
Opcodes.LOP_LOADB = 3
Opcodes.LOP_LOADN = 4
Opcodes.LOP_LOADK = 5
Opcodes.LOP_MOVE = 6
Opcodes.LOP_GETGLOBAL = 7
Opcodes.LOP_SETGLOBAL = 8
Opcodes.LOP_GETUPVAL = 9
Opcodes.LOP_SETUPVAL = 10
Opcodes.LOP_CLOSEUPVALS = 11
Opcodes.LOP_GETIMPORT = 12
Opcodes.LOP_GETTABLE = 13
Opcodes.LOP_SETTABLE = 14
Opcodes.LOP_GETTABLEKS = 15
Opcodes.LOP_SETTABLEKS = 16
Opcodes.LOP_GETTABLEN = 17
Opcodes.LOP_SETTABLEN = 18
Opcodes.LOP_NEWCLOSURE = 19
Opcodes.LOP_NAMECALL = 20
Opcodes.LOP_CALL = 21
Opcodes.LOP_RETURN = 22
Opcodes.LOP_JUMP = 23
Opcodes.LOP_JUMPBACK = 24
Opcodes.LOP_JUMPIF = 25
Opcodes.LOP_JUMPIFNOT = 26
Opcodes.LOP_JUMPIFEQ = 27
Opcodes.LOP_JUMPIFLE = 28
Opcodes.LOP_JUMPIFLT = 29
Opcodes.LOP_JUMPIFNOTEQ = 30
Opcodes.LOP_JUMPIFNOTLE = 31
Opcodes.LOP_JUMPIFNOTLT = 32
Opcodes.LOP_ADD = 33
Opcodes.LOP_SUB = 34
Opcodes.LOP_MUL = 35
Opcodes.LOP_DIV = 36
Opcodes.LOP_MOD = 37
Opcodes.LOP_POW = 38
Opcodes.LOP_ADDK = 39
Opcodes.LOP_SUBK = 40
Opcodes.LOP_MULK = 41
Opcodes.LOP_DIVK = 42
Opcodes.LOP_MODK = 43
Opcodes.LOP_POWK = 44
Opcodes.LOP_AND = 45
Opcodes.LOP_OR = 46
Opcodes.LOP_ANDK = 47
Opcodes.LOP_ORK = 48
Opcodes.LOP_CONCAT = 49
Opcodes.LOP_NOT = 50
Opcodes.LOP_MINUS = 51
Opcodes.LOP_LENGTH = 52
Opcodes.LOP_NEWTABLE = 53
Opcodes.LOP_DUPTABLE = 54
Opcodes.LOP_SETLIST = 55
Opcodes.LOP_FORNPREP = 56
Opcodes.LOP_FORNLOOP = 57
Opcodes.LOP_FORGLOOP = 58
Opcodes.LOP_FORGPREP_INEXT = 59
Opcodes.LOP_FASTCALL3 = 60
Opcodes.LOP_FORGPREP_NEXT = 61
Opcodes.LOP_NATIVECALL = 62
Opcodes.LOP_GETVARARGS = 63
Opcodes.LOP_DUPCLOSURE = 64
Opcodes.LOP_PREPVARARGS = 65
Opcodes.LOP_LOADKX = 66
Opcodes.LOP_JUMPX = 67
Opcodes.LOP_FASTCALL = 68
Opcodes.LOP_COVERAGE = 69
Opcodes.LOP_CAPTURE = 70
Opcodes.LOP_SUBRK = 71
Opcodes.LOP_DIVRK = 72
Opcodes.LOP_FASTCALL1 = 73
Opcodes.LOP_FASTCALL2 = 74
Opcodes.LOP_FASTCALL2K = 75
Opcodes.LOP_FORGPREP = 76
Opcodes.LOP_JUMPXEQKNIL = 77
Opcodes.LOP_JUMPXEQKB = 78
Opcodes.LOP_JUMPXEQKN = 79
Opcodes.LOP_JUMPXEQKS = 80
Opcodes.LOP_IDIV = 81
Opcodes.LOP_IDIVK = 82

Opcodes.LOP__COUNT = 83

Opcodes.LCT_VAL = 0
Opcodes.LCT_REF = 1
Opcodes.LCT_UPVAL = 2

Opcodes.Format = {}
for _, V in { 0, 1, 2, 3, 6, 7, 8, 9, 10, 11, 13, 14, 15, 16, 17, 18, 20, 21, 22, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 55, 60, 63, 65, 66, 68, 70, 71, 72, 73, 74, 75, 81, 82 } do
	Opcodes.Format[V] = "BC"
end
for _, V in { 4, 5, 12, 19, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 54, 56, 57, 58, 59, 61, 62, 64, 76, 77, 78, 79, 80 } do
	Opcodes.Format[V] = "AD"
end
for _, V in { 67, 69 } do
	Opcodes.Format[V] = "E"
end

local HAS_AUX = {}
HAS_AUX[Opcodes.LOP_GETGLOBAL] = true
HAS_AUX[Opcodes.LOP_SETGLOBAL] = true
HAS_AUX[Opcodes.LOP_GETIMPORT] = true
HAS_AUX[Opcodes.LOP_GETTABLEKS] = true
HAS_AUX[Opcodes.LOP_SETTABLEKS] = true
HAS_AUX[Opcodes.LOP_NAMECALL] = true
HAS_AUX[Opcodes.LOP_JUMPIFEQ] = true
HAS_AUX[Opcodes.LOP_JUMPIFLE] = true
HAS_AUX[Opcodes.LOP_JUMPIFLT] = true
HAS_AUX[Opcodes.LOP_JUMPIFNOTEQ] = true
HAS_AUX[Opcodes.LOP_JUMPIFNOTLE] = true
HAS_AUX[Opcodes.LOP_JUMPIFNOTLT] = true
HAS_AUX[Opcodes.LOP_NEWTABLE] = true
HAS_AUX[Opcodes.LOP_SETLIST] = true
HAS_AUX[Opcodes.LOP_FORGLOOP] = true
HAS_AUX[Opcodes.LOP_LOADKX] = true
HAS_AUX[Opcodes.LOP_FASTCALL2] = true
HAS_AUX[Opcodes.LOP_FASTCALL2K] = true
HAS_AUX[Opcodes.LOP_FASTCALL3] = true
HAS_AUX[Opcodes.LOP_JUMPXEQKNIL] = true
HAS_AUX[Opcodes.LOP_JUMPXEQKB] = true
HAS_AUX[Opcodes.LOP_JUMPXEQKN] = true
HAS_AUX[Opcodes.LOP_JUMPXEQKS] = true

function Opcodes.GetOpLength(Op: number): number
	if HAS_AUX[Op] then
		return 2
	end
	return 1
end

function Opcodes.EncodeABC(Op: number, A: number, B: number, C: number): number
	return bit32.bor(
		bit32.band(Op, 0xFF),
		bit32.lshift(bit32.band(A, 0xFF), 8),
		bit32.lshift(bit32.band(B, 0xFF), 16),
		bit32.lshift(bit32.band(C, 0xFF), 24)
	)
end

function Opcodes.EncodeAD(Op: number, A: number, D: number): number
	return bit32.bor(
		bit32.band(Op, 0xFF),
		bit32.lshift(bit32.band(A, 0xFF), 8),
		bit32.lshift(bit32.band(D, 0xFFFF), 16)
	)
end

function Opcodes.EncodeE(Op: number, E: number): number
	return bit32.bor(
		bit32.band(Op, 0xFF),
		bit32.lshift(bit32.band(E, 0xFFFFFF), 8)
	)
end

function Opcodes.DecodeOp(Insn: number): number
	return bit32.band(Insn, 0xFF)
end

function Opcodes.DecodeA(Insn: number): number
	return bit32.band(bit32.rshift(Insn, 8), 0xFF)
end

function Opcodes.DecodeB(Insn: number): number
	return bit32.band(bit32.rshift(Insn, 16), 0xFF)
end

function Opcodes.DecodeC(Insn: number): number
	return bit32.band(bit32.rshift(Insn, 24), 0xFF)
end

function Opcodes.DecodeD(Insn: number): number
	local Raw = bit32.band(bit32.rshift(Insn, 16), 0xFFFF)
	if Raw >= 32768 then
		return Raw - 65536
	end
	return Raw
end

function Opcodes.DecodeE(Insn: number): number
	local Raw = bit32.band(bit32.rshift(Insn, 8), 0xFFFFFF)
	if Raw >= 8388608 then
		return Raw - 16777216
	end
	return Raw
end

return Opcodes

local Lexer = require(script.Lexer)
local Parser = require(script.Parser)
local Lowerer = require(script.Lowerer)
local VM = require(script.VM)
local Serialiser = require(script.Serialiser)
local Sandbox = require(script.Sandbox)

local Splice = {}

function Splice.Compile(Source: string): any
	local Tokens = Lexer.Tokenize(Source)
	local AST = Parser.Parse(Tokens)
	local Proto = Lowerer.Compile(AST)
	return Proto
end

function Splice.Serialise(Proto: any): buffer
	return Serialiser.Serialise(Proto)
end

function Splice.Deserialise(Buf: buffer): any
	return Serialiser.Deserialise(Buf)
end

function Splice.CreateEnv(Config: Sandbox.SandboxConfig?): { [string]: any }
	return Sandbox.CreateEnv(Config)
end

function Splice.Execute(Proto: any, Env: any?): ...any
	return VM.Execute(Proto, Env)
end

function Splice.Run(Source: string, Env: any?): ...any
	local Proto = Splice.Compile(Source)
	return VM.Execute(Proto, Env)
end

return Splice

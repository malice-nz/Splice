# Splice

A Luau compiler and virtual machine, written entirely in Luau.

## Features

- Full Luau lexer, parser, and compiler pipeline
- Bytecode serialisation and deserialisation (version 6)
- Stack-based virtual machine supporting all 83 Luau opcodes
- Sandboxed execution with whitelist/blacklist controls, service blocking, and custom global injection
- Upvalue handling, closures, varargs, and coroutine-compatible calling convention

## Usage

```luau
local Splice = require(script.Splice)
```

### Compile and run

```luau
local result = Splice.Run([[
    local x = 10
    local y = 20
    return x + y
]])

print(result) --> 30
```

### Compile, serialise, deserialise, execute

```luau
local proto = Splice.Compile([[
    local function greet(name)
        return "Hello, " .. name .. "!"
    end
    return greet("world")
]])

local bytecode = Splice.Serialise(proto)

local restored = Splice.Deserialise(bytecode)
local message = Splice.Execute(restored)
print(message) --> Hello, world!
```

### Sandboxed execution

```luau
local env = Splice.CreateEnv({
    Whitelist = { "print", "math", "string", "table" },
    BlockedServices = { "HttpService", "DataStoreService" },
    Globals = {
        customLog = function(msg)
            print("[LOG]", msg)
        end,
    },
})

Splice.Run([[
    customLog("running in a sandbox")
    print(math.pi)
]], env)
```

### Sandbox configuration

The `CreateEnv` function accepts a config table with the following fields:

| Field | Type | What it does |
|-------|------|--------------|
| `Whitelist` | `{string}?` | Only these globals get forwarded from the host |
| `Blacklist` | `{string}?` | These globals get excluded |
| `BlockedServices` | `{string}?` | `game:GetService()` calls for these services throw an error |
| `Wrappers` | `{[string]: (any) -> any}?` | Functions that wrap specific globals before they enter the sandbox |
| `Script` | `any?` | Overrides the `script` global inside the sandbox |
| `Globals` | `{[string]: any}?` | Extra globals merged into the environment |

## Project Structure

```
init.luau        Entry point and public API
Lexer.luau       Tokeniser (keywords, strings, numbers, interpolation)
Parser.luau      Recursive descent parser producing an AST
Lowerer.luau     AST to bytecode compiler (register allocation, scoping, upvalues)
Opcodes.luau     Opcode definitions, encoding/decoding helpers
Serialiser.luau  Bytecode serialisation and deserialisation
Sandbox.luau     Environment builder with Roblox global forwarding
VM.luau          Stack-based virtual machine
```

## License

[MIT](LICENSE)

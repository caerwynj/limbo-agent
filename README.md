# limbo-agent

An AI coding agent written in [Limbo](https://en.wikipedia.org/wiki/Limbo_(programming_language)) for [Inferno OS](https://en.wikipedia.org/wiki/Inferno_(operating_system)). It connects to a locally hosted LLM via Inferno's filesystem protocol and provides an interactive REPL where the model can read, write, edit files, and execute shell commands in the Inferno environment.

## How it works

The agent mounts a remote LLM service as a 9P filesystem at `/n/llm/`. It communicates with the model by writing prompts to and reading completions from files under that mount. When the model emits a tool call (a JSON block fenced in `` ```json ``), the agent intercepts it, executes the requested operation natively in Inferno, and feeds the result back as context for the next turn.

### Tool loop

```
User input
  -> build prompt (system + conversation history)
  -> write to /n/llm/<conn>/data
  -> stream model output, watching for tool calls
  -> if tool call detected:
       parse JSON, dispatch to handler, collect result
       append result to history, repeat
  -> otherwise, print response and wait for next input
```

### Built-in tools

| Tool    | Description                              |
|---------|------------------------------------------|
| `read`  | Read the contents of a file              |
| `write` | Create or overwrite a file               |
| `edit`  | Find-and-replace a substring in a file   |
| `shell` | Run an Inferno shell command             |

## Prerequisites

- [Inferno OS](https://bitbucket.org/inferno-os/inferno-os) (or a host-OS `emu` build)
- A 9P-accessible LLM service exposing `clone`, `ctl`, `data`, and `info` files

## Building

```sh
cd /path/to/limbo-agent
mk
```

This compiles `agent.b` into `agent.dis` using the Inferno Limbo compiler.

## Running

1. Start `emu` and mount the LLM service:

```sh
# inside emu
load std
mkdir -p /n/llm
mount -A tcp!<host>!<port> /n/llm
```

2. Run the agent:

```sh
agent.dis
```

Or pass an existing connection number:

```sh
agent.dis 3
```

### Shell escape

Type `!<command>` at the prompt to run an Inferno shell command directly without sending it to the model.

## Project layout

```
agent.b          Limbo source for the agent
mkfile           Build file (Inferno mk)
system.md        System prompt sent to the model
tools.md         Tool documentation appended to the system prompt
setup            Inferno shell script to mount the LLM service
transcript.log   Conversation log (generated at runtime)
skills/          Placeholder for additional skill definitions
```

## License

See repository for license details.

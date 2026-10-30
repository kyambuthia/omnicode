# Omnicode

Omnicode is a terminal coding agent written in Zig. It can inspect and edit files,
run shell commands, load project skills, and work with hosted model providers.
It has no Zig package dependencies. Shell commands run with your user permissions;
Omnicode is not a sandbox. Install `rg` (ripgrep) for file search tools.

## Install

Prebuilt binaries are available for Linux x86_64 and aarch64:

```sh
curl -fsSL https://raw.githubusercontent.com/kyambuthia/omnicode/main/install.sh | sh
omnicode
```

## Build from source

Requires Zig 0.17.0, a POSIX system, and ripgrep.

```sh
zig build
./zig-out/bin/omnicode
./zig-out/bin/omnicode "explain src/main.zig"
```

## Configure a provider

Start Omnicode and run `/providers setup` to search providers, select one, and
paste an API key. The key stays hidden and is saved in the private configuration
file at `~/.config/omnicode/config.env` (or `$XDG_CONFIG_HOME/omnicode/config.env`).
Ctrl+V requests clipboard access where the terminal supports OSC 52; otherwise use
the terminal's paste shortcut, often Ctrl+Shift+V. Ctrl+C or Escape cancels.

You can also export a provider and key before starting Omnicode:

```sh
export PROVIDER=runinfra
export RUNINFRA_API_KEY='your-key'
omnicode
```

Do not put API keys in tracked files. Run `/providers` to view configured providers
and `/model` to search and select models.

## Use

```sh
omnicode "fix the failing tests"
omnicode --help
```

Inside the interactive session, `/help` lists commands. Source code and its tests
are the reference for implementation details and behavior.

## Verify changes

```sh
zig build test
python3 tests/integration.py
python3 tests/installer.py
```

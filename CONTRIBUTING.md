# Contributing

Thanks for helping!

## Ground rules

- **Zero dependencies, no Xcode project.** The whole app builds with `./build.sh` (plain `swiftc`). Please keep it that way.
- **Safety first.** Nothing may delete user files, touch `com.apple.*` agents, or require admin rights. Destructive actions must be reversible.
- **Tests must pass.** Run `./test.sh` (the full suite, not just `--unit`) before opening a PR. New parsing or control logic needs a test — pure logic goes in a unit test; anything that touches launchd or real processes gets an integration test that cleans up after itself.

## Workflow

```sh
./build.sh && open bgviewer.app   # build and run
./test.sh                         # full test suite (~10s)
```

Open an issue first for bigger features (new service sources, LaunchDaemons support, etc.) so we can agree on scope.

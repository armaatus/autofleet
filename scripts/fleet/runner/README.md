# Runner drivers

`lib.sh` sources `$AUTOFLEET_RUNNER.sh` from this directory. The contract every
driver meets is in [../../../docs/RUNNERS.md](../../../docs/RUNNERS.md).

Anything in this directory may know about one runner. Nothing outside it may —
and that is checkable rather than aspirational:

```sh
grep -rn 'ORCA_CLI\|orca ' scripts/fleet --include='*.sh' \
  | grep -v '^scripts/fleet/runner/'
```

`tests/test_fleet.sh runner_stub` is the other half: it drives the whole fleet
on a driver that is not Orca and fails if anything reaches for the CLI.

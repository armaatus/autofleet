# Runner drivers

`lib.sh` sources `$AUTOFLEET_RUNNER.sh` from this directory. The contract every
driver meets is in [../../../docs/RUNNERS.md](../../../docs/RUNNERS.md).

Anything in this directory may know about one runner. Nothing outside it may —
and that is checkable rather than aspirational:

```sh
grep -rn 'ORCA_\|orca\b' scripts/fleet --include='*.sh' \
  | grep -v '^scripts/fleet/runner/' \
  | grep -v ':[0-9]*: *#' \
  | grep -v '^scripts/fleet/config.sh:[0-9]*:: "${AUTOFLEET_RUNNER:=orca}"$'
```

Comments are excluded, and `config.sh`'s `AUTOFLEET_RUNNER` default is allowed by
name — prose may say `orca`, and the file that CHOOSES the driver may name one.
Code may not. `evals/lint.sh` runs it.

`tests/test_fleet.sh runner_stub` is the other half: it drives the whole fleet
on a driver that is not Orca and fails if anything reaches for the CLI.

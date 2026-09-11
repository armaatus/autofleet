# Runner drivers

`lib.sh` sources `$AUTOFLEET_RUNNER.sh` from this directory. The contract every
driver meets is in [../../../docs/RUNNERS.md](../../../docs/RUNNERS.md).

Anything in this directory may know about one runner. Nothing outside it may —
and that is checkable rather than aspirational:

```sh
grep -rn 'ORCA_\|orca\b' scripts/fleet --include='*.sh' \
  | grep -v '^scripts/fleet/runner/' \
  | awk '{
      code = $0
      sub(/^[^:]*:[0-9]+:/, "", code)   # drop path:lineno:
      sub(/#.*/, "", code)               # drop the comment, do not skip the line
      if (code ~ /ORCA_/ || code ~ /orca([^A-Za-z0-9_]|$)/) print
    }' \
  | grep -v '^scripts/fleet/config.sh:[0-9]*:: "${AUTOFLEET_RUNNER:=orca}"$'
```

The comment is STRIPPED rather than the line skipped, so `FOO=1  # not orca` is
prose and `ORCA_DEADLINE=20  # a knob` is a leak. `config.sh`'s
`AUTOFLEET_RUNNER` default is allowed by name: prose may say `orca`, and the file
that CHOOSES the driver may name one. Code may not.

This is what `evals/lint.sh` check 4c runs, byte for byte. It is the definition;
this copy is a convenience.

`tests/test_fleet.sh runner_stub` is the other half: it drives the whole fleet
on a driver that is not Orca and fails if anything reaches for the CLI.

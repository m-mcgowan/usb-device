# Bash Script Coverage

Investigation into line coverage tooling for `usb-device` (bash) and `serial-monitor` (python) test suites.

## Status: Not yet implemented

Coverage tooling for bash scripts is immature. We investigated three approaches and found none ready for production use with our bats test suite.

## Tools investigated

### kcov

**Result: Doesn't work on macOS.**

- On macOS, kcov uses the Mach binary engine by default instead of the bash engine
- SIP prevents instrumenting `/bin/bash` and `/usr/bin/env`
- Even with brew bash, kcov fails with "Can't write helper" errors when running bats
- Known issues: [#458](https://github.com/SimonKagstrom/kcov/issues/458) (infinite loop with bash 3.2), [#462](https://github.com/SimonKagstrom/kcov/issues/462) (inconsistent coverage with bats), [#476](https://github.com/SimonKagstrom/kcov/issues/476) (zero coverage for function bodies)
- Works on Linux — could be used in a CI-only coverage job on `ubuntu-latest`

### bashcov (Ruby gem)

**Result: Runs but corrupts bats test output.**

- Uses `PS4` + `BASH_XTRACEFD` to trace executed lines
- Requires bash 4+ and Ruby 3.2+ (macOS ships bash 3.2 and Ruby 2.6)
- With brew bash 5.3 and brew Ruby 4.0, bashcov runs but:
  - **PS4 trace output leaks into bats `run` captures**, causing ~15% of tests to fail with unexpected output
  - **Xtrace parser errors**: comments/strings in the script confuse bashcov's line parser, causing early abort
  - Reported 0% coverage due to the parser abort
- Install: `brew install bash ruby && gem install --user-install bashcov`

### DIY (PS4 + BASH_XTRACEFD)

**Result: Not yet attempted. Most promising approach.**

- Set `PS4='+ ${BASH_SOURCE[0]}:${LINENO}: '` and redirect xtrace to a dedicated FD via `BASH_XTRACEFD`
- Parse the trace log after test runs to compute per-file line coverage
- Avoids the stdout pollution problem because we control where trace output goes
- Requires bash 4.1+ for `BASH_XTRACEFD`
- Would need a custom wrapper around bats that sets up tracing and a post-processor (~50-100 lines)
- Full control means we can handle edge cases that break kcov/bashcov

## Recommendations

1. **Short term**: Rely on test pass/fail counts and manual review. The mock test suite (103 tests) covers locking, scanning, reset, plugins, Insight Hub, and registration.
2. **Medium term**: Build a DIY coverage wrapper using `BASH_XTRACEFD`. This avoids all the issues with existing tools.
3. **CI**: If we add coverage, kcov on `ubuntu-latest` is the easiest path for CI-only coverage (avoids all macOS issues). Local coverage would use the DIY approach.

## Test infrastructure (ready to use)

- `test/setup.sh` — installs test dependencies (bats, jq, bash 5, ruby, bashcov)
- `test/coverage.sh` — coverage runner (currently uses bashcov; update when DIY approach is built)
- `.gitignore` includes `coverage/`

# Partner Device Registration & Fuzzy Matching

Two enhancements to partner device support in `usb-device`.

## 1. `register --partner-of`

Register a partner device via CLI instead of editing `devices.conf` manually.

```bash
usb-device register ppk2 --serial C7749C622998 --type ppk2 --partner-of "1.9"
```

**Behavior:**

- First positional arg is the **role** (e.g. `ppk2`, `notecard`)
- `--partner-of` takes a fuzzy device pattern, resolved via existing `resolve_device()`
- Composed INI section name: `[<resolved primary>:<role>]` (e.g. `[MPCB 1.9 Development:ppk2]`)
- Validates: primary device exists, partner `primary:role` doesn't already exist
- Uses `serial=` key (not `mac=`) for partner sections; omits `chip=`
- Runs `cmd_scan` after registration (same as current behavior)

**Error cases:**

- `--partner-of` pattern matches no device: error with device list
- `--partner-of` pattern matches multiple devices: interactive selection (existing flow)
- Partner already registered: error "partner 'primary:role' already exists"

## 2. Fuzzy Partner Matching

Enable shorthand like `"1.9:ppk2"` to resolve partner devices.

**Current behavior:** When pattern contains `:`, partners are included in substring/regex matching against full device names. `"1.9:ppk2"` fails because it doesn't literally appear in `"MPCB 1.9 Development:ppk2"`.

**New behavior in `_find_matching_indices`:** When pattern contains `:`, split on the first `:`:

- **Left side**: fuzzy-match against primary device names only (substring or regex, case-insensitive)
- **Right side**: exact-match as role suffix (case-insensitive)
- **Compose**: for each primary match, check if `"<primary>:<role>"` exists in DEVICE_NAMES
- If multiple matches, collect all and let the existing selection flow handle disambiguation

**Exact match still takes priority:** The existing exact-match pass runs first (lines 306-311), so `"MPCB 1.9 Development:ppk2"` still resolves directly without hitting the split logic.

## Files Changed

- `usb-device` (main script): `cmd_register()`, `_find_matching_indices()`

## Testing

- BATS tests for register with `--partner-of`
- BATS tests for fuzzy partner matching (`"1.9:ppk2"`, ambiguous patterns, missing partners)

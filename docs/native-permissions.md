# Native helper permissions

CuaAgent holds Accessibility and Screen Recording grants. Starting the helper,
reading status, running `cua doctor`, or attempting capture does not request them.
Capture without a grant fails with `permission_denied`. Request access explicitly:

```sh
cua permissions accessibility
cua permissions screen-recording
```

The helper requests each permission at most once per process. Grant access yourself
in System Settings > Privacy & Security. No command resets TCC. Protected content,
minimized windows and platform restrictions can still prevent capture.

## Stable signing

The old ad-hoc signature identified the helper by its binary hash. Rebuilding changed
that identity. Use a persistent certificate instead; never use an identifier-only
custom designated requirement.

One-time setup, **only with the owner's approval**:

```sh
bash scripts/setup-signing.sh
```

This creates `CUA Local Development` in the login Keychain and trusts it for code
signing only. It does not grant privacy access, enable TLS trust, change account
settings, or grant every application access to the private key. Keep that identity;
replacing it may require new privacy grants. A Developer ID identity can be selected
with `CUA_SIGNING_IDENTITY` instead. Local signing is not Apple notarization and does
not make a distributable trusted release for other machines.

Build without affecting the installed helper:

```sh
python3 scripts/build-native.py --build-only /path/to/empty-output
```

Install just the native apps (no MCP registration, browser, dependency install,
provider settings or TCC changes):

```sh
python3 scripts/build-native.py
```

This compiles and verifies every replacement before stopping the installed helper,
retains the previous bundles for rollback, and launches the replacement agent.
It interrupts native CUA sessions. Existing rollback bundles must be inspected and
moved aside before another upgrade; they are never silently deleted. Full
`install.sh` also registers integrations and is not necessary for a helper repair.

The first migration from ad-hoc signing can require a manual privacy regrant.
A matching certificate-bound designated requirement is necessary for stable future
identity, but does not guarantee that every macOS version retains every grant.
Test an actual signed upgrade before claiming that on a particular machine.

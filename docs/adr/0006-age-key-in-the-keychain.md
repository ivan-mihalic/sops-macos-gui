# ADR 0006 — The age key lives in the Keychain, unlocked once per launch

**Date:** 2026-09-03
**Status:** Accepted
**Milestone:** M3 (SOPS-46, feature f65)

## Context

Until this decision, `SessionKeyStore` held the age identity in a single `private var` for
the lifetime of the process and nowhere else. That is a real property, and the type's own
doc comment defends it at length: no disk, no `UserDefaults`, no Keychain, cleared on sleep
and on a TTL. It also has a cost the app charged the user every single time: **a relaunch
means importing the key again**, by paste or by pointing at a `keys.txt`. For a tool someone
opens several times a day, that turns the most sensitive gesture in the app — handling a raw
private key — into the most frequent one, which is the wrong way round.

PROPOSAL.md §9 has always listed "Keychain + Touch ID" as M3's first item. This ADR records
what was actually decided when it came to be built, because two of the three choices below
were not obvious and one of them costs something worth naming out loud.

## Decision

### 1. The key is stored in the data-protection keychain behind `SecAccessControl`

One `kSecClassGenericPassword` item, `kSecUseDataProtectionKeychain: true`,
`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, `kSecAttrSynchronizable: false`, and an
access control created with `.userPresence`.

`kSecUseDataProtectionKeychain` is not a detail. The older file-based keychain **silently
ignores** `kSecAttrAccessControl`: the item would be stored, everything would appear to work,
and the Touch ID gate this whole decision is about would not exist. `KeychainAgeKeyVaultTests`
asserts that one dictionary key for exactly this reason.

`.userPresence` rather than `.biometryCurrentSet`. The stricter flag invalidates the stored
item whenever the enrolled fingerprint set changes — enrol a finger in System Settings and
the key is gone, with no warning and no way back. That trades a real data-loss mode for
protection against an attacker who is already able to enrol their own fingerprint on the
unlocked Mac, which is to say against someone who has already won. `.userPresence` also keeps
the password fallback, so a failing Touch ID sensor does not lock the owner out of their key.

### 2. Unlock happens once per launch, not once per use

The alternative — a Touch ID prompt in front of every decrypt — is genuinely more secure and
was considered and rejected. Once unlocked, the key sits in `SessionKeyStore` exactly as it
did before this ADR, under the same TTL and the same sleep observer.

**The cost, stated plainly:** this decision buys nothing for in-memory hygiene. The section
of `SessionKeyStore`'s doc comment headed "What this does *not* protect against" — a Swift
`String` cannot be reliably zeroed, and the runtime may hold copies — is still true, word for
word, and this ADR does not fix it. That comment used to say the actual fix was "M3's
Keychain-backed store, which never materializes the key as a long-lived Swift `String`".
That fix is the *per-use* design, not this one. What this decision buys is that a relaunch,
a sleep, or an elapsed TTL costs a Touch ID instead of a re-import — a usability property,
and an exposure reduction only in the sense that the raw key stops passing through the
clipboard and a text field several times a day.

### 3. Storing is opt-in, and failing to store never fails the import

`importKey(_:remember:)` defaults `remember` to `false`. Writing a private key durably is a
decision, and a pre-ticked checkbox is not one the user made.

When the vault refuses the write, the import still succeeds and the failure comes back as a
*returned warning* rather than a thrown error. By that point the key has been validated and
installed in memory: the session works completely. Throwing would report total failure for
something that failed only for next time, and would send the user back to a paste field for
no reason.

### 4. `forget()` now means "locked", and deleting is a separate verb

`KeyStoreState` gains a third case, `.locked`: a key is stored but has not been unlocked in
this run. `forget()` — which the sleep observer and the TTL both call, many times a day —
drops to `.locked` and destroys nothing. `forgetPermanently()` is the only thing that empties
the vault, and it exists only as a deliberate user gesture. Fusing the two would mean closing
the lid deletes your key.

`.locked` is a third case rather than a flavour of `.empty` because the two ask the user for
opposite things: `.empty` needs an import, `.locked` needs a Touch ID. Every screen that
offers "import a key" to someone who already has one stored is telling them to redo work they
have already done.

## Consequences

### The signing work this needed, and what it actually took (SOPS-49)

The data-protection keychain gates access by keychain access group, derived from the
`application-identifier` and `keychain-access-groups` entitlements. This app shipped as a
Developer ID build with **no entitlements file at all**, so `SecItemAdd` returned
`errSecMissingEntitlement` (-34018).

Done on 2026-09-03, with an App Store Connect API key holding the Admin role:

| Thing | Identifier |
|---|---|
| App ID `cz.mihalic.SopsGUI` | `8GFGWUQMWS` |
| Profile `SOPS GUI Developer ID` (`MAC_APP_DIRECT`) | `VHHP89JJ8S`, valid to 2044 |

Three findings worth writing down, because each contradicts something that gets assumed:

1. **The "Keychain Sharing" capability cannot be enabled through the API** — it is not in
   `capabilityType`'s vocabulary, which offers only `ICLOUD` and `IN_APP_PURCHASE`. It also
   turned out not to be needed: the issued profile carries
   `keychain-access-groups = ['NA99TRHL4B.*']` on its own.
2. **A Developer ID profile does not expire in a year.** It inherits the signing
   certificate's life — this one runs to 2044. The annual expiry everyone quotes belongs to
   development and App Store profiles.
3. **`codesign` does not expand `$(AppIdentifierPrefix)`.** Only Xcode does, from the profile.
   A signature applied outside Xcode with the entitlements file verbatim carries the literal
   string, and the binary is killed exactly as if the entitlement were unauthorised. That is
   why `project.yml` signs with `CODE_SIGN_STYLE: Manual` and a named profile rather than
   leaving it all to the release driver.

### What is still unverified, and by whom it has to be verified

The app **builds, signs, embeds the profile and launches** — measured: the Release build
carries `keychain-access-groups = NA99TRHL4B.cz.mihalic.SopsGUI` in its signature and starts
normally.

What is **not** established is that `SecItemAdd` then succeeds. Every probe run from this
machine's agent shell returned `errSecInteractionNotAllowed` (-25308) for anything touching
the data-protection keychain or a `SecAccessControl`, and `errSecSuccess` only for a plain
legacy-keychain write — the same result from a CLI binary, from a bundled binary launched
through LaunchServices, from an `NSApplication` running as an accessory, with and without the
App Sandbox, and with an explicit `kSecAttrAccessGroup`. Whether that is a property of how
those probes were launched or a real obstacle for the shipped app is **not something this
repository can answer**: it needs a human at the machine, pressing the button and putting a
finger on the sensor.

Decision 3 above is what makes that acceptable to ship: if `SecItemAdd` does fail, the import
still succeeds, the warning says the key was not saved, and the app behaves exactly as it did
before this ADR. Nothing regresses either way.

### Copy that was true stopped being true

Three shipped strings promised the app "never writes it down" / "never written to disk". They
were accurate and are not any more. All three were rewritten, and
`KeychainKeyStorageCopyTests` now fails the build on the claim rather than on the sentence, so
a reworded relapse is caught too. This is the part of the change most likely to be got wrong
later: adding a `SecItemAdd` call does not, on its own, make any test go red about what the
UI promises.

### What is tested and what is not

Everything above `AgeKeyVault` is covered by `InMemoryAgeKeyVault` — the three states, the
TTL falling back to `.locked`, unlock authenticating exactly once per launch, an import
surviving a failed save. The `SecItem*` calls themselves are not, and cannot be: reading the
item requires a user presence check, and a test process has no user (in this repo's headless
`Background` launchd session it has no window server to draw the sheet on either). A test
that "verified" the round trip would either hang or be measuring a mock. The round trip is on
the ticket's manual acceptance list, where the fact that a human has to do it is visible.

## Alternatives considered

**Secure Enclave.** The Enclave cannot hold an age identity — it does P-256, age is X25519 —
so this would mean generating an SE key and using it to wrap the age key into a blob in
Application Support. It avoids the entitlement problem, but it is a hand-rolled crypto layer
protecting a file this app would have to manage itself, against a Keychain item the OS
manages. Not worth it unless the entitlement route turns out to be blocked.

**A file at `~/.config/sops/age/keys.txt`, remembering only the path.** This is what
`SecurityPostureCheck`'s `security.legacy-key-file` finding exists to warn *against*. An app
whose health report flags that file cannot also recommend it.

**Touch ID on every use.** Better hygiene, worse ergonomics, and the decision was the user's
to make (2026-09-03). Reversing it later is a change to `SessionKeyStore.unlock` and its
callers, not to the vault — the seam this ADR introduces is the same either way.

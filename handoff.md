# Handoff: sops-macos-gui — continue on Mac Studio 
## State - Private repo created: 
https://github.com/ivan-mihalic/sops-macos-gui (MIT 
license, branch `master`) - `PROPOSAL.md` committed 
& pushed — **the single source of truth** for scope, 
architecture, security model, UI, help content, 
release pipeline, DX extras, milestones. Read it 
first; do not re-litigate decisions captured there. 
- No code yet. Next milestone: **M0 — spike the Go 
bridge** (PROPOSAL.md §8). ## Key decisions already 
made (details in PROPOSAL.md) - Open source (MIT), 
private until first functional version; 
Buy-me-a-coffee; **no App Store** → no sandbox - 
SwiftUI, macOS 26+ HIG incl. Liquid Glass; sidebar 
layout, About+Settings bottom; `⌘,` settings; 
light/dark auto; String Catalogs (en only) - Engine: 
upstream sops+age Go code as xcframework (c-archive) 
in-process; **fallback = bundled binaries as 
subprocess**. Never reimplement SOPS format; CLI 
byte-compatibility is a hard requirement. - Keys: 
only user's own private age key (Keychain + Touch 
ID, SE-wrapped, session TTL, reveal+copy with 
clipboard auto-clear). Colleagues/servers = public 
keys only in `.sops.yaml`. - Releases: build locally 
on Mac Studio, notarize, upload dmg+zip to GitHub 
Releases (same as engram / ui-tester). Sparkle 2 
auto-updates. ## Machine-specific (Mac Studio) - 
Apple credentials expected at 
`~/Development/_apple-developer-id/mac_studio/` 
(AuthKey .p8, DeveloperID .p12, cert). Issuer/Key 
IDs are in PROPOSAL.md §6. Verify the folder exists 
on the Studio; never commit these files. - Verify 
`sops` + `age` installed (needed as compatibility 
oracle for the spike): `brew install sops age` ## 
Next step: M0 spike (go/no-go) Goal: prove Swift can 
call sops encrypt/decrypt in-process via a Go 
c-archive/xcframework, producing files the standard 
`sops` CLI decrypts (and vice versa), incl. MAC + 
`encrypted_regex`. 1. Thin Go wrapper module around 
`getsops/sops` (decrypt API is public; encrypt may 
need internal-package shim) + `filippo.io/age` 2. 
`go build -buildmode=c-archive` → xcframework 
(arm64) 3. Minimal Swift CLI/test target: encrypt 
YAML → decrypt with `sops` CLI; encrypt with CLI → 
decrypt via bridge; round-trip byte/MAC checks 4. If 
blocked → document why and switch to the subprocess 
fallback; record the decision in the repo (ADR or 
PROPOSAL amendment) ## Suggested skills - 
`superpowers:writing-plans` — before starting M1 
(after spike verdict) - 
`superpowers:test-driven-development` — for the 
spike's compatibility tests and all M1+ code - 
`superpowers:verification-before-completion` — 
before claiming spike success (run the actual CLI 
round-trip) ## Open questions (PROPOSAL.md §9 — ask 
user when relevant)
App name; v1 formats (YAML only vs +dotenv/JSON); arm64-only?; macOS 26 minimum vs 15+.

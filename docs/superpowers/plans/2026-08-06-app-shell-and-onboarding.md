# App Shell & Onboarding Health Check — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a launchable, notarizable macOS app shell with the in-process SOPS engine wired in, plus the complete re-runnable onboarding/health-check system described in PROPOSAL.md §6.

**Architecture:** All logic lives in a local SwiftPM package (`Packages/SopsGUIKit`) so `swift test` is the fast TDD loop; a thin Xcode app target — generated from a committed `project.yml` via XcodeGen — links that package and exists only for archiving, signing and notarization. The Go bridge proven in M0 is promoted out of `spike/` into `Engine/` and consumed as a binary xcframework target. Health checks are independent values behind one protocol, each returning a status plus an optional copyable remediation command; the runner knows nothing about individual checks. Checks whose subject does not exist yet (Keychain key store, Sparkle, the project list) depend on injected protocols and report `.skipped` with a reason until their milestone lands.

**Tech Stack:** Swift 6, SwiftUI, swift-testing, SwiftPM, XcodeGen, Go 1.26 (cgo `c-archive`), upstream `getsops/sops` v3.13.3, `filippo.io/age` v1.3.1.

## Global Constraints

- **arm64-only.** One slice. Do not add x86_64 anywhere.
- **Deployment target is one variable.** `MACOSX_DEPLOYMENT_TARGET` defaults to `14.0` in `Engine/build-xcframework.sh` and must equal `platforms:` in `Package.swift` and `deploymentTarget` in `project.yml`. Mismatch produces a linker warning on every object file.
- **Key material never goes through the environment.** The bridge injects age identities via its own `keyservice.KeyServiceServer`. Never call `decrypt.File`, `decrypt.Data`, or set `SOPS_AGE_KEY`/`SOPS_AGE_KEY_FILE` in app code. (ADR 0001.)
- **The app never mutates the system.** No check and no remediation may run an installer, a package manager, `sudo`, or any command that changes state outside the app's own data. Remediation is an explanation plus a string the user can copy. (PROPOSAL.md §6.)
- **No secret values in logs, errors, or crash reports.** Error messages may name a file or a key name, never a value.
- **All user-facing strings go through String Catalogs** (`Localizable.xcstrings`), English only, from the first view onward. (PROPOSAL.md §3.)
- **Nothing blocks.** A failing health check never prevents using the app.
- **Network access is consent-gated and offline-tolerant.** The only network call in this plan is the upstream version lookup; with consent off or the network down it reports `.unknown`, never an error dialog.
- **Every check states its own limits.** Where the app cannot actually verify something (see Task 11), the UI copy must say what it did verify.

---

## File Structure

| Path | Responsibility |
|---|---|
| `project.yml` | XcodeGen spec: app target, signing, Info.plist, package dependency. Committed; `.xcodeproj` is generated and gitignored. |
| `Scripts/bootstrap.sh` | One command for a fresh clone: build the bridge, generate the Xcode project. |
| `Engine/` | The Go bridge, promoted from `spike/`. Unchanged in behaviour. |
| `Engine/build-xcframework.sh` | Produces `Engine/build/SopsBridge.xcframework`. |
| `App/SopsGUIApp.swift` | `@main`, window and scene configuration, `⌘,` settings scene. |
| `App/Info.plist` | Bundle identity, category, hardened-runtime-relevant keys. |
| `Packages/SopsGUIKit/Package.swift` | Targets: `SopsEngine`, `SopsHealth`, `SopsUI`, plus test targets. |
| `Sources/SopsEngine/SopsBridge.swift` | Swift wrapper over the C API (promoted from the spike). |
| `Sources/SopsEngine/EngineVersion.swift` | Reads the sops/age versions compiled into the bridge. |
| `Sources/SopsHealth/HealthCheck.swift` | `HealthCheck` protocol, `HealthStatus`, `HealthFinding`, `Remediation`. |
| `Sources/SopsHealth/HealthReport.swift` | Runs a set of checks concurrently, aggregates, re-runs. |
| `Sources/SopsHealth/SemanticVersion.swift` | Parsing and comparison. Pure value type. |
| `Sources/SopsHealth/ToolLocator.swift` | PATH-independent discovery of CLI tools + version probing. |
| `Sources/SopsHealth/Checks/ExternalToolCheck.swift` | §6 A — sops, age, git, yq, docker. |
| `Sources/SopsHealth/Checks/EngineFreshnessCheck.swift` | §6 B — embedded vs upstream. |
| `Sources/SopsHealth/Checks/SecurityPostureCheck.swift` | §6 C — macOS, biometrics, key store, stray keys.txt. |
| `Sources/SopsHealth/Checks/ProjectHealthCheck.swift` | §6 D — `.sops.yaml`, stale recipients, gitignore leaks. |
| `Sources/SopsHealth/UpstreamVersionSource.swift` | GitHub releases lookup behind a protocol. |
| `Sources/SopsUI/AppShell.swift` | `NavigationSplitView`, sidebar with About/Settings pinned at the bottom. |
| `Sources/SopsUI/Health/HealthPanel.swift` | The re-runnable report view used inside Settings. |
| `Sources/SopsUI/Health/HealthFindingRow.swift` | One finding: status glyph, title, detail, remediation. |
| `Sources/SopsUI/Health/OnboardingWizard.swift` | First-launch modal; steps through categories. |
| `Sources/SopsUI/Resources/Localizable.xcstrings` | All user-facing strings. |
| `Sources/SopsUI/Resources/LocalizedKey.swift` | Typed keys into the catalog; a missing entry becomes a test failure. |

---

### Task 1: Repo skeleton and a launchable empty app

**Files:**
- Create: `project.yml`
- Create: `App/SopsGUIApp.swift`
- Create: `App/Info.plist`
- Create: `Packages/SopsGUIKit/Package.swift`
- Create: `Packages/SopsGUIKit/Sources/SopsUI/AppShell.swift`
- Create: `Packages/SopsGUIKit/Tests/SopsUITests/AppShellTests.swift`
- Create: `Scripts/bootstrap.sh`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: nothing.
- Produces: `AppShell` (a SwiftUI `View` with an `init()`), the `SopsGUIKit` package with targets `SopsUI`, and the `sops-gui` Xcode scheme.

- [ ] **Step 1: Write the failing test**

`Packages/SopsGUIKit/Tests/SopsUITests/AppShellTests.swift`:

```swift
import Testing
@testable import SopsUI

@Test("the shell exposes the navigation sections the sidebar renders")
func shellSections() {
    #expect(AppShell.Section.allCases.map(\.rawValue) == ["projects", "about", "settings"])
}

@Test("about and settings are pinned to the bottom of the sidebar")
func pinnedSections() {
    #expect(AppShell.Section.pinnedToBottom == [.about, .settings])
}
```

`Packages/SopsGUIKit/Tests/SopsUITests/LocalizationTests.swift`:

```swift
import Foundation
import Testing
@testable import SopsUI

@Suite("localization")
struct LocalizationTests {

    @Test("the string catalog ships in the module bundle")
    func catalogIsBundled() throws {
        #expect(Bundle.module.url(forResource: "Localizable", withExtension: "xcstrings") != nil,
                "Localizable.xcstrings is missing from the SopsUI bundle")
    }

    // Every view added in any task must add its keys here. A key that resolves
    // to itself means the catalog entry was forgotten.
    @Test("every key this module uses resolves to English text, not to the key",
          arguments: LocalizedKey.allCases)
    func everyKeyResolves(key: LocalizedKey) {
        #expect(key.text != key.rawValue, "missing catalog entry for \(key.rawValue)")
    }
}
```

- [ ] **Step 1b: Extend the failing test to cover the sidebar's own keys**

Append to `AppShellTests.swift`:

```swift
@Test("the sidebar labels come from the string catalog")
func sidebarLabelsAreLocalized() {
    #expect(LocalizedKey.sidebarProjects.text == "Projects")
    #expect(LocalizedKey.sidebarAbout.text == "About")
    #expect(LocalizedKey.sidebarSettings.text == "Settings")
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd Packages/SopsGUIKit && swift test
```

Expected: FAIL — `cannot find 'AppShell' in scope`.

- [ ] **Step 3: Create the package manifest**

`Packages/SopsGUIKit/Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SopsGUIKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SopsUI", targets: ["SopsUI"])
    ],
    targets: [
        .target(name: "SopsUI", resources: [.process("Resources")]),
        .testTarget(name: "SopsUITests", dependencies: ["SopsUI"]),
    ]
)
```

- [ ] **Step 3b: Create the string catalog and its key type**

Every user-facing string in this module goes through here, from the first view
onward — that is a Global Constraint, not a later cleanup. `LocalizedKey` makes
a forgotten entry a test failure instead of a string that silently renders as
its own key.

`Packages/SopsGUIKit/Sources/SopsUI/Resources/Localizable.xcstrings`:

```json
{
  "sourceLanguage" : "en",
  "version" : "1.0",
  "strings" : {
    "sidebar.projects" : {
      "extractionState" : "manual",
      "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Projects" } } }
    },
    "sidebar.about" : {
      "extractionState" : "manual",
      "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "About" } } }
    },
    "sidebar.settings" : {
      "extractionState" : "manual",
      "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "Settings" } } }
    },
    "detail.no-selection" : {
      "extractionState" : "manual",
      "localizations" : { "en" : { "stringUnit" : { "state" : "translated", "value" : "No project selected" } } }
    }
  }
}
```

`Packages/SopsGUIKit/Sources/SopsUI/Resources/LocalizedKey.swift`:

```swift
import Foundation
import SwiftUI

/// Every user-facing string this module can render.
///
/// Views never take a string literal. Adding a case without adding the matching
/// entry to Localizable.xcstrings fails `everyKeyResolves`.
public enum LocalizedKey: String, CaseIterable, Sendable {
    case sidebarProjects = "sidebar.projects"
    case sidebarAbout = "sidebar.about"
    case sidebarSettings = "sidebar.settings"
    case detailNoSelection = "detail.no-selection"

    /// The resolved English text. Used in views and asserted in tests.
    public var text: String {
        String(localized: String.LocalizationValue(rawValue), bundle: .module)
    }
}

extension Text {
    init(_ key: LocalizedKey) {
        self.init(key.text)
    }
}

extension Label where Title == Text, Icon == Image {
    init(_ key: LocalizedKey, systemImage: String) {
        self.init(key.text, systemImage: systemImage)
    }
}
```

- [ ] **Step 4: Write the minimal shell**

`Packages/SopsGUIKit/Sources/SopsUI/AppShell.swift`:

```swift
import SwiftUI

public struct AppShell: View {
    public enum Section: String, CaseIterable, Hashable {
        case projects, about, settings

        /// PROPOSAL.md §4: About and Settings sit at the bottom of the sidebar.
        public static let pinnedToBottom: [Section] = [.about, .settings]
    }

    @State private var selection: Section = .projects

    public init() {}

    public var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label(.sidebarProjects, systemImage: "folder")
                    .tag(Section.projects)
                Spacer()
                Label(.sidebarAbout, systemImage: "info.circle")
                    .tag(Section.about)
                Label(.sidebarSettings, systemImage: "gearshape")
                    .tag(Section.settings)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            Text(.detailNoSelection)
                .foregroundStyle(.secondary)
        }
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

```bash
cd Packages/SopsGUIKit && swift test
```

Expected: PASS — 2 shell tests, 1 sidebar-label test, and the localization suite
(1 bundle test plus one case per `LocalizedKey`).

- [ ] **Step 6: Write the app entry point**

`App/SopsGUIApp.swift`:

```swift
import SwiftUI
import SopsUI

@main
struct SopsGUIApp: App {
    var body: some Scene {
        WindowGroup {
            AppShell()
        }
        // ⌘, is wired automatically by the Settings scene (PROPOSAL.md §4).
        Settings {
            Text("Settings")
                .frame(width: 480, height: 320)
        }
    }
}
```

- [ ] **Step 7: Write the XcodeGen spec**

`project.yml`:

```yaml
name: SopsGUI
options:
  bundleIdPrefix: cz.mihalic
  deploymentTarget:
    macOS: "14.0"
  createIntermediateGroups: true
settings:
  base:
    SWIFT_VERSION: "6.0"
    ARCHS: arm64
    ONLY_ACTIVE_ARCH: YES
    ENABLE_HARDENED_RUNTIME: YES
packages:
  SopsGUIKit:
    path: Packages/SopsGUIKit
targets:
  SopsGUI:
    type: application
    platform: macOS
    sources:
      - App
    info:
      path: App/Info.plist
      properties:
        CFBundleName: SOPS GUI
        LSApplicationCategoryType: public.app-category.developer-tools
        LSMinimumSystemVersion: "14.0"
    dependencies:
      - package: SopsGUIKit
        product: SopsUI
```

- [ ] **Step 8: Write the bootstrap script**

`Scripts/bootstrap.sh`:

```bash
#!/usr/bin/env bash
# Everything a fresh clone needs before opening Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null || { echo "need: brew install xcodegen"; exit 1; }

echo "==> generating SopsGUI.xcodeproj"
xcodegen generate

echo "==> done. Open SopsGUI.xcodeproj, or run: cd Packages/SopsGUIKit && swift test"
```

- [ ] **Step 9: Extend .gitignore**

Append to `.gitignore`:

```
# Generated by XcodeGen from project.yml — never commit
SopsGUI.xcodeproj/
```

- [ ] **Step 10: Verify the app builds and launches**

```bash
chmod +x Scripts/bootstrap.sh && ./Scripts/bootstrap.sh
xcodebuild -project SopsGUI.xcodeproj -scheme SopsGUI -configuration Debug build
```

Expected: `BUILD SUCCEEDED`. Then launch the built `.app` from `~/Library/Developer/Xcode/DerivedData/.../Build/Products/Debug/` and confirm a window opens with a sidebar, and `⌘,` opens a Settings window.

- [ ] **Step 11: Commit**

```bash
git add project.yml App Packages Scripts .gitignore
git commit -m "M1: app shell scaffold — XcodeGen project, SwiftPM kit, launchable window"
```

---

### Task 2: Promote the M0 bridge out of the spike

**Files:**
- Create: `Engine/` (moved from `spike/`, git mv)
- Delete: `spike/`
- Modify: `Packages/SopsGUIKit/Package.swift`
- Create: `Packages/SopsGUIKit/Sources/SopsEngine/SopsBridge.swift` (moved)
- Create: `Packages/SopsGUIKit/Tests/SopsEngineTests/CompatibilityTests.swift` (moved)
- Modify: `Scripts/bootstrap.sh`

**Interfaces:**
- Consumes: `Engine/build-xcframework.sh` from M0.
- Produces: `SopsEngine.SopsBridge.encryptYAML(_:recipients:encryptedRegex:) throws -> String`, `SopsEngine.SopsBridge.decryptYAML(_:agePrivateKey:) throws -> String`, `SopsEngine.SopsBridgeError`.

- [ ] **Step 1: Move the Go side**

```bash
git mv spike Engine
git mv Engine/Sources/SopsBridge/SopsBridge.swift Packages/SopsGUIKit/Sources/SopsEngine/SopsBridge.swift
git mv Engine/Tests/SopsBridgeTests/CompatibilityTests.swift Packages/SopsGUIKit/Tests/SopsEngineTests/CompatibilityTests.swift
git mv Engine/Tests/SopsBridgeTests/TestSupport.swift Packages/SopsGUIKit/Tests/SopsEngineTests/TestSupport.swift
rm -rf Engine/Package.swift Engine/Sources Engine/Tests
```

Update the module path in `Engine/go.mod` and both Go files that reference it:

```bash
sed -i '' 's|/spike|/engine|' Engine/go.mod Engine/cshim/main.go
cd Engine && go test ./...
```

Expected: `ok ... /engine/gobridge`.

- [ ] **Step 2: Point the package at the xcframework**

In `Packages/SopsGUIKit/Package.swift`, add to `products`, `targets`:

```swift
        .library(name: "SopsEngine", targets: ["SopsEngine"]),
```

```swift
        .binaryTarget(
            name: "CSopsBridge",
            path: "../../Engine/build/SopsBridge.xcframework"
        ),
        .target(
            name: "SopsEngine",
            dependencies: ["CSopsBridge"],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("CoreFoundation"),
                .linkedLibrary("resolv"),
            ]
        ),
        .testTarget(name: "SopsEngineTests", dependencies: ["SopsEngine"]),
```

- [ ] **Step 3: Fix the moved test's import**

In `CompatibilityTests.swift`, change `@testable import SopsBridge` to:

```swift
@testable import SopsEngine
```

- [ ] **Step 4: Run the ported tests**

```bash
Engine/build-xcframework.sh
cd Packages/SopsGUIKit && swift test --filter SopsEngineTests
```

Expected: PASS, the same 5 compatibility tests that passed in M0.

- [ ] **Step 5: Wire the engine into bootstrap and the app target**

In `Scripts/bootstrap.sh`, before `xcodegen generate`:

```bash
echo "==> building the SOPS bridge"
Engine/build-xcframework.sh
```

In `project.yml`, add to the `SopsGUI` target's `dependencies`:

```yaml
      - package: SopsGUIKit
        product: SopsEngine
```

- [ ] **Step 6: Verify the app still builds with the engine linked**

```bash
./Scripts/bootstrap.sh
xcodebuild -project SopsGUI.xcodeproj -scheme SopsGUI -configuration Debug build
```

Expected: `BUILD SUCCEEDED`, no `was built for newer 'macOS' version` warnings.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "M1: promote the M0 bridge from spike/ to Engine/, link it into the app"
```

---

### Task 3: Engine version introspection

The freshness check (Task 10) needs to know which sops and age versions are actually compiled into the bridge. Only the Go side knows.

**Files:**
- Modify: `Engine/gobridge/bridge.go`
- Create: `Engine/gobridge/version_test.go`
- Modify: `Engine/cshim/main.go`
- Create: `Packages/SopsGUIKit/Sources/SopsEngine/EngineVersion.swift`
- Create: `Packages/SopsGUIKit/Tests/SopsEngineTests/EngineVersionTests.swift`

**Interfaces:**
- Consumes: `SopsEngine` from Task 2.
- Produces: `SopsEngine.EngineVersion.sops: String`, `SopsEngine.EngineVersion.age: String` — both bare versions with no leading `v`, e.g. `"3.13.3"`, `"1.3.1"`.

- [ ] **Step 1: Write the failing Go test**

`Engine/gobridge/version_test.go`:

```go
package gobridge

import (
	"regexp"
	"testing"
)

// The freshness check compares these against upstream releases, so they must be
// bare semver with no "v" prefix and no build metadata.
func TestEngineVersionsAreBareSemver(t *testing.T) {
	semver := regexp.MustCompile(`^\d+\.\d+\.\d+$`)

	for name, got := range map[string]string{
		"sops": SopsVersion(),
		"age":  AgeVersion(),
	} {
		if !semver.MatchString(got) {
			t.Errorf("%s version %q is not bare semver", name, got)
		}
	}
}

// A stale hand-maintained constant is worse than no check at all, so the sops
// version must come from the module we actually linked.
func TestSopsVersionMatchesLinkedModule(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted, err := Encrypt([]byte(plainYAML), FormatYAML, EncryptOpts{
		AgeRecipients: []string{key.Public},
	})
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}
	want := "version: " + SopsVersion()
	if !containsLine(string(encrypted), want) {
		t.Errorf("encrypted file does not carry %q", want)
	}
}

func containsLine(haystack, needle string) bool {
	for _, line := range regexp.MustCompile(`\r?\n`).Split(haystack, -1) {
		if regexp.MustCompile(`^\s*`).ReplaceAllString(line, "") == needle {
			return true
		}
	}
	return false
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd Engine && go test ./gobridge/ -run Version
```

Expected: FAIL — `undefined: SopsVersion`.

- [ ] **Step 3: Implement the accessors**

Append to `Engine/gobridge/bridge.go`:

```go
// SopsVersion reports the sops version compiled into this bridge, taken from
// the linked module rather than a hand-maintained constant.
func SopsVersion() string {
	return strings.TrimPrefix(version.Version, "v")
}

// AgeVersion reports the filippo.io/age version compiled into this bridge.
// age exposes no version constant, so it is read from the build info.
func AgeVersion() string {
	info, ok := debug.ReadBuildInfo()
	if !ok {
		return "0.0.0"
	}
	for _, dep := range info.Deps {
		if dep.Path == "filippo.io/age" {
			return strings.TrimPrefix(dep.Version, "v")
		}
	}
	return "0.0.0"
}
```

Add `"runtime/debug"` to the import block.

- [ ] **Step 4: Run it to verify it passes**

```bash
cd Engine && go test ./gobridge/
```

Expected: PASS. If `AgeVersion` returns `0.0.0`, the test binary lacks build info — run `go test` (not a prebuilt binary) and confirm `filippo.io/age` is a direct requirement in `go.mod`.

- [ ] **Step 5: Expose both across the C boundary**

Append to `Engine/cshim/main.go`:

```go
//export sops_engine_versions
func sops_engine_versions(outSops **C.char, outAge **C.char) {
	*outSops = C.CString(gobridge.SopsVersion())
	*outAge = C.CString(gobridge.AgeVersion())
}
```

- [ ] **Step 6: Write the failing Swift test**

`Packages/SopsGUIKit/Tests/SopsEngineTests/EngineVersionTests.swift`:

```swift
import Testing
@testable import SopsEngine

@Test("the embedded sops version is readable and is bare semver")
func embeddedSopsVersion() throws {
    let version = EngineVersion.sops
    #expect(version.split(separator: ".").count == 3)
    #expect(!version.hasPrefix("v"))
}

@Test("the embedded age version is readable and is bare semver")
func embeddedAgeVersion() throws {
    let version = EngineVersion.age
    #expect(version.split(separator: ".").count == 3)
    #expect(!version.hasPrefix("v"))
}
```

- [ ] **Step 7: Run it to verify it fails**

```bash
cd Packages/SopsGUIKit && swift test --filter EngineVersion
```

Expected: FAIL — `cannot find 'EngineVersion' in scope`.

- [ ] **Step 8: Implement the Swift side**

`Packages/SopsGUIKit/Sources/SopsEngine/EngineVersion.swift`:

```swift
import CSopsBridge
import Foundation

/// The sops and age versions compiled into the bridge. Read once at first use —
/// they cannot change while the process is running.
public enum EngineVersion {
    public static let sops: String = versions.sops
    public static let age: String = versions.age

    private static let versions: (sops: String, age: String) = {
        var sopsPtr: UnsafeMutablePointer<CChar>?
        var agePtr: UnsafeMutablePointer<CChar>?
        sops_engine_versions(&sopsPtr, &agePtr)
        defer {
            if let sopsPtr { sops_free(sopsPtr) }
            if let agePtr { sops_free(agePtr) }
        }
        return (
            sopsPtr.map { String(cString: $0) } ?? "0.0.0",
            agePtr.map { String(cString: $0) } ?? "0.0.0"
        )
    }()
}
```

- [ ] **Step 9: Rebuild the bridge and run the tests**

```bash
Engine/build-xcframework.sh
cd Packages/SopsGUIKit && swift test
```

Expected: PASS, all targets.

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "M1: expose the embedded sops and age versions through the bridge"
```

---

### Task 4: SemanticVersion

Every check that says "outdated" needs to compare versions. Pure value type, no I/O — the easiest thing in the plan to get subtly wrong (`1.10.0` vs `1.9.0`).

**Files:**
- Create: `Packages/SopsGUIKit/Sources/SopsHealth/SemanticVersion.swift`
- Create: `Packages/SopsGUIKit/Tests/SopsHealthTests/SemanticVersionTests.swift`
- Modify: `Packages/SopsGUIKit/Package.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `SemanticVersion(major:minor:patch:)`, `SemanticVersion(parsing: String)` (failable), `SemanticVersion: Comparable`, `SemanticVersion.description -> String` (bare, no `v`).

- [ ] **Step 1: Add the SopsHealth target**

In `Packages/SopsGUIKit/Package.swift` add to `products` and `targets`:

```swift
        .library(name: "SopsHealth", targets: ["SopsHealth"]),
```

```swift
        .target(name: "SopsHealth", dependencies: ["SopsEngine"]),
        .testTarget(name: "SopsHealthTests", dependencies: ["SopsHealth"]),
```

- [ ] **Step 2: Write the failing test**

`Packages/SopsGUIKit/Tests/SopsHealthTests/SemanticVersionTests.swift`:

```swift
import Testing
@testable import SopsHealth

@Suite("SemanticVersion")
struct SemanticVersionTests {

    @Test("parses bare and v-prefixed versions identically")
    func parsesBothForms() throws {
        #expect(SemanticVersion(parsing: "3.13.3") == SemanticVersion(3, 13, 3))
        #expect(SemanticVersion(parsing: "v3.13.3") == SemanticVersion(3, 13, 3))
    }

    @Test("treats a missing patch component as zero")
    func toleratesShortVersions() throws {
        #expect(SemanticVersion(parsing: "1.3") == SemanticVersion(1, 3, 0))
        #expect(SemanticVersion(parsing: "2") == SemanticVersion(2, 0, 0))
    }

    @Test("ignores trailing build metadata")
    func ignoresSuffix() throws {
        #expect(SemanticVersion(parsing: "2.54.0 (Apple Git-157)") == SemanticVersion(2, 54, 0))
        #expect(SemanticVersion(parsing: "1.3.1-rc.2") == SemanticVersion(1, 3, 1))
    }

    @Test("rejects strings with no leading number")
    func rejectsGarbage() throws {
        #expect(SemanticVersion(parsing: "") == nil)
        #expect(SemanticVersion(parsing: "unknown") == nil)
    }

    @Test("compares numerically, not lexicographically")
    func comparesNumerically() throws {
        #expect(SemanticVersion(1, 9, 0) < SemanticVersion(1, 10, 0))
        #expect(SemanticVersion(3, 13, 2) < SemanticVersion(3, 13, 3))
        #expect(SemanticVersion(4, 0, 0) > SemanticVersion(3, 99, 99))
    }

    @Test("renders without a v prefix")
    func rendersBare() throws {
        #expect(SemanticVersion(3, 13, 3).description == "3.13.3")
    }
}
```

- [ ] **Step 3: Run it to verify it fails**

```bash
cd Packages/SopsGUIKit && swift test --filter SemanticVersion
```

Expected: FAIL — `cannot find 'SemanticVersion' in scope`.

- [ ] **Step 4: Implement**

`Packages/SopsGUIKit/Sources/SopsHealth/SemanticVersion.swift`:

```swift
import Foundation

/// A version as printed by a CLI tool or a GitHub release tag.
/// Deliberately lenient: real tools print things like "2.54.0 (Apple Git-157)".
public struct SemanticVersion: Comparable, Equatable, Hashable, CustomStringConvertible, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init?(parsing text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .drop(while: { $0 == "v" || $0 == "V" })

        var components: [Int] = []
        var current = ""
        for character in trimmed {
            if character.isNumber {
                current.append(character)
            } else if character == "." && !current.isEmpty && components.count < 2 {
                components.append(Int(current) ?? 0)
                current = ""
            } else {
                break
            }
        }
        if !current.isEmpty { components.append(Int(current) ?? 0) }

        guard let major = components.first else { return nil }
        self.init(major, components.count > 1 ? components[1] : 0,
                  components.count > 2 ? components[2] : 0)
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
```

- [ ] **Step 5: Run it to verify it passes**

```bash
cd Packages/SopsGUIKit && swift test --filter SemanticVersion
```

Expected: PASS, 6 tests.

- [ ] **Step 6: Commit**

```bash
git add Packages/SopsGUIKit
git commit -m "M1: SemanticVersion parsing and comparison"
```

---

### Task 5: HealthCheck protocol and report runner

**Files:**
- Create: `Packages/SopsGUIKit/Sources/SopsHealth/HealthCheck.swift`
- Create: `Packages/SopsGUIKit/Sources/SopsHealth/HealthReport.swift`
- Create: `Packages/SopsGUIKit/Tests/SopsHealthTests/HealthReportTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `HealthCategory` — `.tools`, `.engine`, `.security`, `.projects`
  - `HealthStatus` — `.ok`, `.warning`, `.problem`, `.skipped(reason: String)`, `.unknown(reason: String)`
  - `Remediation(explanation: String, command: String?, documentationURL: URL?)`
  - `HealthFinding(id: String, title: String, status: HealthStatus, detail: String, remediation: Remediation?)`
  - `protocol HealthCheck: Sendable { var id: String { get }; var category: HealthCategory { get }; func run() async -> [HealthFinding] }`
  - `HealthReport(checks: [any HealthCheck])`, `HealthReport.run() async -> [HealthFinding]`, `HealthReport.worstStatus(in: [HealthFinding]) -> HealthStatus`

- [ ] **Step 1: Write the failing test**

`Packages/SopsGUIKit/Tests/SopsHealthTests/HealthReportTests.swift`:

```swift
import Testing
@testable import SopsHealth

private struct StubCheck: HealthCheck {
    let id: String
    let category: HealthCategory
    let findings: [HealthFinding]
    func run() async -> [HealthFinding] { findings }
}

private func finding(_ id: String, _ status: HealthStatus) -> HealthFinding {
    HealthFinding(id: id, title: id, status: status, detail: "", remediation: nil)
}

@Suite("HealthReport")
struct HealthReportTests {

    @Test("collects findings from every check")
    func collectsAll() async {
        let report = HealthReport(checks: [
            StubCheck(id: "a", category: .tools, findings: [finding("a1", .ok), finding("a2", .warning)]),
            StubCheck(id: "b", category: .engine, findings: [finding("b1", .ok)]),
        ])
        let findings = await report.run()
        #expect(Set(findings.map(\.id)) == ["a1", "a2", "b1"])
    }

    @Test("a check that throws or hangs must not take the report down")
    func isolatesFailures() async {
        struct ExplodingCheck: HealthCheck {
            let id = "boom"
            let category = HealthCategory.tools
            func run() async -> [HealthFinding] {
                [HealthFinding(id: "boom", title: "boom", status: .unknown(reason: "probe failed"),
                               detail: "", remediation: nil)]
            }
        }
        let report = HealthReport(checks: [
            ExplodingCheck(),
            StubCheck(id: "ok", category: .engine, findings: [finding("fine", .ok)]),
        ])
        let findings = await report.run()
        #expect(findings.count == 2)
        #expect(findings.contains { $0.id == "fine" })
    }

    @Test("the worst status wins, and problem outranks warning")
    func worstStatusOrdering() {
        #expect(HealthReport.worstStatus(in: [finding("a", .ok), finding("b", .warning)]) == .warning)
        #expect(HealthReport.worstStatus(in: [finding("a", .warning), finding("b", .problem)]) == .problem)
        #expect(HealthReport.worstStatus(in: [finding("a", .ok)]) == .ok)
    }

    @Test("skipped and unknown never mask a real problem")
    func informationalStatusesDoNotMask() {
        let findings = [
            finding("a", .skipped(reason: "arrives with Sparkle in M5")),
            finding("b", .unknown(reason: "offline")),
            finding("c", .problem),
        ]
        #expect(HealthReport.worstStatus(in: findings) == .problem)
    }

    @Test("an empty report is OK, not an error")
    func emptyIsOK() async {
        let findings = await HealthReport(checks: []).run()
        #expect(findings.isEmpty)
        #expect(HealthReport.worstStatus(in: findings) == .ok)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd Packages/SopsGUIKit && swift test --filter HealthReport
```

Expected: FAIL — `cannot find type 'HealthCheck' in scope`.

- [ ] **Step 3: Implement the types**

`Packages/SopsGUIKit/Sources/SopsHealth/HealthCheck.swift`:

```swift
import Foundation

public enum HealthCategory: String, CaseIterable, Sendable, Hashable {
    case tools, engine, security, projects
}

public enum HealthStatus: Equatable, Sendable, Hashable {
    case ok
    case warning
    case problem
    /// The check could not run because its subject does not exist yet.
    /// The reason is shown to the user verbatim — always say why.
    case skipped(reason: String)
    /// The check ran but could not reach a verdict (offline, no consent).
    case unknown(reason: String)

    /// Ordering used to pick the headline status. Informational statuses sit
    /// below `warning` so they can never hide a real finding.
    var severity: Int {
        switch self {
        case .ok: 0
        case .skipped: 1
        case .unknown: 2
        case .warning: 3
        case .problem: 4
        }
    }
}

/// What the user can do about a finding. PROPOSAL.md §6: the app shows the
/// command, the user runs it. Nothing here is ever executed by the app.
public struct Remediation: Equatable, Sendable, Hashable {
    public let explanation: String
    public let command: String?
    public let documentationURL: URL?

    public init(explanation: String, command: String? = nil, documentationURL: URL? = nil) {
        self.explanation = explanation
        self.command = command
        self.documentationURL = documentationURL
    }
}

public struct HealthFinding: Identifiable, Equatable, Sendable, Hashable {
    public let id: String
    public let title: String
    public let status: HealthStatus
    public let detail: String
    public let remediation: Remediation?

    public init(id: String, title: String, status: HealthStatus, detail: String,
                remediation: Remediation? = nil) {
        self.id = id
        self.title = title
        self.status = status
        self.detail = detail
        self.remediation = remediation
    }
}

/// One independently re-runnable diagnostic. Implementations must never mutate
/// the system and must never throw — an unrunnable probe is a `.unknown` finding.
public protocol HealthCheck: Sendable {
    var id: String { get }
    var category: HealthCategory { get }
    func run() async -> [HealthFinding]
}
```

`Packages/SopsGUIKit/Sources/SopsHealth/HealthReport.swift`:

```swift
import Foundation

/// Runs a set of checks concurrently and aggregates their findings.
/// Knows nothing about any individual check.
public struct HealthReport: Sendable {
    private let checks: [any HealthCheck]

    public init(checks: [any HealthCheck]) {
        self.checks = checks
    }

    public func run() async -> [HealthFinding] {
        await withTaskGroup(of: [HealthFinding].self) { group in
            for check in checks {
                group.addTask { await check.run() }
            }
            var all: [HealthFinding] = []
            for await findings in group {
                all.append(contentsOf: findings)
            }
            return all.sorted { $0.id < $1.id }
        }
    }

    public static func worstStatus(in findings: [HealthFinding]) -> HealthStatus {
        findings.map(\.status).max { $0.severity < $1.severity } ?? .ok
    }
}
```

- [ ] **Step 4: Run it to verify it passes**

```bash
cd Packages/SopsGUIKit && swift test --filter HealthReport
```

Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add Packages/SopsGUIKit
git commit -m "M1: HealthCheck protocol and concurrent report runner"
```

---

### Task 6: ToolLocator — finding CLI tools without inheriting PATH

A GUI app launched from Finder gets a minimal `PATH` that does not include `/opt/homebrew/bin`. Naive `which` reports every Homebrew tool as missing. This is the single most likely source of false "not installed" findings.

**Files:**
- Create: `Packages/SopsGUIKit/Sources/SopsHealth/ToolLocator.swift`
- Create: `Packages/SopsGUIKit/Tests/SopsHealthTests/ToolLocatorTests.swift`

**Interfaces:**
- Consumes: `SemanticVersion` from Task 4.
- Produces:
  - `struct LocatedTool { let name: String; let path: String; let version: SemanticVersion? ; let rawVersionOutput: String }`
  - `protocol ToolLocating: Sendable { func locate(_ name: String, versionArguments: [String]) async -> LocatedTool? }`
  - `struct ToolLocator: ToolLocating` with `init(searchPaths: [String]? = nil)`
  - `static ToolLocator.loginShellSearchPaths() -> [String]`
  - `static ToolLocator.parseVersion(from output: String) -> SemanticVersion?`

- [ ] **Step 1: Write the failing test**

`Packages/SopsGUIKit/Tests/SopsHealthTests/ToolLocatorTests.swift`:

```swift
import Foundation
import Testing
@testable import SopsHealth

@Suite("ToolLocator")
struct ToolLocatorTests {

    // Real output captured on macOS 26.5 from the tools this app cares about.
    @Test("parses the version out of each tool's real output", arguments: [
        ("sops 3.13.2\n[info] a new version of sops (v3.13.3) is available", SemanticVersion(3, 13, 2)),
        ("v1.3.1", SemanticVersion(1, 3, 1)),
        ("git version 2.54.0 (Apple Git-157)", SemanticVersion(2, 54, 0)),
        ("yq (https://github.com/mikefarah/yq/) version v4.44.3", SemanticVersion(4, 44, 3)),
        ("Docker version 29.4.0, build 9d7ad9f", SemanticVersion(29, 4, 0)),
    ])
    func parsesRealOutput(output: String, expected: SemanticVersion) {
        #expect(ToolLocator.parseVersion(from: output) == expected)
    }

    @Test("returns nil rather than a wrong version for unparseable output")
    func refusesToGuess() {
        #expect(ToolLocator.parseVersion(from: "") == nil)
        #expect(ToolLocator.parseVersion(from: "command not found") == nil)
    }

    @Test("finds a tool that exists only in a non-default search path")
    func findsToolOutsideProcessPath() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("locator-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("faketool")
        try "#!/bin/sh\necho 'faketool version 9.8.7'\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let locator = ToolLocator(searchPaths: [dir.path])
        let found = await locator.locate("faketool", versionArguments: ["--version"])

        #expect(found?.path == script.path)
        #expect(found?.version == SemanticVersion(9, 8, 7))
    }

    @Test("reports nil for a tool that is genuinely absent")
    func absentToolIsNil() async {
        let locator = ToolLocator(searchPaths: ["/nonexistent"])
        #expect(await locator.locate("definitely-not-a-tool", versionArguments: ["--version"]) == nil)
    }

    @Test("the login shell PATH includes Homebrew, which the process PATH may not")
    func loginShellPathIsRicherThanProcessPath() {
        let paths = ToolLocator.loginShellSearchPaths()
        #expect(!paths.isEmpty)
        #expect(paths.contains("/usr/bin"))
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd Packages/SopsGUIKit && swift test --filter ToolLocator
```

Expected: FAIL — `cannot find 'ToolLocator' in scope`.

- [ ] **Step 3: Implement**

`Packages/SopsGUIKit/Sources/SopsHealth/ToolLocator.swift`:

```swift
import Foundation

public struct LocatedTool: Equatable, Sendable {
    public let name: String
    public let path: String
    public let version: SemanticVersion?
    public let rawVersionOutput: String
}

public protocol ToolLocating: Sendable {
    func locate(_ name: String, versionArguments: [String]) async -> LocatedTool?
}

/// Finds CLI tools without trusting the process `PATH`.
///
/// A GUI app launched from Finder inherits a minimal environment — typically no
/// `/opt/homebrew/bin` — so `which sops` reports "missing" on a machine that has
/// it. We ask the login shell what its `PATH` is and probe well-known locations.
public struct ToolLocator: ToolLocating {
    private let searchPaths: [String]

    public init(searchPaths: [String]? = nil) {
        self.searchPaths = searchPaths ?? Self.loginShellSearchPaths()
    }

    public static func loginShellSearchPaths() -> [String] {
        var paths: [String] = []

        // -lc, never -lic: an interactive shell can block on prompts or plugins.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        if let output = try? Self.capture(shell, ["-lc", "echo $PATH"], timeout: 3) {
            paths += output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":").map(String.init)
        }

        // Fallbacks for the case where the login shell is unusable.
        paths += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    public func locate(_ name: String, versionArguments: [String]) async -> LocatedTool? {
        guard let path = searchPaths
            .map({ ($0 as NSString).appendingPathComponent(name) })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { return nil }

        let output = (try? Self.capture(path, versionArguments, timeout: 5)) ?? ""
        return LocatedTool(
            name: name,
            path: path,
            version: Self.parseVersion(from: output),
            rawVersionOutput: output.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Pulls the first version-looking token out of a tool's output.
    /// Tools print wildly different shapes; anchoring on the first token that
    /// starts with a digit (optionally after a `v`) covers all of ours.
    public static func parseVersion(from output: String) -> SemanticVersion? {
        for token in output.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            let candidate = token.drop(while: { $0 == "v" || $0 == "V" })
            guard candidate.first?.isNumber == true else { continue }
            if let version = SemanticVersion(parsing: String(candidate)) { return version }
        }
        return nil
    }

    /// Runs a command and returns stdout+stderr. Never throws for a non-zero
    /// exit — many tools print `--version` to stderr and exit non-zero.
    private static func capture(_ launchPath: String, _ arguments: [String], timeout: TimeInterval) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning { process.terminate() }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }
}
```

- [ ] **Step 4: Run it to verify it passes**

```bash
cd Packages/SopsGUIKit && swift test --filter ToolLocator
```

Expected: PASS, 9 tests (5 from the parameterised case).

- [ ] **Step 5: Verify the PATH problem is actually solved**

```bash
cd Packages/SopsGUIKit && env -u PATH swift test --filter loginShellPathIsRicherThanProcessPath
```

Expected: PASS — the locator finds paths even with no `PATH` in the environment.

- [ ] **Step 6: Commit**

```bash
git add Packages/SopsGUIKit
git commit -m "M1: ToolLocator — PATH-independent CLI discovery and version probing"
```

---

### Task 7: ExternalToolCheck (§6 A)

**Files:**
- Create: `Packages/SopsGUIKit/Sources/SopsHealth/Checks/ExternalToolCheck.swift`
- Create: `Packages/SopsGUIKit/Tests/SopsHealthTests/ExternalToolCheckTests.swift`

**Interfaces:**
- Consumes: `ToolLocating`, `LocatedTool`, `SemanticVersion`, `HealthCheck`, `HealthFinding`, `Remediation`.
- Produces: `ExternalToolCheck(locator: any ToolLocating, embeddedSopsVersion: SemanticVersion)`, and `ExternalToolCheck.Requirement`.

Finding ids are stable and used by the UI: `tool.sops`, `tool.age`, `tool.git`, `tool.yq`, `tool.docker`.

- [ ] **Step 1: Write the failing test**

`Packages/SopsGUIKit/Tests/SopsHealthTests/ExternalToolCheckTests.swift`:

```swift
import Testing
@testable import SopsHealth

private struct FakeLocator: ToolLocating {
    var tools: [String: LocatedTool]
    func locate(_ name: String, versionArguments: [String]) async -> LocatedTool? { tools[name] }
}

private func tool(_ name: String, _ version: SemanticVersion?) -> LocatedTool {
    LocatedTool(name: name, path: "/opt/homebrew/bin/\(name)",
                version: version, rawVersionOutput: version.map(\.description) ?? "")
}

private func finding(_ findings: [HealthFinding], _ id: String) -> HealthFinding {
    findings.first { $0.id == id }!
}

@Suite("ExternalToolCheck")
struct ExternalToolCheckTests {
    private let embedded = SemanticVersion(3, 13, 3)

    @Test("a sops CLI older than the embedded engine is a warning with an upgrade command")
    func staleSopsWarns() async {
        let check = ExternalToolCheck(
            locator: FakeLocator(tools: ["sops": tool("sops", SemanticVersion(3, 13, 2))]),
            embeddedSopsVersion: embedded)

        let sops = finding(await check.run(), "tool.sops")
        #expect(sops.status == .warning)
        #expect(sops.remediation?.command == "brew upgrade sops")
        #expect(sops.detail.contains("3.13.2"))
        #expect(sops.detail.contains("3.13.3"))
    }

    @Test("a sops CLI at or above the embedded engine is OK")
    func currentSopsIsOK() async {
        let check = ExternalToolCheck(
            locator: FakeLocator(tools: ["sops": tool("sops", SemanticVersion(3, 13, 3))]),
            embeddedSopsVersion: embedded)
        #expect(finding(await check.run(), "tool.sops").status == .ok)
    }

    // yq v3 accepts `-o=props` silently but produces different output, so the
    // Help snippet in PROPOSAL.md §5 would generate a wrong .env file.
    @Test("yq v3 is a problem, not a warning")
    func yqV3IsAProblem() async {
        let check = ExternalToolCheck(
            locator: FakeLocator(tools: ["yq": tool("yq", SemanticVersion(3, 4, 1))]),
            embeddedSopsVersion: embedded)

        let yq = finding(await check.run(), "tool.yq")
        #expect(yq.status == .problem)
        #expect(yq.remediation?.command == "brew upgrade yq")
    }

    @Test("an absent optional tool is informational, not a failure")
    func absentDockerIsSkipped() async {
        let check = ExternalToolCheck(locator: FakeLocator(tools: [:]), embeddedSopsVersion: embedded)
        let docker = finding(await check.run(), "tool.docker")
        if case .skipped = docker.status {} else {
            Issue.record("docker absence should be skipped, got \(docker.status)")
        }
    }

    @Test("an absent recommended tool warns and offers an install command")
    func absentSopsWarns() async {
        let check = ExternalToolCheck(locator: FakeLocator(tools: [:]), embeddedSopsVersion: embedded)
        let sops = finding(await check.run(), "tool.sops")
        #expect(sops.status == .warning)
        #expect(sops.remediation?.command == "brew install sops")
    }

    @Test("a tool whose version cannot be parsed is unknown, never wrongly OK")
    func unparseableVersionIsUnknown() async {
        let check = ExternalToolCheck(
            locator: FakeLocator(tools: ["git": tool("git", nil)]),
            embeddedSopsVersion: embedded)
        let git = finding(await check.run(), "tool.git")
        if case .unknown = git.status {} else {
            Issue.record("unparseable version should be unknown, got \(git.status)")
        }
    }

    @Test("no remediation command ever mutates the system on the app's behalf")
    func remediationsAreCopyOnly() async {
        let check = ExternalToolCheck(locator: FakeLocator(tools: [:]), embeddedSopsVersion: embedded)
        for finding in await check.run() {
            guard let command = finding.remediation?.command else { continue }
            #expect(!command.contains("sudo"))
            #expect(command.hasPrefix("brew "))
        }
    }

    @Test("reports on every tool the proposal lists")
    func coversAllTools() async {
        let check = ExternalToolCheck(locator: FakeLocator(tools: [:]), embeddedSopsVersion: embedded)
        let ids = Set((await check.run()).map(\.id))
        #expect(ids == ["tool.sops", "tool.age", "tool.git", "tool.yq", "tool.docker"])
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd Packages/SopsGUIKit && swift test --filter ExternalToolCheck
```

Expected: FAIL — `cannot find 'ExternalToolCheck' in scope`.

- [ ] **Step 3: Implement**

`Packages/SopsGUIKit/Sources/SopsHealth/Checks/ExternalToolCheck.swift`:

```swift
import Foundation

/// PROPOSAL.md §6 A. None of these tools are needed for the app to work — the
/// engine is in-process. They matter because the Help snippets run in the user's
/// terminal and CI against files this app writes.
public struct ExternalToolCheck: HealthCheck {
    public let id = "external-tools"
    public let category = HealthCategory.tools

    struct Requirement: Sendable {
        let name: String
        let findingID: String
        let title: String
        let purpose: String
        /// Below this, the tool is wrong rather than merely old.
        let hardFloor: SemanticVersion?
        /// Below this, the tool still works but should be updated.
        let softFloor: SemanticVersion?
        /// Absence is informational rather than a warning.
        let optional: Bool
        let versionArguments: [String]
        let formula: String
    }

    private let locator: any ToolLocating
    private let embeddedSopsVersion: SemanticVersion

    public init(locator: any ToolLocating, embeddedSopsVersion: SemanticVersion) {
        self.locator = locator
        self.embeddedSopsVersion = embeddedSopsVersion
    }

    private var requirements: [Requirement] {
        [
            Requirement(
                name: "sops", findingID: "tool.sops", title: "sops CLI",
                purpose: "Decrypting these files in your terminal and in CI.",
                hardFloor: nil, softFloor: embeddedSopsVersion, optional: false,
                versionArguments: ["--version"], formula: "sops"),
            Requirement(
                name: "age", findingID: "tool.age", title: "age",
                purpose: "Generating keys outside this app, e.g. on a server.",
                hardFloor: nil, softFloor: SemanticVersion(1, 3, 0), optional: false,
                versionArguments: ["--version"], formula: "age"),
            Requirement(
                name: "git", findingID: "tool.git", title: "git",
                purpose: "Worktree detection and commit hygiene.",
                hardFloor: SemanticVersion(2, 30, 0), softFloor: nil, optional: false,
                versionArguments: ["--version"], formula: "git"),
            Requirement(
                name: "yq", findingID: "tool.yq", title: "yq",
                purpose: "The .env generation snippet uses yq v4 syntax (-o=props). v3 accepts it and produces different output.",
                hardFloor: SemanticVersion(4, 0, 0), softFloor: nil, optional: false,
                versionArguments: ["--version"], formula: "yq"),
            Requirement(
                name: "docker", findingID: "tool.docker", title: "Docker",
                purpose: "Only needed for the docker-compose snippets.",
                hardFloor: nil, softFloor: nil, optional: true,
                versionArguments: ["--version"], formula: "docker"),
        ]
    }

    public func run() async -> [HealthFinding] {
        await withTaskGroup(of: HealthFinding.self) { group in
            for requirement in requirements {
                group.addTask { await evaluate(requirement) }
            }
            var findings: [HealthFinding] = []
            for await finding in group { findings.append(finding) }
            return findings
        }
    }

    private func evaluate(_ requirement: Requirement) async -> HealthFinding {
        guard let located = await locator.locate(requirement.name,
                                                 versionArguments: requirement.versionArguments) else {
            return HealthFinding(
                id: requirement.findingID, title: requirement.title,
                status: requirement.optional
                    ? .skipped(reason: "Not installed. \(requirement.purpose)")
                    : .warning,
                detail: "Not found on this machine. \(requirement.purpose)",
                remediation: Remediation(
                    explanation: "Install it with Homebrew, then re-run this check.",
                    command: "brew install \(requirement.formula)"))
        }

        guard let version = located.version else {
            return HealthFinding(
                id: requirement.findingID, title: requirement.title,
                status: .unknown(reason: "Could not read a version number from \(requirement.name)."),
                detail: "Found at \(located.path), but its output was not recognisable: \(located.rawVersionOutput)")
        }

        let upgrade = Remediation(
            explanation: "Update it with Homebrew, then re-run this check.",
            command: "brew upgrade \(requirement.formula)")

        if let floor = requirement.hardFloor, version < floor {
            return HealthFinding(
                id: requirement.findingID, title: requirement.title, status: .problem,
                detail: "\(requirement.name) \(version) is too old — \(floor) or newer is required. \(requirement.purpose)",
                remediation: upgrade)
        }
        if let floor = requirement.softFloor, version < floor {
            return HealthFinding(
                id: requirement.findingID, title: requirement.title, status: .warning,
                detail: "\(requirement.name) \(version) is older than \(floor). \(requirement.purpose)",
                remediation: upgrade)
        }
        return HealthFinding(
            id: requirement.findingID, title: requirement.title, status: .ok,
            detail: "\(requirement.name) \(version) at \(located.path)")
    }
}
```

- [ ] **Step 4: Run it to verify it passes**

```bash
cd Packages/SopsGUIKit && swift test --filter ExternalToolCheck
```

Expected: PASS, 8 tests.

- [ ] **Step 5: Verify it against the real machine**

Add a temporary scratch test, run it, read the output, then delete it:

```swift
@Test("scratch: real machine report")
func realMachine() async {
    let check = ExternalToolCheck(locator: ToolLocator(), embeddedSopsVersion: SemanticVersion(3, 13, 3))
    for finding in await check.run() {
        print("\(finding.id): \(finding.status) — \(finding.detail)")
    }
}
```

Expected on this Mac Studio: `tool.sops` warning (3.13.2 < 3.13.3), `tool.age` ok, `tool.git` ok (2.54.0), `tool.yq` warning + `brew install yq` (not installed), `tool.docker` ok (29.4.0 at `/usr/local/bin`). If `yq` or `docker` come back "not found" despite being installed, `ToolLocator` is not reading the login shell `PATH` — fix that before continuing.

- [ ] **Step 6: Commit**

```bash
git add Packages/SopsGUIKit
git commit -m "M1: external CLI tool health check"
```

---

### Task 8: UpstreamVersionSource

**Files:**
- Create: `Packages/SopsGUIKit/Sources/SopsHealth/UpstreamVersionSource.swift`
- Create: `Packages/SopsGUIKit/Tests/SopsHealthTests/UpstreamVersionSourceTests.swift`

**Interfaces:**
- Consumes: `SemanticVersion`.
- Produces:
  - `struct UpstreamRelease { let version: SemanticVersion; let releaseNotesURL: URL }`
  - `protocol UpstreamVersionProviding: Sendable { func latestRelease(repository: String) async -> UpstreamRelease? }`
  - `struct GitHubReleaseSource: UpstreamVersionProviding` with `init(session: URLSession = .shared, isEnabled: @Sendable () -> Bool)`
  - `static GitHubReleaseSource.parseRelease(from data: Data) -> UpstreamRelease?`

- [ ] **Step 1: Write the failing test**

`Packages/SopsGUIKit/Tests/SopsHealthTests/UpstreamVersionSourceTests.swift`:

```swift
import Foundation
import Testing
@testable import SopsHealth

@Suite("GitHubReleaseSource")
struct UpstreamVersionSourceTests {

    // Trimmed shape of the real api.github.com/repos/getsops/sops/releases/latest response.
    private let realPayload = Data("""
    {
      "tag_name": "v3.13.3",
      "published_at": "2026-07-23T05:27:57Z",
      "html_url": "https://github.com/getsops/sops/releases/tag/v3.13.3"
    }
    """.utf8)

    @Test("parses a real GitHub release payload")
    func parsesRealPayload() throws {
        let release = try #require(GitHubReleaseSource.parseRelease(from: realPayload))
        #expect(release.version == SemanticVersion(3, 13, 3))
        #expect(release.releaseNotesURL.absoluteString == "https://github.com/getsops/sops/releases/tag/v3.13.3")
    }

    @Test("returns nil for malformed or truncated payloads instead of crashing")
    func toleratesGarbage() {
        #expect(GitHubReleaseSource.parseRelease(from: Data("not json".utf8)) == nil)
        #expect(GitHubReleaseSource.parseRelease(from: Data("{}".utf8)) == nil)
    }

    @Test("makes no network request at all when the user has not consented")
    func respectsConsent() async {
        let session = URLSession(configuration: .ephemeral)
        let source = GitHubReleaseSource(session: session, isEnabled: { false })
        #expect(await source.latestRelease(repository: "getsops/sops") == nil)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd Packages/SopsGUIKit && swift test --filter GitHubReleaseSource
```

Expected: FAIL — `cannot find 'GitHubReleaseSource' in scope`.

- [ ] **Step 3: Implement**

`Packages/SopsGUIKit/Sources/SopsHealth/UpstreamVersionSource.swift`:

```swift
import Foundation

public struct UpstreamRelease: Equatable, Sendable {
    public let version: SemanticVersion
    public let releaseNotesURL: URL
}

public protocol UpstreamVersionProviding: Sendable {
    func latestRelease(repository: String) async -> UpstreamRelease?
}

/// Looks up the latest release of a GitHub repository.
///
/// This is the only network call in the app. It is gated behind explicit user
/// consent (`isEnabled`) and returns nil — never an error — when consent is off,
/// the network is down, or the response is unexpected. PROPOSAL.md §6 B.
public struct GitHubReleaseSource: UpstreamVersionProviding {
    private let session: URLSession
    private let isEnabled: @Sendable () -> Bool

    public init(session: URLSession = .shared, isEnabled: @escaping @Sendable () -> Bool) {
        self.session = session
        self.isEnabled = isEnabled
    }

    public func latestRelease(repository: String) async -> UpstreamRelease? {
        guard isEnabled() else { return nil }
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            return nil
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }

        return Self.parseRelease(from: data)
    }

    public static func parseRelease(from data: Data) -> UpstreamRelease? {
        struct Payload: Decodable {
            let tag_name: String
            let html_url: String
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let version = SemanticVersion(parsing: payload.tag_name),
              let url = URL(string: payload.html_url)
        else { return nil }
        return UpstreamRelease(version: version, releaseNotesURL: url)
    }
}
```

- [ ] **Step 4: Run it to verify it passes**

```bash
cd Packages/SopsGUIKit && swift test --filter GitHubReleaseSource
```

Expected: PASS, 3 tests.

- [ ] **Step 5: Commit**

```bash
git add Packages/SopsGUIKit
git commit -m "M1: consent-gated GitHub release lookup"
```

---

### Task 9: EngineFreshnessCheck (§6 B)

**Files:**
- Create: `Packages/SopsGUIKit/Sources/SopsHealth/Checks/EngineFreshnessCheck.swift`
- Create: `Packages/SopsGUIKit/Tests/SopsHealthTests/EngineFreshnessCheckTests.swift`

**Interfaces:**
- Consumes: `UpstreamVersionProviding`, `SemanticVersion`, `HealthCheck`.
- Produces: `EngineFreshnessCheck(embeddedSops:embeddedAge:upstream:)`. Finding ids: `engine.sops`, `engine.age`.

- [ ] **Step 1: Write the failing test**

`Packages/SopsGUIKit/Tests/SopsHealthTests/EngineFreshnessCheckTests.swift`:

```swift
import Foundation
import Testing
@testable import SopsHealth

private struct FakeUpstream: UpstreamVersionProviding {
    var releases: [String: UpstreamRelease]
    func latestRelease(repository: String) async -> UpstreamRelease? { releases[repository] }
}

private func release(_ version: SemanticVersion) -> UpstreamRelease {
    UpstreamRelease(version: version, releaseNotesURL: URL(string: "https://example.invalid/notes")!)
}

private func finding(_ findings: [HealthFinding], _ id: String) -> HealthFinding {
    findings.first { $0.id == id }!
}

@Suite("EngineFreshnessCheck")
struct EngineFreshnessCheckTests {

    @Test("an up-to-date embedded engine is OK")
    func upToDateIsOK() async {
        let check = EngineFreshnessCheck(
            embeddedSops: SemanticVersion(3, 13, 3),
            embeddedAge: SemanticVersion(1, 3, 1),
            upstream: FakeUpstream(releases: [
                "getsops/sops": release(SemanticVersion(3, 13, 3)),
                "FiloSottile/age": release(SemanticVersion(1, 3, 1)),
            ]))
        let findings = await check.run()
        #expect(finding(findings, "engine.sops").status == .ok)
        #expect(finding(findings, "engine.age").status == .ok)
    }

    @Test("an outdated embedded engine warns the user to update the app, not to run brew")
    func outdatedWarnsAboutTheApp() async {
        let check = EngineFreshnessCheck(
            embeddedSops: SemanticVersion(3, 12, 0),
            embeddedAge: SemanticVersion(1, 3, 1),
            upstream: FakeUpstream(releases: [
                "getsops/sops": release(SemanticVersion(3, 13, 3)),
                "FiloSottile/age": release(SemanticVersion(1, 3, 1)),
            ]))
        let sops = finding(await check.run(), "engine.sops")
        #expect(sops.status == .warning)
        // The engine is inside the app bundle; brew cannot fix it.
        #expect(sops.remediation?.command == nil)
        #expect(sops.remediation?.documentationURL != nil)
    }

    @Test("offline or without consent the verdict is unknown, never a failure")
    func offlineIsUnknown() async {
        let check = EngineFreshnessCheck(
            embeddedSops: SemanticVersion(3, 13, 3),
            embeddedAge: SemanticVersion(1, 3, 1),
            upstream: FakeUpstream(releases: [:]))
        for finding in await check.run() {
            if case .unknown = finding.status {} else {
                Issue.record("\(finding.id) should be unknown when upstream is unreachable, got \(finding.status)")
            }
        }
    }

    // The app must not imply it knows whether a version is vulnerable.
    @Test("never claims a version is vulnerable, only that it is behind")
    func makesNoSecurityClaims() async {
        let check = EngineFreshnessCheck(
            embeddedSops: SemanticVersion(3, 12, 0),
            embeddedAge: SemanticVersion(1, 3, 1),
            upstream: FakeUpstream(releases: [
                "getsops/sops": release(SemanticVersion(3, 13, 3)),
                "FiloSottile/age": release(SemanticVersion(1, 3, 1)),
            ]))
        for finding in await check.run() {
            let text = (finding.detail + (finding.remediation?.explanation ?? "")).lowercased()
            #expect(!text.contains("vulnerable"))
            #expect(!text.contains("cve-"))
        }
    }

    @Test("an embedded version ahead of the latest release is OK, not a warning")
    func aheadOfUpstreamIsOK() async {
        let check = EngineFreshnessCheck(
            embeddedSops: SemanticVersion(3, 14, 0),
            embeddedAge: SemanticVersion(1, 3, 1),
            upstream: FakeUpstream(releases: [
                "getsops/sops": release(SemanticVersion(3, 13, 3)),
                "FiloSottile/age": release(SemanticVersion(1, 3, 1)),
            ]))
        #expect(finding(await check.run(), "engine.sops").status == .ok)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd Packages/SopsGUIKit && swift test --filter EngineFreshnessCheck
```

Expected: FAIL — `cannot find 'EngineFreshnessCheck' in scope`.

- [ ] **Step 3: Implement**

`Packages/SopsGUIKit/Sources/SopsHealth/Checks/EngineFreshnessCheck.swift`:

```swift
import Foundation

/// PROPOSAL.md §6 B. Compares the sops/age versions compiled into the bridge
/// against the latest upstream releases.
///
/// This is a version comparison, not CVE matching. The app must never state or
/// imply that a particular version is vulnerable — it links to the advisories
/// page and lets the user judge.
public struct EngineFreshnessCheck: HealthCheck {
    public let id = "engine-freshness"
    public let category = HealthCategory.engine

    private struct Component {
        let findingID: String
        let title: String
        let repository: String
        let embedded: SemanticVersion
        let advisoriesURL: URL
    }

    private let embeddedSops: SemanticVersion
    private let embeddedAge: SemanticVersion
    private let upstream: any UpstreamVersionProviding

    public init(embeddedSops: SemanticVersion, embeddedAge: SemanticVersion,
                upstream: any UpstreamVersionProviding) {
        self.embeddedSops = embeddedSops
        self.embeddedAge = embeddedAge
        self.upstream = upstream
    }

    private var components: [Component] {
        [
            Component(findingID: "engine.sops", title: "Embedded sops engine",
                      repository: "getsops/sops", embedded: embeddedSops,
                      advisoriesURL: URL(string: "https://github.com/getsops/sops/security/advisories")!),
            Component(findingID: "engine.age", title: "Embedded age library",
                      repository: "FiloSottile/age", embedded: embeddedAge,
                      advisoriesURL: URL(string: "https://github.com/FiloSottile/age/security/advisories")!),
        ]
    }

    public func run() async -> [HealthFinding] {
        await withTaskGroup(of: HealthFinding.self) { group in
            for component in components {
                group.addTask { await evaluate(component) }
            }
            var findings: [HealthFinding] = []
            for await finding in group { findings.append(finding) }
            return findings
        }
    }

    private func evaluate(_ component: Component) async -> HealthFinding {
        guard let latest = await upstream.latestRelease(repository: component.repository) else {
            return HealthFinding(
                id: component.findingID, title: component.title,
                status: .unknown(reason: "Could not reach GitHub. Update checks may be turned off, or you may be offline."),
                detail: "This app has \(component.embedded) built in. The latest release is unknown.",
                remediation: Remediation(
                    explanation: "Review the project's security advisories yourself.",
                    documentationURL: component.advisoriesURL))
        }

        guard component.embedded < latest.version else {
            return HealthFinding(
                id: component.findingID, title: component.title, status: .ok,
                detail: "This app has \(component.embedded) built in; the latest release is \(latest.version).")
        }

        return HealthFinding(
            id: component.findingID, title: component.title, status: .warning,
            detail: "This app has \(component.embedded) built in; \(latest.version) has been released.",
            remediation: Remediation(
                explanation: "The engine ships inside this app, so updating the app is what updates it. Read the release notes to decide whether the difference matters to you.",
                command: nil,
                documentationURL: latest.releaseNotesURL))
    }
}
```

- [ ] **Step 4: Run it to verify it passes**

```bash
cd Packages/SopsGUIKit && swift test --filter EngineFreshnessCheck
```

Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add Packages/SopsGUIKit
git commit -m "M1: embedded engine freshness check"
```

---

### Task 10: SecurityPostureCheck (§6 C)

Depends on two things that do not exist yet (the Keychain key store, M3; Sparkle, M5). Both are reached through protocols so this check is complete and tested now, and reports `.skipped` with a reason until they land.

**Files:**
- Create: `Packages/SopsGUIKit/Sources/SopsHealth/Checks/SecurityPostureCheck.swift`
- Create: `Packages/SopsGUIKit/Tests/SopsHealthTests/SecurityPostureCheckTests.swift`

**Interfaces:**
- Consumes: `HealthCheck`, `SemanticVersion`.
- Produces:
  - `enum KeyStoreState { case configured, empty, unavailable(reason: String) }`
  - `protocol KeyStoreStatusProviding: Sendable { var state: KeyStoreState { get } }`
  - `enum BiometryState { case available, notEnrolled, unavailable(reason: String) }`
  - `protocol BiometryStatusProviding: Sendable { var state: BiometryState { get } }`
  - `protocol AppUpdateStatusProviding: Sendable { var state: HealthStatus { get }; var detail: String { get } }`
  - `SecurityPostureCheck(osVersion:minimumOSVersion:keyStore:biometry:appUpdates:legacyKeyFilePath:)`

Finding ids: `security.os`, `security.biometry`, `security.keystore`, `security.legacy-key-file`, `security.app-updates`.

- [ ] **Step 1: Write the failing test**

`Packages/SopsGUIKit/Tests/SopsHealthTests/SecurityPostureCheckTests.swift`:

```swift
import Foundation
import Testing
@testable import SopsHealth

private struct FakeKeyStore: KeyStoreStatusProviding { let state: KeyStoreState }
private struct FakeBiometry: BiometryStatusProviding { let state: BiometryState }
private struct FakeUpdates: AppUpdateStatusProviding {
    let state: HealthStatus
    let detail: String
}

private func finding(_ findings: [HealthFinding], _ id: String) -> HealthFinding {
    findings.first { $0.id == id }!
}

private func makeCheck(
    os: SemanticVersion = SemanticVersion(26, 5, 2),
    keyStore: KeyStoreState = .configured,
    biometry: BiometryState = .available,
    updates: HealthStatus = .ok,
    legacyKeyFilePath: String = "/nonexistent/keys.txt"
) -> SecurityPostureCheck {
    SecurityPostureCheck(
        osVersion: os,
        minimumOSVersion: SemanticVersion(14, 0, 0),
        keyStore: FakeKeyStore(state: keyStore),
        biometry: FakeBiometry(state: biometry),
        appUpdates: FakeUpdates(state: updates, detail: "up to date"),
        legacyKeyFilePath: legacyKeyFilePath)
}

@Suite("SecurityPostureCheck")
struct SecurityPostureCheckTests {

    @Test("a fully configured machine reports OK across the board")
    func healthyMachine() async {
        for finding in await makeCheck().run() {
            #expect(finding.status == .ok, "\(finding.id) was \(finding.status)")
        }
    }

    @Test("no age key configured is a problem — the app cannot decrypt anything")
    func missingKeyIsAProblem() async {
        let keystore = finding(await makeCheck(keyStore: .empty).run(), "security.keystore")
        #expect(keystore.status == .problem)
    }

    @Test("biometry not enrolled is a warning, not a problem — a password still works")
    func biometryNotEnrolledWarns() async {
        let biometry = finding(await makeCheck(biometry: .notEnrolled).run(), "security.biometry")
        #expect(biometry.status == .warning)
    }

    // The whole point of the Keychain model is that the key is not sitting in a
    // plaintext file. Finding one is the single most valuable thing this check does.
    @Test("a plaintext keys.txt still on disk is a warning that explains the risk")
    func legacyKeyFileWarns() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("posture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let keyFile = dir.appendingPathComponent("keys.txt")
        try "# created by age-keygen\n".write(to: keyFile, atomically: true, encoding: .utf8)

        let legacy = finding(await makeCheck(legacyKeyFilePath: keyFile.path).run(),
                             "security.legacy-key-file")
        #expect(legacy.status == .warning)
        #expect(legacy.detail.contains(keyFile.path))
        #expect(legacy.remediation != nil)
    }

    @Test("no plaintext key file on disk is OK")
    func noLegacyKeyFileIsOK() async {
        #expect(finding(await makeCheck().run(), "security.legacy-key-file").status == .ok)
    }

    @Test("an unsupported macOS version is a problem")
    func oldOSIsAProblem() async {
        let os = finding(await makeCheck(os: SemanticVersion(13, 0, 0)).run(), "security.os")
        #expect(os.status == .problem)
    }

    @Test("features that have not shipped report skipped with a reason, never a false OK")
    func unshippedFeaturesAreSkipped() async {
        let findings = await makeCheck(
            keyStore: .unavailable(reason: "Keychain storage arrives in M3."),
            updates: .skipped(reason: "Update checking arrives with Sparkle in M5.")
        ).run()

        for id in ["security.keystore", "security.app-updates"] {
            guard case .skipped(let reason) = finding(findings, id).status else {
                Issue.record("\(id) should be skipped, got \(finding(findings, id).status)")
                continue
            }
            #expect(!reason.isEmpty, "a skipped check must say why")
        }
    }

    @Test("no finding ever contains key material")
    func neverLeaksKeyMaterial() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("posture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let keyFile = dir.appendingPathComponent("keys.txt")
        try "AGE-SECRET-KEY-1QQQQQQQQQQQQQQQQQQQQQQQQQQQ\n".write(to: keyFile, atomically: true, encoding: .utf8)

        for finding in await makeCheck(legacyKeyFilePath: keyFile.path).run() {
            let text = finding.detail + finding.title + (finding.remediation?.explanation ?? "")
            #expect(!text.contains("AGE-SECRET-KEY-1QQQ"))
        }
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd Packages/SopsGUIKit && swift test --filter SecurityPostureCheck
```

Expected: FAIL — `cannot find type 'KeyStoreStatusProviding' in scope`.

- [ ] **Step 3: Implement**

`Packages/SopsGUIKit/Sources/SopsHealth/Checks/SecurityPostureCheck.swift`:

```swift
import Foundation

public enum KeyStoreState: Equatable, Sendable {
    case configured
    case empty
    /// The store itself is not available yet — e.g. the feature has not shipped.
    case unavailable(reason: String)
}

public protocol KeyStoreStatusProviding: Sendable {
    var state: KeyStoreState { get }
}

public enum BiometryState: Equatable, Sendable {
    case available
    case notEnrolled
    case unavailable(reason: String)
}

public protocol BiometryStatusProviding: Sendable {
    var state: BiometryState { get }
}

public protocol AppUpdateStatusProviding: Sendable {
    var state: HealthStatus { get }
    var detail: String { get }
}

/// PROPOSAL.md §6 C. Everything here is read-only inspection of the local
/// machine and the app's own configuration.
public struct SecurityPostureCheck: HealthCheck {
    public let id = "security-posture"
    public let category = HealthCategory.security

    private let osVersion: SemanticVersion
    private let minimumOSVersion: SemanticVersion
    private let keyStore: any KeyStoreStatusProviding
    private let biometry: any BiometryStatusProviding
    private let appUpdates: any AppUpdateStatusProviding
    private let legacyKeyFilePath: String

    public init(osVersion: SemanticVersion,
                minimumOSVersion: SemanticVersion,
                keyStore: any KeyStoreStatusProviding,
                biometry: any BiometryStatusProviding,
                appUpdates: any AppUpdateStatusProviding,
                legacyKeyFilePath: String) {
        self.osVersion = osVersion
        self.minimumOSVersion = minimumOSVersion
        self.keyStore = keyStore
        self.biometry = biometry
        self.appUpdates = appUpdates
        self.legacyKeyFilePath = legacyKeyFilePath
    }

    public func run() async -> [HealthFinding] {
        [osFinding, biometryFinding, keyStoreFinding, legacyKeyFileFinding, appUpdateFinding]
    }

    private var osFinding: HealthFinding {
        osVersion >= minimumOSVersion
            ? HealthFinding(id: "security.os", title: "macOS version", status: .ok,
                            detail: "macOS \(osVersion).")
            : HealthFinding(id: "security.os", title: "macOS version", status: .problem,
                            detail: "macOS \(osVersion) is below the minimum \(minimumOSVersion) this app supports.",
                            remediation: Remediation(
                                explanation: "Update macOS in System Settings › General › Software Update."))
    }

    private var biometryFinding: HealthFinding {
        switch biometry.state {
        case .available:
            HealthFinding(id: "security.biometry", title: "Touch ID", status: .ok,
                          detail: "Touch ID is available for unlocking your key.")
        case .notEnrolled:
            HealthFinding(id: "security.biometry", title: "Touch ID", status: .warning,
                          detail: "No fingerprint is enrolled, so unlocking will fall back to your password.",
                          remediation: Remediation(
                              explanation: "Add a fingerprint in System Settings › Touch ID & Password."))
        case .unavailable(let reason):
            HealthFinding(id: "security.biometry", title: "Touch ID",
                          status: .skipped(reason: reason),
                          detail: "Unlocking will use your password instead.")
        }
    }

    private var keyStoreFinding: HealthFinding {
        switch keyStore.state {
        case .configured:
            HealthFinding(id: "security.keystore", title: "Your age key", status: .ok,
                          detail: "An age key is stored in your Keychain.")
        case .empty:
            HealthFinding(id: "security.keystore", title: "Your age key", status: .problem,
                          detail: "No age key is configured, so nothing can be decrypted.",
                          remediation: Remediation(
                              explanation: "Generate a new key, or import an existing one, from the Keys section of this app."))
        case .unavailable(let reason):
            HealthFinding(id: "security.keystore", title: "Your age key",
                          status: .skipped(reason: reason), detail: "")
        }
    }

    /// A plaintext key file on disk defeats the point of Keychain storage.
    /// Only its existence is reported — the contents are never read.
    private var legacyKeyFileFinding: HealthFinding {
        guard FileManager.default.fileExists(atPath: legacyKeyFilePath) else {
            return HealthFinding(id: "security.legacy-key-file", title: "Plaintext key file",
                                 status: .ok,
                                 detail: "No unprotected age key file was found.")
        }
        return HealthFinding(
            id: "security.legacy-key-file", title: "Plaintext key file", status: .warning,
            detail: "An age key file sits unencrypted at \(legacyKeyFilePath). Anything that can read your home directory — including any process you run — can read that key.",
            remediation: Remediation(
                explanation: "Import it into the Keychain from the Keys section of this app. Once the import is verified, delete the file yourself; this app will not delete it for you."))
    }

    private var appUpdateFinding: HealthFinding {
        HealthFinding(id: "security.app-updates", title: "App updates",
                      status: appUpdates.state, detail: appUpdates.detail)
    }
}
```

- [ ] **Step 4: Run it to verify it passes**

```bash
cd Packages/SopsGUIKit && swift test --filter SecurityPostureCheck
```

Expected: PASS, 8 tests.

- [ ] **Step 5: Commit**

```bash
git add Packages/SopsGUIKit
git commit -m "M1: security posture check with protocol seams for Keychain and Sparkle"
```

---

### Task 11: ProjectHealthCheck (§6 D)

**Files:**
- Create: `Packages/SopsGUIKit/Sources/SopsHealth/Checks/ProjectHealthCheck.swift`
- Create: `Packages/SopsGUIKit/Tests/SopsHealthTests/ProjectHealthCheckTests.swift`

**Interfaces:**
- Consumes: `HealthCheck`.
- Produces:
  - `struct InspectedProject { let name: String; let rootPath: String }`
  - `protocol ProjectSourceProviding: Sendable { var projects: [InspectedProject] { get } }`
  - `ProjectHealthCheck(source: any ProjectSourceProviding)`

Finding ids are per project: `project.<name>.sops-yaml`, `project.<name>.stale-recipients`, `project.<name>.gitignore`. With no projects, one finding `project.none` with status `.skipped`.

- [ ] **Step 1: Write the failing test**

`Packages/SopsGUIKit/Tests/SopsHealthTests/ProjectHealthCheckTests.swift`:

```swift
import Foundation
import Testing
@testable import SopsHealth

private struct FakeProjects: ProjectSourceProviding {
    let projects: [InspectedProject]
}

/// Builds a throwaway project directory. Returns its root path.
private func makeProject(
    sopsYAML: String?,
    files: [String: String] = [:],
    gitignore: String? = nil
) throws -> String {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("project-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    if let sopsYAML {
        try sopsYAML.write(to: root.appendingPathComponent(".sops.yaml"),
                           atomically: true, encoding: .utf8)
    }
    if let gitignore {
        try gitignore.write(to: root.appendingPathComponent(".gitignore"),
                            atomically: true, encoding: .utf8)
    }
    for (name, contents) in files {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
    return root.path
}

private let devKey = "age1ykd0u99qxpdl4yr57lwqv5rt9e473p6hhdps2a5q5ddmt0x6ryaqkjpx4f"
private let serverKey = "age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"

private func encryptedFile(recipients: [String]) -> String {
    let entries = recipients.map { "        - recipient: \($0)\n          enc: |\n            -----BEGIN AGE ENCRYPTED FILE-----\n" }
    return """
    password: ENC[AES256_GCM,data:abc,iv:def,tag:ghi,type:str]
    sops:
        age:
    \(entries.joined())
        lastmodified: "2026-08-06T14:00:00Z"
        mac: ENC[AES256_GCM,data:xyz,iv:uvw,tag:rst,type:str]
        version: 3.13.3
    """
}

private func finding(_ findings: [HealthFinding], suffix: String) -> HealthFinding {
    findings.first { $0.id.hasSuffix(suffix) }!
}

@Suite("ProjectHealthCheck")
struct ProjectHealthCheckTests {

    @Test("with no projects added the check is skipped, not failing")
    func noProjectsIsSkipped() async {
        let findings = await ProjectHealthCheck(source: FakeProjects(projects: [])).run()
        #expect(findings.count == 1)
        guard case .skipped = findings[0].status else {
            Issue.record("expected skipped, got \(findings[0].status)")
            return
        }
    }

    @Test("a project with no .sops.yaml is a warning")
    func missingSopsYAMLWarns() async throws {
        let root = try makeProject(sopsYAML: nil)
        let check = ProjectHealthCheck(source: FakeProjects(
            projects: [InspectedProject(name: "demo", rootPath: root)]))
        #expect(finding(await check.run(), suffix: "sops-yaml").status == .warning)
    }

    @Test("an unparseable .sops.yaml is a problem")
    func malformedSopsYAMLIsAProblem() async throws {
        let root = try makeProject(sopsYAML: "creation_rules:\n  - this: [is: not: valid\n")
        let check = ProjectHealthCheck(source: FakeProjects(
            projects: [InspectedProject(name: "demo", rootPath: root)]))
        #expect(finding(await check.run(), suffix: "sops-yaml").status == .problem)
    }

    @Test("a valid .sops.yaml with every file matching its rule is OK")
    func healthyProjectIsOK() async throws {
        let root = try makeProject(
            sopsYAML: """
            creation_rules:
              - path_regex: secrets/.*\\.yaml$
                age: \(devKey),\(serverKey)
            """,
            files: ["secrets/prod.yaml": encryptedFile(recipients: [devKey, serverKey])])
        let check = ProjectHealthCheck(source: FakeProjects(
            projects: [InspectedProject(name: "demo", rootPath: root)]))
        let findings = await check.run()
        #expect(finding(findings, suffix: "sops-yaml").status == .ok)
        #expect(finding(findings, suffix: "stale-recipients").status == .ok)
    }

    @Test("a file encrypted to a recipient no longer in .sops.yaml is a problem")
    func staleRecipientIsAProblem() async throws {
        let removedColleague = "age1z7wqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"
        let root = try makeProject(
            sopsYAML: """
            creation_rules:
              - path_regex: secrets/.*\\.yaml$
                age: \(devKey)
            """,
            files: ["secrets/prod.yaml": encryptedFile(recipients: [devKey, removedColleague])])
        let check = ProjectHealthCheck(source: FakeProjects(
            projects: [InspectedProject(name: "demo", rootPath: root)]))

        let stale = finding(await check.run(), suffix: "stale-recipients")
        #expect(stale.status == .problem)
        #expect(stale.detail.contains("secrets/prod.yaml"))
        // Removing a recipient does not un-leak the old value.
        #expect(stale.remediation?.explanation.lowercased().contains("rotate") == true)
    }

    @Test("a file missing a recipient its rule declares is a problem")
    func missingRecipientIsAProblem() async throws {
        let root = try makeProject(
            sopsYAML: """
            creation_rules:
              - path_regex: secrets/.*\\.yaml$
                age: \(devKey),\(serverKey)
            """,
            files: ["secrets/prod.yaml": encryptedFile(recipients: [devKey])])
        let check = ProjectHealthCheck(source: FakeProjects(
            projects: [InspectedProject(name: "demo", rootPath: root)]))
        #expect(finding(await check.run(), suffix: "stale-recipients").status == .problem)
    }

    @Test("a plaintext .env inside the project that is not gitignored is a problem")
    func ungitignoredPlaintextIsAProblem() async throws {
        let root = try makeProject(
            sopsYAML: "creation_rules:\n  - age: \(devKey)\n",
            files: [".env": "API_KEY=sk-live-abc123\n"],
            gitignore: "node_modules/\n")
        let check = ProjectHealthCheck(source: FakeProjects(
            projects: [InspectedProject(name: "demo", rootPath: root)]))

        let leak = finding(await check.run(), suffix: "gitignore")
        #expect(leak.status == .problem)
        #expect(leak.detail.contains(".env"))
        // The value must never appear in the finding.
        #expect(!leak.detail.contains("sk-live-abc123"))
    }

    @Test("a gitignored plaintext .env is OK")
    func gitignoredPlaintextIsOK() async throws {
        let root = try makeProject(
            sopsYAML: "creation_rules:\n  - age: \(devKey)\n",
            files: [".env": "API_KEY=sk-live-abc123\n"],
            gitignore: ".env\n")
        let check = ProjectHealthCheck(source: FakeProjects(
            projects: [InspectedProject(name: "demo", rootPath: root)]))
        #expect(finding(await check.run(), suffix: "gitignore").status == .ok)
    }

    // The app has only public keys. It cannot prove a colleague can decrypt.
    @Test("the recipient finding says it checked the key list, not decryptability")
    func wordingIsHonestAboutWhatWasVerified() async throws {
        let root = try makeProject(
            sopsYAML: "creation_rules:\n  - path_regex: secrets/.*\\.yaml$\n    age: \(devKey)\n",
            files: ["secrets/prod.yaml": encryptedFile(recipients: [devKey])])
        let check = ProjectHealthCheck(source: FakeProjects(
            projects: [InspectedProject(name: "demo", rootPath: root)]))

        let text = finding(await check.run(), suffix: "stale-recipients").detail.lowercased()
        #expect(!text.contains("can decrypt"))
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd Packages/SopsGUIKit && swift test --filter ProjectHealthCheck
```

Expected: FAIL — `cannot find type 'ProjectSourceProviding' in scope`.

- [ ] **Step 3: Implement**

`Packages/SopsGUIKit/Sources/SopsHealth/Checks/ProjectHealthCheck.swift`:

```swift
import Foundation

public struct InspectedProject: Equatable, Sendable {
    public let name: String
    public let rootPath: String

    public init(name: String, rootPath: String) {
        self.name = name
        self.rootPath = rootPath
    }
}

public protocol ProjectSourceProviding: Sendable {
    var projects: [InspectedProject] { get }
}

/// PROPOSAL.md §6 D.
///
/// Honesty constraint: this check reads public key lists. It can tell you that a
/// public key is or is not present in a file's recipients; it cannot tell you
/// whether the holder of that key can decrypt, because that needs their private
/// key. All user-facing wording must reflect that distinction.
public struct ProjectHealthCheck: HealthCheck {
    public let id = "project-health"
    public let category = HealthCategory.projects

    /// Plaintext files that commonly hold secrets and must not be committed.
    private static let plaintextSecretNames = [".env", ".env.local", ".env.production"]

    private let source: any ProjectSourceProviding

    public init(source: any ProjectSourceProviding) {
        self.source = source
    }

    public func run() async -> [HealthFinding] {
        let projects = source.projects
        guard !projects.isEmpty else {
            return [HealthFinding(
                id: "project.none", title: "Projects",
                status: .skipped(reason: "No projects have been added yet."),
                detail: "Add a project to have its .sops.yaml and encrypted files checked.")]
        }
        return projects.flatMap(findings(for:))
    }

    private func findings(for project: InspectedProject) -> [HealthFinding] {
        let root = URL(fileURLWithPath: project.rootPath)
        let configURL = root.appendingPathComponent(".sops.yaml")

        guard let configText = try? String(contentsOf: configURL, encoding: .utf8) else {
            return [HealthFinding(
                id: "project.\(project.name).sops-yaml", title: "\(project.name): .sops.yaml",
                status: .warning,
                detail: "No .sops.yaml in \(project.rootPath). Without it, sops has no rules for which keys to encrypt new files to.",
                remediation: Remediation(
                    explanation: "Create one from the .sops.yaml wizard in this app."))]
        }

        guard let rules = SopsConfig(parsing: configText) else {
            return [HealthFinding(
                id: "project.\(project.name).sops-yaml", title: "\(project.name): .sops.yaml",
                status: .problem,
                detail: "The .sops.yaml in \(project.rootPath) could not be parsed, so neither this app nor the sops CLI can apply its rules.",
                remediation: Remediation(
                    explanation: "Fix the YAML syntax, then re-run this check."))]
        }

        return [
            HealthFinding(id: "project.\(project.name).sops-yaml",
                          title: "\(project.name): .sops.yaml", status: .ok,
                          detail: "\(rules.creationRules.count) creation rule(s)."),
            recipientFinding(for: project, root: root, rules: rules),
            gitignoreFinding(for: project, root: root),
        ]
    }

    private func recipientFinding(for project: InspectedProject, root: URL,
                                  rules: SopsConfig) -> HealthFinding {
        var mismatches: [String] = []

        for file in encryptedFiles(under: root) {
            let relative = file.path.replacingOccurrences(of: root.path + "/", with: "")
            guard let rule = rules.rule(matching: relative) else { continue }
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }

            let actual = Set(SopsConfig.recipients(inEncryptedFile: text))
            let expected = Set(rule.ageRecipients)

            for extra in actual.subtracting(expected).sorted() {
                mismatches.append("\(relative) is encrypted to \(extra), which is not in .sops.yaml")
            }
            for missing in expected.subtracting(actual).sorted() {
                mismatches.append("\(relative) is missing \(missing), which .sops.yaml declares")
            }
        }

        guard !mismatches.isEmpty else {
            return HealthFinding(
                id: "project.\(project.name).stale-recipients",
                title: "\(project.name): recipients", status: .ok,
                detail: "Every encrypted file's key list matches the rule that governs it.")
        }

        return HealthFinding(
            id: "project.\(project.name).stale-recipients",
            title: "\(project.name): recipients", status: .problem,
            detail: mismatches.joined(separator: "\n"),
            remediation: Remediation(
                explanation: "Run updatekeys to re-wrap these files for the declared recipients. If someone was removed, also rotate the secret values themselves — they may still hold an old copy.",
                command: "sops updatekeys <file>"))
    }

    private func gitignoreFinding(for project: InspectedProject, root: URL) -> HealthFinding {
        let ignored = (try? String(contentsOf: root.appendingPathComponent(".gitignore"), encoding: .utf8))
            .map { $0.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) } } ?? []

        let exposed = Self.plaintextSecretNames.filter { name in
            FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)
                && !ignored.contains(name)
        }

        guard !exposed.isEmpty else {
            return HealthFinding(
                id: "project.\(project.name).gitignore",
                title: "\(project.name): plaintext files", status: .ok,
                detail: "No unignored plaintext secret files found.")
        }

        return HealthFinding(
            id: "project.\(project.name).gitignore",
            title: "\(project.name): plaintext files", status: .problem,
            detail: "These plaintext files are in the repository and not gitignored: \(exposed.joined(separator: ", ")). Committing one publishes its contents to everyone with repository access, permanently.",
            remediation: Remediation(
                explanation: "Add them to .gitignore, then encrypt their contents with this app. If one has already been committed, rotating the values is the only real fix.",
                command: exposed.map { "echo '\($0)' >> .gitignore" }.joined(separator: "\n")))
    }

    /// Files carrying sops metadata, found by sniffing rather than by extension.
    private func encryptedFiles(under root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }

        return enumerator.compactMap { $0 as? URL }.filter { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
            return text.contains("\nsops:") || text.hasPrefix("sops:")
        }
    }
}
```

- [ ] **Step 4: Add the minimal .sops.yaml parser the check needs**

Append to the same file:

```swift
/// The subset of .sops.yaml this check understands. Deliberately narrow — the
/// app is not a YAML editor, it only needs the age recipients per creation rule.
struct SopsConfig {
    struct CreationRule {
        let pathRegex: String?
        let ageRecipients: [String]
    }

    let creationRules: [CreationRule]

    init?(parsing text: String) {
        var rules: [CreationRule] = []
        var pathRegex: String?
        var age: [String] = []
        var sawCreationRules = false
        var inRule = false

        func flush() {
            if inRule { rules.append(CreationRule(pathRegex: pathRegex, ageRecipients: age)) }
            pathRegex = nil
            age = []
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("#") || line.trimmingCharacters(in: .whitespaces).isEmpty { continue }

            if line.hasPrefix("creation_rules:") {
                sawCreationRules = true
                continue
            }
            guard sawCreationRules else { continue }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") {
                flush()
                inRule = true
                Self.assign(trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces),
                            pathRegex: &pathRegex, age: &age)
            } else if inRule {
                Self.assign(trimmed, pathRegex: &pathRegex, age: &age)
            }
        }
        flush()

        // A file that declared creation_rules but produced nothing parseable is broken.
        guard sawCreationRules, !rules.isEmpty else { return nil }
        self.creationRules = rules
    }

    private static func assign(_ entry: String, pathRegex: inout String?, age: inout [String]) {
        guard let colon = entry.firstIndex(of: ":") else { return }
        let key = String(entry[entry.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
        let value = String(entry[entry.index(after: colon)...])
            .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))

        switch key {
        case "path_regex": pathRegex = value
        case "age": age = value.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        default: break
        }
    }

    /// The first rule whose path_regex matches, mirroring how sops picks a rule.
    /// A rule with no path_regex matches everything.
    func rule(matching relativePath: String) -> CreationRule? {
        creationRules.first { rule in
            guard let pattern = rule.pathRegex else { return true }
            return relativePath.range(of: pattern, options: .regularExpression) != nil
        }
    }

    /// Public keys a sops-encrypted file is wrapped for, read from its metadata.
    static func recipients(inEncryptedFile text: String) -> [String] {
        text.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- recipient:") || trimmed.hasPrefix("recipient:") else { return nil }
            guard let colon = trimmed.lastIndex(of: ":") else { return nil }
            let value = String(trimmed[trimmed.index(after: colon)...])
                .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            return value.isEmpty ? nil : value
        }
    }
}
```

- [ ] **Step 5: Run it to verify it passes**

```bash
cd Packages/SopsGUIKit && swift test --filter ProjectHealthCheck
```

Expected: PASS, 9 tests.

- [ ] **Step 6: Verify against a real sops file rather than a fixture**

The `encryptedFile` helper in the test is hand-written. Prove the recipient parser works on genuine output:

```bash
cd Engine && go test ./gobridge/ -run TestEveryRecipientCanDecryptIndependently -v
```

Then add a temporary test that encrypts with the real bridge and feeds the result to `SopsConfig.recipients(inEncryptedFile:)`, asserting both recipients come back. Keep this test — it is the one that catches an upstream metadata format change.

- [ ] **Step 7: Commit**

```bash
git add Packages/SopsGUIKit
git commit -m "M1: per-project health check — .sops.yaml, stale recipients, plaintext leak guard"
```

---

### Task 12: Health panel UI

**Files:**
- Create: `Packages/SopsGUIKit/Sources/SopsUI/Health/HealthFindingRow.swift`
- Create: `Packages/SopsGUIKit/Sources/SopsUI/Health/HealthPanel.swift`
- Create: `Packages/SopsGUIKit/Sources/SopsUI/Health/HealthViewModel.swift`
- Create: `Packages/SopsGUIKit/Tests/SopsUITests/HealthViewModelTests.swift`
- Modify: `Packages/SopsGUIKit/Package.swift` (SopsUI depends on SopsHealth)

**Interfaces:**
- Consumes: `HealthReport`, `HealthFinding`, `HealthStatus`, `HealthCategory`.
- Produces: `@MainActor @Observable final class HealthViewModel` with `findings: [HealthFinding]`, `isRunning: Bool`, `headlineStatus: HealthStatus`, `findings(in: HealthCategory) -> [HealthFinding]`, `func refresh() async`; and `HealthPanel(model:)`.

- [ ] **Step 1: Make SopsUI depend on SopsHealth**

In `Packages/SopsGUIKit/Package.swift`:

```swift
        .target(name: "SopsUI", dependencies: ["SopsHealth"]),
```

- [ ] **Step 2: Write the failing test**

`Packages/SopsGUIKit/Tests/SopsUITests/HealthViewModelTests.swift`:

```swift
import Testing
@testable import SopsHealth
@testable import SopsUI

private struct StubCheck: HealthCheck {
    let id: String
    let category: HealthCategory
    let findings: [HealthFinding]
    func run() async -> [HealthFinding] { findings }
}

private func finding(_ id: String, _ status: HealthStatus, _ category: HealthCategory) -> HealthFinding {
    HealthFinding(id: id, title: id, status: status, detail: "")
}

@Suite("HealthViewModel")
@MainActor
struct HealthViewModelTests {

    @Test("starts empty and populates after a refresh")
    func refreshPopulates() async {
        let model = HealthViewModel(report: HealthReport(checks: [
            StubCheck(id: "t", category: .tools, findings: [finding("tool.sops", .ok, .tools)])
        ]))
        #expect(model.findings.isEmpty)
        await model.refresh()
        #expect(model.findings.map(\.id) == ["tool.sops"])
    }

    @Test("the headline status is the worst finding")
    func headlineIsWorst() async {
        let model = HealthViewModel(report: HealthReport(checks: [
            StubCheck(id: "t", category: .tools, findings: [
                finding("a", .ok, .tools), finding("b", .problem, .tools), finding("c", .warning, .tools),
            ])
        ]))
        await model.refresh()
        #expect(model.headlineStatus == .problem)
    }

    @Test("findings are grouped by the category prefix of their id")
    func groupsByCategory() async {
        let model = HealthViewModel(report: HealthReport(checks: [
            StubCheck(id: "t", category: .tools, findings: [finding("tool.sops", .ok, .tools)]),
            StubCheck(id: "e", category: .engine, findings: [finding("engine.sops", .ok, .engine)]),
        ]))
        await model.refresh()
        #expect(model.findings(in: .tools).map(\.id) == ["tool.sops"])
        #expect(model.findings(in: .engine).map(\.id) == ["engine.sops"])
    }

    @Test("re-running replaces the previous results rather than appending")
    func refreshReplaces() async {
        let model = HealthViewModel(report: HealthReport(checks: [
            StubCheck(id: "t", category: .tools, findings: [finding("tool.sops", .ok, .tools)])
        ]))
        await model.refresh()
        await model.refresh()
        #expect(model.findings.count == 1)
    }

    @Test("isRunning is false once a refresh completes")
    func runningFlagResets() async {
        let model = HealthViewModel(report: HealthReport(checks: []))
        await model.refresh()
        #expect(model.isRunning == false)
    }
}
```

- [ ] **Step 3: Run it to verify it fails**

```bash
cd Packages/SopsGUIKit && swift test --filter HealthViewModel
```

Expected: FAIL — `cannot find 'HealthViewModel' in scope`.

- [ ] **Step 4: Implement the view model**

`Packages/SopsGUIKit/Sources/SopsUI/Health/HealthViewModel.swift`:

```swift
import Foundation
import Observation
import SopsHealth

@MainActor
@Observable
public final class HealthViewModel {
    public private(set) var findings: [HealthFinding] = []
    public private(set) var isRunning = false

    private let report: HealthReport

    public init(report: HealthReport) {
        self.report = report
    }

    public var headlineStatus: HealthStatus {
        HealthReport.worstStatus(in: findings)
    }

    /// Findings are keyed by an id whose prefix names the category, which keeps
    /// the grouping stable without the view knowing which check produced what.
    public func findings(in category: HealthCategory) -> [HealthFinding] {
        let prefix = switch category {
        case .tools: "tool."
        case .engine: "engine."
        case .security: "security."
        case .projects: "project."
        }
        return findings.filter { $0.id.hasPrefix(prefix) }
    }

    public func refresh() async {
        isRunning = true
        defer { isRunning = false }
        findings = await report.run()
    }
}
```

- [ ] **Step 5: Run it to verify it passes**

```bash
cd Packages/SopsGUIKit && swift test --filter HealthViewModel
```

Expected: PASS, 5 tests.

- [ ] **Step 5b: Add this task's catalog entries**

Add these cases to `LocalizedKey` (Task 1) and a matching entry to
`Localizable.xcstrings` for each. `everyKeyResolves` fails until both sides exist.

```swift
    case statusOK = "status.ok"                              // "OK"
    case statusWarning = "status.warning"                    // "Warning"
    case statusProblem = "status.problem"                    // "Problem"
    case statusSkipped = "status.skipped"                    // "Skipped"
    case statusUnknown = "status.unknown"                    // "Unknown"
    case actionCopy = "action.copy"                          // "Copy"
    case actionCopied = "action.copied"                      // "Copied"
    case actionLearnMore = "action.learn-more"               // "Learn more"
    case actionRerunChecks = "action.rerun-checks"           // "Re-run checks"
    case healthChecking = "health.checking"                  // "Checking…"
    case healthCategoryTools = "health.category.tools"       // "Command-line tools"
    case healthCategoryEngine = "health.category.engine"     // "Encryption engine"
    case healthCategorySecurity = "health.category.security" // "Security"
    case healthCategoryProjects = "health.category.projects" // "Projects"
```

Findings produced by `SopsHealth` carry their own English text and stay as they
are — they are diagnostic output, not chrome. Localizing them is a separate job
for whenever a second language is added.

- [ ] **Step 6: Implement the row view**

`Packages/SopsGUIKit/Sources/SopsUI/Health/HealthFindingRow.swift`:

```swift
import SwiftUI
import SopsHealth

struct HealthFindingRow: View {
    let finding: HealthFinding
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: glyph)
                    .foregroundStyle(tint)
                    .accessibilityLabel(statusDescription)
                Text(finding.title).font(.headline)
                Spacer()
            }

            if !finding.detail.isEmpty {
                Text(finding.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if case .skipped(let reason) = finding.status {
                Text(reason).font(.callout).foregroundStyle(.secondary)
            }
            if case .unknown(let reason) = finding.status {
                Text(reason).font(.callout).foregroundStyle(.secondary)
            }

            if let remediation = finding.remediation {
                Text(remediation.explanation)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                if let command = remediation.command {
                    HStack {
                        Text(command)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(6)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                        // The app shows the command; the user runs it. PROPOSAL.md §6.
                        Button(didCopy ? LocalizedKey.actionCopied.text : LocalizedKey.actionCopy.text) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(command, forType: .string)
                            didCopy = true
                        }
                    }
                }
                if let url = remediation.documentationURL {
                    Link(LocalizedKey.actionLearnMore.text, destination: url).font(.callout)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var glyph: String {
        switch finding.status {
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .problem: "xmark.octagon.fill"
        case .skipped: "minus.circle"
        case .unknown: "questionmark.circle"
        }
    }

    private var tint: Color {
        switch finding.status {
        case .ok: .green
        case .warning: .orange
        case .problem: .red
        case .skipped, .unknown: .secondary
        }
    }

    private var statusDescription: String {
        switch finding.status {
        case .ok: LocalizedKey.statusOK.text
        case .warning: LocalizedKey.statusWarning.text
        case .problem: LocalizedKey.statusProblem.text
        case .skipped: LocalizedKey.statusSkipped.text
        case .unknown: LocalizedKey.statusUnknown.text
        }
    }
}
```

- [ ] **Step 7: Implement the panel**

`Packages/SopsGUIKit/Sources/SopsUI/Health/HealthPanel.swift`:

```swift
import SwiftUI
import SopsHealth

/// The re-runnable report. Used as a Settings tab and as the final wizard step.
public struct HealthPanel: View {
    @Bindable private var model: HealthViewModel

    public init(model: HealthViewModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(HealthCategory.allCases, id: \.self) { category in
                    let findings = model.findings(in: category)
                    if !findings.isEmpty {
                        Section(title(for: category)) {
                            ForEach(findings) { HealthFindingRow(finding: $0) }
                        }
                    }
                }
            }

            Divider()

            HStack {
                if model.isRunning {
                    ProgressView().controlSize(.small)
                    Text(.healthChecking).foregroundStyle(.secondary)
                }
                Spacer()
                Button(LocalizedKey.actionRerunChecks.text) {
                    Task { await model.refresh() }
                }
                .disabled(model.isRunning)
            }
            .padding(12)
        }
        .task {
            if model.findings.isEmpty { await model.refresh() }
        }
    }

    private func title(for category: HealthCategory) -> String {
        switch category {
        case .tools: LocalizedKey.healthCategoryTools.text
        case .engine: LocalizedKey.healthCategoryEngine.text
        case .security: LocalizedKey.healthCategorySecurity.text
        case .projects: LocalizedKey.healthCategoryProjects.text
        }
    }
}
```

- [ ] **Step 8: Verify it renders**

Add the panel as a Settings tab in `App/SopsGUIApp.swift`:

```swift
        Settings {
            TabView {
                HealthPanel(model: HealthViewModel(report: .standard()))
                    .tabItem { Label(.settingsTabHealth, systemImage: "stethoscope") }
            }
            .frame(width: 620, height: 480)
        }
```

`HealthReport.standard()` does not exist yet — Task 13 adds it. For now, build with an inline `HealthReport(checks: [])` and confirm the window renders an empty list with a working "Re-run checks" button.

- [ ] **Step 9: Commit**

```bash
git add Packages/SopsGUIKit App
git commit -m "M1: health panel UI with copyable remediations"
```

---

### Task 13: Wire the real checks together

**Files:**
- Create: `Packages/SopsGUIKit/Sources/SopsHealth/HealthReport+Standard.swift`
- Create: `Packages/SopsGUIKit/Tests/SopsHealthTests/StandardReportTests.swift`
- Modify: `App/SopsGUIApp.swift`

**Interfaces:**
- Consumes: every check from Tasks 7–11.
- Produces: `HealthReport.standard(updateChecksEnabled:projects:keyStore:biometry:appUpdates:) -> HealthReport`, with defaults that reflect what has shipped so far.

- [ ] **Step 1: Write the failing test**

`Packages/SopsGUIKit/Tests/SopsHealthTests/StandardReportTests.swift`:

```swift
import Testing
@testable import SopsHealth

@Suite("standard report")
struct StandardReportTests {

    @Test("covers all four categories from PROPOSAL §6")
    func coversEveryCategory() async {
        let findings = await HealthReport.standard(updateChecksEnabled: false).run()
        let prefixes = Set(findings.map { $0.id.split(separator: ".").first.map(String.init) ?? "" })
        #expect(prefixes.isSuperset(of: ["tool", "engine", "security", "project"]))
    }

    @Test("runs offline without producing a single error state")
    func worksOffline() async {
        for finding in await HealthReport.standard(updateChecksEnabled: false).run() {
            if case .problem = finding.status {
                // Problems are legitimate findings, but none may be caused by the
                // network being unavailable.
                #expect(!finding.detail.lowercased().contains("github"))
            }
        }
    }

    @Test("every finding has a non-empty title and a stable id")
    func findingsAreWellFormed() async {
        let findings = await HealthReport.standard(updateChecksEnabled: false).run()
        #expect(!findings.isEmpty)
        #expect(Set(findings.map(\.id)).count == findings.count, "ids must be unique")
        for finding in findings {
            #expect(!finding.title.isEmpty)
            #expect(!finding.id.isEmpty)
        }
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd Packages/SopsGUIKit && swift test --filter StandardReport
```

Expected: FAIL — `type 'HealthReport' has no member 'standard'`.

- [ ] **Step 3: Implement**

`Packages/SopsGUIKit/Sources/SopsHealth/HealthReport+Standard.swift`:

```swift
import Foundation
import LocalAuthentication
import SopsEngine

extension HealthReport {

    /// The report shown in the wizard and the Settings panel.
    ///
    /// Subjects that have not shipped yet are injected as stubs that report
    /// `.skipped` with a reason, so the check is real and tested from day one.
    public static func standard(
        updateChecksEnabled: Bool,
        projects: any ProjectSourceProviding = NoProjects(),
        keyStore: any KeyStoreStatusProviding = UnshippedKeyStore(),
        biometry: any BiometryStatusProviding = SystemBiometry(),
        appUpdates: any AppUpdateStatusProviding = UnshippedAppUpdates()
    ) -> HealthReport {
        let embeddedSops = SemanticVersion(parsing: EngineVersion.sops) ?? SemanticVersion(0, 0, 0)
        let embeddedAge = SemanticVersion(parsing: EngineVersion.age) ?? SemanticVersion(0, 0, 0)

        let os = ProcessInfo.processInfo.operatingSystemVersion

        return HealthReport(checks: [
            ExternalToolCheck(locator: ToolLocator(), embeddedSopsVersion: embeddedSops),
            EngineFreshnessCheck(
                embeddedSops: embeddedSops, embeddedAge: embeddedAge,
                upstream: GitHubReleaseSource(isEnabled: { updateChecksEnabled })),
            SecurityPostureCheck(
                osVersion: SemanticVersion(os.majorVersion, os.minorVersion, os.patchVersion),
                minimumOSVersion: SemanticVersion(14, 0, 0),
                keyStore: keyStore, biometry: biometry, appUpdates: appUpdates,
                legacyKeyFilePath: NSHomeDirectory() + "/.config/sops/age/keys.txt"),
            ProjectHealthCheck(source: projects),
        ])
    }
}

public struct NoProjects: ProjectSourceProviding {
    public init() {}
    public let projects: [InspectedProject] = []
}

public struct UnshippedKeyStore: KeyStoreStatusProviding {
    public init() {}
    public let state = KeyStoreState.unavailable(reason: "Keychain key storage arrives in M3.")
}

public struct UnshippedAppUpdates: AppUpdateStatusProviding {
    public init() {}
    public let state = HealthStatus.skipped(reason: "Update checking arrives with Sparkle in M5.")
    public let detail = ""
}

public struct SystemBiometry: BiometryStatusProviding {
    public init() {}

    public var state: BiometryState {
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            return .available
        }
        return switch error?.code {
        case LAError.biometryNotEnrolled.rawValue: .notEnrolled
        case LAError.biometryNotAvailable.rawValue:
            .unavailable(reason: "This Mac has no Touch ID hardware.")
        default: .unavailable(reason: "Touch ID is not available right now.")
        }
    }
}
```

- [ ] **Step 4: Run it to verify it passes**

```bash
cd Packages/SopsGUIKit && swift test --filter StandardReport
```

Expected: PASS, 3 tests.

- [ ] **Step 5: Point the Settings panel at the real report**

In `App/SopsGUIApp.swift`, replace the placeholder from Task 12 Step 8:

```swift
                HealthPanel(model: HealthViewModel(report: .standard(updateChecksEnabled: false)))
```

- [ ] **Step 6: Run the whole suite and the app**

```bash
cd Packages/SopsGUIKit && swift test
cd ../.. && xcodebuild -project SopsGUI.xcodeproj -scheme SopsGUI -configuration Debug build
```

Open the app, press `⌘,`, and read the Health tab. On this Mac Studio expect: `sops` warning (3.13.2 behind the embedded 3.13.3), `yq` warning (not installed), engine checks unknown (update checks off), key store skipped, projects skipped, plaintext key file OK or warning depending on whether `~/.config/sops/age/keys.txt` exists.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "M1: assemble the standard health report and show it in Settings"
```

---

### Task 14: Onboarding wizard

**Files:**
- Create: `Packages/SopsGUIKit/Sources/SopsUI/Health/OnboardingWizard.swift`
- Create: `Packages/SopsGUIKit/Sources/SopsUI/Health/OnboardingState.swift`
- Create: `Packages/SopsGUIKit/Tests/SopsUITests/OnboardingStateTests.swift`
- Modify: `App/SopsGUIApp.swift`

**Interfaces:**
- Consumes: `HealthViewModel`, `HealthCategory`.
- Produces: `@MainActor @Observable final class OnboardingState` with `step: OnboardingStep`, `hasCompletedOnboarding: Bool`, `advance()`, `back()`, `finish()`; `enum OnboardingStep: welcome, tools, engine, security, projects, summary`; `OnboardingWizard(health:state:)`.

- [ ] **Step 1: Write the failing test**

`Packages/SopsGUIKit/Tests/SopsUITests/OnboardingStateTests.swift`:

```swift
import Foundation
import Testing
@testable import SopsUI

@Suite("OnboardingState")
@MainActor
struct OnboardingStateTests {

    private func makeState() -> OnboardingState {
        // A private suite name keeps the test off the real user defaults.
        OnboardingState(defaults: UserDefaults(suiteName: "onboarding-" + UUID().uuidString)!)
    }

    @Test("starts at the welcome step")
    func startsAtWelcome() {
        #expect(makeState().step == .welcome)
    }

    @Test("walks forward through every step and stops at the summary")
    func walksForward() {
        let state = makeState()
        let expected: [OnboardingStep] = [.tools, .engine, .security, .projects, .summary]
        for step in expected {
            state.advance()
            #expect(state.step == step)
        }
        state.advance()
        #expect(state.step == .summary, "the summary is the last step")
    }

    @Test("walks back and stops at the welcome step")
    func walksBack() {
        let state = makeState()
        state.advance()
        state.back()
        #expect(state.step == .welcome)
        state.back()
        #expect(state.step == .welcome)
    }

    @Test("is not marked complete until it is finished")
    func completionIsExplicit() {
        let state = makeState()
        #expect(state.hasCompletedOnboarding == false)
        state.finish()
        #expect(state.hasCompletedOnboarding == true)
    }

    @Test("completion survives a restart")
    func completionPersists() {
        let suite = "onboarding-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        OnboardingState(defaults: defaults).finish()
        #expect(OnboardingState(defaults: defaults).hasCompletedOnboarding == true)
    }

    // PROPOSAL.md §6: re-runnable. Reopening it must not lose the completion flag.
    @Test("re-running the wizard after completion restarts at welcome without un-completing it")
    func rerunIsNonDestructive() {
        let state = makeState()
        state.finish()
        state.restart()
        #expect(state.step == .welcome)
        #expect(state.hasCompletedOnboarding == true)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd Packages/SopsGUIKit && swift test --filter OnboardingState
```

Expected: FAIL — `cannot find 'OnboardingState' in scope`.

- [ ] **Step 3: Implement the state**

`Packages/SopsGUIKit/Sources/SopsUI/Health/OnboardingState.swift`:

```swift
import Foundation
import Observation
import SopsHealth

public enum OnboardingStep: Int, CaseIterable, Comparable, Sendable {
    case welcome, tools, engine, security, projects, summary

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The health category this step reports on, if any.
    var category: HealthCategory? {
        switch self {
        case .tools: .tools
        case .engine: .engine
        case .security: .security
        case .projects: .projects
        case .welcome, .summary: nil
        }
    }
}

@MainActor
@Observable
public final class OnboardingState {
    private static let completionKey = "onboarding.completed"

    public private(set) var step: OnboardingStep = .welcome
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var hasCompletedOnboarding: Bool {
        defaults.bool(forKey: Self.completionKey)
    }

    public func advance() {
        guard let next = OnboardingStep(rawValue: step.rawValue + 1) else { return }
        step = next
    }

    public func back() {
        guard let previous = OnboardingStep(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    public func finish() {
        defaults.set(true, forKey: Self.completionKey)
    }

    /// Reopens the wizard. Completion is sticky — re-running is a diagnostic,
    /// not a reset.
    public func restart() {
        step = .welcome
    }
}
```

- [ ] **Step 4: Run it to verify it passes**

```bash
cd Packages/SopsGUIKit && swift test --filter OnboardingState
```

Expected: PASS, 6 tests.

- [ ] **Step 4b: Add this task's catalog entries**

Add these cases to `LocalizedKey` (Task 1) and a matching `Localizable.xcstrings`
entry for each — `everyKeyResolves` fails until both sides exist. The English
values are the exact copy to use:

```swift
    case actionBack = "action.back"                                  // "Back"
    case actionContinue = "action.continue"                          // "Continue"
    case actionDone = "action.done"                                  // "Done"
    case actionRunSetupCheck = "action.run-setup-check"              // "Run Setup Check…"
    case settingsTabHealth = "settings.tab.health"                   // "Health"
    case onboardingWelcomeTitle = "onboarding.welcome.title"         // "Welcome"
    case onboardingSummaryTitle = "onboarding.summary.title"         // "Summary"
    case onboardingWelcomeSubtitle = "onboarding.welcome.subtitle"   // "A quick look at how this machine is set up."
    case onboardingToolsSubtitle = "onboarding.tools.subtitle"       // "Optional, but the Help snippets rely on them."
    case onboardingEngineSubtitle = "onboarding.engine.subtitle"     // "The sops and age versions built into this app."
    case onboardingSecuritySubtitle = "onboarding.security.subtitle" // "How your key is protected on this Mac."
    case onboardingProjectsSubtitle = "onboarding.projects.subtitle" // "Your .sops.yaml files and encrypted secrets."
    case onboardingSummarySubtitle = "onboarding.summary.subtitle"   // "That's everything."
    case onboardingWelcomeBody1 = "onboarding.welcome.body1"         // "This app encrypts and decrypts your secrets itself — no command-line tools required."
    case onboardingWelcomeBody2 = "onboarding.welcome.body2"         // "The next few screens check your machine anyway, because the snippets in Help run in your terminal and in CI, against the same files."
    case onboardingWelcomeBody3 = "onboarding.welcome.body3"         // "Nothing here is installed or changed for you. Where something needs fixing, you get the command and run it yourself."
    case onboardingSummaryOK = "onboarding.summary.ok"               // "Everything checks out."
    case onboardingSummaryWarning = "onboarding.summary.warning"     // "Some things are worth a look."
    case onboardingSummaryProblem = "onboarding.summary.problem"     // "Some things need fixing."
    case onboardingSummaryFooter = "onboarding.summary.footer"       // "You can re-run these checks any time from Settings › Health. Nothing here blocks you from using the app."
```

- [ ] **Step 5: Implement the wizard view**

`Packages/SopsGUIKit/Sources/SopsUI/Health/OnboardingWizard.swift`:

```swift
import SwiftUI
import SopsHealth

public struct OnboardingWizard: View {
    @Bindable private var health: HealthViewModel
    @Bindable private var state: OnboardingState
    @Environment(\.dismiss) private var dismiss

    public init(health: HealthViewModel, state: OnboardingState) {
        self.health = health
        self.state = state
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2).bold()
            Text(subtitle).foregroundStyle(.secondary)

            Divider()

            Group {
                if let category = state.step.category {
                    List(health.findings(in: category)) { HealthFindingRow(finding: $0) }
                } else if state.step == .summary {
                    summary
                } else {
                    welcome
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                Button(LocalizedKey.actionBack.text) { state.back() }
                    .disabled(state.step == .welcome)
                Spacer()
                if state.step == .summary {
                    Button(LocalizedKey.actionDone.text) {
                        state.finish()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button(LocalizedKey.actionContinue.text) { state.advance() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 640, height: 520)
        .task { await health.refresh() }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(.onboardingWelcomeBody1)
            Text(.onboardingWelcomeBody2)
            Text(.onboardingWelcomeBody3)
                .foregroundStyle(.secondary)
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch health.headlineStatus {
            case .ok:
                Label(.onboardingSummaryOK, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.title3)
            case .warning, .unknown, .skipped:
                Label(.onboardingSummaryWarning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.title3)
            case .problem:
                Label(.onboardingSummaryProblem, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red).font(.title3)
            }
            Text(.onboardingSummaryFooter)
                .foregroundStyle(.secondary)
        }
    }

    private var title: String {
        switch state.step {
        case .welcome: LocalizedKey.onboardingWelcomeTitle.text
        case .tools: LocalizedKey.healthCategoryTools.text
        case .engine: LocalizedKey.healthCategoryEngine.text
        case .security: LocalizedKey.healthCategorySecurity.text
        case .projects: LocalizedKey.healthCategoryProjects.text
        case .summary: LocalizedKey.onboardingSummaryTitle.text
        }
    }

    private var subtitle: String {
        switch state.step {
        case .welcome: LocalizedKey.onboardingWelcomeSubtitle.text
        case .tools: LocalizedKey.onboardingToolsSubtitle.text
        case .engine: LocalizedKey.onboardingEngineSubtitle.text
        case .security: LocalizedKey.onboardingSecuritySubtitle.text
        case .projects: LocalizedKey.onboardingProjectsSubtitle.text
        case .summary: LocalizedKey.onboardingSummarySubtitle.text
        }
    }
}
```

- [ ] **Step 6: Present it on first launch**

In `App/SopsGUIApp.swift`:

```swift
@main
struct SopsGUIApp: App {
    @State private var health = HealthViewModel(report: .standard(updateChecksEnabled: false))
    @State private var onboarding = OnboardingState()
    @State private var isShowingOnboarding = false

    var body: some Scene {
        WindowGroup {
            AppShell()
                .sheet(isPresented: $isShowingOnboarding) {
                    OnboardingWizard(health: health, state: onboarding)
                }
                .onAppear {
                    isShowingOnboarding = !onboarding.hasCompletedOnboarding
                }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button(LocalizedKey.actionRunSetupCheck.text) {
                    onboarding.restart()
                    isShowingOnboarding = true
                }
            }
        }

        Settings {
            TabView {
                HealthPanel(model: health)
                    .tabItem { Label(.settingsTabHealth, systemImage: "stethoscope") }
            }
            .frame(width: 620, height: 480)
        }
    }
}
```

- [ ] **Step 7: Verify the wizard end to end**

```bash
./Scripts/bootstrap.sh
xcodebuild -project SopsGUI.xcodeproj -scheme SopsGUI -configuration Debug build
defaults delete cz.mihalic.SopsGUI 2>/dev/null || true
```

Launch the app. Confirm: the wizard appears on first launch; Continue walks through all six steps; findings render with copy buttons; Done closes it; relaunching does **not** show it again; the app menu's "Run Setup Check…" reopens it at the welcome step.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "M1: re-runnable onboarding wizard"
```

---

### Task 15: Final verification

**Files:**
- Modify: `README.md` (create if absent)

- [ ] **Step 1: Run every suite from a clean state**

```bash
rm -rf Engine/build Packages/SopsGUIKit/.build SopsGUI.xcodeproj
./Scripts/bootstrap.sh
cd Engine && go vet ./... && go test ./...
cd ../Packages/SopsGUIKit && swift test
cd ../.. && xcodebuild -project SopsGUI.xcodeproj -scheme SopsGUI -configuration Release build
```

Expected: all green, no linker warnings about deployment target.

- [ ] **Step 2: Verify the app against the checklist**

Launch the Release build and confirm each of these by hand:

- First launch shows the wizard; a second launch does not.
- "Run Setup Check…" in the app menu reopens it.
- `⌘,` opens Settings with a Health tab showing the same findings.
- "Re-run checks" re-runs and the results update.
- Every remediation command has a working Copy button.
- Uninstalling a tool (`brew uninstall yq` if present) and re-running flips that finding to a warning.
- Turning off Wi-Fi and re-running leaves the engine checks `unknown`, with no error dialog.

- [ ] **Step 3: Confirm nothing leaks**

```bash
grep -rniE 'AGE-SECRET-KEY|print\(.*key' Packages/SopsGUIKit/Sources App
```

Expected: no matches outside test files.

- [ ] **Step 3b: Confirm no UI string escaped the catalog**

```bash
grep -rnE 'Text\("|Button\("|Label\("|Link\("' Packages/SopsGUIKit/Sources/SopsUI --include='*.swift'
```

Expected: no matches — every view takes a `LocalizedKey`, never a literal. The
`everyKeyResolves` test already proves each key has an English value.

- [ ] **Step 4: Write the README**

Cover: what the app is, the arm64-only + macOS 14 constraints, `./Scripts/bootstrap.sh` as the one-command setup, where the Go engine lives, how to run each suite, and a pointer to `PROPOSAL.md` and `docs/adr/`.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "M1: README and final verification pass"
```

---

## Self-Review

**Spec coverage against PROPOSAL.md §6:**

| Requirement | Task |
|---|---|
| Re-runnable | 14 (`restart()`, menu item), 12 ("Re-run checks") |
| Modal wizard on first launch + Settings panel | 14, 12 |
| App never mutates the system | 7 (`remediationsAreCopyOnly`), 10, 11 |
| A — external tools incl. yq v4 rule | 7 |
| A — PATH-independent discovery | 6 |
| B — embedded vs upstream, no CVE claims | 8, 9 (`makesNoSecurityClaims`) |
| B — consent-gated, offline-tolerant | 8 (`respectsConsent`), 9 (`offlineIsUnknown`) |
| C — macOS, biometry, key store, stray keys.txt | 10 |
| D — .sops.yaml, stale recipients, gitignore guard | 11 |
| D — honest wording about what was verified | 11 (`wordingIsHonestAboutWhatWasVerified`) |
| OK / Warning / Problem / Skipped with reasons | 5 |
| Nothing blocks | 14 (summary copy), 5 (no throwing path) |
| String Catalogs from day one | 1, 12, 14 (keys added by the task that renders them) |
| Engine integration (§3) | 2, 3 |
| Sidebar with About/Settings pinned (§4) | 1 |

**Known gaps, deliberately deferred:**

- `HealthReport.standard()` injects stubs for the Keychain key store (M3) and Sparkle (M5). The checks are complete and tested; only their data sources are stubbed. Task 10's `unshippedFeaturesAreSkipped` test locks in that they report `.skipped` with a reason rather than a false OK.
- `ProjectSourceProviding` returns no projects until the project model lands in M2. Task 11's logic is fully tested against real directories on disk.
- The `.sops.yaml` parser in Task 11 is deliberately narrow — `path_regex` and `age` only. Key groups, Shamir thresholds and non-age backends are out of scope for v1 (PROPOSAL.md §1 Non-Goals) and will need extending if that changes.

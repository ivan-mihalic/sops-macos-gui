import Foundation

/// Which on-disk document format a `SopsBridge` call is reading or writing.
///
/// Every cshim export that touches a document's *content* — as opposed to a
/// `.sops.yaml` project config, which is always YAML and never takes this —
/// now takes a `format` C string alongside the document text
/// (`Engine/cshim/main.go`'s `sops_encrypt`/`sops_decrypt`/... family). This
/// type is the one place that string is spelled in Swift; every call site
/// states it explicitly rather than defaulting, so a new document type reads
/// as a decision made at each call site rather than something that silently
/// falls back to YAML. See `String.withGoString` for how `rawValue` crosses
/// the boundary — the same mechanism every other string argument uses.
///
/// `rawValue` is the wire value in both directions: it is what crosses to Go
/// as the `format` C string, and it is exactly what `gobridge.Format`
/// (`Engine/gobridge/bridge.go`) expects — `FormatYAML = "yaml"`,
/// `FormatDotenv = "dotenv"` — before `Format.toSopsFormat()` validates it
/// against sops's own format enum. Nothing on the Swift side re-derives or
/// re-validates that string; an unrecognized value surfaces as an ordinary
/// bridge error, never a panic, because the Go side validates it first.
///
/// `.dotenv` was the first non-YAML format this app reads and writes;
/// `.json` and `.ini` (SOPS-38 phase F2) are the next two sops itself
/// supports. Adding a case here is deliberately the only place a new
/// format's wire value is spelled on the Swift side — and, by construction,
/// every exhaustive `switch` over this type elsewhere in the app fails to
/// compile until it says what the new case means, rather than silently
/// falling through a `default:`.
///
/// `.json` and `.ini` are not yet reachable from `forDestinationName` below
/// (that is F2 task 5) — a new file of either format still cannot be
/// *created* from this app. Both are fully reachable everywhere else: the
/// health scanner's classification (F2 task 3) and the editor's own
/// per-format capability matrix (`SecretDocumentViewModel.AddCapabilities`,
/// F2 task 4) both treat them as first-class formats. This task (F2 task 2)
/// only made the wire value exist and prove itself through the bridge;
/// every compile site it touched to get there is documented at that site.
public enum SopsFileFormat: String, Sendable, Codable {
    case yaml
    case dotenv
    case json
    case ini

    /// Which format a not-yet-created file at `name` should be written in —
    /// `.dotenv` when `name` ends `.env` (case-insensitively; `.sops.env`
    /// qualifies exactly like `secrets.env` does, since the decision looks
    /// only at the trailing four characters, not at how many dots come
    /// before them), `.yaml` for everything else, `.json`/`.ini` included —
    /// this build does not write either yet (see this type's own doc
    /// comment), so a name suggesting one of them still gets `.yaml` rather
    /// than a format nothing here can produce.
    ///
    /// This is the **one place** the app decides a new file's format from
    /// its *name* alone (task SOPS-38). It is a genuinely different question
    /// from how `ProjectScanner` classifies an *existing* file — that reads
    /// the file's own tail bytes and recognises sops's own on-disk metadata
    /// shape (`SopsMetadataShape`), because a file that already exists has
    /// content to sniff and a name that can lie about it (nothing stops a
    /// `.yaml` extension on a dotenv-shaped file someone renamed by hand). A
    /// file this app is about to *create* has no content yet, so the name is
    /// the only signal there is, and it is the same name the creation-plan
    /// resolver and `SecretFileCreator` already treat as authoritative for
    /// everything else about the write.
    ///
    /// Both `SecretFileCreator.create` (what actually gets written) and
    /// `NewSecretFileModel.targetFormat` (what the wizard tells the user
    /// before Create is pressed) call this and only this — see
    /// `SecretFileCreator`'s own doc comment for why a second, independent
    /// guess at the same answer would be the one way this could ever
    /// disagree with what gets written.
    public static func forDestinationName(_ name: String) -> SopsFileFormat {
        name.lowercased().hasSuffix(".env") ? .dotenv : .yaml
    }
}

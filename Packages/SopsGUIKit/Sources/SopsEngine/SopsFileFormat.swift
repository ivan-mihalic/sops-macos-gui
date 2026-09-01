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
/// `.dotenv` is the first non-YAML format this app reads and writes; `.json`
/// and `.ini` are the next two sops itself supports and are not implemented
/// yet — adding a case here is deliberately the only place a new format's
/// wire value is spelled on the Swift side.
public enum SopsFileFormat: String, Sendable, Codable {
    case yaml
    case dotenv
}

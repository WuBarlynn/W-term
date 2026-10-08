import Foundation
import Security

@main
struct SigningPolicyCheck {
  static func main() {
    guard CommandLine.arguments.count == 3 else {
      fatalError("Usage: signing-policy-check <path> <allow|deny>")
    }
    if CommandLine.arguments[1] == "--self" {
      let issue = BiometricSigningPolicy.currentIssue()
      guard (issue == nil) == (CommandLine.arguments[2] == "allow") else {
        fatalError("Unexpected current-process decision: \(issue ?? "allowed")")
      }
      print("PASS current process: \(issue ?? "allowed")")
      return
    }
    var code: SecStaticCode?
    let status = SecStaticCodeCreateWithPath(
      URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL,
      SecCSFlags(rawValue: 0), &code)
    guard status == errSecSuccess, let code = code else {
      fatalError("Unable to inspect test fixture: \(status)")
    }
    let issue = BiometricSigningPolicy.issue(for: code, expectedIdentifier: "dev.wterm.wterm")
    let expectedAllow = CommandLine.arguments[2] == "allow"
    guard (issue == nil) == expectedAllow else {
      fatalError("Unexpected signing decision: \(issue ?? "allowed")")
    }
    print("PASS \(URL(fileURLWithPath: CommandLine.arguments[1]).lastPathComponent): \(issue ?? "allowed")")
  }
}

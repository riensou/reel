// Lets Apple's signing tools use a self-signed identity's private key without
// a keychain password prompt every build. Usage:
//   swift scripts/allow-codesign.swift <identity label> [keychain path]
// Asks for the keychain (login) password once.
//
// Why not `security set-key-partition-list -l <label>`? `security import`
// gives a PKCS#12 key a NUL-terminated label that no shell argument can
// match, so we find the key through its identity instead and do what that
// command does: add "apple:" (Apple-signed tools such as codesign) to the
// key's partition list.
import Foundation
import Security

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: allow-codesign.swift <identity label> [keychain]\n".utf8))
    exit(2)
}
let name = args[1]
let wanted = ["apple-tool:", "apple:", "codesign:"]

func fail(_ msg: String, _ status: OSStatus = 0) -> Never {
    let detail = status == 0 ? "" : " (\(SecCopyErrorMessageString(status, nil) as String? ?? "\(status)"))"
    FileHandle.standardError.write(Data("allow-codesign: \(msg)\(detail)\n".utf8))
    exit(1)
}

var query: [String: Any] = [kSecClass as String: kSecClassIdentity, kSecAttrLabel as String: name,
                            kSecReturnRef as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
if args.count >= 3 {
    var kc: SecKeychain?
    guard SecKeychainOpen(args[2], &kc) == errSecSuccess, let kc else { fail("can't open keychain \(args[2])") }
    query[kSecMatchSearchList as String] = [kc]
}
var found: CFTypeRef?
let st = SecItemCopyMatching(query as CFDictionary, &found)
guard st == errSecSuccess, let identities = found as? [SecIdentity], !identities.isEmpty else { fail("no identity named \(name)", st) }

// The partition list lives in a dedicated ACL entry as a hex-encoded plist.
func partitions(of acl: SecACL) -> [String] {
    var apps: CFArray?; var desc: CFString?; var prompt = SecKeychainPromptSelector()
    SecACLCopyContents(acl, &apps, &desc, &prompt)
    guard let hex = desc as String?, hex.count % 2 == 0 else { return [] }
    var data = Data(); var i = hex.startIndex
    while i < hex.endIndex {
        let j = hex.index(i, offsetBy: 2)
        guard let b = UInt8(hex[i..<j], radix: 16) else { return [] }
        data.append(b); i = j
    }
    let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    return plist?["Partitions"] as? [String] ?? []
}

// The password-taking access setter is what `security` uses; it isn't in the
// public headers, so look it up by name.
typealias SetAccessWithPassword = @convention(c) (SecKeychainItem, SecAccess, UInt32, UnsafeRawPointer) -> OSStatus
guard let sym = dlsym(dlopen(nil, RTLD_NOW), "SecKeychainItemSetAccessWithPassword") else {
    fail("SecKeychainItemSetAccessWithPassword not available")
}
let setAccess = unsafeBitCast(sym, to: SetAccessWithPassword.self)
var password: String?

// There can be more than one identity with the name (e.g. the script run on
// two checkouts); codesign may pick any of them, so fix every key.
var seen = Set<Data>()
for identity in identities {
    var key: SecKey?
    let st2 = SecIdentityCopyPrivateKey(identity, &key)
    guard st2 == errSecSuccess, let key else { fail("no private key for \(name)", st2) }
    let attrs = SecKeyCopyAttributes(key) as? [String: Any]
    let keyID = attrs?[kSecAttrApplicationLabel as String] as? Data ?? Data()
    if !seen.insert(keyID).inserted { continue }
    let label = "key \(keyID.prefix(4).map { String(format: "%02X", $0) }.joined())"
    // Keychain-backed keys are also keychain items.
    let item = unsafeBitCast(key, to: SecKeychainItem.self)

    var access: SecAccess?
    let st3 = SecKeychainItemCopyAccess(item, &access)
    guard st3 == errSecSuccess, let access else { fail("can't read the access of \(label)", st3) }

    var acl: SecACL
    let existing = SecAccessCopyMatchingACLList(access, kSecACLAuthorizationPartitionID) as? [SecACL] ?? []
    if let first = existing.first {
        acl = first
    } else {
        var created: SecACL?
        let st = SecACLCreateWithSimpleContents(access, nil, "" as CFString, SecKeychainPromptSelector(), &created)
        guard st == errSecSuccess, let created else { fail("can't add a partition entry to \(label)", st) }
        SecACLUpdateAuthorizations(created, [kSecACLAuthorizationPartitionID] as CFArray)
        acl = created
    }
    let current = partitions(of: acl)
    let merged = current + wanted.filter { !current.contains($0) }
    if merged == current {
        print("\(name) \(label): already allows codesign (\(current.joined(separator: " ")))")
        continue
    }
    let plist: [String: Any] = ["Partitions": merged]
    let data = try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    let hex = data.map { String(format: "%02x", $0) }.joined()
    var apps: CFArray?; var desc: CFString?; var prompt = SecKeychainPromptSelector()
    SecACLCopyContents(acl, &apps, &desc, &prompt)
    let st4 = SecACLSetContents(acl, apps, hex as CFString, prompt)
    guard st4 == errSecSuccess else { fail("can't update the partition entry of \(label)", st4) }

    // Writing the ACL needs the keychain password (asked once). From the
    // terminal when there is one; otherwise piped in (tests).
    if password == nil {
        password = isatty(0) != 0 ? String(cString: getpass("Keychain password for \(name): ")) : (readLine() ?? "")
    }
    let st5 = password!.withCString { p in setAccess(item, access, UInt32(strlen(p)), p) }
    guard st5 == errSecSuccess else { fail("couldn't change the access of \(label)", st5) }
    print("\(name) \(label): codesign may now use it without asking (\(merged.joined(separator: " ")))")
}

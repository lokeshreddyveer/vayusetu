import Foundation
@main enum GeoDatabaseTests {
 static func main() {
  let db = GeoDatabase(directory: URL(fileURLWithPath: CommandLine.arguments[1]))
  precondition(db.available)
  precondition(db.country(for:"8.8.8.8")?.code == "US")
  precondition(db.country(for:"2001:4860:4860::8888")?.code == "CA")
  precondition(db.country(for:"::ffff:8.8.8.8")?.code == "US")
  for host in ["127.0.0.1","192.168.1.1","10.0.0.1","172.16.1.1","100.64.1.1","169.254.0.1","::1","fe80::1","fc00::1","example.com","unknown"] { precondition(db.country(for:host) == nil, host) }
  let missing=GeoDatabase(directory:nil)
  precondition(!missing.available && missing.country(for:"8.8.8.8") == nil)
  print("Geo database checks passed: 16")
 }
}

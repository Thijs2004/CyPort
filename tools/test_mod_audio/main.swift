// The Mac harness of tools/test_mod_audio.sh: runs the mod manager's own code (shim/ModManager*.swift, ModManagerCore.c)
// against a throw-away game folder, so the script can compare what it writes with convert.py's output.
//   convert <archive> [--keep-bnk] [--drop-unknown]   ModAudio.convert in place; prints "renamed kept bankDrops otherDrops written"
//   import <mod file> <game folder>                   analyze + install, like "Import mod…"; prints the preview and the installed files
//   installed <game folder>                           scan, then "Convert audio for the Mac game" on every mod that offers it
import Foundation

func MacShimLogC(_ what: UnsafePointer<CChar>, _ detail: UnsafePointer<CChar>) {
    FileHandle.standardError.write(Data("[\(String(cString: what))] \(String(cString: detail))\n".utf8))
}
func fail(_ s: String) -> Never { FileHandle.standardError.write(Data((s + "\n").utf8)); exit(1) }

let env = ProcessInfo.processInfo.environment
ModStore.hashesPath = env["MAC_HASHES"].flatMap { $0.isEmpty ? nil : $0 }
ModAudio.idsPath = env["MAC_MEDIA"]
let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { fail("usage: convert | import | installed") }
do {
    switch cmd {
    case "convert":
        let r = try ModAudio.convert(args[1], keepBnk: args.contains("--keep-bnk"), dropUnknown: args.contains("--drop-unknown"))
        print(r.renamed, r.kept, r.droppedBanks.count, r.droppedOther, r.written)
        for n in r.notes { print("  " + n) }
    case "import":
        let store = ModStore(gameRoot: args[2])
        let plan = try store.analyze(file: args[1])
        print("plan \(plan.name): \(plan.items.count) item(s), hashes checked: \(plan.hashesChecked)")
        for n in plan.notes { print("  note: " + n) }
        for it in plan.items { print("  \(it.selected ? "[x]" : "[ ]") \(it.rel) -> \(it.dest)\n      " + it.verdict.replacingOccurrences(of: "\n", with: "\n      ")) }
        guard plan.items.contains(where: \.selected) else { store.discard(plan); print("nothing selected"); break }
        let m = try store.install(plan)
        for n in m.notes { print("  manifest note: " + n) }
        for f in m.files { print("installed " + f.path) }
        let l = store.scan()
        print("still offers the conversion: \(l.audio[m.id] != nil)")
    case "installed":
        let store = ModStore(gameRoot: args[1])
        let l = store.scan()
        for m in l.mods + l.unmanaged {
            guard let a = l.audio[m.id] else { print("\(m.id): no conversion offered"); continue }
            print("\(m.id): offered (\(a.sounds) sound(s), \(a.banks.count) foreign bank(s))")
            print("  " + (try store.convertAudio(m)))
        }
        let after = store.scan()
        print("offered after: \((after.mods + after.unmanaged).filter { after.audio[$0.id] != nil }.map(\.id))")
    default: fail("unknown command")
    }
} catch { fail("error: \(error.localizedDescription)") }

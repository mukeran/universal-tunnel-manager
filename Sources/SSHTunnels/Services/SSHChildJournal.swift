import Darwin
import Foundation

struct SSHChildJournal {
    private struct Identity: Codable, Equatable {
        let pid: pid_t
        let uid: uid_t
        let seconds: UInt64
        let microseconds: UInt64

        init?(_ pid: pid_t) {
            guard pid > 1 else { return nil }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
                  info.pbi_uid == geteuid() else { return nil }
            self.pid = pid
            uid = info.pbi_uid
            seconds = info.pbi_start_tvsec
            microseconds = info.pbi_start_tvusec
        }
    }

    private struct Entry: Codable {
        let manager: Identity
        let child: Identity
    }

    let directory: URL

    func record(_ process: Process) {
        guard process.isRunning, let manager = Identity(getpid()),
              let child = Identity(process.processIdentifier), child.pid != manager.pid else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(Entry(manager: manager, child: child))
                .write(to: file(owner: manager.pid, child: child.pid), options: .atomic)
        } catch {
            return
        }
    }

    func remove(_ process: Process) {
        try? FileManager.default.removeItem(at: file(owner: getpid(), child: process.processIdentifier))
    }

    func recover() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        for url in files {
            guard url.pathExtension == "json", (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let data = try? Data(contentsOf: url), let entry = try? JSONDecoder().decode(Entry.self, from: data),
                  Identity(entry.manager.pid) != entry.manager else { continue }
            if entry.child.pid != getpid(), Identity(entry.child.pid) == entry.child,
               getpgid(entry.child.pid) == entry.child.pid {
                kill(-entry.child.pid, SIGTERM)
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func file(owner: pid_t, child: pid_t) -> URL {
        directory.appendingPathComponent("\(owner)-\(child).json")
    }
}

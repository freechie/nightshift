// Copyright 2026 John
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Darwin
import Foundation
import os

private let log = Logger(subsystem: "io.github.freechie.nightshift.swift", category: "command")

/// Owns nightshiftd.lock and nightshiftd.sock so the existing nightshift command
/// can talk to this app. Accept on a serial queue; handle on the main queue.
final class CommandListener: @unchecked Sendable {
  private var lockFD: Int32 = -1
  private var listenFD: Int32 = -1
  private let acceptQueue = DispatchQueue(label: "io.github.freechie.nightshift.swift.command")
  private let state = NSLock()
  private var running = false
  private var sockPath: String?
  private var onLine: ((String) -> String)?

  var isListening: Bool {
    state.lock()
    defer { state.unlock() }
    return running
  }

  /// Takes the lock, then binds the sock. False when another Nightshift already holds them.
  @discardableResult
  func start(handler: @escaping (String) -> String) -> Bool {
    stop()
    let dir = Self.supportDir()
    do {
      try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    } catch {
      log.error("command support dir failed")
      return false
    }
    guard holdLock(in: dir) else {
      log.info("command lock held; CLI keeps talking to the other process")
      return false
    }
    let path = (dir as NSString).appendingPathComponent("nightshiftd.sock")
    guard let fd = listenSocket(path: path) else {
      releaseLock()
      log.error("command socket bind failed")
      return false
    }
    state.lock()
    listenFD = fd
    sockPath = path
    onLine = handler
    running = true
    state.unlock()
    acceptLoop(fd: fd)
    log.info("listening on nightshiftd.sock")
    return true
  }

  func stop() {
    state.lock()
    running = false
    onLine = nil
    let fd = listenFD
    listenFD = -1
    let path = sockPath
    sockPath = nil
    state.unlock()
    if fd >= 0 {
      close(fd)
    }
    if let path {
      unlink(path)
    }
    releaseLock()
  }

  private static func supportDir() -> String {
    NSHomeDirectory() + "/Library/Application Support/nightshift"
  }

  private func holdLock(in dir: String) -> Bool {
    let path = (dir as NSString).appendingPathComponent("nightshiftd.lock")
    let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, S_IRUSR | S_IWUSR)
    guard fd >= 0 else { return false }
    if flock(fd, LOCK_EX | LOCK_NB) != 0 {
      close(fd)
      return false
    }
    lockFD = fd
    return true
  }

  private func releaseLock() {
    if lockFD >= 0 {
      close(lockFD)
      lockFD = -1
    }
  }

  private func listenSocket(path: String) -> Int32? {
    if path.utf8.count >= 104 { return nil }
    if Self.daemonAlreadyRunning(path: path) { return nil }
    unlink(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    path.withCString { src in
      withUnsafeMutablePointer(to: &addr.sun_path) { dst in
        dst.withMemoryRebound(to: CChar.self, capacity: 104) { buf in
          _ = strncpy(buf, src, 103)
        }
      }
    }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    let bound = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, len)
      }
    }
    if bound < 0 || chmod(path, S_IRUSR | S_IWUSR) < 0 || listen(fd, 4) < 0 {
      close(fd)
      unlink(path)
      return nil
    }
    return fd
  }

  private static func daemonAlreadyRunning(path: String) -> Bool {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    path.withCString { src in
      withUnsafeMutablePointer(to: &addr.sun_path) { dst in
        dst.withMemoryRebound(to: CChar.self, capacity: 104) { buf in
          _ = strncpy(buf, src, 103)
        }
      }
    }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    return withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, len) == 0
      }
    }
  }

  private func acceptLoop(fd: Int32) {
    acceptQueue.async { [weak self] in
      while true {
        let client = accept(fd, nil, nil)
        if client < 0 {
          if errno == EINTR { continue }
          break
        }
        self?.serve(client: client)
      }
    }
  }

  private func serve(client: Int32) {
    defer { close(client) }
    var peer: uid_t = 0
    var gid: gid_t = 0
    if getpeereid(client, &peer, &gid) != 0 || peer != getuid() {
      return
    }
    var buf = [CChar](repeating: 0, count: 128)
    let n = read(client, &buf, buf.count - 1)
    guard n > 0 else { return }
    buf[Int(n)] = 0
    guard let nl = buf.firstIndex(of: Int8(UInt8(ascii: "\n"))), nl > 0 else {
      _ = "failed\n".withCString { write(client, $0, 7) }
      return
    }
    let raw = String(decoding: buf[0..<nl].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    let replyBody: String = DispatchQueue.main.sync {
      self.state.lock()
      let handler = self.onLine
      self.state.unlock()
      return handler?(raw) ?? "failed"
    }
    let reply = replyBody + "\n"
    reply.withCString { ptr in
      let len = strlen(ptr)
      var written = 0
      while written < len {
        let n = write(client, ptr + written, len - written)
        if n < 0 {
          if errno == EINTR { continue }
          break
        }
        written += n
      }
    }
  }
}

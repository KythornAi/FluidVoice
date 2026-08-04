//
//  ProcessDataBuffer.swift
//  FluidChat (FluidVoice fork)
//
//  Lock-guarded Data accumulator for draining subprocess pipes from
//  readabilityHandler callbacks without tripping Swift 6 concurrency
//  diagnostics. Used by the Piper sidecar and environment setup.
//

import Foundation

nonisolated final class ProcessDataBuffer: @unchecked Sendable {
    private var storage = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        self.lock.lock()
        self.storage.append(chunk)
        self.lock.unlock()
    }

    func snapshot() -> Data {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.storage
    }
}

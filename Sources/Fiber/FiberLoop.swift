/*
 * Copyright 2017 Tris Foundation and the project authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License
 *
 * See LICENSE.txt in the project root for license information
 * See CONTRIBUTORS.txt for the list of the project authors
 */

import Log
import Async
import Platform
import Foundation

enum PollError: Error {
    case alreadyInUse
    case doesNotExist
}

struct Watcher {
    let fiber: UnsafeMutablePointer<Fiber>
    let deadline: Deadline
}

extension Watcher: Equatable {
    public static func ==(lhs: Watcher, rhs: Watcher) -> Bool {
        return lhs.fiber == rhs.fiber
    }
}

struct WatchersPair {
    var read: Watcher?
    var write: Watcher?
}

public struct EventError: Error, CustomStringConvertible {
    public let number = errno
    public let description = String(cString: strerror(errno))
}

extension FiberLoop: Equatable {
    public static func ==(lhs: FiberLoop, rhs: FiberLoop) -> Bool {
        return lhs.poller == rhs.poller
    }
}

extension Thread {
    var isMain: Bool {
        return true
    }
}

public class FiberLoop {
    var poller: Poller
    var watchers: [WatchersPair]
    var activeWatchers: [Watcher]

    var scheduler: FiberScheduler

    public private(set) static var main = FiberLoop()
    private static var _current = ThreadSpecific<FiberLoop>()
    public class var current: FiberLoop {
        if Thread.isMain {
            return main
        }
        return FiberLoop._current.get() {
            return FiberLoop()
        }
    }

    var loopDeadline = Deadline.distantFuture

    var nextDeadline: Deadline {
        if scheduler.hasReady {
            return now
        }

        var deadline = loopDeadline
        for watcher in activeWatchers {
            deadline = min(deadline, watcher.deadline)
        }
        return deadline
    }

    public init() {
        scheduler = FiberScheduler()
        poller = Poller()

        watchers = [WatchersPair](repeating: WatchersPair(), count: Descriptor.maxLimit)
        activeWatchers = []
    }

    var started = false
    public func run(until deadline: Date = Date.distantFuture) {
        if !started {
            started = true
            loopDeadline = deadline
            runLoop()
        }
    }

    var readyCount = 0

    var now = Date()

    func runLoop() {
        while true {
            do {
                let deadline = nextDeadline
                guard deadline >= now else {
                    break
                }

                let events = try poller.poll(deadline: deadline)
                now = Date()

                scheduleReady(events)
                scheduleExpired()
                runScheduled()
            } catch {
                Log.error("poll error \(error)")
            }
        }
    }

    func scheduleReady(_ events: ArraySlice<Event>) {
        for event in events {
            let index = Int(event.descriptor)

            guard watchers[index].read != nil || watchers[index].write != nil else {
                // kqueue error on closed descriptor
                if event.isError {
                    Log.error("event \(EventError())")
                    return
                }
                // shouldn't happen
                Log.critical("zombie descriptor \(event.descriptor) event (\"\\(O.o)/\") booooo!")
                abort()
            }

            if event.typeOptions.contains(.read),
                let watcher = watchers[index].read {
                scheduler.schedule(fiber: watcher.fiber, state: .ready)
            }

            if event.typeOptions.contains(.write),
                let watcher = watchers[index].write {
                scheduler.schedule(fiber: watcher.fiber, state: .ready)
            }
        }
    }

    func scheduleExpired() {
        for watcher in activeWatchers {
            if watcher.deadline <= now {
                scheduler.schedule(fiber: watcher.fiber, state: .expired)
            }
        }
    }

    func runScheduled() {
        if scheduler.hasReady {
            scheduler.runReadyChain()
        }
    }

    public func wait(for deadline: Deadline) {
        let watcher = Watcher(fiber: scheduler.running, deadline: deadline)
        add(watcher)
        scheduler.sleep()
        remove(watcher)
    }

    func add(_ watcher: Watcher) {
        activeWatchers.append(watcher)
    }

    func remove(_ watcher: Watcher) {
        let index = activeWatchers.index(of: watcher)!
        activeWatchers.remove(at: index)
    }

    public func wait(for socket: Descriptor, event: IOEvent, deadline: Deadline) throws {
        let watcher = Watcher(fiber: scheduler.running, deadline: deadline)
        try add(watcher, for: socket, event: event)
        scheduler.sleep()
        remove(watcher, for: socket, event: event)
    }

    func add(_ watcher: Watcher, for descriptor: Descriptor, event: IOEvent) throws {
        let fd = Int(descriptor)

        switch event {
        case .read:
            guard watchers[fd].read == nil else {
                throw PollError.alreadyInUse
            }
            watchers[fd].read = watcher
            activeWatchers.append(watcher)
        case .write:
            guard watchers[fd].write == nil else {
                throw PollError.alreadyInUse
            }
            watchers[fd].write = watcher
            activeWatchers.append(watcher)
        }

        poller.add(socket: descriptor, event: event)
    }

    func remove(_ watcher: Watcher, for descriptor: Descriptor, event: IOEvent) {
        let fd = Int(descriptor)

        switch event {
        case .read:
            watchers[fd].read = nil
            let index = activeWatchers.index(of: watcher)!
            activeWatchers.remove(at: index)

        case .write:
            watchers[fd].write = nil
            let index = activeWatchers.index(of: watcher)!
            activeWatchers.remove(at: index)
        }
        
        poller.remove(socket: descriptor, event: event)
    }
}

//
//  Future.swift
//  Based originially on swiftz code by Maxwell Swadling
//  With GCD additions by Rob Napier
//

import Foundation

private let sharedProcessingQueue = dispatch_queue_create("llama.future.shared-processing", DISPATCH_QUEUE_CONCURRENT)

public class Future<T> {
  private var _value: Result<T>?

  // The resultQueue is used to read the result. It begins suspended
  // and is resumed once a result exists.
  // FIXME: Would like to add a uniqueid to the label
  let resultReadyGroup = dispatch_group_create()

  let mutateQueue = dispatch_queue_create("llama.future.value", DISPATCH_QUEUE_SERIAL)

  let processingQueue: dispatch_queue_t

  internal init(queue: dispatch_queue_t = sharedProcessingQueue) {
    self.processingQueue = queue
    dispatch_group_enter(self.resultReadyGroup)
  }

  public convenience init(_ f: () -> Result<T>, queue: dispatch_queue_t = sharedProcessingQueue) {
    self.init(queue: queue)
    dispatch_async(self.processingQueue) { self.completeWith(f()) }
  }

  public func isCompleted() -> Bool {
    var isCompleted: Bool = false
    dispatch_sync(self.mutateQueue) {
      isCompleted = self._value != nil
    }
    return isCompleted
  }

  // FIXME: Use dispatch_group_notify to schedule
  public func onComplete(f: Result<T> -> ()) {
    dispatch_group_notify(self.resultReadyGroup, processingQueue) { f(self._value!) }
  }

  public func onSuccess(f: T -> ()) {
    dispatch_group_notify(self.resultReadyGroup, self.processingQueue) {
      switch self._value! {
      case .Success(let box):
        dispatch_group_notify(self.resultReadyGroup, self.processingQueue) { f(box.unbox) }
      case .Failure(_): return
      }
    }
  }

  public func onFailure(f: NSError -> ()) {
    dispatch_group_notify(self.resultReadyGroup, self.processingQueue) {
      switch self._value! {
      case .Success(_): return
      case .Failure(let err): dispatch_group_notify(self.resultReadyGroup, self.processingQueue) { f(err) }
      }
    }
  }

  internal func completeWith(x: Result<T>) {
    dispatch_async(mutateQueue) {
      precondition(self._value == nil, "Future cannot complete more than once")
      self._value = x
      dispatch_group_leave(self.resultReadyGroup)
    }
  }

  public func result() -> Result<T> {
    return self.waitResult()!
  }

  public func waitResult(timeout: dispatch_time_t = DISPATCH_TIME_FOREVER) -> Result<T>? {
    if dispatch_group_wait(self.resultReadyGroup, timeout) == 0 {
      return self._value!
    } else {
      return nil
    }
  }

  public func map<U>(f: T -> U) -> Future<U> {
    let newFuture = Future<U>()
    self.onComplete { r in
      switch r {
      case .Success(let box): newFuture.completeWith(success(f(box.unbox)))
      case .Failure(let err): newFuture.completeWith(failure(err))
      }
    }
    return newFuture
  }

  public func flatMap<U>(f: T -> Future<U>) -> Future<U> {
    let newFuture = Future<U>()
    self.onComplete { r in
      switch r {
      case .Success(let box): newFuture.completeWith(f(box.unbox).result())
      case .Failure(let err): newFuture.completeWith(failure(err))
      }
    }
    return newFuture
  }
}

public func sequence<T>(futures: [Future<T>]) -> Future<[T]> {
  return future {
    return futures.reduce(success([T]())) { acc, fu in
      switch acc {
      case .Success(let accBox):
        switch fu.result() {
        case .Success(let resultBox): return success(accBox.unbox + [resultBox.unbox])
        case .Failure(let err): return failure(err)
        }
      case .Failure(let err): return acc
      }
    }
  }
}

// FIXME: This should be combinable with the Result version.
// But not sure how to define Functor without forcing Result and Future to be subclasses
// Result is an enum, so that's hard.
public func <**><T,U>(x: Future<T>, f: T -> U) -> Future<U> {
  return x.map(f)
}

public func future<T>(f: () -> Result<T>) -> Future<T> {
  return Future(f)
}

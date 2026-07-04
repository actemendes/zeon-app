import Foundation

func runBlocking<T>(_ operation: @escaping () async throws -> T) throws -> T {
  let semaphore = DispatchSemaphore(value: 0)
  var result: Result<T, Error>!

  Task {
    do {
      result = .success(try await operation())
    } catch {
      result = .failure(error)
    }
    semaphore.signal()
  }

  semaphore.wait()
  return try result.get()
}

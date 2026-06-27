import Foundation

@propertyWrapper
struct Stored<Value> {
  private let key: String
  private let defaultValue: Value
  private let store: UserDefaults

  init(key: String, defaultValue: Value, store: UserDefaults = UserDefaults(suiteName: FilePath.groupName) ?? .standard) {
    self.key = key
    self.defaultValue = defaultValue
    self.store = store
  }

  var wrappedValue: Value {
    get {
      store.object(forKey: key) as? Value ?? defaultValue
    }
    set {
      store.set(newValue, forKey: key)
    }
  }
}

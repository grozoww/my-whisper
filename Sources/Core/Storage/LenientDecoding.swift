import Foundation

/// Decoding that tolerates a file written by a different version of the app.
///
/// Swift's synthesized `Codable` does **not** fall back to a property's default value when a key
/// is missing — it throws. That behaviour is a trap for a settings file: adding one field to a
/// struct makes every existing file undecodable, `JSONFileStore` quarantines it, and everyone's
/// configuration, modes and vocabulary silently revert on upgrade.
///
/// Every persisted type in this app therefore decodes through this helper, so a missing key takes
/// the default and an unrecognised key is ignored. That is what makes "add a field with a default"
/// a safe change, and it is the only reason the schema can evolve without a migration for each
/// step.
extension KeyedDecodingContainer {
    /// The value for `key`, or `fallback` when it is absent, null, or the wrong type.
    ///
    /// The wrong-type case is deliberate too: a hand-edited file with `"retention": 30` where a
    /// string belongs should cost the user that one setting, not the whole file.
    ///
    /// `try?` flattens the `T??` that `decodeIfPresent` would otherwise produce, which collapses
    /// "key absent" and "value unreadable" into the same `nil` — and both should take the default,
    /// so there is nothing to tell apart.
    func value<T: Decodable>(_ key: Key, or fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }

    /// Same, for a genuinely optional field where absent, null and unreadable all mean nil.
    func optional<T: Decodable>(_ key: Key) -> T? {
        try? decodeIfPresent(T.self, forKey: key)
    }

    /// For an optional field whose default is *not* nil.
    ///
    /// `decodeIfPresent` collapses "the key is missing" and "the key is null" into the same nil,
    /// which is wrong here: a file written before the field existed should get the new default,
    /// while a file where the user deliberately cleared the value must stay cleared. `contains`
    /// is what tells those two apart.
    func optional<T: Decodable>(_ key: Key, defaultWhenAbsent fallback: T?) -> T? {
        guard contains(key) else { return fallback }
        return try? decodeIfPresent(T.self, forKey: key)
    }
}

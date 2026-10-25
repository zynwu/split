import Foundation

enum DeviceIDStorageKey {
#if DEBUG
    static let deviceID = "deviceID"
#else
    static let deviceID = "deviceID.release"
#endif
}

protocol DeviceIDStoring {
    func loadDeviceID() -> DeviceID?
    func saveDeviceID(_ deviceID: DeviceID)
    func deleteDeviceID()
}

struct UserDefaultsDeviceIDStore: DeviceIDStoring {
    private let userDefaults: UserDefaults
    private let key = DeviceIDStorageKey.deviceID

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func loadDeviceID() -> DeviceID? {
        guard let rawValue = userDefaults.string(forKey: key) else { return nil }
        return DeviceID(rawValue: rawValue)
    }

    func saveDeviceID(_ deviceID: DeviceID) {
        userDefaults.set(deviceID.rawValue, forKey: key)
    }

    func deleteDeviceID() {
        userDefaults.removeObject(forKey: key)
    }
}

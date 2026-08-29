import Foundation

protocol DeviceIDStoring {
    func loadDeviceID() -> DeviceID?
    func saveDeviceID(_ deviceID: DeviceID)
}

struct UserDefaultsDeviceIDStore: DeviceIDStoring {
    private let userDefaults: UserDefaults
    private let key = "deviceID"

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
}

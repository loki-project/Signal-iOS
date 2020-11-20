
public struct Configuration {
    public let storage: SessionSnodeKitStorageProtocol

    internal static var shared: Configuration!
}

public enum SessionSnodeKit { // Just to make the external API nice

    public static func configure(storage: SessionSnodeKitStorageProtocol) {
        Configuration.shared = Configuration(storage: storage)
    }
}

//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

import Foundation

// WARNING: This code is generated. Only edit within the markers.

public enum SignalIOSProtoError: Error {
    case invalidProtobuf(description: String)
}

// MARK: - SignalIOSProtoBackupSnapshotBackupEntity

@objc public class SignalIOSProtoBackupSnapshotBackupEntity: NSObject {

    // MARK: - SignalIOSProtoBackupSnapshotBackupEntityType

    @objc public enum SignalIOSProtoBackupSnapshotBackupEntityType: Int32 {
        case unknown = 0
        case migration = 1
        case thread = 2
        case interaction = 3
        case attachment = 4
        case misc = 5
    }

    private class func SignalIOSProtoBackupSnapshotBackupEntityTypeWrap(_ value: IOSProtos_BackupSnapshot.BackupEntity.TypeEnum) -> SignalIOSProtoBackupSnapshotBackupEntityType {
        switch value {
        case .unknown: return .unknown
        case .migration: return .migration
        case .thread: return .thread
        case .interaction: return .interaction
        case .attachment: return .attachment
        case .misc: return .misc
        }
    }

    private class func SignalIOSProtoBackupSnapshotBackupEntityTypeUnwrap(_ value: SignalIOSProtoBackupSnapshotBackupEntityType) -> IOSProtos_BackupSnapshot.BackupEntity.TypeEnum {
        switch value {
        case .unknown: return .unknown
        case .migration: return .migration
        case .thread: return .thread
        case .interaction: return .interaction
        case .attachment: return .attachment
        case .misc: return .misc
        }
    }

    // MARK: - SignalIOSProtoBackupSnapshotBackupEntityBuilder

    @objc public class func builder(type: SignalIOSProtoBackupSnapshotBackupEntityType, entityData: Data, collection: String, key: String) -> SignalIOSProtoBackupSnapshotBackupEntityBuilder {
        return SignalIOSProtoBackupSnapshotBackupEntityBuilder(type: type, entityData: entityData, collection: collection, key: key)
    }

    // asBuilder() constructs a builder that reflects the proto's contents.
    @objc public func asBuilder() -> SignalIOSProtoBackupSnapshotBackupEntityBuilder {
        let builder = SignalIOSProtoBackupSnapshotBackupEntityBuilder(type: type, entityData: entityData, collection: collection, key: key)
        return builder
    }

    @objc public class SignalIOSProtoBackupSnapshotBackupEntityBuilder: NSObject {

        private var proto = IOSProtos_BackupSnapshot.BackupEntity()

        @objc fileprivate override init() {}

        @objc fileprivate init(type: SignalIOSProtoBackupSnapshotBackupEntityType, entityData: Data, collection: String, key: String) {
            super.init()

            setType(type)
            setEntityData(entityData)
            setCollection(collection)
            setKey(key)
        }

        @objc public func setType(_ valueParam: SignalIOSProtoBackupSnapshotBackupEntityType) {
            proto.type = SignalIOSProtoBackupSnapshotBackupEntityTypeUnwrap(valueParam)
        }

        @objc public func setEntityData(_ valueParam: Data) {
            proto.entityData = valueParam
        }

        @objc public func setCollection(_ valueParam: String) {
            proto.collection = valueParam
        }

        @objc public func setKey(_ valueParam: String) {
            proto.key = valueParam
        }

        @objc public func build() throws -> SignalIOSProtoBackupSnapshotBackupEntity {
            return try SignalIOSProtoBackupSnapshotBackupEntity.parseProto(proto)
        }

        @objc public func buildSerializedData() throws -> Data {
            return try SignalIOSProtoBackupSnapshotBackupEntity.parseProto(proto).serializedData()
        }
    }

    fileprivate let proto: IOSProtos_BackupSnapshot.BackupEntity

    @objc public let type: SignalIOSProtoBackupSnapshotBackupEntityType

    @objc public let entityData: Data

    @objc public let collection: String

    @objc public let key: String

    private init(proto: IOSProtos_BackupSnapshot.BackupEntity,
                 type: SignalIOSProtoBackupSnapshotBackupEntityType,
                 entityData: Data,
                 collection: String,
                 key: String) {
        self.proto = proto
        self.type = type
        self.entityData = entityData
        self.collection = collection
        self.key = key
    }

    @objc
    public func serializedData() throws -> Data {
        return try self.proto.serializedData()
    }

    @objc public class func parseData(_ serializedData: Data) throws -> SignalIOSProtoBackupSnapshotBackupEntity {
        let proto = try IOSProtos_BackupSnapshot.BackupEntity(serializedData: serializedData)
        return try parseProto(proto)
    }

    fileprivate class func parseProto(_ proto: IOSProtos_BackupSnapshot.BackupEntity) throws -> SignalIOSProtoBackupSnapshotBackupEntity {
        guard proto.hasType else {
            throw SignalIOSProtoError.invalidProtobuf(description: "\(logTag) missing required field: type")
        }
        let type = SignalIOSProtoBackupSnapshotBackupEntityTypeWrap(proto.type)

        guard proto.hasEntityData else {
            throw SignalIOSProtoError.invalidProtobuf(description: "\(logTag) missing required field: entityData")
        }
        let entityData = proto.entityData

        guard proto.hasCollection else {
            throw SignalIOSProtoError.invalidProtobuf(description: "\(logTag) missing required field: collection")
        }
        let collection = proto.collection

        guard proto.hasKey else {
            throw SignalIOSProtoError.invalidProtobuf(description: "\(logTag) missing required field: key")
        }
        let key = proto.key

        // MARK: - Begin Validation Logic for SignalIOSProtoBackupSnapshotBackupEntity -

        // MARK: - End Validation Logic for SignalIOSProtoBackupSnapshotBackupEntity -

        let result = SignalIOSProtoBackupSnapshotBackupEntity(proto: proto,
                                                              type: type,
                                                              entityData: entityData,
                                                              collection: collection,
                                                              key: key)
        return result
    }

    @objc public override var debugDescription: String {
        return "\(proto)"
    }
}

#if DEBUG

extension SignalIOSProtoBackupSnapshotBackupEntity {
    @objc public func serializedDataIgnoringErrors() -> Data? {
        return try! self.serializedData()
    }
}

extension SignalIOSProtoBackupSnapshotBackupEntity.SignalIOSProtoBackupSnapshotBackupEntityBuilder {
    @objc public func buildIgnoringErrors() -> SignalIOSProtoBackupSnapshotBackupEntity? {
        return try! self.build()
    }
}

#endif

// MARK: - SignalIOSProtoBackupSnapshot

@objc public class SignalIOSProtoBackupSnapshot: NSObject {

    // MARK: - SignalIOSProtoBackupSnapshotBuilder

    @objc public class func builder() -> SignalIOSProtoBackupSnapshotBuilder {
        return SignalIOSProtoBackupSnapshotBuilder()
    }

    // asBuilder() constructs a builder that reflects the proto's contents.
    @objc public func asBuilder() -> SignalIOSProtoBackupSnapshotBuilder {
        let builder = SignalIOSProtoBackupSnapshotBuilder()
        builder.setEntity(entity)
        return builder
    }

    @objc public class SignalIOSProtoBackupSnapshotBuilder: NSObject {

        private var proto = IOSProtos_BackupSnapshot()

        @objc fileprivate override init() {}

        @objc public func addEntity(_ valueParam: SignalIOSProtoBackupSnapshotBackupEntity) {
            var items = proto.entity
            items.append(valueParam.proto)
            proto.entity = items
        }

        @objc public func setEntity(_ wrappedItems: [SignalIOSProtoBackupSnapshotBackupEntity]) {
            proto.entity = wrappedItems.map { $0.proto }
        }

        @objc public func build() throws -> SignalIOSProtoBackupSnapshot {
            return try SignalIOSProtoBackupSnapshot.parseProto(proto)
        }

        @objc public func buildSerializedData() throws -> Data {
            return try SignalIOSProtoBackupSnapshot.parseProto(proto).serializedData()
        }
    }

    fileprivate let proto: IOSProtos_BackupSnapshot

    @objc public let entity: [SignalIOSProtoBackupSnapshotBackupEntity]

    private init(proto: IOSProtos_BackupSnapshot,
                 entity: [SignalIOSProtoBackupSnapshotBackupEntity]) {
        self.proto = proto
        self.entity = entity
    }

    @objc
    public func serializedData() throws -> Data {
        return try self.proto.serializedData()
    }

    @objc public class func parseData(_ serializedData: Data) throws -> SignalIOSProtoBackupSnapshot {
        let proto = try IOSProtos_BackupSnapshot(serializedData: serializedData)
        return try parseProto(proto)
    }

    fileprivate class func parseProto(_ proto: IOSProtos_BackupSnapshot) throws -> SignalIOSProtoBackupSnapshot {
        var entity: [SignalIOSProtoBackupSnapshotBackupEntity] = []
        entity = try proto.entity.map { try SignalIOSProtoBackupSnapshotBackupEntity.parseProto($0) }

        // MARK: - Begin Validation Logic for SignalIOSProtoBackupSnapshot -

        // MARK: - End Validation Logic for SignalIOSProtoBackupSnapshot -

        let result = SignalIOSProtoBackupSnapshot(proto: proto,
                                                  entity: entity)
        return result
    }

    @objc public override var debugDescription: String {
        return "\(proto)"
    }
}

#if DEBUG

extension SignalIOSProtoBackupSnapshot {
    @objc public func serializedDataIgnoringErrors() -> Data? {
        return try! self.serializedData()
    }
}

extension SignalIOSProtoBackupSnapshot.SignalIOSProtoBackupSnapshotBuilder {
    @objc public func buildIgnoringErrors() -> SignalIOSProtoBackupSnapshot? {
        return try! self.build()
    }
}

#endif

// MARK: - SignalIOSProtoDeviceName

@objc public class SignalIOSProtoDeviceName: NSObject {

    // MARK: - SignalIOSProtoDeviceNameBuilder

    @objc public class func builder(ephemeralPublic: Data, syntheticIv: Data, ciphertext: Data) -> SignalIOSProtoDeviceNameBuilder {
        return SignalIOSProtoDeviceNameBuilder(ephemeralPublic: ephemeralPublic, syntheticIv: syntheticIv, ciphertext: ciphertext)
    }

    // asBuilder() constructs a builder that reflects the proto's contents.
    @objc public func asBuilder() -> SignalIOSProtoDeviceNameBuilder {
        let builder = SignalIOSProtoDeviceNameBuilder(ephemeralPublic: ephemeralPublic, syntheticIv: syntheticIv, ciphertext: ciphertext)
        return builder
    }

    @objc public class SignalIOSProtoDeviceNameBuilder: NSObject {

        private var proto = IOSProtos_DeviceName()

        @objc fileprivate override init() {}

        @objc fileprivate init(ephemeralPublic: Data, syntheticIv: Data, ciphertext: Data) {
            super.init()

            setEphemeralPublic(ephemeralPublic)
            setSyntheticIv(syntheticIv)
            setCiphertext(ciphertext)
        }

        @objc public func setEphemeralPublic(_ valueParam: Data) {
            proto.ephemeralPublic = valueParam
        }

        @objc public func setSyntheticIv(_ valueParam: Data) {
            proto.syntheticIv = valueParam
        }

        @objc public func setCiphertext(_ valueParam: Data) {
            proto.ciphertext = valueParam
        }

        @objc public func build() throws -> SignalIOSProtoDeviceName {
            return try SignalIOSProtoDeviceName.parseProto(proto)
        }

        @objc public func buildSerializedData() throws -> Data {
            return try SignalIOSProtoDeviceName.parseProto(proto).serializedData()
        }
    }

    fileprivate let proto: IOSProtos_DeviceName

    @objc public let ephemeralPublic: Data

    @objc public let syntheticIv: Data

    @objc public let ciphertext: Data

    private init(proto: IOSProtos_DeviceName,
                 ephemeralPublic: Data,
                 syntheticIv: Data,
                 ciphertext: Data) {
        self.proto = proto
        self.ephemeralPublic = ephemeralPublic
        self.syntheticIv = syntheticIv
        self.ciphertext = ciphertext
    }

    @objc
    public func serializedData() throws -> Data {
        return try self.proto.serializedData()
    }

    @objc public class func parseData(_ serializedData: Data) throws -> SignalIOSProtoDeviceName {
        let proto = try IOSProtos_DeviceName(serializedData: serializedData)
        return try parseProto(proto)
    }

    fileprivate class func parseProto(_ proto: IOSProtos_DeviceName) throws -> SignalIOSProtoDeviceName {
        guard proto.hasEphemeralPublic else {
            throw SignalIOSProtoError.invalidProtobuf(description: "\(logTag) missing required field: ephemeralPublic")
        }
        let ephemeralPublic = proto.ephemeralPublic

        guard proto.hasSyntheticIv else {
            throw SignalIOSProtoError.invalidProtobuf(description: "\(logTag) missing required field: syntheticIv")
        }
        let syntheticIv = proto.syntheticIv

        guard proto.hasCiphertext else {
            throw SignalIOSProtoError.invalidProtobuf(description: "\(logTag) missing required field: ciphertext")
        }
        let ciphertext = proto.ciphertext

        // MARK: - Begin Validation Logic for SignalIOSProtoDeviceName -

        // MARK: - End Validation Logic for SignalIOSProtoDeviceName -

        let result = SignalIOSProtoDeviceName(proto: proto,
                                              ephemeralPublic: ephemeralPublic,
                                              syntheticIv: syntheticIv,
                                              ciphertext: ciphertext)
        return result
    }

    @objc public override var debugDescription: String {
        return "\(proto)"
    }
}

#if DEBUG

extension SignalIOSProtoDeviceName {
    @objc public func serializedDataIgnoringErrors() -> Data? {
        return try! self.serializedData()
    }
}

extension SignalIOSProtoDeviceName.SignalIOSProtoDeviceNameBuilder {
    @objc public func buildIgnoringErrors() -> SignalIOSProtoDeviceName? {
        return try! self.build()
    }
}

#endif

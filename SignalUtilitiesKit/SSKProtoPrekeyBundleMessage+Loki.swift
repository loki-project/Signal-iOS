
@objc public extension SSKProtoPrekeyBundleMessage {
    
    @objc(builderFromPreKeyBundle:)
    public static func builder(from preKeyBundle: PreKeyBundle) -> SSKProtoPrekeyBundleMessageBuilder {
        let builder = self.builder()
        builder.setIdentityKey(preKeyBundle.identityKey)
        builder.setDeviceID(UInt32(preKeyBundle.deviceId))
        builder.setPrekeyID(UInt32(preKeyBundle.preKeyId))
        builder.setPrekey(preKeyBundle.preKeyPublic)
        builder.setSignedKeyID(UInt32(preKeyBundle.signedPreKeyId))
        builder.setSignedKey(preKeyBundle.signedPreKeyPublic)
        builder.setSignature(preKeyBundle.signedPreKeySignature)
        return builder
    }
    
    @objc(getPreKeyBundleWithTransaction:)
    public func getPreKeyBundle(with transaction: YapDatabaseReadWriteTransaction) -> PreKeyBundle? {
        let registrationId = TSAccountManager.sharedInstance().getOrGenerateRegistrationId(transaction)
        return PreKeyBundle(registrationId: Int32(registrationId), deviceId: Int32(deviceID), preKeyId: Int32(prekeyID), preKeyPublic: prekey,
            signedPreKeyPublic: signedKey, signedPreKeyId: Int32(signedKeyID), signedPreKeySignature: signature, identityKey: identityKey)
    }
}

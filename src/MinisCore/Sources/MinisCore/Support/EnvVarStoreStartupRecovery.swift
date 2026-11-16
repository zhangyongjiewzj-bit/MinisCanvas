import Foundation

/// Narrow production composition seam for startup.  The caller can surface a
/// typed failure and continue with a controlled recovery screen; no pending
/// file is ever promoted by this entry point.
public extension EnvVarStore {
    static func recoverCredentialMetadataAtStartup(
        in directory: URL,
        fileSystem: any CredentialMetadataRecoveryFileSystem = LiveCredentialMetadataRecoveryFileSystem()
    ) -> Result<CredentialMetadataRecovery.Receipt, CredentialMetadataRecovery.Failure> {
        CredentialMetadataRecovery.recover(
            in: directory,
            metadataFileName: Self.fileName,
            fileSystem: fileSystem
        )
    }
}

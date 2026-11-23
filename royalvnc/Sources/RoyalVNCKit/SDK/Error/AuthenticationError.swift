#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

public extension VNCError {
	enum AuthenticationError: Error, LocalizedError {
		case serverOfferedNoAuthTypes(reason: String?)
		case clientCouldNotDecideOnSecurityType
		case securityHandshakingFailed(reason: String?)
		case noAuthenticationDataProvided
		case ardAuthenticationFailed
		case ultraVNCMSLogonIIAuthenticationFailed
		case encryptionFailed
		/// Duo Desktop: the server did not offer the Mac's own account sign-in (type 30). `offered` lists what it did.
		case macAccountSignInNotOffered(offered: [UInt8])

		// MARK: - LocalizedError
		public var errorDescription: String? {
			// TODO: Localize
			switch self {
				case .serverOfferedNoAuthTypes(let reason):
					return combinedErrorDescription("The Server offered no authentication types.",
													reason: reason)
				case .clientCouldNotDecideOnSecurityType:
					return "The Client could not decide on a Security Type."
				case .securityHandshakingFailed(let reason):
					return combinedErrorDescription("Security handshaking failed.",
													reason: reason)
				case .noAuthenticationDataProvided:
					return "No authentication data was provided."
				case .ardAuthenticationFailed:
					return "Apple Remote Desktop authentication failed."
				case .ultraVNCMSLogonIIAuthenticationFailed:
					return "UltraVNC MS-Logon II authentication failed."
				case .encryptionFailed:
					return "Encryption failed."
				case .macAccountSignInNotOffered(let offered):
					return "This computer does not offer sign-in with a Mac account (it offered: \(offered.map(String.init).joined(separator: ", ")))."
			}
		}
	}
}

private extension VNCError.AuthenticationError {
	func combinedErrorDescription(_ baseErrorDescription: String,
								  reason: String?) -> String {
		let unwrappedReason: String

		if let reason = reason {
			unwrappedReason = reason
		} else {
			unwrappedReason = ""
		}

		return "\(baseErrorDescription)\(unwrappedReason.isEmpty ? "" : " Reason provided by the Server: \(unwrappedReason)")"
	}
}

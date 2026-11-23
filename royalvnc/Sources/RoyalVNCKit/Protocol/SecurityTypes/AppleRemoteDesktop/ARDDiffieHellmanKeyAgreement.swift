#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

extension VNCProtocol.ARDAuthentication {
	struct DiffieHellmanKeyAgreement {
		/// Duo Desktop (#43): the largest key size accepted from a server, in bytes (4096 bits). A limit on our work,
		/// not a protocol limit.
		static let maximumKeySize = 512

		let publicKey: Data
		let privateKey: Data
		let secretKey: Data

		init?(prime: Data,
			  generator: Data,
			  peerKey: Data,
			  keyLength: Int) {
			guard Self.acceptsParameters(prime: prime,
										 generator: generator,
										 peerKey: peerKey,
										 keyLength: keyLength) else {
				return nil
			}

			guard let keyPair = Self.generateKeyPair(generator: generator,
													 prime: prime,
													 keyLength: keyLength),
				  !keyPair.privateKey.isEmpty,
				  !keyPair.publicKey.isEmpty else {
				return nil
			}

			guard let secretKey = Self.computeSharedKey(prime: prime,
														peerKey: peerKey,
														privateKey: keyPair.privateKey,
														keyLength: keyLength),
				  !secretKey.isEmpty else {
				return nil
			}

			self.publicKey = keyPair.publicKey
			self.privateKey = keyPair.privateKey
			self.secretKey = secretKey
		}

		/// Duo Desktop (#43): the server's values, checked before any arithmetic. Key size within bounds; prime and
		/// peer key exactly that long; a 1- or 2-byte generator; an odd modulus of at least 5; generator and peer key
		/// strictly between 1 and p - 1. This stops zero-modulus traps, a private-key loop that never ends and trivial
		/// public values. It does not prove the number is prime or who the server is.
		static func acceptsParameters(prime: Data,
									  generator: Data,
									  peerKey: Data,
									  keyLength: Int) -> Bool {
			guard (1...maximumKeySize).contains(keyLength),
				  prime.count == keyLength,
				  peerKey.count == keyLength,
				  (1...2).contains(generator.count),
				  let modulus = BigNum(data: prime),
				  !modulus.isLessThan(5),
				  modulus.isOdd,
				  let base = BigNum(data: generator),
				  let peer = BigNum(data: peerKey) else {
				return false
			}

			return base.isValidDiffieHellmanPublicValue(modulus: modulus) &&
				peer.isValidDiffieHellmanPublicValue(modulus: modulus)
		}
	}
}

private extension VNCProtocol.ARDAuthentication.DiffieHellmanKeyAgreement {
	struct KeyPair {
		let publicKey: Data
		let privateKey: Data
	}

	static func generateKeyPair(generator: Data,
								prime: Data,
								keyLength: Int) -> KeyPair? {
		let bigPrivKey = BigNum()
		let bigPubKey = BigNum()

		guard let bigPrime = BigNum(data: prime),
			  let bigGenerator = BigNum(data: generator) else {
			return nil
		}

		// Generate DH private key
		repeat {
			let randSuccess = bigPrivKey.rand(range: bigPrime)

			guard randSuccess else {
				return nil
			}
		} while bigPrivKey.isZero

		let modSuccess = BigNum.modExp(y: bigPubKey,
									   g: bigGenerator,
									   x: bigPrivKey,
									   p: bigPrime)

		guard modSuccess else {
			return nil
		}

		// Duo Desktop (#42): the values go at the server's key width. Upstream required both to be exactly that many
		// bytes without padding, so a key with a leading zero byte (about 1 in 128) failed the sign-in.
		guard let privKey = bigPrivKey.fixedWidthBigEndianData(length: keyLength),
			  let pubKey = bigPubKey.fixedWidthBigEndianData(length: keyLength) else {
			return nil
		}

		let keyPair = KeyPair(publicKey: pubKey,
							  privateKey: privKey)

		return keyPair
	}

	static func computeSharedKey(prime: Data,
								 peerKey: Data,
								 privateKey: Data,
								 keyLength: Int) -> Data? {
		guard let bigPrime = BigNum(data: prime),
			  let bigPrivKey = BigNum(data: privateKey),
			  let bigPeerKey = BigNum(data: peerKey) else {
			return nil
		}

		let bigSharedKey = BigNum()

		let modSuccess = BigNum.modExp(y: bigSharedKey,
									   g: bigPeerKey,
									   x: bigPrivKey,
									   p: bigPrime)

		guard modSuccess else {
			return nil
		}

		// Duo Desktop (#42): the shared secret is hashed at full width, leading zero bytes included, as the Mac does.
		guard let sharedKey = bigSharedKey.fixedWidthBigEndianData(length: keyLength) else {
			return nil
		}

		return sharedKey
	}
}
